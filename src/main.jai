// Record Collection Manager
// A desktop application for managing vinyl and CD collections

#import "Basic";
#import "GetRect";
#import "Math";
#import "String";
#import "System";
#import "Window_Creation";

Simp :: #import "Simp";
Input :: #import "Input";
SQLite :: #import "SQLite";
Curl :: #import "Curl";
#import "File";
#import "File_Utilities";

#load "test.jai";

// Window state
window: Window_Type;
window_width:  s32 = 2520;
window_height: s32 = 1480;

current_time: float64;
last_time: float64;

// Fonts
title_font: *Simp.Dynamic_Font;
main_font: *Simp.Dynamic_Font;
small_font: *Simp.Dynamic_Font;

// Search state
search_text: string;
search_scroll_value: float;

// Database connection
db: *SQLite.sqlite3;

// Record data structure
Record :: struct {
    id: int;
    number: string;
    artist: string;
    title: string;
    genre: string;
    year: int;
    artwork_path: string;  // Path to cached artwork image
}

// Artwork texture cache
Artwork_Cache_Entry :: struct {
    record_id: int;
    texture: Simp.Texture;
    loaded: bool;
}

artwork_cache: [..] Artwork_Cache_Entry;

// Search results
search_results: [..] Record;
total_record_count: int;  // Total records in database

// Selection state
selected_index: int = -1;  // -1 means nothing selected

// Edit mode
Edit_Mode :: enum {
    NONE;
    ADD;
    EDIT;
    DELETE_CONFIRM;
    ARTWORK_SEARCH;
}

// Artwork search results from Discogs
Artwork_Result :: struct {
    thumb_url: string;
    cover_url: string;
    title: string;
    texture: Simp.Texture;
    texture_loaded: bool;
}

artwork_results: [..] Artwork_Result;
artwork_search_record_id: int;  // Which record we're finding artwork for
artwork_search_pending: bool;   // True when search needs to run (allows UI to show loading first)
artwork_scroll_value: float;
selected_artwork_index: int = -1;  // Which artwork result is highlighted (-1 = none)
artwork_search_text: string;  // Editable search term for artwork lookup

edit_mode: Edit_Mode = .NONE;
edit_mode_just_opened: bool = false;  // Prevents same-frame click-through on dialog buttons

// Form field focus for tab navigation
focused_field: int = 1;  // Which form field has focus (1=Number, 2=Artist, 3=Title, 4=Genre, 5=Year)

// Sort mode
Sort_Mode :: enum {
    ARTIST_AZ;
    ARTIST_ZA;
    YEAR_NEWEST;
    YEAR_OLDEST;
}

sort_mode: Sort_Mode = .ARTIST_AZ;

// Collection statistics cache
Collection_Stats :: struct {
    total_records: int;
    unique_artists: int;
    year_min: int;
    year_max: int;
    top_genres: [5] string;
    top_genre_count: int;
    dirty: bool;  // needs recalculation
}

collection_stats: Collection_Stats;

// Form fields for add/edit
form_number: string;
form_artist: string;
form_title: string;
form_genre: string;
form_year: string;
form_id: int;  // ID of record being edited (for EDIT mode)

// Theme
my_theme: Overall_Theme;

// Color palette for new design
COLOR_BG :: Vector4.{0.08, 0.08, 0.09, 1};           // Main background (darker)
COLOR_PANEL_BG :: Vector4.{0.10, 0.10, 0.11, 1};     // Panel backgrounds
COLOR_SELECTED :: Vector4.{0.15, 0.18, 0.22, 1};    // Selected row highlight
COLOR_ACCENT :: Vector4.{0.2, 0.6, 0.7, 1};          // Teal accent (buttons)
COLOR_ACCENT_HOVER :: Vector4.{0.25, 0.7, 0.8, 1};   // Teal hover
COLOR_TEXT_PRIMARY :: Vector4.{1, 1, 1, 1};          // White
COLOR_TEXT_SECONDARY :: Vector4.{0.5, 0.5, 0.5, 1};  // Gray
COLOR_BORDER :: Vector4.{0.2, 0.2, 0.22, 1};         // Subtle borders

main :: () {
    #if OS == .WINDOWS {
        Windows :: #import "Windows";
        Windows.SetProcessDPIAware();
        Windows.timeBeginPeriod(1);
    }

    // Parse command line flags
    db_path := ifx IS_TEST_BUILD then "data/test_records.db" else "data/records.db";
    test_mode = IS_TEST_BUILD;
    args := get_command_line_arguments();
    for i: 0..args.count-1 {
        if args[i] == "--db" && i + 1 < args.count {
            db_path = args[i + 1];
        }
        if args[i] == "--test" {
            test_mode = true;
        }
        if args[i] == "--watchable" {
            test_watchable = true;
        }
    }

    // Open database
    result := SQLite.sqlite3_open(db_path.data, *db);
    if result != SQLite.SQLITE_OK {
        print("Failed to open database: %\n", db_path);
        return;
    }
    defer SQLite.sqlite3_close(db);

    print("Database opened successfully!\n");

    // Create table if it doesn't exist (needed for fresh databases / tests)
    create_sql := "CREATE TABLE IF NOT EXISTS records (id INTEGER PRIMARY KEY AUTOINCREMENT, number TEXT, artist TEXT, title TEXT, genre TEXT, year INTEGER, artwork_path TEXT)";
    SQLite.sqlite3_exec(db, create_sql.data, null, null, null);

    // Ensure artwork_path column exists (migration for older databases)
    migrate_sql := "ALTER TABLE records ADD COLUMN artwork_path TEXT";
    SQLite.sqlite3_exec(db, migrate_sql.data, null, null, null);
    // Ignore error - column may already exist

    // Ensure artwork directory exists
    make_directory_if_it_does_not_exist("data/artwork");

    // Get initial record count
    get_total_record_count();

    // Mark stats as dirty for initial calculation
    collection_stats.dirty = true;

    // Create window
    window = create_window(window_width, window_height, "Record Collection Manager");
    Simp.set_render_target(window);

    // Initialize fonts
    init_fonts();

    // Initialize UI
    ui_init();

    // Initialize search string
    search_text = copy_string("");

    // Initialize form fields
    form_number = copy_string("");
    form_artist = copy_string("");
    form_title = copy_string("");
    form_genre = copy_string("");
    form_year = copy_string("");
    artwork_search_text = copy_string("");

    // Main loop
    quit := false;
    while !quit {
        current_time = seconds_since_init();
        dt := cast(float)(current_time - last_time);
        Clamp(*dt, 0, 0.1);
        last_time = current_time;

        Input.update_window_events();

        // Run test step (injects synthetic events before they're processed)
        if test_mode run_tests();

        for Input.get_window_resizes() {
            Simp.update_window(it.window);
            if it.window == window {
                should_reinit := (it.width != window_width) || (it.height != window_height);
                window_width = it.width;
                window_height = it.height;
                if should_reinit init_fonts();
            }
        }

        for event: Input.events_this_frame {
            if event.type == .QUIT then quit = true;
            getrect_handle_event(event);

            if event.type == .KEYBOARD && event.key_pressed {
                if event.key_code == .ESCAPE {
                    if edit_mode != .NONE {
                        // Close dialog
                        edit_mode = .NONE;
                    } else if selected_index >= 0 {
                        // Deselect record (close detail panel)
                        selected_index = -1;
                    } else {
                        active_widget_deactivate_all();
                    }
                }

                // Arrow key navigation in record list (only when no dialog open)
                if edit_mode == .NONE {
                    if event.key_code == .ARROW_DOWN {
                        if search_results.count > 0 {
                            selected_index = min(selected_index + 1, search_results.count - 1);
                            scroll_to_selected();
                        }
                    }
                    if event.key_code == .ARROW_UP {
                        if selected_index > 0 {
                            selected_index -= 1;
                            scroll_to_selected();
                        } else if selected_index == 0 {
                            selected_index = -1;
                        }
                    }
                }
            }
        }

        draw_frame(dt);

        if test_should_quit then quit = true;

        reset_temporary_storage();
        sleep_milliseconds(10);
    }
}

init_fonts :: () {
    // Set working directory for font loading
    // The executable will be in the project root, so data/ is relative to it
    #if OS == .MACOS {
        // On macOS, set working directory to where the executable is
        exe_path := get_path_of_running_executable();
        exe_dir := path_strip_filename(exe_path);
        set_working_directory(exe_dir);
    }

    // Use the font we have
    pixel_height := window_height / 28;
    title_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);

    pixel_height = window_height / 42;
    main_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);

    pixel_height = window_height / 54;
    small_font = Simp.get_font_at_size("data", "OpenSans-BoldItalic.ttf", pixel_height);

    // Verify fonts loaded
    if !title_font || !main_font || !small_font {
        print("Error: Could not load fonts from data/\n");
        print("Make sure OpenSans-BoldItalic.ttf is in the data/ directory.\n");
    }
}

