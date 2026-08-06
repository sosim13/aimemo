import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'gemma_provider.dart';
import 'llm_service.dart';

/// Result of a full recognize + crop pass for a single book-cover scan.
class ScanResult {
  final String title;
  final String author;

  /// Absolute path to the cropped + saved thumbnail JPEG.
  final String thumbnailPath;

  ScanResult({
    required this.title,
    required this.author,
    required this.thumbnailPath,
  });
}

/// High-level orchestration for the Reading Tracker's camera scan step.
///
/// Pipeline:
///   1. [recognize] — feed captured JPEG bytes to Gemma 4 E2B vision and
///      get back title / author / bbox.
///   2. [cropAndSaveThumbnail] — crop the original image to the bbox and
///      persist a compressed thumbnail JPEG in the app docs directory.
///
/// Returns a complete [ScanResult] (or null when the image is not a book).
class BookVisionService {
  static final BookVisionService _instance = BookVisionService._internal();
  factory BookVisionService() => _instance;
  BookVisionService._internal();

  final _llmService = LlmService();

  /// Runs the entire scan pipeline on a captured image file:
  /// recognize → crop → save thumbnail. Returns null when the image is not
  /// a recognizable book cover.
  Future<ScanResult?> scanBookCover(String capturedImagePath) async {
    final imageBytes = await File(capturedImagePath).readAsBytes();

    final vision = _llmService.gemmaProvider;
    BookVisionResult? result;
    try {
      result = await vision.analyzeImage(Uint8List.fromList(imageBytes));
    } catch (e) {
      // Fall through to null — caller shows the "not recognized" error.
      result = null;
    }
    if (result == null || result.title.isEmpty) {
      return null;
    }

    // Crop the original image to the bbox (if any) and persist a thumbnail.
    final thumbnailPath = await cropAndSaveThumbnail(
      imageBytes: imageBytes,
      bbox: result.bbox,
      filePrefix: _safeFileName(result.title),
    );

    return ScanResult(
      title: result.title,
      author: result.author,
      thumbnailPath: thumbnailPath,
    );
  }

  /// Crops an image to the given normalized [bbox] = [y1, x1, y2, x2].
  /// When [bbox] is empty or invalid, the whole image is used as-is.
  /// The cropped image is resized so its longest side is at most
  /// [_maxThumbnailSide] pixels, JPEG-compressed, and saved to the app's
  /// documents directory. Returns the absolute path to the saved file.
  Future<String> cropAndSaveThumbnail({
    required Uint8List imageBytes,
    required List<double> bbox,
    required String filePrefix,
  }) async {
    var image = img.decodeImage(imageBytes);
    if (image == null) {
      // Can't decode — fall back to writing the raw bytes.
      return _writeFallback(imageBytes, filePrefix, '.jpg');
    }

    // Apply the bbox crop when 4 valid normalized coords were returned.
    if (bbox.length == 4) {
      final y1 = (bbox[0].clamp(0.0, 1.0) * image.height).round();
      final x1 = (bbox[1].clamp(0.0, 1.0) * image.width).round();
      final y2 = (bbox[2].clamp(0.0, 1.0) * image.height).round();
      final x2 = (bbox[3].clamp(0.0, 1.0) * image.width).round();
      final cropW = x2 - x1;
      final cropH = y2 - y1;
      if (cropW > 8 && cropH > 8) {
        image = img.copyCrop(
          image,
          x: x1,
          y: y1,
          width: cropW,
          height: cropH,
        );
      }
    }

    // Downscale to a thumbnail-friendly size.
    final longest = image.width > image.height
        ? image.width
        : image.height;
    if (longest > _maxThumbnailSide) {
      image = img.copyResize(
        image,
        width: image.width > image.height ? _maxThumbnailSide : null,
        height: image.height >= image.width ? _maxThumbnailSide : null,
        maintainAspect: true,
      );
    }

    final jpeg = img.encodeJpg(image, quality: 85);
    return _writeFallback(Uint8List.fromList(jpeg), filePrefix, '.jpg');
  }

  static const int _maxThumbnailSide = 512;

  Future<String> _writeFallback(
    Uint8List bytes,
    String filePrefix,
    String ext,
  ) async {
    final dir = await getApplicationDocumentsDirectory();
    final readingDir = Directory(p.join(dir.path, 'reading_thumbnails'));
    if (!await readingDir.exists()) {
      await readingDir.create(recursive: true);
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = '${filePrefix}_$timestamp$ext';
    final filePath = p.join(readingDir.path, fileName);
    final file = File(filePath);
    await file.writeAsBytes(bytes, flush: true);
    return filePath;
  }

  /// Sanitize a book title to a safe filesystem token.
  static String _safeFileName(String title) {
    final safe = title
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty
        ? 'book'
        : (safe.length > 40 ? safe.substring(0, 40) : safe);
  }
}
