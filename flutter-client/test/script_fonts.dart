// Fonts for the layout tests that must see the app's words as a phone draws
// them (24 Sep 2026, owner's "fix all bugs"). Not a test file: suites import it.
//
// Inter has no Devanagari, Bengali, Gujarati or Gurmukhi; a phone draws those
// from its system Noto fonts, and the test engine has no system fonts at all.
// [loadScriptFonts] loads Inter as the app bundles it and the four Noto Sans
// fonts from this machine's font directory, and [withScriptFallback] names the
// Noto fonts as the type ramp's fallback — what Android does by itself — so a
// Hindi label is laid out with Hindi glyph widths and a line that mixes the
// scripts gets the taller line a phone gives it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The system fonts a phone falls back to for the four Indic scripts.
const scriptFonts = {
  'Noto Sans Devanagari': 'NotoSansDevanagari',
  'Noto Sans Bengali': 'NotoSansBengali',
  'Noto Sans Gujarati': 'NotoSansGujarati',
  'Noto Sans Gurmukhi': 'NotoSansGurmukhi',
};
const _fontDir = '/usr/share/fonts/truetype/noto';

/// Whether this machine has the Noto fonts; a suite skips without them.
bool haveScriptFonts() => scriptFonts.values.every(
  (file) => File('$_fontDir/$file-Regular.ttf').existsSync(),
);

Future<void> loadScriptFonts() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
  if (!haveScriptFonts()) return;
  for (final MapEntry(key: family, value: file) in scriptFonts.entries) {
    final loader = FontLoader(family);
    for (final face in ['Regular', 'Bold']) {
      final path = '$_fontDir/$file-$face.ttf';
      if (!File(path).existsSync()) continue;
      final bytes = File(path).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}

/// [base] with the phone's script fallback made explicit.
ThemeData withScriptFallback(ThemeData base) {
  final fallback = scriptFonts.keys.toList();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamilyFallback: fallback),
  );
}