draw_frame :: (dt: float) {
    // Set theme
    my_theme = default_theme_procs[Default_Themes.Default]();
    set_default_theme(my_theme);

    // Clear background with new dark color
    Simp.clear_render_target(COLOR_BG.x, COLOR_BG.y, COLOR_BG.z, 1);

    x, y, width, height := get_dimensions(window, true);
    ui_per_frame_update(window, width, height, current_time);

    // Layout constants
    margin := window_height * 0.02;
    top_bar_height := window_height * 0.06;
    footer_height := window_height * 0.05;

    // Fixed two-panel layout: left (40%) + right (60%)
    left_panel_width := (cast(float)window_width - margin * 3) * 0.40;
    right_panel_width := (cast(float)window_width - margin * 3) * 0.60;

    // Draw top bar (search on left, Add button on right)
    top_bar_rect := get_rect(margin, cast(float)window_height - margin - top_bar_height, cast(float)window_width - margin * 2, top_bar_height);
    draw_top_bar(top_bar_rect);

    // Content area (between top bar and footer)
    content_top := cast(float)window_height - margin * 2 - top_bar_height;
    content_bottom := margin + footer_height + margin;
    content_height := content_top - content_bottom;

    // Left panel (record list)
    left_panel_rect := get_rect(margin, content_bottom, left_panel_width, content_height);
    draw_left_panel(left_panel_rect);

    // Right panel (detail view - always visible)
    right_panel_rect := get_rect(margin * 2 + left_panel_width, content_bottom, right_panel_width, content_height);
    draw_right_panel(right_panel_rect);

    // Single footer spanning full width
    footer_rect := get_rect(margin, margin, cast(float)window_width - margin * 2, footer_height);
    draw_footer(footer_rect);

    // Draw edit dialog if in edit mode
    if edit_mode != .NONE {
        draw_edit_dialog();
    }

    draw_popups();

    Simp.swap_buffers(window);
}

get_sort_label :: () -> string {
    if sort_mode == {
        case .ARTIST_AZ;    return "Sort: A-Z";
        case .ARTIST_ZA;    return "Sort: Z-A";
        case .YEAR_NEWEST;  return "Sort: Newest";
        case .YEAR_OLDEST;  return "Sort: Oldest";
    }
    return "Sort";
}

cycle_sort_mode :: () {
    if sort_mode == {
        case .ARTIST_AZ;    sort_mode = .ARTIST_ZA;
        case .ARTIST_ZA;    sort_mode = .YEAR_NEWEST;
        case .YEAR_NEWEST;  sort_mode = .YEAR_OLDEST;
        case .YEAR_OLDEST;  sort_mode = .ARTIST_AZ;
    }
    // Re-sort current results
    if search_text.count >= 2 {
        do_search(search_text);
    } else {
        load_all_records();
    }
}

draw_top_bar :: (r: Rect) {
    // Search field on left (~50%), Sort button, Add button on right
    search_width := r.w * 0.50;
    sort_width := r.w * 0.15;
    button_width := r.w * 0.15;

    // Search bar
    search_rect := get_rect(r.x, r.y, search_width, r.h);
    draw_search_bar(search_rect);

    // Sort button
    sort_theme := my_theme.button_theme;
    sort_theme.font = main_font;
    sort_theme.surface_color = .{0.2, 0.2, 0.22, 1};
    sort_theme.surface_color_over = .{0.25, 0.25, 0.28, 1};
    sort_theme.text_color = COLOR_TEXT_PRIMARY;

    sort_rect := get_rect(r.x + r.w - button_width - sort_width - r.w * 0.02, r.y, sort_width, r.h);
    if button(sort_rect, get_sort_label(), *sort_theme, 300) {
        cycle_sort_mode();
    }

    // Add Record button (teal accent)
    button_theme := my_theme.button_theme;
    button_theme.font = main_font;
    button_theme.surface_color = COLOR_ACCENT;
    button_theme.surface_color_over = COLOR_ACCENT_HOVER;
    button_theme.surface_color_down = .{0.15, 0.5, 0.6, 1};
    button_theme.text_color = COLOR_TEXT_PRIMARY;

    add_btn_rect := get_rect(r.x + r.w - button_width, r.y, button_width, r.h);
    if button(add_btn_rect, "+ Add Record", *button_theme) {
        clear_form();
        focused_field = 1;
        edit_mode = .ADD;
        edit_mode_just_opened = true;
    }
}

draw_search_bar :: (r: Rect) {
    text_theme := my_theme.text_input_theme;
    text_theme.font = main_font;
    text_theme.deactivate_on_enter = false;  // Keep focus after pressing enter

    action, new_text, state := text_input(r, search_text, *text_theme);

    // Check if text was modified (for live search)
    should_search := false;

    if action & .TEXT_MODIFIED {
        // Get the current text from the input state
        current_text := state.text;

        // Only search if the text actually changed
        if current_text != search_text {
            if search_text.data free(search_text.data);
            search_text = copy_string(current_text);
            should_search = true;
        }
    }

    if action & .ENTERED {
        // User pressed enter - also trigger search
        if new_text.count > 0 {
            if search_text.data free(search_text.data);
            search_text = copy_string(new_text);
            should_search = true;
        }
    }

    if should_search {
        // Perform search if we have 2+ characters
        if search_text.count >= 2 {
            do_search(search_text);
        } else {
            clear_search_results();
        }
    }
}

clear_search_results :: () {
    for * search_results {
        if it.number.data free(it.number.data);
        if it.artist.data free(it.artist.data);
        if it.title.data  free(it.title.data);
        if it.genre.data  free(it.genre.data);
        if it.artwork_path.data free(it.artwork_path.data);
    }
    search_results.count = 0;
}

scroll_to_selected :: () {
    if selected_index < 0 return;
    // Approximate row height and adjust scroll to keep selection visible
    row_height := cast(float)main_font.character_height * 2.8;
    target := cast(float)selected_index * row_height;
    search_scroll_value = target;
}

draw_left_panel :: (r: Rect) {
    // Draw panel background
    Simp.set_shader_for_color();
    p0, p1, p2, p3 := get_quad(r);
    Simp.immediate_quad(p0, p1, p2, p3, COLOR_PANEL_BG);

    // Draw border on right edge
    Simp.immediate_quad(.{r.x + r.w - 1, r.y}, .{r.x + r.w, r.y}, .{r.x + r.w, r.y + r.h}, .{r.x + r.w - 1, r.y + r.h}, COLOR_BORDER);

    draw_results(r);
}

draw_results :: (r: Rect) {
    theme := my_theme.scrollable_region_theme;
    theme.region_background.shape.roundedness = 0;
    theme.region_background.color = .{0, 0, 0, 0};  // Transparent - we draw our own bg
    region, inside := begin_scrollable_region(r, *theme);

    row_height := cast(float)main_font.character_height * 2.8;
    s := inside;
    s.y = s.y + s.h - row_height;
    s.h = row_height;
    s.y += search_scroll_value;

    label_theme := my_theme.label_theme;
    label_theme.font = main_font;
    label_theme.alignment = .Left;

    small_label_theme := label_theme;
    small_label_theme.font = small_font;
    small_label_theme.text_color = COLOR_TEXT_SECONDARY;

    if search_results.count == 0 {
        label_theme.alignment = .Center;
        label_theme.text_color = COLOR_TEXT_SECONDARY;
        label(s, "Type to search records...", *label_theme);
    } else {
        for search_results {
            // Draw record row
            draw_record_row(s, it, *label_theme, *small_label_theme, it_index);
            s.y -= row_height;
        }
    }

    end_scrollable_region(region, s.x + s.w, s.y, *search_scroll_value);
}

draw_rounded_corner_mask :: (r: Rect, radius: float, bg: Vector4) {
    // Approximate rounded corners by drawing bg-colored strips that mask the image corners
    // Uses horizontal strips at each corner to carve out a rounded shape
    Simp.set_shader_for_color();
    steps :: 8;
    for i: 0..steps-1 {
        // Calculate how much to inset at this vertical position in the corner
        t := cast(float)(i + 1) / cast(float)steps;
        y_offset := radius * t;
        // Circle equation: x = radius - sqrt(radius^2 - (radius - y_offset)^2)
        dy := radius - y_offset;
        x_inset := radius - cast(float)sqrt(cast(float64)(radius * radius - dy * dy));
        strip_h := radius / cast(float)steps;
        strip_y := y_offset - strip_h;

        // Bottom-left corner
        Simp.immediate_quad(r.x, r.y + strip_y, r.x + x_inset, r.y + strip_y + strip_h, bg);
        // Bottom-right corner
        Simp.immediate_quad(r.x + r.w - x_inset, r.y + strip_y, r.x + r.w, r.y + strip_y + strip_h, bg);
        // Top-left corner
        Simp.immediate_quad(r.x, r.y + r.h - strip_y - strip_h, r.x + x_inset, r.y + r.h - strip_y, bg);
        // Top-right corner
        Simp.immediate_quad(r.x + r.w - x_inset, r.y + r.h - strip_y - strip_h, r.x + r.w, r.y + r.h - strip_y, bg);
    }
}

draw_artwork_placeholder :: (r: Rect) {
    // Draw dark rectangle with "No Artwork" text
    Simp.set_shader_for_color();
    p0, p1, p2, p3 := get_quad(r);
    Simp.immediate_quad(p0, p1, p2, p3, .{0.15, 0.15, 0.15, 1});

    // Draw border
    border_color := Vector4.{0.3, 0.3, 0.3, 1};
    border := 2.0;
    Simp.immediate_quad(.{r.x, r.y}, .{r.x + r.w, r.y}, .{r.x + r.w, r.y + border}, .{r.x, r.y + border}, border_color);
    Simp.immediate_quad(.{r.x, r.y + r.h - border}, .{r.x + r.w, r.y + r.h - border}, .{r.x + r.w, r.y + r.h}, .{r.x, r.y + r.h}, border_color);
    Simp.immediate_quad(.{r.x, r.y}, .{r.x + border, r.y}, .{r.x + border, r.y + r.h}, .{r.x, r.y + r.h}, border_color);
    Simp.immediate_quad(.{r.x + r.w - border, r.y}, .{r.x + r.w, r.y}, .{r.x + r.w, r.y + r.h}, .{r.x + r.w - border, r.y + r.h}, border_color);

    // "No Artwork" text
    label_theme := my_theme.label_theme;
    label_theme.font = small_font;
    label_theme.alignment = .Center;
    label_theme.text_color = .{0.5, 0.5, 0.5, 1};
    label(r, "No Artwork", *label_theme);
}

