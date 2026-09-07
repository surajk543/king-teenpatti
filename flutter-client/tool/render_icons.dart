// Renders the launcher, adaptive-icon and native-splash bitmaps from
// assets/app_icon.svg with the project's own toolchain. Run explicitly:
//
//   flutter test tool/render_icons.dart
//
// It is not part of `flutter test` (that only runs test/), so the PNGs in
// android/app/src/main/res change only when someone asks for it.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const res = 'android/app/src/main/res';
const artboard = 1024.0;

Future<Uint8List> rasterise(String svg, int px, {double scale = 1}) async {
  final info = await vg.loadPicture(SvgStringLoader(svg), null);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final s = px / artboard * scale;
  // Centre the (possibly shrunken) artwork on the canvas.
  canvas.translate(px * (1 - scale) / 2, px * (1 - scale) / 2);
  canvas.scale(s, s);
  canvas.drawPicture(info.picture);
  final image = await recorder.endRecording().toImage(px, px);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  info.picture.dispose();
  return bytes!.buffer.asUint8List();
}

Future<void> write(String path, Uint8List bytes) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes);
  stdout.writeln('  wrote $path (${bytes.length} bytes)');
}

/// "powered by sungamestudio.com" as a bitmap for Android 12's branding slot
/// and the pre-12 launch layer-list. Android fits the branding image into a
/// 200×80 dp box and stretches whatever it is given, so the canvas is exactly
/// that box (at the density's scale) with the line centred in it. Transparent
/// ground; colour per theme.
Future<Uint8List> branding(Color colour, double scale) async {
  final w = (200 * scale).round();
  final h = (80 * scale).round();
  final painter = TextPainter(
    text: TextSpan(
      text: 'powered by sungamestudio.com',
      style: TextStyle(
        fontFamily: 'Branding',
        fontSize: 11.5 * scale,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2 * scale,
        color: colour,
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: w.toDouble());
  // One line, or the box is being asked to hold more than it can.
  assert(painter.computeLineMetrics().length == 1, 'branding line wrapped');
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Offset((w - painter.width) / 2, (h - painter.height) / 2));
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

void main() {
  testWidgets('render launcher and splash bitmaps', (tester) async {
    await tester.runAsync(() async {
      final svg = File('assets/app_icon.svg').readAsStringSync();
      // The adaptive foreground has no ground of its own: the launcher paints
      // ic_launcher_background behind it and masks the pair.
      final foreground = svg
          .replaceFirst(RegExp(r'<rect x="0" y="0" width="1024" height="1024" rx="224" fill="url\(#bg\)"/>'), '')
          .replaceFirst(RegExp(r'<g fill="#000" opacity="0.10">[\s\S]*?</g>'), '');

      const densities = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
      for (final entry in densities.entries) {
        await write('$res/mipmap-${entry.key}/ic_launcher.png', await rasterise(svg, (48 * entry.value).round()));
        // 108dp canvas, artwork in the 66% safe zone the mask keeps.
        await write('$res/mipmap-${entry.key}/ic_launcher_foreground.png', await rasterise(foreground, (108 * entry.value).round(), scale: 0.66));
      }
      // Pre-Android-12 launch image: 160dp at xxhdpi, scaled by the system elsewhere.
      await write('$res/drawable-xxhdpi/splash_icon.png', await rasterise(svg, 480));
      await write('$res/drawable-xxxhdpi/splash_icon.png', await rasterise(svg, 640));

      final font = File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf').readAsBytesSync();
      await (FontLoader('Branding')..addFont(Future.value(ByteData.view(font.buffer)))).load();
      await write('$res/drawable-xxhdpi/splash_branding.png', await branding(const Color(0xFF5B5B58), 3));
      await write('$res/drawable-night-xxhdpi/splash_branding.png', await branding(const Color(0xFFB9B9B4), 3));
      await write('$res/drawable-xxxhdpi/splash_branding.png', await branding(const Color(0xFF5B5B58), 4));
      await write('$res/drawable-night-xxxhdpi/splash_branding.png', await branding(const Color(0xFFB9B9B4), 4));
    });
  });
}
