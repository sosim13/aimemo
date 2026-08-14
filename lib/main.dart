import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models/queue_state.dart';
import 'services/auth_service.dart';
import 'services/supabase_config.dart';
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
import 'screens/reading/reading_dashboard_screen.dart';
import 'screens/reading/reading_calendar_screen.dart';
import 'screens/sync_history_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize debug logger
  await DebugLogger().init();

  // 한국어 달력 locale 초기화
  await initializeDateFormatting('ko_KR', null);

  // .env 파일 로드 — Supabase.initialize 전에 반드시 실행되어야 함
  await dotenv.load(fileName: '.env');

  // Initialize Supabase (auth + cloud sync) — dotenv에서 URL/key 읽기
  await Supabase.initialize(
    url: SupabaseConfig.supabaseUrl,
    publishableKey: SupabaseConfig.supabaseAnonKey,
  );
  AuthService().init();

  // Initialize flutter_gemma for on-device LLM inference
  // Register LiteRT-LM engine for .litertlm model support
  await FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()]);

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
    await secureStorage.saveNaverClientSecret(
      'aNPC4VRfpV8tSgSMI7OtYMwRCfOrNhya6qhRaMQP',
    );
  }

  runApp(const AimemoApp());
}

@pragma('vm:entry-point')
Future<void> backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // 1. 초기화 — 각 단계 실패 시 AI 없이 fallback 저장 모드로 진행
  // ---------------------------------------------------------------------------

  // 백그라운드 isolate 시작 로그 — 서비스가 실제로 진입했는지 확인 용도
  try {
    await DebugLogger().init();
    await DebugLogger().log('backgroundMain: isolate 시작됨');
  } catch (_) {}

  var aiAvailable = true;

  // FlutterGemma: on-device AI 엔진. secondary engine에서 실패할 수 있으므로
  // 실패해도 치명적이지 않음 — AI 없이 원본 저장만 하면 됨.
  try {
    await FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()]);
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

  // ContentProcessingService는 내부적으로 SyncService(지연 초기화)를 참조한다.
  // 백그라운드 isolate에서는 Supabase.initialize()가 호출되지 않으므로,
  // 생성 실패에 대비해 try-catch로 감싼다. (실패 시 처리를 포기하고 종료)
  ContentProcessingService processor;
  try {
    processor = ContentProcessingService();
  } catch (e) {
    // ignore: avoid_print
    print('[backgroundMain] ContentProcessingService 초기화 실패 — 종료: $e');
    try {
      await DebugLogger().log(
        'backgroundMain: ContentProcessingService 초기화 실패 $e',
      );
    } catch (_) {}
    return;
  }

  try {
    while (true) {
      final items = await queue.getPendingItems();
      if (items.isEmpty) {
        await DebugLogger().log('backgroundMain: 큐 비어있음 — 종료');
        break;
      }

      await DebugLogger().log('backgroundMain: ${items.length}건 처리 시작');

      for (final item in items) {
        // 각 아이템을 개별 try-catch로 감싸서 한 건 실패해도 나머지 계속 처리
        try {
          await DebugLogger().log(
            'backgroundMain: 처리 시작 id=${item.id} type=${item.type} content=${item.content.length > 50 ? item.content.substring(0, 50) + "..." : item.content}',
          );

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

          // 안전장치: processItem이 영원히 return하지 않는 경우(hang)를 방지.
          // 3분 내에 처리가 끝나지 않으면 강제로 큐에서 제거하고 알림.
          // (on-device LLM이 응답하지 않거나 network fetch가 hang하는 경우)
          ProcessingResult result;
          try {
            result = await processor
                .processItem(
                  ProcessingItem(
                    content: item.content,
                    type: contentType,
                    fallbackTitle: fallbackTitle,
                  ),
                )
                .timeout(const Duration(minutes: 3));
            await DebugLogger().log(
              'backgroundMain: 처리 완료 id=${item.id} success=${result.success}',
            );
          } catch (e) {
            // timeout 또는 예외 — 처리 실패로 간주하고 큐에서 강제 제거
            await DebugLogger().log(
              'backgroundMain: 처리 실패 id=${item.id} error=$e',
            );
            await queue.removeById(item.id);
            await queue.notifyComplete(
              title: item.content,
              success: false,
              error: '처리 시간 초과 또는 오류: $e',
            );
            continue;
          }

          await queue.markComplete(item.id);
          await queue.notifyComplete(
            title: result.title ?? item.content,
            success: result.success,
            error: result.error,
          );
        } catch (e) {
          // processor.processItem() 자체가 예상치 못하게 던진 경우
          await DebugLogger().log('backgroundMain: 예외 id=${item.id} error=$e');
          await queue.removeById(item.id);
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
    try {
      await DebugLogger().log('backgroundMain: 루프 중단 $e');
    } catch (_) {}
  } finally {
    await DebugLogger().log('backgroundMain: 종료 — stopServiceIfIdle 호출');
    await queue.stopServiceIfIdle();
  }
}

/// Main shell with bottom navigation bar.
/// 하단 5개 탭: 메모, 처리현황, AI 챗봇, 지도, 더보기(menu)
/// 더보기 탭 선택 시 전체메뉴 모달 시트 표시 (독서기록, 독서달력, 동기화 이력, 설정).
/// 모달 시트에서 메뉴 선택 시 해당 화면이 IndexedStack에 표시되며
/// 하단 메뉴는 항상 유지됨.
/// 향후 메뉴 추가 시 _MoreSheet에 ListTile 추가 + _screenIndex에 인덱스 매핑.
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

  /// 하단 메뉴 탭 인덱스 — 더보기는 항상 4.
  static const _moreTabIndex = 4;

  void _onDestinationSelected(int index) {
    if (index == _moreTabIndex) {
      _showMoreSheet();
      return;
    }
    setState(() => _currentIndex = index);
  }

  /// 더보기 모달 시트에서 메뉴 선택 시 호출.
  /// 선택한 화면 인덱스로 전환하되, 하단 메뉴의 더보기 탭이
  /// 선택된 상태로 표시되도록 한다.
  void _selectMoreMenu(int screenIndex) {
    setState(() => _currentIndex = screenIndex);
  }

  void _showMoreSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _MoreSheet(onSelect: _selectMoreMenu),
    );
  }

  /// 하단 메뉴의 선택 인덱스 계산.
  /// 0~3은 그대로, 4~7(더보기 서브 메뉴)은 모두 4(더보기)로 매핑.
  int get _navBarIndex {
    if (_currentIndex <= _moreTabIndex) return _currentIndex;
    return _moreTabIndex;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          HomeScreen(), // 0: 메모
          QueueScreen(), // 1: 처리현황
          ChatScreen(), // 2: AI 챗봇
          MapScreen(), // 3: 지도
          ReadingDashboardScreen(), // 4: 독서 기록
          ReadingCalendarScreen(), // 5: 독서 달력
          SyncHistoryScreen(), // 6: 동기화 이력
          SettingsScreen(), // 7: 설정
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: NavigationBar(
          selectedIndex: _navBarIndex,
          onDestinationSelected: _onDestinationSelected,
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
              icon: Icon(Icons.menu_outlined),
              selectedIcon: Icon(Icons.menu),
              label: '더보기',
            ),
          ],
        ),
      ),
    );
  }
}