draw_right_panel :: (r: Rect) {
    // Draw panel background
    Simp.set_shader_for_color();
    p0, p1, p2, p3 := get_quad(r);
    Simp.immediate_quad(p0, p1, p2, p3, COLOR_PANEL_BG);

    if selected_index >= 0 && selected_index < search_results.count {
        draw_detail_panel(r, search_results[selected_index]);
    } else {
        // Placeholder when nothing selected
        draw_detail_placeholder(r);
    }
}

calculate_collection_stats :: () {
    if !collection_stats.dirty return;
    collection_stats.dirty = false;

    // Total records
    collection_stats.total_records = total_record_count;

    // Unique artists
    {
        sql := "SELECT COUNT(DISTINCT artist) FROM records";
        stmt: *SQLite.sqlite3_stmt;
        result := SQLite.sqlite3_prepare_v2(db, sql.data, cast(s32)sql.count, *stmt, null);
        if result == SQLite.SQLITE_OK {
            defer SQLite.sqlite3_finalize(stmt);
            if SQLite.sqlite3_step(stmt) == SQLite.SQLITE_ROW {
                collection_stats.unique_artists = SQLite.sqlite3_column_int(stmt, 0);
            }
        }
    }

    // Year range
    {
        sql := "SELECT MIN(year), MAX(year) FROM records WHERE year > 0";
        stmt: *SQLite.sqlite3_stmt;
        result := SQLite.sqlite3_prepare_v2(db, sql.data, cast(s32)sql.count, *stmt, null);
        if result == SQLite.SQLITE_OK {
            defer SQLite.sqlite3_finalize(stmt);
            if SQLite.sqlite3_step(stmt) == SQLite.SQLITE_ROW {
                collection_stats.year_min = SQLite.sqlite3_column_int(stmt, 0);
                collection_stats.year_max = SQLite.sqlite3_column_int(stmt, 1);
            }
        }
    }

    // Top genres
    {
        // Free old genre strings
        for i: 0..collection_stats.top_genre_count-1 {
            if collection_stats.top_genres[i].data free(collection_stats.top_genres[i].data);
            collection_stats.top_genres[i] = "";
        }
        collection_stats.top_genre_count = 0;

        sql := "SELECT genre, COUNT(*) as cnt FROM records WHERE genre != '' GROUP BY genre ORDER BY cnt DESC LIMIT 5";
        stmt: *SQLite.sqlite3_stmt;
        result := SQLite.sqlite3_prepare_v2(db, sql.data, cast(s32)sql.count, *stmt, null);
        if result == SQLite.SQLITE_OK {
            defer SQLite.sqlite3_finalize(stmt);
            while SQLite.sqlite3_step(stmt) == SQLite.SQLITE_ROW && collection_stats.top_genre_count < 5 {
                genre_ptr := SQLite.sqlite3_column_text(stmt, 0);
                if genre_ptr {
                    collection_stats.top_genres[collection_stats.top_genre_count] = copy_string(to_string(genre_ptr));
                    collection_stats.top_genre_count += 1;
                }
            }
        }
    }
}

draw_detail_placeholder :: (r: Rect) {
    // Recalculate stats if needed
    calculate_collection_stats();

    margin := r.w * 0.08;
    inner := shrink(r, margin);

    label_theme := my_theme.label_theme;
    label_theme.font = title_font;
    label_theme.alignment = .Center;
    label_theme.text_color = COLOR_TEXT_PRIMARY;

    current_y := inner.y + inner.h - cast(float)title_font.character_height * 2;
    line_h := cast(float)title_font.character_height * 1.5;

    // Title
    title_rect := get_rect(inner.x, current_y, inner.w, line_h);
    label(title_rect, "Collection", *label_theme);
    current_y -= line_h * 1.5;

    // Stats using main_font
    stat_theme := my_theme.label_theme;
    stat_theme.font = main_font;
    stat_theme.alignment = .Center;
    stat_theme.text_color = COLOR_TEXT_SECONDARY;
    stat_h := cast(float)main_font.character_height * 1.8;

    // Total records
    stat_rect := get_rect(inner.x, current_y, inner.w, stat_h);
    label(stat_rect, tprint("% records", collection_stats.total_records), *stat_theme);
    current_y -= stat_h;

    // Unique artists
    stat_rect = get_rect(inner.x, current_y, inner.w, stat_h);
    label(stat_rect, tprint("% artists", collection_stats.unique_artists), *stat_theme);
    current_y -= stat_h;

    // Year range
    if collection_stats.year_min > 0 && collection_stats.year_max > 0 {
        stat_rect = get_rect(inner.x, current_y, inner.w, stat_h);
        label(stat_rect, tprint("% - %", collection_stats.year_min, collection_stats.year_max), *stat_theme);
        current_y -= stat_h;
    }

    // Top genres
    if collection_stats.top_genre_count > 0 {
        current_y -= stat_h * 0.5;  // Extra spacing
        stat_rect = get_rect(inner.x, current_y, inner.w, stat_h);
        stat_theme.text_color = COLOR_TEXT_PRIMARY;
        label(stat_rect, "Top Genres", *stat_theme);
        current_y -= stat_h;

        stat_theme.text_color = COLOR_TEXT_SECONDARY;
        for i: 0..collection_stats.top_genre_count-1 {
            stat_rect = get_rect(inner.x, current_y, inner.w, stat_h);
            label(stat_rect, collection_stats.top_genres[i], *stat_theme);
            current_y -= stat_h;
        }
    }
}

draw_detail_panel :: (r: Rect, record: Record) {
    margin := r.w * 0.08;
    inner := shrink(r, margin);

    // Layout from bottom up:
    // 1. Buttons at the very bottom
    button_w := inner.w * 0.35;
    button_h := cast(float)main_font.character_height * 1.8;
    button_y := inner.y;
    button_spacing := inner.w * 0.08;

    // 2. Text area above buttons
    text_area_bottom := button_y + button_h + margin;

    // Calculate text heights
    artist_h := cast(float)title_font.character_height * 1.5;
    album_h := cast(float)main_font.character_height * 1.3;
    year_h := cast(float)small_font.character_height * 1.2;
    text_spacing := margin * 0.3;
    total_text_height := artist_h + album_h + year_h + text_spacing * 2;

    // 3. Artwork fills remaining space above text
    artwork_area_top := inner.y + inner.h;
    artwork_area_bottom := text_area_bottom + total_text_height + margin;
    available_artwork_height := artwork_area_top - artwork_area_bottom;

    artwork_size := min(available_artwork_height, inner.w * 0.85);
    artwork_x := inner.x + (inner.w - artwork_size) / 2;
    artwork_y := artwork_area_top - artwork_size;
    artwork_rect := get_rect(artwork_x, artwork_y, artwork_size, artwork_size);

    // Draw artwork or placeholder
    // Try explicit path first, then auto-detect from data/artwork/<id>.*
    effective_artwork_path := record.artwork_path;
    if effective_artwork_path.count == 0 {
        // Try common image extensions
        extensions :: string.["jpg", "jpeg", "png"];
        for ext: extensions {
            auto_path := tprint("data/artwork/%.%", record.id, ext);
            if file_exists(auto_path) {
                effective_artwork_path = auto_path;
                // Persist to database and update in-memory record so we don't re-detect every frame
                path_copy := copy_string(auto_path);
                update_record_artwork(record.id, path_copy);
                // Update the in-memory search result
                if selected_index >= 0 && selected_index < search_results.count {
                    if search_results[selected_index].artwork_path.data free(search_results[selected_index].artwork_path.data);
                    search_results[selected_index].artwork_path = path_copy;
                }
                break;
            }
        }
    }

    if effective_artwork_path.count > 0 {
        texture := get_artwork_texture(record.id, effective_artwork_path);
        if texture && texture.width > 0 {
            Simp.set_shader_for_images(texture);
            pa, pb, pc, pd := get_quad(artwork_rect);
            Simp.immediate_quad(pa, pb, pc, pd, .{1,1,1,1});
        } else {
            draw_artwork_placeholder(artwork_rect);
        }
    } else {
        draw_artwork_placeholder(artwork_rect);
    }

    // Position text below artwork
    text_y := artwork_y - margin;

    // Artist name (title_font, centered, white)
    artist_rect := get_rect(inner.x, text_y - artist_h, inner.w, artist_h);
    artist_theme := my_theme.label_theme;
    artist_theme.font = title_font;
    artist_theme.alignment = .Center;
    artist_theme.text_color = COLOR_TEXT_PRIMARY;
    label(artist_rect, record.artist, *artist_theme);
    text_y = artist_rect.y - text_spacing;

    // Album title (main_font, centered, light gray)
    title_rect := get_rect(inner.x, text_y - album_h, inner.w, album_h);
    title_theme := my_theme.label_theme;
    title_theme.font = main_font;
    title_theme.alignment = .Center;
    title_theme.text_color = .{0.85, 0.85, 0.85, 1};
    label(title_rect, record.title, *title_theme);
    text_y = title_rect.y - text_spacing;

    // Year + Catalog (small_font, centered, muted)
    year_cat_text: string;
    if record.year > 0 && record.number.count > 0 {
        year_cat_text = tprint("% \u2022 Catalog: %", record.year, record.number);
    } else if record.year > 0 {
        year_cat_text = tprint("%", record.year);
    } else if record.number.count > 0 {
        year_cat_text = tprint("Catalog: %", record.number);
    }
    if year_cat_text.count > 0 {
        yc_rect := get_rect(inner.x, text_y - year_h, inner.w, year_h);
        yc_theme := my_theme.label_theme;
        yc_theme.font = small_font;
        yc_theme.alignment = .Center;
        yc_theme.text_color = COLOR_TEXT_SECONDARY;
        label(yc_rect, year_cat_text, *yc_theme);
    }

    // Edit button (outline/subtle style)
    edit_theme := my_theme.button_theme;
    edit_theme.font = main_font;
    edit_theme.surface_color = .{0.2, 0.2, 0.22, 1};
    edit_theme.surface_color_over = .{0.25, 0.25, 0.28, 1};
    edit_theme.text_color = COLOR_TEXT_PRIMARY;

    edit_rect := get_rect(inner.x + inner.w * 0.5 - button_w - button_spacing * 0.5, button_y, button_w, button_h);
    if button(edit_rect, "Edit", *edit_theme, 200) {
        load_record_to_form(record);
        focused_field = 1;
        edit_mode = .EDIT;
        edit_mode_just_opened = true;
    }

    // Delete button (teal accent)
    delete_theme := my_theme.button_theme;
    delete_theme.font = main_font;
    delete_theme.surface_color = COLOR_ACCENT;
    delete_theme.surface_color_over = COLOR_ACCENT_HOVER;
    delete_theme.text_color = COLOR_TEXT_PRIMARY;

    delete_rect := get_rect(inner.x + inner.w * 0.5 + button_spacing * 0.5, button_y, button_w, button_h);
    if button(delete_rect, "Delete", *delete_theme, 201) {
        edit_mode = .DELETE_CONFIRM;
        edit_mode_just_opened = true;
    }
}

