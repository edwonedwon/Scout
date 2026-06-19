# Scout — Location Scouting App
### Platform: iOS + macOS (SwiftUI, shared codebase via Swift Package)

---

## Vision

An AI-powered location scouting tool for film production. The AI agent searches across the web (maps, social media, video platforms, review sites) using natural language queries, drops pins on a map, and surfaces imagery and metadata about candidate locations. Teams can collaborate, organize locations into project groups, and integrate geo-tagged photos from scouting trips.

---

## Core Features

### 1. AI Chat Search
- Natural language query: *"abandoned industrial warehouse near Osaka with high ceilings"*
- AI agent fans out to multiple sources in parallel:
  - **Google Maps Places API** — POIs, reviews, photos, Street View
  - **Google Custom Search / SerpApi** — web articles and image search in any language
  - **YouTube Data API** — location walk-throughs, travel vlogs
  - **TikTok / Instagram** — via third-party scrapers or RapidAPI wrappers (official APIs have limited search; fallback to embedded webviews or scrapers)
  - **Wikipedia / Wikidata** — structured location data, coordinates
  - **OpenStreetMap Overpass API** — detailed map features (free, no key)
  - **Flickr API** — geotagged creative commons photography
- Agent returns structured `Location` objects: coordinates, name, description, source URLs, images
- Results are pinned on the map instantly as they arrive (streaming)
- Each result card shows: thumbnail gallery, Google Maps deep link, source attribution

### 2. Map View
- **MapKit** (Apple native) as the primary map — works on both iOS and macOS with identical SwiftUI code
- **Google Maps SDK** as optional overlay/alternative (better POI data, Street View)
- **MKMapView** + custom annotation views for pins with thumbnail previews
- Tap a pin → slide-up detail sheet with image carousel, description, links
- Google Maps link opens in Google Maps app / web
- Street View embedded via Google Maps Static API or WKWebView

> **Google Earth**: The Google Earth API was deprecated in 2015. The Google Earth web app can be opened via URL scheme, but embedding it natively isn't supported. MapKit 3D flyover mode is the best native equivalent. For serious 3D terrain, **Cesium** (via WebKit) or **MapLibre GL** are options, but MapKit covers most needs.

### 3. Location Groups (Projects)
- Locations organized into **Projects** (e.g., *Film: Act 1 Locations*)
- Each project has sub-groups/categories (e.g., *Exteriors*, *Interiors*, *Possibles*)
- Tap a group → map filters to show only those pins
- Color-coded pins per group
- Drag locations between groups

### 4. Collaboration / Sharing
- **CloudKit** (free, Apple-native) for sync across the team's devices
  - `CKContainer` with a shared zone — team members accept a share invitation
  - Real-time conflict resolution, offline support
- Alternatively: **Firebase Firestore** if cross-platform sharing with non-Apple users is needed later
- Share a group as a **read-only link** (opens in app or falls back to a generated web view)
- Comments per location (team notes, approval status: *Scout*, *Shortlist*, *Approved*, *Rejected*)

### 5. Geotagged Photo Import
- Import photos from Camera Roll, Files, or a folder (Mac drag-and-drop)
- Read GPS EXIF data → auto-place on map
- Assign to a group/project
- Shown as photo pins (thumbnail as pin icon) on the map
- Photo detail: full image, EXIF metadata, notes field

### 6. GPS Track Import + Photo Alignment
- **Google Maps Timeline export** (JSON / KML from Google Takeout)
- Or **live GPS recording** in-app during scouting trip (CoreLocation background mode)
- Import a batch of photos that lack GPS tags
- Algorithm: for each photo, find the GPS track point whose timestamp is closest to the photo's EXIF `DateTimeOriginal`
- Interpolate between track points for sub-minute accuracy
- Preview the alignment on a timeline scrubber before committing
- Write inferred GPS back to photo EXIF (using `CGImageDestinationAddImageFromSource` + metadata dict) and place on map

---

## Tech Stack

