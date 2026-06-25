# Scout iOS — Implementation Plan

## Overview

iPhone app with 1:1 feature parity with the Mac version plus two exclusive features:
GPS trail recording and in-trip camera. All data syncs via CloudKit (except original large photo files).

---

## Sync Architecture

**CloudKit + SwiftData** — add `.cloudKitDatabase(.private)` to the existing `ModelConfiguration`.
Same `ProjectData`, `LocationListData`, `PinnedLocationData` models sync transparently with zero extra sync code.

| What syncs | What doesn't |
|---|---|
| All SwiftData models | Compressed JPEGs / thumbnails (app container) |
| GPS, notes, lists, pin order | Original large photo files (intentional) |
| Track recordings | — |

**Photo files on iOS:** Compressed JPEGs are not in CloudKit (too large per-record, 1 MB limit).
- Google/source pins → re-download from URL on demand (already works)
- Imported photos → placeholder shown until user re-imports on that device, or we add iCloud Drive sync later
- In-trip camera photos → stored locally on iPhone, not synced to Mac as files (metadata syncs)

**CloudKit schema requirements before enabling:**
- All `@Relationship` inverses must be explicit
- All optional relationships need `deleteRule: .nullify` (CloudKit rejects `.cascade` on optional)
- Audit pass required before first sync test

---

## Project Structure

New `ScoutIOS` Xcode target sharing the `ScoutKit` package and all model/service files.

```
Scout/              ← existing Mac target (unchanged)
ScoutKit/           ← shared package
  Models/           ← ScoutLocation, ScoutImage, GPSTrack, etc.
  Services/         ← GooglePlacesService, etc.

Scout/Sources/Models/         ← shared SwiftData models (both targets)
Scout/Sources/PhotoImportService.swift  ← shared (uses CGImageSource, works on iOS)
Scout/Sources/PinPhotoStore   ← shared (app container path works on both)
Scout/Sources/TimelineGeoService.swift  ← shared
Scout/Sources/BackupService.swift       ← shared

ScoutIOS/Sources/
  App/
    ScoutIOSApp.swift
    ContentView.swift         ← TabView root
  Map/
    MapTab.swift              ← Full-screen MKMapView + bottom sheet callout
    PinCalloutSheet.swift     ← Bottom sheet replacing Mac NSPopover
  Projects/
    ProjectsTab.swift         ← NavigationStack root
    ProjectListView.swift     ← List of projects
    ProjectDetailView.swift   ← Lists within a project
    ListDetailView.swift      ← Pins within a list
    PinDetailView.swift       ← Pin info + photo viewer
  Photos/
    PhotosTab.swift           ← Masonry grid (shared PhotoGridView logic)
  Camera/
    InTripCameraView.swift    ← AVCaptureSession during scouting trip
  Scouting/
    ScoutTab.swift            ← Trip recorder root
    ScoutingSessionView.swift ← Live recording UI
    TrackHistoryView.swift    ← Past trips
```

---

## Tab Structure

```
┌─────────────────────────────────┐
│           [Tab content]         │
│                                 │
│                                 │
│                                 │
├─────────────────────────────────┤
│  🗺 Map  │ 📁 Projects │ 🖼 Photos │ 🎯 Scout  │
└─────────────────────────────────┘
```

### Map Tab
- Full-screen `MKMapView`
- Search bar at top (collapses on scroll)
- Tap pin → bottom sheet slides up (replaces Mac NSPopover)
- Bottom sheet shows: photo strip, name, description, links, save-to-list menu
- Long-press map → add new location
- Saved project pins shown with list color (same as Mac)
- During scouting trip: live polyline overlay + blinking record indicator

### Projects Tab
`NavigationStack` hierarchy:
```
Project List
  └─ Project Detail (lists + uncategorized)
       └─ List Detail (pins in sort order)
            └─ Pin Detail (photo carousel, notes, GPS, edit)
```
- Swipe-to-delete on pins and lists
- Drag-to-reorder via `.onMove`  
- Context menu: Rename, Move to list, Remove from list
- Tap pin → pushes Pin Detail (same data as Mac sidebar row)

