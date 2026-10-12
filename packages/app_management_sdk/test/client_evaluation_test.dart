import 'package:app_management_sdk/app_management_sdk.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

Future<AppManagementClient> loaded(
  Map<String, Object?> payload, {
  AppPlatform platform = AppPlatform.android,
  String appVersion = '2.1.0',
  String installationId = 'install-1',
  DateTime Function()? now,
}) async {
  final client = buildClient(
    FakeAdapter([respond(200, json: payload)]),
    platform: platform,
    appVersion: appVersion,
    installationId: installationId,
    now: now,
  );
  addTearDown(client.dispose);
  await client.initialize();
  return client;
}

Map<String, Object?> flag({
  int rollout = 100,
  List<String> platforms = const [],
  String? minAppVersion,
  bool enabled = true,
}) => {
  'enabled': enabled,
  'rolloutPercentage': rollout,
  'platforms': platforms,
  'minAppVersion': minAppVersion,
};

void main() {
  group('fnv1a32', () {
    test('matches reference vectors', () {
      expect(fnv1a32(''), 0x811c9dc5);
      expect(fnv1a32('a'), 0xe40c292c);
      expect(fnv1a32('foobar'), 0xbf9cf968);
      expect(fnv1a32('ü'), 0x119dd44a);
      expect(fnv1a32('new_checkout:install-1'), 0xb5c0cefd);
    });
  });

  group('isFeatureEnabled', () {
    test('is false without a snapshot or for missing flags', () async {
      final client = buildClient(FakeAdapter([respond(500)]));
      addTearDown(client.dispose);
      expect(client.isFeatureEnabled('new_checkout'), isFalse);
      await client.initialize();
      expect(client.isFeatureEnabled('new_checkout'), isFalse);

      final withFlags = await loaded(fullPayload());
      expect(withFlags.isFeatureEnabled('does_not_exist'), isFalse);
    });

    test('is false when the flag is explicitly disabled', () async {
      final client = await loaded(
        fullPayload(features: {'f': flag(enabled: false)}),
      );
      expect(client.isFeatureEnabled('f'), isFalse);
    });

    test('respects platform targeting', () async {
      final features = {
        'android_only': flag(platforms: ['android']),
        'ios_only': flag(platforms: ['ios']),
        'both': flag(platforms: ['android', 'ios']),
        'all': flag(),
      };
      final android = await loaded(fullPayload(features: features));
      final ios = await loaded(
        fullPayload(features: features),
        platform: AppPlatform.ios,
      );

      expect(android.isFeatureEnabled('android_only'), isTrue);
      expect(android.isFeatureEnabled('ios_only'), isFalse);
      expect(ios.isFeatureEnabled('android_only'), isFalse);
      expect(ios.isFeatureEnabled('ios_only'), isTrue);
      for (final c in [android, ios]) {
        expect(c.isFeatureEnabled('both'), isTrue);
        expect(c.isFeatureEnabled('all'), isTrue);
      }
    });

    test('respects minAppVersion including pre-releases', () async {
      final payload = fullPayload(
        features: {
          'f': flag(minAppVersion: '2.1.0'),
          'bad': flag(minAppVersion: 'soon'),
        },
      );
      final expectations = {
        '2.0.9': false,
        '2.1.0-beta.1': false,
        '2.1.0': true,
        '2.1.0+99': true,
        '2.10.0': true,
        '3.0.0-rc.1': true,
      };
      for (final MapEntry(key: version, value: expected)
          in expectations.entries) {
        final client = await loaded(payload, appVersion: version);
        expect(client.isFeatureEnabled('f'), expected, reason: version);
        expect(client.isFeatureEnabled('bad'), isFalse, reason: 'fail closed');
      }
    });

    test('0% is never on and 100% is always on', () async {
      final payload = fullPayload(
        features: {'zero': flag(rollout: 0), 'full': flag(rollout: 100)},
      );
      for (var i = 0; i < 50; i++) {
        final client = await loaded(payload, installationId: 'install-$i');
        expect(client.isFeatureEnabled('zero'), isFalse);
        expect(client.isFeatureEnabled('full'), isTrue);
      }
    });

    test('rollout is deterministic per installation and flag', () async {
      final payload = fullPayload(features: {'f': flag(rollout: 25)});
      final a = await loaded(payload, installationId: 'abc');
      final b = await loaded(payload, installationId: 'abc');

      expect(a.rolloutBucket('f'), 63);
      expect(a.rolloutBucket('f'), fnv1a32('f:abc') % 100);
      expect(a.rolloutBucket('f'), b.rolloutBucket('f'));
      expect(a.isFeatureEnabled('f'), b.isFeatureEnabled('f'));
      expect(a.isFeatureEnabled('f'), a.rolloutBucket('f') < 25);
    });

    test('rollout follows bucket < percentage and is roughly uniform', () {
      var enabled = 0;
      const total = 2000;
      for (var i = 0; i < total; i++) {
        final bucket = fnv1a32('new_checkout:device-$i') % 100;
        expect(bucket, inInclusiveRange(0, 99));
        if (bucket < 25) enabled++;
      }
      expect(enabled / total, closeTo(0.25, 0.05));
    });

    test('a different flag key gives an independent bucket', () {
      final differs = List.generate(
        100,
        (i) =>
            fnv1a32('flag_a:device-$i') % 100 !=
            fnv1a32('flag_b:device-$i') % 100,
      ).where((d) => d).length;
      expect(differs, greaterThan(80));
    });
  });

  group('updateStatus', () {
    Map<String, Object?> policy({String? min, String? latest}) => fullPayload(
      updatePolicy: {
        'android': {
          'minimumVersion': min,
          'latestVersion': latest,
          'updateUrl': 'https://play.example/app',
        },
        'ios': {'minimumVersion': '9.0.0', 'latestVersion': '9.0.0'},
        'message': 'Update please',
      },
    );

    test('required when below minimumVersion', () async {
      final client = await loaded(
        policy(min: '1.2.0', latest: '1.4.0'),
        appVersion: '1.1.9',
      );
      final status = client.updateStatus();
      expect(status.level, UpdateLevel.required);
      expect(status.isRequired, isTrue);
      expect(status.updateUrl, 'https://play.example/app');
      expect(status.message, 'Update please');
      expect(status.minimumVersion, SemanticVersion.parse('1.2.0'));
      expect(status.currentVersion, SemanticVersion.parse('1.1.9'));
    });

    test('pre-release of the minimum is still required', () async {
      final client = await loaded(
        policy(min: '1.2.0'),
        appVersion: '1.2.0-rc.1',
      );
      expect(client.updateStatus().level, UpdateLevel.required);
    });

    test('recommended when below latestVersion only', () async {
      final client = await loaded(
        policy(min: '1.2.0', latest: '1.4.0'),
        appVersion: '1.3.0',
      );
      expect(client.updateStatus().level, UpdateLevel.recommended);
    });

    test('upToDate at or above latestVersion or without a policy', () async {
      expect(
        (await loaded(
          policy(min: '1.2.0', latest: '1.4.0'),
          appVersion: '1.4.0',
        )).updateStatus().level,
        UpdateLevel.upToDate,
      );
      expect(
        (await loaded(policy(), appVersion: '0.0.1')).updateStatus().level,
        UpdateLevel.upToDate,
      );
      final empty = buildClient(FakeAdapter([respond(500)]));
      addTearDown(empty.dispose);
      expect(empty.updateStatus().isUpToDate, isTrue);
    });

    test('uses the current platform policy', () async {
      final ios = await loaded(
        policy(),
        platform: AppPlatform.ios,
        appVersion: '8.0.0',
      );
      expect(ios.updateStatus().level, UpdateLevel.required);
      expect(ios.updateStatus().updateUrl, isNull);
    });

    test('ignores unparseable policy versions', () async {
      final client = await loaded(
        policy(min: 'n/a', latest: '1.4.0'),
        appVersion: '1.0.0',
      );
      expect(client.updateStatus().level, UpdateLevel.recommended);
    });
  });

  group('banners', () {
    final banners = [
      {'id': 'always', 'priority': 1},
      {'id': 'future', 'priority': 50, 'startsAt': '2026-10-13T00:00:00Z'},
      {'id': 'expired', 'priority': 50, 'endsAt': '2026-10-11T00:00:00Z'},
      {
        'id': 'window',
        'priority': 10,
        'startsAt': '2026-10-12T00:00:00Z',
        'endsAt': '2026-10-12T23:00:00Z',
      },
      {'id': 'tie', 'priority': 1},
    ];

    test('filters by time window and sorts by priority desc', () async {
      final client = await loaded(fullPayload(banners: banners));
      expect(client.activeBanners().map((b) => b.id), [
        'window',
        'always',
        'tie',
      ]);
    });

    test(
      'evaluates at a given moment with inclusive start, exclusive end',
      () async {
        final client = await loaded(fullPayload(banners: banners));
        List<String> at(DateTime t) =>
            client.activeBanners(at: t).map((b) => b.id).toList();

        expect(at(DateTime.utc(2026, 10, 13)), ['future', 'always', 'tie']);
        expect(at(DateTime.utc(2026, 10, 10)), ['expired', 'always', 'tie']);
        expect(at(DateTime.utc(2026, 10, 12)), ['window', 'always', 'tie']);
        expect(at(DateTime.utc(2026, 10, 12, 23)), ['always', 'tie']);
      },
    );

    test('uses the injected clock and handles local times', () async {
      final client = await loaded(
        fullPayload(banners: banners),
        now: () => DateTime.utc(2026, 10, 14),
      );
      expect(client.activeBanners().map((b) => b.id), [
        'future',
        'always',
        'tie',
      ]);
      final local = DateTime.utc(2026, 10, 12, 12).toLocal();
      expect(client.activeBanners(at: local).first.id, 'window');
    });
  });

  group('maintenance and strings', () {
    test('reports maintenance mode', () async {
      expect((await loaded(fullPayload())).isInMaintenance, isFalse);
      expect(
        (await loaded(fullPayload(maintenance: true))).isInMaintenance,
        isTrue,
      );
    });

    test('looks up strings', () async {
      final client = await loaded(fullPayload());
      expect(client.string('home.welcome'), 'Hi');
      expect(client.string('missing'), isNull);
    });
  });
}
