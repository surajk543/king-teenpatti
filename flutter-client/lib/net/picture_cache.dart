import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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

  /// What is already in memory, or null. Synchronous on purpose: a widget can
  /// paint the picture on its first frame when it has been seen before, with
  /// no placeholder flash and no future to await.
  static Uint8List? peek(String url) => _memory[url];

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
          if (bytes.isNotEmpty) {
            _remember(url, bytes);
            return bytes;
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
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      return response.bodyBytes;
    } catch (_) {
      // Offline, DNS, TLS, a timeout, a malformed URL from a catalogue row:
      // all the same answer here, and all retried on the next build.
      return null;
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

  /// Forgets everything held in memory. The files stay: this is for tests and
  /// for a sign-out, neither of which should cost the next player a re-fetch.
  static void clearMemory() {
    _memory.clear();
    _inFlight.clear();
  }
}
