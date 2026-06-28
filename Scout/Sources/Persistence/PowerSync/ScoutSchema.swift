import PowerSync

/// PowerSync local SQLite schema — mirrors `db/supabase-schema.sql`. The `id` (text UUID) primary
/// key is implicit on every PowerSync table, so only the other columns are declared here.
/// Booleans are stored as INTEGER (0/1) and timestamps as TEXT (ISO-8601), matching how the
/// Supabase Postgres columns serialize over the sync protocol.
enum ScoutSchema {
    static let schema = Schema(tables: [
        Table(name: "projects", columns: [
            .text("owner_id"),
            .text("name"),
            .text("notes"),
            .integer("uncategorized_panel_order"),
            .text("created_at"),
            .text("deleted_at"),
        ]),
        Table(name: "location_lists", columns: [
            .text("project_id"),
            .text("parent_list_id"),
            .text("name"),
            .text("color_hex"),
            .text("scene_type"),
            .integer("panel_order"),
            .integer("sort_order"),
            .text("created_at"),
            .text("deleted_at"),
        ]),
        Table(name: "pins", columns: [
            .text("list_id"),
            .text("owning_project_id"),
            .text("name"),
            .text("notes"),
            .real("latitude"),
            .real("longitude"),
            .integer("has_gps"),
            .integer("gps_from_timeline"),
            .integer("is_flagged"),
            .integer("rotation_quarter_turns"),
            .real("aspect_ratio"),
            .integer("panel_order"),
            .integer("sort_order"),
            .text("status_raw"),
            .text("image_source_raw"),
            .text("image_url"),
            .text("google_place_id"),
            .text("google_maps_url"),
            .text("source_url"),
            .text("original_filename"),
            .text("photo_files"),
            .text("thumbnail_files"),
            .text("date_taken"),
            .text("created_at"),
            .text("deleted_at"),
        ]),
        Table(name: "scripts", columns: [
            .text("project_id"),
            .text("name"),
            .text("raw_text"),
            .integer("sort_order"),
            .text("imported_at"),
            .text("updated_at"),
        ]),
        Table(name: "script_highlights", columns: [
            .text("script_id"),
            .text("list_id"),
            .integer("range_start"),
            .integer("range_length"),
            .text("excerpt"),
            .text("context_before"),
            .text("context_after"),
            .text("scene_heading"),
            .text("created_at"),
        ]),
        Table(name: "project_members", columns: [
            .text("project_id"),
            .text("user_id"),
            .text("role"),
            .text("created_at"),
        ]),
    ])
}
