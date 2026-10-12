import 'dart:async';
import 'dart:convert';

import 'package:app_management_sdk/app_management_sdk.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('construction', () {
    test('builds the public endpoint URL', () {
      final client = AppManagementClient(
        baseUrl: 'https://api.example.com/base/',
        appKey: testAppKey,
        platform: AppPlatform.ios,
        appVersion: '1.0.0',
        installationId: 'i',
      );
      addTearDown(client.dispose);
      expect(
        client.endpoint.toString(),
        'https://api.example.com/base/api/v1/public/apps/$testAppKey/config?platform=ios',
      );
    });

    test('rejects invalid arguments', () {
      AppManagementClient make({
        String baseUrl = testBaseUrl,
        String appKey = testAppKey,
        String appVersion = '1.0.0',
        String installationId = 'i',
        Duration timeout = const Duration(seconds: 1),
      }) => AppManagementClient(
        baseUrl: baseUrl,
        appKey: appKey,
        platform: AppPlatform.android,
        appVersion: appVersion,
        installationId: installationId,
        timeout: timeout,
      );

      expect(() => make(baseUrl: 'ftp://x'), throwsArgumentError);
      expect(() => make(baseUrl: 'not a url'), throwsArgumentError);
      expect(() => make(appKey: ' '), throwsArgumentError);
      expect(() => make(appVersion: 'latest'), throwsArgumentError);
      expect(() => make(installationId: ''), throwsArgumentError);
      expect(() => make(timeout: Duration.zero), throwsArgumentError);
    });
  });

  group('refresh', () {
    test('fetches, persists and emits a new snapshot', () async {
      final adapter = FakeAdapter([
        respond(200, json: fullPayload(), etag: '"v3-abc"'),
      ]);
      final store = InMemoryConfigStore();
      final client = buildClient(adapter, store: store);
      addTearDown(client.dispose);
      final emitted = <RemoteConfigSnapshot>[];
      client.changes.listen(emitted.add);

      final result = await client.refresh();
      await pumpEventQueue();

      expect(result, isA<RefreshUpdated>());
      expect(result.status, RefreshStatus.updated);
      expect(client.current!.configVersion, 3);
      expect(emitted.single.configVersion, 3);

      final request = adapter.requests.single;
      expect(request.method, 'GET');
      expect(request.uri.path, '/api/v1/public/apps/$testAppKey/config');
      expect(request.uri.queryParameters, {'platform': 'android'});
      expect(request.headers.containsKey('If-None-Match'), isFalse);
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.headers.containsKey('Cookie'), isFalse);

      final stored = (await store.read())!;
      expect(stored.etag, '"v3-abc"');
      expect(stored.fetchedAt, DateTime.utc(2026, 10, 12, 11));
      expect(jsonDecode(stored.rawJson), fullPayload());
      expect(client.lastFetchedAt, DateTime.utc(2026, 10, 12, 11));
    });

    test('sends If-None-Match and treats 304 as notModified', () async {
      final adapter = FakeAdapter([
        respond(200, json: fullPayload(), etag: '"v3-abc"'),
        respond(304),
      ]);
      final client = buildClient(adapter);
      addTearDown(client.dispose);
      await client.refresh();
      final before = client.current;
      final emitted = <RemoteConfigSnapshot>[];
      client.changes.listen(emitted.add);

      final result = await client.refresh();
      await pumpEventQueue();

      expect(result, isA<RefreshNotModified>());
      expect((result as RefreshNotModified).snapshot, same(before));
      expect(client.current, same(before));
      expect(emitted, isEmpty);
      expect(adapter.requests.last.headers['If-None-Match'], '"v3-abc"');
    });

    test('304 without a cached snapshot is an invalid payload', () async {
      final client = buildClient(FakeAdapter([respond(304)]));
      addTearDown(client.dispose);
      final result = await client.refresh();
      expect(_errorKind(result), ConfigErrorKind.invalidPayload);
    });

    test('a newer version replaces the snapshot and the ETag', () async {
      final adapter = FakeAdapter([
        respond(200, json: fullPayload(configVersion: 3), etag: '"v3"'),
        respond(200, json: fullPayload(configVersion: 4), etag: '"v4"'),
        respond(304),
      ]);
      final client = buildClient(adapter);
      addTearDown(client.dispose);
      await client.refresh();
      await client.refresh();
      await client.refresh();
      expect(client.current!.configVersion, 4);
      expect(adapter.requests.last.headers['If-None-Match'], '"v4"');
    });

    group('keeps the last-known-good snapshot on', () {
      final cases = <String, (FakeHandler, ConfigErrorKind)>{
        'network error': (
          throwing(DioExceptionType.connectionError),
          ConfigErrorKind.network,
        ),
        'unknown dio error': (
          throwing(DioExceptionType.unknown),
          ConfigErrorKind.network,
        ),
        'connect timeout': (
          throwing(DioExceptionType.connectionTimeout),
          ConfigErrorKind.timeout,
        ),
        'receive timeout': (
          throwing(DioExceptionType.receiveTimeout),
          ConfigErrorKind.timeout,
        ),
        'HTTP 500': (respond(500, body: 'oops'), ConfigErrorKind.server),
        'HTTP 503': (respond(503), ConfigErrorKind.server),
        'HTTP 404': (
          respond(
            404,
            json: {
              'error': {'code': 'not_found', 'message': 'App not found'},
            },
          ),
          ConfigErrorKind.notFound,
        ),
        'HTTP 429': (
          respond(429, headers: {'retry-after': '30'}),
          ConfigErrorKind.rateLimited,
        ),
        'invalid JSON': (
          respond(200, body: '{"schemaVersion": 1,'),
          ConfigErrorKind.invalidPayload,
        ),
        'empty 200 body': (
          respond(200, body: ''),
          ConfigErrorKind.invalidPayload,
        ),
        'invalid structure': (
          respond(200, json: {...fullPayload(), 'config': 'nope'}),
          ConfigErrorKind.invalidPayload,
        ),
        'invalid color': (
          respond(200, json: _withLightPrimary('#XYZ')),
          ConfigErrorKind.invalidPayload,
        ),
        'unsupported schemaVersion': (
          respond(200, json: fullPayload(schemaVersion: 2)),
          ConfigErrorKind.unsupportedSchema,
        ),
        'appKey mismatch': (
          respond(200, json: fullPayload(appKey: 'app_other')),
          ConfigErrorKind.invalidPayload,
        ),
      };

      for (final MapEntry(key: name, value: (handler, kind)) in cases.entries) {
        test(name, () async {
          final store = InMemoryConfigStore();
          final adapter = FakeAdapter([
            respond(200, json: fullPayload(), etag: '"v3"'),
            handler,
          ]);
          final client = buildClient(adapter, store: store);
          addTearDown(client.dispose);
          await client.refresh();
          final good = client.current!;
          final storedBefore = await store.read();

          final result = await client.refresh();

          expect(result, isA<RefreshFailed>());
          final failed = result as RefreshFailed;
          expect(failed.error.kind, kind);
          expect(failed.lastKnownGood, same(good));
          expect(client.current, same(good));
          expect(await store.read(), same(storedBefore));
        });
      }
    });

    test('maps error details from the response', () async {
      final client = buildClient(
        FakeAdapter([
          respond(
            404,
            json: {
              'error': {'code': 'not_found', 'message': 'App not found'},
            },
          ),
          respond(429, headers: {'retry-after': '30'}),
        ]),
      );
      addTearDown(client.dispose);

      final notFound = (await client.refresh() as RefreshFailed).error;
      expect(notFound.statusCode, 404);
      expect(notFound.message, 'App not found');

      final limited = (await client.refresh() as RefreshFailed).error;
      expect(limited.statusCode, 429);
      expect(limited.retryAfter, const Duration(seconds: 30));
    });

    test('enforces the overall timeout', () async {
      final client = buildClient(
        FakeAdapter([hanging()]),
        timeout: const Duration(milliseconds: 50),
      );
      addTearDown(client.dispose);
      final result = await client.refresh().timeout(const Duration(seconds: 5));
      expect(_errorKind(result), ConfigErrorKind.timeout);
    });

    test(
      'rejects unsupported schema and appKey mismatch with no cache',
      () async {
        final client = buildClient(
          FakeAdapter([
            respond(200, json: fullPayload(schemaVersion: 2)),
            respond(200, json: fullPayload(appKey: 'app_other')),
          ]),
        );
        addTearDown(client.dispose);
        expect(
          _errorKind(await client.refresh()),
          ConfigErrorKind.unsupportedSchema,
        );
        expect(
          _errorKind(await client.refresh()),
          ConfigErrorKind.invalidPayload,
        );
        expect(client.current, isNull);
      },
    );

    test('accepts an older configVersion by default', () async {
      final client = buildClient(
        FakeAdapter([
          respond(200, json: fullPayload(configVersion: 5)),
          respond(200, json: fullPayload(configVersion: 4)),
        ]),
      );
      addTearDown(client.dispose);
      await client.refresh();
      expect(await client.refresh(), isA<RefreshUpdated>());
      expect(client.current!.configVersion, 4);
    });

    test('can reject an older configVersion', () async {
      final client = buildClient(
        FakeAdapter([
          respond(200, json: fullPayload(configVersion: 5)),
          respond(200, json: fullPayload(configVersion: 4)),
          respond(200, json: fullPayload(configVersion: 5)),
        ]),
        rejectOlderConfigVersions: true,
      );
      addTearDown(client.dispose);
      await client.refresh();
      expect(_errorKind(await client.refresh()), ConfigErrorKind.staleVersion);
      expect(client.current!.configVersion, 5);
      expect(await client.refresh(), isA<RefreshUpdated>());
    });

    test('coalesces concurrent calls into one request', () async {
      final gate = Completer<void>();
      final adapter = FakeAdapter([
        gated(gate.future, respond(200, json: fullPayload())),
      ]);
      final client = buildClient(adapter);
      addTearDown(client.dispose);

      final futures = List.generate(5, (_) => client.refresh());
      expect(futures.toSet(), hasLength(1));
      gate.complete();
      final results = await Future.wait(futures);

      expect(adapter.requests, hasLength(1));
      expect(results.every((r) => identical(r, results.first)), isTrue);
      expect(results.first, isA<RefreshUpdated>());

      await client.refresh();
      expect(adapter.requests, hasLength(2));
    });

    test('a store write failure still applies the snapshot', () async {
      final client = buildClient(
        FakeAdapter([respond(200, json: fullPayload())]),
        store: ThrowingStore(),
      );
      addTearDown(client.dispose);
      expect(await client.initialize(), isNotNull);
      expect(client.current!.configVersion, 3);
    });
  });

  group('initialize', () {
    test('restores the cache, emits it, then refreshes', () async {
      final store = InMemoryConfigStore(
        StoredConfig(
          rawJson: jsonEncode(fullPayload(configVersion: 2)),
          etag: '"v2"',
          fetchedAt: DateTime.utc(2026, 10, 1),
        ),
      );
      final adapter = FakeAdapter([
        respond(200, json: fullPayload(configVersion: 3), etag: '"v3"'),
      ]);
      final client = buildClient(adapter, store: store);
      addTearDown(client.dispose);
      final emitted = <int>[];
      client.changes.listen((s) => emitted.add(s.configVersion));

      final result = await client.initialize();
      await pumpEventQueue();

      expect(emitted, [2, 3]);
      expect(result!.configVersion, 3);
      expect(adapter.requests.single.headers['If-None-Match'], '"v2"');
      expect((await store.read())!.etag, '"v3"');
    });

    test('persists across client instances and works offline', () async {
      final store = InMemoryConfigStore();
      final online = buildClient(
        FakeAdapter([respond(200, json: fullPayload(), etag: '"v3"')]),
        store: store,
      );
      await online.initialize();
      await online.dispose();

      final offline = buildClient(
        FakeAdapter([throwing(DioExceptionType.connectionError)]),
        store: store,
      );
      addTearDown(offline.dispose);
      final restored = await offline.initialize();

      expect(restored!.configVersion, 3);
      expect(offline.current!.config.branding.appTitle, 'Shop');
      expect(offline.lastFetchedAt, DateTime.utc(2026, 10, 12, 11));
    });

    test('a 304 after restore keeps the cached snapshot', () async {
      final store = InMemoryConfigStore(
        StoredConfig(
          rawJson: jsonEncode(fullPayload()),
          etag: '"v3"',
          fetchedAt: DateTime.utc(2026, 10, 1),
        ),
      );
      final client = buildClient(FakeAdapter([respond(304)]), store: store);
      addTearDown(client.dispose);
      final result = await client.initialize();
      expect(result!.configVersion, 3);
      expect(client.lastFetchedAt, DateTime.utc(2026, 10, 12, 11));
    });

    test('returns null offline with an empty cache and never throws', () async {
      final client = buildClient(
        FakeAdapter([throwing(DioExceptionType.connectionError)]),
      );
      addTearDown(client.dispose);
      expect(await client.initialize(), isNull);
    });

    test('ignores corrupt store data', () async {
      final corrupt = [
        'not json at all',
        '{"schemaVersion":1}',
        jsonEncode(_withLightPrimary('bad')),
        jsonEncode(fullPayload(schemaVersion: 9)),
        jsonEncode(fullPayload(appKey: 'app_other')),
      ];
      for (final raw in corrupt) {
        final store = InMemoryConfigStore(
          StoredConfig(
            rawJson: raw,
            etag: '"old"',
            fetchedAt: DateTime.utc(2026),
          ),
        );
        final adapter = FakeAdapter([respond(200, json: fullPayload())]);
        final client = buildClient(adapter, store: store);
        final result = await client.initialize();
        await client.dispose();

        expect(result!.configVersion, 3, reason: raw);
        expect(
          adapter.requests.single.headers.containsKey('If-None-Match'),
          isFalse,
          reason: 'etag of a corrupt cache must not be reused',
        );
      }
    });

    test('tolerates a store that throws', () async {
      final client = buildClient(
        FakeAdapter([throwing(DioExceptionType.connectionError)]),
        store: ThrowingStore(),
      );
      addTearDown(client.dispose);
      expect(await client.initialize(), isNull);
    });

    test('is idempotent', () async {
      final adapter = FakeAdapter([respond(200, json: fullPayload())]);
      final client = buildClient(adapter);
      addTearDown(client.dispose);
      final a = client.initialize();
      final b = client.initialize();
      expect(identical(a, b), isTrue);
      await a;
      expect(adapter.requests, hasLength(1));
    });
  });

  group('dispose', () {
    test('closes the stream and rejects further use', () async {
      final client = buildClient(
        FakeAdapter([respond(200, json: fullPayload())]),
      );
      final done = expectLater(client.changes, emitsDone);
      await client.dispose();
      await done;
      expect(client.refresh, throwsStateError);
      expect(client.initialize, throwsStateError);
      await client.dispose();
    });

    test('cancels an in-flight request without emitting', () async {
      final client = buildClient(FakeAdapter([hanging()]));
      final emitted = <RemoteConfigSnapshot>[];
      client.changes.listen(emitted.add);
      final pending = client.refresh();
      await client.dispose();
      expect(_errorKind(await pending), ConfigErrorKind.network);
      await pumpEventQueue();
      expect(emitted, isEmpty);
    });
  });
}

ConfigErrorKind? _errorKind(RefreshResult result) =>
    result is RefreshFailed ? result.error.kind : null;

Map<String, Object?> _withLightPrimary(String color) {
  final payload = fullPayload();
  final theme =
      (payload['config']! as Map<String, Object?>)['theme']!
          as Map<String, Object?>;
  (theme['light']! as Map<String, Object?>)['primary'] = color;
  return payload;
}
