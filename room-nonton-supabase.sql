-- AI Nexus Pro — Room Nonton
-- Jalankan di Supabase SQL Editor setelah membuat project.
-- Aktifkan juga Authentication > Providers > Anonymous Sign-Ins.

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

-- Helper aman untuk mengecek keanggotaan tanpa recursive RLS policy.
-- Security definer diperlukan karena policy room_members tidak boleh
-- membaca room_members melalui policy yang sama (yang menyebabkan recursion).
create or replace function public.is_room_member(p_room_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.room_members
    where room_id = p_room_id
      and user_id = p_user_id
  );
$$;

revoke all on function public.is_room_member(uuid, uuid) from public;
grant execute on function public.is_room_member(uuid, uuid) to authenticated;

-- Rooms: authenticated users can discover active rooms by code.
drop policy if exists "active rooms are readable" on public.rooms;
create policy "active rooms are readable"
on public.rooms for select
to authenticated
using (active = true);

-- A user can create a Room only for their own auth user.
drop policy if exists "users can create own rooms" on public.rooms;
create policy "users can create own rooms"
on public.rooms for insert
to authenticated
with check (host_id = (select auth.uid()));

-- Only the host can change/end a Room.
drop policy if exists "hosts can update rooms" on public.rooms;
create policy "hosts can update rooms"
on public.rooms for update
to authenticated
using (host_id = (select auth.uid()))
with check (host_id = (select auth.uid()));

-- Members can see membership records for Rooms they belong to.
drop policy if exists "members can read room members" on public.room_members;
create policy "members can read room members"
on public.room_members for select
to authenticated
using (public.is_room_member(room_id, (select auth.uid())));

-- A user can add/update only their own membership.
drop policy if exists "users can join rooms" on public.room_members;
create policy "users can join rooms"
on public.room_members for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and (
    is_host = false
    or exists (
      select 1 from public.rooms r
      where r.id = room_id and r.host_id = (select auth.uid())
    )
  )
);

drop policy if exists "users can update own membership" on public.room_members;
create policy "users can update own membership"
on public.room_members for update
to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

-- Comments are visible only to members of the same Room.
drop policy if exists "room members can read comments" on public.room_messages;
create policy "room members can read comments"
on public.room_messages for select
to authenticated
using (public.is_room_member(room_id, (select auth.uid())));

drop policy if exists "room members can send comments" on public.room_messages;
create policy "room members can send comments"
on public.room_messages for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and public.is_room_member(room_id, (select auth.uid()))
);

-- Realtime private-channel authorization.
-- Channel topic used by the app: room:<ROOM_UUID>
drop policy if exists "room members can receive realtime" on realtime.messages;
create policy "room members can receive realtime"
on realtime.messages for select
to authenticated
using (
  realtime.messages.extension in ('broadcast','presence')
  and public.is_room_member(
    split_part(realtime.topic(), ':', 2)::uuid,
    (select auth.uid())
  )
);

drop policy if exists "room members can send realtime" on realtime.messages;
create policy "room members can send realtime"
on realtime.messages for insert
to authenticated
with check (
  realtime.messages.extension in ('broadcast','presence')
  and public.is_room_member(
    split_part(realtime.topic(), ':', 2)::uuid,
    (select auth.uid())
  )
);

-- Enable database changes for comments.
-- If Supabase reports that room_messages is already in the publication,
-- simply skip this statement.
alter publication supabase_realtime add table public.room_messages;
