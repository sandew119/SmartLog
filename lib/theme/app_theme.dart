import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The app's visual language, in one place.
///
/// A deep forest green carries the brand; a warm timber gold is the accent
/// that marks what is new, featured or worth money. Surfaces sit on a warm
/// paper background rather than cold grey, because the thing this app is
/// about is wood -- and every component theme below is tuned so screens get
/// the same corner radii, borders and type scale without styling themselves.
class AppTheme {
  AppTheme._();

  // --- brand -----------------------------------------------------------------

  /// Deep forest green: app bars, primary buttons, the brand itself.
  static const Color primary = Color(0xFF1E4D3A);

  /// A brighter green for icons, progress and positive figures on white.
  static const Color primaryBright = Color(0xFF2F7D5B);

  /// The darkest green, for gradients and text on light green.
  static const Color primaryDeep = Color(0xFF12332A);

  /// Timber gold: featured cards, highlights, the premium accent.
  static const Color accent = Color(0xFFC0894A);

  /// Kept under its original name so anything still asking for the "wood"
  /// colour gets the accent rather than the old flat brown.
  static const Color secondary = accent;

  // --- surfaces --------------------------------------------------------------

  static const Color background = Color(0xFFF6F5F1);
  static const Color surface = Colors.white;
  static const Color surfaceMuted = Color(0xFFEFEDE7);
  static const Color line = Color(0xFFE5E2D9);

  // --- text ------------------------------------------------------------------

  static const Color textPrimary = Color(0xFF17211C);
  static const Color textSecondary = Color(0xFF5E6862);
  static const Color textTertiary = Color(0xFF8E968F);

  // --- status ----------------------------------------------------------------

  static const Color error = Color(0xFFC0392B);
  static const Color success = Color(0xFF2E8B57);
  static const Color warning = Color(0xFFE08A1E);
  static const Color info = Color(0xFF2F6FB0);

  // --- severity, shared by every screen that grades a defect -----------------

  static const Color severityHigh = Color(0xFFC0392B);
  static const Color severityMedium = Color(0xFFE07A2E);
  static const Color severityLow = Color(0xFFD9A21B);

  // --- geometry --------------------------------------------------------------

  static const double radiusSmall = 10;
  static const double radius = 16;
  static const double radiusLarge = 24;

  /// The brand gradient, for hero headers and the featured card.
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1E4D3A), Color(0xFF12332A)],
  );

  /// Timber gold to deep bronze, for anything marked premium or new.
  static const LinearGradient timberGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFD4A15F), Color(0xFF9C6431)],
  );

  /// A soft, wide shadow: enough to lift a card off the paper, never enough
  /// to look like a 2014 app.
  static List<BoxShadow> get softShadow => [
        BoxShadow(
          color: const Color(0xFF17211C).withValues(alpha: 0.06),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ];

  static const TextTheme _text = TextTheme(
    displayLarge: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.8,
      color: textPrimary,
    ),
    displaySmall: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.6,
      color: textPrimary,
    ),
    headlineMedium: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.4,
      color: textPrimary,
    ),
    headlineSmall: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      color: textPrimary,
    ),
    titleLarge: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      color: textPrimary,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
      color: textPrimary,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: textPrimary,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.4, color: textPrimary),
    // Ink, not grey: this is the default for every Text with no style of its
    // own, all over the app. Secondary text asks for its colour explicitly.
    bodyMedium: TextStyle(fontSize: 14, height: 1.4, color: textPrimary),
    bodySmall: TextStyle(fontSize: 12, height: 1.35, color: textSecondary),
    labelLarge: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.1,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      color: textSecondary,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.6,
      color: textTertiary,
    ),
  );

  static final ColorScheme _scheme = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: Brightness.light,
  ).copyWith(
    primary: primary,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFDDEBE3),
    onPrimaryContainer: primaryDeep,
    secondary: accent,
    onSecondary: Colors.white,
    secondaryContainer: const Color(0xFFF4E6D3),
    onSecondaryContainer: const Color(0xFF4A2F12),
    tertiary: primaryBright,
    error: error,
    surface: surface,
    onSurface: textPrimary,
    onSurfaceVariant: textSecondary,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFFAF9F6),
    surfaceContainer: surfaceMuted,
    surfaceContainerHigh: const Color(0xFFE9E6DE),
    surfaceContainerHighest: const Color(0xFFE2DFD6),
    outline: const Color(0xFFBFBAAD),
    outlineVariant: line,
    surfaceTint: Colors.transparent,
  );

  static final ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    colorScheme: _scheme,
    scaffoldBackgroundColor: background,
    canvasColor: background,
    textTheme: _text,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      backgroundColor: background,
      foregroundColor: textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: textPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: const BorderSide(color: line),
      ),
    ),
    // Minimum *height* only. A theme that forced every button to full width
    // would blow up any button sitting in a Row without an Expanded.
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFD9D6CE),
        disabledForegroundColor: textTertiary,
        minimumSize: const Size(64, 52),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFD9D6CE),
        disabledForegroundColor: textTertiary,
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: primary,
        minimumSize: const Size(64, 48),
        side: const BorderSide(color: Color(0xFFCFCABD)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: textPrimary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: const TextStyle(color: textSecondary),
      floatingLabelStyle: const TextStyle(
        color: primary,
        fontWeight: FontWeight.w600,
      ),
      helperStyle: const TextStyle(color: textTertiary, fontSize: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: error, width: 1.6),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.white,
      selectedColor: const Color(0xFFDDEBE3),
      side: const BorderSide(color: line),
      labelStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(40)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: const Color(0xFFDDEBE3),
        selectedForegroundColor: primaryDeep,
        side: const BorderSide(color: line),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLarge)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLarge),
      ),
      titleTextStyle: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: textPrimary,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: textPrimary,
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      actionTextColor: const Color(0xFFE8C48F),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: primaryBright,
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
      titleTextStyle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      subtitleTextStyle: TextStyle(fontSize: 13, color: textSecondary),
    ),
    dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: primaryBright,
      linearTrackColor: Color(0xFFE5E2D9),
      circularTrackColor: Colors.transparent,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : const Color(0xFF8E968F),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? primaryBright
            : const Color(0xFFE2DFD6),
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: primary,
      foregroundColor: Colors.white,
      elevation: 2,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: textPrimary,
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
