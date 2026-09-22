import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

/// Paints [painter] offscreen at [size] and returns a PNG.
///
/// This is how the report gets the same pictures the screen shows -- the
/// defect overlay and the sawing pattern -- without screenshotting widgets:
/// the painters are asked to draw into a recorder at print resolution.
Future<Uint8List?> paintToPng(CustomPainter painter, Size size) async {
  if (size.width <= 0 || size.height <= 0) return null;

  try {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);

    painter.paint(canvas, size);

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.round(),
      size.height.round(),
    );

    final data = await image.toByteData(format: ui.ImageByteFormat.png);

    picture.dispose();
    image.dispose();

    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// Loads a photo through Flutter's own decoder, so its orientation matches
/// exactly what every screen painted.
Future<ui.Image?> loadUiImage(File file) async {
  try {
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  } catch (_) {
    return null;
  }
}

/// A downscaled copy of [image] whose longest side is at most [maxSide],
/// drawn by the GPU rather than resampled pixel by pixel in Dart.
Future<ui.Image> downscale(ui.Image image, int maxSide) async {
  final longest = image.width > image.height ? image.width : image.height;
  if (longest <= maxSide) return image;

  final scale = maxSide / longest;
  final width = (image.width * scale).round().clamp(1, maxSide);
  final height = (image.height * scale).round().clamp(1, maxSide);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );

  final picture = recorder.endRecording();
  final small = await picture.toImage(width, height);
  picture.dispose();

  return small;
}
