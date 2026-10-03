-- AI Nexus Pro — Room Nonton (NO PASSWORD)
-- Jalankan script ini di Supabase SQL Editor.
-- WAJIB: Authentication > Providers > Anonymous Sign-Ins = ON.
-- Room memakai anonymous auth di belakang layar; user tidak perlu email/password.

create extension if not exists pgcrypto;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  host_id uuid not null references auth.users(id) on delete cascade,
  video_url text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.room_members (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  nickname text not null default 'Pengguna',
  is_host boolean not null default false,
  joined_at timestamptz not null default now(),
  unique(room_id, user_id)
);

create table if not exists public.room_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  nickname text not null default 'Pengguna',
  message text not null check (char_length(message) between 1 and 500),
  created_at timestamptz not null default now()
);

create index if not exists rooms_code_idx on public.rooms(code);
create index if not exists room_members_room_idx on public.room_members(room_id);
create index if not exists room_messages_room_time_idx on public.room_messages(room_id, created_at);

alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.room_messages enable row level security;

-- Helper untuk membaca membership tanpa recursive RLS.
create or replace function public.is_room_member(p_room_id uuid, p_user_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.room_members
    where room_id = p_room_id and user_id = p_user_id
  );
$$;

-- Membuat Room + otomatis menjadi host dalam satu transaksi.
create or replace function public.create_watch_room(p_code text, p_nickname text)
returns public.rooms
language plpgsql security definer
set search_path = public
as $$
declare
  v_room public.rooms;
  v_uid uuid := auth.uid();
  v_name text := left(coalesce(nullif(trim(p_nickname), ''), 'Pengguna'), 24);
begin
  if v_uid is null then raise exception 'Sesi pengguna belum tersedia'; end if;
  insert into public.rooms(code, host_id)
  values (upper(trim(p_code)), v_uid)
  returning * into v_room;
  insert into public.room_members(room_id,user_id,nickname,is_host)
  values (v_room.id,v_uid,v_name,true)
  on conflict (room_id,user_id) do update
    set nickname=excluded.nickname,is_host=true;
  return v_room;
end;
$$;

-- Bergabung tanpa password; cukup kode Room.
create or replace function public.join_watch_room(p_code text, p_nickname text)
returns public.rooms
language plpgsql security definer
set search_path = public
as $$
declare
  v_room public.rooms;
  v_uid uuid := auth.uid();
  v_name text := left(coalesce(nullif(trim(p_nickname), ''), 'Pengguna'), 24);
begin
  if v_uid is null then raise exception 'Sesi pengguna belum tersedia'; end if;
  select * into v_room from public.rooms
  where code = upper(trim(p_code)) and active = true
  limit 1;
  if v_room.id is null then raise exception 'Room tidak ditemukan atau sudah ditutup'; end if;
  insert into public.room_members(room_id,user_id,nickname,is_host)
  values (v_room.id,v_uid,v_name,false)
  on conflict (room_id,user_id) do update
    set nickname=excluded.nickname;
  return v_room;
end;
$$;

grant execute on function public.create_watch_room(text,text) to authenticated;
grant execute on function public.join_watch_room(text,text) to authenticated;
grant execute on function public.is_room_member(uuid,uuid) to authenticated;

-- Room dapat ditemukan oleh user anonim yang sudah login anonim.
drop policy if exists "active rooms are readable" on public.rooms;
create policy "active rooms are readable"
on public.rooms for select to authenticated
using (active = true);

-- Update video hanya boleh host.
drop policy if exists "hosts can update rooms" on public.rooms;
create policy "hosts can update rooms"
on public.rooms for update to authenticated
using (host_id = (select auth.uid()))
with check (host_id = (select auth.uid()));

-- Anggota hanya melihat membership Room yang mereka ikuti.
drop policy if exists "members can read room members" on public.room_members;
create policy "members can read room members"
on public.room_members for select to authenticated
using (public.is_room_member(room_id, (select auth.uid())));

-- Komentar hanya dapat dibaca/dikirim anggota Room.
drop policy if exists "room members can read comments" on public.room_messages;
create policy "room members can read comments"
on public.room_messages for select to authenticated
using (public.is_room_member(room_id, (select auth.uid())));

drop policy if exists "room members can send comments" on public.room_messages;
create policy "room members can send comments"
on public.room_messages for insert to authenticated
with check (
  user_id = (select auth.uid())
  and public.is_room_member(room_id, (select auth.uid()))
);

-- Realtime: Room dibuat PUBLIC supaya tidak tersandung private-channel authorization.
-- Data komentar tetap dilindungi RLS di tabel room_messages.
-- Tidak perlu policy realtime.messages untuk channel Room ini.

do $$
begin
  alter publication supabase_realtime add table public.room_messages;
exception when duplicate_object then
  null;
end $$;
