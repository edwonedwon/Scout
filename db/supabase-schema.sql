-- Script Scout — Supabase Postgres schema (PowerSync backend).
-- Run this in the Supabase SQL editor on a fresh project.
-- Mirrors the Core Data model; photos live in Supabase Storage (only filenames stored here).
-- All ids are client-generated UUID text so offline inserts never collide.

create table if not exists projects (
    id text primary key,
    owner_id uuid not null default auth.uid(),
    name text not null default '',
    notes text not null default '',
    uncategorized_panel_order bigint not null default 0,
    created_at timestamptz not null default now(),
    deleted_at timestamptz
);

create table if not exists location_lists (
    id text primary key,
    project_id text references projects(id) on delete cascade,
    parent_list_id text references location_lists(id) on delete cascade,
    name text not null default '',
    color_hex text not null default '#FF6B35',
    scene_type text,
    panel_order bigint not null default 0,
    sort_order bigint not null default 0,
    created_at timestamptz not null default now(),
    deleted_at timestamptz
);

create table if not exists pins (
    id text primary key,
    list_id text references location_lists(id) on delete cascade,
    owning_project_id text references projects(id) on delete cascade,
    name text not null default '',
    notes text not null default '',
    latitude double precision not null default 0,
    longitude double precision not null default 0,
    has_gps boolean not null default true,
    gps_from_timeline boolean not null default false,
    is_flagged boolean not null default false,
    rotation_quarter_turns bigint not null default 0,
    aspect_ratio double precision not null default 0,
    panel_order bigint not null default 0,
    sort_order bigint not null default 0,
    status_raw text not null default '',
    image_source_raw text,
    image_url text,
    google_place_id text,
    google_maps_url text,
    source_url text,
    original_filename text,
    -- Photo derivatives kept as JSON arrays of filenames (the files live in Storage, not here).
    photo_files text not null default '[]',
    thumbnail_files text not null default '[]',
    date_taken timestamptz,
    created_at timestamptz not null default now(),
    deleted_at timestamptz
);

create table if not exists scripts (
    id text primary key,
    project_id text references projects(id) on delete cascade,
    name text not null default '',
    raw_text text not null default '',
    sort_order bigint not null default 0,
    imported_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists script_highlights (
    id text primary key,
    script_id text references scripts(id) on delete cascade,
    list_id text references location_lists(id) on delete set null,
    range_start bigint not null default 0,
    range_length bigint not null default 0,
    excerpt text not null default '',
    context_before text not null default '',
    context_after text not null default '',
    scene_heading text,
    created_at timestamptz not null default now()
);

-- Collaboration: who can access a project (replaces CKShare). role = owner | editor | viewer.
create table if not exists project_members (
    id text primary key,
    project_id text references projects(id) on delete cascade,
    user_id uuid not null,
    role text not null default 'viewer',
    created_at timestamptz not null default now(),
    unique (project_id, user_id)
);

create index if not exists idx_lists_project on location_lists(project_id);
create index if not exists idx_lists_parent on location_lists(parent_list_id);
create index if not exists idx_pins_list on pins(list_id);
create index if not exists idx_pins_project on pins(owning_project_id);
create index if not exists idx_scripts_project on scripts(project_id);
create index if not exists idx_highlights_script on script_highlights(script_id);
create index if not exists idx_members_project on project_members(project_id);
create index if not exists idx_members_user on project_members(user_id);

-- ============================================================================
-- Row-Level Security (run this whole block AFTER the tables above).
-- Each signed-in user (auth.uid()) sees only projects they own or are a member
-- of, and every child row inherits that access through its project. This is what
-- makes the shippable multi-user app secure — without it the anon key could read
-- everything. Sharing (editor/viewer) lands in P6 by inserting project_members.
-- ============================================================================

alter table projects          enable row level security;
alter table location_lists    enable row level security;
alter table pins              enable row level security;
alter table scripts           enable row level security;
alter table script_highlights enable row level security;
alter table project_members   enable row level security;

-- Helper: is the current user allowed to touch this project?
create or replace function can_access_project(pid text)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from projects p where p.id = pid and p.owner_id = auth.uid()
  ) or exists (
    select 1 from project_members m where m.project_id = pid and m.user_id = auth.uid()
  );
$$;

-- projects: owner has full control; members can read.
create policy projects_owner_all on projects
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy projects_member_read on projects
  for select using (can_access_project(id));

-- Child tables: gated by the owning project.
create policy lists_access on location_lists
  for all using (can_access_project(project_id)) with check (can_access_project(project_id));
create policy pins_access on pins
  for all using (can_access_project(coalesce(owning_project_id,
                   (select project_id from location_lists l where l.id = pins.list_id))))
  with check (can_access_project(coalesce(owning_project_id,
                   (select project_id from location_lists l where l.id = pins.list_id))));
create policy scripts_access on scripts
  for all using (can_access_project(project_id)) with check (can_access_project(project_id));
create policy highlights_access on script_highlights
  for all using (can_access_project((select project_id from scripts s where s.id = script_highlights.script_id)))
  with check (can_access_project((select project_id from scripts s where s.id = script_highlights.script_id)));

-- project_members: the project owner manages membership; a member can read the roster.
create policy members_owner_all on project_members
  for all using (exists (select 1 from projects p where p.id = project_id and p.owner_id = auth.uid()))
  with check (exists (select 1 from projects p where p.id = project_id and p.owner_id = auth.uid()));
create policy members_self_read on project_members
  for select using (user_id = auth.uid());

-- ============================================================================
-- Storage: photo files (migration plan P5). One private bucket; object paths are
-- `{projectId}/{tier}/{filename}` so access is authorized by the project, exactly
-- like the row tables. Members of a project can read/write its photos.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('photos', 'photos', false)
on conflict (id) do nothing;

create policy photos_read on storage.objects
  for select using (
    bucket_id = 'photos' and can_access_project((storage.foldername(name))[1])
  );
create policy photos_write on storage.objects
  for insert with check (
    bucket_id = 'photos' and can_access_project((storage.foldername(name))[1])
  );
create policy photos_update on storage.objects
  for update using (
    bucket_id = 'photos' and can_access_project((storage.foldername(name))[1])
  );
create policy photos_delete on storage.objects
  for delete using (
    bucket_id = 'photos' and can_access_project((storage.foldername(name))[1])
  );

-- ============================================================================
-- Look up a user id by email so the owner can add collaborators (migration plan
-- P6). SECURITY DEFINER so it can read auth.users; only returns the bare id.
-- ============================================================================
create or replace function user_id_for_email(lookup_email text)
returns uuid language sql security definer stable as $$
  select id from auth.users where lower(email) = lower(lookup_email) limit 1;
$$;
