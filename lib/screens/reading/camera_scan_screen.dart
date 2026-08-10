import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../services/book_vision_service.dart';

/// Full-screen camera capture for the Reading Tracker.
///
/// Phase 1 — Live preview with real-time OpenCV corner detection overlay.
///   - Periodically grabs a frame and runs detectCorners().
///   - Draws detected corners as draggable-looking markers.
///   - Capture button is always enabled (user can snap even if corners
///     are not detected; they can adjust afterwards).
///
/// Phase 2 — After capture, frozen still + corner adjustment.
///   - Shows the captured image with 4 corner dots.
///   - User drags corners to fine-tune.
///   - "완료" button warps and proceeds to OCR.
///   - "다시 촬영" button restarts the camera.
class CameraScanScreen extends StatefulWidget {
  const CameraScanScreen({super.key});

  @override
  State<CameraScanScreen> createState() => _CameraScanScreenState();
}

class _CameraScanScreenState extends State<CameraScanScreen> {
  CameraController? _controller;
  Future<void>? _initializeFuture;

  // The camera description used for the live preview — kept so we can read
  // its sensorOrientation when converting the Y-plane into display
  // coordinates. Set during _setupCamera.
  CameraDescription? _cameraDescription;

  // Phase: 0 = live preview, 1 = corner adjustment
  int _phase = 0;
  bool _isProcessing = false;

  // Captured image path (phase 1).
  String? _capturedPath;

  // Detected corners (normalized 0~1).
  DetectedCorners? _liveCorners;     // from live preview
  DetectedCorners? _capturedCorners; // from captured still

  // Debug edge-carrier to the scanner. Set each frame from
  // detectCornersWithDebug and shown as a small top-right overlay. Null when
  // no edge image was produced (e.g. detection failed) so the overlay hides.
  Uint8List? _debugImage;

  // Rolling history of recent live detections used by
  // BookVisionService.smoothCorners to stabilize the overlay via a weighted
  // moving average. Kept capped at 5 entries. Entries are appended *before*
  // smoothing so the latest detection (including the current frame) is the
  // last element.
  final List<DetectedCorners> _cornerHistory = [];

  // Adjustable corner positions in screen coordinates (phase 2).
  // Stored as Offset relative to the displayed image rect.
  List<Offset>? _adjustableCorners;
  Rect? _imageDisplayRect;

  // Image stream for live corner detection.
  bool _isDetecting = false;
  int _frameCounter = 0;

  @override
  void initState() {
    super.initState();
    _setupCamera();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _setupCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) setState(() {});
      return;
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _cameraDescription = back;
    _controller = CameraController(
      back,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _initializeFuture = _controller!.initialize();
    if (mounted) setState(() {});

    // Start image stream for live corner detection once initialized.
    _initializeFuture!.then((_) {
      if (!mounted) return;
      _startLiveDetection();
    });
  }

  // ─── Phase 0: Live corner detection via image stream ────────────

