import SwiftUI

/// Project sharing entry point used by the Mac/iOS UI. Sharing moved from CloudKit `CKShare` (link
/// invites) to Supabase account-based sharing (`project_members` + RLS, migration plan P6), so this
/// is now a thin wrapper over `ShareProjectView` (invite by email, set editor/viewer, manage the
/// roster). Kept as a separate type so existing call sites (`ProjectShareSheet(project:onDismiss:)`)
/// are unchanged.
struct ProjectShareSheet: View {
    let project: ProjectVM
    let onDismiss: () -> Void

    var body: some View {
        ShareProjectView(projectId: project.id, projectName: project.name)
    }
}
