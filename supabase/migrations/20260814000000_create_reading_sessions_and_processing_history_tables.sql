-- ============================================================================
-- Migration: reading_sessions + processing_history tables + RLS
-- Created: 2026-08-14
--
-- 독서 이력(reading_sessions)과 처리 이력/큐(processing_history)를
-- Supabase에 동기화하기 위한 테이블. books/memos와 동일한 패턴:
--   - user_id (auth.users.id) 기준 본인만 접근 (RLS)
--   - updated_at 기반 last-write-wins 충돌 해결
--   - deleted_at 기반 soft delete
--   - updated_at 트리거 없음 (클라이언트 updated_at 존중 — 20260813 마이그레이션과 동일)
--
-- 로컬 스키마 대응:
--   reading_sessions:
--     sessionId TEXT PK        ->  session_id text primary key
--     bookId TEXT NOT NULL     ->  book_id text not null
--     readRound INTEGER        ->  read_round integer not null default 1
--     firstStartDate TEXT      ->  first_start_date timestamptz not null
--     completedDate TEXT       ->  completed_date timestamptz
--     accumulatedActiveTime    ->  accumulated_active_time integer not null default 0
--     status TEXT              ->  status text not null default 'READING'
--   processing_history:
--     itemId TEXT              ->  item_id text primary key (UUID)
--     content TEXT NOT NULL    ->  content text not null
--     type TEXT NOT NULL       ->  type text not null ('url'|'text'|'image')
--     status TEXT NOT NULL     ->  status text not null ('completed'|'failed')
--     progress REAL            ->  progress double precision not null default 1.0
--     error TEXT               ->  error text
--     memoTitle TEXT           ->  memo_title text
--     memoId INTEGER           ->  memo_id integer (로컬 memo id — 참조용)
--     completedAt TEXT         ->  completed_at timestamptz
-- ============================================================================

-- 1) reading_sessions 테이블
create table if not exists public.reading_sessions (
    session_id              text primary key,
    user_id                 uuid not null references auth.users(id) on delete cascade,
    book_id                 text not null,
    read_round              integer not null default 1,
    first_start_date        timestamptz not null,
    completed_date          timestamptz,
    accumulated_active_time integer not null default 0,
    status                  text not null default 'READING',
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now(),
    deleted_at              timestamptz
);

-- 2) reading_sessions 인덱스
create index if not exists idx_sessions_user_id    on public.reading_sessions(user_id);
create index if not exists idx_sessions_book_id    on public.reading_sessions(book_id);
create index if not exists idx_sessions_updated_at on public.reading_sessions(updated_at);
create index if not exists idx_sessions_deleted_at on public.reading_sessions(deleted_at);

-- 3) reading_sessions RLS
alter table public.reading_sessions enable row level security;

create policy "reading_sessions_select_own"
    on public.reading_sessions for select
    using (auth.uid() = user_id);

create policy "reading_sessions_insert_own"
    on public.reading_sessions for insert
    with check (auth.uid() = user_id);

create policy "reading_sessions_update_own"
    on public.reading_sessions for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "reading_sessions_delete_own"
    on public.reading_sessions for delete
    using (auth.uid() = user_id);

-- 4) processing_history 테이블
create table if not exists public.processing_history (
    item_id             text primary key,
    user_id             uuid not null references auth.users(id) on delete cascade,
    content             text not null,
    type                text not null,
    status              text not null,
    progress            double precision not null default 1.0,
    error               text,
    memo_title          text,
    memo_id             integer,
    created_at          timestamptz not null default now(),
    completed_at        timestamptz,
    updated_at          timestamptz not null default now(),
    deleted_at          timestamptz
);

-- 5) processing_history 인덱스
create index if not exists idx_history_user_id    on public.processing_history(user_id);
create index if not exists idx_history_updated_at on public.processing_history(updated_at);
create index if not exists idx_history_deleted_at on public.processing_history(deleted_at);
create index if not exists idx_history_created_at on public.processing_history(created_at);

-- 6) processing_history RLS
alter table public.processing_history enable row level security;

create policy "processing_history_select_own"
    on public.processing_history for select
    using (auth.uid() = user_id);

create policy "processing_history_insert_own"
    on public.processing_history for insert
    with check (auth.uid() = user_id);

create policy "processing_history_update_own"
    on public.processing_history for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "processing_history_delete_own"
    on public.processing_history for delete
    using (auth.uid() = user_id);

-- 참고: updated_at 트리거는 의도적으로 추가하지 않는다.
-- 20260813000000_fix_updated_at_trigger.sql에서 제거한 것과 동일한 이유:
-- 클라이언트가 보낸 updated_at을 그대로 저장해야 last-write-wins 충돌 해결이 동작한다.