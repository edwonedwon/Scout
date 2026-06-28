# Migration: Core Data/CloudKit → PowerSync + Supabase

Status: IN PROGRESS (branch `powersync-supabase`). Goal: replace the Apple-only Core Data +
NSPersistentCloudKitContainer stack with an offline-first **PowerSync** local SQLite layer that
syncs to a **Supabase Postgres** backend. Cross-platform (Mac/iOS now, Android/web later),
predictable cost, and sharing via Postgres Row-Level Security instead of CKShare.

## Architecture
- **Device:** PowerSync-managed local **SQLite** is the read/write store. App is fully usable offline.
- **Sync:** PowerSync streams rows Supabase Postgres ⇄ local SQLite; local writes queue and upload
  when online. Last-write-wins by default (customizable).
- **Auth:** Supabase Auth (the user signs in; RLS scopes their data).
- **Photos:** Supabase Storage (or Cloudflare R2). DB rows hold filename references + a local file
  cache (reuse the existing `PinPhotoStore` pattern). Photos NEVER go through PowerSync sync.
- **Sharing:** a `project_members` table + RLS policies (owner/editor/viewer) — replaces CKShare.

## What gets deleted (Apple-specific)
`PersistenceController` (NSPersistentCloudKitContainer), `PhotoBlobSync`/`PhotoBlobData`,
`ScoutModel.xcdatamodeld`, CloudKit entitlements + share UI plumbing, `OrphanSweeper`
(Postgres FKs handle integrity). Keep `BackupService` export/import (repurpose for data import).

## Phases (each stays buildable)

- [ ] **P0 — Foundation (no cloud needed).** Add PowerSync + supabase-swift SPM deps (done).
      Define the PowerSync `Schema` (local tables) and the Supabase SQL schema. Build green.
- [ ] **P1 — Local data layer.** A `Store` abstraction over PowerSync SQLite with typed
      models (Project/List/Pin/Script/Highlight) + CRUD + `watch` queries. Seedable; fully
      testable offline with NO Supabase account.
- [ ] **P2 — Wire the UI.** Replace `@FetchRequest`/`@ObservedObject`(NSManagedObject) usage in
      ContentView, ProjectsPanel, iOS views, DataInspector, DebugPanel with the new store +
      observable queries. App runs entirely on local SQLite.
- [ ] **P3 — Data import.** One-time import of the user's existing data (via the current backup
      export, or a direct Core Data → SQLite migration) so nothing is lost.
- [ ] **P4 — Cloud sync.** Stand up Supabase project + PowerSync instance; add the
      `PowerSyncBackendConnector` (Supabase auth + upload). Verify Mac ⇄ iPhone sync.
- [ ] **P5 — Photos.** Upload/download derivatives via Supabase Storage; local cache; the
      always-visible download progress bar repurposed for Storage fetches.
- [ ] **P6 — Sharing.** `project_members` + RLS (owner/editor/viewer); invite by email; a share
      sheet that adds a member row (no more CKShare hangs).
- [ ] **P7 — Cleanup.** Delete Core Data/CloudKit code + entitlements; update CLAUDE.md.

## Account setup the USER must do (blocks P4+)
1. Create a **Supabase** project → run `db/supabase-schema.sql`.
2. Create a **PowerSync** instance (free tier) → connect it to the Supabase Postgres → define
   sync rules → copy the instance URL.
3. Provide: Supabase URL + anon key, PowerSync instance URL. (P0–P3 need none of this.)

## ID strategy
Every row uses a client-generated UUID text primary key (matches today's `uuid`), so offline
inserts never collide and sync is conflict-free on identity.
