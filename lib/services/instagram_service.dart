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
///
/// embed 페이지 안에서도 캡션 위치가 두 군데다:
///  - `contextJSON` 스크립트 데이터(gql_data.shortcode_media) — 가장 안정적.
///    요청 조건(UA 등)에 따라 아래 Caption div가 빠진 페이지가 와도 대개 들어 있다.
///  - 서버 렌더링된 `<div class="Caption">` 블록 — 보조 경로.
///
/// 인스타그램은 User-Agent에 따라 전혀 다른 페이지(데이터 없는 JS 셸)를
/// 내려주기도 하므로, 캡션을 못 찾으면 다른 UA로 한 번 더 시도한다.
class InstagramService {
  static final InstagramService _instance = InstagramService._internal();
  factory InstagramService() => _instance;
  InstagramService._internal();

  /// 순서대로 시도할 User-Agent. 데스크톱 Chrome UA는 데이터 없는 JS 셸
  /// 페이지를 받으므로 넣지 않는다.
  static const _userAgents = [
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
  ];

  static Map<String, String> _headersFor(String userAgent) => {
    'User-Agent': userAgent,
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
  /// 1순위: 공개 게시물용 embed 페이지(UA를 바꿔가며) / 2순위: 원본 페이지의 og 메타 태그.
  /// URL이 게시물/릴스 형식이 아니면(스토리, 프로필 등) null을 반환한다.
  Future<InstagramPostInfo?> getPostInfo(String url) async {
    final parsed = _parseShortcode(url);
    if (parsed == null) return null;
    final shortcode = parsed.shortcode;
    final isReel = parsed.isReel;

    // 캡션은 못 찾았지만 작성자/썸네일은 얻은 경우를 기억해 뒀다가 최종 폴백에 쓴다.
    InstagramPostInfo? partial;

    // 1순위: embed 페이지 — 공개 게시물은 로그인 없이도 캡션이 그대로 노출됨.
    final embedPath = isReel ? 'reel' : 'p';
    final embedUrl =
        'https://www.instagram.com/$embedPath/$shortcode/embed/captioned/';

    for (var i = 0; i < _userAgents.length; i++) {
      final html = await _fetch(embedUrl, _userAgents[i], 'embed#$i');
      if (html == null) continue;

      final info = _parseEmbedHtml(html, shortcode: shortcode, isReel: isReel);
      if (info != null && info.hasCaption) {
        await _debug.log(
          'Instagram embed#$i 성공: captionLen=${info.caption!.length}',
        );
        return info;
      }
      partial = _merge(partial, info);
      // 진단용: 실제로 받은 HTML에 캡션 데이터 마커가 있었는지 확인 —
      // 없으면 인스타그램이 이 요청에는 다른(축약된) 페이지를 내려준 것이고,
      // 있는데도 실패했으면 파싱 버그다.
      await _debug.log(
        'Instagram embed#$i: 캡션 파싱 실패 '
        '(htmlLen=${html.length}, hasContextJson=${html.contains('contextJSON')}, '
        'hasCaptionMarker=${html.contains('class="Caption"')})',
      );
    }

    // 2순위: 원본 게시물 페이지의 og 메타 태그.
    for (var i = 0; i < _userAgents.length; i++) {
      final html = await _fetch(url, _userAgents[i], 'page#$i');
      if (html == null) continue;

      final info = _parseOgTags(html, shortcode: shortcode, isReel: isReel);
      if (info != null && info.hasCaption) {
        await _debug.log(
          'Instagram og태그 성공(page#$i): captionLen=${info.caption!.length}',
        );
        return _merge(info, partial);
      }
      partial = _merge(partial, info);
      await _debug.log(
        'Instagram page#$i: og 태그 캡션 없음 '
        '(htmlLen=${html.length}, hasOgDesc=${html.contains('og:description')})',
      );
      // 원본 페이지는 무겁고(수백 KB) UA별 차이가 거의 없으므로 한 번만 시도.
      break;
    }

    // 캡션을 못 가져와도 shortcode는 유효하므로 얻은 만큼(작성자/썸네일)이라도
    // 반환 — 상위에서 fallback 저장용으로 사용.
    await _debug.log('Instagram: 캡션 추출 실패, 부분 정보만 반환 (shortcode=$shortcode)');
    return partial ?? InstagramPostInfo(shortcode: shortcode, isReel: isReel);
  }

  Future<String?> _fetch(String url, String userAgent, String label) async {
    try {
      final response = await http
          .get(Uri.parse(url), headers: _headersFor(userAgent))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        await _debug.log('Instagram $label 실패: status=${response.statusCode}');
        return null;
      }
      final html = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (_looksBlocked(html)) {
        await _debug.log('Instagram $label: 로그인 유도 페이지로 차단됨');
        return null;
      }
      return html;
    } catch (e) {
      await _debug.log('Instagram $label 예외: $e');
      return null;
    }
  }

