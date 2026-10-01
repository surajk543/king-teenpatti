import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// The loaders a profile picture can be drawn with.
enum PictureKind { bitmap, svg, lottie, unsupported }

/// Which loader draws [bytes].
///
/// A declared [format] wins: it is the catalogue saying what the file is
/// ('IMAGE' | 'SVG' | 'LOTTIE' | 'RIVE'). Without one the bytes are read for
/// their magic numbers — reliable where a URL extension is not (hosted URLs
/// rarely have one), and the only way a seat pod or the top bar can tell an
/// animation from a photo, because a worn picture reaches them as a bare URL
/// with no catalogue row beside it.
///
/// RIVE is [PictureKind.unsupported]: no Rive runtime ships in the app yet, so
/// the bundled default is the honest answer — decoding a .riv as a bitmap is
/// not.
PictureKind pictureKindOf(String? format, Uint8List bytes) {
  switch (format) {
    case 'LOTTIE':
      return PictureKind.lottie;
    case 'SVG':
      return PictureKind.svg;
    case 'IMAGE':
      return PictureKind.bitmap;
    case 'RIVE':
      return PictureKind.unsupported;
  }
  if (bytes.length >= 4) {
    // "PK\x03\x04" is a zip, which in a picture slot is a dotLottie.
    if (bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04) {
      return PictureKind.lottie;
    }
    // "RIVE" opens every Rive runtime file.
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x56 && bytes[3] == 0x45) {
      return PictureKind.unsupported;
    }
  }
  // Text formats: past a UTF-8 byte-order mark and leading whitespace, '{'
  // opens a Lottie JSON and '<' an SVG (or the XML prolog before one).
  var i = 0;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    i = 3;
  }
  while (i < bytes.length &&
      (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D)) {
    i++;
  }
  if (i < bytes.length) {
    if (bytes[i] == 0x7B) return PictureKind.lottie;
    if (bytes[i] == 0x3C) return PictureKind.svg;
  }
  return PictureKind.bitmap;
}

/// The canvas a Lottie declares at its head, as width over height, or null
/// when the head does not say (not a Lottie, or `w`/`h` past the first 512
/// bytes, where Bodymovin never puts them). What a box needs to know to fit
/// a banner-shaped file whole rather than crop it to a fragment.
double? lottieCanvasAspect(Uint8List bytes) {
  final end = bytes.length < 512 ? bytes.length : 512;
  final head = String.fromCharCodes(bytes.sublist(0, end));
  final w = RegExp(r'"w"\s*:\s*(\d+(?:\.\d+)?)').firstMatch(head);
  final h = RegExp(r'"h"\s*:\s*(\d+(?:\.\d+)?)').firstMatch(head);
  if (w == null || h == null) return null;
  final width = double.parse(w.group(1)!);
  final height = double.parse(h.group(1)!);
  if (width <= 0 || height <= 0) return null;
  return width / height;
}

/// Whether [bytes] are a web page rather than a picture — what a host serves
/// in place of a file it will not hand out: Google Drive's sign-in page for a
/// file that is not shared (or not shared *yet*: a phone that asked in the
/// minute before the owner set "Anyone with the link" got one, 16 Sep 2026),
/// a "download quota exceeded" notice, a captive portal's login. Such a page
/// answers 200, so the status says nothing, and [pictureKindOf] reads its
/// leading '<' as an SVG. Past a byte-order mark and whitespace, `<!doctype
/// html` or `<html` (any case) is a page; `<?xml`, `<svg` and an SVG's own
/// `<!DOCTYPE svg` are pictures.
bool looksLikeHtml(Uint8List bytes) {
  var i = 0;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    i = 3;
  }
  while (i < bytes.length &&
      (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D)) {
    i++;
  }
  if (i >= bytes.length || bytes[i] != 0x3C) return false;
  final end = bytes.length < i + 32 ? bytes.length : i + 32;
  final head = String.fromCharCodes(bytes.sublist(i, end)).toLowerCase();
  return head.startsWith('<html') || RegExp(r'^<!doctype\s+html').hasMatch(head);
}

