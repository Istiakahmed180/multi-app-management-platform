import 'dart:convert';
import 'dart:io';

import 'package:app_management_sdk/io.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  final sample = StoredConfig(
    rawJson: jsonEncode(fullPayload()),
    etag: '"v3-abc"',
    fetchedAt: DateTime.utc(2026, 10, 12, 10, 30),
  );

  group('InMemoryConfigStore', () {
    test('reads, writes and clears', () async {
      final store = InMemoryConfigStore();
      expect(await store.read(), isNull);
      await store.write(sample);
      expect(await store.read(), same(sample));
      await store.clear();
      expect(await store.read(), isNull);
    });
  });

  group('FileConfigStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('app_mgmt_sdk_test_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('round-trips through a file', () async {
      final store = FileConfigStore.inDirectory('${dir.path}/nested/cache');
      expect(await store.read(), isNull);

      await store.write(sample);
      final reopened = FileConfigStore(store.file);
      final read = (await reopened.read())!;

      expect(read.rawJson, sample.rawJson);
      expect(read.etag, sample.etag);
      expect(read.fetchedAt, sample.fetchedAt);
      expect(File('${store.file.path}.tmp').existsSync(), isFalse);
    });

    test('overwrites atomically and serializes writes', () async {
      final store = FileConfigStore(File('${dir.path}/config.json'));
      await Future.wait([
        for (var i = 0; i < 10; i++)
          store.write(
            StoredConfig(rawJson: '{"n":$i}', fetchedAt: DateTime.utc(2026)),
          ),
      ]);
      expect((await store.read())!.rawJson, '{"n":9}');
      expect(dir.listSync().map((e) => e.uri.pathSegments.last), [
        'config.json',
      ]);
    });

    test('clear removes the file', () async {
      final store = FileConfigStore(File('${dir.path}/config.json'));
      await store.write(sample);
      await store.clear();
      expect(store.file.existsSync(), isFalse);
      expect(await store.read(), isNull);
      await store.clear();
    });

    test('returns null for a corrupt file', () async {
      final file = File('${dir.path}/config.json');
      for (final content in ['', 'garbage', '{"rawJson":', '[1,2]']) {
        await file.writeAsString(content);
        expect(await FileConfigStore(file).read(), isNull, reason: content);
      }
      await file.writeAsBytes([0xff, 0xfe, 0x00, 0xc3]);
      expect(await FileConfigStore(file).read(), isNull);
    });

    test('feeds an offline client after a restart', () async {
      final file = File('${dir.path}/config.json');
      final online = buildClient(
        FakeAdapter([respond(200, json: fullPayload(), etag: '"v3"')]),
        store: FileConfigStore(file),
      );
      await online.initialize();
      await online.dispose();

      final offline = buildClient(
        FakeAdapter([throwing(DioExceptionType.connectionError)]),
        store: FileConfigStore(file),
      );
      addTearDown(offline.dispose);
      expect((await offline.initialize())!.configVersion, 3);
    });

    test('a corrupt payload inside a valid envelope is ignored', () async {
      final file = File('${dir.path}/config.json');
      await FileConfigStore(file).write(
        StoredConfig(rawJson: '{"broken"', fetchedAt: DateTime.utc(2026)),
      );
      final client = buildClient(
        FakeAdapter([throwing(DioExceptionType.connectionError)]),
        store: FileConfigStore(file),
      );
      addTearDown(client.dispose);
      expect(await client.initialize(), isNull);
    });
  });
}
