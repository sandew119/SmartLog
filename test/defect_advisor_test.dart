import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:smartlog2/models/log_defect.dart';
import 'package:smartlog2/services/defect_advisor.dart';

/// Suggestions and the SmartLog grade: what a sawmill should do about what
/// the scan found, and how clean the face is at a glance.
void main() {
  const image = Size(1000, 1000);
  const centre = Offset(500, 500);
  const radius = 400.0;

  AssessedDefect at(
    LogDefectKind kind,
    Rect region, {
    bool confirmed = true,
    bool withFace = true,
  }) =>
      AssessedDefect.locate(
        kind: kind,
        label: kind.label,
        region: region,
        confirmed: confirmed,
        imageSize: image,
        faceCentre: withFace ? centre : null,
        faceRadius: withFace ? radius : null,
      );

  group('placing a defect on the face', () {
    test('a box over the pith is at the heart', () {
      final d = at(LogDefectKind.crack, const Rect.fromLTWH(470, 300, 60, 400));
      expect(d.zone, DefectZone.heart);
    });

    test('a box out by the bark is near the bark', () {
      final d = at(LogDefectKind.knot, const Rect.fromLTWH(830, 480, 40, 40));
      expect(d.zone, DefectZone.outer);
    });

    test('without a face, position is unknown rather than guessed', () {
      final d = at(
        LogDefectKind.knot,
        const Rect.fromLTWH(830, 480, 40, 40),
        withFace: false,
      );
      expect(d.zone, DefectZone.unknown);
    });

    test('extent is length across the face, not box area', () {
      // A thin crack two-fifths of the diameter long.
      final d = at(LogDefectKind.crack, const Rect.fromLTWH(480, 340, 10, 320));
      expect(d.extent, closeTo(320 / 800, 1e-9));
    });
  });

  group('grade', () {
    test('a clean face is prime', () {
      expect(LogQualityGrader.grade(const []).grade, LogGrade.prime);
    });

    test('a couple of small knots is select', () {
      final result = LogQualityGrader.grade([
        at(LogDefectKind.knot, const Rect.fromLTWH(700, 300, 40, 40)),
        at(LogDefectKind.knot, const Rect.fromLTWH(300, 700, 40, 40)),
      ]);

      expect(result.grade, LogGrade.select);
    });

    test('a crack makes it standard', () {
      final result = LogQualityGrader.grade([
        at(LogDefectKind.crack, const Rect.fromLTWH(760, 480, 20, 80)),
      ]);

      expect(result.grade, LogGrade.standard);
    });

    test('a long crack through the face makes it utility', () {
      final result = LogQualityGrader.grade([
        at(LogDefectKind.crack, const Rect.fromLTWH(490, 150, 20, 700)),
      ]);

      expect(result.grade, LogGrade.utility);
      expect(result.reasons.join(), contains("crack"));
    });

    test('a hole at the heart is utility', () {
      final result = LogQualityGrader.grade([
        at(LogDefectKind.hollow, const Rect.fromLTWH(470, 470, 60, 60)),
      ]);

      expect(result.grade, LogGrade.utility);
    });

    test('faint marks do not drag the grade down until confirmed', () {
      final pending = [
        at(
          LogDefectKind.crack,
          const Rect.fromLTWH(490, 150, 20, 700),
          confirmed: false,
        ),
      ];

      final result = LogQualityGrader.grade(pending);

      expect(result.grade, LogGrade.prime);
      expect(result.pendingReview, 1);
      expect(result.reasons.single, contains("faint"));
    });
  });

  group('suggestions', () {
    List<String> titles(List<DefectAdvice> advice) =>
        [for (final a in advice) a.title];

    test('a clean face says so, and asks for the other end', () {
      final advice = DefectAdvisor.advise(defects: const []);

      expect(titles(advice).join(" "), contains("Clean face"));
      expect(titles(advice).join(" "), contains("other end"));
    });

    test('a heart crack says to saw along it and to seal the ends', () {
      final advice = DefectAdvisor.advise(
        defects: [
          at(LogDefectKind.crack, const Rect.fromLTWH(490, 200, 20, 600)),
        ],
        hasTracedFace: true,
      );

      expect(advice.first.priority, AdvicePriority.critical);
      expect(titles(advice), contains("Saw along the crack, not across it"));
      expect(titles(advice), contains("Seal the ends and saw soon"));
    });

    test('holes raise the borer check first', () {
      final advice = DefectAdvisor.advise(
        defects: [
          at(LogDefectKind.hollow, const Rect.fromLTWH(700, 300, 30, 30)),
        ],
      );

      expect(advice.first.title, contains("borers"));
    });

    test('many knots points the log at knot-tolerant products', () {
      final advice = DefectAdvisor.advise(
        defects: [
          for (var i = 0; i < 4; i++)
            at(
              LogDefectKind.knot,
              Rect.fromLTWH(200.0 + i * 120, 250, 30, 30),
            ),
        ],
      );

      expect(
        titles(advice),
        contains("Sell this one where knots are fine"),
      );
    });

    test('faint marks come with a request to check them', () {
      final advice = DefectAdvisor.advise(
        defects: [
          at(
            LogDefectKind.knot,
            const Rect.fromLTWH(700, 300, 30, 30),
            confirmed: false,
          ),
        ],
      );

      expect(advice.first.title, contains("by eye"));
    });

    test('a measured loss becomes a pricing suggestion with the money', () {
      final advice = DefectAdvisor.advise(
        defects: [
          at(LogDefectKind.crack, const Rect.fromLTWH(490, 200, 20, 600)),
        ],
        hasTracedFace: true,
        lostCubicFeet: 1.25,
        lostValue: 3750,
      );

      final pricing = advice.firstWhere(
        (a) => a.topic == AdviceTopic.pricing,
      );

      expect(pricing.body, contains("1.25"));
      expect(pricing.body, contains("Rs. 3,750"));
    });

    test('suggestions come most urgent first and never repeat', () {
      final advice = DefectAdvisor.advise(
        defects: [
          at(LogDefectKind.rot, const Rect.fromLTWH(450, 450, 100, 100)),
          at(LogDefectKind.crack, const Rect.fromLTWH(490, 200, 20, 600)),
          at(LogDefectKind.hollow, const Rect.fromLTWH(700, 300, 30, 30)),
          at(LogDefectKind.knot, const Rect.fromLTWH(300, 700, 30, 30)),
        ],
        hasTracedFace: true,
      );

      for (var i = 1; i < advice.length; i++) {
        expect(
          advice[i].priority.index,
          greaterThanOrEqualTo(advice[i - 1].priority.index),
        );
      }

      expect(titles(advice).toSet().length, advice.length);
      expect(advice.length, lessThanOrEqualTo(7));
    });
  });
}
