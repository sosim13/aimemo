-- ============================================================================
-- Migration: debug_logs 테이블 (임시 — 인스타그램 요약 실패 원인 진단용)
-- Created: 2026-09-01
--
-- 사용자가 기기 밖(디버그 로그 화면에 접근 못하는 상황)에서도 로그를 확인할
-- 수 있도록, 앱의 DebugLogger가 남기는 모든 로그 라인을 Supabase에도 함께
-- 적재한다. Claude가 Supabase MCP(또는 대시보드 SQL 편집기)로 조회해서
-- 원인을 분석하기 위한 용도.
--
-- *** 인스타그램 요약 문제가 해결되면 이 마이그레이션으로 만든 테이블과
-- *** lib/services/debug_logger.dart의 "TEMP: Supabase 원격 로그 업로드"
-- *** 블록을 함께 제거할 것 (연락처/URL 등이 로그에 그대로 남으므로 계속
-- *** 켜둘 이유가 없음).
--
-- 로그인 여부와 무관하게(비로그인 상태에서도 인스타그램 처리는 발생) 기록
-- 되어야 진단에 쓸모가 있으므로 user_id는 nullable이고, insert는 인증 없이도
-- 허용한다. 반대로 select는 일반 클라이언트에게 노출하지 않는다 — 조회는
-- Supabase 대시보드 또는 서비스 롤(Claude의 Supabase MCP 연결)을 통해서만.
-- ============================================================================

create table if not exists public.debug_logs (
    id          bigint generated always as identity primary key,
    user_id     uuid references auth.users(id) on delete set null,
    message     text not null,
    created_at  timestamptz not null default now()
);

create index if not exists idx_debug_logs_created_at on public.debug_logs(created_at);

alter table public.debug_logs enable row level security;

-- 진단 목적의 쓰기 전용 테이블 — insert는 완전히 개방(익명 포함).
create policy "debug_logs_insert_anyone"
    on public.debug_logs for insert
    with check (true);

-- select 정책은 의도적으로 만들지 않는다(=일반 클라이언트는 조회 불가).
-- 서비스 롤(RLS 우회)만 조회 가능.
