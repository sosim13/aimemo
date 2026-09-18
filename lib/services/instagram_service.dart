import 'dart:convert';
import 'package:http/http.dart' as http;
import 'debug_logger.dart';

/// Instagram 게시물(포스트/릴스)에서 추출한 메타데이터.
class InstagramPostInfo {
  final String shortcode;
  final String? username;
  final String? caption;
  final String? thumbnailUrl;
  final bool isReel;

  InstagramPostInfo({
    required this.shortcode,
    this.username,
    this.caption,
    this.thumbnailUrl,
    this.isReel = false,
  });

  bool get hasCaption => caption != null && caption!.trim().isNotEmpty;

  /// AI 분석에 넘길 텍스트를 구성한다.
  String buildContentForAi() {
    final buffer = StringBuffer();
    buffer.writeln('인스타그램 ${isReel ? '릴스' : '게시물'}');
    if (username != null && username!.isNotEmpty) {
      buffer.writeln('작성자: @$username');
    }
    if (hasCaption) {
      buffer.writeln('캡션: $caption');
    } else {
      // 캡션이 없는 사진/영상 위주 게시물 — AI가 참고할 텍스트가 거의 없음을 명시.
      buffer.writeln('캡션 없음 (사진/영상 위주 게시물이라 텍스트 정보가 부족합니다)');
    }
    return buffer.toString();
  }
}

/// 인스타그램 게시물 URL을 파싱해서 작성자/캡션/썸네일을 가져오는 서비스.
///
/// Meta의 공식 Graph API(`instagram_oembed`)는 의도적으로 쓰지 않는다 —
/// 비즈니스 인증 + 앱 리뷰를 통과해도 응답에 캡션(title) 필드 자체가 없고
/// (공개 필드는 html/provider_name/provider_url/type/version/width뿐),
/// 반환되는 embed html도 "front-end 렌더링 전용" 이용약관이 걸려 있어
/// 캡션을 데이터로 추출하는 용도로는 쓸 수 없다.
///
/// 대신 인스타그램은 로그인 없이는 일반 페이지 접근이 막히는 경우가 많아,
/// 블로그/뉴스 사이트 임베드용 페이지(`/embed/captioned/`)를 1순위로,
/// 원본 게시물 페이지의 og:meta 태그를 2순위 폴백으로 스크레이핑한다.
class InstagramService {
  static final InstagramService _instance = InstagramService._internal();
  factory InstagramService() => _instance;
  InstagramService._internal();

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  static const _headers = {
    'User-Agent': _userAgent,
    'Accept-Language': 'ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7',
    // 아래 헤더들은 순수 http 클라이언트 요청이 실제 브라우저 내비게이션처럼
    // 보이게 해서 Instagram의 봇 차단(스크레이핑 방지)에 덜 걸리게 하기 위함.
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Site': 'none',
    'Upgrade-Insecure-Requests': '1',
  };

  final _debug = DebugLogger();

