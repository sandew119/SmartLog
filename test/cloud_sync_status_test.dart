import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/services/cloud_sync_status.dart';
import 'package:smartlog2/widgets/cloud_backup_banner.dart';

FirebaseException _error(String code) =>
    FirebaseException(plugin: "cloud_firestore", code: code);

void main() {
  final status = CloudSyncStatus.instance;

  setUp(status.resetForTesting);

  group('what the user is told', () {
    test('a rejected write says so, and says it will not fix itself', () {
      // This is the exact failure the app was hiding: the security rules
      // granted access to users/{uid} only, and Firestore rules do not
      // cascade into subcollections, so every stack and log was refused.
      final message = CloudSyncStatus.describe(_error("permission-denied"));

      expect(message, contains("security rules"));
      expect(message, contains("not fix itself"));

      // Never imply data loss: the phone's database still has everything.
      expect(message.toLowerCase(), contains("safe on this phone"));
    });

    test('being offline is described as temporary, not as a fault', () {
      for (final code in ["unavailable", "network-request-failed"]) {
        final message = CloudSyncStatus.describe(_error(code));

        expect(message, contains("when you're online"));
        expect(message, isNot(contains("security rules")));
      }
    });

    test('an unknown error still names its code rather than shrugging', () {
      expect(CloudSyncStatus.describe(_error("aborted")), contains("aborted"));
    });

    test('a plain Dart error is handled without crashing', () {
      expect(
        CloudSyncStatus.describe(StateError("boom")),
        contains("saved on this phone"),
      );
    });
  });

  group('telling a bad afternoon apart from a broken configuration', () {
    test('one failure is not treated as persistent', () {
      status.recordFailure(_error("unavailable"));

      expect(status.current.state, CloudSyncState.failed);
      expect(status.current.isPersistentlyFailing, isFalse);
    });

    test('three in a row is', () {
      for (var i = 0; i < 3; i++) {
        status.recordFailure(_error("permission-denied"));
      }

      expect(status.current.consecutiveFailures, 3);
      expect(status.current.isPersistentlyFailing, isTrue);
    });

    test('one success clears the run', () {
      for (var i = 0; i < 5; i++) {
        status.recordFailure(_error("unavailable"));
      }
      expect(status.current.isPersistentlyFailing, isTrue);

      status.recordSuccess();

      expect(status.current.state, CloudSyncState.ok);
      expect(status.current.isPersistentlyFailing, isFalse);
      expect(status.current.consecutiveFailures, 0);
    });

    test('signing out is not a failure', () {
      status.recordSignedOut();

      expect(status.current.state, CloudSyncState.signedOut);
      expect(status.current.isPersistentlyFailing, isFalse);
      expect(status.current.message, isNull);
    });

    test('a success timestamp survives later failures', () {
      status.recordSuccess();
      final succeededAt = status.current.lastSuccess;

      status.recordFailure(_error("unavailable"));

      // "Last backed up at ..." must still be answerable after things break.
      expect(status.current.lastSuccess, succeededAt);
      expect(status.current.lastFailure, isNotNull);
    });
  });

  group('the banner', () {
    Future<void> pumpBanner(WidgetTester tester) => tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: CloudBackupBanner()),
          ),
        );

    testWidgets('says nothing while backups are working', (tester) async {
      status.recordSuccess();
      await pumpBanner(tester);

      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('says nothing after a single blip', (tester) async {
      status.recordFailure(_error("unavailable"));
      await pumpBanner(tester);

      // A yard with no signal is not worth interrupting anyone about.
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('warns once failures are systematic', (tester) async {
      await pumpBanner(tester);

      for (var i = 0; i < 3; i++) {
        status.recordFailure(_error("permission-denied"));
      }
      await tester.pump();

      expect(find.text("Cloud backup isn't working"), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    });

    testWidgets('separates a configuration fault from a connection one',
        (tester) async {
      await pumpBanner(tester);

      for (var i = 0; i < 3; i++) {
        status.recordFailure(_error("unavailable"));
      }
      await tester.pump();

      // Behind, not broken -- and deliberately the softer colour and wording,
      // because this one really does clear on its own.
      expect(find.text("Cloud backup is behind"), findsOneWidget);
      expect(find.byIcon(Icons.cloud_queue), findsOneWidget);
    });

    testWidgets('disappears again as soon as a backup succeeds',
        (tester) async {
      await pumpBanner(tester);

      for (var i = 0; i < 4; i++) {
        status.recordFailure(_error("permission-denied"));
      }
      await tester.pump();
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);

      status.recordSuccess();
      await tester.pump();

      expect(find.byIcon(Icons.cloud_off), findsNothing);
    });
  });
}