draw_record_row :: (r: Rect, record: Record, label_theme: *Label_Theme, small_theme: *Label_Theme, index: int) {
    // Check if we're visible
    if r.y + r.h < 0 || r.y > cast(float)window_height return;

    pad := r.h * 0.15;

    // Check if this row is selected
    is_selected := (index == selected_index);

    // Draw selection background (subtle blue tint)
    if is_selected {
        Simp.set_shader_for_color();
        p0, p1, p2, p3 := get_quad(r);
        Simp.immediate_quad(p0, p1, p2, p3, COLOR_SELECTED);
    }

    // Make row clickable - use button with invisible style
    button_theme := my_theme.button_theme;
    button_theme.surface_color = .{0, 0, 0, 0};
    button_theme.surface_color_over = .{0.18, 0.20, 0.24, 1};
    button_theme.surface_color_flash = .{0.2, 0.22, 0.26, 1};
    button_theme.surface_color_down = .{0.15, 0.17, 0.20, 1};
    button_theme.frame_color = .{0, 0, 0, 0};
    button_theme.text_color = .{0, 0, 0, 0};

    if button(r, "", *button_theme, index + 1000) {
        selected_index = index;
    }

    // Text only layout - no thumbnails
    text_pad_left := pad * 1.5;

    // Artist name on first line (white, bold)
    artist_rect := r;
    artist_rect.h = r.h * 0.45;
    artist_rect.y = r.y + r.h * 0.5;
    artist_rect.x += text_pad_left;
    artist_rect.w -= text_pad_left + pad;

    my_label_theme := label_theme.*;
    my_label_theme.text_color = COLOR_TEXT_PRIMARY;

    label(artist_rect, record.artist, *my_label_theme);

    // Album title + year on second line (gray, smaller)
    info_rect := artist_rect;
    info_rect.y = r.y + pad;

    my_small_theme := small_theme.*;
    my_small_theme.text_color = COLOR_TEXT_SECONDARY;

    info_text: string;
    if record.year > 0 {
        info_text = tprint("% \u2022 %", record.title, record.year);
    } else {
        info_text = record.title;
    }
    label(info_rect, info_text, *my_small_theme);

    // Draw separator line
    Simp.set_shader_for_color();
    line_y := r.y;
    Simp.immediate_quad(
        .{r.x + text_pad_left, line_y}, .{r.x + r.w - pad, line_y},
        .{r.x + r.w - pad, line_y + 1}, .{r.x + text_pad_left, line_y + 1},
        COLOR_BORDER
    );
}

draw_footer :: (r: Rect) {
    // Draw background
    Simp.set_shader_for_color();
    p0, p1, p2, p3 := get_quad(r);
    Simp.immediate_quad(p0, p1, p2, p3, COLOR_PANEL_BG);

    // Draw top border
    Simp.immediate_quad(.{r.x, r.y + r.h - 1}, .{r.x + r.w, r.y + r.h - 1}, .{r.x + r.w, r.y + r.h}, .{r.x, r.y + r.h}, COLOR_BORDER);

    // Record count centered
    count_theme := my_theme.label_theme;
    count_theme.font = small_font;
    count_theme.alignment = .Center;
    count_theme.text_color = COLOR_TEXT_SECONDARY;

    // Show total count when no search, otherwise show search results count
    count_text: string;
    if search_text.count < 2 {
        count_text = tprint("% records", total_record_count);
    } else {
        count_text = tprint("% records", search_results.count);
    }
    label(r, count_text, *count_theme);
}

do_search :: (query: string) {
    // Clear previous results
    for * search_results {
        if it.number.data free(it.number.data);
        if it.artist.data free(it.artist.data);
        if it.title.data  free(it.title.data);
        if it.genre.data  free(it.genre.data);
        if it.artwork_path.data free(it.artwork_path.data);
    }
    search_results.count = 0;

    // Build query - search artist and title (case insensitive)
    order_by := get_order_by_clause();
    sql := tprint("SELECT id, number, artist, title, genre, year, artwork_path FROM records WHERE artist LIKE '\%%\%' OR title LIKE '\%%\%' %", query, query, order_by);

    stmt: *SQLite.sqlite3_stmt;
    result := SQLite.sqlite3_prepare_v2(db, sql.data, cast(s32)sql.count, *stmt, null);

    if result != SQLite.SQLITE_OK {
        print("SQL error: %\n", result);
        return;
    }

    defer SQLite.sqlite3_finalize(stmt);

    while SQLite.sqlite3_step(stmt) == SQLite.SQLITE_ROW {
        record: Record;
        record.id = SQLite.sqlite3_column_int(stmt, 0);

        // Get text columns - need to copy strings as SQLite memory is temporary
        number_ptr := SQLite.sqlite3_column_text(stmt, 1);
        artist_ptr := SQLite.sqlite3_column_text(stmt, 2);
        title_ptr  := SQLite.sqlite3_column_text(stmt, 3);
        genre_ptr  := SQLite.sqlite3_column_text(stmt, 4);
        record.year = SQLite.sqlite3_column_int(stmt, 5);
        artwork_ptr := SQLite.sqlite3_column_text(stmt, 6);

        if number_ptr record.number = copy_string(to_string(number_ptr));
        if artist_ptr record.artist = copy_string(to_string(artist_ptr));
        if title_ptr  record.title  = copy_string(to_string(title_ptr));
        if genre_ptr  record.genre  = copy_string(to_string(genre_ptr));
        if artwork_ptr record.artwork_path = copy_string(to_string(artwork_ptr));

        array_add(*search_results, record);
    }

    print("Found % results for '%'\n", search_results.count, query);
}

get_order_by_clause :: () -> string {
    if sort_mode == {
        case .ARTIST_AZ;    return "ORDER BY artist COLLATE NOCASE, title COLLATE NOCASE";
        case .ARTIST_ZA;    return "ORDER BY artist COLLATE NOCASE DESC, title COLLATE NOCASE";
        case .YEAR_NEWEST;  return "ORDER BY year DESC, artist COLLATE NOCASE";
        case .YEAR_OLDEST;  return "ORDER BY year ASC, artist COLLATE NOCASE";
    }
    return "ORDER BY artist COLLATE NOCASE, title COLLATE NOCASE";
}

load_all_records :: () {
    // Clear previous results
    for * search_results {
        if it.number.data free(it.number.data);
        if it.artist.data free(it.artist.data);
        if it.title.data  free(it.title.data);
        if it.genre.data  free(it.genre.data);
        if it.artwork_path.data free(it.artwork_path.data);
    }
    search_results.count = 0;

    order_by := get_order_by_clause();
    sql := tprint("SELECT id, number, artist, title, genre, year, artwork_path FROM records %", order_by);

    stmt: *SQLite.sqlite3_stmt;
    result := SQLite.sqlite3_prepare_v2(db, sql.data, cast(s32)sql.count, *stmt, null);

    if result != SQLite.SQLITE_OK {
        print("SQL error: %\n", result);
        return;
    }

    defer SQLite.sqlite3_finalize(stmt);

    while SQLite.sqlite3_step(stmt) == SQLite.SQLITE_ROW {
        record: Record;
        record.id = SQLite.sqlite3_column_int(stmt, 0);

        number_ptr := SQLite.sqlite3_column_text(stmt, 1);
        artist_ptr := SQLite.sqlite3_column_text(stmt, 2);
        title_ptr  := SQLite.sqlite3_column_text(stmt, 3);
        genre_ptr  := SQLite.sqlite3_column_text(stmt, 4);
        record.year = SQLite.sqlite3_column_int(stmt, 5);
        artwork_ptr := SQLite.sqlite3_column_text(stmt, 6);

        if number_ptr record.number = copy_string(to_string(number_ptr));
        if artist_ptr record.artist = copy_string(to_string(artist_ptr));
        if title_ptr  record.title  = copy_string(to_string(title_ptr));
        if genre_ptr  record.genre  = copy_string(to_string(genre_ptr));
        if artwork_ptr record.artwork_path = copy_string(to_string(artwork_ptr));

        array_add(*search_results, record);
    }

    print("Loaded % records\n", search_results.count);
}

