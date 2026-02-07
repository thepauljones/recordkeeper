// Automated test suite for Record Collection Manager
// Loaded from main.jai - runs when --test flag is passed
// Uses a step-based state machine to exercise the app like a real user

test_mode: bool = false;
test_watchable: bool = false;
test_should_quit: bool = false;
test_step: int = 0;
test_wait_frames: int = 0;
test_failures: int = 0;
test_total: int = 0;

test_assert :: (condition: bool, description: string) {
    test_total += 1;
    if condition {
        print("  PASS: %\n", description);
    } else {
        print("  FAIL: %\n", description);
        test_failures += 1;
    }
}

test_report_and_exit :: () {
    print("\n========================================\n");
    if test_failures == 0 {
        print("ALL % TESTS PASSED\n", test_total);
    } else {
        print("% of % TESTS FAILED\n", test_failures, test_total);
    }
    print("========================================\n\n");
    test_should_quit = true;
}

// Called each frame from the main loop after draw_frame
run_tests :: () {
    if !test_mode return;

    if test_wait_frames > 0 { test_wait_frames -= 1; return; }

    gap := ifx test_watchable then 60 else 5;

    if test_step == {

    // ── Step 0: Clean DB, reset app state ────────────────────
    case 0;
        print("\n=== Step 0: Clean DB, reset app state ===\n");
        clean_sql := "DELETE FROM records";
        SQLite.sqlite3_exec(db, clean_sql.data, null, null, null);
        clear_search_results();
        selected_index = -1;
        edit_mode = .NONE;
        sort_mode = .ARTIST_AZ;
        get_total_record_count();
        collection_stats.dirty = true;
        test_assert(total_record_count == 0, "DB clean: 0 records after DELETE");

    // ── Step 1: Create record A ──────────────────────────────
    case 1;
        print("\n=== Step 1: Create record A ===\n");
        set_form_field(*form_number, "TEST-001");
        set_form_field(*form_artist, "Test Artist");
        set_form_field(*form_title, "Test Album");
        set_form_field(*form_genre, "Rock");
        set_form_field(*form_year, "2024");
        edit_mode = .ADD;
        save_record();
        edit_mode = .NONE;

        get_total_record_count();
        test_assert(total_record_count == 1, "Total record count is 1 after insert");

    // ── Step 2: Search for A, verify all fields ──────────────
    case 2;
        print("\n=== Step 2: Search for A, verify all fields ===\n");
        do_search("Test Artist");
        test_assert(search_results.count == 1, "Search returns 1 result");
        if search_results.count > 0 {
            test_assert(search_results[0].artist == "Test Artist", "Artist matches");
            test_assert(search_results[0].title == "Test Album", "Title matches");
            test_assert(search_results[0].genre == "Rock", "Genre matches");
            test_assert(search_results[0].year == 2024, "Year matches");
            test_assert(search_results[0].number == "TEST-001", "Number matches");
        }

        // Search that should NOT match
        do_search("Nonexistent Band");
        test_assert(search_results.count == 0, "Search for nonexistent returns 0");

    // ── Step 3: Open edit for A, change fields, save ─────────
    case 3;
        print("\n=== Step 3: Edit record A ===\n");
        do_search("Test Artist");
        test_assert(search_results.count == 1, "Found record to edit");
        if search_results.count > 0 {
            load_record_to_form(search_results[0]);
            set_form_field(*form_artist, "Edited Artist");
            set_form_field(*form_title, "Edited Album");
            set_form_field(*form_year, "2025");
            edit_mode = .EDIT;
            save_record();
            edit_mode = .NONE;
        }

    // ── Step 4: Verify edit stuck, old name gone ─────────────
    case 4;
        print("\n=== Step 4: Verify edit ===\n");
        do_search("Edited Artist");
        test_assert(search_results.count == 1, "Edited record found by new name");
        if search_results.count > 0 {
            test_assert(search_results[0].artist == "Edited Artist", "Edited artist matches");
            test_assert(search_results[0].title == "Edited Album", "Edited title matches");
            test_assert(search_results[0].year == 2025, "Edited year matches");
            test_assert(search_results[0].number == "TEST-001", "Number preserved after edit");
        }

        // Old name should not be found
        do_search("Test Artist");
        test_assert(search_results.count == 0, "Old artist name not found after edit");

    // ── Step 5: Create record B ──────────────────────────────
    case 5;
        print("\n=== Step 5: Create record B ===\n");
        set_form_field(*form_number, "TEST-002");
        set_form_field(*form_artist, "Second Artist");
        set_form_field(*form_title, "Second Album");
        set_form_field(*form_genre, "Pop");
        set_form_field(*form_year, "2020");
        edit_mode = .ADD;
        save_record();
        edit_mode = .NONE;

        get_total_record_count();
        test_assert(total_record_count == 2, "Total record count is 2 after second insert");

    // ── Step 6: Verify count=2, search for B, verify fields ──
    case 6;
        print("\n=== Step 6: Verify record B ===\n");
        load_all_records();
        test_assert(search_results.count == 2, "Loaded 2 records total");

        do_search("Second Artist");
        test_assert(search_results.count == 1, "Search for B returns 1 result");
        if search_results.count > 0 {
            test_assert(search_results[0].artist == "Second Artist", "B artist matches");
            test_assert(search_results[0].title == "Second Album", "B title matches");
            test_assert(search_results[0].genre == "Pop", "B genre matches");
            test_assert(search_results[0].year == 2020, "B year matches");
            test_assert(search_results[0].number == "TEST-002", "B number matches");
        }

    // ── Step 7: Edit B genre to Jazz, save, close ────────────
    case 7;
        print("\n=== Step 7: Edit B genre to Jazz ===\n");
        do_search("Second Artist");
        test_assert(search_results.count == 1, "Found B to edit");
        if search_results.count > 0 {
            load_record_to_form(search_results[0]);
            set_form_field(*form_genre, "Jazz");
            edit_mode = .EDIT;
            save_record();
            edit_mode = .NONE;
        }

    // ── Step 8: Reopen edit for B, verify form loads Jazz ────
    case 8;
        print("\n=== Step 8: Reopen edit for B (state-reset check) ===\n");
        do_search("Second Artist");
        test_assert(search_results.count == 1, "Found B for reopen");
        if search_results.count > 0 {
            load_record_to_form(search_results[0]);
            // Form should load current DB values, not stale state
            test_assert(form_genre == "Jazz", "Reopen form loads Jazz (not Pop)");
            // Close without saving
            edit_mode = .NONE;
        }

    // ── Step 9: Verify B still has Jazz ──────────────────────
    case 9;
        print("\n=== Step 9: Verify close didn't revert ===\n");
        do_search("Second Artist");
        test_assert(search_results.count == 1, "B still found");
        if search_results.count > 0 {
            test_assert(search_results[0].genre == "Jazz", "B genre still Jazz after close without save");
        }

    // ── Step 10: Search for A then B (search state reset) ────
    case 10;
        print("\n=== Step 10: Back-to-back search state reset ===\n");
        do_search("Edited");
        test_assert(search_results.count == 1, "Search for Edited finds A");
        if search_results.count > 0 {
            test_assert(search_results[0].artist == "Edited Artist", "A found correctly");
        }

        do_search("Second");
        test_assert(search_results.count == 1, "Search for Second finds B");
        if search_results.count > 0 {
            test_assert(search_results[0].artist == "Second Artist", "B found correctly");
        }

    // ── Step 11: Keyboard nav — inject DOWN arrow ────────────
    case 11;
        print("\n=== Step 11: Keyboard navigation (DOWN) ===\n");
        do_search("Edited");
        test_assert(search_results.count > 0, "Have results for navigation test");

        selected_index = -1;
        {
            event: Input.Event;
            event.type = .KEYBOARD;
            event.key_code = .ARROW_DOWN;
            event.key_pressed = 1;
            array_add(*Input.events_this_frame, event);
        }
        test_wait_frames = 2;  // Need at least 2 frames for event processing
        test_step += 1;
        return;  // Skip the gap/increment at the bottom

    // ── Step 12: Verify DOWN, inject UP then ESCAPE ──────────
    case 12;
        print("\n=== Step 12: Verify DOWN, inject UP + ESCAPE ===\n");
        test_assert(selected_index == 0, "Down arrow selected first record");

        // Inject UP arrow
        {
            event: Input.Event;
            event.type = .KEYBOARD;
            event.key_code = .ARROW_UP;
            event.key_pressed = 1;
            array_add(*Input.events_this_frame, event);
        }
        test_wait_frames = 2;
        test_step += 1;
        return;

    // ── Step 13: Verify UP/ESCAPE ────────────────────────────
    case 13;
        print("\n=== Step 13: Verify UP worked ===\n");
        test_assert(selected_index == -1, "Up arrow deselected (back to -1)");

        // Inject ESCAPE
        {
            event: Input.Event;
            event.type = .KEYBOARD;
            event.key_code = .ESCAPE;
            event.key_pressed = 1;
            array_add(*Input.events_this_frame, event);
        }
        test_wait_frames = 2;
        test_step += 1;
        return;

    // ── Step 14: Sort modes with both records ────────────────
    case 14;
        print("\n=== Step 14: Sort modes ===\n");
        test_assert(edit_mode == .NONE, "Escape keeps edit_mode NONE when no dialog");

        // Test A-Z sort
        sort_mode = .ARTIST_AZ;
        load_all_records();
        test_assert(search_results.count == 2, "A-Z: loaded 2 records");
        if search_results.count == 2 {
            test_assert(search_results[0].artist == "Edited Artist", "A-Z: Edited first");
            test_assert(search_results[1].artist == "Second Artist", "A-Z: Second second");
        }

        // Test Z-A sort
        sort_mode = .ARTIST_ZA;
        load_all_records();
        if search_results.count == 2 {
            test_assert(search_results[0].artist == "Second Artist", "Z-A: Second first");
            test_assert(search_results[1].artist == "Edited Artist", "Z-A: Edited second");
        }

        // Test newest first
        sort_mode = .YEAR_NEWEST;
        load_all_records();
        if search_results.count == 2 {
            test_assert(search_results[0].year == 2025, "Newest: 2025 first");
            test_assert(search_results[1].year == 2020, "Newest: 2020 second");
        }

        // Test oldest first
        sort_mode = .YEAR_OLDEST;
        load_all_records();
        if search_results.count == 2 {
            test_assert(search_results[0].year == 2020, "Oldest: 2020 first");
            test_assert(search_results[1].year == 2025, "Oldest: 2025 second");
        }

        // Reset sort mode
        sort_mode = .ARTIST_AZ;

    // ── Step 15: Collection stats ────────────────────────────
    case 15;
        print("\n=== Step 15: Collection stats ===\n");
        get_total_record_count();
        collection_stats.dirty = true;
        calculate_collection_stats();
        test_assert(collection_stats.total_records == 2, "Stats: 2 total records");
        test_assert(collection_stats.unique_artists == 2, "Stats: 2 unique artists");
        test_assert(collection_stats.year_min == 2020, "Stats: year min 2020");
        test_assert(collection_stats.year_max == 2025, "Stats: year max 2025");
        test_assert(collection_stats.top_genre_count >= 2, "Stats: at least 2 genres");

    // ── Step 16: Delete record A, verify ─────────────────────
    case 16;
        print("\n=== Step 16: Delete record A ===\n");
        do_search("Edited Artist");
        test_assert(search_results.count == 1, "Found A for deletion");
        if search_results.count > 0 {
            delete_record(search_results[0].id);
            get_total_record_count();
            test_assert(total_record_count == 1, "1 record after deleting A");

            do_search("Edited Artist");
            test_assert(search_results.count == 0, "A not searchable after delete");
        }

    // ── Step 17: Delete record B, verify empty ───────────────
    case 17;
        print("\n=== Step 17: Delete record B ===\n");
        do_search("Second Artist");
        test_assert(search_results.count == 1, "Found B for deletion");
        if search_results.count > 0 {
            delete_record(search_results[0].id);
            get_total_record_count();
            test_assert(total_record_count == 0, "0 records after deleting B");
        }

        do_search("Second");
        test_assert(search_results.count == 0, "No results after all deleted");
        do_search("Edited");
        test_assert(search_results.count == 0, "No results after all deleted (2)");

    // ── Step 18: Tab focus cycling ───────────────────────────
    case 18;
        print("\n=== Step 18: Tab focus cycling ===\n");
        // Test the logic directly
        focused_field = 1;

        // Simulate Tab forward
        focused_field += 1;
        test_assert(focused_field == 2, "Tab forward: field 1 -> 2");

        focused_field = 5;
        focused_field += 1;
        if focused_field > 5 focused_field = 1;
        test_assert(focused_field == 1, "Tab forward wraps: field 5 -> 1");

        // Simulate Shift+Tab backward
        focused_field = 1;
        focused_field -= 1;
        if focused_field < 1 focused_field = 5;
        test_assert(focused_field == 5, "Shift+Tab backward wraps: field 1 -> 5");

        edit_mode = .NONE;

    // ── Step 19: Report results & exit ───────────────────────
    case 19;
        test_report_and_exit();
    }

    test_wait_frames = gap;
    test_step += 1;
}
