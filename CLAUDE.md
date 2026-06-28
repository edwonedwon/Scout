# Scout / Script Scout — project notes for Claude

## Project generation (XcodeGen)
- The Xcode project is generated from `project.yml` via **XcodeGen**. `Scout.xcodeproj` is NOT
  tracked — never hand-edit `project.pbxproj`.
- After adding/removing/moving source files, run `xcodegen generate`. New `.swift` files under
  `Scout/Sources/` are auto-included. iOS-only files need `#if os(iOS)` guards (same sources
  compile into both the iOS and macOS targets).

## Build / verify
- macOS: `xcodebuild -project Scout.xcodeproj -scheme Scout_macOS -destination 'platform=macOS' build`
- iOS:   `xcodebuild -project Scout.xcodeproj -scheme Scout_iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Always build after changes and fix errors before finishing. SourceKit "No such module
  ScoutKit" / "cannot find in scope" diagnostics are false positives — ignore them; trust the
  `xcodebuild` result.

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
