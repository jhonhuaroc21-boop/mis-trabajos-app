-- Mis trabajos — esquema inicial para Supabase
-- Ejecuta todo este archivo en Supabase > SQL Editor > New query.
-- No incluyas nunca una service_role/secret key en index.html.

create extension if not exists pgcrypto;

create table if not exists public.courses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  color text not null default '#4f46e5' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  created_at timestamptz not null default now()
);

create unique index if not exists courses_id_user_id_uq on public.courses(id, user_id);

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 80),
  due date,
  done boolean not null default false,
  guide_path text,
  file_path text,
  created_at timestamptz not null default now(),
  constraint tasks_course_owner_match foreign key (course_id, user_id)
    references public.courses(id, user_id) on delete cascade
);

-- La clave foránea compuesta verifica que el curso pertenece al mismo usuario.
create table if not exists public.shares (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references auth.users(id) on delete cascade,
  code text not null unique check (char_length(code) between 8 and 40),
  label text not null default 'Mis trabajos' check (char_length(label) between 1 and 60),
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.courses enable row level security;
alter table public.tasks enable row level security;
alter table public.shares enable row level security;

-- Cursos: cada usuario solo puede consultar y modificar sus cursos.
drop policy if exists "courses_select_own" on public.courses;
create policy "courses_select_own" on public.courses for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "courses_insert_own" on public.courses;
create policy "courses_insert_own" on public.courses for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "courses_update_own" on public.courses;
create policy "courses_update_own" on public.courses for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists "courses_delete_own" on public.courses;
create policy "courses_delete_own" on public.courses for delete to authenticated using ((select auth.uid()) = user_id);

-- Trabajos: dueño autenticado solamente. La relación compuesta impide asignar un curso ajeno.
drop policy if exists "tasks_select_own" on public.tasks;
create policy "tasks_select_own" on public.tasks for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "tasks_insert_own" on public.tasks;
create policy "tasks_insert_own" on public.tasks for insert to authenticated with check ((select auth.uid()) = user_id and exists (select 1 from public.courses c where c.id = course_id and c.user_id = (select auth.uid())));
drop policy if exists "tasks_update_own" on public.tasks;
create policy "tasks_update_own" on public.tasks for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id and exists (select 1 from public.courses c where c.id = course_id and c.user_id = (select auth.uid())));
drop policy if exists "tasks_delete_own" on public.tasks;
create policy "tasks_delete_own" on public.tasks for delete to authenticated using ((select auth.uid()) = user_id);

-- La tabla de códigos solo la administra el dueño. La lectura compartida ocurre por RPC limitada.
drop policy if exists "shares_select_own" on public.shares;
create policy "shares_select_own" on public.shares for select to authenticated using ((select auth.uid()) = owner_id);
drop policy if exists "shares_insert_own" on public.shares;
create policy "shares_insert_own" on public.shares for insert to authenticated with check ((select auth.uid()) = owner_id);
drop policy if exists "shares_update_own" on public.shares;
create policy "shares_update_own" on public.shares for update to authenticated using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
drop policy if exists "shares_delete_own" on public.shares;
create policy "shares_delete_own" on public.shares for delete to authenticated using ((select auth.uid()) = owner_id);

-- RPC pública y de solo lectura. Devuelve solo cursos y tareas; nunca devuelve rutas de archivos.
create or replace function public.get_shared_workspace(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_label text;
  v_result jsonb;
begin
  select s.owner_id, s.label into v_owner, v_label
  from public.shares s
  where s.code = p_code and s.enabled = true
  limit 1;

  if v_owner is null then
    return jsonb_build_object('error', 'not_found');
  end if;

  select jsonb_build_object(
    'label', v_label,
    'courses', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'user_id', c.user_id, 'name', c.name, 'color', c.color, 'created_at', c.created_at) order by c.created_at)
      from public.courses c where c.user_id = v_owner
    ), '[]'::jsonb),
    'tasks', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'user_id', t.user_id, 'course_id', t.course_id, 'title', t.title, 'due', t.due, 'done', t.done, 'guide_path', t.guide_path, 'file_path', t.file_path, 'created_at', t.created_at) order by t.created_at)
      from public.tasks t where t.user_id = v_owner
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;
revoke all on function public.get_shared_workspace(text) from public;
grant execute on function public.get_shared_workspace(text) to anon, authenticated;

-- Almacenamiento privado de PDF. Crear bucket privado desde SQL si está permitido en el proyecto.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('private-pdfs', 'private-pdfs', false, 20971520, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 20971520, allowed_mime_types = array['application/pdf'];

-- Cada usuario solo puede leer, cargar, reemplazar y borrar archivos dentro de su carpeta UID.
drop policy if exists "pdf_select_own_folder" on storage.objects;
create policy "pdf_select_own_folder" on storage.objects for select to authenticated
using (bucket_id = 'private-pdfs' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "pdf_insert_own_folder" on storage.objects;
create policy "pdf_insert_own_folder" on storage.objects for insert to authenticated
with check (bucket_id = 'private-pdfs' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "pdf_update_own_folder" on storage.objects;
create policy "pdf_update_own_folder" on storage.objects for update to authenticated
using (bucket_id = 'private-pdfs' and (storage.foldername(name))[1] = (select auth.uid())::text)
with check (bucket_id = 'private-pdfs' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "pdf_delete_own_folder" on storage.objects;
create policy "pdf_delete_own_folder" on storage.objects for delete to authenticated
using (bucket_id = 'private-pdfs' and (storage.foldername(name))[1] = (select auth.uid())::text);
