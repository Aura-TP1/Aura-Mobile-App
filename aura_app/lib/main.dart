import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'config/app_config.dart';
import 'screens/home_screen.dart';
import 'screens/search_screen.dart';
import 'screens/my_objects.dart';
import 'screens/camera_detection_view.dart';
import 'screens/save_object_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/help_screen.dart';
import 'screens/stt_diagnostics_screen.dart';
import 'services/app_settings.dart';
import 'theme/aura_colors.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Cargar preferencias (velocidad de voz, volumen, tamaño de letra) antes
  // de construir la UI por primera vez.
  await AppSettings.instance.load();

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
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'AURA',
          debugShowCheckedModeBanner: false,
          navigatorKey: AppConfig.navigatorKey,

          // Tema: gris estándar (mismo que la pantalla principal) como
          // fondo por defecto de cualquier pantalla que no lo pise
          // explícitamente. Las pantallas existentes ya fijan su propio
          // backgroundColor/appBar, así que esto no cambia cómo se ven
          // hoy — es la base para que una pantalla nueva nazca consistente
          // con la paleta en vez de blanca por defecto.
          theme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: AuraColors.background,
            appBarTheme: const AppBarTheme(
              backgroundColor: AuraColors.surface,
              elevation: 0,
              iconTheme: IconThemeData(color: Colors.white),
              titleTextStyle: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // Aplica el tamaño de letra elegido en Ajustes a toda la app.
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: TextScaler.linear(AppSettings.instance.fontScale),
              ),
              child: child!,
            );
          },

          // Rutas nombradas
          routes: {
            '/': (context) => const HomeScreen(),
            '/search': (context) => const SearchObjectScreen(),
            '/camera': (context) => const CameraDetectionView(),
            '/my-objects': (context) => const MyObjectsScreen(),
            '/save-object': (context) => const SaveObjectScreen(),
            '/settings': (context) => const SettingsScreen(),
            '/help': (context) => const HelpScreen(),
            '/stt-diagnostics': (context) => const SttDiagnosticsScreen(),
          },
        );
      },
    );
  }
}