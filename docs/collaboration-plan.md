# Plan: iCloud Project Sharing & Real-Time Collaboration

Status: PLANNING (not started). Owner: Edwon. Last updated: 2026-06-26.

## Goal

Let the owner (writer/director/scout) share a **project** with another person (e.g. the
line producer) by their Apple ID, so both can open it and see each other's changes in
near-real-time — like collaborating on an Apple Notes note or a Google Doc. Everything
lives in the **owner's iCloud** (the owner is the host); the collaborator reads/writes
into the owner's shared copy. Two roles when inviting:

- **Editor** — can do anything the owner can (add/edit/move/delete lists, pins, photos,
  scripts, scene links, flags, scene types).
- **Viewer** — read-only: can open and look at everything, but cannot change anything.

Out of scope (explicitly): live cursor/selection presence. We sync **data changes**, not
ephemeral UI state like who has what selected.

## Where we're starting from (current reality)

- Persistence is **local SwiftData**: `ScoutApp` uses
  `.modelContainer(for: [ProjectData, LocationListData, PinnedLocationData, ScriptData, ScriptHighlight])`
  with **no CloudKit** configured. (`Scout/Sources/ScoutApp.swift:47`.)
- **No iCloud/CloudKit/push entitlements** exist yet.
- **Photos are on-disk files**, not in the store: `PinnedLocationData.photoFiles` /
  `thumbnailFiles` are filename strings pointing into `PinPhotoStore.directory`
  (Application Support); `originalFilePath` points at the user's local original.
  (`Scout/Sources/PhotoViewerOverlay.swift:175`.) **These files do not sync** — the
  collaborator would see pins with no images. This is the single biggest work item.
- Cross-platform: iOS 17 + macOS 14 (`project.yml`). So the collaborator could be on Mac
  or iPhone/iPad.
- No `@Attribute(.unique)` / `#Unique` anywhere (good — CloudKit forbids uniqueness).

## The core technical question (decide first, via a short spike)

iCloud collaboration with per-record permissions = **CloudKit sharing** (`CKShare`,
participants with `.readWrite` / `.readOnly`, a shared database). The mature, proven host
for this is **`NSPersistentCloudKitContainer`** (Core Data), which natively supports a
`.private` store + a `.shared` store, `share(_:to:)`, participant management, and
read/write permissions — this is exactly what Apple Notes-style sharing uses.

SwiftData syncs to the **private** CloudKit DB (via `ModelConfiguration(... cloudKitDatabase:)`)
but historically has **not** exposed `CKShare` for sharing. So:

- **Path A — SwiftData + CloudKit sharing (preferred if the target OS supports it).**
  Verify whether the deployment OS (current macOS/iOS) now exposes share creation +
  shared store for SwiftData. If yes, keep SwiftData and add sharing on top. Lowest churn.
- **Path B — migrate persistence to Core Data + `NSPersistentCloudKitContainer` (proven fallback).**
  Re-express the five `@Model` types as Core Data entities (the relationships/fields map
  1:1) and drive the existing SwiftUI views from Core Data. Large but battle-tested; the
  only fully-supported sharing path if Path A isn't available.

**Phase 0 is a 1–2 day spike** to confirm which path is viable on our OS targets, because
it determines the size of everything else. Bump `deploymentTarget` if a newer OS is needed
for SwiftData sharing.

## Make the model CloudKit-compatible (both paths)

CloudKit imposes rules the local store doesn't:

- Every relationship must be **optional** (already true) and have an **inverse** (already
  true) — but **no `deleteRule: .cascade`**: CloudKit doesn't honor cascade; deletes must
  be cascaded **manually** in code, or rules relaxed to `.nullify`. We currently rely on
  cascade in several places (project→lists/pins/scripts, list→pins/childLists,
  script→highlights). Need an explicit "delete project and all its children" routine.
- Every non-optional attribute needs a **default value** (CloudKit can't represent
  required-with-no-default). Audit: `name`, `rawText`, `colorHex`, `latitude`, etc. — give
  defaults or make optional.
- Add an explicit **owner/identity** concept only if needed for UI (CloudKit tracks the
  share owner separately).

## Photos — the hard part

For a collaborator to see images, the photo **bytes** must travel through CloudKit, not
sit in local files. Plan:

- Introduce a synced photo payload on the pin (or a child `PhotoAsset` entity):
  `@Attribute(.externalStorage) var displayImageData: Data?` (the ~2048px JPEG) and a
  small `thumbnailData: Data?`. External-storage binary attributes sync as **CKAssets**.
- On import, write these alongside the existing local files (keep local files as the fast
  local cache; the synced data is the source of truth for collaborators).
