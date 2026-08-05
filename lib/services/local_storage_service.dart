import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class LocalStorageService {
  LocalStorageService._();

  static const _rememberMeKey = "remember_me";
  static const _guestModeKey = "guest_mode";
  static const _userEmailKey = "user_email";
  static const _deviceIdKey = "device_sync_id";

  static Future<void> setRememberMe(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rememberMeKey, value);
  }

  static Future<bool> getRememberMe() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rememberMeKey) ?? true;
  }

  static Future<void> saveUserEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userEmailKey, email);
  }

  static Future<String> getUserEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_userEmailKey) ?? "";
  }

  static Future<void> setGuestMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_guestModeKey, value);
  }

  static Future<bool> getGuestMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_guestModeKey) ?? true;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_rememberMeKey);
    await prefs.remove(_guestModeKey);
    await prefs.remove(_userEmailKey);
  }

  /// A random id generated once per install and cached forever, used to
  /// namespace cloud-synced document ids so a reinstalled app (whose local
  /// row ids restart from 1) never collides with a previous install's data.
  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();

    final existing = prefs.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final generated =
        "${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 32)}";

    await prefs.setString(_deviceIdKey, generated);
    return generated;
  }
}
