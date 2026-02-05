// SQLite3 Bindings Generator for Jai
// Generates bindings from the system SQLite3 headers

AT_COMPILE_TIME :: true;

#if AT_COMPILE_TIME {
    #run,stallable {
        set_build_options_dc(.{do_output=false});
        if !generate_bindings() {
            compiler_set_workspace_status(.FAILED);
        }
    }
} else {
    #import "System";

    main :: () {
        set_working_directory(path_strip_filename(get_path_of_running_executable()));
        if !generate_bindings() {
            exit(1);
        }
    }
}

generate_bindings :: () -> bool {
    output_filename: string;
    opts: Generate_Bindings_Options;
    {
        using opts;

        #if OS == .MACOS {
            // Get macOS SDK path and use it for sqlite3.h
            sdk_path := get_sdk_path();
            if !sdk_path {
                log_error("Could not find macOS SDK path. Make sure Xcode Command Line Tools are installed.");
                return false;
            }
            sqlite_header := tprint("%/usr/include/sqlite3.h", sdk_path);
            array_add(*path_fragments_to_treat_as_non_system_paths, "sqlite3.h");
            array_add(*source_files, sqlite_header);
            // Tell the bindings generator about the system library
            array_add(*system_library_search_paths, tprint("%/usr/lib", sdk_path));
            array_add(*system_libraries, .{"libsqlite3", "sqlite3_lib"});
            output_filename = "macos.jai";
            // Don't use footer - library declaration is generated automatically
        } else #if OS == .LINUX {
            array_add(*path_fragments_to_treat_as_non_system_paths, "sqlite3.h");
            array_add(*source_files, "/usr/include/sqlite3.h");
            array_add(*system_library_search_paths, "/usr/lib", "/usr/lib/x86_64-linux-gnu");
            array_add(*system_libraries, .{"libsqlite3", "sqlite3_lib"});
            output_filename = "linux.jai";
            // Don't use footer - library declaration is generated automatically
        } else #if OS == .WINDOWS {
            // Windows needs bundled headers - user must provide sqlite3.h
            array_add(*include_paths, "windows");
            array_add(*source_files, "windows/sqlite3.h");
            array_add(*library_search_paths, "windows");
            array_add(*libraries, .{"sqlite3", "sqlite3_lib"});
            output_filename = "windows.jai";
        }

        alias_original_enum_names = false;
        log_stripped_declarations = false;
        generate_compile_time_struct_checks = false;
        generate_library_declarations = true;  // Generate library declarations for all platforms

        visitor = sqlite_visitor;
    }

    return generate_bindings(opts, output_filename);
}

// Filter out some declarations we don't need
DECLARATIONS_TO_OMIT :: string.[
    // Internal/deprecated functions
    "sqlite3_aggregate_count",
    "sqlite3_expired",
    "sqlite3_transfer_bindings",
    "sqlite3_global_recover",
    "sqlite3_thread_cleanup",
    "sqlite3_memory_alarm",
];

sqlite_visitor :: (decl: *Declaration, parent_decl: *Declaration) -> Declaration_Visit_Result {
    if !parent_decl && array_find(DECLARATIONS_TO_OMIT, decl.name) {
        decl.decl_flags |= .OMIT_FROM_OUTPUT;
        return .STOP;
    }
    return .RECURSE;
}

#import "Basic";
#import "Bindings_Generator";
#import "Compiler";
#import "String";
#import "Process";

#if OS == .MACOS {
    get_sdk_path :: () -> string {
        result, output, error := run_command("xcrun", "--show-sdk-path", capture_and_return_output = true);
        if result.exit_code != 0 return "";
        // Trim newline
        trimmed := trim(output);
        return copy_string(trimmed);
    }
}

FOOTER_MACOS :: #string END

sqlite3_lib :: #library,system "libsqlite3";

END

FOOTER_LINUX :: #string END

sqlite3_lib :: #library,system "libsqlite3";

END
