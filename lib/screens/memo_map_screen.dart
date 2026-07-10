import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import '../models/memo.dart';
import '../services/database_service.dart';

/// Full-screen Naver map showing a single memo's location.
/// Pushed as a route from MemoDetailScreen when user taps the address.
class MemoMapScreen extends StatefulWidget {
  final int memoId;

  const MemoMapScreen({super.key, required this.memoId});

  @override
  State<MemoMapScreen> createState() => _MemoMapScreenState();
}

class _MemoMapScreenState extends State<MemoMapScreen> {
  final _databaseService = DatabaseService();
  Memo? _memo;
  bool _isLoading = true;
  bool _mapInitialized = false;

  @override
  void initState() {
    super.initState();
    _loadAndInit();
  }

  Future<void> _loadAndInit() async {
    await _loadMemo();
    // Initialize NaverMap SDK if not already done
    if (mounted) {
      setState(() => _mapInitialized = true);
    }
  }

  Future<void> _loadMemo() async {
    final memo = await _databaseService.getMemoById(widget.memoId);
    if (mounted) {
      setState(() {
        _memo = memo;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _memo != null ? _memo!.title : '위치',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final memo = _memo;
    if (memo == null || !memo.hasCoordinates) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              '위치 정보가 없습니다',
              style: TextStyle(fontSize: 16, color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }

    return NaverMap(
      options: NaverMapViewOptions(
        initialCameraPosition: NCameraPosition(
          target: NLatLng(memo.kakaoLat!, memo.kakaoLng!),
          zoom: 15,
        ),
        scaleBarEnable: true,
        locationButtonEnable: true,
      ),
      onMapReady: (controller) {
        final marker = NMarker(
          id: 'memo_${memo.id}',
          position: NLatLng(memo.kakaoLat!, memo.kakaoLng!),
          caption: NOverlayCaption(
            text: memo.title,
            color: Colors.white,
            haloColor: Colors.blueAccent,
          ),
        );
        controller.addOverlay(marker);
      },
    );
  }
}
