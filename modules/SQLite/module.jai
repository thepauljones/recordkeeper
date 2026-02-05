// SQLite3 module for Jai
// Cross-platform SQLite bindings

#if OS == .MACOS {
    #load "macos.jai";
} else #if OS == .LINUX {
    #load "linux.jai";
} else #if OS == .WINDOWS {
    #load "windows.jai";
} else {
    #assert(false, "Unsupported platform for SQLite module");
}
