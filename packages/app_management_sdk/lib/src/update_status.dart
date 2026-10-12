import 'semver.dart';

enum UpdateLevel {
  upToDate,

  /// A newer version exists; the user may dismiss the prompt.
  recommended,

  /// The running version is below the minimum supported version. The host
  /// app is expected to block usage until the user updates.
  required,
}

/// The update state of the running app against the current platform's policy.
///
/// This is advisory data. The server cannot install or block anything: the
/// host app must enforce [UpdateLevel.required] in its own UI.
final class UpdateStatus {
  const UpdateStatus({
    required this.level,
    required this.currentVersion,
    this.minimumVersion,
    this.latestVersion,
    this.updateUrl,
    this.message = '',
  });

  final UpdateLevel level;
  final SemanticVersion currentVersion;
  final SemanticVersion? minimumVersion;
  final SemanticVersion? latestVersion;

  /// Store listing to open, e.g. a Play Store or App Store URL.
  final String? updateUrl;
  final String message;

  bool get isRequired => level == UpdateLevel.required;
  bool get isRecommended => level == UpdateLevel.recommended;
  bool get isUpToDate => level == UpdateLevel.upToDate;
}
