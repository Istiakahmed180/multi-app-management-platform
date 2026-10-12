import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService extends GetxService {
  ThemeService({this._prefs});

  final SharedPreferencesAsync? _prefs;
  static const _key = 'amp.themeMode';
  final mode = ThemeMode.system.obs;

  Future<ThemeService> load() async {
    try {
      final saved = await _prefs?.getString(_key);
      mode.value = ThemeMode.values.firstWhere((m) => m.name == saved, orElse: () => ThemeMode.system);
    } catch (_) {}
    return this;
  }

  Future<void> setMode(ThemeMode m) async {
    mode.value = m;
    Get.changeThemeMode(m);
    try {
      await _prefs?.setString(_key, m.name);
    } catch (_) {}
  }
}
