-- ============================================================================
-- Migration: books table + RLS + Storage + updated_at trigger
-- Created: 2026-08-10
-- 
-- 로컬 Book 모델 기반 스키마:
--   bookId TEXT PRIMARY KEY  ->  book_id text primary key
--   title TEXT NOT NULL      ->  title text not null
--   author TEXT DEFAULT ''   ->  author text not null default ''
--   coverThumbnailPath TEXT  ->  cover_thumbnail_path text
--   category TEXT DEFAULT    ->  category text not null default '독서'
--   totalReadCount INTEGER   ->  total_read_count integer not null default 0
-- ============================================================================

-- 1) updated_at 자동 갱신 함수 (재사용 가능)
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

-- 2) books 테이블 생성
create table if not exists public.books (
    book_id             text primary key,
    user_id             uuid not null references auth.users(id) on delete cascade,
    title               text not null,
    author              text not null default '',
    cover_thumbnail_path text,
    thumbnail_url       text,
    category            text not null default '독서',
    total_read_count    integer not null default 0,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    deleted_at          timestamptz
);

-- 3) 인덱스
create index if not exists idx_books_user_id      on public.books(user_id);
create index if not exists idx_books_updated_at   on public.books(updated_at);
create index if not exists idx_books_deleted_at   on public.books(deleted_at);
create index if not exists idx_books_title        on public.books(title);

-- 4) updated_at 자동 갱신 trigger
create trigger trg_books_set_updated_at
    before update on public.books
    for each row
    execute function public.set_updated_at();

-- 5) RLS 활성화
alter table public.books enable row level security;

-- 6) RLS 정책 4개 (본인 only)
create policy "books_select_own"
    on public.books for select
    using (auth.uid() = user_id);

create policy "books_insert_own"
    on public.books for insert
    with check (auth.uid() = user_id);

create policy "books_update_own"
    on public.books for update
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy "books_delete_own"
    on public.books for delete
    using (auth.uid() = user_id);

-- 7) Storage: book-covers 버킷 (public 읽기)
insert into storage.buckets (id, name, public)
values ('book-covers', 'book-covers', true)
on conflict (id) do nothing;

-- 8) Storage RLS: book-covers 버킷
--    경로 규칙: user_id/book_id.jpg
--    본인 폴더만 업로드/수정/삭제, 모두 읽기 가능(public bucket)

create policy "book_covers_read_all"
    on storage.objects for select
    using (bucket_id = 'book-covers');

create policy "book_covers_upload_own"
    on storage.objects for insert
    with check (
        bucket_id = 'book-covers'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "book_covers_update_own"
    on storage.objects for update
    using (
        bucket_id = 'book-covers'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "book_covers_delete_own"
    on storage.objects for delete
    using (
        bucket_id = 'book-covers'
        and (storage.foldername(name))[1] = auth.uid()::text
    );
