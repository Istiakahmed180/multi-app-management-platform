import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

typedef Handler = ResponseBody Function(RequestOptions options);

/// Scriptable Dio adapter: records requests and answers from [handler].
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  Handler handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

Dio fakeDio(FakeAdapter adapter) => Dio()..httpClientAdapter = adapter;

Map<String, dynamic> profileBody({String csrf = 'csrf-1'}) => {
  'data': {
    'csrfToken': csrf,
    'admin': {'id': 'a1', 'email': 'owner@example.com', 'name': 'Owner', 'isSuperAdmin': false},
    'organizations': [
      {
        'id': 'o1',
        'name': 'Acme',
        'slug': 'acme',
        'role': 'owner',
        'appIds': <String>[],
        'permissions': ['apps:read', 'apps:create', 'members:manage'],
      },
      {
        'id': 'o2',
        'name': 'Beta',
        'slug': 'beta',
        'role': 'support_agent',
        'appIds': <String>[],
        'permissions': ['apps:read'],
      },
    ],
  },
};

/// Answers `/apps` with an empty page and everything else with a signed-in profile.
ResponseBody signedInHandler(RequestOptions o) => o.path == '/apps'
    ? jsonResponse(200, {
        'data': <dynamic>[],
        'meta': {'page': 1, 'pageSize': 100, 'total': 0, 'totalPages': 1},
      })
    : jsonResponse(200, profileBody());
