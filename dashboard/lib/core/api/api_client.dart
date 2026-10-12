import 'dart:async';

import 'package:dio/dio.dart';

import '../env.dart';
import '../models/models.dart';
import 'adapter_stub.dart' if (dart.library.js_interop) 'adapter_web.dart';
import 'api_exception.dart';

class Paged<T> {
  const Paged({required this.items, required this.page, required this.pageSize, required this.total, required this.totalPages});

  final List<T> items;
  final int page;
  final int pageSize;
  final int total;
  final int totalPages;

  static Paged<T> empty<T>() => Paged<T>(items: const [], page: 1, pageSize: 20, total: 0, totalPages: 1);
}

/// HTTP client for the dashboard API.
///
/// Authentication uses HttpOnly cookies managed by the browser. The CSRF token
/// returned by login/refresh/me is kept in memory and sent on unsafe methods.
/// A 401 triggers a single coalesced refresh followed by one retry.
class ApiClient {
  ApiClient({Dio? dio, String? baseUrl}) : dio = dio ?? Dio() {
    this.dio.options
      ..baseUrl = baseUrl ?? Env.apiBaseUrl
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(seconds: 30)
      ..contentType = Headers.jsonContentType
      ..responseType = ResponseType.json;
    if (dio == null) this.dio.httpClientAdapter = createAdapter();
    this.dio.interceptors.add(InterceptorsWrapper(onRequest: _attachCsrf));
  }

  final Dio dio;
  String? csrfToken;

  /// Called when the session cannot be refreshed (e.g. to route to /login).
  void Function()? onSessionExpired;

  Future<void>? _refreshing;

  static const _unsafe = {'POST', 'PUT', 'PATCH', 'DELETE'};

  void _attachCsrf(RequestOptions options, RequestInterceptorHandler handler) {
    if (_unsafe.contains(options.method.toUpperCase()) && csrfToken != null) {
      options.headers['X-CSRF-Token'] = csrfToken;
    }
    handler.next(options);
  }

  Future<void> _refresh() {
    return _refreshing ??= () async {
      try {
        final res = await dio.post<dynamic>('/auth/refresh');
        final data = (res.data as Map)['data'] as Map;
        csrfToken = data['csrfToken'] as String?;
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<Response<dynamic>> _send(Future<Response<dynamic>> Function() call, {required bool allowRefresh}) async {
    try {
      return await call();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final path = e.requestOptions.path;
      final isAuthCall = path.startsWith('/auth/login') || path.startsWith('/auth/refresh');
      if (status == 401 && allowRefresh && !isAuthCall) {
        try {
          await _refresh();
        } on DioException {
          // A concurrent tab may have rotated the token; one more attempt decides.
        }
        try {
          return await call();
        } on DioException catch (retryError) {
          if (retryError.response?.statusCode == 401) onSessionExpired?.call();
          throw ApiException.fromDio(retryError);
        }
      }
      throw ApiException.fromDio(e);
    }
  }

  Future<dynamic> _data(Future<Response<dynamic>> Function() call, {bool allowRefresh = true}) async {
    final res = await _send(call, allowRefresh: allowRefresh);
    final body = res.data;
    return body is Map ? body['data'] : body;
  }

  Map<String, dynamic>? _clean(Map<String, dynamic>? query) {
    if (query == null) return null;
    final out = <String, dynamic>{};
    query.forEach((k, v) {
      if (v == null) return;
      if (v is String && v.isEmpty) return;
      out[k] = v;
    });
    return out;
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) => _data(() => dio.get<dynamic>(path, queryParameters: _clean(query)));

  /// Full response body (`data` and `meta`) for endpoints that return more than a list.
  Future<Json> getEnvelope(String path, {Map<String, dynamic>? query}) async {
    final res = await _send(() => dio.get<dynamic>(path, queryParameters: _clean(query)), allowRefresh: true);
    return asJson(res.data);
  }

  Future<Paged<T>> getPaged<T>(String path, T Function(Json) map, {Map<String, dynamic>? query}) async {
    final res = await _send(() => dio.get<dynamic>(path, queryParameters: _clean(query)), allowRefresh: true);
    final body = res.data as Map;
    final items = (body['data'] as List).map((e) => map(Map<String, dynamic>.from(e as Map))).toList();
    final meta = Map<String, dynamic>.from((body['meta'] as Map?) ?? const {});
    return Paged<T>(
      items: items,
      page: (meta['page'] as num?)?.toInt() ?? 1,
      pageSize: (meta['pageSize'] as num?)?.toInt() ?? items.length,
      total: (meta['total'] as num?)?.toInt() ?? items.length,
      totalPages: (meta['totalPages'] as num?)?.toInt() ?? 1,
    );
  }

  Future<dynamic> post(String path, {Object? body, Map<String, String>? headers, bool allowRefresh = true}) => _data(
    () => dio.post<dynamic>(
      path,
      data: body ?? const <String, dynamic>{},
      options: Options(headers: headers),
    ),
    allowRefresh: allowRefresh,
  );

  Future<dynamic> put(String path, {Object? body}) => _data(() => dio.put<dynamic>(path, data: body));

  Future<dynamic> patch(String path, {Object? body}) => _data(() => dio.patch<dynamic>(path, data: body));

  Future<dynamic> delete(String path) => _data(() => dio.delete<dynamic>(path));
}
