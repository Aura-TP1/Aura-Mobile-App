import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/home_screen.dart';
import 'screens/search_screen.dart';
import 'screens/my_objects.dart';
import 'screens/camera_detection_view.dart';
import 'screens/settings_screen.dart';
import 'screens/help_screen.dart';


void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Forzar orientación vertical
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  
  runApp(const AuraApp());
}

class AuraApp extends StatelessWidget {
  const AuraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AURA',
      debugShowCheckedModeBanner: false,
      
      // Tema
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFFAFAFA),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.black),
          titleTextStyle: TextStyle(
            color: Colors.black,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      
      // Rutas nombradas
      routes: {
        '/': (context) => const HomeScreen(),
        '/search': (context) => const SearchObjectScreen(),
        '/camera': (context) => const CameraDetectionView(),
        '/my-objects': (context) => const MyObjectsScreen(),
        '/settings': (context) => const SettingsScreen(),
        '/help': (context) => const HelpScreen(),
      },
    );
  }
}