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

- [x] **P0 — Foundation.** PowerSync + supabase-swift deps; PowerSync `Schema` + `db/supabase-schema.sql`.
- [x] **P1 — Local data layer.** `ScoutStore` over PowerSync SQLite + `*Record` models, full CRUD,
      `watch` queries, transactions. Testable offline with no account.
- [x] **P2 — Wire the UI.** Mac (ContentView/ProjectsPanel/DataInspector/DebugPanel) and the iOS
      browse tree (ScoutIOSRootView/InProjectShell/IOSSidebarDrawer/IOSMapTab/IOSPhotosTab/Script/
      Scout) now read/write the store via the **MacStore VM adapter** (ProjectVM/ListVM/PinVM/
      ScriptVM). RootGate shows the store-backed iOS tree by default. Timeline GPS backfill + original
      relink also ported (relink writes a local-only OriginalPathStore for absolute paths). In-app
      photo imports upload thumb+full to Storage.
      **Residual before P7:** ContentView/ProjectsPanel still have ~40 dead `try? modelContext.save()`
      no-ops + dead `modelContext.undoManager`/`OrphanSweeper.sweep`/`purgeAllProjects(context)`;
      SettingsView still calls the old Core Data `BackupService.importBackup(from:context:)` +
      `PhotoBlobSync.reconcile`. These must be stripped/redirected first. iOS photo import / camera /
      scout recording remain stubs (later milestones, not blockers for P7).
- [x] **P3 — Data import.** `BackupService.importIntoStore(from:)` loads a pre-migration Export zip
      into `ScoutStore` (no auto Core Data migration). Copies photo bytes locally + uploads to
      Storage when configured. (Wire the Import menu action to it as part of P2.)
- [x] **P4 — Cloud sync (code).** `SupabaseConnector` (`fetchCredentials` + `uploadData`), Supabase
      Auth (email/password + Apple), login UI, `ScoutStore.connectIfPossible()`. Needs the user's
      accounts (see `account-setup.md`) to verify Mac ⇄ iPhone end-to-end.
- [x] **P5 — Photos (code).** `PhotoStorageService` (thumbnail/full/original tiers) over Supabase
      Storage; local cache; **originals download is opt-in, off by default** (Settings toggle).
      Storage bucket + RLS in the schema. Hook into pin display/import during P2.
- [x] **P6 — Sharing (code).** `project_members` + RLS; `ProjectSharing` (invite by email via the
      `user_id_for_email` RPC, roles, remove); `ShareProjectView`. Replaces CKShare — no hang.
- [x] **P7 — Cleanup. DONE.** Deleted the entire Core Data/CloudKit stack on both platforms:
      PersistenceController, PhotoBlobSync, OrphanSweeper, the ProjectData/LocationListData/
      PinnedLocationData/ScriptData managed objects, PreviewData, `ScoutModel.xcdatamodeld`, the
      Core Data halves of BackupService (export(ProjectData)/importBackup/fromBackup) and
      PhotoImportService (makePin/fromImport). Removed all `import CoreData`, the modelContext
      injection + no-op `save()` calls + undoManager hookup, the CKShare app/scene delegates, and
      the iCloud/CloudKit/aps entitlements from `project.yml` (Apple Sign-In kept). PhotoSyncProgress
      moved into PhotoSyncBar; list-color palette moved onto ListVM. Both targets build green.

## Auth (DONE in code — P4 backend wiring)
Supabase Auth (GoTrue) with **email/password** and **Sign in with Apple** (OIDC id-token flow).
- `SupabaseConfig.swift` — paste URL / anon key / PowerSync URL here (anon key is public-safe; RLS
  protects data). Blank = auth disabled, app runs local-only (build never blocked).
- `AuthManager` — session + sign in/up/out, password reset, Apple nonce flow; observes
  `authStateChanges`; stores session in Keychain via the SDK.
- `AuthView` — shared login UI (both platforms). `RootGate` in `ScoutApp` shows it until signed in.
- `SupabaseConnector` — PowerSync backend connector: `fetchCredentials` (session token) +
  `uploadData` (CRUD batch → PostgREST upsert/delete). `ScoutStore.connectIfPossible()` starts sync.
- Entitlement `com.apple.developer.applesignin` added for both targets.

## Account setup the USER must do (blocks P4+)
1. Create a **Supabase** project → SQL editor → run `db/supabase-schema.sql` (tables **and** the RLS
   block at the bottom).
2. **Auth → Providers:** Email is on by default. For **Apple**, enable the Apple provider and set the
   Services ID / team / key (Apple Developer → Certificates, IDs & Profiles). For native iOS/macOS
   Sign in with Apple, also add the app's **bundle id** (`com.cutetech.scout`) to the provider's
   allowed client ids so the id-token audience validates.
3. Create a **PowerSync** instance (free tier) → connect it to the Supabase Postgres → define sync
   rules (sync rows where the user owns/belongs to the project) → copy the instance URL.
4. Paste **Supabase URL + anon key + PowerSync URL** into `SupabaseConfig.swift`. (P0–P3 need none.)

## Importing pre-migration data
No automatic Core Data → PowerSync migration. Old projects come in through the existing **Export
Project Data** backup → an **Import** path that writes into `ScoutStore` (wire `BackupService` to the
store; tracked under P3).

## ID strategy
Every row uses a client-generated UUID text primary key (matches today's `uuid`), so offline
inserts never collide and sync is conflict-free on identity.
