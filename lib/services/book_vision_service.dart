import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

/// Detected corners from a book cover image, in normalized coordinates
/// (0.0 ~ 1.0) relative to the image dimensions. Ordered [TL, TR, BR, BL].
class DetectedCorners {
  final double x1, y1; // TL
  final double x2, y2; // TR
  final double x3, y3; // BR
  final double x4, y4; // BL

  /// true when OpenCV found a valid quadrilateral; false when using
  /// default corners (full image with small inset).
  final bool isDetected;

  const DetectedCorners({
    required this.x1, required this.y1,
    required this.x2, required this.y2,
    required this.x3, required this.y3,
    required this.x4, required this.y4,
    required this.isDetected,
  });

  /// Default corners covering ~90% of the image (slight inset).
  factory DetectedCorners.defaultCorners() {
    return const DetectedCorners(
      x1: 0.05, y1: 0.05,  // TL
      x2: 0.95, y2: 0.05,  // TR
      x3: 0.95, y3: 0.95,  // BR
      x4: 0.05, y4: 0.95,  // BL
      isDetected: false,
    );
  }

  List<({double x, double y})> toList() => [
    (x: x1, y: y1), (x: x2, y: y2), (x: x3, y: y3), (x: x4, y: y4),
  ];

  /// Copy with new coordinates (keep isDetected).
  DetectedCorners copyWith({
    double? x1, double? y1, double? x2, double? y2,
    double? x3, double? y3, double? x4, double? y4,
    bool? isDetected,
  }) {
    return DetectedCorners(
      x1: x1 ?? this.x1, y1: y1 ?? this.y1,
      x2: x2 ?? this.x2, y2: y2 ?? this.y2,
      x3: x3 ?? this.x3, y3: y3 ?? this.y3,
      x4: x4 ?? this.x4, y4: y4 ?? this.y4,
      isDetected: isDetected ?? this.isDetected,
    );
  }
}

/// Result record returned by [BookVisionService.detectCornersWithDebug] and
/// the internal `_findCornersInGrayMat` helper.
typedef CornersResult = ({DetectedCorners corners, Uint8List? debugImage});

/// High-level orchestration for the Reading Tracker's camera scan step.
class BookVisionService {
  static final BookVisionService _instance = BookVisionService._internal();
  factory BookVisionService() => _instance;
  BookVisionService._internal();

  final _latinRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final _koreanRecognizer = TextRecognizer(script: TextRecognitionScript.korean);

  // ─── Corner detection ─────────────────────────────────────────────

  /// Detects corners from a raw Y-plane (grayscale) bytes from CameraImage.
  /// This is faster than decoding JPEG because it skips the JPEG decode step.
  /// [yBytes] is the Y plane bytes, [width] and [height] are the image
  /// dimensions, [yStride] is the row stride (may be > width due to padding).
  ///
  /// [sensorOrientation] is the camera sensor orientation reported by
  /// `CameraDescription.sensorOrientation`. When it is 90 (the typical value
  /// for back cameras on Android phones), the Y plane is rotated 90°
  /// clockwise so the detected corners are in display coordinates — i.e. the
  /// normalized 0~1 output maps directly to the camera preview's width/height.
  DetectedCorners detectCornersFromYPlane(
    Uint8List yBytes, int width, int height,
    {required int yStride, int sensorOrientation = 90}) {
    return _detectFromYPlane(yBytes, width, height,
        yStride: yStride, sensorOrientation: sensorOrientation,
        returnDebug: false).corners;
  }

  /// Same pipeline as [detectCornersFromYPlane] but additionally returns a
  /// JPEG-encoded preview of the edge image used for contour detection, so
  /// the caller can show a small debug overlay on the camera screen. The
  /// debugImage is `null` when no edge image was produced.
  CornersResult detectCornersWithDebug(
    Uint8List yBytes, int width, int height,
    {required int yStride, int sensorOrientation = 90}) {
    return _detectFromYPlane(yBytes, width, height,
        yStride: yStride, sensorOrientation: sensorOrientation,
        returnDebug: true);
  }

