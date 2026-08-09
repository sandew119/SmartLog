import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smartlog2/screens/log_face_trace_screen.dart';

import 'support/async_pump.dart';

const _imageSize = 400;
const _centre = Offset(200, 200);
const _radiusX = 150.0;
const _radiusY = 90.0;

/// A pale elliptical face on a dark background, written to a real file.
///
/// The screen decodes the photo through Flutter's own image pipeline and
/// traces it in a background isolate, so nothing here can be faked: it has
/// to be a picture on disk.
File _writeFace(Directory dir) {
  final image = img.Image(width: _imageSize, height: _imageSize);

  for (var y = 0; y < _imageSize; y++) {
    for (var x = 0; x < _imageSize; x++) {
      final dx = (x - _centre.dx) / _radiusX;
      final dy = (y - _centre.dy) / _radiusY;

      final inside = dx * dx + dy * dy <= 1;

      image.setPixelRgb(
        x,
        y,
        inside ? 210 : 38,
        inside ? 190 : 36,
        inside ? 155 : 33,
      );
    }
  }

  final file = File("${dir.path}/face.png")
    ..writeAsBytesSync(img.encodePng(image));

  return file;
}

/// The screen's canvas, and the scale the photo is drawn at inside it.
({Rect rect, double scale}) _canvas(WidgetTester tester) {
  final rect = tester.getRect(find.byKey(const ValueKey("trace-canvas")));

  // BoxFit.contain on a square photo: the smaller side decides the scale and
  // the picture is centred, so the ellipse's centre lands on the canvas
  // centre and its semi-axes scale by this factor.
  return (rect: rect, scale: math.min(rect.width, rect.height) / _imageSize);
}

/// The "18.4 × 11.0 in" line, which is the only place the outline's shape is
/// visible as text -- and so the only way to tell whether a drag changed it.
String _summary() {
  // The caption underneath it reads "widest × narrowest", so matching on the
  // separator alone is not enough -- only the measurement carries the unit.
  final matches = find
      .byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data?.contains(" × ") ?? false) &&
            w.data!.endsWith(" in"),
      )
      .evaluate();

  return (matches.single.widget as Text).data!;
}

void main() {
  late Directory dir;
  late File photo;

  setUp(() {
    dir = Directory.systemTemp.createTempSync("smartlog_trace_test");
    photo = _writeFace(dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> traceIt(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LogFaceTraceScreen(photo: photo, initialGirthInches: 60),
      ),
    );

    // The photo has to be decoded before a tap can be mapped into it.
    await pumpUntilFound(tester, find.text("Tap the middle of the cut face"));

    await tester.tapAt(_canvas(tester).rect.center);

    // Detection runs in a real isolate.
    await pumpUntilFound(tester, find.text("Adjust"));
  }

  testWidgets('a tap finds the face and the outline can be measured',
      (tester) async {
    await tester.runAsync(() async {
      await traceIt(tester);

      // 150 x 90 pixel semi-axes, so the face is markedly oval. Recovering
      // that is the whole reason the outline exists.
      final parts = _summary().split(" × ");
      final major = double.parse(parts[0]);
      final minor = double.parse(parts[1].replaceAll(" in", ""));

      expect(major, greaterThan(minor * 1.4));

      expect(find.text("Use This Outline"), findsOneWidget);
    });
  });

  testWidgets('dragging empty photo leaves the outline alone', (tester) async {
    await tester.runAsync(() async {
      await traceIt(tester);

      final before = _summary();
      final canvas = _canvas(tester);

      // Well outside the face, and nowhere near a handle. The old screen
      // grabbed whichever of its 72 points happened to be nearest -- often
      // one on the far side of the log -- and dragged a dent into the
      // boundary. A stray touch must now do nothing at all.
      await tester.dragFrom(
        canvas.rect.topLeft + const Offset(14, 14),
        const Offset(120, 90),
      );
      await tester.pump();

      expect(_summary(), before);
    });
  });

  testWidgets('dragging the width handle resizes only that axis',
      (tester) async {
    await tester.runAsync(() async {
      await traceIt(tester);

      final before = _summary();
      final canvas = _canvas(tester);

      // The face is drawn unrotated, so the long axis runs horizontally and
      // its handle sits one semi-major axis to the right of centre.
      final handle = canvas.rect.center + Offset(_radiusX * canvas.scale, 0);

      await tester.dragFrom(handle, const Offset(40, 0));
      await tester.pump();

      final after = _summary();
      expect(after, isNot(before));

      // Pulling the long axis out makes the face longer relative to its
      // width; the short axis must not have followed.
      double majorOf(String s) => double.parse(s.split(" × ").first);
      double minorOf(String s) =>
          double.parse(s.split(" × ").last.replaceAll(" in", ""));

      expect(
        majorOf(after) / minorOf(after),
        greaterThan(majorOf(before) / minorOf(before)),
      );
    });
  });

  testWidgets('a tap marks one defect, and tapping it again clears it',
      (tester) async {
    await tester.runAsync(() async {
      await traceIt(tester);

      await tester.tap(find.text("Defects"));
      await tester.pump();

      final spot = _canvas(tester).rect.center;

      // One tap, one defect. When the canvas carried both tap and pan
      // recognisers this ran twice -- adding the defect and then finding it
      // already there and removing it -- so nothing could ever be marked.
      await tester.tapAt(spot);
      await tester.pump();

      expect(find.text("1 defect marked"), findsOneWidget);

      // The same gesture takes it away again: there is no delete mode to
      // discover.
      await tester.tapAt(spot);
      await tester.pump();

      expect(find.text("widest × narrowest"), findsOneWidget);
    });
  });

  testWidgets('a grabbed handle is not let go of mid-drag', (tester) async {
    await tester.runAsync(() async {
      await traceIt(tester);

      final canvas = _canvas(tester);
      final handle = canvas.rect.center + Offset(_radiusX * canvas.scale, 0);

      // Drag the long-axis handle *across* the log and out the other side.
      // Under the old "nearest point wins" behaviour the gesture would let
      // go of this handle the moment the finger passed the middle. Holding
      // it means the axis simply follows the finger, so the shape stays a
      // sane ellipse rather than collapsing.
      final gesture = await tester.startGesture(handle);

      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(-18, 0));
        await tester.pump();
      }

      await gesture.up();
      await tester.pump();

      final parts = _summary().split(" × ");
      final major = double.parse(parts[0]);
      final minor = double.parse(parts[1].replaceAll(" in", ""));

      expect(major, greaterThan(0));
      expect(minor, greaterThan(0));
      expect(major, greaterThanOrEqualTo(minor));

      // Still a usable outline, not a degenerate sliver.
      expect(find.text("Use This Outline"), findsOneWidget);
    });
  });
}
