import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:geolocator/geolocator.dart';
import '../models/memo.dart';
import '../services/database_service.dart';
import '../services/secure_storage_service.dart';
import '../services/content_processing_service.dart';
import 'memo_detail_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _databaseService = DatabaseService();
  final _storage = SecureStorageService();
  final _processingService = ContentProcessingService();

  List<Memo> _memos = [];
  Memo? _selectedMemo;
  bool _isLoading = true;
  bool _mapInitialized = false;
  NaverMapController? _mapController;
  StreamSubscription<ProcessingResult>? _processingSubscription;

  @override
  void initState() {
    super.initState();
    _initMapAndLoad();

    // Auto-refresh when a new memo is processed/saved
    _processingSubscription = _processingService.onItemProcessed.listen((_) {
      _refreshMarkers();
    });
  }

  @override
  void dispose() {
    _processingSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initMapAndLoad() async {
    // Initialize NaverMap SDK
    final clientId = await _storage.getNaverClientId();
    if (clientId != null && clientId.isNotEmpty) {
      try {
        await FlutterNaverMap().init(
          clientId: clientId,
          onAuthFailed: (ex) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('⚠️ 네이버 지도 인증 실패: $ex'),
                  backgroundColor: Colors.orange,
                ),
              );
            }
          },
        );
      } catch (_) {
        // Already initialized — proceed
      }
    }

    await _loadMemos();
    if (mounted) {
      setState(() => _mapInitialized = true);
    }
  }

  Future<void> _loadMemos() async {
    final memos = await _databaseService.getMemosWithCoordinates();
    if (mounted) {
      setState(() {
        _memos = memos;
        _isLoading = false;
      });
    }
  }

  /// Reload memos from DB and re-add all markers to the map.
  Future<void> _refreshMarkers() async {
    final memos = await _databaseService.getMemosWithCoordinates();
    if (!mounted) return;

    setState(() {
      _memos = memos;
      _selectedMemo = null;
    });

    // Rebuild markers on the existing map
    _rebuildMarkers();
  }

  void _rebuildMarkers() {
    final controller = _mapController;
    if (controller == null) return;

    // Clear all existing markers
    controller.clearOverlays(type: NOverlayType.marker);

    // Add markers for memos with coordinates
    for (final memo in _memos) {
      if (memo.kakaoLat == null || memo.kakaoLng == null) continue;

      final marker = NMarker(
        id: 'memo_${memo.id}',
        position: NLatLng(memo.kakaoLat!, memo.kakaoLng!),
        caption: NOverlayCaption(
          text: memo.title,
          color: Colors.white,
          haloColor: Colors.blueAccent,
        ),
      );

      marker.setOnTapListener((_) {
        _onMarkerTapped(memo);
      });

      controller.addOverlay(marker);
    }

    // Fit camera to markers if first load
    if (_memos.isNotEmpty) {
      final positions = _memos
          .where((m) => m.kakaoLat != null && m.kakaoLng != null)
          .map((m) => NLatLng(m.kakaoLat!, m.kakaoLng!))
          .toList();
      if (positions.isNotEmpty) {
        controller.updateCamera(
          NCameraUpdate.fitBounds(
            NLatLngBounds.from(positions),
            padding: const EdgeInsets.all(100),
          ),
        );
      }
    }
  }

  /// Request location permission and enable location tracking on the map.
  Future<void> _requestLocationAndTrack(NaverMapController controller) async {
    // Check if location permission is already granted
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ 위치 권한이 필요합니다. 설정에서 위치 권한을 허용해주세요.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    // Permission granted — enable location tracking
    controller.setLocationTrackingMode(NLocationTrackingMode.follow);
  }

  void _onMarkerTapped(Memo memo) {
    setState(() {
      _selectedMemo = memo;
    });
  }

  void _openMemoDetail(Memo memo) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MemoDetailScreen(memoId: memo.id!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              Icons.map_rounded,
              color: Theme.of(context).colorScheme.primary,
              size: 24,
            ),
            const SizedBox(width: 10),
            const Text('지도'),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
            onPressed: _isLoading ? null : _refreshMarkers,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_mapInitialized) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              '지도를 초기화 중입니다...',
              style: TextStyle(color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }

    if (_memos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              '위치 정보가 있는 메모가 없습니다',
              style: TextStyle(fontSize: 16, color: Colors.grey[500]),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                '링크나 텍스트 요약 시 주소("서울시 ...", "경기도 ...")가 포함되면\n자동으로 지도에 표시됩니다',
                style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _refreshMarkers,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('새로고침'),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        // Naver Map
        NaverMap(
          options: const NaverMapViewOptions(
            initialCameraPosition: NCameraPosition(
              target: NLatLng(37.5665, 126.9780), // Seoul City Hall
              zoom: 12,
            ),
            scaleBarEnable: true,
            locationButtonEnable: true,
          ),
          onMapReady: (controller) {
            _mapController = controller;
            _rebuildMarkers();
            _requestLocationAndTrack(controller);
          },
          onMapTapped: (_, __) {
            if (_selectedMemo != null) {
              setState(() => _selectedMemo = null);
            }
          },
        ),

        // Selected memo info card overlay
        if (_selectedMemo != null) _buildInfoCard(),
      ],
    );
  }

  Widget _buildInfoCard() {
    final memo = _selectedMemo!;
    final preview = memo.content.length > 100
        ? '${memo.content.substring(0, 100)}...'
        : memo.content;

    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openMemoDetail(memo),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.location_on, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        memo.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.chevron_right, color: Colors.grey[400]),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  preview,
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 14,
                    height: 1.4,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.touch_app, size: 14, color: Colors.grey[400]),
                    const SizedBox(width: 4),
                    Text(
                      '탭하여 메모 보기',
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
