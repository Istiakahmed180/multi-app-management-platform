import 'package:amp_dashboard/core/api/api_client.dart';
import 'package:amp_dashboard/core/api/api_exception.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  group('ApiException.fromDio', () {
    DioException responseError(int status, Object? body) {
      final options = RequestOptions(path: '/x');
      return DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(requestOptions: options, statusCode: status, data: body),
      );
    }

    test('maps validation errors with field paths', () {
      final e = ApiException.fromDio(
        responseError(422, {
          'error': {
            'code': 'validation_failed',
            'message': 'Request validation failed',
            'requestId': 'req-1',
            'details': [
              {'path': 'content.theme.light.primary', 'message': 'Must be a hex color'},
            ],
          },
        }),
      );
      expect(e.isValidation, isTrue);
      expect(e.code, 'validation_failed');
      expect(e.requestId, 'req-1');
      expect(e.fieldError('theme.light.primary'), 'Must be a hex color');
      expect(e.fieldError('theme.dark.primary'), isNull);
    });

    test('maps network and timeout failures to friendly messages', () {
      final options = RequestOptions(path: '/x');
      final network = ApiException.fromDio(DioException(requestOptions: options, type: DioExceptionType.connectionError));
      final timeout = ApiException.fromDio(DioException(requestOptions: options, type: DioExceptionType.receiveTimeout));
      expect(network.isNetwork, isTrue);
      expect(timeout.code, 'timeout');
    });

    test('does not leak raw server bodies for unexpected 5xx responses', () {
      final e = ApiException.fromDio(responseError(502, '<html>Bad gateway stack trace</html>'));
      expect(e.code, 'server_error');
      expect(e.message, isNot(contains('stack trace')));
    });
  });

  group('ApiClient', () {
    test('sends the CSRF token only on unsafe methods', () async {
      final adapter = FakeAdapter((_) => jsonResponse(200, {'data': <String, dynamic>{}}));
      final api = ApiClient(dio: fakeDio(adapter), baseUrl: 'http://api.test/api/v1')..csrfToken = 'tok';
      await api.get('/apps');
      await api.post('/apps', body: {'a': 1});
      await api.delete('/apps/1');
      expect(adapter.requests[0].headers['X-CSRF-Token'], isNull);
      expect(adapter.requests[1].headers['X-CSRF-Token'], 'tok');
      expect(adapter.requests[2].headers['X-CSRF-Token'], 'tok');
    });

    test('refreshes once on 401, updates the CSRF token and retries', () async {
      var authed = false;
      final adapter = FakeAdapter((o) {
        if (o.path == '/auth/refresh') {
          authed = true;
          return jsonResponse(200, {
            'data': {'csrfToken': 'fresh'},
          });
        }
        return authed
            ? jsonResponse(200, {
                'data': {'ok': true},
              })
            : jsonResponse(401, {
                'error': {'code': 'session_expired', 'message': 'Session expired'},
              });
      });
      final api = ApiClient(dio: fakeDio(adapter), baseUrl: 'http://api.test/api/v1');
      final result = await api.get('/overview');
      expect(result, {'ok': true});
      expect(api.csrfToken, 'fresh');
      expect(adapter.requests.map((r) => r.path), ['/overview', '/auth/refresh', '/overview']);
    });

    test('coalesces concurrent refreshes and reports session expiry when refresh fails', () async {
      var expired = 0;
      final adapter = FakeAdapter(
        (o) => jsonResponse(401, {
          'error': {'code': 'unauthenticated', 'message': 'Authentication required'},
        }),
      );
      final api = ApiClient(dio: fakeDio(adapter), baseUrl: 'http://api.test/api/v1')..onSessionExpired = () => expired++;
      final results = await Future.wait([
        api.get('/a').then<Object?>((v) => v, onError: (Object e) => e),
        api.get('/b').then<Object?>((v) => v, onError: (Object e) => e),
      ]);
      expect(results.every((r) => r is ApiException && r.isUnauthenticated), isTrue);
      expect(adapter.requests.where((r) => r.path == '/auth/refresh'), hasLength(1));
      expect(expired, 2);
    });

    test('does not try to refresh failed logins', () async {
      final adapter = FakeAdapter(
        (o) => jsonResponse(401, {
          'error': {'code': 'unauthenticated', 'message': 'Invalid email or password'},
        }),
      );
      final api = ApiClient(dio: fakeDio(adapter), baseUrl: 'http://api.test/api/v1');
      await expectLater(api.post('/auth/login', body: {}, allowRefresh: false), throwsA(isA<ApiException>()));
      expect(adapter.requests, hasLength(1));
    });

    test('parses paginated envelopes', () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse(200, {
          'data': [
            {'id': 1},
            {'id': 2},
          ],
          'meta': {'page': 2, 'pageSize': 2, 'total': 5, 'totalPages': 3},
        }),
      );
      final api = ApiClient(dio: fakeDio(adapter), baseUrl: 'http://api.test/api/v1');
      final page = await api.getPaged('/apps', (j) => j['id'], query: {'page': 2, 'search': '', 'status': null});
      expect(page.items, [1, 2]);
      expect(page.totalPages, 3);
      expect(adapter.requests.single.queryParameters, {'page': 2});
    });
  });
}