  /// Shared implementation for both [detectCornersFromYPlane] and
  /// [detectCornersWithDebug]. See those methods for documentation.
  CornersResult _detectFromYPlane(
    Uint8List yBytes, int width, int height,
    {required int yStride, required int sensorOrientation,
     required bool returnDebug}) {
    // Create a single-channel Mat from the Y plane.
    cv.Mat gray;
    if (yStride == width) {
      gray = cv.Mat.fromList(height, width, cv.MatType.CV_8UC1, yBytes);
    } else {
      final tightBytes = Uint8List(width * height);
      for (var row = 0; row < height; row++) {
        final srcOffset = row * yStride;
        final dstOffset = row * width;
        tightBytes.setRange(dstOffset, dstOffset + width, yBytes, srcOffset);
      }
      gray = cv.Mat.fromList(height, width, cv.MatType.CV_8UC1, tightBytes);
    }

    // Rotate the Y plane into display orientation. The camera sensor is
    // typically mounted 90° clockwise relative to the display on Android, so
    // rotating the sensor-domain Mat 90° CW makes its coordinate system
    // match the preview the user sees. Corners are then normalized against
    // this rotated Mat and map directly to the preview width/height.
    cv.Mat rotated;
    if (sensorOrientation == 90) {
      rotated = cv.rotate(gray, cv.ROTATE_90_CLOCKWISE);
      gray.dispose();
    } else if (sensorOrientation == 180) {
      rotated = cv.rotate(gray, cv.ROTATE_180);
      gray.dispose();
    } else if (sensorOrientation == 270) {
      rotated = cv.rotate(gray, cv.ROTATE_90_COUNTERCLOCKWISE);
      gray.dispose();
    } else {
      rotated = gray; // 0 (or anything else) — use as-is, no transfer.
    }

    try {
      // Downscale for processing if too large — keeps edge detection fast
      // without sacrificing accuracy (600px long side is plenty for corners).
      final longestSide = rotated.width > rotated.height
          ? rotated.width : rotated.height;
      const maxLiveSide = 600;
      if (longestSide > maxLiveSide) {
        final ratio = maxLiveSide / longestSide;
        final resized = cv.resize(rotated,
          ((rotated.width * ratio).round(),
           (rotated.height * ratio).round()),
          interpolation: cv.INTER_AREA);
        try {
          return _findCornersInGrayMat(resized, returnDebug: returnDebug);
        } finally {
          resized.dispose();
        }
      }
      return _findCornersInGrayMat(rotated, returnDebug: returnDebug);
    } finally {
      rotated.dispose();
    }
  }

