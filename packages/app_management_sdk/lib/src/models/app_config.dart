import '../json.dart';
import '../platform.dart';
import 'theme_config.dart';

final class BrandingConfig {
  const BrandingConfig({this.appTitle = '', this.logoUrl});

  factory BrandingConfig.fromJson(Object? data) {
    final json = JsonObject.from(data);
    return BrandingConfig(
      appTitle: json.string('appTitle'),
      logoUrl: json.optString('logoUrl'),
    );
  }

  final String appTitle;
  final String? logoUrl;

  Map<String, Object?> toJson() => {'appTitle': appTitle, 'logoUrl': logoUrl};
}

/// Maintenance mode. [enabled] is authoritative; [estimatedEndAt] is only
/// informational and does not end maintenance by itself.
final class MaintenanceConfig {
  const MaintenanceConfig({
    this.enabled = false,
    this.title = '',
    this.message = '',
    this.estimatedEndAt,
  });

  factory MaintenanceConfig.fromJson(Object? data) {
    final json = JsonObject.from(data);
    return MaintenanceConfig(
      enabled: json.boolean('enabled', fallback: false),
      title: json.string('title'),
      message: json.string('message'),
      estimatedEndAt: json.optDateTime('estimatedEndAt'),
    );
  }

  final bool enabled;
  final String title;
  final String message;
  final DateTime? estimatedEndAt;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'title': title,
    'message': message,
    'estimatedEndAt': isoOrNull(estimatedEndAt),
  };
}

final class PlatformUpdatePolicy {
  const PlatformUpdatePolicy({
    this.minimumVersion,
    this.latestVersion,
    this.updateUrl,
  });

  factory PlatformUpdatePolicy.fromJson(Object? data) {
    final json = JsonObject.from(data);
    return PlatformUpdatePolicy(
      minimumVersion: json.optString('minimumVersion'),
      latestVersion: json.optString('latestVersion'),
      updateUrl: json.optString('updateUrl'),
    );
  }

  final String? minimumVersion;
  final String? latestVersion;
  final String? updateUrl;

  Map<String, Object?> toJson() => {
    'minimumVersion': minimumVersion,
    'latestVersion': latestVersion,
    'updateUrl': updateUrl,
  };
}

final class UpdatePolicy {
  const UpdatePolicy({
    this.android = const PlatformUpdatePolicy(),
    this.ios = const PlatformUpdatePolicy(),
    this.message = '',
  });

  factory UpdatePolicy.fromJson(Object? data) {
    final json = JsonObject.from(data);
    PlatformUpdatePolicy read(String key) {
      final object = json.optObject(key);
      return object == null
          ? const PlatformUpdatePolicy()
          : PlatformUpdatePolicy.fromJson(object);
    }

    return UpdatePolicy(
      android: read('android'),
      ios: read('ios'),
      message: json.string('message'),
    );
  }

  final PlatformUpdatePolicy android;
  final PlatformUpdatePolicy ios;
  final String message;

  PlatformUpdatePolicy forPlatform(AppPlatform platform) => switch (platform) {
    AppPlatform.android => android,
    AppPlatform.ios => ios,
  };

  Map<String, Object?> toJson() => {
    'android': android.toJson(),
    'ios': ios.toJson(),
    'message': message,
  };
}

final class RemoteBanner {
  const RemoteBanner({
    required this.id,
    this.title = '',
    this.subtitle,
    this.imageUrl,
    this.actionUrl,
    this.priority = 0,
    this.startsAt,
    this.endsAt,
  });

  factory RemoteBanner.fromJson(Object? data) {
    final json = JsonObject.from(data);
    return RemoteBanner(
      id: json.requireString('id'),
      title: json.string('title'),
      subtitle: json.optString('subtitle'),
      imageUrl: json.optString('imageUrl'),
      actionUrl: json.optString('actionUrl'),
      priority: json.integer('priority', fallback: 0),
      startsAt: json.optDateTime('startsAt'),
      endsAt: json.optDateTime('endsAt'),
    );
  }

