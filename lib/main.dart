import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_shell.dart';
import 'theme/app_theme.dart';

const _themePrefKey = 'sanctuary_theme_dark';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // Sunlit by default: the Organic system is authored as a light theme, and
  // Dusk is the derived one.
  final isDark = prefs.getBool(_themePrefKey) ?? false;

  runApp(SanctuaryApp(initialDark: isDark));
}

class SanctuaryApp extends StatefulWidget {
  final bool initialDark;

  const SanctuaryApp({super.key, this.initialDark = false});

  @override
  State<SanctuaryApp> createState() => SanctuaryAppState();

  static SanctuaryAppState of(BuildContext context) =>
      context.findAncestorStateOfType<SanctuaryAppState>()!;
}

class SanctuaryAppState extends State<SanctuaryApp> {
  late bool _isDark;

  @override
  void initState() {
    super.initState();
    _isDark = widget.initialDark;
  }

  bool get isDark => _isDark;

  /// Switches palette and remembers the choice.
  ///
  /// This used to write the preference and change nothing: `themeMode` was
  /// hardcoded to `ThemeMode.dark` and both themes were identical, so the
  /// drawer's toggle was a dead control. It is the "Sunlit / Dusk" segmented
  /// control now, and it works.
  Future<void> setDark(bool value) async {
    if (value == _isDark) return;
    setState(() => _isDark = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themePrefKey, value);
  }

  void toggleTheme() => setDark(!_isDark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sanctuary',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.sunlit(),
      darkTheme: AppTheme.dusk(),
      themeMode: _isDark ? ThemeMode.dark : ThemeMode.light,
      home: HomeShell(isDark: _isDark, onThemeChanged: setDark),
    );
  }
}
