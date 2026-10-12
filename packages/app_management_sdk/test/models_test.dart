import 'dart:convert';

import 'package:app_management_sdk/app_management_sdk.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('RemoteConfigSnapshot.fromJson', () {
    test('parses a full payload', () {
      final s = RemoteConfigSnapshot.fromJson(fullPayload());

      expect(s.schemaVersion, 1);
      expect(s.appKey, testAppKey);
      expect(s.configVersion, 3);
      expect(s.publishedAt, DateTime.utc(2026, 10, 12, 10));
      expect(s.publishedAt.isUtc, isTrue);

      final c = s.config;
      expect(c.branding.appTitle, 'Shop');
      expect(c.branding.logoUrl, 'https://cdn.example.com/l.png');
      expect(c.theme.defaultMode, ConfigThemeMode.dark);
      expect(c.theme.darkModeEnabled, isTrue);
      expect(c.theme.light.primary.colorValue, 0xFF2563EB);
      expect(c.theme.light.error.colorValue, 0xFFDC2626);
      expect(c.theme.dark.primary.colorValue, 0x8060A5FA);
      expect(c.theme.dark.surface.colorValue, 0xFF111827);
      expect(c.maintenance.enabled, isFalse);
      expect(c.maintenance.title, 'Down');
      expect(c.maintenance.estimatedEndAt, DateTime.utc(2026, 10, 12, 12));
      expect(c.updatePolicy.android.minimumVersion, '1.2.0');
      expect(c.updatePolicy.android.latestVersion, '1.4.0');
      expect(c.updatePolicy.ios.updateUrl, isNull);
      expect(c.updatePolicy.message, 'Please update');
      expect(c.banners.single.id, 'sale');
      expect(c.banners.single.priority, 1);
      expect(c.onboarding.enabled, isTrue);
      expect(c.onboarding.pages.single.title, 'Welcome');
      expect(c.strings, {'home.welcome': 'Hi'});

      final flag = s.features['new_checkout']!;
      expect(flag.key, 'new_checkout');
      expect(flag.enabled, isTrue);
      expect(flag.rolloutPercentage, 100);
      expect(flag.platforms, ['android']);
      expect(flag.minAppVersion, '2.1.0');
    });

    test('applies safe defaults to a minimal payload', () {
      final s = RemoteConfigSnapshot.fromJson(minimalPayload());
      final c = s.config;

      expect(c.branding.appTitle, '');
      expect(c.branding.logoUrl, isNull);
      expect(c.theme.defaultMode, ConfigThemeMode.system);
      expect(c.theme.darkModeEnabled, isTrue);
      expect(c.theme.light.primary, ColorPalette.defaultLight.primary);
      expect(c.theme.dark.background, ColorPalette.defaultDark.background);
      expect(c.maintenance.enabled, isFalse);
      expect(c.maintenance.estimatedEndAt, isNull);
      expect(c.updatePolicy.android.minimumVersion, isNull);
      expect(c.updatePolicy.message, '');
      expect(c.banners, isEmpty);
      expect(c.onboarding.enabled, isFalse);
      expect(c.onboarding.pages, isEmpty);
      expect(c.strings, isEmpty);
      expect(s.features, isEmpty);
    });

    test('fills missing palette colors and flag fields with defaults', () {
      final payload = minimalPayload();
      (payload['config']! as Map<String, Object?>)['theme'] = {
        'darkModeEnabled': false,
        'light': {'primary': '#000000'},
      };
      payload['features'] = {
        'bare': <String, Object?>{},
        'on': {'enabled': true},
      };
      final s = RemoteConfigSnapshot.fromJson(payload);

      expect(s.config.theme.light.primary.colorValue, 0xFF000000);
      expect(
        s.config.theme.light.secondary,
        ColorPalette.defaultLight.secondary,
      );
      expect(s.config.theme.effectiveMode, ConfigThemeMode.light);
      expect(s.features['bare']!.enabled, isFalse);
      expect(s.features['on']!.rolloutPercentage, 100);
      expect(s.features['on']!.platforms, isEmpty);
    });

    test('ignores unknown fields at every level', () {
      final payload = fullPayload();
      payload['futureTopLevel'] = {'x': 1};
      final config = payload['config']! as Map<String, Object?>;
      config['newSection'] = [1, 2, 3];
      (config['branding']! as Map<String, Object?>)['tagline'] = 'new';
      ((config['banners']! as List<Object?>).first!
              as Map<String, Object?>)['variant'] =
          'hero';
      ((payload['features']! as Map<String, Object?>)['new_checkout']!
          as Map<String, Object?>)['segments'] = [
        'beta',
      ];

      final s = RemoteConfigSnapshot.fromJson(payload);
      expect(s.config.branding.appTitle, 'Shop');
      expect(s.config.banners.single.id, 'sale');
      expect(s.features['new_checkout']!.enabled, isTrue);
    });

    test('treats unknown theme modes as system', () {
      final payload = minimalPayload();
      (payload['config']! as Map<String, Object?>)['theme'] = {
        'defaultMode': 'sepia',
      };
      expect(
        RemoteConfigSnapshot.fromJson(payload).config.theme.defaultMode,
        ConfigThemeMode.system,
      );
    });

    final malformed = <String, void Function(Map<String, Object?>)>{
      'root is not an object': (_) {},
      'missing appKey': (p) => p.remove('appKey'),
      'missing configVersion': (p) => p.remove('configVersion'),
      'non-integer configVersion': (p) => p['configVersion'] = 'three',
      'invalid publishedAt': (p) => p['publishedAt'] = 'yesterday',
      'missing config': (p) => p.remove('config'),
      'config is a list': (p) => p['config'] = <Object?>[],
      'banners is not a list': (p) => _config(p)['banners'] = {'id': 'x'},
      'banner without id': (p) => _config(p)['banners'] = [
        {'title': 'x'},
      ],
      'non-string string value': (p) => _config(p)['strings'] = {'a': 1},
      'feature is not an object': (p) => p['features'] = {'f': true},
      'wrong type for boolean': (p) =>
          _config(p)['maintenance'] = {'enabled': 'yes'},
    };
    for (final MapEntry(key: name, value: mutate) in malformed.entries) {
      test('throws FormatException for $name', () {
        final payload = fullPayload();
        mutate(payload);
        final input = name == 'root is not an object' ? <Object?>[] : payload;
        expect(
          () => RemoteConfigSnapshot.fromJson(input),
          throwsFormatException,
        );
      });
    }

    for (final color in ['blue', '#12345', '#1234567', '#GGGGGG', '2563EB']) {
      test('throws FormatException for invalid color "$color"', () {
        final payload = fullPayload();
        final theme = _config(payload)['theme']! as Map<String, Object?>;
        (theme['light']! as Map<String, Object?>)['primary'] = color;
        expect(
          () => RemoteConfigSnapshot.fromJson(payload),
          throwsFormatException,
        );
      });
    }

    test('toJson round-trips', () {
      final original = RemoteConfigSnapshot.fromJson(fullPayload());
      final encoded = jsonEncode(original.toJson());
      final restored = RemoteConfigSnapshot.fromJsonString(encoded);

      expect(jsonEncode(restored.toJson()), encoded);
      expect(restored.config.theme.dark.primary.colorValue, 0x8060A5FA);
      expect(restored.features['new_checkout']!.minAppVersion, '2.1.0');
    });

    test('collections are unmodifiable', () {
      final s = RemoteConfigSnapshot.fromJson(fullPayload());
      expect(() => s.config.banners.clear(), throwsUnsupportedError);
      expect(() => s.features.clear(), throwsUnsupportedError);
      expect(() => s.config.strings['x'] = 'y', throwsUnsupportedError);
    });
  });

  group('ConfigColor', () {
    test('parses #RRGGBB as opaque ARGB', () {
      expect(ConfigColor.parse('#2563EB').colorValue, 0xFF2563EB);
      expect(ConfigColor.parse('#2563eb').colorValue, 0xFF2563EB);
    });

    test('parses #RRGGBBAA moving alpha to the high byte', () {
      final c = ConfigColor.parse('#11223344');
      expect(c.colorValue, 0x44112233);
      expect((c.alpha, c.red, c.green, c.blue), (0x44, 0x11, 0x22, 0x33));
    });

    test('formats back to hex', () {
      expect(ConfigColor.parse('#2563eb').toHex(), '#2563EB');
      expect(ConfigColor.parse('#11223344').toHex(), '#11223344');
    });
  });

  group('StoredConfig', () {
    test('encodes and decodes', () {
      final stored = StoredConfig(
        rawJson: '{"a":1}',
        etag: '"v1"',
        fetchedAt: DateTime.utc(2026),
      );
      final decoded = StoredConfig.tryDecode(stored.encode())!;
      expect(decoded.rawJson, '{"a":1}');
      expect(decoded.etag, '"v1"');
      expect(decoded.fetchedAt, DateTime.utc(2026));
    });

    test('tryDecode returns null for corrupt input', () {
      for (final input in [null, '', 'not json', '[]', '{"rawJson":1}']) {
        expect(StoredConfig.tryDecode(input), isNull, reason: '$input');
      }
    });
  });
}

Map<String, Object?> _config(Map<String, Object?> payload) =>
    payload['config']! as Map<String, Object?>;
