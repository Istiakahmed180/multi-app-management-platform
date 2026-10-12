/// The mobile platform the host app is running on.
enum AppPlatform {
  android('android'),
  ios('ios');

  const AppPlatform(this.wireName);

  /// The value used in the `platform` query parameter and in flag targeting.
  final String wireName;
}