- **Originals** (RAW/large) stay **owner-local** (via `originalFilePath` + relink) — the
  collaborator gets the 2048px display copy + thumbnail. (Mirrors today's backup, which
  ships thumbnails only.)
- Watch CloudKit per-record size limits and total quota (it counts against the **owner's**
  iCloud). A 100-photo project of 2048px JPEGs is well within limits, but we should batch
  and avoid syncing full originals.

## Sharing flow

- **Granularity: per-project.** A `CKShare` rooted at the project's record; sharing a
  project brings its whole object graph (lists, pins, photos, scripts, scene links).
- **Owner invites:** from a project's context menu / detail → "Share…" → system share UI
  (macOS: `NSSharingServicePicker` with the `CKShare`; iOS: `UICloudSharingController`).
  Add participants by Apple ID / iCloud email, or send a link. Choose **Editor**
  (`.readWrite`) or **Viewer** (`.readOnly`) per participant; changeable later.
- **Collaborator accepts:** tapping the link / accepting opens the app and the shared
  project appears (served from their **shared** DB). Handle the accept via
  `userDidAcceptCloudKitShareWith` (the scene/app delegate).
- **Role enforcement:** read the share's permission for the current user; **Viewers get a
  read-only UI** (hide/disable add, edit, delete, drag, assign, rename, flag, scene-type,
  trash). CloudKit also rejects writes server-side, but we gate the UI so it's obvious.

## Real-time updates

- Register a **CKDatabaseSubscription** on the shared (and private) DB; enable **remote
  (silent) push** + **Background Modes → Remote notifications**.
- On push, the container **imports** changes; `@Query`-driven views refresh automatically.
  Latency is seconds (like Notes), not keystroke-instant — acceptable per the goal.
- **Conflict policy:** last-writer-wins at the field level is the CloudKit default and is
  fine here (location data, not prose). Verify no merge crashes; the existing
  `repairDuplicateUUIDs` stays useful.

## Entitlements / project config

- iCloud capability with **CloudKit** + a container id (e.g. `iCloud.com.edwon.Scout`).
- **Push Notifications** + **Background Modes: Remote notifications**.
- Add these to a `Scout.entitlements` (none today) and wire in `project.yml`.
- Requires a paid Apple Developer account; distribute to the collaborator via **App Store
  or TestFlight**; both users must be signed into iCloud.

## Phasing (each phase builds & ships independently)

0. **Spike (decide Path A vs B).** Stand up CloudKit on a throwaway branch; confirm whether
   SwiftData sharing works on our OS targets. Output: the architecture decision.
1. **Private CloudKit sync.** Make the model CloudKit-compatible (optional/defaults, manual
   cascade), add entitlements, enable the private DB. Goal: a single user's data syncs
   across *their own* devices. No sharing yet. (De-risks the schema + photo sync.)
2. **Photo assets.** Move display+thumbnail image bytes into synced storage so a second
   device shows images. Keep local-file cache.
3. **Per-project share + accept.** Create `CKShare` for a project, present share UI, handle
   accept; shared project shows up for the collaborator (full access for now).
4. **Roles.** Editor vs Viewer on invite + change; read-only UI gating for Viewers.
5. **Real-time.** Subscriptions, push, background import, conflict pass.
6. **Polish.** Manage participants (remove / change role / stop sharing), "shared" badge on
   shared projects, graceful offline + not-signed-in-to-iCloud states.

## Decisions (locked 2026-06-26)

1. **Platform: Mac first, iOS soon.** Both will be supported, but the iOS app isn't being
   built yet. Build the Mac sharing UI now (`NSSharingServicePicker` + the macOS accept
   flow); keep the sharing/sync layer platform-agnostic so adding `UICloudSharingController`
   for iOS later is small. The CloudKit data is shared across platforms automatically once
   iOS ships.
2. **Photo sync: display copy (2048px) + thumbnail.** Originals (RAW/large) stay
   owner-local via relink. Keeps the owner's iCloud quota sane; collaborator sees
   good-quality images.
3. **Granularity: per-project.** Invite someone to a specific project; they see only that
   project (its lists, pins, photos, scripts, scene links).

## Risks / notes

- **Biggest risk:** SwiftData sharing maturity (Path A vs B). The spike resolves it before
  committing to the migration cost.
- **Photos drive iCloud quota** (the owner's). Sync display copies, not originals.
- **Cascade deletes** must be reimplemented manually under CloudKit.
- This is a distribution change too: signing, entitlements, App Store/TestFlight, both
  users on iCloud.
- Keep the existing local-file photo cache and the zip backup/export — they remain the
  offline/portable path and a safety net during migration.
