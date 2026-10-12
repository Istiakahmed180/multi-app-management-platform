import 'package:app_management_sdk/app_management_sdk.dart';
import 'package:test/test.dart';

void main() {
  SemanticVersion v(String s) => SemanticVersion.parse(s);

  test('parses full and partial versions', () {
    final full = v('1.2.3-beta.1+45');
    expect((full.major, full.minor, full.patch), (1, 2, 3));
    expect(full.preRelease, ['beta', '1']);
    expect(full.build, '45');
    expect(v('2.1'), v('2.1.0'));
    expect(v('3'), v('3.0.0'));
    expect(v('v1.0.0'), v('1.0.0'));
    expect(v(' 1.0.0 '), v('1.0.0'));
  });

  test('rejects invalid versions', () {
    for (final s in [
      '',
      'abc',
      '1.2.3.4',
      '1.-2',
      '1.2.3-',
      '1.2.3+',
      'x1.0',
    ]) {
      expect(SemanticVersion.tryParse(s), isNull, reason: s);
      expect(() => SemanticVersion.parse(s), throwsFormatException);
    }
    expect(SemanticVersion.tryParse(null), isNull);
  });

  test('orders by major, minor, patch numerically', () {
    expect(v('1.10.0') > v('1.9.0'), isTrue);
    expect(v('2.0.0') > v('1.99.99'), isTrue);
    expect(v('1.0.10') > v('1.0.9'), isTrue);
    expect(v('1.2.3') >= v('1.2.3'), isTrue);
    expect(v('1.2.3') <= v('1.2.3'), isTrue);
  });

  test('pre-release ranks below the release', () {
    expect(v('1.0.0-alpha') < v('1.0.0'), isTrue);
    expect(v('2.1.0-rc.1') < v('2.1.0'), isTrue);
    expect(v('2.1.0-rc.1') > v('2.0.9'), isTrue);
  });

  test('follows the semver.org pre-release precedence chain', () {
    final chain = [
      '1.0.0-alpha',
      '1.0.0-alpha.1',
      '1.0.0-alpha.beta',
      '1.0.0-beta',
      '1.0.0-beta.2',
      '1.0.0-beta.11',
      '1.0.0-rc.1',
      '1.0.0',
    ].map(v).toList();
    for (var i = 0; i < chain.length - 1; i++) {
      expect(
        chain[i] < chain[i + 1],
        isTrue,
        reason: '${chain[i]} < ${chain[i + 1]}',
      );
    }
    final shuffled = [...chain.reversed]..sort();
    expect(shuffled, chain);
  });

  test('ignores build metadata for ordering and equality', () {
    expect(v('1.0.0+1'), v('1.0.0+2'));
    expect(v('1.0.0+1').hashCode, v('1.0.0+2').hashCode);
    expect(v('1.0.0+1').compareTo(v('1.0.0')), 0);
  });

  test('toString is canonical', () {
    expect(v('v1.2-rc.1+7').toString(), '1.2.0-rc.1+7');
  });
}
