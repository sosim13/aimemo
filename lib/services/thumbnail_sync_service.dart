import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/memo.dart';

/// Supabase Storage를 통한 메모 이미지 업로드/다운로드 서비스.
///
/// - 업로드: 로컬 메모 이미지를 image 패키지로 리사이즈(최대 800px) + webp 압축 후
///   Supabase Storage의 `memo-images/{userId}/{memoId}.jpg` 경로에 업로드.
/// - 다운로드: 원격에 thumbnail_url이 있고 로컬 파일이 없는 경우 백그라운드에서
///   다운로드하여 path_provider가 제공하는 경로에 저장.
///
/// 모든 작업은 백그라운드에서 비동기로 수행되며, 오류는 debugPrint로만 로깅.
class ThumbnailSyncService {
  static final ThumbnailSyncService _instance =
      ThumbnailSyncService._internal();
  factory ThumbnailSyncService() => _instance;
  ThumbnailSyncService._internal();

  /// Supabase 클라이언트 — 지연 초기화.
  ///
  /// 백그라운드 isolate(main.dart의 backgroundMain)에서는 `Supabase.initialize()`가
  /// 호출되지 않으므로, 생성 시점에 `Supabase.instance`에 접근하면 크래시한다.
  /// 사용 시점에 최초 1회만 접근하고, 미초기화 환경에서는 null(동기화 비활성)을 반환.
  SupabaseClient? _client;

  SupabaseClient? get _clientOrNull {
    if (_client != null) return _client;
    try {
      _client = Supabase.instance.client;
    } catch (_) {
      _client = null; // Supabase 미초기화 — 동기화 비활성으로 진행
    }
    return _client;
  }

  /// 메모 이미지 Storage 버킷 이름.
  static const _memoBucketName = 'memo-images';

  // ---------------------------------------------------------------------------
  // 메모 이미지 (memo-images 버킷)
  // ---------------------------------------------------------------------------

