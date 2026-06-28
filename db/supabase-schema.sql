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

-- NOTE: Row-Level Security policies (owner/editor/viewer access via project_members) are added
-- in Phase 6. Enable RLS + policies before exposing to multiple users.
