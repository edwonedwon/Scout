import SwiftUI

/// Invite collaborators to a project by email (migration plan P6). Replaces the CKShare sheet —
/// no more "preparing invite link" hangs; adding a member is a single Postgres write.
struct ShareProjectView: View {
    let projectId: String
    let projectName: String
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var role: ProjectSharing.Role = .viewer
    @State private var members: [ProjectSharing.Member] = []
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Share “\(projectName)”").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }

            HStack(spacing: 8) {
                TextField("Collaborator email", text: $email)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $role) {
                    ForEach(ProjectSharing.Role.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                Button("Invite", action: invite)
                    .disabled(!email.contains("@") || busy)
            }

            if let error { Text(error).font(.callout).foregroundStyle(.red) }

            if !members.isEmpty {
                Text("People with access").font(.subheadline.bold())
                ForEach(members) { member in
                    HStack {
                        Image(systemName: "person.crop.circle")
                        Text(member.email.isEmpty ? member.userId : member.email)
                        Spacer()
                        Text(member.role.capitalized).foregroundStyle(.secondary)
                        Button(role: .destructive) { remove(member) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.callout)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
        .task { await reload() }
    }

    private func invite() {
        busy = true; error = nil
        Task {
            do {
                _ = try await ProjectSharing.shared.addMember(projectId: projectId, email: email, role: role)
                email = ""
                await reload()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func remove(_ member: ProjectSharing.Member) {
        Task {
            try? await ProjectSharing.shared.removeMember(id: member.id)
            await reload()
        }
    }

    private func reload() async {
        members = (try? await ProjectSharing.shared.members(projectId: projectId)) ?? []
    }
}
