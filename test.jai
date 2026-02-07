// Test build script for Record Collection Manager
// Run with: jai test.jai && ./test
// Watchable: jai test.jai && ./test --watchable

#import "Basic";
#import "Compiler";
#import "File";

build :: () {
    w := compiler_create_workspace("RecordManager");
    if !w {
        print("Workspace creation failed!\n");
        return;
    }

    options := get_build_options(w);
    options.output_executable_name = "test";

    #if OS == .MACOS {
        options.minimum_os_version = .{11, 0};  // Big Sur+ for Apple Silicon
    }

    set_build_options(options, w);

    compiler_begin_intercept(w);
    add_build_string("IS_TEST_BUILD :: true;", w);
    add_build_file("src/main.jai", w);

    // Wait for compilation to finish
    while true {
        message := compiler_wait_for_message();
        if message.kind == .COMPLETE break;
    }

    compiler_end_intercept(w);
}

#run build();