  /// [a]를 우선하되 비어 있는 필드는 [b]로 채운다.
  InstagramPostInfo? _merge(InstagramPostInfo? a, InstagramPostInfo? b) {
    if (a == null) return b;
    if (b == null) return a;
    return InstagramPostInfo(
      shortcode: a.shortcode,
      isReel: a.isReel,
      username: a.username ?? b.username,
      caption: a.hasCaption ? a.caption : b.caption,
      thumbnailUrl: a.thumbnailUrl ?? b.thumbnailUrl,
    );
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
    final fromJson = _parseContextJson(
      html,
      shortcode: shortcode,
      isReel: isReel,
    );
    if (fromJson != null && fromJson.hasCaption) return fromJson;

    // 작성자 — 캡션 앞의 사용자명 링크, 없으면 프로필 링크가 들어있는
    // 헤더 블록에서 추출. 검색 범위를 600자로 제한해 무관한 블록으로
    // 번지지 않게 한다. 인스타그램이 프로필 링크에 ?utm_source=... 같은
    // 쿼리스트링을 붙이는 경우가 있어 사용자명 뒤에 '?'가 올 수도 있다.
    String? username;
    final captionUserMatch = RegExp(
      r'''class=["']CaptionUsername["'][^>]*>([^<]+)</a>''',
    ).firstMatch(html);
    final headerMatch = RegExp(
      r'''class=["']Header["'][\s\S]{0,600}?instagram\.com/([A-Za-z0-9._]+)/?["'?]''',
    ).firstMatch(html);
    username =
        captionUserMatch?.group(1)?.trim() ?? headerMatch?.group(1);

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
      // 캡션 맨 앞의 사용자명 링크는 본문이 아니므로 제거.
      final body = captionMatch.group(1)!.replaceFirst(
        RegExp(r'''<a\s+class=["']CaptionUsername["'][\s\S]*?</a>'''),
        '',
      );
      caption = _sanitizeCaption(_stripHtml(body));
    }

    // 썸네일 — embed 페이지에는 og:image가 없고 본문 이미지 태그에 있다.
    final mediaImage = RegExp(
      r'''class=["']EmbeddedMediaImage["'][^>]*src=["']([^"']+)["']''',
    ).firstMatch(html);
    final ogImage = _metaContent(html, 'og:image');
    final thumbnail = mediaImage != null
        ? _decodeEntities(mediaImage.group(1)!)
        : ogImage;

