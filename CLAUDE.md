# Scout / Script Scout — project notes for Claude

## Project generation (XcodeGen)
- The Xcode project is generated from `project.yml` via **XcodeGen**. `Scout.xcodeproj` is NOT
  tracked — never hand-edit `project.pbxproj`.
- After adding/removing/moving source files, run `xcodegen generate`. New `.swift` files under
  `Scout/Sources/` are auto-included. iOS-only files need `#if os(iOS)` guards (same sources
  compile into both the iOS and macOS targets).

## Build / verify
- **Preferred:** `./build.sh` (both platforms) — also `./build.sh mac`, `./build.sh ios`,
  `./build.sh gen` (runs `xcodegen generate` first). It filters output to errors + the final
  BUILD result and exits non-zero on failure.
- Raw commands if needed:
  - macOS: `xcodebuild -project Scout.xcodeproj -scheme Scout_macOS -destination 'platform=macOS' build`
  - iOS:   `xcodebuild -project Scout.xcodeproj -scheme Scout_iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Always build after changes and fix errors before finishing. SourceKit "No such module
  ScoutKit" / "cannot find in scope" diagnostics are false positives — ignore them; trust the
  `xcodebuild` result.

## File organization (post-refactor)
The two former mega-files were split by type/concern; same module, no behavior change.
- **`ContentView`** (the macOS root view) keeps its stored properties + `body` in
  `ContentView.swift`; its methods live in `ContentView+Views/Script/Backup.swift` and
  `Map/ContentView+Map.swift` / `Map/ContentView+Pins.swift` as `extension ContentView`.
  Chrome types (SavedRegion, LocationRow, enums) are in `ContentViewChrome.swift`; the shared
  pin context-menu helpers are in `PinMenu.swift`; map popovers in `Map/MapPanels.swift`.
- **`ProjectDetailView`** (the sidebar) keeps stored props + `body` in `ProjectsPanel.swift`;
  its methods live in `Sidebar/ProjectDetailView+DragDrop/Trash/Rows/Import.swift`. Sidebar
  rows/sheets/helpers are in `Sidebar/SidebarRows.swift`, `SidebarSheets.swift`,
  `SidebarSupport.swift`.
- **`ScoutMapView`** map subviews (ZoomableMapView + annotation views) are in
  `Map/MapMacViews.swift`; boundary/menu helpers in `Map/MapBoundaryViews.swift`.
- Because these are `extension`s of a type, the type and its members are `internal` (not
  `private`) — keep new cross-file members internal, and add new stored properties to the main
  file (extensions can't hold stored properties).

## Release / version bump ritual
When the user says **"set version to X"** (e.g. "set version to 1.2"), do all of this:
1. **Bump the build number** — increment `CURRENT_PROJECT_VERSION` by 1 in `project.yml`.
2. **Set the marketing version** — `MARKETING_VERSION: "X"` in `project.yml`.
3. `xcodegen generate` and build to verify.
4. **Commit** the change.
5. **Tag** it with a **platform suffix** (Git tags can't contain spaces — use a hyphen):
   `git tag -a vX-Mac -m "Version X (Mac)"` or `git tag -a vX-iOS -m "Version X (iOS)"`,
   depending on which platform the current work targets.
6. Mention they can `git push --tags` to push the tag (tags are created locally).

`CFBundleShortVersionString` and `CFBundleVersion` are driven from those two `project.yml`
settings. App Store Connect rejects duplicate build numbers, so always bump the build number.

## Git
- Don't auto-commit; the user controls commits. (The version-bump ritual above is an explicit
  exception — it includes a commit + tag.)
- End commit messages with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
