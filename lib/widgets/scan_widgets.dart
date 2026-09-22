import 'package:flutter/material.dart';

import '../models/log_defect.dart';
import '../services/defect_advisor.dart';
import '../theme/app_theme.dart';

/// A bright line sweeping down over a photo while it is being scanned.
///
/// Only ever built while a scan is running, so its repeating animation can
/// never hold up a test waiting for the screen to settle.
class ScanSweep extends StatefulWidget {
  final String caption;

  const ScanSweep({super.key, required this.caption});

  @override
  State<ScanSweep> createState() => _ScanSweepState();
}

class _ScanSweepState extends State<ScanSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Colors.black.withValues(alpha: 0.25)),
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = Curves.easeInOut.transform(_controller.value);

            return LayoutBuilder(
              builder: (context, constraints) {
                final y = constraints.maxHeight * t;

                return Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: y - 60,
                      height: 60,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              const Color(0xFF7CE0B0).withValues(alpha: 0),
                              const Color(0xFF7CE0B0).withValues(alpha: 0.35),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: y - 1,
                      height: 2,
                      child: const ColoredBox(color: Color(0xFFB9F5D8)),
                    ),
                  ],
                );
              },
            );
          },
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(40),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  widget.caption,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The grade as a medallion: letter, name, and a ring in the grade's colour.
class GradeBadge extends StatelessWidget {
  final LogGrade grade;
  final double size;
  final bool showLabel;
  final bool onDark;

  const GradeBadge({
    super.key,
    required this.grade,
    this.size = 56,
    this.showLabel = true,
    this.onDark = false,
  });

  static Color colourOf(LogGrade grade) => switch (grade) {
        LogGrade.prime => const Color(0xFF2E8B57),
        LogGrade.select => const Color(0xFF4F9D69),
        LogGrade.standard => AppTheme.warning,
        LogGrade.utility => AppTheme.severityHigh,
      };

  @override
  Widget build(BuildContext context) {
    final colour = colourOf(grade);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(colour, Colors.white, 0.18)!,
                Color.lerp(colour, Colors.black, 0.18)!,
              ],
            ),
            border: Border.all(
              color: onDark ? Colors.white24 : Colors.white,
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: colour.withValues(alpha: 0.35),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            grade.letter,
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.46,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
        ),
        if (showLabel) ...[
          const SizedBox(height: 6),
          Text(
            grade.label.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
              color: onDark ? Colors.white70 : colour,
            ),
          ),
        ],
      ],
    );
  }
}

/// One suggestion, styled by how urgent it is.
class AdviceCard extends StatelessWidget {
  final DefectAdvice advice;

  const AdviceCard({super.key, required this.advice});

  static IconData iconFor(AdviceTopic topic) => switch (topic) {
        AdviceTopic.cutting => Icons.content_cut_rounded,
        AdviceTopic.storage => Icons.inventory_2_outlined,
        AdviceTopic.inspection => Icons.visibility_outlined,
        AdviceTopic.pricing => Icons.payments_outlined,
        AdviceTopic.grading => Icons.workspace_premium_outlined,
        AdviceTopic.treatment => Icons.science_outlined,
        AdviceTopic.clean => Icons.verified_outlined,
      };

  static Color colourFor(AdvicePriority priority) => switch (priority) {
        AdvicePriority.critical => AppTheme.severityHigh,
        AdvicePriority.important => AppTheme.accent,
        AdvicePriority.tip => AppTheme.primaryBright,
      };

  static String priorityLabel(AdvicePriority priority) => switch (priority) {
        AdvicePriority.critical => "Do this first",
        AdvicePriority.important => "Recommended",
        AdvicePriority.tip => "Good to know",
      };

  @override
  Widget build(BuildContext context) {
    final colour = colourFor(advice.priority);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: colour),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: colour.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child:
                          Icon(iconFor(advice.topic), color: colour, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            priorityLabel(advice.priority).toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.9,
                              color: colour,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            advice.title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            advice.body,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plain-words size of a defect, from its extent across the face.
String sizeWord(double extent) {
  if (extent < 0.08) return "Small";
  if (extent < 0.2) return "Medium";
  return "Large";
}

/// What a kind of defect means for the boards, in one line.
String kindMeaning(LogDefectKind kind) => switch (kind) {
      LogDefectKind.hollow => "Missing wood — no board can be cut through it.",
      LogDefectKind.rot => "Decayed wood — must be cut out completely.",
      LogDefectKind.crack =>
        "Splits boards it crosses — orientation decides the loss.",
      LogDefectKind.shake =>
        "A separation along the rings — boards across it fall apart.",
      LogDefectKind.knot =>
        "Boards containing it still sell, at a lower grade.",
    };
