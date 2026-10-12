import 'package:dio/dio.dart';

class FieldError {
  const FieldError(this.path, this.message);
  final String path;
  final String message;
}

/// Normalized API failure. Messages are safe to show to admins.
class ApiException implements Exception {
  const ApiException({required this.code, required this.message, this.status, this.fieldErrors = const [], this.requestId});

  final String code;
  final String message;
  final int? status;
  final List<FieldError> fieldErrors;
  final String? requestId;

  bool get isUnauthenticated => status == 401;
  bool get isForbidden => status == 403;
  bool get isNotFound => status == 404;
  bool get isConflict => status == 409;
  bool get isValidation => status == 422;
  bool get isNetwork => code == 'network_error' || code == 'timeout';

  /// First error for a form field, matched on the path suffix (e.g. `content.theme.light.primary`).
  String? fieldError(String path) {
    for (final e in fieldErrors) {
      if (e.path == path || e.path.endsWith('.$path')) return e.message;
    }
    return null;
  }

  factory ApiException.fromDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const ApiException(code: 'timeout', message: 'The server took too long to respond. Please try again.');
      case DioExceptionType.connectionError:
        return const ApiException(code: 'network_error', message: 'Cannot reach the server. Check your connection.');
      case DioExceptionType.cancel:
        return const ApiException(code: 'cancelled', message: 'Request cancelled');
      default:
        break;
    }
    final response = e.response;
    final status = response?.statusCode;
    final data = response?.data;
    if (data is Map && data['error'] is Map) {
      final err = Map<String, dynamic>.from(data['error'] as Map);
      final details = err['details'];
      final fields = <FieldError>[];
      if (details is List) {
        for (final d in details) {
          if (d is Map && d['message'] is String) {
            fields.add(FieldError('${d['path'] ?? ''}', d['message'] as String));
          }
        }
      }
      return ApiException(
        code: '${err['code'] ?? 'error'}',
        message: '${err['message'] ?? 'Request failed'}',
        status: status,
        fieldErrors: fields,
        requestId: err['requestId'] as String?,
      );
    }
    return ApiException(
      code: status != null && status >= 500 ? 'server_error' : 'error',
      message: status != null && status >= 500
          ? 'The server encountered an error. Please try again later.'
          : 'Request failed${status != null ? ' ($status)' : ''}.',
      status: status,
    );
  }

  @override
  String toString() => 'ApiException($code, $status): $message';
}
