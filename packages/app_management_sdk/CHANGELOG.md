# Changelog

## 0.1.0

- Initial release.
- `AppManagementClient` with `initialize`, coalesced `refresh`, ETag /
  `If-None-Match` revalidation and a last-known-good offline fallback.
- Typed, immutable models with tolerant parsing (`RemoteConfigSnapshot`,
  `AppConfig`, `ThemeConfig`, `ColorPalette`, `ConfigColor`, `FeatureFlag`,
  `RemoteBanner`, `UpdatePolicy`, `MaintenanceConfig`, `OnboardingConfig`).
- Feature evaluation with platform targeting, `minAppVersion` and
  deterministic FNV-1a percentage rollouts.
- `updateStatus()`, `isInMaintenance`, `activeBanners()` and `string()`.
- `ConfigStore` with `InMemoryConfigStore` and an atomic `FileConfigStore`
  (in `package:app_management_sdk/io.dart`).
- Optional `rejectOlderConfigVersions` guard.
