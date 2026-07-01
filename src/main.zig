const std = @import("std");
const Io = std.Io;

const kdb = @import("kdb");

const Command = enum {
    exit,
    set,
    get,
    delete,
    lst,
};

const ParsedCommand = struct {
    command: Command,
    args: []const []const u8,
};

const ParseError = error{
    EmptyInput,
    UnknownCommand,
    TooManyArgs,
};

fn parseCommand(input: []const u8, args_buf: [][]const u8) ParseError!ParsedCommand {
    var input_it = std.mem.tokenizeAny(u8, input, " \t\r\n");
    const command_str = input_it.next() orelse return error.EmptyInput;

    const command = std.meta.stringToEnum(Command, command_str) orelse return error.UnknownCommand;

    var len: usize = 0;
    while (input_it.next()) |arg| {
        if (len == args_buf.len) return error.TooManyArgs;
        args_buf[len] = arg;
        len += 1;
    }

    return .{
        .command = command,
        .args = args_buf[0..len],
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const log_file_path = "data.log";

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var db = try Db.open(alloc, io, .{
        .log_file_path = log_file_path,
        .create_if_missing = true,
    });
    defer db.close();

    while (true) {
        try stdout.print("kdb> ", .{});
        try stdout.flush();

        const input = try stdin.takeDelimiterExclusive('\n');
        stdin.toss(1);

        var args: [2][]const u8 = undefined;
        const parsed = parseCommand(input, &args) catch |err| switch (err) {
            error.EmptyInput => {
                try stdout.print("No command entered\n", .{});
                continue;
            },
            error.UnknownCommand => {
                try stdout.print("Unknown command: {s}\n", .{input});
                continue;
            },
            error.TooManyArgs => {
                try stdout.print("Too many arguments: {s}\n", .{input});
                continue;
            },
        };

        const command = parsed.command;
        const command_args = parsed.args;

        switch (command) {
            .exit => {
                if (command_args.len != 0) {
                    try stdout.print("Usage: exit\n", .{});
                    continue;
                }
                return;
            },
            .set => {
                if (command_args.len != 2) {
                    try stdout.print("Usage: set <key> <value>\n", .{});
                    continue;
                }

                db.set(command_args[0], command_args[1]) catch |err| {
                    try stdout.print("Error setting key-value pair: {any}\n", .{err});
                    continue;
                };
            },
            .get => {
                if (command_args.len != 1) {
                    try stdout.print("Usage: get <key>\n", .{});
                    continue;
                }
                const value = db.get(command_args[0]) orelse {
                    try stdout.print("Key `{s}` not found\n", .{command_args[0]});
                    continue;
                };
                try stdout.print("{s}\n", .{value});
            },
            .delete => {
                if (command_args.len != 1) {
                    try stdout.print("Usage: delete <key>\n", .{});
                    continue;
                }
                _ = db.delete(command_args[0]) catch |err| {
                    try stdout.print("Error deleting key: {any}\n", .{err});
                    continue;
                };
                try stdout.print("ok\n", .{});
            },
            .lst => {
                if (command_args.len != 0) {
                    try stdout.print("Usage: lst\n", .{});
                    continue;
                }
                var entries = db.index.iterator();
                while (entries.next()) |entry| {
                    try stdout.print("{s} -> {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            },
        }

        try stdout.flush();
    }
}

pub const Log = struct {
    pub const Record = union(enum) {
        set: struct {
            key: []const u8,
            value: []const u8,
        },
        delete: []const u8,
    };

    alloc: std.mem.Allocator,
    file: std.Io.File,
    path: []const u8,
    io: std.Io,

    pub fn open(
        alloc: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        create_if_no_exist: bool,
    ) !Log {
        var file_exists = true;
        std.Io.Dir.cwd().access(io, path, .{ .write = true }) catch |err| {
            file_exists = err != std.Io.Dir.AccessError.FileNotFound;
        };

        var f: std.Io.File = undefined;
        if (file_exists) {
            f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        } else if (create_if_no_exist) {
            f = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true });
        } else {
            return error.FileNotFound;
        }

        return Log{
            .alloc = alloc,
            .file = f,
            .path = path,
            .io = io,
        };
    }

    pub fn close(self: *Log) void {
        self.file.close(self.io);
    }

    pub fn appendPut(self: *Log, key: []const u8, value: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var fw = self.file.writer(self.io, &write_buf);
        const w = &fw.interface;

        const log_entry = try std.fmt.allocPrint(self.alloc, "set {s} {s}\n", .{ key, value });
        defer self.alloc.free(log_entry);

        const file_len = try self.file.length(self.io);
        try fw.seekTo(file_len);

        try w.writeAll(log_entry);
        try w.flush();
    }

    pub fn appendDelete(self: *Log, key: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var fw = self.file.writer(self.io, &write_buf);
        const w = &fw.interface;

        const log_entry = try std.fmt.allocPrint(self.alloc, "delete {s}\n", .{key});
        defer self.alloc.free(log_entry);

        const file_len = try self.file.length(self.io);
        try fw.seekTo(file_len);

        try w.writeAll(log_entry);
        try w.flush();
    }

    pub fn replay(
        self: *Log,
        comptime Ctx: type,
        context: *Ctx,
        comptime apply: fn (*Ctx, Record) anyerror!void,
    ) !void {
        var read_buf: [4096]u8 = undefined;
        var fr = self.file.reader(self.io, &read_buf);
        const r = &fr.interface;

        while (true) {
            const line = r.takeDelimiterExclusive('\n') catch |err| {
                if (err == std.Io.Reader.Error.EndOfStream) break;
                return err;
            };
            r.toss(1);
            if (line.len == 0) break;

            var args: [2][]const u8 = undefined;
            const parsed = parseCommand(line, &args) catch |err| switch (err) {
                error.EmptyInput => continue,
                error.UnknownCommand => continue,
                error.TooManyArgs => continue,
            };

            const command = parsed.command;
            const command_args = parsed.args;

            switch (command) {
                .set => {
                    if (command_args.len != 2) continue;
                    try apply(context, .{ .set = .{
                        .key = command_args[0],
                        .value = command_args[1],
                    } });
                },
                .delete => {
                    if (command_args.len != 1) continue;
                    try apply(context, .{ .delete = command_args[0] });
                },
                else => {},
            }
        }
    }
};

pub const Db = struct {
    const DbOptions = struct {
        log_file_path: []const u8,
        create_if_missing: bool = true,
    };

    alloc: std.mem.Allocator,
    index: std.StringHashMap([]const u8),
    log: Log,
    state: enum {
        open,
        closed,
    } = .closed,

    pub fn open(alloc: std.mem.Allocator, io: std.Io, options: DbOptions) !Db {
        var log = try Log.open(alloc, io, options.log_file_path, options.create_if_missing);
        errdefer log.close();
        const index = std.StringHashMap([]const u8).init(alloc);

        var db = Db{
            .alloc = alloc,
            .index = index,
            .log = log,
            .state = .open,
        };
        errdefer db.close();

        try db.log.replay(Db, &db, applyLogRecord);

        return db;
    }

    pub fn close(self: *Db) void {
        if (self.state == .closed) return;
        self.state = .closed;

        var entries = self.index.iterator();
        while (entries.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.index.deinit();
        self.log.close();
    }

    pub fn set(self: *Db, key: []const u8, value: []const u8) !void {
        if (self.state != .open) return error.DbClosed;

        try self.log.appendPut(key, value);
        try self.putInIndex(key, value);
    }

    fn putInIndex(self: *Db, key: []const u8, value: []const u8) !void {
        const key_copy = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(key_copy);
        const value_copy = try self.alloc.dupe(u8, value);
        errdefer self.alloc.free(value_copy);

        const res = try self.index.getOrPut(key_copy);
        if (!res.found_existing) {
            res.value_ptr.* = value_copy;
        } else {
            self.alloc.free(res.value_ptr.*);
            self.alloc.free(res.key_ptr.*);
            res.key_ptr.* = key_copy;
            res.value_ptr.* = value_copy;
        }
    }

    pub fn get(self: *const Db, key: []const u8) ?[]const u8 {
        if (self.state != .open) return null;
        return self.index.get(key);
    }

    pub fn delete(self: *Db, key: []const u8) !bool {
        if (self.state != .open) return error.DbClosed;
        try self.log.appendDelete(key);

        return self.deleteFromIndex(key);
    }

    fn deleteFromIndex(self: *Db, key: []const u8) bool {
        if (self.index.fetchRemove(key)) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
            return true;
        }
        return false;
    }

    pub fn exists(self: *const Db, key: []const u8) bool {
        if (self.state != .open) return false;
        return self.index.get(key) != null;
    }

    fn applyLogRecord(self: *Db, record: Log.Record) !void {
        switch (record) {
            .set => |entry| try self.putInIndex(entry.key, entry.value),
            .delete => |key| _ = self.deleteFromIndex(key),
        }
    }
};

test "parseInput ignores leading trailing and repeated whitespace" {
    var args: [2][]const u8 = undefined;
    const parsed = try parseCommand(" \t set   key\tvalue  \r", &args);

    try std.testing.expectEqual(Command.set, parsed.command);
    try std.testing.expectEqual(@as(usize, 2), parsed.args.len);
    try std.testing.expectEqualStrings("key", parsed.args[0]);
    try std.testing.expectEqualStrings("value", parsed.args[1]);
}

test "parseInput handles single argument command" {
    var args: [2][]const u8 = undefined;
    const parsed = try parseCommand("get   key", &args);

    try std.testing.expectEqual(Command.get, parsed.command);
    try std.testing.expectEqual(@as(usize, 1), parsed.args.len);
    try std.testing.expectEqualStrings("key", parsed.args[0]);
}

test "parseInput rejects unknown commands and too many args" {
    var args: [2][]const u8 = undefined;

    try std.testing.expectError(error.UnknownCommand, parseCommand("wat key", &args));
    try std.testing.expectError(error.TooManyArgs, parseCommand("set key value extra", &args));
}
