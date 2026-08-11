/// Formats measurements the way the people using them read them.
///
/// The app calculates in decimal feet and decimal inches because that is what
/// the trade's volume tables are built on, and that is right for the
/// arithmetic. It is wrong for the screen. "0.66 ft" is not a length anybody
/// checks against a tape, and on a short piece it reads as a rounding error
/// rather than a measurement.
///
/// So every figure is shown twice: in the trade's own units, and in metric.
/// One of the two is always the one the reader can sanity-check, and being
/// able to sanity-check the number is most of what makes a measurement
/// trustworthy.
class UnitDisplay {
  const UnitDisplay._();

  static const double inchesPerFoot = 12;
  static const double centimetresPerInch = 2.54;
  static const double metresPerFoot = 0.3048;

  /// Cubic inches to the cubic foot: 12 x 12 x 12.
  ///
  /// Not to be confused with angal, which is a *twelfth* of a cubic foot.
  /// The two differ by a factor of 144 and both get called "inches" in
  /// conversation, so they are never formatted with the same word here.
  static const double cubicInchesPerCubicFoot = 1728;

  static const double litresPerCubicFoot = 28.316846592;

  /// A length as a tape reads it: `4 ft 3 in`.
  ///
  /// Inches are rounded, and a rounded 12 carries into the next foot rather
  /// than printing the impossible `3 ft 12 in`.
  static String feetAndInches(double feet) {
    if (!feet.isFinite || feet < 0) return "—";

    var wholeFeet = feet.floor();
    var inches = ((feet - wholeFeet) * inchesPerFoot).round();

    if (inches >= inchesPerFoot) {
      wholeFeet += 1;
      inches = 0;
    }

    if (wholeFeet == 0) return "$inches in";

    return "$wholeFeet ft $inches in";
  }

  /// A length in both systems: `4 ft 3 in  ·  1.30 m`.
  static String length(double feet) {
    if (!feet.isFinite || feet < 0) return "—";

    final metres = feet * metresPerFoot;

    // Centimetres below a metre: "0.20 m" invites a misread as 20 cm's
    // decimal cousin, and a short piece is exactly where that matters.
    final metric = metres < 1
        ? "${(metres * 100).toStringAsFixed(1)} cm"
        : "${metres.toStringAsFixed(2)} m";

    return "${feetAndInches(feet)}  ·  $metric";
  }

  /// A girth or diameter in both systems: `26.5 in  ·  67.3 cm`.
  static String across(double inches) {
    if (!inches.isFinite || inches < 0) return "—";

    return "${inches.toStringAsFixed(1)} in  ·  "
        "${(inches * centimetresPerInch).toStringAsFixed(1)} cm";
  }

  /// A volume in both systems, at a grain that suits its size.
  ///
  /// A log is quoted in cubic feet. A 20 cm sample is 0.002 ft3, which reads
  /// as zero and tells the user nothing -- so below a tenth of a cubic foot
  /// the figure switches to cubic inches, and metric follows it from litres
  /// down to millilitres.
  static String volume(double cubicFeet) {
    if (!cubicFeet.isFinite || cubicFeet < 0) return "—";

    final litres = cubicFeet * litresPerCubicFoot;

    if (cubicFeet >= 0.1) {
      final metric = litres >= 1000
          ? "${(litres / 1000).toStringAsFixed(3)} m³"
          : "${litres.toStringAsFixed(1)} L";

      return "${cubicFeet.toStringAsFixed(3)} ft³  ·  $metric";
    }

    final cubicInches = cubicFeet * cubicInchesPerCubicFoot;

    final metric = litres >= 1
        ? "${litres.toStringAsFixed(2)} L"
        : "${(litres * 1000).round()} ml";

    return "${cubicInches.toStringAsFixed(1)} in³  ·  $metric";
  }

  /// The trade's own reading, spelled out so it cannot be mistaken for
  /// cubic inches.
  ///
  /// An angal is a twelfth of a cubic foot -- 144 cubic inches. Printing it
  /// as "in" next to a genuine cubic-inch figure is how a reading ends up
  /// wrong by two orders of magnitude, so the word is never abbreviated.
  static String adiAngal(int adi, int angal) => "$adi adi · $angal angal";

  /// A tolerance as a plus-or-minus band in both systems.
  static String tolerance(double inches) {
    if (!inches.isFinite || inches <= 0) return "";

    return "±${inches.toStringAsFixed(2)} in "
        "(±${(inches * centimetresPerInch).toStringAsFixed(1)} cm)";
  }
}