  /// 로컬 메모 이미지를 Supabase Storage에 업로드.
  ///
  /// 800px 리사이즈 + webp 압축 후
  /// `memo-images/{userId}/{memoId}.jpg` 경로에 업로드하고 publicUrl 반환.
  ///
  /// 실패 시 null 반환 (호출자가 처리).
  Future<String?> uploadMemoImage(Memo memo, String userId) async {
    if (userId.isEmpty) {
      debugPrint('[ThumbnailSync] userId가 비어있음 — 메모 이미지 업로드 생략');
      return null;
    }

    // 로컬 이미지 파일이 없으면 업로드 불가
    final localPath = memo.imagePath;
    if (localPath == null || localPath.isEmpty) {
      debugPrint('[ThumbnailSync] memo.imagePath 없음 — 업로드 생략');
      return null;
    }

    final localFile = File(localPath);
    if (!await localFile.exists()) {
      debugPrint('[ThumbnailSync] 로컬 메모 이미지 파일 없음: $localPath');
      return null;
    }

    // Supabase 미초기화(백그라운드 isolate 등) — 업로드 불가
    final client = _clientOrNull;
    if (client == null) {
      debugPrint('[ThumbnailSync] Supabase 미초기화 — 메모 이미지 업로드 생략');
      return null;
    }

    try {
      // 1. 로컬 파일 읽기
      final bytes = await localFile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        debugPrint('[ThumbnailSync] 메모 이미지 디코딩 실패');
        return null;
      }

      // 2. 최대 800px 리사이즈 (비율 유지)
      img.Image resized = decoded;
      const maxDimension = 800;
      if (decoded.width > maxDimension || decoded.height > maxDimension) {
        if (decoded.width >= decoded.height) {
          resized = img.copyResize(decoded, width: maxDimension);
        } else {
          resized = img.copyResize(decoded, height: maxDimension);
        }
      }

      // 3. webp 압축 인코딩
      final encoded = img.encodeWebP(resized);

      // 4. Storage 업로드 경로: memo-images/{userId}/{memoId}.jpg
      final storagePath = '$userId/${memo.memoId}.jpg';
      final appDir = await getApplicationDocumentsDirectory();
      final tempFile = File(p.join(appDir.path, 'temp_${memo.memoId}.webp'));
      await tempFile.writeAsBytes(encoded);
      await client.storage
          .from(_memoBucketName)
          .upload(
            storagePath,
            tempFile,
            fileOptions: const FileOptions(
              contentType: 'image/webp',
              upsert: true,
            ),
          );
      // 임시 파일 삭제
      if (await tempFile.exists()) await tempFile.delete();

      // 5. public URL 반환
      final publicUrl = client.storage
          .from(_memoBucketName)
          .getPublicUrl(storagePath);
      debugPrint('[ThumbnailSync] 메모 이미지 업로드 성공: $publicUrl');
      return publicUrl;
    } catch (e) {
      debugPrint('[ThumbnailSync] 메모 이미지 업로드 실패: $e');
      return null;
    }
  }

  /// 원격 메모 이미지(thumbnail_url)에서 로컬로 다운로드.
  ///
  /// 저장 경로: path_provider의 application documents directory 하위
  /// `memo_images/{memoId}.jpg`.
  ///
  /// 반환값: 다운로드한 로컬 파일 경로. 실패 시 null.
  Future<String?> downloadMemoImage(Memo memo) async {
    final remoteUrl = memo.thumbnailUrl;
    if (remoteUrl == null || remoteUrl.isEmpty) {
      debugPrint('[ThumbnailSync] 메모 thumbnailUrl 없음 — 다운로드 생략');
      return null;
    }

    // 로컬 파일이 이미 있으면 다운로드하지 않음
    if (memo.imagePath != null && memo.imagePath!.isNotEmpty) {
      final localFile = File(memo.imagePath!);
      if (await localFile.exists()) {
        debugPrint('[ThumbnailSync] 로컬 메모 이미지 이미 존재 — 다운로드 생략');
        return memo.imagePath;
      }
    }

    try {
      // 로컬 저장 경로 결정
      final appDir = await getApplicationDocumentsDirectory();
      final imagesDir = Directory(p.join(appDir.path, 'memo_images'));
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }
      final localPath = p.join(imagesDir.path, '${memo.memoId}.jpg');

      // 로컬 파일이 이미 존재하는지 재확인 (경로 계산 후)
      final localFile = File(localPath);
      if (await localFile.exists()) {
        return localPath;
      }

      // Supabase 미초기화(백그라운드 isolate 등) — 다운로드 불가
      final client = _clientOrNull;
      if (client == null) {
        debugPrint('[ThumbnailSync] Supabase 미초기화 — 메모 이미지 다운로드 생략');
        return null;
      }

      // 원격에서 다운로드 — publicUrl에서 storage path 추출
      // publicUrl 형태: https://xxxx.supabase.co/storage/v1/object/public/memo-images/{userId}/{memoId}.jpg
      final storagePath = _extractMemoStoragePath(remoteUrl);
      if (storagePath == null) {
        debugPrint('[ThumbnailSync] 메모 storagePath 추출 실패: $remoteUrl');
        return null;
      }
      final response = await client.storage
          .from(_memoBucketName)
          .download(storagePath);
      await localFile.writeAsBytes(response);

      debugPrint('[ThumbnailSync] 메모 이미지 다운로드 성공: $localPath');
      return localPath;
    } catch (e) {
      debugPrint('[ThumbnailSync] 메모 이미지 다운로드 실패: $e');
      return null;
    }
  }

  /// 메모 publicUrl에서 storage path 추출.
  /// 입력: https://xxxx.supabase.co/storage/v1/object/public/memo-images/{path}
  /// 출력: {path} (memo-images/ 이후 부분)
  static String? _extractMemoStoragePath(String publicUrl) {
    final idx = publicUrl.indexOf('$_memoBucketName/');
    if (idx < 0) return null;
    return publicUrl.substring(idx + _memoBucketName.length + 1);
  }
}