// Form helper functions
clear_form :: () {
    set_form_field(*form_number, "");
    set_form_field(*form_artist, "");
    set_form_field(*form_title, "");
    set_form_field(*form_genre, "");
    set_form_field(*form_year, "");
    form_id = 0;
}

set_form_field :: (field: *string, value: string) {
    if field.data free(field.data);
    field.* = copy_string(value);
}

load_record_to_form :: (record: Record) {
    set_form_field(*form_number, record.number);
    set_form_field(*form_artist, record.artist);
    set_form_field(*form_title, record.title);
    set_form_field(*form_genre, record.genre);
    if record.year > 0 {
        set_form_field(*form_year, tprint("%", record.year));
    } else {
        set_form_field(*form_year, "");
    }
    form_id = record.id;
}

draw_edit_dialog :: () {
    // Semi-transparent overlay
    Simp.set_shader_for_color();
    overlay_color := Vector4.{0, 0, 0, 0.6};
    Simp.immediate_quad(
        .{0, 0}, .{cast(float)window_width, 0},
        .{cast(float)window_width, cast(float)window_height}, .{0, cast(float)window_height},
        overlay_color
    );

    // Dialog box
    dialog_w := window_width * 0.65;
    dialog_h := window_height * 0.7;
    dialog_x := (window_width - dialog_w) / 2.0;
    dialog_y := (window_height - dialog_h) / 2.0;
    dialog_rect := get_rect(cast(float)dialog_x, cast(float)dialog_y, cast(float)dialog_w, cast(float)dialog_h);

    // Draw dialog background
    Simp.set_shader_for_color();
    bg_color := my_theme.background_color;
    p0, p1, p2, p3 := get_quad(dialog_rect);
    Simp.immediate_quad(p0, p1, p2, p3, bg_color);

    // Draw border
    border_color := Vector4.{0.5, 0.5, 0.5, 1};
    border := 2.0;
    Simp.immediate_quad(.{dialog_rect.x, dialog_rect.y}, .{dialog_rect.x + dialog_rect.w, dialog_rect.y}, .{dialog_rect.x + dialog_rect.w, dialog_rect.y + border}, .{dialog_rect.x, dialog_rect.y + border}, border_color);
    Simp.immediate_quad(.{dialog_rect.x, dialog_rect.y + dialog_rect.h - border}, .{dialog_rect.x + dialog_rect.w, dialog_rect.y + dialog_rect.h - border}, .{dialog_rect.x + dialog_rect.w, dialog_rect.y + dialog_rect.h}, .{dialog_rect.x, dialog_rect.y + dialog_rect.h}, border_color);
    Simp.immediate_quad(.{dialog_rect.x, dialog_rect.y}, .{dialog_rect.x + border, dialog_rect.y}, .{dialog_rect.x + border, dialog_rect.y + dialog_rect.h}, .{dialog_rect.x, dialog_rect.y + dialog_rect.h}, border_color);
    Simp.immediate_quad(.{dialog_rect.x + dialog_rect.w - border, dialog_rect.y}, .{dialog_rect.x + dialog_rect.w, dialog_rect.y}, .{dialog_rect.x + dialog_rect.w, dialog_rect.y + dialog_rect.h}, .{dialog_rect.x + dialog_rect.w - border, dialog_rect.y + dialog_rect.h}, border_color);

    // Skip drawing interactive content on the frame the dialog was just opened
    // to prevent same-frame click-through from the button that opened it
    if edit_mode_just_opened {
        edit_mode_just_opened = false;
        return;
    }

    if edit_mode == .DELETE_CONFIRM {
        draw_delete_confirm_dialog(dialog_rect);
    } else if edit_mode == .ARTWORK_SEARCH {
        draw_artwork_search_dialog(dialog_rect);
    } else {
        draw_add_edit_dialog(dialog_rect);
    }
}

draw_delete_confirm_dialog :: (dialog_rect: Rect) {
    margin := dialog_rect.h * 0.05;
    inner := shrink(dialog_rect, margin);

    // Title
    title_rect := inner;
    title_rect.h = cast(float)main_font.character_height * 2;
    title_rect.y = inner.y + inner.h - title_rect.h;

    label_theme := my_theme.label_theme;
    label_theme.font = title_font;
    label_theme.alignment = .Center;
    label(title_rect, "Confirm Delete", *label_theme);

    // Message
    msg_rect := title_rect;
    msg_rect.y -= main_font.character_height * 3;
    msg_rect.h = cast(float)main_font.character_height * 2;

    label_theme.font = main_font;
    if selected_index >= 0 && selected_index < search_results.count {
        record := search_results[selected_index];
        msg := tprint("Delete \"% - %\"?", record.artist, record.title);
        label(msg_rect, msg, *label_theme);
    }

    // Buttons
    button_theme := my_theme.button_theme;
    button_theme.font = main_font;

    button_w := inner.w * 0.3;
    button_h := cast(float)main_font.character_height * 2;
    button_y := inner.y + margin;

    // Cancel button
    cancel_rect := get_rect(inner.x + inner.w * 0.2 - button_w / 2, button_y, button_w, button_h);
    if button(cancel_rect, "Cancel", *button_theme) {
        edit_mode = .NONE;
    }

    // Delete button (red-ish)
    delete_theme := button_theme;
    delete_theme.surface_color = .{0.7, 0.2, 0.2, 1};
    delete_theme.surface_color_over = .{0.8, 0.3, 0.3, 1};

    delete_rect := get_rect(inner.x + inner.w * 0.8 - button_w / 2, button_y, button_w, button_h);
    if button(delete_rect, "Delete", *delete_theme) {
        if selected_index >= 0 && selected_index < search_results.count {
            delete_record(search_results[selected_index].id);
            get_total_record_count();  // Update total after deleting
            // Refresh search
            if search_text.count >= 2 {
                do_search(search_text);
            } else {
                load_all_records();
            }
            selected_index = -1;
            collection_stats.dirty = true;
        }
        edit_mode = .NONE;
    }
}

draw_add_edit_dialog :: (dialog_rect: Rect) {
    margin := dialog_rect.h * 0.02;
    inner := shrink(dialog_rect, margin);

    // Title
    title_rect := inner;
    title_rect.h = cast(float)main_font.character_height * 2;
    title_rect.y = inner.y + inner.h - title_rect.h;

    label_theme := my_theme.label_theme;
    label_theme.font = title_font;
    label_theme.alignment = .Center;

    title_text := ifx edit_mode == .ADD then "Add New Record" else "Edit Record";
    label(title_rect, title_text, *label_theme);

    // Form fields
    text_theme := my_theme.text_input_theme;
    text_theme.font = main_font;

    field_height := main_font.character_height * 1.8;
    field_spacing := field_height * 0.5;
    label_width := inner.w * 0.2;
    input_width := inner.w * 0.75;

    current_y := title_rect.y - field_height - field_spacing;

    label_theme.font = main_font;
    label_theme.alignment = .Right;

    // Number field
    draw_form_field(inner.x, current_y, label_width, input_width, field_height, "Number:", *form_number, *label_theme, *text_theme, 1);
    current_y -= field_height + field_spacing;

    // Artist field
    draw_form_field(inner.x, current_y, label_width, input_width, field_height, "Artist:", *form_artist, *label_theme, *text_theme, 2);
    current_y -= field_height + field_spacing;

    // Title field
    draw_form_field(inner.x, current_y, label_width, input_width, field_height, "Title:", *form_title, *label_theme, *text_theme, 3);
    current_y -= field_height + field_spacing;

    // Genre field
    draw_form_field(inner.x, current_y, label_width, input_width, field_height, "Genre:", *form_genre, *label_theme, *text_theme, 4);
    current_y -= field_height + field_spacing;

    // Year field
    draw_form_field(inner.x, current_y, label_width, input_width, field_height, "Year:", *form_year, *label_theme, *text_theme, 5);
    current_y -= field_height + field_spacing;

    // Handle Tab / Shift+Tab to cycle through form fields
    for Input.events_this_frame {
        if it.type == .KEYBOARD && it.key_pressed && it.key_code == .TAB {
            if it.shift_pressed {
                focused_field -= 1;
                if focused_field < 1 focused_field = 5;
            } else {
                focused_field += 1;
                if focused_field > 5 focused_field = 1;
            }
        }
    }

    // Find Artwork button (only in edit mode for existing records)
    // Positioned below the Year field
    button_theme := my_theme.button_theme;
    button_theme.font = main_font;

    if edit_mode == .EDIT && form_artist.count > 0 {
        artwork_btn_w := inner.w * 0.4;
        artwork_btn_h := cast(float)main_font.character_height * 1.8;
        artwork_rect := get_rect(inner.x + (inner.w - artwork_btn_w) / 2, current_y, artwork_btn_w, artwork_btn_h);

        if button(artwork_rect, "Find Artwork...", *button_theme, 99) {
            // Start artwork search - set pending flag so UI shows loading first
            artwork_search_record_id = form_id;
            artwork_search_pending = true;
            selected_artwork_index = -1;
            // Pre-fill search term with artist + title
            if artwork_search_text.data free(artwork_search_text.data);
            artwork_search_text = copy_string(tprint("% %", form_artist, form_title));
            edit_mode = .ARTWORK_SEARCH;
        }
    }

    // Buttons - positioned at fixed margin from bottom
    button_w := inner.w * 0.3;
    button_h := cast(float)main_font.character_height * 2;
    button_y := inner.y + margin;

    // Cancel button
    cancel_rect := get_rect(inner.x + inner.w * 0.25 - button_w / 2, button_y, button_w, button_h);
    if button(cancel_rect, "Cancel", *button_theme) {
        edit_mode = .NONE;
    }

    // Save button
    save_rect := get_rect(inner.x + inner.w * 0.75 - button_w / 2, button_y, button_w, button_h);
    if button(save_rect, "Save", *button_theme) {
        save_record();
        edit_mode = .NONE;
    }
}

