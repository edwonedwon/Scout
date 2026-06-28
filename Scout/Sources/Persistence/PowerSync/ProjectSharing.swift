import Foundation
import Supabase

/// Project collaboration (migration plan P6) — replaces CKShare. A project's owner adds members by
/// email; each member gets a `project_members` row with a role, and Postgres RLS then scopes what
/// they can see/do. Adding a member writes directly to Supabase (not the local queue) because the
/// target user must exist server-side and RLS must evaluate against live auth state.
struct ProjectSharing {
    static let shared = ProjectSharing()

    enum Role: String, CaseIterable, Identifiable {
        case viewer, editor
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    struct Member: Identifiable, Hashable {
        let id: String
        let userId: String
        let email: String
        let role: String
    }

    enum ShareError: LocalizedError {
        case notConfigured, notSignedIn, userNotFound, selfInvite
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Sharing requires the cloud backend to be configured."
            case .notSignedIn:   return "You must be signed in to share a project."
            case .userNotFound:  return "No Scout account found for that email. Ask them to sign up first."
            case .selfInvite:    return "You already own this project."
            }
        }
    }

    private var client: SupabaseClient? { SupabaseService.client }

    /// Invite a user (by email) to a project with a role. Returns the created membership.
    @discardableResult
    func addMember(projectId: String, email: String, role: Role) async throws -> Member {
        guard let client else { throw ShareError.notConfigured }
        guard let me = client.auth.currentUser else { throw ShareError.notSignedIn }

        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Resolve the email → user id via the SECURITY DEFINER RPC (see db/supabase-schema.sql).
        let lookup: String? = try await client
            .rpc("user_id_for_email", params: ["lookup_email": trimmed])
            .execute()
            .value
        guard let userId = lookup, !userId.isEmpty else { throw ShareError.userNotFound }
        guard userId != me.id.uuidString else { throw ShareError.selfInvite }

        let row: [String: AnyJSON] = [
            "id": .string(UUID().uuidString),
            "project_id": .string(projectId),
            "user_id": .string(userId),
            "role": .string(role.rawValue),
        ]
        try await client.from("project_members")
            .upsert(row, onConflict: "project_id,user_id")
            .execute()

        return Member(id: row["id"]!.stringValue ?? "", userId: userId, email: trimmed, role: role.rawValue)
    }

    /// Current members of a project (owner-only by RLS). Joins emails via the lookup RPC isn't
    /// possible in one call, so we read memberships and resolve emails best-effort.
    func members(projectId: String) async throws -> [Member] {
        guard let client else { throw ShareError.notConfigured }
        let rows: [MemberRow] = try await client.from("project_members")
            .select("id, user_id, role")
            .eq("project_id", value: projectId)
            .execute()
            .value
        return rows.map { Member(id: $0.id, userId: $0.user_id, email: "", role: $0.role) }
    }

    func removeMember(id: String) async throws {
        guard let client else { throw ShareError.notConfigured }
        try await client.from("project_members").delete().eq("id", value: id).execute()
    }

    func changeRole(id: String, role: Role) async throws {
        guard let client else { throw ShareError.notConfigured }
        try await client.from("project_members").update(["role": role.rawValue]).eq("id", value: id).execute()
    }

    private struct MemberRow: Decodable { let id: String; let user_id: String; let role: String }
}

private extension AnyJSON {
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
}
