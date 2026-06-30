import 'dart:convert';
import 'dart:io';

String? extractOgTitle(String html) {
  final regex = RegExp(
    r'''<meta\s+[^>]*property=["']og:title["'][^>]*content=["']([^"']*)["']''',
    caseSensitive: false,
  );
  final match = regex.firstMatch(html);
  return match?.group(1)?.trim();
}

String? extractOgDesc(String html) {
  final regex = RegExp(
    r'''<meta\s+[^>]*property=["']og:description["'][^>]*content=["']([^"']*)["']''',
    caseSensitive: false,
  );
  final match = regex.firstMatch(html);
  return match?.group(1)?.trim();
}

String extractTextContent(String html) {
  var text = html
      .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true, caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true, caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<noscript[^>]*>.*?</noscript>', dotAll: true, caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  
  // Extract Korean blocks (same as WebPageService)
  final blocks = RegExp(r'[가-힣\s.,!?0-9a-zA-Z()@\-_=+#/~\[\]{}%\^&\*]{15,}').allMatches(text);
  if (blocks.isNotEmpty) {
    final extracted = blocks
        .map((m) => m.group(0)!.trim())
        .where((s) => s.length > 10)
        .toList();
    if (extracted.isNotEmpty) {
      text = extracted.join('\n');
    }
  }
  
  if (text.length > 5000) text = text.substring(0, 5000);
  return text.trim();
}

Future<void> main() async {
  final url = 'https://m.10000recipe.com/recipe/6944392';
  
  // Test: Dart HttpClient
  print('=== Test: Dart HttpClient ===');
  try {
    final client = HttpClient();
    client.userAgent = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
    request.headers.set('Accept-Language', 'ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7');
    request.followRedirects = true;
    
    final response = await request.close().timeout(Duration(seconds: 15));
    print('Status: ${response.statusCode}');
    print('Content-Type: ${response.headers.contentType}');
    print('Headers:');
    response.headers.forEach((name, values) {
      print('  $name: $values');
    });
    
    if (response.statusCode == 200) {
      final body = await response.transform(utf8.decoder).join();
      print('Body length: ${body.length}');
      
      final title = extractOgTitle(body);
      final desc = extractOgDesc(body);
      print('og:title: $title');
      print('og:desc: ${desc?.length ?? 0} chars');
      
      final extracted = extractTextContent(body);
      print('Extracted content length: ${extracted.length}');
      if (extracted.length > 0) {
        print('Preview (first 500 chars):');
        print(extracted.substring(0, extracted.length > 500 ? 500 : extracted.length));
      } else {
        print('EMPTY - this is the bug!');
        
        // Debug: show raw stripped text
        var raw = body
            .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true, caseSensitive: false), ' ')
            .replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true, caseSensitive: false), ' ')
            .replaceAll(RegExp(r'<noscript[^>]*>.*?</noscript>', dotAll: true, caseSensitive: false), ' ')
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        print('Raw stripped length: ${raw.length}');
        print('Raw preview: ${raw.substring(0, raw.length > 300 ? 300 : raw.length)}');
        
        // Check all matches of Korean block regex
        final blocks = RegExp(r'[가-힣\s.,!?0-9a-zA-Z()@\-_=+#/~\[\]{}%\^&\*]{15,}').allMatches(raw);
        print('Number of 15+ char blocks: ${blocks.length}');
        for (int i = 0; i < blocks.length && i < 5; i++) {
          final m = blocks.elementAt(i);
          print('  Block $i: len=${m.group(0)!.length}, text=${m.group(0)!.trim().substring(0, (m.group(0)!.trim().length > 50 ? 50 : m.group(0)!.trim().length))}');
        }
      }
    } else {
      print('Unexpected status: ${response.statusCode}');
    }
    client.close();
  } catch (e, st) {
    print('Error: $e');
    print('Stack: $st');
  }
}
