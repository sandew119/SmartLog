import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/timber_volume.dart';

/// Measurement settings the user controls from their profile. These affect
/// every volume figure the app produces, so they are deliberately kept in
/// one small, validated, testable place.
@immutable
class UserPreferences {
  /// Which formula turns girth+length into a volume.
  final VolumeMethod volumeMethod;

  /// Trade/bark allowance subtracted from a log's measured girth before its
  /// volume is computed. 0 means "use the tape reading as-is".
  final double girthDeductionInches;

  /// Whether the cutting optimiser routes boards around marked defects.
  ///
  /// Off by default: with it on, a log with a rotten centre reports fewer
  /// boards, and a user who has not yet marked any defects would just see a
  /// setting that appears to do nothing. Turning it on is a deliberate act.
  final bool avoidDefects;

  /// Defaults to the Sri Lankan ready-reckoner: it is what the trade this
  /// app serves actually uses, so it is the setting a new user should get
  /// without having to go and find it.
  const UserPreferences({
    this.volumeMethod = VolumeMethod.referenceTable,
    this.girthDeductionInches = 0,
    this.avoidDefects = false,
  });

  UserPreferences copyWith({
    VolumeMethod? volumeMethod,
    double? girthDeductionInches,
    bool? avoidDefects,
  }) {
    return UserPreferences(
      volumeMethod: volumeMethod ?? this.volumeMethod,
      girthDeductionInches:
          girthDeductionInches ?? this.girthDeductionInches,
      avoidDefects: avoidDefects ?? this.avoidDefects,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      "volumeMethod": volumeMethod.name,
      "girthDeductionInches": girthDeductionInches,
      "avoidDefects": avoidDefects,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is UserPreferences &&
        other.volumeMethod == volumeMethod &&
        other.girthDeductionInches == girthDeductionInches &&
        other.avoidDefects == avoidDefects;
  }

  @override
  int get hashCode =>
      Object.hash(volumeMethod, girthDeductionInches, avoidDefects);
}

/// Called after a preference change so the app can mirror it to the cloud.
/// Kept as an injected callback rather than a direct dependency so this
/// service imports no Firebase and stays trivially unit-testable.
typedef PreferencesSyncCallback = Future<void> Function(UserPreferences prefs);

class UserPreferencesService {
  UserPreferencesService._();

  static final UserPreferencesService instance = UserPreferencesService._();

  static const _volumeMethodKey = "volume_method";
  static const _girthDeductionKey = "girth_deduction_inches";
  static const _avoidDefectsKey = "avoid_defects";

  /// Pre-girth key, holding an allowance measured on the *diameter*. Read
  /// once at load and converted; see [_migrateLegacyDeduction].
  static const _legacyDiameterDeductionKey = "diameter_deduction_inches";

  /// A deduction larger than this is almost certainly a typo (three feet of
  /// tape is already absurd), so values are clamped rather than trusted -- a
  /// runaway deduction would silently undervalue every log.
  static const double maxDeductionInches = 36;

  final ValueNotifier<UserPreferences> _notifier =
      ValueNotifier<UserPreferences>(const UserPreferences());

  /// Screens can listen so a settings change is reflected without a reload.
  ValueListenable<UserPreferences> get listenable => _notifier;

  UserPreferences get current => _notifier.value;

  /// Installed once at app startup to mirror changes to Firestore. Left null
  /// in tests.
  PreferencesSyncCallback? syncCallback;

  /// Clamps a deduction into a sane range, mapping NaN/Infinity/negative
  /// values to 0 so corrupt stored data can never poison a volume figure.
  static double sanitizeDeduction(double? value) {
    if (value == null || value.isNaN || value.isInfinite || value <= 0) {
      return 0;
    }

    return value > maxDeductionInches ? maxDeductionInches : value;
  }

  static VolumeMethod _parseMethod(String? stored) {
    for (final method in VolumeMethod.values) {
      if (method.name == stored) return method;
    }

    // Unknown/corrupt/legacy value -- fall back to the default rather than
    // throwing and locking the user out of their own settings.
    return const UserPreferences().volumeMethod;
  }

  /// Converts a pre-girth deduction so an existing user's volumes do not
  /// shift under them when they update the app.
  ///
  /// The old setting was subtracted from the diameter; the new one is
  /// subtracted from the tape reading. Taking pi inches off the girth is the
  /// same cut as taking 1 inch off the diameter, so the stored number is
  /// scaled rather than reused -- carrying it across unchanged would quietly
  /// shrink every allowance to a third of what the user set.
  ///
  /// Runs once: the converted value is written under the new key and the old
  /// key is cleared.
  Future<double> _migrateLegacyDeduction(SharedPreferences prefs) async {
    final legacy = prefs.getDouble(_legacyDiameterDeductionKey);
    await prefs.remove(_legacyDiameterDeductionKey);

    if (legacy == null) return 0;

    final converted = sanitizeDeduction(
      TimberVolumeCalculator.girthInchesFromDiameter(legacy),
    );

    await prefs.setDouble(_girthDeductionKey, converted);
    return converted;
  }

  Future<UserPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();

    final stored = prefs.getDouble(_girthDeductionKey);
    final deduction = stored != null
        ? sanitizeDeduction(stored)
        : await _migrateLegacyDeduction(prefs);

    final loaded = UserPreferences(
      volumeMethod: _parseMethod(prefs.getString(_volumeMethodKey)),
      girthDeductionInches: deduction,
      avoidDefects: prefs.getBool(_avoidDefectsKey) ?? false,
    );

    _notifier.value = loaded;
    return loaded;
  }

  Future<void> setVolumeMethod(VolumeMethod method) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_volumeMethodKey, method.name);

    _notifier.value = current.copyWith(volumeMethod: method);
    await _mirror();
  }

  Future<void> setGirthDeductionInches(double inches) async {
    final sanitized = sanitizeDeduction(inches);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_girthDeductionKey, sanitized);

    _notifier.value = current.copyWith(girthDeductionInches: sanitized);
    await _mirror();
  }

  Future<void> setAvoidDefects(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_avoidDefectsKey, value);

    _notifier.value = current.copyWith(avoidDefects: value);
    await _mirror();
  }

  Future<void> _mirror() async {
    final callback = syncCallback;
    if (callback == null) return;

    try {
      await callback(current);
    } catch (_) {
      // Cloud mirroring is best-effort; never let it break a local save.
    }
  }

  /// Test-only: restores in-memory state to defaults between tests.
  @visibleForTesting
  void resetForTesting() {
    _notifier.value = const UserPreferences();
    syncCallback = null;
  }
}