/// 전체메뉴 모달 시트.
///
/// 메뉴 순서 (위에서 아래):
///   1. 독서 기록
///   2. 독서 달력
///   3. 동기화 이력
///   (향후 추가 메뉴는 여기에)
///   마지막: 설정  ← 항상 맨 아래
///
/// 새 메뉴 추가時: ListTile 추가 + onSelect 인덱스 매핑.
/// 선택한 화면은 MainShell의 IndexedStack 내에 표시되어
/// 하단 메뉴가 사라지지 않음.
class _MoreSheet extends StatelessWidget {
  const _MoreSheet({required this.onSelect});

  /// 선택한 메뉴의 IndexedStack 인덱스를 MainShell에 전달.
  final void Function(int screenIndex) onSelect;

  void _select(BuildContext context, int screenIndex) {
    Navigator.pop(context);
    onSelect(screenIndex);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 핸들 바
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '전체 메뉴',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          const Divider(height: 1),

          // --- 메뉴 항목들 ---
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('독서 기록'),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => _select(context, 4), // _readingIndex
          ),
          ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('독서 달력'),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => _select(context, 5), // _calendarIndex
          ),
          ListTile(
            leading: const Icon(Icons.sync_outlined),
            title: const Text('동기화 이력'),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => _select(context, 6), // _syncIndex
          ),

          const Divider(height: 1),

          // --- 설정 (항상 맨 아래) ---
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('설정'),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            onTap: () => _select(context, 7), // _settingsIndex
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class AimemoApp extends StatelessWidget {
  const AimemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AuthService(),
      child: MaterialApp(
        title: 'Aimemo',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1565C0),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          fontFamily: 'Roboto',
          appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
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
              return MaterialPageRoute(builder: (_) => const MainShell());
            case '/settings':
              return MaterialPageRoute(builder: (_) => const SettingsScreen());
            case '/memo-input':
              final args = settings.arguments as Map<String, dynamic>?;
              return MaterialPageRoute(
                builder:
                    (_) => MemoInputScreen(
                      initialUrl: args?['url'] as String?,
                      initialContent: args?['content'] as String?,
                      youtubeVideoId: args?['youtubeVideoId'] as String?,
                    ),
              );
            case '/memo-detail':
              final args = settings.arguments as Map<String, dynamic>;
              return MaterialPageRoute(
                builder: (_) => MemoDetailScreen(memoId: args['memoId'] as int),
              );
            case '/memo-map':
              final args = settings.arguments as Map<String, dynamic>;
              return MaterialPageRoute(
                builder: (_) => MemoMapScreen(memoId: args['memoId'] as int),
              );
            case '/chat':
              return MaterialPageRoute(builder: (_) => const ChatScreen());
            case '/url-processing':
              final args = settings.arguments as Map<String, dynamic>;
              return MaterialPageRoute(
                builder:
                    (_) =>
                        UrlProcessingScreen(sharedUrl: args['url'] as String),
              );
            default:
              return MaterialPageRoute(builder: (_) => const MainShell());
          }
        },
      ),
    );
  }
}
