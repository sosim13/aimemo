import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'models/queue_state.dart';
import 'services/database_service.dart';
import 'services/llm_service.dart';
import 'services/debug_logger.dart';
import 'services/background_queue_service.dart';
import 'services/content_processing_service.dart';
import 'services/secure_storage_service.dart';
import 'screens/home_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/map_screen.dart';
import 'screens/memo_input_screen.dart';
import 'screens/memo_detail_screen.dart';
import 'screens/memo_map_screen.dart';
import 'screens/url_processing_screen.dart';
import 'screens/chat_screen.dart';

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

  // Initialize API keys if not already stored
  final secureStorage = SecureStorageService();

  // Kakao REST API key: provided by user, stored once
  if (await secureStorage.getKakaoRestApiKey() == null) {
    await secureStorage.saveKakaoRestApiKey('2df99702c2f066873c6525cd2c62105d');
  }

  // Naver Client ID
  if (await secureStorage.getNaverClientId() == null) {
    await secureStorage.saveNaverClientId('14d00nos0m');
  }

  // Naver Client Secret
  if (await secureStorage.getNaverClientSecret() == null) {
    await secureStorage.saveNaverClientSecret('aNPC4VRfpV8tSgSMI7OtYMwRCfOrNhya6qhRaMQP');
  }

  runApp(const AimemoApp());
}

@pragma('vm:entry-point')
Future<void> backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // 1. 초기화 — 각 단계 실패 시 AI 없이 fallback 저장 모드로 진행
  // ---------------------------------------------------------------------------
  try {
    await DebugLogger().init();
  } catch (_) {}

  var aiAvailable = true;

  // FlutterGemma: on-device AI 엔진. secondary engine에서 실패할 수 있으므로
  // 실패해도 치명적이지 않음 — AI 없이 원본 저장만 하면 됨.
  try {
    await FlutterGemma.initialize(
      inferenceEngines: [LiteRtLmEngine()],
    );
  } catch (e) {
    // ignore: avoid_print
    print('[backgroundMain] FlutterGemma 초기화 실패 (AI 없이 진행): $e');
    aiAvailable = false;
  }

  // Database: 실패 시 저장소를 사용할 수 없으므로 여기서 중단
  try {
    await DatabaseService().database;
  } catch (e) {
    // ignore: avoid_print
    print('[backgroundMain] DB 초기화 실패 (처리 불가): $e');
    return;
  }

  try {
    await LlmService().init();
  } catch (e) {
    // ignore: avoid_print
    print('[backgroundMain] LlmService 초기화 실패 (AI 없이 진행): $e');
    aiAvailable = false;
  }

  // ---------------------------------------------------------------------------
  // 2. 큐에 쌓인 아이템을 순차 처리
  // ---------------------------------------------------------------------------
  final queue = BackgroundQueueService();
  final processor = ContentProcessingService();

  try {
    while (true) {
      final items = await queue.getPendingItems();
      if (items.isEmpty) break;

      for (final item in items) {
        // 각 아이템을 개별 try-catch로 감싸서 한 건 실패해도 나머지 계속 처리
        try {
          final contentType = switch (item.type) {
            BackgroundQueueType.url => ContentType.url,
            BackgroundQueueType.image => ContentType.image,
            BackgroundQueueType.text => ContentType.text,
          };

          final fallbackTitle = switch (item.type) {
            BackgroundQueueType.text => '공유된 내용',
            BackgroundQueueType.image => '이미지 메모',
            BackgroundQueueType.url => null,
          };

          final result = await processor.processItem(
            ProcessingItem(
              content: item.content,
              type: contentType,
              fallbackTitle: fallbackTitle,
            ),
          );

          await queue.markComplete(item.id);
          await queue.notifyComplete(
            title: result.title ?? item.content,
            success: result.success,
            error: result.error,
          );
        } catch (e) {
          // processor.processItem() 자체가 예상치 못하게 던진 경우
          await queue.markComplete(item.id);
          await queue.notifyComplete(
            title: item.content,
            success: false,
            error: '처리 중 오류: $e',
          );
        }
      }
    }
  } catch (e) {
    // while/for 루프 자체가 깨진 경우 — 최소한 알림이라도 전송
    // ignore: avoid_print
    print('[backgroundMain] 처리 루프 중단: $e');
  } finally {
    await queue.stopServiceIfIdle();
  }
}

/// Main shell with bottom navigation bar.
/// Five tabs: 메모 (Home), 처리현황 (Queue), AI 챗봇 (Chat), 지도 (Map), 설정 (Settings)
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    final cps = ContentProcessingService();
    // Load processing history into queue state on startup
    cps.loadHistoryIntoState();
    // Start periodic polling for new history from background isolate
    cps.startPeriodicRefresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          HomeScreen(),
          QueueScreen(),
          ChatScreen(),
          MapScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            setState(() => _currentIndex = index);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: '메모',
            ),
            NavigationDestination(
              icon: Icon(Icons.hourglass_bottom_outlined),
              selectedIcon: Icon(Icons.hourglass_bottom),
              label: '처리현황',
            ),
            NavigationDestination(
              icon: Icon(Icons.smart_toy_outlined),
              selectedIcon: Icon(Icons.smart_toy),
              label: 'AI 챗봇',
            ),
            NavigationDestination(
              icon: Icon(Icons.map_outlined),
              selectedIcon: Icon(Icons.map),
              label: '지도',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '설정',
            ),
          ],
        ),
      ),
    );
  }
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
          seedColor: const Color(0xFF1565C0),
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
              builder: (_) => const MainShell(),
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
          case '/memo-map':
            final args = settings.arguments as Map<String, dynamic>;
            return MaterialPageRoute(
              builder: (_) => MemoMapScreen(
                memoId: args['memoId'] as int,
              ),
            );
          case '/chat':
            return MaterialPageRoute(
              builder: (_) => const ChatScreen(),
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
              builder: (_) => const MainShell(),
            );
        }
      },
    );
  }
}
