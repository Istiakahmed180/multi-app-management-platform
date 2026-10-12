import 'config_error.dart';
import 'models/remote_config_snapshot.dart';

enum RefreshStatus { updated, notModified, failed }

/// The outcome of `AppManagementClient.refresh`.
sealed class RefreshResult {
  const RefreshResult();

  RefreshStatus get status;
}

/// A new snapshot was fetched, persisted and emitted on `changes`.
final class RefreshUpdated extends RefreshResult {
  const RefreshUpdated(this.snapshot);

  final RemoteConfigSnapshot snapshot;

  @override
  RefreshStatus get status => RefreshStatus.updated;
}

/// The server confirmed the cached snapshot is current (HTTP 304).
final class RefreshNotModified extends RefreshResult {
  const RefreshNotModified(this.snapshot);

  final RemoteConfigSnapshot snapshot;

  @override
  RefreshStatus get status => RefreshStatus.notModified;
}

/// The refresh failed; the last-known-good snapshot, if any, is still in use.
final class RefreshFailed extends RefreshResult {
  const RefreshFailed(this.error, {this.lastKnownGood});

  final ConfigError error;
  final RemoteConfigSnapshot? lastKnownGood;

  @override
  RefreshStatus get status => RefreshStatus.failed;
}