  /// Detects the 4 corners of a book cover in the given image.
  /// Returns normalized coordinates (0.0~1.0) so the caller can
  /// overlay them on any rendered preview size.
  ///
  /// When OpenCV cannot find a quadrilateral, returns default corners
  /// covering ~90% of the image so the user can drag-adjust.
  DetectedCorners detectCorners(Uint8List imageBytes) {
    final src = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
    try {
      final longestSide = src.width > src.height ? src.width : src.height;
      final ratio = longestSide > _maxProcessSide
          ? _maxProcessSide / longestSide
          : 1.0;
      final working = ratio < 1.0
          ? cv.resize(src,
              ((src.width * ratio).round(), (src.height * ratio).round()),
              interpolation: cv.INTER_AREA)
          : src.clone();

      try {
        final gray = cv.cvtColor(working, cv.COLOR_BGR2GRAY);
        try {
          return _findCornersInGrayMat(gray).corners;
        } finally {
          gray.dispose();
        }
      } finally {
        working.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  /// Runs edge detection → contour → approxPolyDP on a grayscale Mat
  /// and returns normalized corner coordinates.
  ///
  /// Two independent edge maps are produced and searched:
  ///   1. Canny edges (+ dilate + morphological close) — original pipeline.
  ///   2. Adaptive thresholding — robust to uneven lighting on glossy covers.
  /// The best quadrilateral found across both is returned. Each 4-point
  /// candidate from `approxPolyDP` must additionally be convex
  /// (`cv.isContourConvex`); non-convex results are replaced with their
  /// convex hull so we never accept a concave "quadrilateral".
  ///
  /// When [returnDebug] is true, the morphologically closed Canny edge image
  /// is JPEG-encoded (quality 80) and returned as `debugImage` for the caller
  /// to display as a small preview overlay. The closed Mat is always disposed.
  CornersResult _findCornersInGrayMat(cv.Mat gray, {bool returnDebug = false}) {
    cv.Mat blurred = cv.gaussianBlur(gray, (5, 5), 0);

    final median = cv.mean(blurred).val[0].toDouble();
    final lower = (median * 0.66).round().clamp(0, 255).toDouble();
    final upper = (median * 1.33).round().clamp(0, 255).toDouble();
    cv.Mat edges = cv.canny(blurred, lower, upper);
    blurred.dispose();

    cv.Mat dilKernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
    cv.Mat dilated = cv.dilate(edges, dilKernel);
    dilKernel.dispose();
    edges.dispose();

    cv.Mat closeKernel = cv.getStructuringElement(cv.MORPH_RECT, (11, 11));
    cv.Mat closed = cv.morphologyEx(dilated, cv.MORPH_CLOSE, closeKernel);
    closeKernel.dispose();
    dilated.dispose();

    // Encode the closed edge image for the debug overlay before we dispose it.
    Uint8List? debugImage;
    if (returnDebug) {
      final (_, jpgBytes) = cv.imencode('.jpg', closed,
          params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 80]));
      debugImage = jpgBytes;
    }

    // --- Edge source #2: adaptive thresholding ---------------------------
    // blockSize must be odd and > 1; 11 works well for book-cover scales.
    final adaptive = cv.adaptiveThreshold(
      gray, 255, cv.ADAPTIVE_THRESH_MEAN_C, cv.THRESH_BINARY_INV, 11, 2);

    final imageArea = gray.width * gray.height;
    final imgW = gray.width.toDouble();
    final imgH = gray.height.toDouble();

    // Track the best candidate found across both edge sources, scored by
    // contour area (closest to a full-cover quad wins).
    double bestArea = 0;
    List<cv.Point>? bestOrdered;

    void searchContours(cv.VecVecPoint contours) {
      try {
        final sorted = contours.toList()
          ..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

        for (final contour in sorted.take(20)) {
          final peri = cv.arcLength(contour, true);
          for (final epsFactor in [0.01, 0.015, 0.02, 0.03, 0.05, 0.08]) {
            final approxRaw =
                cv.approxPolyDP(contour, epsFactor * peri, true);
            final rawList = approxRaw.toList();
            approxRaw.dispose();

            if (rawList.length != 4) continue;

            // Enforce convexity: book covers are convex quadrilaterals.
            // If approxPolyDP returns a non-convex 4-point polygon, replace
            // it with the convex hull of the contour.
            List<cv.Point> quad;
            if (cv.isContourConvex(cv.VecPoint.fromList(rawList))) {
              quad = rawList;
            } else {
              final hull = cv.convexHull(cv.VecPoint.fromList(rawList));
              quad = hull.toList().cast<cv.Point>();
              hull.dispose();
              if (quad.length != 4) continue;
            }

            final area = cv.contourArea(contour);
            if (area > imageArea * 0.10 && area > bestArea) {
              bestArea = area;
              bestOrdered = _orderCorners(quad);
            }
            break; // first good eps for this contour — move on
          }
        }
      } finally {
        contours.dispose();
      }
    }

    final (cannyContours, cannyHierarchy) = cv.findContours(
      closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE,
    );
    closed.dispose();
    searchContours(cannyContours);
    cannyHierarchy.dispose();

    final (adaptiveContours, adaptiveHierarchy) = cv.findContours(
      adaptive, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE,
    );
    adaptive.dispose();
    searchContours(adaptiveContours);
    adaptiveHierarchy.dispose();

    if (bestOrdered != null && bestOrdered!.length == 4) {
      final o = bestOrdered!;
      return (
        corners: DetectedCorners(
          x1: o[0].x / imgW, y1: o[0].y / imgH,
          x2: o[1].x / imgW, y2: o[1].y / imgH,
          x3: o[2].x / imgW, y3: o[2].y / imgH,
          x4: o[3].x / imgW, y4: o[3].y / imgH,
          isDetected: true,
        ),
        debugImage: debugImage,
      );
    }

    // No quadrilateral found — return default corners.
    return (corners: DetectedCorners.defaultCorners(), debugImage: debugImage);
  }

  /// Smooths corner coordinates across recent frames using a weighted moving
  /// average to reduce jitter on the live overlay.
  ///
  /// Weights (most recent frame has the highest weight):
  ///   - current (last entry of [history]): 0.5
  ///   - previous:                          0.3
  ///   - one before previous:               0.2
  ///
  /// If [history] has fewer than 3 entries (insufficient for a stable
  /// average), [current] is returned unchanged so the very first detections
  /// don't get smeared toward partial history.
  ///
  /// `isDetected` is taken from [current] — smoothing only affects the
  /// coordinate values, not whether the corner set is treated as a detection.
  static DetectedCorners smoothCorners(
      List<DetectedCorners> history, DetectedCorners current) {
    if (history.length < 3) return current;

    // history[history.length-1] is the most recent (= current).
    final n = history.length;
    final cur = history[n - 1];   // weight 0.5
    final prev = history[n - 2];  // weight 0.3
    final prev2 = history[n - 3]; // weight 0.2

    double wAvg(double a, double b, double c) => a * 0.5 + b * 0.3 + c * 0.2;

    return DetectedCorners(
      x1: wAvg(cur.x1, prev.x1, prev2.x1),
      y1: wAvg(cur.y1, prev.y1, prev2.y1),
      x2: wAvg(cur.x2, prev.x2, prev2.x2),
      y2: wAvg(cur.y2, prev.y2, prev2.y2),
      x3: wAvg(cur.x3, prev.x3, prev2.x3),
      y3: wAvg(cur.y3, prev.y3, prev2.y3),
      x4: wAvg(cur.x4, prev.x4, prev2.x4),
      y4: wAvg(cur.y4, prev.y4, prev2.y4),
      isDetected: current.isDetected,
    );
  }

  // ─── Perspective warp with custom corners ─────────────────────────

  /// Warps [imageBytes] using the given [corners] (normalized 0~1)
  /// and returns JPEG bytes of the cropped, rectified book cover.
  Uint8List warpWithCorners(Uint8List imageBytes, DetectedCorners corners) {
    final src = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
    try {
      final imgW = src.width.toDouble();
      final imgH = src.height.toDouble();

      // Convert normalized corners to pixel coordinates.
      final pts = corners.toList();
      final pixelCorners = pts.map((p) => cv.Point(
        (p.x * imgW).round().clamp(0, src.width - 1),
        (p.y * imgH).round().clamp(0, src.height - 1),
      )).toList();

      final warped = _warpToRectangle(src, pixelCorners);
      try {
        if (warped.width <= 0 || warped.height <= 0) {
          final encoded = cv.imencode('.jpg', src,
              params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 90]));
          return encoded.$2;
        }

        final longest =
            warped.width > warped.height ? warped.width : warped.height;
        final thumb = longest > _maxThumbnailSide
            ? (() {
                final scale = _maxThumbnailSide / longest;
                return cv.resize(warped,
                  ((warped.width * scale).round(),
                   (warped.height * scale).round()),
                  interpolation: cv.INTER_AREA);
              })()
            : warped.clone();
        try {
          final encoded = cv.imencode('.jpg', thumb,
              params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 90]));
          return encoded.$2;
        } finally {
          thumb.dispose();
        }
      } finally {
        warped.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  // ─── Full scan pipeline ───────────────────────────────────────────

  /// Full pipeline: OpenCV crop → ML Kit OCR → ScanResult.
  /// When [corners] is provided, uses them instead of auto-detecting.
  Future<ScanResult?> scanBookCover(String capturedImagePath,
      {DetectedCorners? corners}) async {
    final imageBytes = await File(capturedImagePath).readAsBytes();

    // Step 1: Crop with provided corners or auto-detect.
    final Uint8List thumbnailBytes = corners != null
        ? warpWithCorners(imageBytes, corners)
        : await cropBookCoverBytes(imageBytes);

    final thumbnailPath = await _persistThumbnail(thumbnailBytes, 'book');

    // Step 2: ML Kit OCR.
    String title = '';
    String author = '';

    try {
      final tmpThumb = File('${thumbnailPath}_ocr_tmp.jpg');
      await tmpThumb.writeAsBytes(thumbnailBytes, flush: true);
      final thumbInput = InputImage.fromFile(tmpThumb);
      final origFile = File(capturedImagePath);

      final attempts = <({String title, String author, int score})>[];

      for (final recognizer in [_latinRecognizer, _koreanRecognizer]) {
        try {
          final r = await recognizer.processImage(thumbInput);
          final parsed = _parseOcrText(r.text);
          attempts.add((
            title: parsed.title, author: parsed.author,
            score: parsed.title.length + parsed.author.length,
          ));
        } catch (_) {}

        try {
          final origInput = InputImage.fromFile(origFile);
          final r = await recognizer.processImage(origInput);
          final parsed = _parseOcrText(r.text);
          attempts.add((
            title: parsed.title, author: parsed.author,
            score: parsed.title.length + parsed.author.length,
          ));
        } catch (_) {}
      }

      try { await tmpThumb.delete(); } catch (_) {}

      attempts.sort((a, b) => b.score.compareTo(a.score));
      if (attempts.isNotEmpty && attempts.first.score > 0) {
        title = attempts.first.title;
        author = attempts.first.author;
      }
    } catch (_) {}

    return ScanResult(title: title, author: author, thumbnailPath: thumbnailPath);
  }

  // ─── Auto crop (no corners provided) ──────────────────────────────

  /// OpenCV auto-crop pipeline. Falls back to center crop.
  Future<Uint8List> cropBookCoverBytes(Uint8List imageBytes) async {
    final corners = detectCorners(imageBytes);
    return warpWithCorners(imageBytes, corners);
  }

  // ─── Warp helpers ─────────────────────────────────────────────────

  cv.Mat _warpToRectangle(cv.Mat src, List<cv.Point> corners) {
    final ordered = _orderCorners(corners);

    final widthA = _distance(ordered[0], ordered[1]);
    final widthB = _distance(ordered[2], ordered[3]);
    final maxWidth = widthA > widthB ? widthA : widthB;

    final heightA = _distance(ordered[0], ordered[3]);
    final heightB = _distance(ordered[1], ordered[2]);
    final maxHeight = heightA > heightB ? heightA : heightB;

    final outW = maxWidth.round().clamp(1, _maxThumbnailSide * 2).toInt();
    final outH = maxHeight.round().clamp(1, _maxThumbnailSide * 2).toInt();

    final srcPts = cv.VecPoint.fromList(ordered);
    final dstPts = cv.VecPoint.fromList([
      cv.Point(0, 0),
      cv.Point(outW - 1, 0),
      cv.Point(outW - 1, outH - 1),
      cv.Point(0, outH - 1),
    ]);
    final m = cv.getPerspectiveTransform(srcPts, dstPts);
    try {
      return cv.warpPerspective(src, m, (outW, outH));
    } finally {
      m.dispose();
      srcPts.dispose();
      dstPts.dispose();
    }
  }

  List<cv.Point> _orderCorners(List<cv.Point> pts) {
    if (pts.length != 4) return pts;
    final sorted = [...pts];
    sorted.sort((a, b) => (a.x + a.y).compareTo(b.x + b.y));
    final tl = sorted.first;
    final br = sorted.last;
    sorted.sort((a, b) => (a.x - a.y).compareTo(b.x - b.y));
    final bl = sorted.first;
    final tr = sorted.last;
    return [tl, tr, br, bl];
  }

  double _distance(cv.Point a, cv.Point b) {
    final dx = (a.x - b.x).toDouble();
    final dy = (a.y - b.y).toDouble();
    return dx * dx + dy * dy;
  }

  // ─── OCR text parsing ─────────────────────────────────────────────

  ({String title, String author}) _parseOcrText(String raw) {
    if (raw.trim().isEmpty) return (title: '', author: '');

    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty) return (title: '', author: '');

    String title = '';
    String author = '';

    final candidates = <String>[];
    for (final line in lines) {
      if (RegExp(r'^ISBN', caseSensitive: false).hasMatch(line)) continue;
      if (RegExp(r'^\d{10,}').hasMatch(line)) continue;
      if (RegExp(r'^[₩\$\€\£]\s*\d').hasMatch(line)) continue;
      if (line.length < 2) continue;
      if (line.length <= 4 && line == line.toUpperCase()) continue;
      candidates.add(line);
    }

    if (candidates.isEmpty) return (title: '', author: '');

    title = candidates.first;

    for (var i = 1; i < candidates.length; i++) {
      final line = candidates[i];
      final byMatch = RegExp(r'^by\s+(.+)', caseSensitive: false)
          .firstMatch(line);
      if (byMatch != null) {
        author = byMatch.group(1)!.trim();
        break;
      }
      final krMatch = RegExp(r'(?:저자|지은이|글|그림)\s*[:：]?\s*(.+)')
          .firstMatch(line);
      if (krMatch != null) {
        author = krMatch.group(1)!.trim();
        break;
      }
    }

    if (author.isEmpty && candidates.length >= 3) {
      final lastLine = candidates.last;
      final words = lastLine.split(RegExp(r'\s+'));
      if (words.length >= 2 && words.length <= 5 &&
          !RegExp(r'\d').hasMatch(lastLine) && lastLine.length <= 40) {
        final isNameLike = words.every((w) =>
            w.isNotEmpty && w[0].toUpperCase() == w[0]);
        if (isNameLike) author = lastLine;
      }
    }

    title = _stripMarketingPhrases(title);
    return (title: title, author: author);
  }

  static const _marketingPhrases = [
    'A Novel', 'A Novel by', 'Bestselling Author', 'International Bestseller',
    'Award-winning', 'The #1 Bestseller', '#1 Bestseller',
    'Soon to be a Major Motion Picture', 'Now a Major Motion Picture',
    'Now a Netflix Series', 'Now a Netflix Original Series',
    'New York Times Bestseller', 'NYT Bestseller',
    'A New York Times Bestseller', 'National Bestseller',
    'A National Bestseller', 'Bestselling Novel',
  ];

  String _stripMarketingPhrases(String title) {
    var result = title;
    for (final phrase in _marketingPhrases) {
      if (result.toLowerCase().endsWith(': ${phrase.toLowerCase()}')) {
        result = result.substring(
            0, result.length - (': ${phrase}'.length)).trim();
      } else if (result.toLowerCase().endsWith(' ${phrase.toLowerCase()}')) {
        result = result.substring(
            0, result.length - (' ${phrase}'.length)).trim();
      }
    }
    result = result.replaceAll(
      RegExp(r':\s*A Novel\s*$', caseSensitive: false), '').trim();
    return result;
  }

  // ─── Thumbnail persistence ────────────────────────────────────────

  Future<String> _persistThumbnail(Uint8List jpegBytes, String title) async {
    final dir = await getApplicationDocumentsDirectory();
    final readingDir = Directory(p.join(dir.path, 'reading_thumbnails'));
    if (!await readingDir.exists()) await readingDir.create(recursive: true);
    final safe = _safeFileName(title.isEmpty ? 'book' : title);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = '${safe}_$timestamp.jpg';
    final filePath = p.join(readingDir.path, fileName);
    await File(filePath).writeAsBytes(jpegBytes, flush: true);
    return filePath;
  }

  static const int _maxProcessSide = 1200;
  static const int _maxThumbnailSide = 512;

  static String _safeFileName(String title) {
    final safe = title
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'book' : (safe.length > 40 ? safe.substring(0, 40) : safe);
  }

  /// Legacy entry kept for compatibility.
  Future<String> cropAndSaveThumbnail({
    required Uint8List imageBytes,
    required List<double> bbox,
    required String filePrefix,
  }) async {
    final bytes = await cropBookCoverBytes(imageBytes);
    return _persistThumbnail(bytes, filePrefix);
  }
}
