import 'package:flutter_test/flutter_test.dart';
import 'package:aimemo/services/category_detector.dart';
import 'package:aimemo/services/llm_provider.dart';

void main() {
  group('CategoryDetector — 맛집 & 카페 vs 요리 & 레시피', () {
    test('식당 방문 후기(웨이팅/영업시간)는 결정적 신호로 맛집 & 카페', () {
      final text = '오늘 성수동 파스타 맛집 다녀왔어요. 웨이팅 30분, 영업시간 11시부터예요.';
      expect(CategoryDetector.detect(text), '맛집 & 카페');
    });

    test('조리 과정(만드는 법/중불)은 결정적 신호로 요리 & 레시피', () {
      final text = '크림 파스타 만드는 법! 재료 준비하고 중불에서 5분 볶아주세요.';
      expect(CategoryDetector.detect(text), '요리 & 레시피');
    });

    test('음식 맥락 없이 예약 단어만 있으면 맛집 & 카페로 오분류하지 않음', () {
      // '호텔 예약' — 음식 관련 키워드가 부족하면 결정적 신호가 발동하지 않아야 함
      final text = '호텔 예약 완료했습니다. 내일 체크인 예정.';
      final result = CategoryDetector.detect(text);
      expect(result, isNot('맛집 & 카페'));
    });

    test('지역명(강남)만으로는 맛집 & 카페로 분류하지 않음', () {
      final text = '강남에서 친구랑 놀기로 했어요.';
      expect(CategoryDetector.detect(text), isNot('맛집 & 카페'));
    });

    test('맛집 후기와 레시피 단어가 섞여도 방문 신호(재방문)가 이김', () {
      final text = '파스타 맛집 후기 — 집에서 해먹는 것보다 훨씬 맛있어요. 재방문 의사 100%!';
      expect(CategoryDetector.detect(text), '맛집 & 카페');
    });
  });

  group('AiAnalysisResult.fromText — AI 판단 우선 + 키워드 폴백', () {
    test('AI가 유효한 카테고리를 답하면 키워드 검출을 이김', () {
      final response = '''
## 제목
크림 파스타 레시피

## 카테고리
요리 & 레시피

## 키워드
파스타, 크림

## 내용
재료와 조리법을 소개하는 영상입니다.
''';
      // 원문은 맛집 키워드가 강하지만 AI 답변(요리 & 레시피)을 신뢰해야 함
      final result = AiAnalysisResult.fromText(
        response,
        originalContent: '성수 파스타 맛집, 웨이팅 30분, 분위기 좋은 카페',
      );
      expect(result.category, '요리 & 레시피');
    });

    test('AI가 카테고리를 못 내면(없음) 키워드 검출로 폴백', () {
      final response = '''
## 제목
맛집 탐방기

## 카테고리
없음

## 키워드
맛집, 카페

## 내용
오늘 방문한 곳 소개입니다.
''';
      final result = AiAnalysisResult.fromText(
        response,
        originalContent: '성수 파스타 맛집, 웨이팅 30분, 분위기 좋은 카페',
      );
      expect(result.category, '맛집 & 카페');
    });

    test('AI가 별칭(맛집/카페)으로 답해도 정규화됨', () {
      final response = '''
## 제목
신상 카페 소개

## 카테고리
맛집/카페

## 키워드
카페

## 내용
신상 카페에 다녀왔습니다.
''';
      final result = AiAnalysisResult.fromText(
        response,
        originalContent: '카페 후기',
      );
      expect(result.category, '맛집 & 카페');
    });
  });
}
