import SwiftUI
import ScoutKit

// MARK: - Name entry sheet

struct NameEntrySheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var confirmLabel: String = "Create"
    let onDismiss: () -> Void
    let onConfirm: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !text.isEmpty { onConfirm(text) } }
            HStack {
                Button("Cancel", action: onDismiss)
                Spacer()
                Button(confirmLabel) { onConfirm(text) }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}

/// New-list sheet for the Script "Create new list and assign" flow: a name field plus an
/// optional "nest inside" picker that reuses the same project.lists source and row style as the
/// Move ("m") box. Selecting a folder nests the new list inside it; "Top level" keeps it loose.
struct NewListForSceneSheet: View {
    let project: ProjectVM
    @Binding var name: String
    let onDismiss: () -> Void
    let onConfirm: (String, ListVM?) -> Void

    /// The committed parent (nil = top level).
    @State private var parent: ListVM?
    @State private var query = ""
    /// Keyboard highlight index into `options` (0 = "Top level", then filtered lists).
    @State private var highlighted = 0
    @FocusState private var nameFocused: Bool

    // Same source + ordering the sidebar and Move box use; trashed excluded.
    private var projectLists: [ListVM] {
        project.lists.filter { $0.deletedAt == nil }.sorted {
            $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
        }
    }
    private var filtered: [ListVM] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return projectLists }
        return projectLists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    /// Selectable options: index 0 is "Top level" (nil), the rest are the filtered lists.
    private var options: [ListVM?] { [nil] + filtered }

    var body: some View {
        VStack(spacing: 14) {
            Text("New List for Scene").font(.headline)
            TextField("List name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(handleReturn)

            VStack(alignment: .leading, spacing: 6) {
                Text("PUT INSIDE (OPTIONAL) — ↑↓ to choose, ⏎ to select")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.caption)
                    TextField("Filter folders…", text: $query).textFieldStyle(.plain)
                        .onSubmit(handleReturn)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                                parentRow(
                                    label: opt?.name ?? "Top level (no folder)",
                                    color: opt.map { Color(hexString: $0.colorHex) },
                                    isSelected: parent?.id == opt?.id,
                                    isHighlighted: idx == highlighted
                                ) {
                                    highlighted = idx
                                    parent = opt
                                }
                                .id(idx)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 160)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: highlighted) { _, _ in
                        withAnimation { proxy.scrollTo(min(max(highlighted, 0), options.count - 1), anchor: .center) }
                    }
                }
            }

            HStack {
                Button("Cancel", action: onDismiss)
                Spacer()
                Button("Create & Assign") { commit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
        // Arrow/escape via hidden shortcut buttons (not .onKeyPress on the field, which on macOS
        // would stop the live text binding — see MoveToListSheet's notes).
        .background {
            Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: []).opacity(0).allowsHitTesting(false)
            Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: []).opacity(0).allowsHitTesting(false)
            Button("") { onDismiss() }.keyboardShortcut(.escape, modifiers: []).opacity(0).allowsHitTesting(false)
        }
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
        .onChange(of: query) { highlighted = 0 }
    }

    @ViewBuilder
    private func parentRow(label: String, color: Color?, isSelected: Bool, isHighlighted: Bool,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if let color {
                Circle().fill(color).frame(width: 9, height: 9)
            } else {
                Image(systemName: "tray").font(.caption2).foregroundStyle(.secondary).frame(width: 9)
            }
            Text(label).font(.subheadline)
            Spacer()
            if isSelected { Image(systemName: "checkmark").font(.caption2).foregroundStyle(.tint) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isHighlighted ? Color.accentColor.opacity(0.25)
                    : (isSelected ? Color.accentColor.opacity(0.12) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private func move(_ delta: Int) {
        guard !options.isEmpty else { return }
        highlighted = (highlighted + delta + options.count) % options.count
    }

    /// Return: if the highlighted option isn't the selected parent yet, SELECT it. If it's
    /// already selected (or it's the preselected top level), CREATE the list.
    private func handleReturn() {
        guard !options.isEmpty else { commit(); return }
        let opt = options[min(max(highlighted, 0), options.count - 1)]
        if parent?.id != opt?.id {
            parent = opt
        } else {
            commit()
        }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed, parent)
    }
}

// MARK: - Import progress overlay

struct ImportProgressOverlay: View {
    let label: String
    let current: Int
    let total: Int

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(current) / Double(total), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 220)
            Text("\(current) of \(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 12)
    }
}

// MARK: - Timeline progress overlay

struct TimelineProgressOverlay: View {
    let current: Int
    let total: Int
    let currentName: String

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(current) / Double(total), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Setting Photo Locations")
                .font(.subheadline.weight(.semibold))
            Text("Matching photos to Timeline history…")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 200)
            if !currentName.isEmpty {
                Text(currentName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 200)
            }
            if total > 0 {
                Text("\(current) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 12)
    }
}

// MARK: - Move-to-list popup

