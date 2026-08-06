import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../services/book_vision_service.dart';

/// Full-screen camera capture for the Reading Tracker.
///
/// Opens the rear camera, lets the user frame a book cover, and on tap
/// writes the still to a temp file and runs it through [BookVisionService].
/// Returns a [ScanResult] via Navigator.pop when recognition succeeds.
class CameraScanScreen extends StatefulWidget {
  const CameraScanScreen({super.key});

  @override
  State<CameraScanScreen> createState() => _CameraScanScreenState();
}

class _CameraScanScreenState extends State<CameraScanScreen> {
  CameraController? _controller;
  Future<void>? _initializeFuture;
  bool _isProcessing = false;

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
      // No cameras — caller should have pre-checked, but guard anyway.
      if (mounted) {
        setState(() {});
      }
      return;
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _controller = CameraController(
      back,
      ResolutionPreset.high,
      enableAudio: false,
    );
    _initializeFuture = _controller!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _onCapture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() => _isProcessing = true);

    try {
      final xFile = await _controller!.takePicture();
      final capturedPath = xFile.path;

      final vision = BookVisionService();
      final result = await vision.scanBookCover(capturedPath);

      if (!mounted) return;
      if (result == null) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('책 표지를 인식하지 못했습니다. 다시 시도해주세요.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        // Clean up the orphan temp file.
        await File(capturedPath).delete();
        return;
      }

      // Success — pop with the ScanResult so the timer screen can take over.
      Navigator.pop(context, result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('스캔 중 오류가 발생했습니다: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('책 표지 스캔'),
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
        child: Text(
          '사용 가능한 카메라가 없습니다.',
          style: TextStyle(color: Colors.white),
        ),
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
            child: Text(
              '카메라 초기화 실패: ${snapshot.error}',
              style: const TextStyle(color: Colors.white),
            ),
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            // Centered camera preview with a square framing guide.
            CameraPreview(_controller!),
            _buildFramingOverlay(),
            // Bottom capture bar.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildCaptureBar(),
            ),
          ],
        );
      },
    );
  }

  /// Draws a square aspect-ratio guide in the center to help the user frame
  /// the book cover. The scan itself uses the full sensor frame.
  Widget _buildFramingOverlay() {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = constraints.biggest.shortestSide * 0.8;
          return Align(
            alignment: Alignment.center,
            child: Container(
              width: side,
              height: side * 1.4,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCaptureBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: _isProcessing
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 3,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'AI가 책을 분석 중…',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                )
              : FloatingActionButton.large(
                  heroTag: 'capture',
                  backgroundColor: Colors.white,
                  onPressed: _onCapture,
                  child: const Icon(Icons.camera_alt, size: 36),
                ),
        ),
      ),
    );
  }
}
