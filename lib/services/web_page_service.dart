import 'dart:convert';
import 'package:http/http.dart' as http;
import 'debug_logger.dart';

class WebPageInfo {
  final String url;
  final String title;
  final String description;
  final String textContent;

  WebPageInfo({
    required this.url,
    required this.title,
    required this.description,
    required this.textContent,
  });
}

class WebPageService {
  static final WebPageService _instance = WebPageService._internal();
  factory WebPageService() => _instance;
  WebPageService._internal();

  final _debug = DebugLogger();

  final _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7',
  };

  Future<WebPageInfo?> fetchPageContent(String url) async {
    try {
      final fetchUrl = _normalizeUrl(url);
      await _debug.log('WPS: Fetching $fetchUrl');

      final response = await http.get(Uri.parse(fetchUrl), headers: _headers);
      await _debug.log(
          'WPS: Status ${response.statusCode}, body length: ${response.bodyBytes.length}');

      if (response.statusCode != 200) {
        await _debug.log(
            'WPS: Non-200 status, body preview: ${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}');
        return null;
      }

      var html = utf8.decode(response.bodyBytes);
      await _debug.log('WPS: Decoded HTML length: ${html.length}');

      // Save original HTML — only replace it with redirect result if original is barren
      final originalHtml = html;
      final originalTitle = _extractTitle(originalHtml);

      final jsRedirect = _extractJsRedirect(html);
      if (jsRedirect != null) {
        await _debug.log('WPS: JS redirect to $jsRedirect');
        // Resolve relative redirect URLs against the original fetch URL
        final baseUri = Uri.parse(fetchUrl);
        final resolvedUri = baseUri.resolve(jsRedirect);
        if (resolvedUri.host.isNotEmpty &&
            resolvedUri.toString() != fetchUrl) {
          try {
            final redirectResponse =
                await http.get(resolvedUri, headers: _headers);
            if (redirectResponse.statusCode == 200) {
              final redirectHtml = utf8.decode(redirectResponse.bodyBytes);
              // Only replace if original page had no meaningful content
              // (e.g. JS redirect from a thin interstitial to the real page)
              final hasOriginalContent =
                  originalTitle.isNotEmpty || originalHtml.length > 5000;
              if (!hasOriginalContent) {
                html = redirectHtml;
                await _debug.log(
                    'WPS: Original was empty, used redirect HTML (len=${redirectHtml.length})');
              } else {
                html = originalHtml;
                await _debug.log(
                    'WPS: Original has content, KEPT original HTML (redirect to $jsRedirect ignored)');
              }
            }
          } catch (e) {
            await _debug.log(
                'WPS: Redirect fetch failed: $e — continuing with original HTML');
            html = originalHtml;
          }
        } else {
          await _debug.log(
              'WPS: Redirect URL "$jsRedirect" has no host or same as fetch URL — continuing with original HTML');
          html = originalHtml;
        }
      }

      final title = _extractTitle(html);
      final description = _extractDescription(html);
      final textContent = _extractTextContent(html);
      await _debug.log(
          'WPS: title="$title" desc_len=${description.length} text_len=${textContent.length}');

      if (title.isEmpty && textContent.isEmpty) {
        await _debug.log('WPS: Both title and textContent empty, returning null');
        return null;
      }

      return WebPageInfo(
        url: url,
        title: title,
        description: description,
        textContent: textContent,
      );
    } catch (e) {
      await _debug.log('WPS: Exception: $e');
      return null;
    }
  }

  String _normalizeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;

    if (uri.host == 'blog.naver.com') {
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length >= 2) {
        final blogId = segments[0];
        final logNo = segments[1];
        return 'https://m.blog.naver.com/PostView.naver?blogId=$blogId&logNo=$logNo';
      }
    }

    return url;
  }

  String? _extractJsRedirect(String html) {
    final patterns = [
      RegExp(r"""top\.location\.replace\(['"]([^'"]+)['"]\)"""),
      RegExp(r"""location\.href\s*=\s*['"]([^'"]+)['"]"""),
      RegExp(r"""location\.replace\(['"]([^'"]+)['"]\)"""),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null) {
        var redirectUrl = match.group(1)!;
        redirectUrl = redirectUrl.replaceAll('\\/', '/');
        return redirectUrl;
      }
    }

    return null;
  }

  String _extractTitle(String html) {
    final ogTitle = RegExp(
      r"""<meta\s+[^>]*property=["']og:title["'][^>]*content=["']([^"']*)["']""",
      caseSensitive: false,
    ).firstMatch(html);
    if (ogTitle != null) {
      final t = ogTitle.group(1)?.trim();
      if (t != null && t.isNotEmpty) return t;
    }

    final titleMatch =
        RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false)
            .firstMatch(html);
    if (titleMatch != null) {
      return titleMatch.group(1)?.trim() ?? '';
    }

    return '';
  }

  String _extractDescription(String html) {
    final ogDesc = RegExp(
      r"""<meta\s+[^>]*property=["']og:description["'][^>]*content=["']([^"']*)["']""",
      caseSensitive: false,
    ).firstMatch(html);
    if (ogDesc != null) {
      final d = ogDesc.group(1)?.trim();
      if (d != null && d.isNotEmpty) return d;
    }

    final metaDesc = RegExp(
      r"""<meta\s+[^>]*name=["']description["'][^>]*content=["']([^"']*)["']""",
      caseSensitive: false,
    ).firstMatch(html);
    if (metaDesc != null) {
      return metaDesc.group(1)?.trim() ?? '';
    }

    return '';
  }

  String _extractTextContent(String html) {
    // 1. Extract <body> content first for focused processing
    var text = html;
    final bodyMatch = RegExp(r'<body[^>]*>(.*?)</body>',
            caseSensitive: false, dotAll: true)
        .firstMatch(html);
    if (bodyMatch != null) {
      text = bodyMatch.group(1)!;
    }

    // 2. Remove all script, style, noscript, svg, canvas, iframe, nav, footer
    for (final tag in [
      'script', 'style', 'noscript', 'svg', 'canvas',
      'iframe', 'nav', 'footer', 'header', 'aside',
    ]) {
      // Run twice: some scripts may contain </script> inside JS strings
      text = text.replaceAll(
          RegExp('<$tag[^>]*>.*?</$tag>',
              caseSensitive: false, dotAll: true),
          ' ');
      text = text.replaceAll(
          RegExp('<$tag[^>]*>.*?</$tag>',
              caseSensitive: false, dotAll: true),
          ' ');
    }

    // 3. Remove HTML comments
    text = text.replaceAll(
        RegExp(r'<!--.*?-->', caseSensitive: false, dotAll: true), ' ');

    // 4. Remove remaining HTML tags
    text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');

    // 5. Decode HTML entities
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&#x2F;', '/');

    final numericEntity = RegExp(r'&#(\d+);');
    while (true) {
      final match = numericEntity.firstMatch(text);
      if (match == null) break;
      final code = int.tryParse(match.group(1) ?? '');
      if (code != null) {
        text = text.replaceFirst(match.group(0)!, String.fromCharCode(code));
      } else {
        break;
      }
    }

    // 6. Collapse whitespace
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 7. Post-processing: remove JS code patterns that may survive tag removal
    text = text.replaceAll(
        RegExp(r'function\s*\([^)]*\)\s*\{[^}]*\}',
            caseSensitive: false, dotAll: true),
        ' ');
    text = text.replaceAll(
        RegExp(r'\(function\s*\([^)]*\)\s*\{', caseSensitive: false),
        ' ');
    text = text.replaceAll(
        RegExp(r'\}\s*\)\s*\([^)]*\)\s*[;.]?\s*', caseSensitive: false),
        ' ');
    text = text.replaceAll(
        RegExp(
            r'\b(var|let|const|new\s+Promise|async\s+function|module\.exports|export\s+default|import\s+)\s',
            caseSensitive: false),
        ' ');
    text = text.replaceAll(
        RegExp(r'\w+\.(appendChild|addEventListener|getElementById|querySelector|createElement|setAttribute|getAttribute)\([^)]*\)',
            caseSensitive: false),
        ' ');
    text = text.replaceAll(
        RegExp(r'JSON\.\s*(parse|stringify)\s*\([^)]*\)', caseSensitive: false),
        ' ');
    text = text.replaceAll(
        RegExp(r'(document|window|console|localStorage|sessionStorage)\s*\.\s*\w+\s*\([^)]*\)',
            caseSensitive: false),
        ' ');

    // 8. Remove CSS-like fragments and URLs
    text = text.replaceAll(
        RegExp(r'[\w-]+\s*:\s*[^;]+;'), ' ');
    text = text.replaceAll(
        RegExp(r'https?://\S+', caseSensitive: false), ' ');

    // 9. Strip lines that are too short or are just numbers/symbols
    final lines = text.split('\n')
        .map((l) => l.trim())
        .where((l) => l.length >= 8)
        .where((l) => RegExp(r'[가-힣]').hasMatch(l))
        .toList();
    if (lines.isNotEmpty) {
      text = lines.join('\n');
    }

    // 10. Deduplicate consecutive identical lines
    text = text.replaceAll(RegExp(r'^(.+)\n\1$', multiLine: true), r'$1');

    // 11. Extract meaningful Korean text blocks
    // Use a stricter regex that prefers Korean-centric content
    final blocks = RegExp(
            r'[가-힣\s.,!?0-9a-zA-Z()@\-_+=/#~%\^&]{15,}')
        .allMatches(text);
    if (blocks.isNotEmpty) {
      final extracted = blocks
          .map((m) => m.group(0)!.trim())
          .where((s) => s.length > 10)
          .where((s) {
            // Filter out lines that are mostly code (too many special chars)
            final codeCharCount =
                RegExp(r'[{}();=\[\]/\\]').allMatches(s).length;
            return codeCharCount < s.length * 0.1; // < 10% special chars
          })
          .toList();
      if (extracted.isNotEmpty) {
        text = extracted.join('\n');
      }
    }
    if (text.length > 5000) {
      text = text.substring(0, 5000);
    }

    return text.trim();
  }
}
