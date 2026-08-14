-- 메모 이미지 동기화: memo-images Storage 버킷 생성 + RLS 정책
-- 독서 기록 썸네일(book-covers)과 동일한 패턴:
--   경로 규칙: user_id/memo_id.jpg (webp 압축)
--   본인 폴더만 업로드/수정/삭제, 모두 읽기 가능(public bucket)

-- 1) Storage: memo-images 버킷 (public 읽기)
insert into storage.buckets (id, name, public)
values ('memo-images', 'memo-images', true)
on conflict (id) do nothing;

-- 2) Storage RLS: memo-images 버킷
--    경로 규칙: user_id/memo_id.jpg
--    본인 폴더만 업로드/수정/삭제, 모두 읽기 가능(public bucket)

create policy "memo_images_read_all"
    on storage.objects for select
    using (bucket_id = 'memo-images');

create policy "memo_images_upload_own"
    on storage.objects for insert
    with check (
        bucket_id = 'memo-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "memo_images_update_own"
    on storage.objects for update
    using (
        bucket_id = 'memo-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

create policy "memo_images_delete_own"
    on storage.objects for delete
    using (
        bucket_id = 'memo-images'
        and (storage.foldername(name))[1] = auth.uid()::text
    );