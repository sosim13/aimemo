import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_service.dart';

/// Supabase 인증 서비스.
///
/// - 구글 OAuth 로그인
/// - 비로그인(게스트) 모드: 로그인 없이도 모든 기능 사용 가능
/// - 로그인 시 향후 클라우드 동기화를 위한 user_id 확보
///
/// 중요: 앱 시작 시 [init]을 반드시 호출해야 함 (main.dart).
class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final SupabaseClient _client = Supabase.instance.client;

  User? _user;
  bool _isInitializing = true;
  bool _isSigningIn = false;

  /// 현재 로그인된 사용자 (비로그인 시 null)
  User? get currentUser => _user;

  /// 로그인 여부
  bool get isLoggedIn => _user != null;

  /// 초기 로딩 중
  bool get isInitializing => _isInitializing;

  /// 로그인 처리 중
  bool get isSigningIn => _isSigningIn;

  /// 사용자 표시 이름 (이메일 앞部分 또는 전체 이메일)
  String get displayName {
    final email = _user?.email;
    if (email == null) return '게스트';
    final atIdx = email.indexOf('@');
    return atIdx > 0 ? email.substring(0, atIdx) : email;
  }

  /// 사용자 이메일
  String? get email => _user?.email;

  /// 초기화. main.dart에서 호출.
  void init() {
    _user = _client.auth.currentUser;

    _client.auth.onAuthStateChange.listen((data) {
      final event = data.event;
      final session = data.session;
      _user = session?.user;

      debugPrint('[AuthService] auth state changed: $event, user: ${_user?.email}');

      if (event == AuthChangeEvent.signedOut) {
        _user = null;
      } else if (event == AuthChangeEvent.signedIn ||
          event == AuthChangeEvent.tokenRefreshed) {
        // 로그인 성공 시 로컬 메모/책을 Supabase에 백업하고 원격 데이터를 pull.
        // 비로그인/익명이면 SyncService 내부에서 no-op.
        // fire-and-forget — UI 블로킹 방지.
        SyncService().pushAllLocalMemos().catchError((e) {
          debugPrint('[AuthService] pushAllLocalMemos 오류: $e');
        });
        SyncService().pullFromSupabase().catchError((e) {
          debugPrint('[AuthService] pullFromSupabase 오류: $e');
        });
      }

      _isInitializing = false;
      notifyListeners();
    });

    _isInitializing = false;
    notifyListeners();
  }

  /// 구글 OAuth 로그인.
  ///
  /// 크롬(또는 기본 외부 브라우저)을 열어 Google 로그인 진행 →
  /// 완료 후 `io.supabase.flutter://login-callback/` redirect URI로
  /// 앱으로 돌아오면 onAuthStateChange가 자동 처리.
  ///
  /// 주의: Supabase 대시보드에서
  /// - Google provider 활성화 필수
  /// - Redirect URLs에 `io.supabase.flutter://login-callback/` 등록 필수
  Future<void> signInWithGoogle() async {
    if (_isSigningIn) return;
    _isSigningIn = true;
    notifyListeners();

    try {
      await _client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'io.supabase.flutter://login-callback/',
        // 외부 브라우저(크롬)로 열어서 정상적인 Google 로그인 페이지 표시
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      // 여기서 반환되는건 브라우저 열기 성공 여부.
      // 실제 로그인 완료는 redirect → onAuthStateChange가 처리함.
    } catch (e) {
      debugPrint('[AuthService] Google sign-in error: $e');
      rethrow;
    } finally {
      _isSigningIn = false;
      notifyListeners();
    }
  }

  /// 로그아웃
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } catch (e) {
      debugPrint('[AuthService] sign out error: $e');
      rethrow;
    } finally {
      _user = null;
      notifyListeners();
    }
  }
}
