import 'package:flutter/material.dart';

/// 앱 하단 5탭 내비게이션 바 (공용 위젯).
///
/// MainShell(홈 셸)과 상세 화면(예: BookDetailScreen)에서 함께 사용하여
/// 상세 화면에서도 하단 메뉴를 유지할 수 있게 한다.
class AppBottomNavBar extends StatelessWidget {
  /// 현재 선택된 탭 인덱스 (0~4).
  final int selectedIndex;

  /// 탭 선택 시 호출되는 콜백 (인덱스 0~4).
  final ValueChanged<int> onDestinationSelected;

  const AppBottomNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  /// 더보기 탭 인덱스 — 항상 마지막(4).
  static const moreTabIndex = 4;

  /// MainShell 외부(상세 화면)에서 하단 탭 전환을 요청하기 위한 정적 핸들러.
  ///
  /// MainShell이 mount될 때 등록되고 dispose 시 해제된다. BookDetailScreen처럼
  /// root Navigator에 push된 화면이 하단 바를 눌렀을 때, pop과 함께 이 핸들러를
  /// 호출하여 MainShell의 탭 인덱스를 변경한다.
  static void Function(int index)? onSwitchTabRequested;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '메모',
          ),
          NavigationDestination(
            icon: Icon(Icons.hourglass_bottom_outlined),
            selectedIcon: Icon(Icons.hourglass_bottom),
            label: '처리현황',
          ),
          NavigationDestination(
            icon: Icon(Icons.smart_toy_outlined),
            selectedIcon: Icon(Icons.smart_toy),
            label: 'AI 챗봇',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: '지도',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_outlined),
            selectedIcon: Icon(Icons.menu),
            label: '더보기',
          ),
        ],
      ),
    );
  }
}