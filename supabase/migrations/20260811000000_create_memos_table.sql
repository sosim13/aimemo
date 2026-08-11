-- ============================================================================
-- Migration: memos table + RLS + updated_at trigger
-- Created: 2026-08-11
--
-- 로컬 Memo 모델 기반 스키마:
--   memoId TEXT              ->  memo_id text primary key
--   title TEXT NOT NULL       ->  title text not null
--   content TEXT NOT NULL     ->  content text not null
--   category TEXT NOT NULL    ->  category text not null
--   sourceUrl TEXT            ->  source_url text
--   youtubeVideoId TEXT       ->  youtube_video_id text
--   thumbnailUrl TEXT         ->  thumbnail_url text
--   imagePath TEXT            ->  image_path text
--   address TEXT              ->  address text
--   searchKeyword TEXT        ->  search_keyword text
--   kakaoLat REAL             ->  kakao_lat double precision
--   kakaoLng REAL             ->  kakao_lng double precision
--   naverX REAL               ->  naver_x double precision
--   naverY REAL               ->  naver_y double precision
--   userId TEXT               ->  user_id uuid (auth.users.id)
--   updatedAt TEXT            ->  updated_at timestamptz
--   deletedAt TEXT            ->  deleted_at timestamptz (soft delete)
-- ============================================================================

-- 1) updated_at 자동 갱신 함수 — books 마이그레이션에서 이미 생성됨.
--    (동일 함수 재사용, 없으면 생성)
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

-- 2) memos 테이블 생성
create table if not exists public.memos (
    memo_id             text primary key,
    user_id             uuid not null references auth.users(id) on delete cascade,
    title               text not null,
    content             text not null,
    category            text not null,
    source_url          text,
    youtube_video_id    text,
    thumbnail_url       text,
    image_path          text,
    address             text,
    search_keyword      text,
    kakao_lat           double precision,
    kakao_lng           double precision,
    naver_x             double precision,
    naver_y             double precision,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    deleted_at          timestamptz
);

-- 3) 인덱스
create index if not exists idx_memos_user_id      on public.memos(user_id);
create index if not exists idx_memos_updated_at   on public.memos(updated_at);
create index if not exists idx_memos_deleted_at   on public.memos(deleted_at);
create index if not exists idx_memos_category     on public.memos(category);
create index if not exists idx_memos_created_at   on public.memos(created_at);

-- 4) updated_at 자동 갱신 trigger
create trigger trg_memos_set_updated_at
    before update on public.memos
    for each row
    execute function public.set_updated_at();

-- 5) RLS 활성화
alter table public.memos enable row level security;

-- 6) RLS 정책 4개 (본인 only)
create policy "memos_select_own"
    on public.memos for select
    using (auth.uid() = user_id);

create policy "memos_insert_own"
    on public.memos for insert
    with check (auth.uid() = user_id);

create policy "memos_update_own"
    on public.memos for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "memos_delete_own"
    on public.memos for delete
    using (auth.uid() = user_id);