| Layer | Choice | Reason |
|---|---|---|
| UI | SwiftUI | Single codebase for iOS + macOS |
| Map | MapKit (primary) | Native, free, SwiftUI-friendly |
| Map (enhanced) | Google Maps SDK | Richer POI, Street View |
| Backend sync | CloudKit | Free, Apple-native, E2E encrypted |
| AI agent | Claude API (claude-sonnet-4-6) | Tool-calling for multi-source search |
| Web search | Google Custom Search API / SerpApi | Programmatic search results |
| Places data | Google Maps Places API | Photos, reviews, geocoding |
| Video search | YouTube Data API v3 | Location videos |
| Social search | RapidAPI (Instagram/TikTok scrapers) | No official API alternative |
| Photo metadata | ImageIO framework | Read/write EXIF GPS |
| GPS tracks | CoreLocation + KML/JSON parser | Live recording + Google Takeout import |
| Secrets | `.xcconfig.local` (gitignored) | API keys never committed |

---

## Architecture

```
Scout/
├── ScoutKit/               ← Swift Package — all shared logic
│   ├── Models/
│   │   ├── Location.swift
│   │   ├── LocationGroup.swift
│   │   ├── ScoutPhoto.swift
│   │   └── GPSTrack.swift
│   ├── Services/
│   │   ├── AISearchService.swift      ← Claude agent orchestration
│   │   ├── GooglePlacesService.swift
│   │   ├── YouTubeService.swift
│   │   ├── SocialSearchService.swift
│   │   ├── CloudKitSyncService.swift
│   │   ├── PhotoImportService.swift
│   │   └── GPSAlignmentService.swift
│   └── Utilities/
│       ├── EXIFReader.swift
│       └── KMLParser.swift
├── Scout-iOS/              ← iOS app target
│   └── App.swift / ContentView.swift
├── Scout-macOS/            ← macOS app target
│   └── App.swift / ContentView.swift
└── PLAN.md
```

Most views will be in ScoutKit as SwiftUI views with `#if os(iOS)` / `#if os(macOS)` conditionals for platform-specific adaptations (NavigationSplitView on Mac, NavigationStack on iOS).

---

## AI Agent Design

The Claude AI agent is given a set of **tools** it can call:

```
search_google_places(query, location_hint) → [Place]
search_web(query, language) → [WebResult]
search_youtube(query) → [Video]
search_social(query, platform) → [Post]
get_street_view(lat, lng) → ImageURL
geocode(address) → Coordinates
```

The agent receives the user's chat message, decides which tools to call (and in parallel where possible), aggregates results, ranks them by relevance, and returns a structured list of `Location` objects plus a natural language summary. Results stream into the UI as tool calls complete.

---

## API Keys Needed

- Google Maps Platform (Places API, Maps Static API, Street View, Custom Search, YouTube Data API)
- Anthropic (Claude API)
- RapidAPI (social media scrapers — optional, validate need)
- SerpApi (optional alternative to Google Custom Search)

---

## Phases

### Phase 1 — Foundation
- Xcode project: iOS + macOS targets, ScoutKit package
- MapKit integration with pin/group system
- CloudKit data model + sync
- Manual location creation + photo import with EXIF GPS

### Phase 2 — AI Search
- Claude agent with Google Places + web search tools
- Chat UI + streaming pin drops on map
- Location detail sheet with image gallery + Google Maps link

### Phase 3 — Social + Video
- YouTube search tool
- Social media search (RapidAPI wrappers)
- Street View embed in detail sheet

### Phase 4 — GPS Alignment
- CoreLocation background recording
- Google Takeout KML/JSON import
- Photo timestamp alignment algorithm + UI

### Phase 5 — Collaboration
- CloudKit shared zones (team sharing)
- Share link generation
- Comment / approval status per location

---

## Open Questions

1. **Instagram/TikTok**: Official APIs don't support public location search. Options: RapidAPI scrapers (fragile, ToS grey area), embedded webviews with JS extraction, or skip and link out. Recommend starting with YouTube + Google and validating the workflow before investing in social scraping.
2. **Google Earth**: Native embed not possible. MapKit flyover or a WKWebView pointing to `earth.google.com/web` is the closest option. Decide if 3D terrain is a must-have.
3. **Firebase vs CloudKit**: CloudKit is Apple-only but free and private. If the team includes Windows/Android users (e.g., producers), Firebase is more universal but adds cost and complexity. Start with CloudKit, migrate later if needed.
4. **Offline**: Should the map + saved locations work fully offline? CloudKit supports local caching; Google Maps SDK requires a network connection for tiles.
