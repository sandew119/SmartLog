import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/utils/depth_frame.dart';
import 'package:smartlog2/utils/face_scan.dart';
import 'package:vector_math/vector_math_64.dart';

import 'support/synthetic_depth.dart';

/// A face's girth is what the log is billed on, so every one of these checks
/// the recovered figure against a perimeter worked out independently -- not
/// against whatever the code happened to produce when it was written.
void main() {
  final camera = SyntheticCamera();

  FaceScan requireFace(FaceAttempt attempt) {
    expect(
      attempt.face,
      isNotNull,
      reason: 'rejected as ${attempt.rejection}',
    );
    return attempt.face!;
  }

  group('a round cut face', () {
    const distance = 0.6;
    const radius = 0.15;

    late FaceScan face;

    setUp(() {
      final depths = camera.renderFace(
        centre: Vector3(0, 0, -distance),
        normal: Vector3(0, 0, 1),
        outline: (_) => radius,
      );

      face = requireFace(FaceScanner.detect(camera.frame(depths)));
    });

    test('is found square on, at the distance it was placed', () {
      expect(face.distanceMetres, closeTo(distance, 0.01));
      expect(face.tiltDegrees, lessThan(3));
    });

    test('traces a girth within 2% of the true circumference', () {
      expect(face.girthMetres, closeTo(2 * math.pi * radius, 0.02 * 2 * math.pi * radius));
    });

    test('reports the diameter it was drawn with', () {
      expect(face.diameterMetres, closeTo(2 * radius, 0.01));
    });

    test('reads as flat, and as fully in frame', () {
      expect(face.flatnessMm, lessThan(5));
      expect(face.touchesFrameEdge, isFalse);
      expect(face.outline.observedFraction, 1.0);
    });

    test('faces the camera, so the normal points back down the log', () {
      expect(face.normal.dot(Vector3(0, 0, 1)), greaterThan(0.99));
    });

    test('satisfies Cauchy: perimeter is pi times the mean width', () {
      expect(
        face.girthMetres,
        closeTo(math.pi * face.outline.meanWidthMetres, 0.01),
      );
    });
  });

  group('an oval face', () {
    // Logs are rarely round, and an oval is where a circle fit starts
    // lying: it reports one radius and there are two.
    const a = 0.18;
    const b = 0.12;

    double outline(double angle) {
      // Radius of an ellipse at a polar angle about its centre.
      final c = math.cos(angle), s = math.sin(angle);
      return a * b / math.sqrt(b * b * c * c + a * a * s * s);
    }

    late FaceScan face;

    setUp(() {
      final depths = camera.renderFace(
        centre: Vector3(0, 0, -0.75),
        normal: Vector3(0, 0, 1),
        outline: outline,
      );

      face = requireFace(FaceScanner.detect(camera.frame(depths)));
    });

    test('traces the ellipse perimeter, not a circle through it', () {
      final expected = truePerimeter(outline);

      expect(face.girthMetres, closeTo(expected, 0.03 * expected));

      // The circle a fit would have reported, for contrast: assuming
      // roundness understates an oval log every time.
      final circleGirth = math.pi * face.diameterMetres;
      expect(circleGirth, lessThan(expected));
    });

    test('reports the narrow and the wide way across', () {
      expect(face.outline.minWidthMetres, closeTo(2 * b, 0.02));
      expect(face.outline.maxWidthMetres, closeTo(2 * a, 0.02));
    });

    test('still satisfies Cauchy, which is what carries it along the log',
        () {
      expect(
        face.girthMetres,
        closeTo(math.pi * face.outline.meanWidthMetres, 0.02 * face.girthMetres),
      );
    });
  });

  group('a lobed, irregular face', () {
    double outline(double angle) => 0.16 * (1 + 0.14 * math.cos(3 * angle));

    test('traces close to the real outline', () {
      final depths = camera.renderFace(
        centre: Vector3(0, 0, -0.7),
        normal: Vector3(0, 0, 1),
        outline: outline,
      );

      final face = requireFace(FaceScanner.detect(camera.frame(depths)));
      final expected = truePerimeter(outline);

      expect(face.girthMetres, closeTo(expected, 0.03 * expected));
    });
  });

  group('a face seen at an angle', () {
    const radius = 0.14;

    test('is measured in its own plane, so the girth is not foreshortened',
        () {
      final normal = Vector3(math.sin(0.5), 0, math.cos(0.5));

      final depths = camera.renderFace(
        centre: Vector3(0, 0, -0.7),
        normal: normal,
        outline: (_) => radius,
      );

      final face = requireFace(FaceScanner.detect(camera.frame(depths)));

      expect(face.tiltDegrees, closeTo(0.5 * 180 / math.pi, 4));
      expect(
        face.girthMetres,
        closeTo(2 * math.pi * radius, 0.04 * 2 * math.pi * radius),
      );
    });

    test('is refused once it is more side than end', () {
      final normal = Vector3(math.sin(1.15), 0, math.cos(1.15));

      final depths = camera.renderFace(
        centre: Vector3(0, 0, -0.7),
        normal: normal,
        outline: (_) => radius,
      );

      final attempt = FaceScanner.detect(camera.frame(depths));

      expect(attempt.isFound, isFalse);
      expect(attempt.rejection, FaceRejection.tooAngled);
    });
  });

  group('things that are not a cut face', () {
    test('the curved side of a log is refused, not measured', () {
      final depths = camera.renderCylinderSide(
        centre: Vector3(0, 0, -0.8),
        axis: Vector3(1, 0, 0),
        radius: 0.16,
      );

      final attempt = FaceScanner.detect(camera.frame(depths));

      expect(attempt.isFound, isFalse);
      expect(attempt.rejection, FaceRejection.notFlat);
    });

    test('a face too big for the frame is refused with a reason', () {
      final depths = camera.renderFace(
        centre: Vector3(0, 0, -0.35),
        normal: Vector3(0, 0, 1),
        outline: (_) => 0.30,
      );

      final attempt = FaceScanner.detect(camera.frame(depths));

      expect(attempt.isFound, isFalse);
      expect(attempt.rejection, FaceRejection.runsOffScreen);
    });

    test('an empty scene is refused for want of depth', () {
      final attempt = FaceScanner.detect(
        camera.frame(
          camera.renderFace(
            centre: Vector3(0, 0, -0.6),
            normal: Vector3(0, 0, 1),
            outline: (_) => 0.0,
            backgroundDepth: 12,
          ),
        ),
      );

      expect(attempt.isFound, isFalse);
    });

    test('a face further than the sensor can trace is refused as too far',
        () {
      final depths = camera.renderFace(
        centre: Vector3(0, 0, -3.2),
        normal: Vector3(0, 0, 1),
        outline: (_) => 0.2,
        backgroundDepth: 5.5,
      );

      final attempt = FaceScanner.detect(camera.frame(depths));

      expect(attempt.rejection, FaceRejection.tooFar);
    });
  });

  group('a log resting against its neighbour', () {
    test('two ends touching are refused, not averaged into one girth', () {
      // Coplanar and in contact, which is the one arrangement no depth test
      // can separate: there is no step between them to stop at. The scanner
      // must refuse rather than report the peanut it traced -- a confident
      // wrong girth is far worse here than no reading, and the user fixes it
      // by shifting their aim.
      const radius = 0.12;

      final depths = camera.renderFace(
        centre: Vector3(0, 0, -0.65),
        normal: Vector3(0, 0, 1),
        outline: (_) => radius,
      );

      final neighbour = camera.renderFace(
        centre: Vector3(0.235, 0, -0.65),
        normal: Vector3(0, 0, 1),
        outline: (_) => radius,
      );

      for (var i = 0; i < depths.length; i++) {
        if (neighbour[i] < depths[i]) depths[i] = neighbour[i];
      }

      final attempt = FaceScanner.detect(camera.frame(depths));

      expect(attempt.isFound, isFalse);
      expect(attempt.rejection, FaceRejection.moreThanOneLog);
    });

    test('one end with the neighbour set back is measured normally', () {
      // The common case in a real stack: ends are not flush, so there is a
      // depth step for the fill to stop at.
      const radius = 0.12;

      final depths = camera.renderFace(
        centre: Vector3(0, 0, -0.65),
        normal: Vector3(0, 0, 1),
        outline: (_) => radius,
      );

      final neighbour = camera.renderFace(
        centre: Vector3(0.235, 0, -0.78),
        normal: Vector3(0, 0, 1),
        outline: (_) => radius,
      );

      for (var i = 0; i < depths.length; i++) {
        if (neighbour[i] < depths[i]) depths[i] = neighbour[i];
      }

      final face = requireFace(FaceScanner.detect(camera.frame(depths)));

      expect(
        face.girthMetres,
        closeTo(2 * math.pi * radius, 0.05 * 2 * math.pi * radius),
      );
    });
  });

  group('the depth frame itself', () {
    test('rescales intrinsics from the full image to the depth grid', () {
      final frame = camera.frame(
        camera.renderFace(
          centre: Vector3(0, 0, -0.6),
          normal: Vector3(0, 0, 1),
          outline: (_) => 0.15,
        ),
      );

      expect(frame.fx, closeTo(110, 1e-6));
      expect(frame.cx, closeTo(64, 1e-6));
      expect(frame.width, 128);
    });

    test('puts a pixel where the scene put it', () {
      final frame = camera.frame(
        camera.renderFace(
          centre: Vector3(0, 0, -0.6),
          normal: Vector3(0, 0, 1),
          outline: (_) => 0.15,
        ),
      );

      final centre = frame.worldPointAt(64, 48)!;

      expect(centre.x, closeTo(0, 0.01));
      expect(centre.y, closeTo(0, 0.01));
      expect(centre.z, closeTo(-0.6, 0.01));
    });

    test('refuses a malformed payload instead of throwing', () {
      expect(DepthFrame.fromNative(const {}), isNull);
      expect(
        DepthFrame.fromNative(const {'width': 4, 'height': 4}),
        isNull,
      );
    });
  });
}