  final String id;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final String? actionUrl;

  /// Higher values are shown first.
  final int priority;
  final DateTime? startsAt;
  final DateTime? endsAt;

  /// Active when `startsAt <= at < endsAt`, with open bounds when `null`.
  bool isActiveAt(DateTime at) {
    final start = startsAt;
    final end = endsAt;
    if (start != null && at.isBefore(start)) return false;
    if (end != null && !at.isBefore(end)) return false;
    return true;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'imageUrl': imageUrl,
    'actionUrl': actionUrl,
    'priority': priority,
    'startsAt': isoOrNull(startsAt),
    'endsAt': isoOrNull(endsAt),
  };
}

final class OnboardingPage {
  const OnboardingPage({this.title = '', this.body = '', this.imageUrl});

  factory OnboardingPage.fromJson(Object? data) {
    final json = JsonObject.from(data);
    return OnboardingPage(
      title: json.string('title'),
      body: json.string('body'),
      imageUrl: json.optString('imageUrl'),
    );
  }

  final String title;
  final String body;
  final String? imageUrl;

  Map<String, Object?> toJson() => {
    'title': title,
    'body': body,
    'imageUrl': imageUrl,
  };
}

final class OnboardingConfig {
  const OnboardingConfig({this.enabled = false, this.pages = const []});

  factory OnboardingConfig.fromJson(Object? data) {
    final json = JsonObject.from(data);
    return OnboardingConfig(
      enabled: json.boolean('enabled', fallback: false),
      pages: json.mapList('pages', OnboardingPage.fromJson),
    );
  }

  final bool enabled;
  final List<OnboardingPage> pages;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'pages': [for (final page in pages) page.toJson()],
  };
}

/// The `config` section of a published snapshot. Every section is optional
/// and defaults to a neutral value when absent.
final class AppConfig {
  const AppConfig({
    this.branding = const BrandingConfig(),
    this.theme = const ThemeConfig(),
    this.maintenance = const MaintenanceConfig(),
    this.updatePolicy = const UpdatePolicy(),
    this.banners = const [],
    this.onboarding = const OnboardingConfig(),
    this.strings = const {},
  });

  factory AppConfig.fromJson(Object? data) {
    final json = JsonObject.from(data);
    T section<T>(String key, T Function(JsonObject) parse, T fallback) {
      final object = json.optObject(key);
      return object == null ? fallback : parse(object);
    }

    return AppConfig(
      branding: section(
        'branding',
        BrandingConfig.fromJson,
        const BrandingConfig(),
      ),
      theme: section('theme', ThemeConfig.fromJson, const ThemeConfig()),
      maintenance: section(
        'maintenance',
        MaintenanceConfig.fromJson,
        const MaintenanceConfig(),
      ),
      updatePolicy: section(
        'updatePolicy',
        UpdatePolicy.fromJson,
        const UpdatePolicy(),
      ),
      banners: json.mapList('banners', RemoteBanner.fromJson),
      onboarding: section(
        'onboarding',
        OnboardingConfig.fromJson,
        const OnboardingConfig(),
      ),
      strings: json.stringMap('strings'),
    );
  }

  final BrandingConfig branding;
  final ThemeConfig theme;
  final MaintenanceConfig maintenance;
  final UpdatePolicy updatePolicy;

  /// All published banners, including scheduled and expired ones. Use
  /// `AppManagementClient.activeBanners` for the ones to display now.
  final List<RemoteBanner> banners;
  final OnboardingConfig onboarding;
  final Map<String, String> strings;

  Map<String, Object?> toJson() => {
    'branding': branding.toJson(),
    'theme': theme.toJson(),
    'maintenance': maintenance.toJson(),
    'updatePolicy': updatePolicy.toJson(),
    'banners': [for (final banner in banners) banner.toJson()],
    'onboarding': onboarding.toJson(),
    'strings': strings,
  };
}