    final fromHtml = (username == null && caption == null && thumbnail == null)
        ? null
        : InstagramPostInfo(
            shortcode: shortcode,
            isReel: isReel,
            username: username,
            caption: caption,
            thumbnailUrl: thumbnail,
          );
    return _merge(fromHtml, fromJson);
  }

  /// embed 페이지에 스크립트 데이터로 들어있는 `contextJSON`(문자열로 한 번 더
  /// 감싼 JSON)에서 게시물 정보를 꺼낸다.
  InstagramPostInfo? _parseContextJson(
    String html, {
    required String shortcode,
    required bool isReel,
  }) {
    try {
      final raw = _extractJsonStringValue(html, 'contextJSON');
      if (raw == null) return null;
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      final media = (data['gql_data'] as Map?)?['shortcode_media'] as Map?;
      if (media == null) return null;

      String? caption;
      final edges =
          (media['edge_media_to_caption'] as Map?)?['edges'] as List?;
      if (edges != null && edges.isNotEmpty) {
        final text = ((edges.first as Map)['node'] as Map?)?['text'];
        if (text is String) caption = _sanitizeCaption(text);
      }
      // 캡션이 없는 사진 게시물은 인스타그램 자동 대체텍스트라도 활용.
      final accessibility = media['accessibility_caption'];
      if (caption == null && accessibility is String) {
        caption = _sanitizeCaption(accessibility);
      }

      final owner = media['owner'] as Map?;
      final thumbnail = media['display_url'] ?? media['thumbnail_src'];

      return InstagramPostInfo(
        shortcode: shortcode,
        isReel: isReel || media['is_video'] == true,
        username: owner?['username'] as String?,
        caption: caption,
        thumbnailUrl: thumbnail is String ? thumbnail : null,
      );
    } catch (e) {
      _debug.log('Instagram contextJSON 파싱 예외: $e');
      return null;
    }
  }

  /// HTML 안의 `"key":"..."` 형태 JSON 문자열 값을 찾아 디코딩해 반환한다.
  /// 값 안의 이스케이프(\" 등)를 건너뛰며 닫는 따옴표를 찾는다.
  String? _extractJsonStringValue(String html, String key) {
    final marker = '"$key":"';
    final start = html.indexOf(marker);
    if (start < 0) return null;
    final buffer = StringBuffer('"');
    var i = start + marker.length;
    while (i < html.length) {
      final c = html[i];
      if (c == r'\' && i + 1 < html.length) {
        buffer
          ..write(c)
          ..write(html[i + 1]);
        i += 2;
        continue;
      }
      if (c == '"') {
        buffer.write('"');
        return jsonDecode(buffer.toString()) as String;
      }
      buffer.write(c);
      i++;
    }
    return null;
  }

  /// 추출한 캡션이 실제 게시물 캡션이 아니라 Instagram 자체 UI 문구/안내
  /// 문구일 가능성이 높으면 버린다(예: 로그인 유도, "게시물 보기" 등
  /// 게시물 내용과 무관한 텍스트가 캡션으로 잘못 추출된 경우).
  String? _sanitizeCaption(String caption) {
    final trimmed = caption.trim();
    if (trimmed.isEmpty) return null;

    const boilerplatePatterns = [
      'Log in to',
      'Sign up to',
      'JavaScript',
      'Cookie',
      '로그인하여',
      '가입하여',
    ];
    for (final p in boilerplatePatterns) {
      if (trimmed.contains(p)) return null;
    }

    // 너무 길면 AI 입력이 과도해지므로 앞부분만 사용.
    if (trimmed.length > 2000) {
      return trimmed.substring(0, 2000);
    }
    return trimmed;
  }

  InstagramPostInfo? _parseOgTags(
    String html, {
    required String shortcode,
    required bool isReel,
  }) {
    final title = _metaContent(html, 'og:title');
    final desc = _metaContent(html, 'og:description');
    final image = _metaContent(html, 'og:image');

    if ((title == null || title.isEmpty) &&
        (desc == null || desc.isEmpty) &&
        image == null) {
      return null;
    }

    // og:description은 보통 `830 likes, 46 comments - user - September 14, 2026: "캡션"`
    // 형식이다(한국어 로케일이면 문구만 다름). 작성자와 따옴표 안 캡션을 분리한다.
    String? username;
    String? caption;
    if (desc != null && desc.isNotEmpty) {
      final m = RegExp(r'^[^\n]*? - ([A-Za-z0-9._]+) - [^\n]*?: "([\s\S]*)"\s*\.?$')
          .firstMatch(desc);
      if (m != null) {
        username = m.group(1);
        caption = _sanitizeCaption(m.group(2)!);
      } else {
        caption = _sanitizeCaption(desc);
      }
    }
    if (username == null && title != null) {
      final m = RegExp(r'\(@([A-Za-z0-9._]+)\)').firstMatch(title);
      username = m?.group(1);
    }

    return InstagramPostInfo(
      shortcode: shortcode,
      isReel: isReel,
      username: username,
      caption: caption,
      thumbnailUrl: image,
    );
  }

  /// `<meta property|name="{name}" content="...">`의 content 값(엔티티 디코딩).
  /// 속성 순서(content가 앞에 오는 경우)와 무관하게 찾는다.
  String? _metaContent(String html, String name) {
    final tag = RegExp(
      '<meta\\s[^>]*(?:property|name)=["\']${RegExp.escape(name)}["\'][^>]*>',
      caseSensitive: false,
    ).firstMatch(html);
    if (tag == null) return null;
    final content = RegExp(r'''content="([^"]*)"|content='([^']*)' ''')
        .firstMatch(tag.group(0)!);
    final value = content?.group(1) ?? content?.group(2);
    if (value == null) return null;
    final decoded = _decodeEntities(value).trim();
    return decoded.isEmpty ? null : decoded;
  }

  String _stripHtml(String html) {
    final text = html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), ' ');
    return _decodeEntities(text)
        .replaceAll(RegExp(r'[ \t ]+'), ' ')
        .replaceAll(RegExp(r' *\n *'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// `&#xc6d0;`, `&#064;`, `&amp;` 등 HTML 엔티티를 문자로 변환한다.
  /// 인스타그램 og 태그/캡션의 한글은 대부분 숫자 엔티티로 인코딩돼 있다.
  String _decodeEntities(String text) {
    const named = {
      'amp': '&',
      'quot': '"',
      'apos': "'",
      'lt': '<',
      'gt': '>',
      'nbsp': ' ',
    };
    return text.replaceAllMapped(
      RegExp(r'&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'),
      (m) {
        final entity = m.group(1)!;
        if (entity.startsWith('#')) {
          final isHex = entity.length > 1 && (entity[1] == 'x' || entity[1] == 'X');
          final code = int.tryParse(
            isHex ? entity.substring(2) : entity.substring(1),
            radix: isHex ? 16 : 10,
          );
          if (code == null || code > 0x10FFFF) return m.group(0)!;
          return String.fromCharCode(code);
        }
        return named[entity] ?? m.group(0)!;
      },
    );
  }
}
