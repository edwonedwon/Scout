import Foundation

/// Connection settings for Supabase (auth + Postgres backend) and the PowerSync sync service.
///
/// HOW TO FILL THESE IN (once your accounts exist — migration plan P4):
///   • `url`     — Supabase → Project Settings → Data API → Project URL
///   • `anonKey` — Supabase → Project Settings → API Keys → `anon` `public` key
///   • `powerSyncURL` — PowerSync dashboard → your instance → Instance URL
///
/// The `anon` key is SAFE to ship in the app: it grants no privileges on its own — every table is
/// guarded by Postgres Row-Level Security (migration plan P6), so a user only ever sees their own
/// rows. This is the standard Supabase client pattern. Do NOT put the `service_role` key here.
///
/// While these are blank, `isConfigured` is false: auth is treated as disabled and the app runs
/// exactly as before (local-only), so the build is never broken by missing accounts.
enum SupabaseConfig {
    static let url = "https://cahtphxqqnlqfxobgkpd.supabase.co"
    static let anonKey = "sb_publishable_BLLDJ8gFO3nsx7pwo6Auiw_Ffz6DpKq"
    static let powerSyncURL = "https://6a40b2e835ca576ca0e04f71.powersync.journeyapps.com"

    static var isConfigured: Bool {
        !url.isEmpty && !anonKey.isEmpty
    }

    /// Sync is only possible once the PowerSync instance URL is also present.
    static var syncEnabled: Bool {
        isConfigured && !powerSyncURL.isEmpty
    }

    static var supabaseURL: URL? { URL(string: url) }
}
