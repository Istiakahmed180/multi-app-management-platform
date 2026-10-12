# app_management_sdk

A pure-Dart client for the App Management Platform. Flutter apps (or any Dart
app) use it to read remote configuration: branding, theme colors, maintenance
mode, update policy, banners, onboarding, localized strings, and feature flags
with percentage rollouts.

- No Flutter dependency, so it works in any Flutter app, on the server and on the web.
- ETag revalidation (`If-None-Match` / `304`) and a last-known-good offline cache.
- Typed, immutable models. Parsing ignores unknown fields and fills in defaults for missing ones.
- Deterministic rollout bucketing that is stable per install and per flag.

## Install

The package is not on pub.dev. Add it as a path or git dependency:

```yaml
dependencies:
  app_management_sdk:
    path: ../packages/app_management_sdk
  # or
  app_management_sdk:
    git:
      url: https://github.com/your-org/app-management-platform.git
      path: packages/app_management_sdk
      ref: main
```

The only runtime dependency is `dio`.

## Quick start (Flutter)

```dart
import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_management_sdk/app_management_sdk.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

late final AppManagementClient appConfig;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final info = await PackageInfo.fromPlatform();

  // A random id generated once and persisted. It is only used for rollout
  // bucketing and is never sent to the server.
  final installationId = prefs.getString('installation_id') ??
      await () async {
        final id = const Uuid().v4();
        await prefs.setString('installation_id', id);
        return id;
      }();

  appConfig = AppManagementClient(
    baseUrl: 'https://config.example.com',
    appKey: 'app_xxx', // public identifier, not a secret
    platform: Platform.isIOS ? AppPlatform.ios : AppPlatform.android,
    appVersion: info.version, // e.g. "1.4.0"
    installationId: installationId,
    store: SharedPreferencesConfigStore(prefs),
  );

  // Load the cache right away. The network refresh keeps going in the
  // background, and later updates arrive on appConfig.changes.
  unawaited(appConfig.initialize());
  runApp(const MyApp());
}
```

Call `appConfig.refresh()` when the app resumes, for example from
`AppLifecycleListener(onResume: ...)`. Concurrent calls share one request, so
calling it often costs nothing.

```dart
StreamBuilder<RemoteConfigSnapshot>(
  stream: appConfig.changes,
  initialData: appConfig.current,
  builder: (context, snap) {
    final title = snap.data?.config.branding.appTitle ?? 'My App';
    return Text(appConfig.string('home.welcome') ?? 'Welcome to $title');
  },
);

if (appConfig.isFeatureEnabled('new_checkout')) { /* ... */ }
final banners = appConfig.activeBanners(); // time-filtered, priority desc
```

### `ConfigStore` backed by SharedPreferences

The SDK doesn't depend on `shared_preferences`. Copy this adapter into your
app instead:

```dart
import 'package:app_management_sdk/app_management_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SharedPreferencesConfigStore implements ConfigStore {
  SharedPreferencesConfigStore(this._prefs, {this.key = 'app_management_config'});

  final SharedPreferences _prefs;
  final String key;

  @override
  Future<StoredConfig?> read() async =>
      StoredConfig.tryDecode(_prefs.getString(key)); // corrupt data -> null

  @override
  Future<void> write(StoredConfig config) =>
      _prefs.setString(key, config.encode());

  @override
  Future<void> clear() => _prefs.remove(key);
}
```

On mobile and desktop you can also use the built-in file store. It writes to a
temp file and renames it into place, so a crash mid-write can't leave a
partial file. It lives in a separate library so web builds never import
`dart:io`:

```dart
import 'package:app_management_sdk/io.dart';
import 'package:path_provider/path_provider.dart';

final dir = await getApplicationSupportDirectory();
final store = FileConfigStore.inDirectory(dir.path);
```

## Mapping colors to `ThemeData`

Every color is a 32-bit ARGB `int` (`colorValue`). `#RRGGBBAA` from the server
becomes `0xAARRGGBB`, so `Color(value)` works directly:

