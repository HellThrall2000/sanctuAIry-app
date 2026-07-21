import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/dashboard_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final isDark = prefs.getBool('sanctuary_theme_dark') ?? false;

  runApp(SanctuaryApp(initialDark: isDark));
}

class SanctuaryApp extends StatefulWidget {
  final bool initialDark;

  // The app will strictly use dark theme, but we keep the parameter for backwards compatibility.
  const SanctuaryApp({Key? key, this.initialDark = true}) : super(key: key);

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

  void toggleTheme() async {
    setState(() {
      _isDark = !_isDark;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sanctuary_theme_dark', _isDark);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sanctuary',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF000000), // Deep black
        primaryColor: const Color(0xFF00E5FF), // Cyan/Neon blue accent
        cardColor: const Color(0xFF0A0A0A), // Dark gray for cards
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Color(0xFFE2E6E9), fontFamily: 'Inter'),
          bodyMedium: TextStyle(color: Color(0xFF878F96), fontFamily: 'Inter'),
          titleLarge: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, fontFamily: 'Inter'),
        ),
        colorScheme: ColorScheme.fromSeed(
          brightness: Brightness.dark,
          seedColor: const Color(0xFF00E5FF),
          background: const Color(0xFF000000),
          surface: const Color(0xFF0A0A0A),
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF000000), // Deep black
        primaryColor: const Color(0xFF00E5FF), // Cyan/Neon blue accent
        cardColor: const Color(0xFF0A0A0A), // Dark gray for cards
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Color(0xFFE2E6E9), fontFamily: 'Inter'),
          bodyMedium: TextStyle(color: Color(0xFF878F96), fontFamily: 'Inter'),
          titleLarge: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, fontFamily: 'Inter'),
        ),
        colorScheme: ColorScheme.fromSeed(
          brightness: Brightness.dark,
          seedColor: const Color(0xFF00E5FF),
          background: const Color(0xFF000000),
          surface: const Color(0xFF0A0A0A),
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark, // Strictly dark-themed
      home: const DashboardScreen(),
    );
  }
}
