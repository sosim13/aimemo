import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:geolocator/geolocator.dart';
import '../models/memo.dart';
import '../services/database_service.dart';
import '../services/secure_storage_service.dart';
import '../services/content_processing_service.dart';
import '../widgets/category_chip.dart';
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
  List<Memo> _visibleMemos = [];
  Memo? _selectedMemo;
  bool _isLoading = true;
  bool _mapInitialized = false;
  bool _showList = false;
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

    // Keep the visible-memo list in sync with the new data
    _refreshVisibleMemos();
  }

  /// Recompute [_visibleMemos] to only the memos whose markers are inside the
  /// current camera viewport. Runs on camera idle and when the list is opened.
  Future<void> _refreshVisibleMemos() async {
    final controller = _mapController;
    if (controller == null) {
      if (mounted) setState(() => _visibleMemos = []);
      return;
    }
    try {
      final bounds = await controller.getContentBounds();
      if (!mounted) return;
      setState(() {
        _visibleMemos = _memos.where((m) {
          if (m.kakaoLat == null || m.kakaoLng == null) return false;
          return bounds.containsPoint(NLatLng(m.kakaoLat!, m.kakaoLng!));
        }).toList();
      });
    } catch (_) {
      // Bounds unavailable — fall back to showing every memo
      if (mounted) setState(() => _visibleMemos = List.of(_memos));
    }
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
  }

  /// Request location permission, center camera on user's current position
  /// at a street-level zoom, then enable location tracking mode.
  Future<void> _requestLocationAndTrack(NaverMapController controller) async {
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

    // Move camera to last known position for an instant preview,
    // then let follow mode refine it when fresh GPS arrives.
    try {
      final lastPos = await Geolocator.getLastKnownPosition();
      if (lastPos != null && mounted) {
        controller.updateCamera(NCameraUpdate.withParams(
          target: NLatLng(lastPos.latitude, lastPos.longitude),
          zoom: 14,
        ));
      }
    } catch (_) {
      // Ignore — follow mode will handle positioning
    }

    // Permission granted — enable live location tracking
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
            icon: Icon(_showList
                ? Icons.map_outlined
                : Icons.format_list_bulleted),
            tooltip: _showList ? '지도 보기' : '목록 보기',
            onPressed: () {
              setState(() {
                _showList = !_showList;
                if (_showList) _selectedMemo = null;
              });
              // Fetch the latest viewport contents when opening the list
              if (_showList) _refreshVisibleMemos();
            },
          ),
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

    // IndexedStack keeps the NaverMap widget alive while the list is shown,
    // so toggling views doesn't re-initialize the map.
    return IndexedStack(
      index: _showList ? 1 : 0,
      children: [
        _buildMapView(),
        _buildMemoListView(),
      ],
    );
  }

  Widget _buildMapView() {
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
          onCameraIdle: () => _refreshVisibleMemos(),
        ),

        // Selected memo info card overlay
        if (_selectedMemo != null) _buildInfoCard(),
      ],
    );
  }

  /// List view of the memos whose markers are currently visible on the map —
  /// handy when markers overlap and are hard to tap.
  Widget _buildMemoListView() {
    if (_visibleMemos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              '현재 지도에 보이는 마커가 없습니다',
              style: TextStyle(fontSize: 16, color: Colors.grey[500]),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                '지도를 이동하거나 축소하면\n그 범위에 있는 메모만 목록에 표시됩니다',
                style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _refreshVisibleMemos,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('다시 불러오기'),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      itemCount: _visibleMemos.length + 1, // +1 for the header row
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '지도에 보이는 메모 ${_visibleMemos.length}개',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Colors.grey[600],
              ),
            ),
          );
        }
        return _buildListTile(_visibleMemos[index - 1]);
      },
    );
  }

  Widget _buildListTile(Memo memo) {
    // Show the most useful location hint: address > search keyword > coords
    final locationHint = memo.address ??
        memo.searchKeyword ??
        '${memo.kakaoLat?.toStringAsFixed(4)}, ${memo.kakaoLng?.toStringAsFixed(4)}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openMemoDetail(memo),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CategoryChip(category: memo.category),
                  const Spacer(),
                  // "지도에서 보기" — center the camera on this memo and
                  // switch back to the map view
                  IconButton(
                    icon: const Icon(Icons.map, size: 18),
                    color: Colors.blueAccent,
                    tooltip: '지도에서 보기',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _focusMemoOnMap(memo),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                memo.title,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.location_on, size: 14, color: Colors.redAccent),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      locationHint,
                      style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (memo.content.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  memo.content,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                    height: 1.4,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Center the camera on [memo]'s marker, show its info card, and return
  /// to the map view.
  void _focusMemoOnMap(Memo memo) {
    final controller = _mapController;
    if (controller != null && memo.kakaoLat != null && memo.kakaoLng != null) {
      controller.updateCamera(NCameraUpdate.withParams(
        target: NLatLng(memo.kakaoLat!, memo.kakaoLng!),
        zoom: 16,
      ));
    }
    setState(() {
      _selectedMemo = memo;
      _showList = false;
    });
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
