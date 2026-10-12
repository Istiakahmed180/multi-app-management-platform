/// Client for the App Management Platform's public configuration endpoint.
///
/// Pure Dart and web-safe. For a file-backed cache on mobile/desktop, import
/// `package:app_management_sdk/io.dart` for `FileConfigStore`.
library;

export 'src/client.dart' show AppManagementClient;
export 'src/config_error.dart';
export 'src/config_store.dart';
export 'src/fnv1a.dart' show fnv1a32;
export 'src/models/app_config.dart';
export 'src/models/config_color.dart';
export 'src/models/feature_flag.dart';
export 'src/models/remote_config_snapshot.dart';
export 'src/models/theme_config.dart';
export 'src/platform.dart';
export 'src/refresh_result.dart';
export 'src/semver.dart';
export 'src/update_status.dart';