/// Whether [url] is a LOCATION in the catalogue's private Cloudflare R2
/// bucket (owner, 1 Oct 2026): `https://<account>.r2.cloudflarestorage.com/<bucket>/<key>`,
/// with no query. The server hands every catalogue file out
/// as its location — the path the database stores, which never changes for a
/// file — and no phone can open one as it stands: [PictureCache] asks the
/// server to sign it ([PictureCache.signer]) and downloads the signed URL,
/// keeping the file under the location.
bool isAssetLocation(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.endsWith('.r2.cloudflarestorage.com') &&
      !uri.hasQuery &&
      uri.pathSegments.length >= 3;
}

/// What POST /api/assets/sign answered: each location it signed, mapped to
/// its signed URL, and when they all stop working (ten minutes on).
class SignedAssets {
  const SignedAssets(this.urls, this.expiresAt);

  /// Nothing signed: signed out, or a server that cannot sign.
  static final none = SignedAssets(
    const {},
    DateTime.fromMillisecondsSinceEpoch(0),
  );

  final Map<String, String> urls;
  final DateTime expiresAt;
}

/// Signs catalogue locations for a download (GameState wires
/// ApiClient.signAssets with the session's token).
typedef AssetSigner = Future<SignedAssets> Function(List<String> locations);

/// Profile pictures, kept on the phone after the first fetch.
///
/// The catalogue is a set of remote URLs (requirement 21), and without this
/// every one of them was fetched again on every cold start, and again each
/// time the picker opened — fifteen round trips to show faces that had not
/// changed since yesterday. A picture is addressed by its URL and a URL's
/// contents do not change: re-pricing or retiring a row changes the row, and a
/// new picture is a new URL. So a file that is on disk is correct for ever,
/// and the only reason to go to the network is not having it yet.
///
/// Three layers, in the order they are asked:
///
///  1. **memory** — [peek], synchronous. Five seat pods and a picker rebuild
///     constantly (the lobby repaints once a second for the reward clock), and
///     none of that should touch the disk, let alone the network.
///  2. **disk** — the app's support directory, which is backed up neither by
///     iCloud nor by Android auto-backup and is the right home for something
///     re-fetchable.
///  3. **network** — once, with the result written to both layers above.
///
/// A failure is not cached. A phone that lost the network mid-fetch gets the
/// bundled default picture for now and tries again on the next build, rather
/// than being told for the rest of the session that the picture does not
/// exist.
///
/// A catalogue file in the R2 bucket ([isAssetLocation]; owner, 1 Oct 2026:
/// "backend will give signed urls valid for 10 min, UI will download and save
/// in phone disk or cache, when user login again, it will see the path of
/// assets is changed, so the UI will ask for new signed url for changed asset
/// path stored in db") is kept under its LOCATION like any URL, so a file the
/// phone has is read from its disk with no network and no signature at all.
/// Only a location it does not have — a new file, or a file the server now
/// names by a new path — goes to the network: [signer] asks the server for a
/// signed URL valid ten minutes (one request for every location asked for
/// within [signWindow], at most [signBatch] at a time), and the file is
/// downloaded from that and written under the location.
///
/// At most [maxDownloads] downloads run at once, whatever their host.
class PictureCache {
  PictureCache._();

  /// Decoded bytes by URL. Bounded: a player sees a few dozen pictures at
  /// most, and the files are 9-64 KB, but an unbounded map behind a widget
  /// that every seat builds is the kind of thing that is fine until it is not.
  static final Map<String, Uint8List> _memory = <String, Uint8List>{};
  static const _memoryLimit = 64;