draw_form_field :: (x: float, y: float, label_width: float, input_width: float, height: float, label_text: string, field: *string, label_theme: *Label_Theme, text_theme: *Text_Input_Theme, identifier: int) {
    // Label
    label_rect := get_rect(x, y, label_width - 10, height);
    label(label_rect, label_text, label_theme);

    // Input
    input_rect := get_rect(x + label_width, y, input_width, height);

    // Draw teal highlight border around the focused field
    if identifier == focused_field {
        Simp.set_shader_for_color();
        border := 2.0;
        // Bottom edge
        Simp.immediate_quad(.{input_rect.x, input_rect.y}, .{input_rect.x + input_rect.w, input_rect.y}, .{input_rect.x + input_rect.w, input_rect.y + border}, .{input_rect.x, input_rect.y + border}, COLOR_ACCENT);
        // Top edge
        Simp.immediate_quad(.{input_rect.x, input_rect.y + input_rect.h - border}, .{input_rect.x + input_rect.w, input_rect.y + input_rect.h - border}, .{input_rect.x + input_rect.w, input_rect.y + input_rect.h}, .{input_rect.x, input_rect.y + input_rect.h}, COLOR_ACCENT);
        // Left edge
        Simp.immediate_quad(.{input_rect.x, input_rect.y}, .{input_rect.x + border, input_rect.y}, .{input_rect.x + border, input_rect.y + input_rect.h}, .{input_rect.x, input_rect.y + input_rect.h}, COLOR_ACCENT);
        // Right edge
        Simp.immediate_quad(.{input_rect.x + input_rect.w - border, input_rect.y}, .{input_rect.x + input_rect.w, input_rect.y}, .{input_rect.x + input_rect.w, input_rect.y + input_rect.h}, .{input_rect.x + input_rect.w - border, input_rect.y + input_rect.h}, COLOR_ACCENT);
    }

    action, new_text, state := text_input(input_rect, field.*, text_theme, identifier);

    // Update focused_field when user clicks/interacts with this field
    if action {
        focused_field = identifier;
    }

    if action & .TEXT_MODIFIED {
        set_form_field(field, state.text);
    }
    if action & .ENTERED {
        set_form_field(field, new_text);
    }
}

save_record :: () {
    // Parse year
    year_value := 0;
    if form_year.count > 0 {
        year_value = parse_int(form_year);
    }

    if edit_mode == .ADD {
        insert_record(form_number, form_artist, form_title, form_genre, year_value);
        get_total_record_count();  // Update total after adding
    } else if edit_mode == .EDIT {
        update_record(form_id, form_number, form_artist, form_title, form_genre, year_value);
    }

    // Refresh search results
    if search_text.count >= 2 {
        do_search(search_text);
    } else {
        load_all_records();
    }
    // Keep selected_index so the user can see their changes
    // Clamp in case the list changed size
    if selected_index >= search_results.count {
        selected_index = search_results.count - 1;
    }
    collection_stats.dirty = true;
}

// Database operations
insert_record :: (number: string, artist: string, title: string, genre: string, year: int) {
    sql := "INSERT INTO records (number, artist, title, genre, year) VALUES (?, ?, ?, ?, ?)";

    stmt: *SQLite.sqlite3_stmt;
    result := SQLite.sqlite3_prepare_v2(db, sql.data, cast(s32)sql.count, *stmt, null);
    if result != SQLite.SQLITE_OK {
        print("SQL prepare error: %\n", result);
        return;
    }
    defer SQLite.sqlite3_finalize(stmt);

    SQLite.sqlite3_bind_text(stmt, 1, number.data, cast(s32)number.count, null);
    SQLite.sqlite3_bind_text(stmt, 2, artist.data, cast(s32)artist.count, null);
    SQLite.sqlite3_bind_text(stmt, 3, title.data, cast(s32)title.count, null);
    SQLite.sqlite3_bind_text(stmt, 4, genre.data, cast(s32)genre.count, null);
    SQLite.sqlite3_bind_int(stmt, 5, cast(s32)year);

    result = SQLite.sqlite3_step(stmt);
    if result != SQLite.SQLITE_DONE {
        print("SQL step error: %\n", result);
    } else {
        print("Record inserted successfully\n");
    }
}

update_record :: (id: int, number: string, artist: string, title: string, genre: string, year: int) {
    sql := "UPDATE records SET number=?, artist=?, title=?, genre=?, year=? WHERE id=?";

    stmt: *SQLite.sqlite3_stmt;
    result := SQLite.sqlite3_prepare_v2(db, sql.data, cast(s32)sql.count, *stmt, null);
    if result != SQLite.SQLITE_OK {
        print("SQL prepare error: %\n", result);
        return;
    }
    defer SQLite.sqlite3_finalize(stmt);

    SQLite.sqlite3_bind_text(stmt, 1, number.data, cast(s32)number.count, null);
    SQLite.sqlite3_bind_text(stmt, 2, artist.data, cast(s32)artist.count, null);
    SQLite.sqlite3_bind_text(stmt, 3, title.data, cast(s32)title.count, null);
    SQLite.sqlite3_bind_text(stmt, 4, genre.data, cast(s32)genre.count, null);
    SQLite.sqlite3_bind_int(stmt, 5, cast(s32)year);
    SQLite.sqlite3_bind_int(stmt, 6, cast(s32)id);

    result = SQLite.sqlite3_step(stmt);
    if result != SQLite.SQLITE_DONE {
        print("SQL step error: %\n", result);
    } else {
        print("Record updated successfully\n");
    }
}

get_total_record_count :: () {
    sql := "SELECT COUNT(*) FROM records";

    stmt: *SQLite.sqlite3_stmt;
    result := SQLite.sqlite3_prepare_v2(db, sql.data, cast(s32)sql.count, *stmt, null);
    if result != SQLite.SQLITE_OK {
        total_record_count = 0;
        return;
    }
    defer SQLite.sqlite3_finalize(stmt);

    if SQLite.sqlite3_step(stmt) == SQLite.SQLITE_ROW {
        total_record_count = SQLite.sqlite3_column_int(stmt, 0);
    }
}

delete_record :: (id: int) {
    sql := "DELETE FROM records WHERE id=?";

    stmt: *SQLite.sqlite3_stmt;
    result := SQLite.sqlite3_prepare_v2(db, sql.data, cast(s32)sql.count, *stmt, null);
    if result != SQLite.SQLITE_OK {
        print("SQL prepare error: %\n", result);
        return;
    }
    defer SQLite.sqlite3_finalize(stmt);

    SQLite.sqlite3_bind_int(stmt, 1, cast(s32)id);

    result = SQLite.sqlite3_step(stmt);
    if result != SQLite.SQLITE_DONE {
        print("SQL step error: %\n", result);
    } else {
        print("Record deleted successfully\n");
    }
}

parse_int :: (s: string) -> int {
    result := 0;
    for i: 0..s.count-1 {
        c := s[i];
        if c >= #char "0" && c <= #char "9" {
            result = result * 10 + (c - #char "0");
        }
    }
    return result;
}

// ============== ARTWORK FUNCTIONS ==============

