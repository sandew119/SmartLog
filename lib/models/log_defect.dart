import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// What is wrong with a patch of the log face.
///
/// The kinds are separated because they do not all cost the same. A knot is
/// a local blemish a buyer may accept at a discount; rot and hollow are
/// wood that is simply not there. [LogDefectKind.severity] is what the
/// packing engine consults, so adding a kind later does not mean touching
/// the engine.
enum LogDefectKind {
  knot,
  rot,
  crack,
  shake,
  hollow,
}

extension LogDefectKindInfo on LogDefectKind {
  String get label => switch (this) {
        LogDefectKind.knot => "Knot",
        LogDefectKind.rot => "Rot",
        LogDefectKind.crack => "Crack",
        LogDefectKind.shake => "Shake",
        LogDefectKind.hollow => "Hollow",
      };

  /// How ruinous this is to a board that contains it, 0..1.
  ///
  /// Rot and hollow are missing wood -- no board can cross them. A knot or a
  /// surface crack still yields a sellable, lower-grade board, so at some
  /// point these should downgrade a board's value rather than delete it.
  /// Until grading exists the engine treats anything at or above
  /// [rejectionThreshold] as a hole.
  double get severity => switch (this) {
        LogDefectKind.hollow => 1.0,
        LogDefectKind.rot => 1.0,
        LogDefectKind.shake => 0.8,
        LogDefectKind.crack => 0.7,
        LogDefectKind.knot => 0.5,
      };
}

/// A circular flaw on the log's cut face.
///
/// Circles rather than outlines on purpose: a defect's extent is fuzzy, a
/// user marking one on a phone can place a circle in one drag, and the
/// overlap test against a rectangular board stays exact and cheap. When a
/// real detection model arrives it can report a bounding circle just as
/// easily as a mask.
///
/// [centre] and [radius] are in the same coordinate space as the
/// [LogFaceOutline] they belong to -- pixels when freshly marked on a photo,
/// inches once scaled.
class LogDefect {
  final LogDefectKind kind;
  final Offset centre;
  final double radius;

  /// 1.0 for something the user marked by hand; a model's own score when
  /// detection is automatic.
  final double confidence;

  /// Whether a person or a model put this here. Kept because the two should
  /// never be silently mixed on screen -- a user must be able to tell what
  /// the app guessed from what they told it.
  final bool automatic;

  const LogDefect({
    required this.kind,
    required this.centre,
    required this.radius,
    this.confidence = 1.0,
    this.automatic = false,
  });

  /// At or above this severity, a board touching the defect is discarded
  /// rather than merely downgraded.
  static const double rejectionThreshold = 0.7;

  bool get isDisqualifying => kind.severity >= rejectionThreshold;

  /// Exact circle/rectangle intersection: clamp the centre into the
  /// rectangle to find the nearest point on it, then compare distances.
  bool overlaps(Rect rect) {
    final nearestX = centre.dx.clamp(rect.left, rect.right);
    final nearestY = centre.dy.clamp(rect.top, rect.bottom);

    final dx = centre.dx - nearestX;
    final dy = centre.dy - nearestY;

    return dx * dx + dy * dy < radius * radius;
  }

  double get area => math.pi * radius * radius;

  LogDefect scaled(double factor) => copyWith(
        centre: centre * factor,
        radius: radius * factor,
      );

  LogDefect translated(Offset delta) => copyWith(centre: centre + delta);

  LogDefect copyWith({
    LogDefectKind? kind,
    Offset? centre,
    double? radius,
    double? confidence,
    bool? automatic,
  }) {
    return LogDefect(
      kind: kind ?? this.kind,
      centre: centre ?? this.centre,
      radius: radius ?? this.radius,
      confidence: confidence ?? this.confidence,
      automatic: automatic ?? this.automatic,
    );
  }

  Map<String, dynamic> toMap() => {
        "kind": kind.name,
        "x": centre.dx,
        "y": centre.dy,
        "radius": radius,
        "confidence": confidence,
        "automatic": automatic,
      };

  factory LogDefect.fromMap(Map<String, dynamic> map) {
    return LogDefect(
      kind: LogDefectKind.values.firstWhere(
        (k) => k.name == map["kind"],
        // An unknown kind from a newer version must not crash an older one.
        orElse: () => LogDefectKind.knot,
      ),
      centre: Offset(
        (map["x"] as num).toDouble(),
        (map["y"] as num).toDouble(),
      ),
      radius: (map["radius"] as num).toDouble(),
      confidence: (map["confidence"] as num?)?.toDouble() ?? 1.0,
      automatic: map["automatic"] as bool? ?? false,
    );
  }
}
