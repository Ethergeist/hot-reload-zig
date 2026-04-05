const std = @import("std");
const Dynlib = std.DynLib;

pub const Plugin = struct {
    pub const Error = error{ Initialization, Shutdown, SymbolNotFound, Update };
    pub const Hook = ?*const fn (*Plugin) callconv(.c) c_int;

    pub const Log = struct {
        _write: *const fn (level: u8, msg: [*:0]const u8) callconv(.c) void,

        pub fn info(self: *const Log, comptime fmt: []const u8, args: anytype) void {
            var buf: [1024:0]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
            self._write(@intFromEnum(std.log.Level.info), msg.ptr);
        }
        pub fn err(self: *const Log, comptime fmt: []const u8, args: anytype) void {
            var buf: [1024:0]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
            self._write(@intFromEnum(std.log.Level.err), msg.ptr);
        }
        pub fn warn(self: *const Log, comptime fmt: []const u8, args: anytype) void {
            var buf: [1024:0]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
            self._write(@intFromEnum(std.log.Level.warn), msg.ptr);
        }
        pub fn debug(self: *const Log, comptime fmt: []const u8, args: anytype) void {
            var buf: [1024:0]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
            self._write(@intFromEnum(std.log.Level.debug), msg.ptr);
        }
    };

    allocator: std.mem.Allocator,
    log: Log,
    name: []const u8,
    path: []u8,
    backupPath: []u8,
    tempPath: []u8,
    handle: ?Dynlib = null,
    timestamp: i128,
    startup: Hook = null,
    shutdown: Hook = null,
    update: Hook = null,

    pub fn init(allocator: std.mem.Allocator, log: Log, name: []const u8) !Plugin {
        const cwd = std.fs.cwd();
        cwd.makeDir("plugins") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const path = try std.fmt.allocPrint(allocator, "plugins/{s}.plg", .{name});
        errdefer allocator.free(path);
        const backupPath = try std.fmt.allocPrint(allocator, "{s}.old", .{path});
        errdefer allocator.free(backupPath);
        const tempPath = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        errdefer allocator.free(tempPath);
        const stat = cwd.statFile(path) catch |err| {
            std.log.err("Unable to get timestamp from path {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
        return .{
            .allocator = allocator,
            .log = log,
            .name = name,
            .path = path,
            .backupPath = backupPath,
            .tempPath = tempPath,
            .timestamp = stat.mtime,
        };
    }

    pub fn deinit(self: *Plugin) void {
        self.allocator.free(self.path);
        self.allocator.free(self.backupPath);
        self.allocator.free(self.tempPath);
    }

    pub fn backup(self: *Plugin) !void {
        self.log.debug("Backing up plugin {s}: {s} -> {s}", .{ self.name, self.tempPath, self.backupPath });
        std.fs.cwd().copyFile(self.tempPath, std.fs.cwd(), self.backupPath, .{}) catch |err| {
            self.log.err("Failed to backup plugin {s}: {s}", .{ self.name, @errorName(err) });
            return err;
        };
    }

    pub fn copyTemp(self: *Plugin) !void {
        self.log.debug("Copying {s} -> {s}", .{ self.path, self.tempPath });
        var tempExists = true;
        std.fs.cwd().access(self.tempPath, .{}) catch {
            tempExists = false;
        };
        if (tempExists) try self.backup();
        std.fs.cwd().copyFile(self.path, std.fs.cwd(), self.tempPath, .{}) catch |err| {
            self.log.err("Failed to copy plugin {s} to temp: {s}", .{ self.name, @errorName(err) });
            return err;
        };
    }

    pub fn checkForUpdate(self: *Plugin) !void {
        const stat = std.fs.cwd().statFile(self.path) catch |err| {
            self.log.err("Failed to stat plugin {s}: {s}", .{ self.name, @errorName(err) });
            return err;
        };
        if (stat.mtime != self.timestamp) {
            self.log.info("Update detected for plugin {s}, reloading...", .{self.name});
            self.open() catch |err| {
                self.log.err("Failed to reload plugin {s}: {s}, rolling back...", .{ self.name, @errorName(err) });
                try self.rollback();
                return;
            };
            self.timestamp = stat.mtime;
        }
    }

    pub fn close(self: *Plugin) !void {
        self.log.debug("Closing plugin {s}", .{self.name});
        self.onShutdown() catch |err| {
            self.log.err("Error shutting down plugin {s}: {s}", .{ self.name, @errorName(err) });
        };
        if (self.handle) |*h| h.close();
        self.handle = null;
    }

    pub fn open(self: *Plugin) !void {
        if (self.handle != null) try self.close();
        try self.copyTemp();
        self.log.debug("Opening plugin {s}", .{self.name});
        self.handle = try Dynlib.open(self.tempPath);
        if (self.handle) |*h| {
            self.startup = h.lookup(*const fn (*Plugin) callconv(.c) c_int, "startup") orelse return error.SymbolNotFound;
            self.shutdown = h.lookup(*const fn (*Plugin) callconv(.c) c_int, "shutdown") orelse return error.SymbolNotFound;
            self.update = h.lookup(*const fn (*Plugin) callconv(.c) c_int, "update") orelse return error.SymbolNotFound;
        }
        try self.onStartup();
    }

    pub fn rollback(self: *Plugin) !void {
        self.log.info("Rolling back plugin {s}...", .{self.name});
        std.fs.cwd().copyFile(self.backupPath, std.fs.cwd(), self.path, .{}) catch |err| {
            self.log.err("Failed to rollback plugin {s}: {s}", .{ self.name, @errorName(err) });
            return err;
        };
        try self.open();
    }

    pub fn onStartup(self: *Plugin) !void {
        if (self.startup) |hook| {
            if (hook(self) != 0) return Error.Initialization;
        }
    }

    pub fn onShutdown(self: *Plugin) !void {
        if (self.shutdown) |hook| {
            if (hook(self) != 0) return Error.Shutdown;
        }
    }

    pub fn onUpdate(self: *Plugin) !void {
        if (self.update) |hook| {
            if (hook(self) != 0) return Error.Update;
        }
    }
};
