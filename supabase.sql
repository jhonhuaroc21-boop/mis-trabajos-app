-- Funcionalidad adicional: grupos compartidos por curso y carga colaborativa de PDF/Word.
-- Ejecuta este archivo UNA VEZ en Supabase > SQL Editor > New query.
-- No elimina las tablas ni los trabajos existentes.

create table if not exists public.shared_course_groups (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  course_id uuid not null,
  name text not null check (char_length(name) between 1 and 60),
  code text not null unique check (char_length(code) between 8 and 40),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  constraint shared_group_course_owner_match foreign key (course_id, owner_id)
    references public.courses(id, user_id) on delete cascade
);

create table if not exists public.shared_group_members (
  group_id uuid not null references public.shared_course_groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create table if not exists public.shared_group_files (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.shared_course_groups(id) on delete cascade,
  uploaded_by uuid not null references auth.users(id) on delete cascade,
  file_name text not null,
  file_path text not null unique,
  mime_type text not null,
  file_size bigint not null check (file_size > 0 and file_size <= 20971520),
  created_at timestamptz not null default now()
);

alter table public.shared_course_groups enable row level security;
alter table public.shared_group_members enable row level security;
alter table public.shared_group_files enable row level security;

-- Acceso compartido comprobado en funciones SECURITY DEFINER para evitar políticas recursivas.
create or replace function public.is_shared_group_member(p_group_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.shared_course_groups g
    where g.id = p_group_id and g.enabled = true
      and (g.owner_id = p_user_id or exists (
        select 1 from public.shared_group_members m
        where m.group_id = g.id and m.user_id = p_user_id
      ))
  );
$$;
revoke all on function public.is_shared_group_member(uuid, uuid) from public;
grant execute on function public.is_shared_group_member(uuid, uuid) to authenticated;

drop policy if exists "shared_groups_select_member" on public.shared_course_groups;
create policy "shared_groups_select_member" on public.shared_course_groups for select to authenticated
using (owner_id = (select auth.uid()) or public.is_shared_group_member(id, (select auth.uid())));
drop policy if exists "shared_groups_insert_owner" on public.shared_course_groups;
create policy "shared_groups_insert_owner" on public.shared_course_groups for insert to authenticated
with check (
  owner_id = (select auth.uid()) and exists (
    select 1 from public.courses c where c.id = course_id and c.user_id = (select auth.uid())
  )
);
drop policy if exists "shared_groups_update_owner" on public.shared_course_groups;
create policy "shared_groups_update_owner" on public.shared_course_groups for update to authenticated
using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
drop policy if exists "shared_groups_delete_owner" on public.shared_course_groups;
create policy "shared_groups_delete_owner" on public.shared_course_groups for delete to authenticated
using (owner_id = (select auth.uid()));

drop policy if exists "shared_group_members_select_self" on public.shared_group_members;
create policy "shared_group_members_select_self" on public.shared_group_members for select to authenticated
using (user_id = (select auth.uid()));
drop policy if exists "shared_group_members_insert_owner_self" on public.shared_group_members;
create policy "shared_group_members_insert_owner_self" on public.shared_group_members for insert to authenticated
with check (
  user_id = (select auth.uid()) and exists (
    select 1 from public.shared_course_groups g
    where g.id = group_id and g.owner_id = (select auth.uid())
  )
);

drop policy if exists "shared_group_files_select_members" on public.shared_group_files;
create policy "shared_group_files_select_members" on public.shared_group_files for select to authenticated
using (public.is_shared_group_member(group_id, (select auth.uid())));
drop policy if exists "shared_group_files_insert_members" on public.shared_group_files;
create policy "shared_group_files_insert_members" on public.shared_group_files for insert to authenticated
with check (
  uploaded_by = (select auth.uid())
  and public.is_shared_group_member(group_id, (select auth.uid()))
  and split_part(file_path, '/', 1) = group_id::text
  and split_part(file_path, '/', 2) = (select auth.uid())::text
);
drop policy if exists "shared_group_files_delete_uploader_or_owner" on public.shared_group_files;
create policy "shared_group_files_delete_uploader_or_owner" on public.shared_group_files for delete to authenticated
using (
  uploaded_by = (select auth.uid()) or exists (
    select 1 from public.shared_course_groups g
    where g.id = group_id and g.owner_id = (select auth.uid())
  )
);

-- La unión por código valida que el grupo siga activo y no expone otros códigos.
create or replace function public.join_shared_course_group(p_code text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare v_group public.shared_course_groups%rowtype;
begin
  if auth.uid() is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;
  select * into v_group from public.shared_course_groups
  where code = upper(trim(p_code)) and enabled = true limit 1;
  if v_group.id is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  insert into public.shared_group_members(group_id, user_id)
  values (v_group.id, auth.uid()) on conflict do nothing;
  return jsonb_build_object('id', v_group.id, 'name', v_group.name, 'course_id', v_group.course_id);
end;
$$;
revoke all on function public.join_shared_course_group(text) from public;
grant execute on function public.join_shared_course_group(text) to authenticated;

-- Bucket privado para archivos colaborativos. PDF, Word DOC y DOCX; máximo 20 MB por archivo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'shared-docs', 'shared-docs', false, 20971520,
  array['application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document']
)
on conflict (id) do update set
  public = false,
  file_size_limit = 20971520,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "shared_docs_select_members" on storage.objects;
create policy "shared_docs_select_members" on storage.objects for select to authenticated
using (
  bucket_id = 'shared-docs'
  and public.is_shared_group_member(((storage.foldername(name))[1])::uuid, (select auth.uid()))
);
drop policy if exists "shared_docs_insert_members" on storage.objects;
create policy "shared_docs_insert_members" on storage.objects for insert to authenticated
with check (
  bucket_id = 'shared-docs'
  and public.is_shared_group_member(((storage.foldername(name))[1])::uuid, (select auth.uid()))
  and (storage.foldername(name))[2] = (select auth.uid())::text
);
drop policy if exists "shared_docs_delete_uploader_or_owner" on storage.objects;
create policy "shared_docs_delete_uploader_or_owner" on storage.objects for delete to authenticated
using (
  bucket_id = 'shared-docs'
  and (storage.foldername(name))[2] = (select auth.uid())::text
);
