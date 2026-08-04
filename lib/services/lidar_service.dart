import 'dart:io';

class LiDARService {
  LiDARService._();

  static final instance = LiDARService._();

  Future<bool> isLiDARAvailable() async {
    // Android emulator / Android phone
    if (Platform.isAndroid) {
      return false;
    }

    // iPhone implementation will come later.
    if (Platform.isIOS) {
      return false;
    }

    return false;
  }
}