//
// The native backend for Windows. `ReadDirectoryChangesW` watches a whole tree through one
// directory handle and reports changes by relative path, so one watch per root covers every
// directory and file under it.
//

const std = @import("std");
const builtin = @import("builtin");
const hints_module = @import("hints.zig");
const limit = @import("limit.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const HintSet = hints_module.HintSet;

const BOOL = c_int;
const DWORD = u32;
const HANDLE = *anyopaque;

//
// The Win32 structure that tracks an asynchronous read.
//
const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    Offset: DWORD,
    OffsetHigh: DWORD,
    hEvent: ?HANDLE,
};

//
// The header of one change record written by `ReadDirectoryChangesW`. The UTF-16 file name of
// `FileNameLength` bytes follows it.
//
pub const FileNotifyInformation = extern struct {
    NextEntryOffset: DWORD,
    Action: DWORD,
    FileNameLength: DWORD,
};

const FILE_LIST_DIRECTORY: DWORD = 0x0001;
const FILE_SHARE_ALL: DWORD = 0x0001 | 0x0002 | 0x0004;
const OPEN_EXISTING: DWORD = 3;
const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
const WAIT_OBJECT_0: DWORD = 0;
const WAIT_TIMEOUT: DWORD = 258;
const ERROR_FILE_NOT_FOUND: DWORD = 2;
const ERROR_PATH_NOT_FOUND: DWORD = 3;
const ERROR_ACCESS_DENIED: DWORD = 5;
const ERROR_DIRECTORY: DWORD = 267;
const ERROR_IO_PENDING: DWORD = 997;

//
// The changes to report: names of files and directories, attributes, sizes, write times and
// creation times. Together they cover every change the snapshot detects.
//
const notify_filter: DWORD = 0x0001 | 0x0002 | 0x0004 | 0x0008 | 0x0010 | 0x0040;

//
// The size of each root's change buffer. 64 KiB is the largest size Windows accepts for
// directories on network shares, so the same size works for every root.
//
const change_buffer_size: u32 = 64 * 1024;

