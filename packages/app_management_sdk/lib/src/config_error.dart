/// Why a refresh failed.
enum ConfigErrorKind {
  /// No connection, DNS failure, TLS error, or the request was cancelled.
  network,

  /// The request exceeded the client's timeout.
  timeout,

  /// HTTP 404: unknown or inactive app, or nothing published yet.
  notFound,

  /// HTTP 429: the endpoint is rate limiting this client.
  rateLimited,

  /// HTTP 5xx, or another unexpected HTTP status.
  server,

  /// The body was not valid JSON, failed validation, or belongs to another
  /// app.
  invalidPayload,

  /// The payload's `schemaVersion` is newer than this SDK supports.
  unsupportedSchema,

  /// The payload's `configVersion` is older than the cached one. Only produced
  /// when `rejectOlderConfigVersions` is enabled.
  staleVersion,
}

/// A typed refresh failure. Never thrown by the client; it is returned inside
/// a `RefreshFailed` result.
final class ConfigError implements Exception {
  const ConfigError(
    this.kind,
    this.message, {
    this.statusCode,
    this.retryAfter,
    this.cause,
  });

  final ConfigErrorKind kind;
  final String message;

  /// The HTTP status code, when a response was received.
  final int? statusCode;

  /// Parsed from `Retry-After` on [ConfigErrorKind.rateLimited], if present.
  final Duration? retryAfter;

  /// The underlying exception, for logging.
  final Object? cause;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'ConfigError.${kind.name}$status: $message';
  }
}
