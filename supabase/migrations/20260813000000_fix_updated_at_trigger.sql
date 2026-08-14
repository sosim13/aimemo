-- ============================================================================
-- Migration: updated_at 트리거 제거 — 클라이언트 updated_at 존중
-- Created: 2026-08-13
--
-- 문제:
--   기존 `before update` 트리거(set_updated_at)가 모든 UPDATE/UPSERT에서
--   updated_at을 서버 now()로 강제 덮어써서:
--     1. 클라이언트가 보낸 updated_at이 무시됨 → 앱의 last-write-wins
--        충돌 해결(updated_at 비교)이 깨짐
--     2. remote가 항상 "더 최신"으로 판정 → pull 시 로컬 데이터가 원격의
--        옛 내용으로 덮어써짐 (AI 요약 데이터 손실)
--
-- 해결:
--   트리거를 제거하면 클라이언트가 보낸 updated_at이 그대로 저장되므로
--   앱의 updated_at 기반 충돌 해결이 정상 동작한다.
--   (신규 INSERT의 기본값은 여전히 now()이며, 앱은 항상 명시적으로
--    updated_at을 보내므로 기본값은 사용되지 않는다.)
--
-- 적용: supabase db push  (또는 Supabase Dashboard → SQL Editor에서 실행)
-- ============================================================================

drop trigger if exists trg_memos_set_updated_at on public.memos;
drop trigger if exists trg_books_set_updated_at on public.books;

-- set_updated_at 함수는 남겨둔다 (트리거와 무관하게 다른 용도 참조 방지 차원).
-- 제거를 원하면: drop function if exists public.set_updated_at();