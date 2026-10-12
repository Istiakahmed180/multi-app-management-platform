import 'dart:async';
import 'dart:io';

import 'config_store.dart';

/// A [ConfigStore] backed by a single JSON file.
///
/// Writes go to a sibling temporary file which is then renamed over the
/// target, so a crash mid-write never leaves a truncated file behind.
/// Operations on one instance are serialized.
final class FileConfigStore implements ConfigStore {
  FileConfigStore(this.file);

  /// Convenience constructor, e.g. with `path_provider`'s support directory:
  /// `FileConfigStore.inDirectory(dir.path)`.
  factory FileConfigStore.inDirectory(
    String directory, {
    String fileName = 'app_management_config.json',
  }) => FileConfigStore(File('$directory${Platform.pathSeparator}$fileName'));

  final File file;

  Future<void> _queue = Future<void>.value();

  File get _tempFile => File('${file.path}.tmp');

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<StoredConfig?> read() => _serialized(() async {
    try {
      if (!await file.exists()) return null;
      return StoredConfig.tryDecode(await file.readAsString());
    } on FileSystemException {
      return null;
    }
  });

  @override
  Future<void> write(StoredConfig config) => _serialized(() async {
    await file.parent.create(recursive: true);
    final temp = _tempFile;
    await temp.writeAsString(config.encode(), flush: true);
    await temp.rename(file.path);
  });

  @override
  Future<void> clear() => _serialized(() async {
    for (final f in [file, _tempFile]) {
      if (await f.exists()) await f.delete();
    }
  });
}
