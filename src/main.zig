const std = @import("std");
const Io = std.Io;

const kdb = @import("kdb");

const Command = enum {
    exit,
    set,
    get,
    delete,
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

fn parseInput(input: []const u8, args_buf: [][]const u8) ParseError!ParsedCommand {
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

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var index = std.StringHashMap([]const u8).init(alloc);
    defer {
        var entries = index.iterator();
        while (entries.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        index.deinit();
    }

    while (true) {
        try stdout.print("kdb> ", .{});
        try stdout.flush();

        const input = try stdin.takeDelimiterExclusive('\n');
        stdin.toss(1);

        var args: [2][]const u8 = undefined;
        const parsed = parseInput(input, &args) catch |err| switch (err) {
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

                const key = try alloc.dupe(u8, command_args[0]);
                errdefer alloc.free(key);
                const value = try alloc.dupe(u8, command_args[1]);
                errdefer alloc.free(value);

                if (try index.fetchPut(key, value)) |old| {
                    alloc.free(old.key);
                    alloc.free(old.value);
                }
            },
            .get => {
                if (command_args.len != 1) {
                    try stdout.print("Usage: get <key>\n", .{});
                    continue;
                }
                const value = index.get(command_args[0]) orelse {
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
                if (index.fetchRemove(command_args[0])) |old| {
                    alloc.free(old.key);
                    alloc.free(old.value);
                } else {
                    try stdout.print("Key `{s}` not found\n", .{command_args[0]});
                    continue;
                }
                try stdout.print("ok\n", .{});
            },
        }

        try stdout.flush();
    }
}

test "parseInput ignores leading trailing and repeated whitespace" {
    var args: [2][]const u8 = undefined;
    const parsed = try parseInput(" \t set   key\tvalue  \r", &args);

    try std.testing.expectEqual(Command.set, parsed.command);
    try std.testing.expectEqual(@as(usize, 2), parsed.args.len);
    try std.testing.expectEqualStrings("key", parsed.args[0]);
    try std.testing.expectEqualStrings("value", parsed.args[1]);
}

test "parseInput handles single argument command" {
    var args: [2][]const u8 = undefined;
    const parsed = try parseInput("get   key", &args);

    try std.testing.expectEqual(Command.get, parsed.command);
    try std.testing.expectEqual(@as(usize, 1), parsed.args.len);
    try std.testing.expectEqualStrings("key", parsed.args[0]);
}

test "parseInput rejects unknown commands and too many args" {
    var args: [2][]const u8 = undefined;

    try std.testing.expectError(error.UnknownCommand, parseInput("wat key", &args));
    try std.testing.expectError(error.TooManyArgs, parseInput("set key value extra", &args));
}