// ⚠️⚠️ DO NOT BREAK THE SEARCH IN THIS VIEW ⚠️⚠️
// The live search here was broken for many debugging rounds. There are THREE separate
// macOS/SwiftUI footguns that each independently break it — all are avoided below, and
// changing any of them brings the bug back (you type "temple" and get an unrelated list):
//
//   1. ForEach row identity MUST be `id: \.id` ONLY. Do NOT also put
//      `.id(idx)` (or any index-based id) on the row. Two competing identities make
//      SwiftUI reuse the row at a given position and keep showing STALE content when the
//      filtered array changes. (This was the final root cause.)
//   2. Do NOT attach `.onKeyPress` to the search TextField. On macOS it intercepts the key
//      path so characters draw in the field but the `text` binding stops updating live —
//      `query` stays "" and nothing filters. Arrow/escape are handled by hidden
//      keyboardShortcut buttons in `.background` instead (see body).
//   3. Read lists from `project.lists` (the forward relationship the sidebar uses), NOT a
//      `@Query` filtered by the `.project` inverse — that inverse isn't reliably set on
//      every list, so the fetch returns a different/partial set.
//
// If you touch this view, re-test: open the M-menu, type a substring of a known list name,
// and confirm ONLY matching lists show, live, on every keystroke.
struct MoveToListSheet: View {
    let project: ProjectVM
    let onMove: (ListVM) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var projectLists: [ListVM] {
        // Use the project.lists forward relationship — the exact same source the
        // sidebar uses — sorted to match sidebar order (panelOrder, then createdAt).
        // Trashed lists are excluded so you can't move photos into a deleted list.
        project.lists.filter { $0.deletedAt == nil }.sorted {
            $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
        }
    }

    private var filtered: [ListVM] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return projectLists }
        return projectLists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// The currently highlighted list (clamped), or nil when there are no results.
    private var highlightedList: ListVM? {
        guard !filtered.isEmpty else { return nil }
        return filtered[min(max(highlighted, 0), filtered.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.square")
                    .foregroundStyle(.secondary)
                TextField("Move to list…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Filtered list
            if filtered.isEmpty {
                Text("No matching lists")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            // Identity is the list's persistentModelID ONLY. A previous
                            // version also set .id(idx), which conflicted with the ForEach
                            // identity and made SwiftUI keep showing a stale row's content
                            // when the filter narrowed — that was the M-menu search bug.
                            ForEach(filtered, id: \.id) { list in
                                let isHi = highlightedList?.id == list.id
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(hexString: list.colorHex))
                                        .frame(width: 9, height: 9)
                                    Text(list.name)
                                        .font(.subheadline)
                                    Spacer()
                                    if isHi {
                                        Image(systemName: "return")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(isHi ? Color.accentColor.opacity(0.15) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { onMove(list) }
                                // ⚠️ Keep this as persistentModelID. NEVER add `.id(idx)` —
                                // see the warning above the struct. It breaks live search.
                                .id(list.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: highlighted) { _, _ in
                        if let hl = highlightedList {
                            withAnimation { proxy.scrollTo(hl.id, anchor: .center) }
                        }
                    }
                    // Cap the scroll area so a long list can't make the sheet taller than the
                    // window — a too-tall .sheet forces macOS to grow the window (and it never
                    // shrinks back). Short lists still size to content via the outer fixedSize.
                    .frame(maxHeight: 320)
                }
            }
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        // Arrow/escape handled by hidden keyboardShortcut buttons rather than
        // .onKeyPress on the TextField — on macOS, attaching .onKeyPress to a
        // focused TextField intercepts the key path and stops the text binding from
        // updating live, which silently broke the search filtering. Letter keys flow
        // straight to the field editor here, so `query` updates on every keystroke.
        .background {
            Button("") { move(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0).allowsHitTesting(false)
            Button("") { move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0).allowsHitTesting(false)
            Button("") { onDismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).allowsHitTesting(false)
        }
        .onAppear {
            highlighted = 0
            // Async focus: in a sheet the window isn't key yet during onAppear, so
            // setting @FocusState synchronously shows a caret but the field never
            // actually becomes first responder — keystrokes get dropped. Defer it.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: query) { highlighted = 0 }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        highlighted = (highlighted + delta + filtered.count) % filtered.count
    }

    private func commit() {
        guard highlighted < filtered.count else { return }
        onMove(filtered[highlighted])
    }
}

/// Compact, keyboard-navigable scene-type chooser (None / INT / EXT / INT/EXT). Opened by pressing
/// "e" with a list selected; ↑/↓ to move, Return to apply, Esc to cancel.
struct SceneTypePickerSheet: View {
    let current: String?
    let onPick: (String?) -> Void
    let onDismiss: () -> Void

    private let options: [String?] = [nil, "INT", "EXT", "INT/EXT"]
    @State private var highlighted = 0

    var body: some View {
        VStack(spacing: 0) {
            Text("Scene Type")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            VStack(spacing: 2) {
                ForEach(options.indices, id: \.self) { idx in
                    let opt = options[idx]
                    let isHi = idx == highlighted
                    HStack(spacing: 8) {
                        Text(opt ?? "None").font(.subheadline)
                        Spacer()
                        if current == opt {
                            Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
                        }
                        if isHi {
                            Image(systemName: "return").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(isHi ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(opt) }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: []).opacity(0).allowsHitTesting(false)
            Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: []).opacity(0).allowsHitTesting(false)
            Button("") { onPick(options[highlighted]) }.keyboardShortcut(.return, modifiers: []).opacity(0).allowsHitTesting(false)
            Button("") { onDismiss() }.keyboardShortcut(.escape, modifiers: []).opacity(0).allowsHitTesting(false)
        }
        .onAppear { highlighted = options.firstIndex(where: { $0 == current }) ?? 0 }
    }

    private func move(_ delta: Int) {
        highlighted = (highlighted + delta + options.count) % options.count
    }
}