  void _startLiveDetection() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      _controller!.startImageStream(_onImageStream);
    } catch (_) {
      // startImageStream can fail if already streaming — ignore.
    }
  }

  void _stopLiveDetection() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      _controller!.stopImageStream();
    } catch (_) {}
  }

  void _onImageStream(CameraImage image) {
    if (_phase != 0 || _isProcessing || _isDetecting) return;

    // Process every 3rd frame (~10 fps on a 30fps stream).
    _frameCounter++;
    if (_frameCounter % 3 != 0) return;

    _isDetecting = true;
    _detectFromCameraImage(image);
  }

  Future<void> _detectFromCameraImage(CameraImage image) async {
    try {
      // Convert CameraImage (YUV420) to JPEG bytes.
      // CameraImage planes: [0]=Y, [1]=U, [2]=V (for Android).
      // We use the Y plane + U/V to build a JPEG via OpenCV.
      // Simpler approach: use the Y plane as grayscale for edge detection.
      final yPlane = image.planes[0];
      final w = image.width;
      final h = image.height;

      // The camera's sensorOrientation rotates the Y plane into display
      // orientation inside detectCornersWithDebug, so the normalized 0~1
      // corner coordinates it returns map directly to the preview area.
      final sensorOrientation = _cameraDescription?.sensorOrientation ?? 90;
      final result = BookVisionService().detectCornersWithDebug(
        yPlane.bytes, w, h,
        yStride: yPlane.bytesPerRow,
        sensorOrientation: sensorOrientation,
      );

      // Update the debug edge preview regardless of detection success so the
      // overlay shows the live edge pipeline.
      _debugImage = result.debugImage;

      final latestCorners = result.corners;

      // Maintain a rolling history of recent detections for the weighted
      // moving average. Keep at most the last 5 frames.
      _cornerHistory.add(latestCorners);
      if (_cornerHistory.length > 5) {
        _cornerHistory.removeRange(0, _cornerHistory.length - 5);
      }

      // Stabilize the overlay: smoothCorners weights the 3 most recent entries
      // (0.5 / 0.3 / 0.2) and returns `latestCorners` unchanged until we have
      // ≥3 samples, so the very first detections are never smeared.
      final smoothed = BookVisionService.smoothCorners(
          _cornerHistory, latestCorners);

      if (mounted && _phase == 0) {
        setState(() => _liveCorners = smoothed);
      }
    } catch (_) {
      // Detection failed silently.
    } finally {
      _isDetecting = false;
    }
  }

  // ─── Capture → Phase 1 ──────────────────────────────────────────

  Future<void> _onCapture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    _stopLiveDetection();
    setState(() => _isProcessing = true);

    try {
      final xFile = await _controller!.takePicture();
      final capturedPath = xFile.path;
      await _controller!.pausePreview();

      // Detect corners on the captured still.
      final bytes = await File(capturedPath).readAsBytes();
      final corners = BookVisionService().detectCorners(bytes);

      if (!mounted) return;
      setState(() {
        _phase = 1;
        _capturedPath = capturedPath;
        _capturedCorners = corners;
        _isProcessing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('캡처 중 오류: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ─── Phase 1: Corner adjustment → OCR ───────────────────────────

  Future<void> _onConfirmCorners() async {
    if (_capturedPath == null || _adjustableCorners == null) return;
    if (_imageDisplayRect == null) return;

    setState(() => _isProcessing = true);

    // Convert screen-space corners to normalized coordinates.
    final rect = _imageDisplayRect!;
    final normalized = <double>[];
    for (final p in _adjustableCorners!) {
      normalized.add((p.dx - rect.left) / rect.width);
      normalized.add((p.dy - rect.top) / rect.height);
    }

    // Clamp to 0~1.
    for (var i = 0; i < normalized.length; i++) {
      normalized[i] = normalized[i].clamp(0.0, 1.0);
    }

    final corners = DetectedCorners(
      x1: normalized[0], y1: normalized[1],
      x2: normalized[2], y2: normalized[3],
      x3: normalized[4], y3: normalized[5],
      x4: normalized[6], y4: normalized[7],
      isDetected: true,
    );

    try {
      final result = await BookVisionService().scanBookCover(
        _capturedPath!,
        corners: corners,
      );
      if (!mounted) return;

      if (result == null) {
        // Fallback: return empty ScanResult.
        Navigator.pop(context, ScanResult(
          title: '', author: '', thumbnailPath: '',
        ));
      } else {
        Navigator.pop(context, result);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('스캔 중 오류: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ─── Retake ─────────────────────────────────────────────────────

  void _onRetake() {
    if (_controller == null) return;
    try {
      _controller!.resumePreview();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _phase = 0;
        _capturedPath = null;
        _capturedCorners = null;
        _adjustableCorners = null;
        _imageDisplayRect = null;
      });
      _startLiveDetection();
    }
  }

  // ─── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_phase == 0 ? '책 표지 스캔' : '모서리 조정'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_controller == null) {
      return const Center(
        child: Text('사용 가능한 카메라가 없습니다.',
            style: TextStyle(color: Colors.white)),
      );
    }
    return FutureBuilder<void>(
      future: _initializeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('카메라 초기화 실패: ${snapshot.error}',
                style: const TextStyle(color: Colors.white)),
          );
        }

        if (_phase == 1 && _capturedPath != null) {
          return _buildCornerAdjustView();
        }
        return _buildLivePreview();
      },
    );
  }

  // ─── Live preview with corner overlay ──────────────────────────

  Widget _buildLivePreview() {
    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_controller!),

        // Dim overlay + detected corners.
        if (_liveCorners != null)
          _buildLiveCornerOverlay(),

        // Framing guide.
        if (_liveCorners == null) _buildFramingOverlay(),

        // Debug edge-pipeline preview (top-right). Only shown when the latest
        // frame produced an edge image. The preview's aspect ratio is
        // portrait-friendly (160×120) to match a rotated Y plane while staying
        // tiny — it's an aid, not a primary display.
        if (_debugImage != null)
          Positioned(
            top: 16,
            right: 16,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 160,
                height: 120,
                color: Colors.black54,
                child: Image.memory(
                  _debugImage!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),

        // Status text.
        Positioned(
          top: 16,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _liveCorners != null && _liveCorners!.isDetected
                    ? '책 모서리 인식됨 — 캡처하세요'
                    : '책 표지를 프레임 안에 맞춰주세요',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),

        // Capture button.
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(child: _buildCaptureButton()),
            ),
          ),
        ),

        if (_isProcessing) _buildProcessingOverlay(),
      ],
    );
  }

  Widget _buildLiveCornerOverlay() {
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, constraints) {
        // The Y plane is rotated to display orientation inside
        // detectCornersWithDebug, so the normalized 0~1 corner coordinates map
        // directly to the full preview area — use constraints.biggest (the
        // whole preview surface) rather than any cropped sub-rect for the
        // width/height of the corner coordinate space.
        final size = constraints.biggest;
        final w = size.width;
        final h = size.height;
        final c = _liveCorners!;
        final pts = [
          Offset(c.x1 * w, c.y1 * h),
          Offset(c.x2 * w, c.y2 * h),
          Offset(c.x3 * w, c.y3 * h),
          Offset(c.x4 * w, c.y4 * h),
        ];
        return CustomPaint(
          painter: _CornerOverlayPainter(pts, c.isDetected),
        );
      }),
    );
  }

  // ─── Phase 1: Corner adjustment view ────────────────────────────

  Widget _buildCornerAdjustView() {
    return LayoutBuilder(builder: (context, constraints) {
      final screenW = constraints.biggest.width;
      final screenH = constraints.biggest.height;

      return Stack(
        fit: StackFit.expand,
        children: [
          // Image fills the screen with BoxFit.contain.
          GestureDetector(
            onPanUpdate: _onPanCorner,
            child: _buildAdjustableImage(screenW, screenH),
          ),

          // Bottom controls.
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _isProcessing ? null : _onRetake,
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      label: const Text('다시 촬영',
                          style: TextStyle(color: Colors.white)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white70),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _isProcessing ? null : _onConfirmCorners,
                      icon: const Icon(Icons.check),
                      label: const Text('완료'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Instruction text.
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '모서리 점을 드래그해서 책 표지에 맞춰주세요',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),

          if (_isProcessing) _buildProcessingOverlay(),
        ],
      );
    });
  }

  Widget _buildAdjustableImage(double screenW, double screenH) {
    return LayoutBuilder(builder: (context, constraints) {
      // We need to know the actual displayed image rect to map corners.
      // Use a key + post-frame callback to compute it.
      // For simplicity, use BoxFit.contain and compute the display rect.
      return FutureBuilder<Size>(
        future: _getImageSize(File(_capturedPath!)),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final imgSize = snapshot.data!;
          // Compute BoxFit.contain display rect.
          final scale = math.min(screenW / imgSize.width, screenH / imgSize.height);
          final dispW = imgSize.width * scale;
          final dispH = imgSize.height * scale;
          final offsetX = (screenW - dispW) / 2;
          final offsetY = (screenH - dispH) / 2;
          final displayRect = Rect.fromLTWH(offsetX, offsetY, dispW, dispH);

          // Initialize adjustable corners from detected corners.
          if (_adjustableCorners == null && _capturedCorners != null) {
            final c = _capturedCorners!;
            _adjustableCorners = [
              Offset(c.x1 * dispW + offsetX, c.y1 * dispH + offsetY),
              Offset(c.x2 * dispW + offsetX, c.y2 * dispH + offsetY),
              Offset(c.x3 * dispW + offsetX, c.y3 * dispH + offsetY),
              Offset(c.x4 * dispW + offsetX, c.y4 * dispH + offsetY),
            ];
            _imageDisplayRect = displayRect;
          }

          _imageDisplayRect = displayRect;

          return Stack(
            children: [
              Positioned.fill(
                child: Image.file(
                  File(_capturedPath!),
                  fit: BoxFit.contain,
                ),
              ),
              // Corner dots.
              if (_adjustableCorners != null)
                ..._buildCornerDots(),
            ],
          );
        },
      );
    });
  }

  List<Widget> _buildCornerDots() {
    final widgets = <Widget>[];
    for (var i = 0; i < _adjustableCorners!.length; i++) {
      final p = _adjustableCorners![i];
      widgets.add(Positioned(
        left: p.dx - 20,
        top: p.dy - 20,
        child: GestureDetector(
          onPanUpdate: (details) => _dragCorner(i, details.delta),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.3),
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red,
                ),
              ),
            ),
          ),
        ),
      ));
    }
    // Draw connecting lines between corners.
    widgets.add(CustomPaint(
      painter: _CornerLinesPainter(_adjustableCorners!),
    ));
    return widgets;
  }

  void _dragCorner(int index, Offset delta) {
    setState(() {
      _adjustableCorners![index] += delta;
      // Clamp to screen bounds.
      final screenW = MediaQuery.of(context).size.width;
      final screenH = MediaQuery.of(context).size.height;
      final p = _adjustableCorners![index];
      _adjustableCorners![index] = Offset(
        p.dx.clamp(0.0, screenW),
        p.dy.clamp(0.0, screenH),
      );
    });
  }

  void _onPanCorner(DragUpdateDetails details) {
    // Unused — individual corner GestureDetectors handle their own drags.
  }

  // ─── Static helpers ─────────────────────────────────────────────

  Future<Size> _getImageSize(File file) async {
    final bytes = await file.readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    final size = Size(decoded.width.toDouble(), decoded.height.toDouble());
    decoded.dispose();
    return size;
  }

  // ─── UI pieces ──────────────────────────────────────────────────

  Widget _buildFramingOverlay() {
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, constraints) {
        final screenW = constraints.biggest.width;
        final screenH = constraints.biggest.height;
        final guideW = screenW * 0.80;
        final guideH = guideW * 1.35;
        final actualH = guideH > screenH * 0.70 ? screenH * 0.70 : guideH;
        final left = (screenW - guideW) / 2;
        final top = (screenH - actualH) / 2 - screenH * 0.05;

        return Stack(children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DimPainter(rect: Rect.fromLTWH(left, top, guideW, actualH)),
            ),
          ),
          Positioned(
            left: left, top: top, width: guideW, height: actualH,
            child: CustomPaint(painter: _GuidePainter()),
          ),
        ]);
      }),
    );
  }

  Widget _buildCaptureButton() {
    final detected = _liveCorners?.isDetected ?? false;
    return FloatingActionButton.large(
      heroTag: 'capture',
      backgroundColor: detected ? Colors.green : Colors.white,
      onPressed: _isProcessing ? null : _onCapture,
      child: Icon(Icons.camera_alt, size: 36, color: detected ? Colors.white : Colors.black),
    );
  }

  Widget _buildProcessingOverlay() {
    return Container(
      color: Colors.black54,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32, height: 32,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
            ),
            SizedBox(height: 14),
            Text('책 표지 분석 중…',
                style: TextStyle(color: Colors.white, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

// ─── Painters ─────────────────────────────────────────────────────

class _DimPainter extends CustomPainter {
  final Rect rect;
  _DimPainter({required this.rect});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.45);
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, paint);
    canvas.drawRect(rect, Paint()..blendMode = BlendMode.clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DimPainter old) => rect != old.rect;
}

class _GuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), const Radius.circular(12)),
      borderPaint,
    );

    final cornerPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;
    final len = math.min(w, h) * 0.08;
    const r = 12.0;

    canvas.drawPath(
      Path()
        ..moveTo(r, 0)..lineTo(len, 0)
        ..moveTo(0, len)..lineTo(0, r),
      cornerPaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(w - len, 0)..lineTo(w - r, 0)
        ..moveTo(w, len)..lineTo(w, r),
      cornerPaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(r, h)..lineTo(len, h)
        ..moveTo(0, h - len)..lineTo(0, h - r),
      cornerPaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(w - len, h)..lineTo(w - r, h)
        ..moveTo(w, h - len)..lineTo(w, h - r),
      cornerPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// Draws detected corners as a quadrilateral with colored dots.
class _CornerOverlayPainter extends CustomPainter {
  final List<Offset> points;
  final bool isDetected;

  _CornerOverlayPainter(this.points, this.isDetected);

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = (isDetected ? Colors.green : Colors.orange)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final path = Path();
    path.moveTo(points[0].dx, points[0].dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    path.close();
    canvas.drawPath(path, linePaint);

    final dotPaint = Paint()
      ..color = isDetected ? Colors.green : Colors.orange;
    for (final p in points) {
      canvas.drawCircle(p, 8, dotPaint);
      canvas.drawCircle(p, 8, Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(covariant _CornerOverlayPainter old) =>
      old.isDetected != isDetected || old.points != points;
}

/// Draws connecting lines between adjustable corner points.
class _CornerLinesPainter extends CustomPainter {
  final List<Offset> points;
  _CornerLinesPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.green.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final path = Path();
    path.moveTo(points[0].dx, points[0].dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    path.close();
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _CornerLinesPainter old) =>
      old.points != points;
}
