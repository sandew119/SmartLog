/// The password rule the system is specified against.
///
/// A pure function with no widget or Firebase dependency, so the rule itself
/// can be tested exhaustively rather than only through a form. Firebase
/// enforces a minimum of six characters and nothing else, so every
/// requirement below has to be checked here or it is not checked at all.
class PasswordPolicy {
  static const int minLength = 8;

  /// Returns null when [password] is acceptable, or the first thing wrong
  /// with it.
  ///
  /// One message at a time, and the length check first: listing every fault
  /// at once reads as a scolding, and the user only fixes one per attempt
  /// anyway.
  static String? validate(String? password) {
    final value = password ?? "";

    if (value.isEmpty) return "Enter a password";

    if (value.length < minLength) {
      return "Use at least $minLength characters";
    }

    if (!value.contains(RegExp(r'[A-Z]'))) {
      return "Add a capital letter";
    }

    if (!value.contains(RegExp(r'[a-z]'))) {
      return "Add a small letter";
    }

    if (!value.contains(RegExp(r'[0-9]'))) {
      return "Add a number";
    }

    // Anything that is not a letter, a digit or a space. Defining it by
    // exclusion rather than listing symbols means a password using a
    // character nobody thought to allow is not rejected for no reason.
    if (!value.contains(RegExp(r'[^A-Za-z0-9\s]'))) {
      return "Add a symbol, like ! or @";
    }

    return null;
  }

  /// True when every rule is satisfied.
  static bool isStrong(String? password) => validate(password) == null;

  /// How far along the requirements a password is, 0..1 -- for a strength
  /// bar that fills as the user types rather than only scolding on submit.
  static double strength(String password) {
    if (password.isEmpty) return 0;

    var met = 0;

    if (password.length >= minLength) met++;
    if (password.contains(RegExp(r'[A-Z]'))) met++;
    if (password.contains(RegExp(r'[a-z]'))) met++;
    if (password.contains(RegExp(r'[0-9]'))) met++;
    if (password.contains(RegExp(r'[^A-Za-z0-9\s]'))) met++;

    return met / 5;
  }
}
