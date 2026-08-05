import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/timber_volume.dart';

/// Measurement settings the user controls from their profile. These affect
/// every volume figure the app produces, so they are deliberately kept in
/// one small, validated, testable place.
@immutable
class UserPreferences {
  /// Which formula turns diameter+length into a volume.
  final VolumeMethod volumeMethod;

  /// Trade/bark allowance subtracted from a log's measured diameter before
  /// its volume is computed. 0 means "use the measured diameter as-is".
  final double diameterDeductionInches;

  const UserPreferences({
    this.volumeMethod = VolumeMethod.standard,
    this.diameterDeductionInches = 0,
  });

  UserPreferences copyWith({
    VolumeMethod? volumeMethod,
    double? diameterDeductionInches,
  }) {
    return UserPreferences(
      volumeMethod: volumeMethod ?? this.volumeMethod,
      diameterDeductionInches:
          diameterDeductionInches ?? this.diameterDeductionInches,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      "volumeMethod": volumeMethod.name,
      "diameterDeductionInches": diameterDeductionInches,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is UserPreferences &&
        other.volumeMethod == volumeMethod &&
        other.diameterDeductionInches == diameterDeductionInches;
  }

  @override
  int get hashCode => Object.hash(volumeMethod, diameterDeductionInches);
}

/// Called after a preference change so the app can mirror it to the cloud.
/// Kept as an injected callback rather than a direct dependency so this
/// service imports no Firebase and stays trivially unit-testable.
typedef PreferencesSyncCallback = Future<void> Function(UserPreferences prefs);

class UserPreferencesService {
  UserPreferencesService._();

  static final UserPreferencesService instance = UserPreferencesService._();

  static const _volumeMethodKey = "volume_method";
  static const _deductionKey = "diameter_deduction_inches";

  /// A deduction larger than this is almost certainly a typo (a foot of bark
  /// allowance is already extreme), so values are clamped rather than
  /// trusted -- a runaway deduction would silently undervalue every log.
  static const double maxDeductionInches = 12;

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

    // Unknown/corrupt/legacy value -- fall back to the safe default rather
    // than throwing and locking the user out of their own settings.
    return VolumeMethod.standard;
  }

  Future<UserPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();

    final loaded = UserPreferences(
      volumeMethod: _parseMethod(prefs.getString(_volumeMethodKey)),
      diameterDeductionInches:
          sanitizeDeduction(prefs.getDouble(_deductionKey)),
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

  Future<void> setDiameterDeductionInches(double inches) async {
    final sanitized = sanitizeDeduction(inches);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_deductionKey, sanitized);

    _notifier.value = current.copyWith(diameterDeductionInches: sanitized);
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
