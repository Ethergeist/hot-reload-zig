const std = @import("std");
const builtin = @import("builtin");

const app_bin = "zig-out/bin/hot-reload";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try build(allocator);
    var app_child = try spawnApp(allocator);

    switch (builtin.os.tag) {
        .linux => try watchLinux(allocator, &app_child),
        .windows => try watchWindows(allocator, &app_child),
        .macos => try watchMacos(allocator, &app_child),
        else => @compileError("unsupported platform"),
    }
}

fn build(allocator: std.mem.Allocator) !void {
    std.debug.print("Building...\n", .{});
    var child = std.process.Child.init(&.{ "zig", "build" }, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) std.debug.print("Build failed (exit code {d})\n", .{code}),
        else => std.debug.print("Build process terminated unexpectedly\n", .{}),
    }
}

fn spawnApp(allocator: std.mem.Allocator) !std.process.Child {
    std.debug.print("Starting app...\n", .{});
    var child = std.process.Child.init(&.{app_bin}, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

fn checkAndRespawn(allocator: std.mem.Allocator, app_child: *std.process.Child) !void {
    if (hasCrashed(app_child)) {
        std.debug.print("App has crashed, restarting...\n", .{});
        app_child.* = try spawnApp(allocator);
    }
}

fn hasCrashed(app_child: *std.process.Child) bool {
    switch (builtin.os.tag) {
        .linux, .macos => {
            const result = std.posix.waitpid(app_child.id, std.posix.W.NOHANG);
            return result.pid == app_child.id;
        },
        .windows => {
            const rc = std.os.windows.kernel32.WaitForSingleObject(app_child.handle, 0);
            return rc == std.os.windows.WAIT_OBJECT_0;
        },
        else => return false,
    }
}

fn onChanged(allocator: std.mem.Allocator, app_child: *std.process.Child) !void {
    try build(allocator);
    try checkAndRespawn(allocator, app_child);
}

// --- Linux (inotify) ---

fn watchLinux(allocator: std.mem.Allocator, app_child: *std.process.Child) !void {
    const inotify_fd = try std.posix.inotify_init1(0);
    defer std.posix.close(inotify_fd);

    try addWatchesLinux(allocator, inotify_fd, "src");

    std.debug.print("Watching src/ for .zig file changes...\n", .{});

    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    while (true) {
        const len = try std.posix.read(inotify_fd, &buf);
        var offset: usize = 0;
        var triggered = false;
        while (offset < len) {
            const event: *std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));
            const name_ptr: [*:0]u8 = @ptrCast(&buf[offset + @sizeOf(std.os.linux.inotify_event)]);
            if (event.len > 0) {
                const name = std.mem.sliceTo(name_ptr, 0);
                if (std.mem.endsWith(u8, name, ".zig")) triggered = true;
            }
            offset += @sizeOf(std.os.linux.inotify_event) + event.len;
        }
        if (triggered) try onChanged(allocator, app_child);
    }
}

fn addWatchesLinux(allocator: std.mem.Allocator, inotify_fd: i32, path: []const u8) !void {
    const flags = std.os.linux.IN.MODIFY | std.os.linux.IN.MOVED_TO | std.os.linux.IN.CREATE;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    _ = try std.posix.inotify_add_watch(inotify_fd, path_z, flags);

    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            const subpath = try std.fs.path.join(allocator, &.{ path, entry.name });
            defer allocator.free(subpath);
            try addWatchesLinux(allocator, inotify_fd, subpath);
        }
    }
}

// --- macOS (kqueue) ---

fn watchMacos(allocator: std.mem.Allocator, app_child: *std.process.Child) !void {
    const kq = try std.posix.kqueue();
    defer std.posix.close(kq);

    var fds = std.ArrayList(std.posix.fd_t).init(allocator);
    defer {
        for (fds.items) |fd| std.posix.close(fd);
        fds.deinit();
    }

    try addWatchesMacos(allocator, kq, "src", &fds);

    std.debug.print("Watching src/ for .zig file changes...\n", .{});

    var events: [32]std.posix.Kevent = undefined;
    while (true) {
        const n = try std.posix.kevent(kq, &.{}, &events, null);
        if (n > 0) try onChanged(allocator, app_child);
    }
}

fn addWatchesMacos(allocator: std.mem.Allocator, kq: std.posix.fd_t, path: []const u8, fds: *std.ArrayList(std.posix.fd_t)) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = try std.posix.open(path_z, .{ .EVTONLY = true }, 0);
    try fds.append(fd);

    const change = std.posix.Kevent{
        .ident = @intCast(fd),
        .filter = std.posix.EVFILT_VNODE,
        .flags = std.posix.EV_ADD | std.posix.EV_ENABLE | std.posix.EV_CLEAR,
        .fflags = std.posix.NOTE_WRITE | std.posix.NOTE_RENAME | std.posix.NOTE_CREATE,
        .data = 0,
        .udata = 0,
    };
    _ = try std.posix.kevent(kq, &.{change}, &.{}, null);

    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            const subpath = try std.fs.path.join(allocator, &.{ path, entry.name });
            defer allocator.free(subpath);
            try addWatchesMacos(allocator, kq, subpath, fds);
        }
    }
}

// --- Windows (ReadDirectoryChangesW) ---

fn watchWindows(allocator: std.mem.Allocator, app_child: *std.process.Child) !void {
    const windows = std.os.windows;

    const handle = windows.kernel32.CreateFileW(
        std.unicode.utf8ToUtf16LeStringLiteral("src"),
        windows.FILE_LIST_DIRECTORY,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return error.OpenFailed;
    defer windows.CloseHandle(handle);

    std.debug.print("Watching src/ for .zig file changes...\n", .{});

    var buf: [65536]u8 align(@alignOf(windows.FILE_NOTIFY_INFORMATION)) = undefined;
    var bytes_returned: windows.DWORD = 0;

    while (true) {
        const ok = windows.kernel32.ReadDirectoryChangesW(
            handle,
            &buf,
            buf.len,
            1,
            windows.FILE_NOTIFY_CHANGE_LAST_WRITE | windows.FILE_NOTIFY_CHANGE_FILE_NAME,
            &bytes_returned,
            null,
            null,
        );
        if (ok == 0) return error.ReadFailed;

        var offset: usize = 0;
        var triggered = false;
        while (offset < bytes_returned) {
            const info: *windows.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(&buf[offset]));
            const name_u16 = @as([*]u16, @ptrCast(&info.FileName))[0 .. info.FileNameLength / 2];
            var name_buf: [512]u8 = undefined;
            const name = std.unicode.utf16LeToUtf8(&name_buf, name_u16) catch "";
            if (std.mem.endsWith(u8, name, ".zig")) triggered = true;
            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
        if (triggered) try onChanged(allocator, app_child);
    }
}
