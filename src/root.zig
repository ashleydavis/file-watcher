//
// The library's public interface. Projects that depend on the package import this module and
// use the names below.
//

const event = @import("event.zig");
const options = @import("options.zig");
const watcher = @import("watcher.zig");

pub const Watcher = watcher.Watcher;
pub const Batch = watcher.Batch;
pub const Stats = watcher.Stats;
pub const Options = options.Options;
pub const Method = options.Method;
pub const default_excluded_directories = options.default_excluded_directories;
pub const is_valid = options.is_valid;
pub const Event = event.Event;
pub const EventKind = event.EventKind;
pub const Problem = event.Problem;
pub const ProblemAction = event.ProblemAction;

test {
    _ = @import("event.zig");
    _ = @import("filter.zig");
    _ = @import("hints.zig");
    _ = @import("inotify.zig");
    _ = @import("kqueue.zig");
    _ = @import("limit.zig");
    _ = @import("options.zig");
    _ = @import("read_directory_changes.zig");
    _ = @import("windows_listing.zig");
    _ = @import("snapshot.zig");
    _ = @import("watcher.zig");
}
