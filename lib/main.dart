import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'services/database_service.dart';
import 'services/llm_service.dart';
import 'services/debug_logger.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/memo_input_screen.dart';
import 'screens/memo_detail_screen.dart';
import 'screens/url_processing_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize debug logger
  await DebugLogger().init();

  // Initialize flutter_gemma for on-device LLM inference
  // Register LiteRT-LM engine for .litertlm model support
  await FlutterGemma.initialize(
    inferenceEngines: [LiteRtLmEngine()],
  );

  // Initialize database
  final databaseService = DatabaseService();
  await databaseService.database; // Pre-initialize

  // Initialize LLM service (load saved settings)
  await LlmService().init();

  runApp(const AimemoApp());
}

class AimemoApp extends StatelessWidget {
  const AimemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aimemo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
        ),
      ),
      initialRoute: '/',
      onGenerateRoute: (settings) {
        // Handle named routes and arguments
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(
              builder: (_) => const HomeScreen(),
            );
          case '/settings':
            return MaterialPageRoute(
              builder: (_) => const SettingsScreen(),
            );
          case '/memo-input':
            final args = settings.arguments as Map<String, dynamic>?;
            return MaterialPageRoute(
              builder: (_) => MemoInputScreen(
                initialUrl: args?['url'] as String?,
                initialContent: args?['content'] as String?,
                youtubeVideoId: args?['youtubeVideoId'] as String?,
              ),
            );
          case '/memo-detail':
            final args = settings.arguments as Map<String, dynamic>;
            return MaterialPageRoute(
              builder: (_) => MemoDetailScreen(
                memoId: args['memoId'] as int,
              ),
            );
          case '/url-processing':
            final args = settings.arguments as Map<String, dynamic>;
            return MaterialPageRoute(
              builder: (_) => UrlProcessingScreen(
                sharedUrl: args['url'] as String,
              ),
            );
          default:
            return MaterialPageRoute(
              builder: (_) => const HomeScreen(),
            );
        }
      },
    );
  }
}
