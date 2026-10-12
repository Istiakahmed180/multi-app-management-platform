/// A semantic version (https://semver.org) used for app version comparisons.
///
/// Parsing is lenient about common app version formats: a leading `v` is
/// allowed, and missing minor/patch components default to `0`, so `"2.1"`
/// equals `"2.1.0"`. Build metadata (`+45`) is accepted and ignored for
/// ordering, as the spec requires.
final class SemanticVersion implements Comparable<SemanticVersion> {
  const SemanticVersion(
    this.major,
    this.minor,
    this.patch, {
    this.preRelease = const [],
    this.build,
  });

  static final RegExp _pattern = RegExp(
    r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );

  final int major;
  final int minor;
  final int patch;
  final List<String> preRelease;
  final String? build;

  bool get isPreRelease => preRelease.isNotEmpty;

  /// Parses [input], throwing a [FormatException] if it is not a version.
  static SemanticVersion parse(String input) {
    final version = tryParse(input);
    if (version == null) {
      throw FormatException('Invalid semantic version', input);
    }
    return version;
  }

  static SemanticVersion? tryParse(String? input) {
    if (input == null) return null;
    final match = _pattern.firstMatch(input.trim());
    if (match == null) return null;
    final major = int.tryParse(match[1]!);
    final minor = int.tryParse(match[2] ?? '0');
    final patch = int.tryParse(match[3] ?? '0');
    if (major == null || minor == null || patch == null) return null;
    return SemanticVersion(
      major,
      minor,
      patch,
      preRelease: List.unmodifiable(match[4]?.split('.') ?? const <String>[]),
      build: match[5],
    );
  }

  @override
  int compareTo(SemanticVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return _comparePreRelease(preRelease, other.preRelease);
  }

  static int _comparePreRelease(List<String> a, List<String> b) {
    if (a.isEmpty && b.isEmpty) return 0;
    // A release ranks above any of its pre-releases.
    if (a.isEmpty) return 1;
    if (b.isEmpty) return -1;
    for (var i = 0; i < a.length && i < b.length; i++) {
      final result = _compareIdentifier(a[i], b[i]);
      if (result != 0) return result;
    }
    return a.length.compareTo(b.length);
  }

  static final RegExp _numeric = RegExp(r'^\d+$');

  static int _compareIdentifier(String a, String b) {
    final aNumeric = _numeric.hasMatch(a);
    final bNumeric = _numeric.hasMatch(b);
    if (aNumeric && bNumeric) {
      return BigInt.parse(a).compareTo(BigInt.parse(b));
    }
    if (aNumeric) return -1;
    if (bNumeric) return 1;
    return a.compareTo(b);
  }

  bool operator <(SemanticVersion other) => compareTo(other) < 0;
  bool operator <=(SemanticVersion other) => compareTo(other) <= 0;
  bool operator >(SemanticVersion other) => compareTo(other) > 0;
  bool operator >=(SemanticVersion other) => compareTo(other) >= 0;

  /// Equality follows precedence, so build metadata is ignored.
  @override
  bool operator ==(Object other) =>
      other is SemanticVersion && compareTo(other) == 0;

  @override
  int get hashCode =>
      Object.hash(major, minor, patch, Object.hashAll(preRelease));

  @override
  String toString() {
    final buffer = StringBuffer('$major.$minor.$patch');
    if (preRelease.isNotEmpty) buffer.write('-${preRelease.join('.')}');
    if (build != null) buffer.write('+$build');
    return buffer.toString();
  }
}
