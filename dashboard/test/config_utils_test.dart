import 'package:amp_dashboard/core/models/models.dart';
import 'package:amp_dashboard/modules/config/config_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses hex colors into ARGB values', () {
    expect(parseHexColor('#2563EB'), 0xFF2563EB);
    expect(parseHexColor('#2563EB80'), 0x802563EB);
    expect(parseHexColor('blue'), isNull);
    expect(parseHexColor('#12345'), isNull);
  });

  test('validators match the backend rules', () {
    expect(validateHex('#ffffff'), isNull);
    expect(validateHex('ffffff'), isNotNull);
    expect(validateOptionalSemver(''), isNull);
    expect(validateOptionalSemver('1.2.3-beta.1'), isNull);
    expect(validateOptionalSemver('1.2'), isNotNull);
    expect(validateOptionalHttps('http://x.com'), isNotNull);
    expect(validateOptionalHttps('https://x.com'), isNull);
    expect(configKeyPattern.hasMatch('home.welcome'), isTrue);
    expect(configKeyPattern.hasMatch('Home'), isFalse);
  });

  test('reads and writes nested paths including list indices', () {
    final c = <String, dynamic>{
      'theme': {
        'light': {'primary': '#000000'},
      },
      'banners': [
        {'id': 'a'},
      ],
    };
    expect(getPath(c, 'theme.light.primary'), '#000000');
    expect(getPath(c, 'banners.0.id'), 'a');
    expect(getPath(c, 'banners.5.id'), isNull);
    setPath(c, 'theme.light.primary', '#FFFFFF');
    setPath(c, 'banners.0.id', 'b');
    expect(getPath(c, 'theme.light.primary'), '#FFFFFF');
    expect(getPath(c, 'banners.0.id'), 'b');
  });

  test('deepCopy is independent of the source', () {
    final source = <String, dynamic>{
      'a': {'b': 1},
    };
    final copy = deepCopy(source);
    setPath(copy, 'a.b', 2);
    expect(getPath(source, 'a.b'), 1);
  });

  test('diffs configuration versions by path', () {
    final before = <String, dynamic>{
      'branding': {'appTitle': 'Old', 'logoUrl': null},
      'banners': <dynamic>[],
    };
    final after = <String, dynamic>{
      'branding': {'appTitle': 'New', 'logoUrl': null},
      'banners': [
        {'id': 'x'},
      ],
    };
    final changes = diffConfigs(before, after);
    expect(changes.map((c) => c.path), containsAll(['branding.appTitle', 'banners.0.id', 'banners']));
    expect(changes.firstWhere((c) => c.path == 'branding.appTitle').after, 'New');
  });

  test('parses API models defensively', () {
    final app = AppInfo.fromJson({
      'id': '1',
      'orgId': 'o',
      'name': 'Shop',
      'slug': 'shop',
      'appKey': 'app_x',
      'platforms': ['ios'],
      'environment': 'production',
      'status': 'active',
      'access': {
        'permissions': ['apps:read'],
      },
    });
    expect(app.permissions, {'apps:read'});
    expect(app.publishedConfigVersion, isNull);
    expect(app.summary, isEmpty);
  });
}
