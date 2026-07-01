const std = @import("std");
const app = @import("main.zig");

fn testLogPath(alloc: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

fn createDb(alloc: std.mem.Allocator, path: []const u8) !app.Db {
    return app.Db.open(alloc, std.testing.io, .{
        .log_file_path = path,
        .create_if_missing = true,
    });
}

const ReplayedRecord = union(enum) {
    set: struct {
        key: []const u8,
        value: []const u8,
    },
    delete: []const u8,
};

const ReplayCollector = struct {
    alloc: std.mem.Allocator,
    records: std.ArrayList(ReplayedRecord),

    fn init(alloc: std.mem.Allocator) ReplayCollector {
        return .{
            .alloc = alloc,
            .records = .empty,
        };
    }

    fn deinit(self: *ReplayCollector) void {
        for (self.records.items) |record| {
            switch (record) {
                .set => |entry| {
                    self.alloc.free(entry.key);
                    self.alloc.free(entry.value);
                },
                .delete => |key| self.alloc.free(key),
            }
        }
        self.records.deinit(self.alloc);
    }

    fn apply(self: *ReplayCollector, record: app.Log.Record) !void {
        switch (record) {
            .set => |entry| try self.records.append(self.alloc, .{ .set = .{
                .key = try self.alloc.dupe(u8, entry.key),
                .value = try self.alloc.dupe(u8, entry.value),
            } }),
            .delete => |key| try self.records.append(self.alloc, .{
                .delete = try self.alloc.dupe(u8, key),
            }),
        }
    }
};

test "log replay emits valid records in order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testLogPath(alloc, tmp, "log-replay.log");
    defer alloc.free(path);

    var log = try app.Log.open(alloc, std.testing.io, path, true);
    defer log.close();

    try log.appendPut("name", "karol");
    try log.appendPut("age", "21");
    try log.appendDelete("name");

    var collector = ReplayCollector.init(alloc);
    defer collector.deinit();

    try log.replay(ReplayCollector, &collector, ReplayCollector.apply);

    try std.testing.expectEqual(@as(usize, 3), collector.records.items.len);
    try std.testing.expectEqualStrings("name", collector.records.items[0].set.key);
    try std.testing.expectEqualStrings("karol", collector.records.items[0].set.value);
    try std.testing.expectEqualStrings("age", collector.records.items[1].set.key);
    try std.testing.expectEqualStrings("21", collector.records.items[1].set.value);
    try std.testing.expectEqualStrings("name", collector.records.items[2].delete);
}

test "db set get exists and delete basic operations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testLogPath(alloc, tmp, "basic.log");
    defer alloc.free(path);

    var db = try createDb(alloc, path);
    defer db.close();

    try db.set("name", "karol");
    try std.testing.expect(db.exists("name"));
    try std.testing.expectEqualStrings("karol", db.get("name").?);

    try std.testing.expect(try db.delete("name"));
    try std.testing.expect(!db.exists("name"));
    try std.testing.expectEqual(@as(?[]const u8, null), db.get("name"));
}

test "db overwrites existing key with latest value" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testLogPath(alloc, tmp, "overwrite.log");
    defer alloc.free(path);

    var db = try createDb(alloc, path);
    defer db.close();

    try db.set("age", "21");
    try db.set("age", "22");

    try std.testing.expectEqualStrings("22", db.get("age").?);
}

test "db owns inserted key and value memory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testLogPath(alloc, tmp, "ownership.log");
    defer alloc.free(path);

    var db = try createDb(alloc, path);
    defer db.close();

    var key_buf = [_]u8{ 'k', 'e', 'y' };
    var value_buf = [_]u8{ 'v', 'a', 'l', 'u', 'e' };

    try db.set(key_buf[0..], value_buf[0..]);

    key_buf[0] = '\n';
    value_buf[0] = '\n';

    try std.testing.expectEqualStrings("value", db.get("key").?);
}

test "db replays log on reopen" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testLogPath(alloc, tmp, "replay.log");
    defer alloc.free(path);

    {
        var db = try createDb(alloc, path);
        defer db.close();

        try db.set("name", "karol");
        try db.set("age", "21");
        try db.set("age", "22");
        try std.testing.expect(try db.delete("name"));
    }

    {
        var db = try createDb(alloc, path);
        defer db.close();

        try std.testing.expectEqual(@as(?[]const u8, null), db.get("name"));
        try std.testing.expectEqualStrings("22", db.get("age").?);
    }
}

test "delete missing key returns false and leaves db usable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testLogPath(alloc, tmp, "missing-delete.log");
    defer alloc.free(path);

    var db = try createDb(alloc, path);
    defer db.close();

    try std.testing.expect(!try db.delete("missing"));
    try db.set("present", "yes");
    try std.testing.expectEqualStrings("yes", db.get("present").?);
}

test "open fails when log is missing and creation is disabled" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testLogPath(alloc, tmp, "does-not-exist.log");
    defer alloc.free(path);

    try std.testing.expectError(error.FileNotFound, app.Db.open(alloc, std.testing.io, .{
        .log_file_path = path,
        .create_if_missing = false,
    }));
}

test "operations fail after close" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testLogPath(alloc, tmp, "closed.log");
    defer alloc.free(path);

    var db = try createDb(alloc, path);
    try db.set("before", "close");
    db.close();
    db.close();

    try std.testing.expectError(error.DbClosed, db.set("after", "close"));
    try std.testing.expectError(error.DbClosed, db.delete("before"));
    try std.testing.expectEqual(@as(?[]const u8, null), db.get("before"));
    try std.testing.expect(!db.exists("before"));
}

test "malformed log records are ignored during replay" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testLogPath(alloc, tmp, "malformed.log");
    defer alloc.free(path);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true });
    defer file.close(std.testing.io);

    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(std.testing.io, &write_buf);
    const w = &fw.interface;
    try w.writeAll(
        \\set good value
        \\set too many args
        \\unknown key value
        \\delete
        \\delete good
        \\set final ok
        \\
    );
    try w.flush();

    var db = try createDb(alloc, path);
    defer db.close();

    try std.testing.expectEqual(@as(?[]const u8, null), db.get("good"));
    try std.testing.expectEqualStrings("ok", db.get("final").?);
}