const windows_api = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadDirectoryChangesW(
        hDirectory: HANDLE,
        lpBuffer: *anyopaque,
        nBufferLength: DWORD,
        bWatchSubtree: BOOL,
        dwNotifyFilter: DWORD,
        lpBytesReturned: ?*DWORD,
        lpOverlapped: *OVERLAPPED,
        lpCompletionRoutine: ?*anyopaque,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateEventW(
        lpEventAttributes: ?*anyopaque,
        bManualReset: BOOL,
        bInitialState: BOOL,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn WaitForMultipleObjects(
        nCount: DWORD,
        lpHandles: [*]const HANDLE,
        bWaitAll: BOOL,
        dwMilliseconds: DWORD,
    ) callconv(.winapi) DWORD;
    extern "kernel32" fn GetOverlappedResult(
        hFile: HANDLE,
        lpOverlapped: *OVERLAPPED,
        lpNumberOfBytesTransferred: *DWORD,
        bWait: BOOL,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
} else struct {};

//
// One watched root and its pending read.
//
const Root = struct {
    //
    // The root path as the caller gave it, owned by the root.
    //
    path: []const u8,

    //
    // The open directory handle.
    //
    handle: HANDLE,

    //
    // The event the system signals when a read completes.
    //
    event: HANDLE,

    //
    // Tracks the pending read. It must not move while the read is pending, which is why roots
    // are allocated one by one.
    //
    overlapped: OVERLAPPED,

    //
    // Receives change records. `ReadDirectoryChangesW` needs it aligned to a `DWORD`.
    //
    buffer: [change_buffer_size]u8 align(@alignOf(DWORD)),
};

//
// The watched roots.
//
pub const ReadDirectoryChanges = struct {
    //
    // One handle watches a whole tree, so the watcher adds roots only.
    //
    pub const is_recursive = true;

    //
    // The tree watch reports file changes too.
    //
    pub const watches_files = false;

    //
    // Allocates the roots.
    //
    gpa: Allocator,

    //
    // The watched roots, in the same order as `events`.
    //
    roots: std.ArrayList(*Root),

    //
    // The event handle of each root, passed to `WaitForMultipleObjects`.
    //
    events: std.ArrayList(HANDLE),

    //
    // Creates a backend with no roots.
    //
    pub fn init(self: *ReadDirectoryChanges, gpa: Allocator) !void {
        self.* = .{
            .gpa = gpa,
            .roots = .empty,
            .events = .empty,
        };
        assert(self.roots.items.len == 0);
    }

    //
    // Cancels every read and closes every handle.
    //
    pub fn deinit(self: *ReadDirectoryChanges) void {
        while (self.roots.items.len > 0) {
            const root = self.roots.items[self.roots.items.len - 1];
            assert(self.unwatch(root.path));
        }
        self.roots.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.* = undefined;
    }

    //
    // Starts watching the tree under the root at `path`. Returns false when it was watched already.
    //
    pub fn watch(self: *ReadDirectoryChanges, path: []const u8, is_directory: bool) !bool {
        assert(is_directory);
        assert(path.len > 0);
        for (self.roots.items) |root| {
            if (std.mem.eql(u8, root.path, path)) {
                return false;
            }
        }
        if (self.roots.items.len >= limit.windows_handles_max) {
            return error.LimitReached;
        }
        try self.roots.ensureUnusedCapacity(self.gpa, 1);
        try self.events.ensureUnusedCapacity(self.gpa, 1);

        const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(self.gpa, path);
        defer self.gpa.free(path_w);

        const root = try self.gpa.create(Root);
        errdefer self.gpa.destroy(root);
        root.path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(root.path);

        const handle = windows_api.CreateFileW(
            path_w.ptr,
            FILE_LIST_DIRECTORY,
            FILE_SHARE_ALL,
            null,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
            null,
        );
        if (@intFromPtr(handle) == std.math.maxInt(usize)) {
            return error_from_code(windows_api.GetLastError());
        }
        errdefer _ = windows_api.CloseHandle(handle);
        const event = windows_api.CreateEventW(null, 1, 0, null) orelse {
            return error_from_code(windows_api.GetLastError());
        };
        errdefer _ = windows_api.CloseHandle(event);

        root.handle = handle;
        root.event = event;
        try start_read(root);
        self.roots.appendAssumeCapacity(root);
        self.events.appendAssumeCapacity(event);
        assert(self.roots.items.len == self.events.items.len);
        return true;
    }

    //
    // Stops watching the root at `path`. Returns false when it was not watched.
    //
    pub fn unwatch(self: *ReadDirectoryChanges, path: []const u8) bool {
        assert(path.len > 0);
        for (self.roots.items, 0..) |root, index| {
            if (std.mem.eql(u8, root.path, path)) {
                _ = self.roots.orderedRemove(index);
                _ = self.events.orderedRemove(index);
                // Cancel the pending read and wait for it to finish, so the system is done
                // with the buffer before it is freed. The results are not needed.
                _ = windows_api.CancelIoEx(root.handle, null);
                var bytes: DWORD = 0;
                _ = windows_api.GetOverlappedResult(root.handle, &root.overlapped, &bytes, 1);
                _ = windows_api.CloseHandle(root.event);
                _ = windows_api.CloseHandle(root.handle);
                self.gpa.free(root.path);
                self.gpa.destroy(root);
                assert(self.roots.items.len == self.events.items.len);
                return true;
            }
        }
        return false;
    }

    //
    // Waits up to `timeout_ms` for changes and records the paths they touch in `hints`.
    //
    pub fn wait(self: *ReadDirectoryChanges, timeout_ms: u32, hints: *HintSet) !void {
        assert(self.events.items.len > 0);
        var timeout = timeout_ms;
        var rounds: usize = 0;
        while (rounds < self.events.items.len) : (rounds += 1) {
            const result = windows_api.WaitForMultipleObjects(
                @intCast(self.events.items.len),
                self.events.items.ptr,
                0,
                timeout,
            );
            if (result == WAIT_TIMEOUT) {
                return;
            }
            const index = result - WAIT_OBJECT_0;
            if (index >= self.events.items.len) {
                return error_from_code(windows_api.GetLastError());
            }
            try read_changes(self.roots.items[index], hints);
            timeout = 0;
        }
    }
};

//
// Starts the next asynchronous read of changes under `root`.
//
fn start_read(root: *Root) !void {
    root.overlapped = .{
        .Internal = 0,
        .InternalHigh = 0,
        .Offset = 0,
        .OffsetHigh = 0,
        .hEvent = root.event,
    };
    const ok = windows_api.ReadDirectoryChangesW(
        root.handle,
        &root.buffer,
        change_buffer_size,
        1,
        notify_filter,
        null,
        &root.overlapped,
        null,
    );
    if (ok == 0) {
        const code = windows_api.GetLastError();
        if (code != ERROR_IO_PENDING) {
            return error_from_code(code);
        }
    }
}

//
// Collects the result of a completed read under `root` and starts the next one. When the read
// failed, the root may be gone, so the root itself is checked. When the buffer overflowed,
// every directory under the root is rescanned.
//
fn read_changes(root: *Root, hints: *HintSet) !void {
    var bytes: DWORD = 0;
    const ok = windows_api.GetOverlappedResult(root.handle, &root.overlapped, &bytes, 0);
    if (ok == 0) {
        try hints.add(root.path, .entry);
        return;
    }
    if (bytes == 0) {
        try hints.add(root.path, .tree);
    } else {
        try decode_changes(root.buffer[0..bytes], root.path, hints);
    }
    start_read(root) catch {
        try hints.add(root.path, .entry);
    };
}

//
// Turns a buffer of change records into hints for paths under `root_path`. Pure, so it is
// tested on every platform.
//
pub fn decode_changes(
    buffer: []align(@alignOf(DWORD)) const u8,
    root_path: []const u8,
    hints: *HintSet,
) !void {
    const header_size = @sizeOf(FileNotifyInformation);
    const arena = hints.arena.allocator();
    const records_max = @divFloor(buffer.len, header_size);
    var offset: usize = 0;
    var records: usize = 0;
    while (true) : (records += 1) {
        assert(records < records_max);
        assert(offset + header_size <= buffer.len);
        const header: *const FileNotifyInformation = @ptrCast(@alignCast(buffer[offset..].ptr));
        const name_start = offset + header_size;
        const name_bytes = buffer[name_start..][0..header.FileNameLength];
        const name_wide: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, name_bytes));
        const name = try std.unicode.wtf16LeToWtf8Alloc(arena, name_wide);
        const path = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ root_path, name });
        try hints.add(path, .entry);
        if (header.NextEntryOffset == 0) {
            return;
        }
        assert(header.NextEntryOffset >= header_size);
        offset += header.NextEntryOffset;
    }
}

//
// Turns a Win32 error code into an error.
//
fn error_from_code(code: DWORD) anyerror {
    return switch (code) {
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
        ERROR_ACCESS_DENIED => error.AccessDenied,
        ERROR_DIRECTORY => error.NotDir,
        else => error.Unexpected,
    };
}

test {
    _ = @import("read_directory_changes.test.zig");
}