```dart
ColorScheme schemeFrom(ColorPalette p, Brightness brightness) {
  final base = ColorScheme.fromSeed(
    seedColor: Color(p.primary.colorValue),
    brightness: brightness,
  );
  return base.copyWith(
    primary: Color(p.primary.colorValue),
    secondary: Color(p.secondary.colorValue),
    surface: Color(p.surface.colorValue),
    error: Color(p.error.colorValue),
  );
}

Widget build(BuildContext context) {
  final theme = (appConfig.current?.config ?? const AppConfig()).theme;
  return MaterialApp(
    theme: ThemeData(
      colorScheme: schemeFrom(theme.light, Brightness.light),
      scaffoldBackgroundColor: Color(theme.light.background.colorValue),
    ),
    darkTheme: theme.darkModeEnabled
        ? ThemeData(
            colorScheme: schemeFrom(theme.dark, Brightness.dark),
            scaffoldBackgroundColor: Color(theme.dark.background.colorValue),
          )
        : null,
    themeMode: switch (theme.effectiveMode) {
      ConfigThemeMode.light => ThemeMode.light,
      ConfigThemeMode.dark => ThemeMode.dark,
      ConfigThemeMode.system => ThemeMode.system,
    },
    home: const HomePage(),
  );
}
```

`effectiveMode` returns `light` when `darkModeEnabled` is false. If the server
leaves out a palette or a single color, the SDK uses its built-in defaults
(`ColorPalette.defaultLight` / `defaultDark`).

## Force update and maintenance

`updateStatus()` compares `appVersion` with the current platform's policy:

| Condition                        | `level`       |
| -------------------------------- | ------------- |
| `appVersion < minimumVersion`    | `required`    |
| `appVersion < latestVersion`     | `recommended` |
| otherwise, or no policy          | `upToDate`    |

Versions are compared as semver. Pre-releases rank lower than the release
(`1.2.0-rc.1 < 1.2.0`) and build metadata (`+45`) is ignored.

**Your app enforces force-update; the server can't.** The platform can't
install, block or remove anything on a device. It only publishes a policy.
Your UI has to act on `required`, for example with a blocking screen. Treat it
as a usability guard rather than a security control: a modified client can
skip it. Anything that must not run on old versions has to be rejected by your
own backend too.

```dart
Widget gate(Widget child) {
  if (appConfig.isInMaintenance) {
    final m = appConfig.current!.config.maintenance;
    return MaintenanceScreen(title: m.title, message: m.message, until: m.estimatedEndAt);
  }
  final update = appConfig.updateStatus();
  if (update.isRequired) {
    return ForceUpdateScreen(
      message: update.message,
      onUpdate: () => launchUrl(Uri.parse(update.updateUrl!)), // url_launcher
    ); // no way to dismiss
  }
  if (update.isRecommended) {
    WidgetsBinding.instance.addPostFrameCallback((_) => showUpdateSnackBar(update));
  }
  return child;
}
```

Wrap your home screen in a `StreamBuilder` over `appConfig.changes` so the gate
re-evaluates when a new config arrives. Maintenance ends only when the server
publishes `enabled: false`. `estimatedEndAt` is for display only.

## Feature flags

`isFeatureEnabled(key)` returns true only when all of these hold:

1. The flag is present in `features` and `enabled`. A missing key means disabled.
2. `platforms` is empty or includes the current platform.
3. `appVersion >= minAppVersion`. A `minAppVersion` that can't be parsed counts as disabled.
4. `bucket < rolloutPercentage`, where
   `bucket = FNV-1a32("$key:$installationId") % 100`.

The bucket is deterministic. Raising a rollout from 10% to 25% keeps the
original 10% enabled, and each flag buckets independently. You can inspect a
bucket with `client.rolloutBucket(key)`. Keep the `installationId` stable
across launches. If it changes, the user is re-bucketed.

## Caching, ETag and offline behavior

- `initialize()` reads the store, emits the cached snapshot on `changes` and
  sets `current`, then calls `refresh()`. Network and storage errors never
  cause it to throw. It returns `current` after the refresh attempt, which is
  `null` only when the device is offline and the cache is empty.