draw_artwork_search_dialog :: (dialog_rect: Rect) {
    margin := dialog_rect.h * 0.05;
    inner := shrink(dialog_rect, margin);

    // Title
    title_rect := inner;
    title_rect.h = cast(float)main_font.character_height * 2;
    title_rect.y = inner.y + inner.h - title_rect.h;

    label_theme := my_theme.label_theme;
    label_theme.font = title_font;
    label_theme.alignment = .Center;
    label(title_rect, "Select Artwork", *label_theme);

    // Search bar for editing the search term
    search_bar_h := cast(float)main_font.character_height * 1.8;
    search_bar_y := title_rect.y - search_bar_h - margin * 0.5;
    search_input_w := inner.w * 0.7;
    search_btn_w := inner.w * 0.25;

    search_input_rect := get_rect(inner.x, search_bar_y, search_input_w, search_bar_h);
    text_theme := my_theme.text_input_theme;
    text_theme.font = main_font;
    action, new_text, search_state := text_input(search_input_rect, artwork_search_text, *text_theme, 500);
    if action & .TEXT_MODIFIED {
        if artwork_search_text.data free(artwork_search_text.data);
        artwork_search_text = copy_string(search_state.text);
    }
    if action & .ENTERED {
        if artwork_search_text.data free(artwork_search_text.data);
        artwork_search_text = copy_string(new_text);
    }

    // Search button
    search_btn_theme := my_theme.button_theme;
    search_btn_theme.font = main_font;
    search_btn_theme.surface_color = COLOR_ACCENT;
    search_btn_theme.surface_color_over = COLOR_ACCENT_HOVER;
    search_btn_theme.text_color = COLOR_TEXT_PRIMARY;

    search_btn_rect := get_rect(inner.x + search_input_w + inner.w * 0.05, search_bar_y, search_btn_w, search_bar_h);
    if button(search_btn_rect, "Search", *search_btn_theme, 501) {
        artwork_search_pending = true;
        selected_artwork_index = -1;
    }

    // Also trigger search on Enter
    if action & .ENTERED {
        artwork_search_pending = true;
        selected_artwork_index = -1;
    }

    // Artwork grid area
    grid_top := search_bar_y - margin * 0.5;
    button_h := cast(float)main_font.character_height * 2;
    grid_bottom := inner.y + button_h + margin * 2;
    grid_rect := get_rect(inner.x, grid_bottom, inner.w, grid_top - grid_bottom);

    // Draw artwork results as a grid
    theme := my_theme.scrollable_region_theme;
    region, inside := begin_scrollable_region(grid_rect, *theme);

    thumb_size := inside.w * 0.22;
    thumb_spacing := inside.w * 0.03;
    cols := 4;

    if artwork_search_pending {
        // Show loading state while search is pending
        label_theme.font = main_font;
        label_theme.text_color.w = 0.5;
        label(inside, "Searching...", *label_theme);
    } else if artwork_results.count == 0 {
        label_theme.font = main_font;
        label_theme.text_color.w = 0.5;
        label(inside, "No artwork found", *label_theme);

        // Show hint for manual artwork path
        hint_rect := get_rect(inside.x, inside.y + inside.h - main_font.character_height * 2.5, inside.w, cast(float)main_font.character_height);
        hint_text := tprint("You can manually add: data/artwork/%.jpg", artwork_search_record_id);
        label(hint_rect, hint_text, *label_theme);
    } else {
        current_x := inside.x;
        current_y := inside.y + inside.h - thumb_size + artwork_scroll_value;
        col := 0;

        button_theme := my_theme.button_theme;

        for * artwork_results {
            // Draw thumbnail
            thumb_rect := get_rect(current_x, current_y, thumb_size, thumb_size);

            // Only draw if visible within the grid area
            visible := (thumb_rect.y + thumb_rect.h > grid_bottom) && (thumb_rect.y < grid_top);

            if visible {
                // Clamp drawing to visible area
                draw_rect := thumb_rect;
                uv_y0 : float = 0;
                uv_y1 : float = 1;
                if draw_rect.y < grid_bottom {
                    clipped := grid_bottom - draw_rect.y;
                    uv_y0 = clipped / thumb_rect.h;
                    draw_rect.h -= clipped;
                    draw_rect.y = grid_bottom;
                }
                if draw_rect.y + draw_rect.h > grid_top {
                    clipped := (draw_rect.y + draw_rect.h) - grid_top;
                    uv_y1 = 1.0 - clipped / thumb_rect.h;
                    draw_rect.h -= clipped;
                }

                // Load texture if not loaded
                if !it.texture_loaded && it.thumb_url.count > 0 {
                    load_artwork_thumbnail(it);
                }

                // Draw the image or placeholder (clipped)
                if it.texture_loaded && it.texture.width > 0 {
                    Simp.set_shader_for_images(*it.texture);
                    Simp.immediate_quad(
                        .{draw_rect.x, draw_rect.y}, .{draw_rect.x + draw_rect.w, draw_rect.y},
                        .{draw_rect.x + draw_rect.w, draw_rect.y + draw_rect.h}, .{draw_rect.x, draw_rect.y + draw_rect.h},
                        .{1,1,1,1}, .{1,1,1,1}, .{1,1,1,1}, .{1,1,1,1},
                        .{0, uv_y0}, .{1, uv_y0}, .{1, uv_y1}, .{0, uv_y1}
                    );
                } else {
                    // Placeholder
                    Simp.set_shader_for_color();
                    p0, p1, p2, p3 := get_quad(draw_rect);
                    Simp.immediate_quad(p0, p1, p2, p3, .{0.3, 0.3, 0.3, 1});
                }

                // Draw rounded corner masks
                draw_rounded_corner_mask(draw_rect, 8.0, my_theme.background_color);

                // Draw selection highlight if this is the selected artwork
                if it_index == selected_artwork_index {
                    Simp.set_shader_for_color();
                    border := 3.0;
                    Simp.immediate_quad(.{draw_rect.x, draw_rect.y}, .{draw_rect.x + draw_rect.w, draw_rect.y}, .{draw_rect.x + draw_rect.w, draw_rect.y + border}, .{draw_rect.x, draw_rect.y + border}, COLOR_ACCENT);
                    Simp.immediate_quad(.{draw_rect.x, draw_rect.y + draw_rect.h - border}, .{draw_rect.x + draw_rect.w, draw_rect.y + draw_rect.h - border}, .{draw_rect.x + draw_rect.w, draw_rect.y + draw_rect.h}, .{draw_rect.x, draw_rect.y + draw_rect.h}, COLOR_ACCENT);
                    Simp.immediate_quad(.{draw_rect.x, draw_rect.y}, .{draw_rect.x + border, draw_rect.y}, .{draw_rect.x + border, draw_rect.y + draw_rect.h}, .{draw_rect.x, draw_rect.y + draw_rect.h}, COLOR_ACCENT);
                    Simp.immediate_quad(.{draw_rect.x + draw_rect.w - border, draw_rect.y}, .{draw_rect.x + draw_rect.w, draw_rect.y}, .{draw_rect.x + draw_rect.w, draw_rect.y + draw_rect.h}, .{draw_rect.x + draw_rect.w - border, draw_rect.y + draw_rect.h}, COLOR_ACCENT);
                }

                // Clickable button overlay - selects this artwork
                button_theme.surface_color = .{0, 0, 0, 0};
                button_theme.surface_color_over = .{1, 1, 1, 0.15};
                button_theme.frame_color = .{0, 0, 0, 0};
                button_theme.text_color = .{0, 0, 0, 0};

                if button(draw_rect, "", *button_theme, it_index + 100) {
                    selected_artwork_index = it_index;
                }
            }

            col += 1;
            if col >= cols {
                col = 0;
                current_x = inside.x;
                current_y -= thumb_size + thumb_spacing;
            } else {
                current_x += thumb_size + thumb_spacing;
            }
        }

        // For scroll calculation
        if col > 0 current_y -= thumb_size + thumb_spacing;
    }

    end_scrollable_region(region, inside.x + inside.w, inside.y + inside.h - (grid_top - grid_bottom + artwork_scroll_value), *artwork_scroll_value);

    // Buttons
    button_theme := my_theme.button_theme;
    button_theme.font = main_font;

    button_w := inner.w * 0.3;
    button_spacing := inner.w * 0.05;
    button_y := inner.y + margin;

    // Back button
    back_rect := get_rect(inner.x + inner.w * 0.5 - button_w - button_spacing * 0.5, button_y, button_w, button_h);
    if button(back_rect, "Back", *button_theme, 400) {
        clear_artwork_results();
        selected_artwork_index = -1;
        artwork_search_pending = false;
        edit_mode = .EDIT;
    }

    // Select button (teal, only active when an artwork is selected)
    select_theme := button_theme;
    if selected_artwork_index >= 0 && selected_artwork_index < artwork_results.count {
        select_theme.surface_color = COLOR_ACCENT;
        select_theme.surface_color_over = COLOR_ACCENT_HOVER;
        select_theme.text_color = COLOR_TEXT_PRIMARY;
    } else {
        select_theme.surface_color = .{0.15, 0.15, 0.17, 1};
        select_theme.text_color = COLOR_TEXT_SECONDARY;
    }

    select_rect := get_rect(inner.x + inner.w * 0.5 + button_spacing * 0.5, button_y, button_w, button_h);
    if button(select_rect, "Select", *select_theme, 401) {
        if selected_artwork_index >= 0 && selected_artwork_index < artwork_results.count {
            select_artwork(*artwork_results[selected_artwork_index]);
            selected_artwork_index = -1;
        }
    }

    // Perform deferred search after UI has rendered "Searching..." state
    if artwork_search_pending {
        search_discogs_artwork();
        artwork_search_pending = false;
    }
}

search_discogs_artwork :: () {
    // Clear previous results
    clear_artwork_results();

    if artwork_search_text.count == 0 return;

    // Use iTunes Search API - reliable, no auth, direct image URLs
    encoded := url_encode(artwork_search_text);
    url := tprint("https://itunes.apple.com/search?term=%&media=music&entity=album&limit=12", encoded);

    print("Searching iTunes: %\n", url);

    body, response_code, curl_code := http_request(url);
    defer if body.data free(body);

    if curl_code != .OK || response_code != 200 {
        print("iTunes API error: curl=% http=%\n", curl_code, response_code);
        return;
    }

    // Parse iTunes JSON response
    parse_itunes_response(body);

    print("Found % artwork results\n", artwork_results.count);
}

http_request :: (url: string, data: string = "", method: string = "", headers: [] string = .[]) -> response_body: string, response_code: int, curl_code: Curl.CURLcode {
    curl := Curl.curl_easy_init();
    if !curl return "", 0, .FAILED_INIT;
    defer Curl.curl_easy_cleanup(curl);

    Curl.curl_easy_setopt(curl, .URL, make_c_string(url));
    Curl.curl_easy_setopt(curl, .FOLLOWLOCATION, 1);
    Curl.curl_easy_setopt(curl, .TIMEOUT, 30);

    if method Curl.curl_easy_setopt(curl, .CUSTOMREQUEST, make_c_string(method));
    if data   Curl.curl_easy_setopt(curl, .POSTFIELDS, make_c_string(data));

    slist: *Curl.curl_slist;
    if headers.count {
        for headers slist = Curl.curl_slist_append(slist, make_c_string(it));
        Curl.curl_easy_setopt(curl, .HTTPHEADER, slist);
    }
    defer if slist Curl.curl_slist_free_all(slist);

    builder: String_Builder;
    defer free_buffers(*builder);
    Curl.curl_easy_setopt(curl, .WRITEFUNCTION, curl_write_callback);
    Curl.curl_easy_setopt(curl, .WRITEDATA, *builder);

    curl_code := Curl.curl_easy_perform(curl);

    response_code: int;
    if curl_code == .OK Curl.curl_easy_getinfo(curl, .RESPONSE_CODE, *response_code);

    response_body := builder_to_string(*builder);
    return response_body, response_code, curl_code;
}

