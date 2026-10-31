//
// Stops the CLI tool cleanly when the user presses Ctrl+C or the system asks it to end: the
// handler records the request and wakes the watcher, so the main loop sees the request at once,
// flushes its output and frees the watcher.
//

const std = @import("std");
const builtin = @import("builtin");
const file_watcher = @import("file_watcher");

const assert = std.debug.assert;
const Watcher = file_watcher.Watcher;

//
// The watcher the handler wakes. A global, because POSIX signal handlers and Windows console
// handlers receive no pointer from the program, so the handler has no other way to reach the
// watcher. It is set only while a handler is installed.
//
var target: std.atomic.Value(?*Watcher) = .init(null);

//
// Whether a stop was requested since the handler was installed. A global for the same reason as
// `target`.
//
var is_stop_requested: std.atomic.Value(bool) = .init(false);

const windows_api = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (u32) callconv(.winapi) c_int,
        add: c_int,
    ) callconv(.winapi) c_int;
} else struct {};

//
// Starts handling Ctrl+C and termination requests by stopping `watcher`.
//
pub fn install(watcher: *Watcher) void {
    assert(target.load(.acquire) == null);
    is_stop_requested.store(false, .release);
    target.store(watcher, .release);
    set_handlers(true);
    assert(target.load(.acquire) == watcher);
}

//
// Restores the default handling, which ends the process at once.
//
pub fn uninstall() void {
    assert(target.load(.acquire) != null);
    set_handlers(false);
    target.store(null, .release);
}

//
// Whether a stop was requested since `install`.
//
pub fn is_requested() bool {
    return is_stop_requested.load(.acquire);
}

//
// Records a stop request and wakes the watcher. Safe in a signal handler: it only stores
// atomics and makes the system calls `Watcher.wake` makes.
//
pub fn request_stop() void {
    is_stop_requested.store(true, .release);
    if (target.load(.acquire)) |watcher| {
        watcher.wake();
    }
}

//
// Installs the handlers when `is_on` is set, and the defaults otherwise.
//
fn set_handlers(is_on: bool) void {
    if (builtin.os.tag == .windows) {
        // Adding or removing a handler fails only for a null handler, which this never passes.
        _ = windows_api.SetConsoleCtrlHandler(on_console_control, if (is_on) 1 else 0);
        return;
    }
    const action: std.posix.Sigaction = .{
        .handler = .{
            .handler = if (is_on) on_signal else std.posix.SIG.DFL,
        },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

//
// The POSIX signal handler for SIGINT and SIGTERM.
//
fn on_signal(signal: std.posix.SIG) callconv(.c) void {
    _ = signal;
    request_stop();
}

//
// The Windows console handler for Ctrl+C, Ctrl+Break and the console closing.
//
fn on_console_control(kind: u32) callconv(.winapi) c_int {
    _ = kind;
    request_stop();
    return 1;
}
