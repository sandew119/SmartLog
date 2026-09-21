import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/screens/log_scanner_screen.dart';
import 'package:vector_math/vector_math_64.dart';

import 'support/synthetic_depth.dart';

/// The scanner screen, run for real: the iOS platform view is stood in for,
/// the native channel is recorded, and synthetic depth frames are delivered
/// over it exactly as the Swift side would send them.
///
/// What this can check is everything Dart does with a frame -- what the user
/// is told, what is drawn on the log, what a tap does, what comes back at the
/// end. What it cannot check is the Swift, which draws the ribbon and answers
/// the tap; that is what `README-VALIDATION.md` is for.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const radius = 0.15;
  const length = 2.4;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late String viewChannel;
  late List<MethodCall> native;
  late String? clipboard;
  var clock = 0.0;

  setUp(() {
    native = [];
    clipboard = null;
    clock = 0;

    // The platform view's own creation call.
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['id'] as int;
        viewChannel = 'smartlog/lidar_scanner/view_$id';

        // Everything the screen then says to the native side is recorded.
        messenger.setMockMethodCallHandler(MethodChannel(viewChannel), (c) async {
          native.add(c);

          // A tap lands in the middle of the picture.
          if (c.method == 'viewToImage') return {'u': 0.5, 'v': 0.5};
          return null;
        });
      }

      return null;
    });

    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// Delivers one frame the way the native side does.
  Future<void> deliver(WidgetTester tester, Map<String, Object?> payload) async {
    final message = const StandardMethodCodec().encodeMethodCall(
      MethodCall('frame', payload),
    );

    await messenger.handlePlatformMessage(viewChannel, message, (_) {});
    await tester.pump();
  }

  Map<String, Object?> nearFrame() {
    final camera = SyntheticCamera();
    clock += 0.1;

    return camera.payload(
      camera.renderFace(
        centre: Vector3(0, 0, -0.6),
        normal: Vector3(0, 0, 1),
        outline: (_) => radius,
      ),
      timestamp: clock,
    );
  }

  Map<String, Object?> sideFrame(double along) {
    final camera = SyntheticCamera(
      transform: Matrix4.translationValues(0.8, 0, -0.6 - along)
        ..rotateY(math.pi / 2),
    );
    clock += 0.1;

    return camera.payload(
      camera.renderCylinderSide(
        centre: Vector3(0, 0, -0.8),
        axis: Vector3(1, 0, 0),
        radius: radius,
      ),
      timestamp: clock,
    );
  }

  Map<String, Object?> farFrame() {
    final camera = SyntheticCamera(
      transform: Matrix4.translationValues(0, 0, -1.2 - length)
        ..rotateY(math.pi),
    );
    clock += 0.1;

    return camera.payload(
      camera.renderFace(
        centre: Vector3(0, 0, -0.6),
        normal: Vector3(0, 0, 1),
        outline: (_) => radius,
      ),
      timestamp: clock,
    );
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: LogScannerScreen()));
    await tester.pump();
  }

  Iterable<MethodCall> calls(String method, {String? id}) => native.where(
        (c) =>
            c.method == method &&
            (id == null || (c.arguments as Map)['id'] == id),
      );

  testWidgets('asks for the camera and says so while it starts', (tester) async {
    await open(tester);

    expect(calls('start'), isNotEmpty);
    expect(find.text('Starting the camera…'), findsOneWidget);
  });

  testWidgets('draws the outline it is measuring, then keeps it on the end',
      (tester) async {
    await open(tester);

    await deliver(tester, nearFrame());

    // Working on it: the outline is on the log before there is a number.
    expect(calls('showOutline', id: 'live'), isNotEmpty);
    expect(find.text('Hold still…'), findsOneWidget);

    await deliver(tester, nearFrame());
    await deliver(tester, nearFrame());

    // Locked: the disc and the outline stay, the live one goes.
    expect(calls('showMarker', id: 'near'), isNotEmpty);
    expect(calls('showOutline', id: 'near'), isNotEmpty);
    expect(calls('clearOutline'), isNotEmpty);
    expect(find.text('Face scan complete'), findsOneWidget);

    // Let the toast time out.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('the outline it draws is a real ribbon', (tester) async {
    await open(tester);
    await deliver(tester, nearFrame());

    final call = calls('showOutline', id: 'live').first;
    final args = call.arguments as Map;

    // Six numbers a point, closed: what the Swift builds its strip from.
    expect((args['vertices'] as List).length % 6, 0);
    expect((args['vertices'] as List).length, greaterThan(100));

    for (final channel in ['r', 'g', 'b', 'a']) {
      expect(args[channel], isA<double>());
    }
  });

  testWidgets('a tap chooses the end under it, and says so', (tester) async {
    await open(tester);
    await deliver(tester, nearFrame());

    expect(find.text('Tap the end you want to measure'), findsOneWidget);

    await tester.tapAt(const Offset(195, 422));
    await tester.pump();

    // The native side was asked where the tap landed in the picture...
    final asked = calls('viewToImage').single.arguments as Map;
    expect(asked['x'], closeTo(0.5, 0.01));
    expect(asked['y'], closeTo(0.5, 0.01));

    // ...and a ring was left on the spot.
    expect(calls('showOutline', id: 'aim'), isNotEmpty);
    expect(find.text('Measuring the end you tapped'), findsOneWidget);

    // Which can be undone.
    await tester.tap(find.text('Use the middle'));
    await tester.pump();

    expect(find.text('Tap the end you want to measure'), findsOneWidget);
    expect(calls('clearOutline', id: 'aim'), isNotEmpty);
  });

  testWidgets('a tap where there is nothing says so', (tester) async {
    await open(tester);
    await deliver(tester, nearFrame());

    // The native side cannot place the tap.
    messenger.setMockMethodCallHandler(MethodChannel(viewChannel), (c) async {
      native.add(c);
      return null;
    });

    await tester.tapAt(const Offset(195, 422));
    await tester.pump();

    expect(find.text('Nothing to measure there'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a whole scan, end to end, comes back as a measurement',
      (tester) async {
    await open(tester);

    for (var i = 0; i < 4; i++) {
      await deliver(tester, nearFrame());
    }

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Now walk to the other end'), findsOneWidget);

    for (var along = 0.3; along < length - 0.2; along += 0.1) {
      await deliver(tester, sideFrame(along));
    }

    // While walking, the trunk is being drawn and the thinnest so far shown.
    expect(find.text('Thinnest so far'), findsOneWidget);
    expect(find.text('Length so far'), findsOneWidget);

    for (var i = 0; i < 4; i++) {
      await deliver(tester, farFrame());
    }

    await tester.pump(const Duration(seconds: 3));

    expect(find.text('Log measured'), findsOneWidget);
    expect(find.text('Thinnest girth'), findsOneWidget);
    expect(find.text('Length, end to end'), findsOneWidget);

    // The far end was outlined too.
    expect(calls('showOutline', id: 'far'), isNotEmpty);
    expect(calls('speak'), isNotEmpty);
  });

  testWidgets('the report can be copied out once the scan is done',
      (tester) async {
    await open(tester);

    for (var i = 0; i < 4; i++) {
      await deliver(tester, nearFrame());
    }
    for (var along = 0.3; along < length - 0.2; along += 0.1) {
      await deliver(tester, sideFrame(along));
    }
    for (var i = 0; i < 4; i++) {
      await deliver(tester, farFrame());
    }

    await tester.pump(const Duration(seconds: 3));

    await tester.scrollUntilVisible(
      find.text('Copy scan report'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Copy scan report'));
    await tester.pump();

    expect(clipboard, isNotNull);
    expect(clipboard, contains('SmartLog scan report'));
    expect(clipboard, contains('near end locked'));
    expect(clipboard, contains('far end locked'));

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('pressing and holding the steps shows the report', (tester) async {
    await open(tester);
    await deliver(tester, nearFrame());

    await tester.longPress(find.text('Cut end'));
    await tester.pumpAndSettle();

    expect(find.text('Scan report'), findsOneWidget);
    expect(find.textContaining('Frames'), findsWidgets);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets('a frame the native side garbles does not break the screen',
      (tester) async {
    await open(tester);

    final message = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('frame', {'width': 4}),
    );

    await messenger.handlePlatformMessage(viewChannel, message, (_) {});
    await tester.pump();

    // Still acknowledged, so the native side keeps sending.
    expect(calls('ack'), isNotEmpty);
    expect(tester.takeException(), isNull);
  });
}
