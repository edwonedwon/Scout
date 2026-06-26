# Plan: Fountain Script Import & Scene → List Linking

Status: Phases 1–2 DONE (import + sidebar + Script view + third island toggle).
Phases 3–5 (highlights, list-side visualization, re-import/merge) not started.
Owner: Edwon. Last updated: 2026-06-26.

## Goal

Import `.fountain` screenplay files into a project, read them in a dedicated Script
view, and link highlighted sections of the script (scenes / parts of scenes) to
location lists — so each list knows which scene(s) it's the location for, and the
script shows which sections already have a location picked.

## User requirements (verbatim intent)

1. Import `.fountain` files; they live in the sidebar under a new auto-list **"Scripts"**
   (like "Uncategorized"). Multiple scripts allowed.
2. Clicking a script opens a new **Script view** — a third mode in the island toggle
   after Map and Photos. Full script, scrollable.
3. Highlight a section of the script, press **`m`**, assign it to a list (assigning
   locations to scenes / parts of scenes).
4. A system that tracks highlights and their links to lists.
5. Scripts are **imported into project data on disk** (copied in, not referenced), so
   they sync via iCloud. Files are small.
6. **Re-import / update flow**: when a newer script version is imported, a merge screen
   matches recognized sections and lets the user decide what to do with changed ones.
7. Decide how to **visualize "scenes"** on the list side (header icon, or other).

## Data model (SwiftData)

New `@Model`s (in `Scout/Sources/Models/ProjectData.swift` to avoid new-file Xcode
registration, or a new file added to `project.pbxproj`):

- **`ScriptData`**
  - `uuid: UUID`, `name: String` (filename), `rawText: String` (full fountain source),
    `importedAt: Date`, `updatedAt: Date`, `sortOrder: Int`.
  - `@Relationship(deleteRule: .cascade) var highlights: [ScriptHighlight]`
  - `var project: ProjectData?`
- **`ScriptHighlight`** (the scene → list link)
  - `uuid: UUID`, `rangeStart: Int`, `rangeLength: Int` (offsets into `rawText`),
    `excerpt: String` (the highlighted text — the durable anchor for re-import matching),
    `contextBefore: String` / `contextAfter: String` (short surrounding text for fuzzy
    re-matching), `sceneHeading: String?` (nearest preceding scene heading, for matching
    + display), `createdAt: Date`.
  - `var script: ScriptData?`
  - `var list: LocationListData?`  (the linked list)
- **`ProjectData`**: add `@Relationship(deleteRule: .cascade, inverse: \ScriptData.project) var scripts: [ScriptData] = []`
- **`LocationListData`**: add `@Relationship(inverse: \ScriptHighlight.list) var sceneLinks: [ScriptHighlight] = []`
  so a list can show its scenes both ways.

UUID uniqueness: extend `repairDuplicateUUIDs()` to scripts/highlights (selection &
identity rules already key by uuid).

## Fountain parsing

Write a focused parser (no external dependency) in `ScoutKit` or the app target.
Parse `rawText` → `[ScriptElement]` where each element has a type + the source
character range:

- Scene heading (`INT./EXT.` …), Action, Character, Dialogue, Parenthetical,
  Transition, Section (`#`), Synopsis (`=`), Page break, Note (`[[ ]]`), Boneyard
  (`/* */`), Title page block.

MVP fidelity: readable styled text (monospace, bold/upcased scene headings, indented
dialogue/character/parenthetical, right-aligned transitions). Not pixel-perfect
screenplay pagination. Keep source ranges so highlights map to `rawText` offsets.

## Script view + island toggle

- Extend the view-mode enum to `{ map, photos, script }`; add a third segment to the
  island toggle (disabled/placeholder when the project has no scripts).
- Center panel: add a `ScriptView` to the existing ZStack (kept in hierarchy like the
  map and grid, or mounted when a script is active).
- "Active script": selecting a script row in the sidebar sets the active script and
  switches to `.script` mode. With multiple scripts, the Script view shows the active
  one; switching scripts = pick another row.
- **Rendering = `NSTextView` via `NSViewRepresentable`** (macOS). Reasons: real text
  selection with a `selectedRange`, custom background highlight per range (attributed
  string / temporary attributes), click-to-act on highlights, smooth large-doc scroll.
  SwiftUI `Text` can't give programmatic arbitrary selection.

## Highlights / scene → list linking

- Select a range in the Script view → press **`m`** → reuse `MoveToListSheet` (list
  picker) → create a `ScriptHighlight` for `selectedRange` linked to the chosen list.
- Render each highlight with the **linked list's color** as a background, plus a margin
  marker (color swatch + list name). Clicking a highlight selects/reveals that list.
- Persist on create; re-apply highlight attributes when the script opens (map stored
  offsets → text attributes).

## List-side visualization (DECISION NEEDED — recommendation below)

Recommended: **A + C**
- **A. Header indicator**: a small scene icon (e.g. `text.quote` or `film`) — optionally
  with a count — on the list/folder header when the list has ≥1 linked scene (mirrors
  the existing flag indicator). At-a-glance "this list has a scene assigned."
- **C. "Scenes" section in the expanded list**: under a list's photos, a small section
  listing each linked excerpt (scene heading + snippet); clicking one opens the Script
  view scrolled to that highlight. Makes the link useful in both directions.

Alternatives considered: B. count badge only; D. colored scene chips. A+C gives both
the glance and the drill-down.

## Re-import / update (merge) flow

- "Import new version" on an existing script (or importing a file whose name matches).
- For each existing `ScriptHighlight`, re-locate its `excerpt` (+ context / scene
  heading) in the new `rawText`:
  - Exact unique match → auto-carry, remap offsets. (silent)
  - Moved but unique match → auto-carry, remap. (silent)
  - No match or ambiguous → collect for review.
- **Review screen**: summary ("X auto-matched, Y need review"); for each unmatched
  highlight show its excerpt + linked list and let the user: re-assign (select a new
  range in the new text), keep detached, or delete. Replace `rawText` only after review.

## Phasing (each phase builds & ships independently)

1. **Data + import + sidebar**: models, `repairDuplicateUUIDs` extension, "Import
   Script…" picker, "Scripts" virtual sidebar list with rows. (No view yet.)
2. **Script view + island toggle**: `.script` mode, third island segment, fountain
   parser, `NSTextView` read-only styled rendering, open-on-row-select.
3. **Highlights**: text selection + `m` → list picker → `ScriptHighlight`; render
   highlights; persist/reload.
4. **List-side visualization**: header icon/count + "Scenes" section (jump to script).
5. **Re-import / merge**: update flow + highlight re-location + review UI.

## Decisions (locked 2026-06-26)

1. **Scene visualization: A + C** — header scene icon (with count) AND a "Scenes"
   section inside the expanded list, each excerpt clickable to jump to the script.
2. **Highlight unit: any selected text** — free arbitrary ranges (whole scene or part).
3. **Script styling: readable styled text** for v1 (monospace, bold/upcased scene
   headings, indented dialogue/character, right-aligned transitions). Full page-accurate
   pagination is a later polish pass.
4. **Multiple scripts** (assumed, not contested): selecting a script row opens it in
   Script mode; the Script island segment shows the active script. Revisit if needed.

## Notes / constraints

- Keep new `.swift` files registered in `project.pbxproj` (XcodeGen not run by the build
  script) — or add the models to existing files.
- Highlights/selection key by uuid like the rest of the app; extend the dup-uuid repair.
- The unified selection store is photo-centric; script highlights are a separate concept
  (don't shove them into `SelectionStore`).
