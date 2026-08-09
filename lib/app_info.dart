/// The version shown to the user.
///
/// A plain constant rather than a `package_info_plus` lookup: the only place
/// it appears is a footer line, and reading it properly would mean a plugin,
/// a platform channel and an async load for one string. Keep it in step with
/// `version:` in pubspec.yaml when releasing.
const String appVersion = "1.0.0";