- `refresh()` sends `If-None-Match` with the cached ETag. Results:
  - `RefreshUpdated`: a new snapshot was validated, persisted and emitted.
  - `RefreshNotModified`: the server returned `304`, and the cached snapshot is
    still current. Nothing is emitted.
  - `RefreshFailed(error)`: `current` and the store are left untouched. That
    snapshot is the last-known-good. `error.kind` is one of `network`,
    `timeout`, `notFound` (404), `rateLimited` (429, with `retryAfter` when
    the server sends it), `server` (5xx or another unexpected status),
    `invalidPayload` (bad JSON or structure, or a payload for a different
    `appKey`), `unsupportedSchema` (`schemaVersion > 1`) or `staleVersion` (see
    below).
- Concurrent `refresh()` calls share one HTTP request and resolve to the same
  result.
- `timeout` (8 s by default) is an overall deadline for the request.
- The store keeps the raw response body exactly as received, with its ETag and
  `fetchedAt`. If a stored entry is corrupt, can't be parsed, uses a newer
  schema or belongs to another app, the SDK ignores it and does not reuse its
  ETag.
- Older `configVersion`: by default the server is authoritative, and a lower
  `configVersion` than the cached one is accepted. That way clients recover if
  the backend is restored from a backup. Pass `rejectOlderConfigVersions: true`
  to reject such payloads as `staleVersion` and keep the newer cached config.
- The server sends `Cache-Control: public, max-age=60, must-revalidate`. You
  don't need to refresh more often than about once a minute. Refreshing on app
  resume is usually enough.
- On the web, the browser HTTP cache may answer revalidations itself, so a
  `304` can show up as an identical `200`. That's harmless.

## Security model

- **The `appKey` only identifies the app.** It is public, ships in every build,
  and grants no authorization. Anyone can read your config with it.
- **The app contains no server secrets.** The SDK sends no credentials, tokens
  or cookies. It never sends `installationId`, which stays on the device for
  bucketing.
- **The config endpoint is public and read-only.** Never put secrets in
  configuration: no API keys, credentials, internal URLs you need to keep
  hidden, or per-user data. Everything you publish is readable by anyone.
- **User authentication belongs to your own backend.** This SDK doesn't
  authenticate users and shouldn't be used to.
- **Use device attestation for sensitive operations.** Verify Play Integrity
  (Android) or App Attest / DeviceCheck (iOS) on your app's backend.
- **Enforce on the server, not the client.** Client-side checks such as
  feature flags, force-update and maintenance screens improve the experience
  but can be bypassed. Server-side state such as a suspended user must be
  checked by your app backend, through the platform's ingest status API or
  webhook. Never trust a status the client reports.
- **The endpoint is rate limited.** A `429` comes back as
  `ConfigErrorKind.rateLimited` and the client keeps the last-known-good
  config. Don't retry in a tight loop.
- If you inject your own `Dio`, keep authorization interceptors off it. The
  config endpoint needs none, and sending tokens to it would leak them.

## API overview

| Member | Description |
| --- | --- |
| `AppManagementClient(...)` | `baseUrl`, `appKey`, `platform`, `appVersion`, `installationId`; optional `store`, `timeout`, `dio`, `now`, `rejectOlderConfigVersions` |
| `initialize()` | Restore the cache, emit it, then refresh. Never throws on failure |
| `refresh()` | `RefreshUpdated` / `RefreshNotModified` / `RefreshFailed` |
| `current`, `changes`, `lastFetchedAt` | State and a broadcast stream of applied snapshots |
| `isFeatureEnabled(key)`, `rolloutBucket(key)` | Flag evaluation |
| `updateStatus()` | `UpdateStatus` with `level`, `updateUrl`, `message` |
| `isInMaintenance`, `activeBanners({at})`, `string(key)` | Convenience accessors |
| `dispose()` | Cancels in-flight work and closes `changes` |
| `SemanticVersion`, `fnv1a32` | Version comparison and the bucketing hash |
| `ConfigStore`, `StoredConfig`, `InMemoryConfigStore`, `FileConfigStore` (io) | Persistence |

## Development

```sh
dart pub get
dart format .
dart analyze
dart test
```
