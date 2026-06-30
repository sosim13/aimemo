import 'package:flutter/material.dart';

class CategoryChip extends StatelessWidget {
  final String category;

  const CategoryChip({super.key, required this.category});

  static const _categoryColors = {
    '개발': Color(0xFF2196F3),
    'AI & 데이터': Color(0xFF673AB7),
    '미술 & 디자인': Color(0xFFE91E63),
    '기획 & 비즈니스': Color(0xFF3F51B5),
    '마케팅 & 브랜딩': Color(0xFFFF9800),
    '재테크 & 금융': Color(0xFF4CAF50),
    '법률 & 계약': Color(0xFF607D8B),
    '이슈 & 뉴스': Color(0xFF795548),
    '요리 & 레시피': Color(0xFFFF6B35),
    '맛집 & 카페': Color(0xFFFF5722),
    '쇼핑 & 위시리스트': Color(0xFFE91E63),
    '여행 & 휴가': Color(0xFF00BCD4),
    '건강 & 운동': Color(0xFF4CAF50),
    '인테리어 & 소품': Color(0xFF8D6E63),
    '반려동물': Color(0xFFA1887F),
    '할 일 & To-Do': Color(0xFF78909C),
    '일정 & 약속': Color(0xFF42A5F5),
    '아이디어 & 영감': Color(0xFFFFD600),
    '명언 & 좋은 글귀': Color(0xFF9E9E9E),
    '인간관계 & 경조사': Color(0xFFEF5350),
    '독서 & 리뷰': Color(0xFF26A69A),
    '어학 & 외국어': Color(0xFFAB47BC),
    '시험 & 자격증': Color(0xFF5C6BC0),
    '인문 & 교양': Color(0xFF8D6E63),
    '과학 & 다큐': Color(0xFF00897B),
    '영화 & 드라마': Color(0xFFEC407A),
    '음악 & 공연': Color(0xFF7B1FA2),
    '웹툰 & 소설': Color(0xFF29B6F6),
    '게임': Color(0xFF66BB6A),
    '육아 & 가족': Color(0xFFFF8A65),
  };

  static Color getColor(String category) {
    return _categoryColors[category] ?? Colors.grey;
  }

  static IconData getIcon(String category) {
    switch (category) {
      case '개발':
        return Icons.code;
      case 'AI & 데이터':
        return Icons.psychology;
      case '미술 & 디자인':
        return Icons.palette;
      case '기획 & 비즈니스':
        return Icons.analytics;
      case '마케팅 & 브랜딩':
        return Icons.campaign;
      case '재테크 & 금융':
        return Icons.account_balance;
      case '법률 & 계약':
        return Icons.gavel;
      case '이슈 & 뉴스':
        return Icons.article;
      case '요리 & 레시피':
        return Icons.restaurant;
      case '맛집 & 카페':
        return Icons.local_cafe;
      case '쇼핑 & 위시리스트':
        return Icons.shopping_bag;
      case '여행 & 휴가':
        return Icons.flight_takeoff;
      case '건강 & 운동':
        return Icons.fitness_center;
      case '인테리어 & 소품':
        return Icons.chair;
      case '반려동물':
        return Icons.pets;
      case '할 일 & To-Do':
        return Icons.checklist;
      case '일정 & 약속':
        return Icons.calendar_today;
      case '아이디어 & 영감':
        return Icons.lightbulb;
      case '명언 & 좋은 글귀':
        return Icons.format_quote;
      case '인간관계 & 경조사':
        return Icons.people;
      case '독서 & 리뷰':
        return Icons.menu_book;
      case '어학 & 외국어':
        return Icons.translate;
      case '시험 & 자격증':
        return Icons.school;
      case '인문 & 교양':
        return Icons.auto_stories;
      case '과학 & 다큐':
        return Icons.science;
      case '영화 & 드라마':
        return Icons.movie;
      case '음악 & 공연':
        return Icons.music_note;
      case '웹툰 & 소설':
        return Icons.auto_stories;
      case '게임':
        return Icons.sports_esports;
      case '육아 & 가족':
        return Icons.family_restroom;
      default:
        return Icons.category;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = getColor(category);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(getIcon(category), size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            category,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