### Photos Tab
- Same masonry grid logic as Mac
- Same section-per-list structure
- Same size slider at bottom
- Tap photo → full-screen carousel (same `PhotoViewerState` logic)
- No sidebar cross-selection (instead: "Show in Projects" button in carousel)

### Scout Tab
- Idle state: big "Start Scouting" button, recent trips list
- Recording state: live map with trail, elapsed time, distance, photo count
- Floating camera button → opens `InTripCameraView`
- Stop → names the trip, saves `GPSTrack` to SwiftData

---

## Scouting Trip Feature

### GPS Trail Recording
```swift
// CLLocationManager with background updates
manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
manager.allowsBackgroundLocationUpdates = true
manager.pausesLocationUpdatesAutomatically = false
```
- Points appended to `GPSTrack.points: [TrackPoint]` in real time
- `MKPolyline` overlay updated as points arrive
- Track saved to SwiftData → syncs to Mac via CloudKit
- Mac displays tracks as polyline overlays (toggle in map controls)

### In-Trip Camera
On capture:
1. Read EXIF GPS from photo; if absent, inject current `CLLocation` coords
2. Run `PhotoImportService.importOne()` → 2048px JPEG + 300px thumbnail
3. Insert `PinnedLocationData` into current project/active list
4. Pin appears on map immediately
5. Photo syncs to Mac as metadata (files stay on device unless iCloud Drive photo sync added later)

Entitlements required:
- `NSLocationAlwaysAndWhenInUseUsageDescription`
- `NSCameraUsageDescription`
- Background Modes: Location updates

---

## What's Already Cross-Platform

These files need zero changes for iOS:

| File | Notes |
|---|---|
| `Models/ProjectData.swift` | Pure SwiftData, no platform code |
| `PhotoImportService.swift` | `CGImageSource` works on iOS |
| `TimelineGeoService.swift` | Pure Foundation + CoreLocation |
| `BackupService.swift` | Uses `/usr/bin/zip` → needs iOS alternative (AppleArchive) |
| `PinPhotoStore` | App container path works on both |
| `PhotoViewerState.swift` | Pure logic, no platform code |
| `ScoutKit` package | Already has `#if os(iOS)` guards in places |

Mac-specific code that stays Mac-only:
- `NSPopover`, `NSOpenPanel`, `NSHostingController`
- `NSCursor`, `NSEvent.modifierFlags`
- `NSSavePanel`, `NSApp.currentEvent`
- All of `ProjectsPanel.swift` (AppKit-heavy)
- `BackupSection` in `SettingsView` (uses `NSOpenPanel`/`NSSavePanel`)

---

## Implementation Order

1. **CloudKit schema audit** — explicit inverses, nullify rules, two-simulator sync test
2. **`ScoutIOS` target** — Xcode target, shared files, Info.plist, entitlements
3. **Tab skeleton** — `ContentView` with `TabView`, placeholder tabs, SwiftData container
4. **Map tab** — port `ScoutMapView` coordinator (already mostly cross-platform), bottom sheet
5. **Projects tab** — `NavigationStack` hierarchy, reuse model mutation functions
6. **Photos tab** — `PhotoGridView` with minor iOS adaptations (no `.onDrag`, touch gestures)
7. **Scout tab** — `CLLocationManager` trail + `GPSTrack` persistence + map overlay
8. **In-trip camera** — `AVCaptureSession` + `PhotoImportService` + real-time pin insertion
9. **BackupService iOS** — swap `/usr/bin/zip` for `AppleArchive` framework
10. **Polish** — haptics, swipe gestures, Dynamic Type, dark mode, iPad layout

---

## Open Questions

- **Photo file sync:** Accept gap (placeholder on iOS for Mac-imported photos) or add iCloud Drive container sync?
- **iPad layout:** Same tab structure, or adopt Mac-style split view on iPad?
- **Tracks on Mac:** Display as toggle-able overlay, or separate "Trips" panel in sidebar?
- **App name:** Same "Scout" or a variant? (same bundle prefix, different target)
- **Minimum iOS version:** iOS 17 (SwiftData + CloudKit sync improvements) recommended