  /// Fetches already running, so five pods showing the same face cause one
  /// download rather than five.
  static final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};

  static Directory? _dir;
  static Future<Directory?>? _dirOpening;

  /// Signs catalogue locations for a download (POST /api/assets/sign). Null —
  /// no session wired yet, a test — signs nothing, and a location then fails
  /// like any picture that could not be fetched.
  static AssetSigner? signer;

  /// How long locations asked for are gathered into one signing request.
  static const signWindow = Duration(milliseconds: 30);

  /// The most locations one signing request carries (the server takes 200).
  static const signBatch = 100;

  /// A signed URL with less than this left is not started on: asked again.
  static const signedMargin = Duration(seconds: 30);

  /// The signed URLs held, by location, until they stop working.
  static final Map<String, ({String url, DateTime expiresAt})> _signed = {};

  /// Locations waiting for the next signing request.
  static final Map<String, Completer<String?>> _toSign = {};
  static Timer? _signTimer;

  /// The most downloads running at once, as a browser opens at most six
  /// connections to one host. A first sign-in asks for every picture, emoji
  /// and table picture at the same moment — over a hundred files, each its
  /// own TLS connection — and all at once they crowd each other out: on the
  /// emulator every one of 128 ran out of time (1 Oct 2026), where six at a
  /// time bring them all in.
  static const maxDownloads = 6;
  static int _downloading = 0;
  static final Queue<Completer<void>> _waitingForSlot = Queue<Completer<void>>();

  /// What is already in memory, or null. Synchronous on purpose: a widget can
  /// paint the picture on its first frame when it has been seen before, with
  /// no placeholder flash and no future to await.
  static Uint8List? peek(String url) => _memory[url];

  /// Puts [bytes] in memory as if [url] had been fetched, for tests that draw
  /// a picture without a network or a disk.
  @visibleForTesting
  static void prime(String url, Uint8List bytes) => _remember(url, bytes);

  /// The picture's bytes, from wherever they can be had.
  static Future<Uint8List?> load(String url) {
    final cached = _memory[url];
    if (cached != null) return Future<Uint8List?>.value(cached);
    final running = _inFlight[url];
    if (running != null) return running;

    // A BLOCK body, not an arrow. Map.remove returns the value it removed —
    // which here is this very future — and whenComplete awaits a returned
    // future, so the arrow form made the fetch wait on itself and no picture
    // ever arrived. It reads as a tidy one-liner and deadlocks every avatar.
    final fetch = _read(url).whenComplete(() {
      _inFlight.remove(url);
    });
    _inFlight[url] = fetch;
    return fetch;
  }

  static Future<Uint8List?> _read(String url) async {
    final dir = await _directory();
    final file = dir == null ? null : File('${dir.path}/${_key(url)}');

    if (file != null) {
      try {
        if (file.existsSync()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty && !looksLikeHtml(bytes)) {
            _remember(url, bytes);
            return bytes;
          }
          if (bytes.isNotEmpty) {
            // A page kept before [_download] refused them (16 Sep 2026): a
            // phone that had cached Drive's sign-in for a not-yet-shared file
            // would otherwise show a bare felt for that picture for ever.
            // Deleted, so this fetch and its write start clean.
            file.deleteSync();
          }
        }
      } on FileSystemException {
        // A half-written or unreadable file is not worth reporting; fetching
        // again overwrites it.
      }
    }

    final Uint8List? fetched = await _download(url);
    if (fetched == null) return null;
    _remember(url, fetched);
    if (file != null) {
      // Write through a temporary name so a process killed mid-write cannot
      // leave a truncated file that would then be served as the picture.
      try {
        final tmp = File('${file.path}.part');
        await tmp.writeAsBytes(fetched, flush: true);
        await tmp.rename(file.path);
      } on FileSystemException {
        // Out of space, or a sandbox that will not have it: the picture still
        // shows this session, it is just not kept.
      }
    }
    return fetched;
  }

  static Future<Uint8List?> _download(String url) async {
    // A file of the private bucket is downloaded through a URL the server
    // signs for it, never through the location itself. Asked for before the
    // wait for a slot, so every location wanted at the same moment goes to
    // the server in one request.
    final location = isAssetLocation(url);
    if (location && await _signedUrl(url) == null) return null;
    await _takeSlot();
    try {
      var from = url;
      if (location) {
        // The URL just signed, or a fresh one if the wait ran it down.
        final signed = await _signedUrl(url);
        if (signed == null) return null;
        from = signed;
      }
      final response = await http
          .get(Uri.parse(from))
          .timeout(const Duration(seconds: 12));
      if (location && response.statusCode == 403) {
        // Run out (a phone asleep past its ten minutes) or refused: the next
        // try asks for a fresh one.
        _signed.remove(url);
      }
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      // A page is not a picture, and a 200 does not say which one arrived:
      // Drive answers a file that is not (yet) shared with its sign-in page.
      // Kept, it would be served as the picture for ever — this cache treats
      // a URL's contents as immutable. Refused, it is asked for again on the
      // next build, by when the owner may have shared the file.
      final type = response.headers['content-type'] ?? '';
      if (type.startsWith('text/html') || looksLikeHtml(response.bodyBytes)) {
        return null;
      }
      return response.bodyBytes;
    } catch (_) {
      // Offline, DNS, TLS, a timeout, a malformed URL from a catalogue row:
      // all the same answer here, and all retried on the next build.
      return null;
    } finally {
      _releaseSlot();
    }
  }

  /// Waits for one of the [maxDownloads] slots.
  static Future<void> _takeSlot() {
    if (_downloading < maxDownloads) {
      _downloading++;
      return Future<void>.value();
    }
    final turn = Completer<void>();
    _waitingForSlot.add(turn);
    return turn.future;
  }

  /// Hands the slot to the download waiting longest, or frees it.
  static void _releaseSlot() {
    if (_waitingForSlot.isNotEmpty) {
      _waitingForSlot.removeFirst().complete();
    } else {
      _downloading--;
    }
  }

  /// A URL [location] can be downloaded from now: one held with more than
  /// [signedMargin] left, else asked for in the next signing request. Null
  /// when the server would not sign it (not a file the catalogue stores,
  /// signed out, offline).
  static Future<String?> _signedUrl(String location) {
    final held = _signed[location];
    if (held != null &&
        held.expiresAt.isAfter(DateTime.now().add(signedMargin))) {
      return Future<String?>.value(held.url);
    }
    final waiting = _toSign[location];
    if (waiting != null) return waiting.future;
    final asked = Completer<String?>();
    _toSign[location] = asked;
    _signTimer ??= Timer(signWindow, () => unawaited(_signWaiting()));
    return asked.future;
  }

  /// Sends every location waiting in requests of at most [signBatch].
  static Future<void> _signWaiting() async {
    _signTimer = null;
    final waiting = Map<String, Completer<String?>>.of(_toSign);
    _toSign.clear();
    final locations = waiting.keys.toList();
    for (var i = 0; i < locations.length; i += signBatch) {
      final batch = locations.sublist(
        i,
        (i + signBatch).clamp(0, locations.length),
      );
      SignedAssets answer = SignedAssets.none;
      final sign = signer;
      if (sign != null) {
        try {
          answer = await sign(batch);
        } catch (_) {
          // Offline, signed out, a server that cannot sign: these files are
          // not fetched now, and the next build that shows one asks again.
        }
      }
      for (final location in batch) {
        final url = answer.urls[location];
        if (url != null) {
          _signed[location] = (url: url, expiresAt: answer.expiresAt);
        }
        waiting[location]!.complete(url);
      }
    }
  }

  static void _remember(String url, Uint8List bytes) {
    if (_memory.length >= _memoryLimit && !_memory.containsKey(url)) {
      _memory.remove(_memory.keys.first); // oldest inserted
    }
    _memory[url] = bytes;
  }

  /// sha1 of the URL, so the name is filesystem-safe and a fixed length
  /// whatever the URL looks like. Not for security — for a valid filename.
  static String _key(String url) => sha1.convert(url.codeUnits).toString();

  static Future<Directory?> _directory() {
    final open = _dirOpening;
    if (_dir != null) return Future<Directory?>.value(_dir);
    if (open != null) return open;
    final opening = _openDirectory();
    _dirOpening = opening;
    return opening;
  }

  static Future<Directory?> _openDirectory() async {
    try {
      // Bounded, because this is awaited before every first paint of every
      // picture: a platform channel that never answers would otherwise leave
      // each avatar on its placeholder for the life of the process, with
      // nothing in the log to say why. Two seconds is far longer than asking
      // the OS for a path can honestly take.
      final support = await getApplicationSupportDirectory()
          .timeout(const Duration(seconds: 2));
      final dir = Directory('${support.path}/pictures');
      if (!dir.existsSync()) await dir.create(recursive: true);
      _dir = dir;
      return dir;
    } catch (_) {
      // No platform channel (a unit test on the host VM) or no writable
      // directory: the cache degrades to memory-only, which is still better
      // than nothing and keeps the widget code identical.
      return null;
    }
  }

  /// Fetches [urls] that are not held yet, without blocking the caller.
  ///
  /// Called when the catalogue arrives, so the picker opens on pictures that
  /// are already down rather than fifteen spinners. Deliberately not awaited
  /// and deliberately unbatched — [load] already dedupes, and a failure here
  /// is silent because nothing is waiting on it.
  static void warm(Iterable<String> urls) {
    for (final url in urls) {
      if (url.isEmpty || _memory.containsKey(url)) continue;
      unawaited(load(url));
    }
  }

  /// Fetches every one of [urls] that is not on the phone yet onto its disk,
  /// one after another, WITHOUT holding it in memory: for a set the app shows
  /// a few of at a time but should never fetch twice — every level's art
  /// (owner, 29 Sep 2026: "Make sure you cache the all level icons in
  /// phone"), fifty files, which [warm] would push through the
  /// [_memoryLimit] entries the faces on screen live in.
  ///
  /// A URL in memory, being fetched, or already on disk is left alone, so
  /// after the first run this costs a directory lookup per URL and no
  /// network. One at a time, so a first sign-in's downloads never crowd the
  /// ones a screen is waiting on; a widget asking for a URL while it is being
  /// kept joins that fetch ([load]). A failure is silent and the file is not
  /// written: the next call — or the icon being shown — tries again. With no
  /// disk (a unit test with no platform channel) it does nothing.
  static Future<void> keep(Iterable<String> urls) async {
    final dir = await _directory();
    if (dir == null) return;
    // The locations to fetch, signed together first — one request for the
    // lot rather than one per file as the downloads reach them.
    final missing = <String>[
      for (final url in urls.toSet())
        if (isAssetLocation(url) &&
            !_memory.containsKey(url) &&
            !_inFlight.containsKey(url) &&
            !_onDisk(dir, url))
          url,
    ];
    if (missing.isNotEmpty) await Future.wait(missing.map(_signedUrl));
    for (final url in urls.toSet()) {
      if (url.isEmpty ||
          _memory.containsKey(url) ||
          _inFlight.containsKey(url)) {
        continue;
      }
      final file = File('${dir.path}/${_key(url)}');
      try {
        if (file.existsSync() && file.lengthSync() > 0) continue;
      } on FileSystemException {
        continue;
      }
      final fetch = _keep(url, file).whenComplete(() {
        _inFlight.remove(url);
      });
      _inFlight[url] = fetch;
      await fetch;
    }
  }

  static bool _onDisk(Directory dir, String url) {
    try {
      final file = File('${dir.path}/${_key(url)}');
      return file.existsSync() && file.lengthSync() > 0;
    } on FileSystemException {
      return false;
    }
  }

  /// [url] fetched and written to [file], not to memory.
  static Future<Uint8List?> _keep(String url, File file) async {
    final fetched = await _download(url);
    if (fetched == null) return null;
    try {
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(fetched, flush: true);
      await tmp.rename(file.path);
    } on FileSystemException {
      // Out of space: the icon is fetched again when it is shown.
    }
    return fetched;
  }

  /// Points the disk layer at [dir] (null: none), for tests that exercise it
  /// without the platform channel.
  @visibleForTesting
  static void debugUseDirectory(Directory? dir) {
    _dir = dir;
    _dirOpening = dir == null ? Future<Directory?>.value(null) : null;
  }

  /// Forgets everything held in memory. The files stay: this is for tests and
  /// for a sign-out, neither of which should cost the next player a re-fetch.
  static void clearMemory() {
    _memory.clear();
    _inFlight.clear();
    _signed.clear();
  }

  /// Forgets the signer and every signature, for tests.
  @visibleForTesting
  static void debugResetSigning() {
    signer = null;
    _signed.clear();
    _signTimer?.cancel();
    _signTimer = null;
    for (final waiting in _toSign.values) {
      waiting.complete(null);
    }
    _toSign.clear();
  }

  /// How many downloads are running and how many wait for a slot, for tests.
  @visibleForTesting
  static ({int running, int waiting}) get debugDownloads =>
      (running: _downloading, waiting: _waitingForSlot.length);
}