curl_write_callback :: (ptr: *u8, size: u64, nmemb: u64, userdata: *void) -> u64 #c_call {
    builder := cast(*String_Builder)userdata;
    push_context {
        append(builder, ptr, cast(s64)nmemb);
    }
    return nmemb;
}

parse_itunes_response :: (json: string) {
    // Parse iTunes Search API response
    // Each result has: artworkUrl100, artistName, collectionName

    pos := 0;
    while pos < json.count && artwork_results.count < 12 {
        // Find artworkUrl100 field
        artwork_key := find_substring(json, "\"artworkUrl100\":", pos);
        if artwork_key < 0 break;

        artwork_url := extract_json_string(json, artwork_key + 16);
        if artwork_url.count == 0 {
            pos = artwork_key + 16;
            continue;
        }

        // Find the start of this result object (search backwards for opening brace)
        obj_start := artwork_key;
        brace_count := 0;
        while obj_start > pos {
            if json[obj_start] == #char "}" brace_count += 1;
            if json[obj_start] == #char "{" {
                if brace_count == 0 break;
                brace_count -= 1;
            }
            obj_start -= 1;
        }

        // Find artistName within this object
        artist_key := find_substring(json, "\"artistName\":", obj_start);
        artist_name := "";
        if artist_key >= 0 && artist_key < artwork_key {
            artist_name = extract_json_string(json, artist_key + 13);
        }

        // Find collectionName within this object
        collection_key := find_substring(json, "\"collectionName\":", obj_start);
        collection_name := "";
        if collection_key >= 0 && collection_key < artwork_key {
            collection_name = extract_json_string(json, collection_key + 17);
        }

        result: Artwork_Result;
        // Thumb: 100x100 (original URL)
        result.thumb_url = copy_string(artwork_url);
        // Full: replace 100x100bb with 600x600bb for high-res
        result.cover_url = replace_artwork_size(artwork_url, "600x600bb");

        if artist_name.count > 0 && collection_name.count > 0 {
            result.title = copy_string(tprint("% - %", artist_name, collection_name));
        } else if collection_name.count > 0 {
            result.title = copy_string(collection_name);
        } else {
            result.title = copy_string("Unknown Album");
        }

        if artwork_url.data free(artwork_url);
        if artist_name.data free(artist_name);
        if collection_name.data free(collection_name);

        array_add(*artwork_results, result);
        pos = artwork_key + 16;
    }
}

replace_artwork_size :: (url: string, new_size: string) -> string {
    // iTunes URLs contain "100x100bb" - replace with new size
    size_pos := find_substring(url, "100x100bb");
    if size_pos < 0 return copy_string(url);

    builder: String_Builder;
    for i: 0..size_pos-1 {
        append(*builder, url[i]);
    }
    append(*builder, new_size);
    for i: size_pos + 9 .. url.count-1 {
        append(*builder, url[i]);
    }
    return builder_to_string(*builder);
}

find_substring :: (haystack: string, needle: string, start: int = 0) -> int {
    if needle.count == 0 return -1;
    if start + needle.count > haystack.count return -1;

    for i: start..haystack.count - needle.count {
        match := true;
        for j: 0..needle.count-1 {
            if haystack[i + j] != needle[j] {
                match = false;
                break;
            }
        }
        if match return i;
    }
    return -1;
}

extract_json_string :: (json: string, start: int) -> string {
    // Skip to opening quote
    pos := start;
    while pos < json.count && json[pos] != #char "\"" pos += 1;
    pos += 1; // Skip the quote

    // Find closing quote
    end := pos;
    while end < json.count && json[end] != #char "\"" {
        if json[end] == #char "\\" && end + 1 < json.count {
            end += 2; // Skip escaped char
        } else {
            end += 1;
        }
    }

    if end > pos {
        result: string;
        result.data = json.data + pos;
        result.count = end - pos;
        return copy_string(result);
    }
    return "";
}

replace_string :: (s: string, old: string, new: string) -> string {
    pos := find_substring(s, old);
    if pos < 0 return copy_string(s);

    builder: String_Builder;
    // Part before
    for i: 0..pos-1 {
        append(*builder, s[i]);
    }
    // Replacement
    append(*builder, new);
    // Part after
    for i: pos + old.count .. s.count-1 {
        append(*builder, s[i]);
    }
    return builder_to_string(*builder);
}

url_encode :: (s: string) -> string {
    builder: String_Builder;
    for i: 0..s.count-1 {
        c := s[i];
        if (c >= #char "a" && c <= #char "z") ||
           (c >= #char "A" && c <= #char "Z") ||
           (c >= #char "0" && c <= #char "9") ||
           c == #char "-" || c == #char "_" || c == #char "." {
            append(*builder, c);
        } else if c == #char " " {
            append(*builder, "+");
        } else {
            // Percent encode
            hex := "0123456789ABCDEF";
            append(*builder, #char "%");
            append(*builder, hex[(c >> 4) & 0xF]);
            append(*builder, hex[c & 0xF]);
        }
    }
    return builder_to_string(*builder);
}

load_artwork_thumbnail :: (result: *Artwork_Result) {
    if result.thumb_url.count == 0 {
        result.texture_loaded = true;
        return;
    }

    // Download thumbnail
    body, response_code, curl_code := http_request(result.thumb_url);

    if curl_code != .OK || response_code != 200 {
        print("Failed to download thumbnail: % (http %)\n", result.thumb_url, response_code);
        result.texture_loaded = true;
        if body.data free(body);
        return;
    }

    // Load into texture
    image_data: [] u8;
    image_data.data = body.data;
    image_data.count = body.count;

    success := Simp.texture_load_from_memory(*result.texture, image_data);
    result.texture_loaded = true;

    if !success {
        print("Failed to load thumbnail image\n");
    }

    free(body);
}

select_artwork :: (result: *Artwork_Result) {
    // Download full cover image
    url := result.cover_url;
    if url.count == 0 url = result.thumb_url;
    if url.count == 0 return;

    print("Downloading artwork: %\n", url);

    body, response_code, curl_code := http_request(url);

    if curl_code != .OK || response_code != 200 {
        print("Failed to download artwork (http %)\n", response_code);
        if body.data free(body);
        return;
    }

    // Save to file
    filename := tprint("data/artwork/%.jpg", artwork_search_record_id);
    success := write_entire_file(filename, body);

    if body.data free(body);

    if !success {
        print("Failed to save artwork to %\n", filename);
        return;
    }

    print("Artwork saved to %\n", filename);

    // Update database
    update_record_artwork(artwork_search_record_id, filename);

    // Invalidate artwork cache for this record so it reloads
    for * artwork_cache {
        if it.record_id == artwork_search_record_id {
            it.loaded = false;
            break;
        }
    }

    // Clear and close the dialog entirely - artwork is saved directly to DB
    clear_artwork_results();
    selected_artwork_index = -1;
    edit_mode = .NONE;

    // Refresh search results to show updated artwork
    if search_text.count >= 2 {
        do_search(search_text);
    } else {
        load_all_records();
    }
    // Keep selected_index so user can see the updated artwork
    if selected_index >= search_results.count {
        selected_index = search_results.count - 1;
    }
}

update_record_artwork :: (id: int, artwork_path: string) {
    sql := "UPDATE records SET artwork_path=? WHERE id=?";

    stmt: *SQLite.sqlite3_stmt;
    result := SQLite.sqlite3_prepare_v2(db, sql.data, cast(s32)sql.count, *stmt, null);
    if result != SQLite.SQLITE_OK {
        print("SQL prepare error: %\n", result);
        return;
    }
    defer SQLite.sqlite3_finalize(stmt);

    SQLite.sqlite3_bind_text(stmt, 1, artwork_path.data, cast(s32)artwork_path.count, null);
    SQLite.sqlite3_bind_int(stmt, 2, cast(s32)id);

    result = SQLite.sqlite3_step(stmt);
    if result != SQLite.SQLITE_DONE {
        print("SQL step error: %\n", result);
    } else {
        print("Artwork path updated for record %\n", id);
    }
}

clear_artwork_results :: () {
    for * artwork_results {
        if it.thumb_url.data free(it.thumb_url.data);
        if it.cover_url.data free(it.cover_url.data);
        if it.title.data free(it.title.data);
        // Note: texture cleanup would go here if needed
    }
    artwork_results.count = 0;
    artwork_scroll_value = 0;
}

get_artwork_texture :: (record_id: int, artwork_path: string) -> *Simp.Texture {
    if artwork_path.count == 0 return null;

    // Check cache
    for * artwork_cache {
        if it.record_id == record_id && it.loaded {
            return *it.texture;
        }
    }

    // Load and cache
    entry: Artwork_Cache_Entry;
    entry.record_id = record_id;
    entry.loaded = Simp.texture_load_from_file(*entry.texture, artwork_path);

    if entry.loaded {
        array_add(*artwork_cache, entry);
        // Return pointer to the one we just added
        return *artwork_cache[artwork_cache.count - 1].texture;
    }

    return null;
}

make_c_string :: (s: string) -> *u8 {
    // Allocate null-terminated string in temporary storage
    result := cast(*u8) talloc(s.count + 1);
    memcpy(result, s.data, s.count);
    result[s.count] = 0;
    return result;
}

#scope_file

// Helper to convert C string to Jai string
to_string :: (c_str: *u8) -> string {
    if !c_str return "";
    len := 0;
    while c_str[len] != 0 len += 1;
    result: string;
    result.data = c_str;
    result.count = len;
    return result;
}
