/// Supabase 프로젝트 설정.
///
/// 환경변수(.env 파일)에서 Supabase URL과 publishable key를 읽어옵니다.
/// main.dart에서 `await dotenv.load(fileName: '.env')`가 먼저 호출되어야
/// 이 클래스의 값들이 정상적으로 사용 가능합니다.
///
/// .env 파일 예시:
/// ```
/// SUPABASE_URL=https://xxxxx.supabase.co
/// SUPABASE_PUBLISHABLE_KEY=sb_publishable_xxxx
/// ```
///
/// Google OAuth 설정:
/// 1. Supabase 대시보드 > Authentication > Providers > Google 활성화
/// 2. Google Cloud Console에서 OAuth 클라이언트 생성 (Web application)
/// 3. Supabase의 redirect URL을 Google OAuth 클라이언트에 등록
/// 4. Authentication > URL Configuration > Redirect URLs에
///    `io.supabase.flutter://login` 추가
library;

import 'package:flutter_dotenv/flutter_dotenv.dart';

class SupabaseConfig {
  /// Supabase 프로젝트 URL (.env의 SUPABASE_URL)
  static String get supabaseUrl =>
      dotenv.env['SUPABASE_URL'] ?? '';

  /// Supabase publishable (anon) key (.env의 SUPABASE_PUBLISHABLE_KEY)
  static String get supabaseAnonKey =>
      dotenv.env['SUPABASE_PUBLISHABLE_KEY'] ?? '';

  /// OAuth redirect URL (Android에서 supabase_flutter가 자동 사용)
  static const String redirectUrl = 'io.supabase.flutter://login-callback/';

  /// 설정이 완료되었는지 확인 — .env가 로드되었고 값이 비어있지 않은지 검사
  static bool get isConfigured =>
      supabaseUrl.isNotEmpty &&
      supabaseAnonKey.isNotEmpty &&
      !supabaseUrl.contains('YOUR_PROJECT') &&
      !supabaseAnonKey.contains('YOUR_ANON_KEY');
}
