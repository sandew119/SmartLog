import 'dart:math';

class Calculator {
  static double calculateVolume({
    required double diameter,
    required double lengthFeet,
  }) {
    double radius = diameter / 2;

    double lengthInches = lengthFeet * 12;

    double cubicInches =
        pi * radius * radius * lengthInches;

    return cubicInches / 1728;
  }
}