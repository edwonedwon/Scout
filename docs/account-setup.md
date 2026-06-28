# Account setup: Supabase + PowerSync

One-time setup to turn on cloud auth + sync. Until step 4 is done, the app runs local-only and the
login screen stays hidden (by design — nothing is broken in the meantime).

## 1. Supabase

1. Go to https://supabase.com → **New project**. Pick a name, a strong DB password, a region near you.
2. When it's ready: left sidebar → **SQL Editor** → **New query** → paste the *entire* contents of
   [`db/supabase-schema.sql`](../db/supabase-schema.sql) → **Run**. This creates the tables, the
   Row-Level Security policies, the photos Storage bucket, and the email-lookup function.
3. Left sidebar → **Project Settings** → **API**:
   - copy **Project URL** → this is `SupabaseConfig.url`
   - copy the **`anon` `public`** key → this is `SupabaseConfig.anonKey`
     (safe to ship — RLS protects the data; never use the `service_role` key here)
4. **Auth** is already on for email/password. Optional but recommended: **Authentication → Providers
   → Email** → turn **Confirm email** on (or off if you want instant sign-up during testing).

### Sign in with Apple (optional — email/password works without this)
Apple's OAuth is the fiddly part; skip it for first tests.
1. Apple Developer → **Certificates, IDs & Profiles**:
   - ensure the App ID `com.cutetech.scout` has **Sign in with Apple** enabled,
   - create a **Services ID**, enable Sign in with Apple on it,
   - create a **Key** with Sign in with Apple, download the `.p8`, note the Key ID + Team ID.
2. Supabase → **Authentication → Providers → Apple** → enable it, fill in the Services ID, Team ID,
   Key ID, and the `.p8` contents.
3. Still under the Apple provider, add **`com.cutetech.scout`** to the list of authorized client IDs
   so the *native* id-token's audience validates (native Sign in with Apple uses the bundle id, not
   the Services ID).

## 2. PowerSync

1. Go to https://www.powersync.com → create an account → **Create instance** (free tier is fine).
2. Connect it to your Supabase Postgres: PowerSync will ask for the database connection string —
   get it from Supabase → **Project Settings → Database → Connection string** (use the direct
   connection / the credentials it shows). Paste into PowerSync's "connect database" step.
3. **Sync Rules**: define which rows each user gets. A simple starting rule set that mirrors the RLS
   (owner or member sees the whole project tree):
   ```yaml
   bucket_definitions:
     user_projects:
       # Projects the user owns or is a member of
       parameters:
         - select id as project_id from projects where owner_id = request.user_id()
         - select project_id from project_members where user_id = request.user_id()
       data:
         - select * from projects where id = bucket.project_id
         - select * from location_lists where project_id = bucket.project_id
         - select * from pins where owning_project_id = bucket.project_id
             or list_id in (select id from location_lists where project_id = bucket.project_id)
         - select * from scripts where project_id = bucket.project_id
         - select * from script_highlights where script_id in
             (select id from scripts where project_id = bucket.project_id)
         - select * from project_members where project_id = bucket.project_id
   ```
   (Adjust to taste; this is a known-good shape, not the only one.)
4. Copy the **instance URL** → this is `SupabaseConfig.powerSyncURL`.

## 3. JWT / auth wiring (PowerSync ⇄ Supabase)

PowerSync must trust Supabase's JWTs. In the PowerSync instance settings, add Supabase as the auth
provider (it has a built-in **Supabase Auth** option) using your Supabase JWT secret / JWKS URL
(Supabase → Project Settings → API → JWT Settings). The app already sends the Supabase access token
via `SupabaseConnector.fetchCredentials()`.

## 4. Put the values in the app

Edit [`Scout/Sources/Persistence/PowerSync/SupabaseConfig.swift`](../Scout/Sources/Persistence/PowerSync/SupabaseConfig.swift):

```swift
static let url = "https://YOURREF.supabase.co"
static let anonKey = "eyJhbGciOi..."          // anon public key
static let powerSyncURL = "https://xxxxx.powersync.journeyapps.com"
```

Rebuild. The login screen now appears; sign up / sign in, and PowerSync connects automatically.

## What to test, in order
1. **Email/password sign-up** → you should land in the app.
2. Sign out (and back in) → session persists across launches.
3. Apple sign-in (once configured).
4. Sync: once the UI is wired to the store (migration plan **P2**), create a project on one device
   and watch it appear on another. (Until P2, the app's screens still read Core Data, so cloud data
   won't be visible in the UI yet — that's the next milestone.)