  /// 인스타그램 URL인지 확인.
  bool isInstagramUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.host.contains('instagram.com');
  }

  /// URL에서 shortcode(게시물 고유 코드)와 릴스 여부를 추출.
  /// /p/{shortcode}/, /reel/{shortcode}/, /reels/{shortcode}/, /tv/{shortcode}/ 지원.
  ({String shortcode, bool isReel})? _parseShortcode(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

    for (var i = 0; i < segments.length - 1; i++) {
      final seg = segments[i];
      if (seg == 'p' || seg == 'tv') {
        return (shortcode: segments[i + 1], isReel: false);
      }
      if (seg == 'reel' || seg == 'reels') {
        return (shortcode: segments[i + 1], isReel: true);
      }
    }
    return null;
  }

  /// 게시물 정보(작성자/캡션/썸네일)를 가져온다.
  /// 1순위: 공개 게시물용 embed 페이지 / 2순위: 원본 페이지의 og 메타 태그.
  /// URL이 게시물/릴스 형식이 아니면(스토리, 프로필 등) null을 반환한다.
  Future<InstagramPostInfo?> getPostInfo(String url) async {
    final parsed = _parseShortcode(url);
    if (parsed == null) return null;
    final shortcode = parsed.shortcode;
    final isReel = parsed.isReel;

    // 1순위: embed 페이지 — 공개 게시물은 로그인 없이도 캡션이 그대로 노출됨.
    final embedPath = isReel ? 'reel' : 'p';
    final embedUrl =
        'https://www.instagram.com/$embedPath/$shortcode/embed/captioned/';

    try {
      final response = await http
          .get(Uri.parse(embedUrl), headers: _headers)
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final html = utf8.decode(response.bodyBytes);
        if (_looksBlocked(html)) {
          await _debug.log('Instagram embed 페이지: 로그인 유도 페이지로 차단됨');
        } else {
          final info = _parseEmbedHtml(
            html,
            shortcode: shortcode,
            isReel: isReel,
          );
          if (info != null &&
              (info.hasCaption || info.thumbnailUrl != null)) {
            await _debug.log(
              'Instagram embed 페이지 성공: captionLen=${info.caption?.length ?? 0}',
            );
            return info;
          }
          // 진단용: 실제로 받은 HTML에 Caption/Header 마커 자체가 있었는지
          // 확인 — 없으면 인스타그램이 이 기기/요청에는 아예 다른(축약된)
          // 페이지를 내려준 것이고, 있는데도 실패했으면 파싱 정규식 버그다.
          await _debug.log(
            'Instagram embed 페이지: 200이지만 캡션/썸네일 파싱 실패 '
            '(htmlLen=${html.length}, hasCaptionMarker=${html.contains('class="Caption"')}, '
            'hasHeaderMarker=${html.contains('class="Header"')})',
          );
        }
      } else {
        await _debug.log('Instagram embed 페이지 실패: status=${response.statusCode}');
      }
    } catch (e) {
      await _debug.log('Instagram embed 페이지 예외: $e');
    }

    // 2순위: 원본 게시물 페이지의 og 메타 태그.
    try {
      final response = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final html = utf8.decode(response.bodyBytes);
        if (_looksBlocked(html)) {
          await _debug.log('Instagram 원본 페이지: 로그인 유도 페이지로 차단됨');
        } else {
          final info = _parseOgTags(
            html,
            shortcode: shortcode,
            isReel: isReel,
          );
          if (info != null) {
            await _debug.log(
              'Instagram og태그 성공: captionLen=${info.caption?.length ?? 0}',
            );
            return info;
          }
          await _debug.log(
            'Instagram 원본 페이지: og 태그 파싱 실패 '
            '(htmlLen=${html.length}, hasOgDesc=${html.contains('og:description')})',
          );
        }
      } else {
        await _debug.log('Instagram 원본 페이지 실패: status=${response.statusCode}');
      }
    } catch (e) {
      await _debug.log('Instagram 원본 페이지 예외: $e');
    }

    // 캡션/썸네일을 하나도 못 가져와도 shortcode는 유효하므로
    // 최소 정보(작성자 없음, 캡션 없음)로라도 반환 — 상위에서 fallback 저장용으로 사용.
    await _debug.log('Instagram: 모든 경로 실패, 최소 정보만 반환 (shortcode=$shortcode)');
    return InstagramPostInfo(shortcode: shortcode, isReel: isReel);
  }

  /// Instagram이 비로그인 요청을 차단/리다이렉트할 때 나오는 로그인 유도
  /// 페이지인지 확인한다. 이 경우 실제 게시물과 무관한 텍스트(추천 콘텐츠,
  /// 로그인 폼 등)가 섞여 있을 수 있으므로 통째로 버리고 사용하지 않는다.
  bool _looksBlocked(String html) {
    const markers = [
      'accounts/login',
      'Log in to see',
      'Log In • Instagram',
      '로그인해야',
      'window._sharedData = {}',
      'loginForm',
    ];
    for (final m in markers) {
      if (html.contains(m)) return true;
    }
    return false;
  }

  InstagramPostInfo? _parseEmbedHtml(
    String html, {
    required String shortcode,
    required bool isReel,
  }) {
    // 작성자 — 프로필 링크가 들어있는 헤더 블록에서 추출. 검색 범위를
    // 600자로 제한해 무관한 블록으로 번지지 않게 한다.
    String? username;
    // 인스타그램이 프로필 링크에 ?utm_source=... 같은 쿼리스트링을 붙이는
    // 경우가 있어(예: instagram.com/themukeou/?utm_source=ig_embed), 사용자명
    // 뒤에 바로 따옴표가 아니라 '?'가 올 수도 있다는 걸 허용한다.
    final headerMatch = RegExp(
      r'''class=["']Header["'][\s\S]{0,600}?instagram\.com/([A-Za-z0-9._]+)/?["'?]''',
    ).firstMatch(html);
    if (headerMatch != null) {
      username = headerMatch.group(1);
    }

    // 캡션 — "Caption" 블록 안의 텍스트(HTML 태그 제거).
    // 종료 마커("CaptionComments")를 못 찾으면 문서 끝까지 긁어올 위험이
    // 있으므로 탐색 범위를 4000자로 제한하고, 그래도 종료 마커가 없으면
    // 캡션을 신뢰하지 않는다(엉뚱한 페이지 내용이 섞여 카테고리 오분류로
    // 이어질 수 있음).
    String? caption;
    final captionMatch = RegExp(
      r'''class=["']Caption["'][\s\S]{0,4000}?>([\s\S]{0,4000}?)<div\s+class=["']CaptionComments''',
    ).firstMatch(html);
    if (captionMatch != null) {
      caption = _sanitizeCaption(_stripHtml(captionMatch.group(1)!));
    }

    final ogImage = RegExp(
      r'''<meta\s+[^>]*property=["']og:image["'][^>]*content=["']([^"']*)["']''',
      caseSensitive: false,
    ).firstMatch(html);

    if (username == null && caption == null && ogImage == null) return null;

    return InstagramPostInfo(
      shortcode: shortcode,
      isReel: isReel,
      username: username,
      caption: caption,
      thumbnailUrl: ogImage?.group(1),
    );
  }

  /// 추출한 캡션이 실제 게시물 캡션이 아니라 Instagram 자체 UI 문구/안내
  /// 문구일 가능성이 높으면 버린다(예: 로그인 유도, "게시물 보기" 등
  /// 게시물 내용과 무관한 텍스트가 캡션으로 잘못 추출된 경우).
  String? _sanitizeCaption(String caption) {
    final trimmed = caption.trim();
    if (trimmed.isEmpty) return null;

    const boilerplatePatterns = [
      '로그인',
      '가입하기',
      'Log in',
      'Sign up',
      'JavaScript',
      '쿠키',
      'Cookie',
    ];
    for (final p in boilerplatePatterns) {
      if (trimmed.contains(p)) return null;
    }

    // 너무 길면(실제 캡션이라기엔 비정상적으로 긴 경우) 페이지의 다른
    // 블록이 섞였을 가능성이 있으므로 앞부분만 신뢰한다.
    if (trimmed.length > 1000) {
      return trimmed.substring(0, 1000);
    }
    return trimmed;
  }

  InstagramPostInfo? _parseOgTags(
    String html, {
    required String shortcode,
    required bool isReel,
  }) {
    final ogTitle = RegExp(
      r'''<meta\s+[^>]*property=["']og:title["'][^>]*content=["']([^"']*)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    final ogDesc = RegExp(
      r'''<meta\s+[^>]*property=["']og:description["'][^>]*content=["']([^"']*)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    final ogImage = RegExp(
      r'''<meta\s+[^>]*property=["']og:image["'][^>]*content=["']([^"']*)["']''',
      caseSensitive: false,
    ).firstMatch(html);

    final title = ogTitle?.group(1)?.trim();
    final desc = ogDesc?.group(1)?.trim();

    if ((title == null || title.isEmpty) &&
        (desc == null || desc.isEmpty) &&
        ogImage == null) {
      return null;
    }

    // og:title은 보통 "Username on Instagram" 형식 — 사용자명 추출 시도.
    String? username;
    if (title != null && title.isNotEmpty) {
      final m = RegExp(r'^([^\s(]+)').firstMatch(title);
      if (m != null) username = m.group(1);
    }

    return InstagramPostInfo(
      shortcode: shortcode,
      isReel: isReel,
      username: username,
      caption: (desc != null && desc.isNotEmpty) ? desc : null,
      thumbnailUrl: ogImage?.group(1),
    );
  }

  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
