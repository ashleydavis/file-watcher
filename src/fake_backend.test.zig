//
// A scripted stand-in for a native backend, so watcher tests control exactly which changes are
// reported, which watches fail and when the backend breaks.
//

const std = @import("std");
const mock_io_module = @import("mock_io");

const Allocator = std.mem.Allocator;
const MockIo = mock_io_module.MockIo;

//
// How a fake backend behaves, fixed per type so each test picks its own.
//
pub const Config = struct {
    //
    // The error `init` returns, or null to start.
    //
    init_error: ?anyerror = null,

    //
    // Whether one watch covers a whole tree, like the Windows backend.
    //
    is_recursive: bool = false,

    //
    // Whether files need their own watch, like the kqueue backend.
    //
    watches_files: bool = false,
};

//
// A fake backend with the behaviour given by `config`. The hint types come in as parameters
// because this file is its own module and cannot import the library's files.
//
pub fn FakeBackend(comptime HintSet: type, comptime Scope: type, comptime config: Config) type {
    return struct {
        const Self = @This();

        //
        // One hint the fake reports on its next wait.
        //
        pub const Step = struct {
            path: []const u8,
            scope: Scope,
        };

        pub const is_recursive = config.is_recursive;
        pub const watches_files = config.watches_files;

        gpa: Allocator,

        //
        // The paths watched, owned by the map.
        //
        watched: std.StringArrayHashMapUnmanaged(void),

        //
        // Hints reported on the next wait, borrowed from the test.
        //
        steps: std.ArrayList(Step),

        //
        // The clock the fake advances when it waits with nothing to report. Set by the test.
        //
        mock: ?*MockIo,

        //
        // Watches of these paths fail with `watch_error`.
        //
        failing_path: ?[]const u8,

        //
        // The error a failing watch returns.
        //
        watch_error: anyerror,

        //
        // The error the next wait returns, or null.
        //
        wait_error: ?anyerror,

        pub fn init(self: *Self, gpa: Allocator) !void {
            if (config.init_error) |err| {
                return err;
            }
            self.* = .{
                .gpa = gpa,
                .watched = .empty,
                .steps = .empty,
                .mock = null,
                .failing_path = null,
                .watch_error = error.Unexpected,
                .wait_error = null,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.watched.keys()) |path| {
                self.gpa.free(path);
            }
            self.watched.deinit(self.gpa);
            self.steps.deinit(self.gpa);
            self.* = undefined;
        }

        pub fn watch(self: *Self, path: []const u8, is_directory: bool) !bool {
            _ = is_directory;
            if (self.failing_path) |failing| {
                if (std.mem.eql(u8, failing, path)) {
                    return self.watch_error;
                }
            }
            const result = try self.watched.getOrPut(self.gpa, path);
            if (result.found_existing) {
                return false;
            }
            result.key_ptr.* = self.gpa.dupe(u8, path) catch |err| {
                self.watched.swapRemoveAt(self.watched.count() - 1);
                return err;
            };
            return true;
        }

        pub fn unwatch(self: *Self, path: []const u8) bool {
            const removed = self.watched.fetchSwapRemove(path) orelse return false;
            self.gpa.free(removed.key);
            return true;
        }

        pub fn wait(self: *Self, timeout_ms: u32, hints: *HintSet) !void {
            if (self.wait_error) |err| {
                self.wait_error = null;
                return err;
            }
            if (self.steps.items.len == 0) {
                const mock = self.mock.?;
                mock.clock_ns += @as(i96, timeout_ms) * std.time.ns_per_ms;
                if (mock.sleep_callback) |callback| {
                    callback(mock);
                }
                return;
            }
            for (self.steps.items) |step| {
                try hints.add(step.path, step.scope);
            }
            self.steps.clearRetainingCapacity();
        }

        //
        // Queues hints for the next wait.
        //
        pub fn queue(self: *Self, steps: []const Step) !void {
            try self.steps.appendSlice(self.gpa, steps);
        }
    };
}
