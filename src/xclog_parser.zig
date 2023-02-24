const std = @import("std");
const shlx = @import("shlex.zig");
const xclog = @import("xcactivitylog.zig");

const SwiftcInfo = struct { swift_files: []const []const u8, swift_filelists: []const []const u8, module_name: []const u8, index_store_path: []const u8 };

fn extract_infos_from_swiftc(command: []const u8) !SwiftcInfo {
    const args = try shlx.split(command);
    var module_name: []u8 = undefined;
    var index_store_path: []u8 = undefined;
    var swift_files = std.ArrayList([]u8).init(std.heap.c_allocator);
    var swift_filelists = std.ArrayList([]u8).init(std.heap.c_allocator);
    for (args) |arg, i| {
        if (std.mem.startsWith(u8, arg, "-module-name")) {
            module_name = args[i + 1];
        } else if (std.mem.startsWith(u8, arg, "-index-store-path")) {
            index_store_path = args[i + 1];
        } else if (std.mem.endsWith(u8, arg, ".swift")) {
            try swift_files.append(arg);
        } else if (std.mem.endsWith(u8, arg, ".SwiftFileList")) {
            try swift_filelists.append(arg[1..arg.len]);
        }
    }
    return SwiftcInfo{
        .swift_files = try swift_files.toOwnedSlice(),
        .swift_filelists = try swift_filelists.toOwnedSlice(),
        .module_name = module_name,
        .index_store_path = index_store_path,
    };
}

test "extract from swiftc" {
    var input = "swiftc a.swift -module-name b -index-store-path c @d.SwiftFileList";
    const expected = SwiftcInfo{
        .swift_files = &[_][]const u8{"a.swift"},
        .swift_filelists = &[_][]const u8{"d.SwiftFileList"},
        .module_name = "b",
        .index_store_path = "c",
    };
    const actual = try extract_infos_from_swiftc(input);
    try std.testing.expectEqualSlices(u8, expected.swift_filelists[0], actual.swift_filelists[0]);
    try std.testing.expectEqualSlices(u8, expected.swift_files[0], actual.swift_files[0]);
    try std.testing.expectEqualSlices(u8, expected.module_name, actual.module_name);
    try std.testing.expectEqualSlices(u8, expected.index_store_path, actual.index_store_path);
}

const Swiftc = struct {
    directory: []const u8,
    command: []const u8,
    module_name: []const u8,
    files: []const []const u8,
    filelists: []const []const u8,
};

const XcodeLogParser = struct {
    index_store_path: std.StringHashMap(void),

    fn init() XcodeLogParser {
        return XcodeLogParser{ .index_store_path = std.StringHashMap(void).init(std.heap.c_allocator) };
    }

    fn parse_swiftc(self: *XcodeLogParser, input: []const []const u8) ?Swiftc {
        const line = input[0];
        if (!std.mem.startsWith(u8, line, "CompileSwiftSources ")) return null;
        const command = input[input.len - 1];
        if (std.mem.indexOf(u8, command, "bin/swiftc") == null) return null;
        var directory: []const u8 = undefined;
        for (input[1..]) |l| {
            if (std.mem.startsWith(u8, l, "cd ")) {
                const args = shlx.split(l) catch return null;
                directory = args[1];
                break;
            }
        }
        const info = extract_infos_from_swiftc(command) catch return null;
        if (info.swift_filelists.len > 0) {
            self.index_store_path.put(info.module_name, {}) catch return null;
        }
        return Swiftc{
            .directory = directory,
            .command = command,
            .module_name = info.module_name,
            .files = info.swift_files,
            .filelists = info.swift_filelists,
        };
    }

    fn parse_swift_driver(self: *XcodeLogParser, input: []const []const u8) ?Swiftc {
        const line = input[0];
        if (!std.mem.startsWith(u8, line, "SwiftDriver")) return null;
        var command = input[input.len - 1];
        if (!std.mem.startsWith(u8, command, "builtin-Swift-Compilation -- ") and
            !std.mem.startsWith(u8, command, "builtin-SwiftDriver -- ")) return null;

        if (std.mem.indexOf(u8, command, "bin/swiftc") == null) return null;
        const index = std.mem.indexOf(u8, command, " -- ") orelse return null;
        command = command[index + " -- ".len ..];
        var directory: []const u8 = undefined;
        for (input[1..]) |l| {
            if (std.mem.startsWith(u8, l, "cd ")) {
                const args = shlx.split(l) catch return null;
                directory = args[1];
                break;
            }
        }
        const info = extract_infos_from_swiftc(command) catch return null;
        if (info.swift_filelists.len > 0) {
            self.index_store_path.put(info.module_name, {}) catch return null;
        }
        return Swiftc{
            .directory = directory,
            .command = command,
            .module_name = info.module_name,
            .files = info.swift_files,
            .filelists = info.swift_filelists,
        };
    }

    fn parse(self: *XcodeLogParser, input: []const []const u8) !Swiftc {
        return self.parse_swiftc(input) orelse self.parse_swift_driver(input) orelse return error.InvalidMacher;
    }
};

pub fn parse(path: []const u8) ![]Swiftc {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer file.close();
    var gzip_stream = try std.compress.gzip.decompress(std.heap.c_allocator, file.reader());
    defer gzip_stream.deinit();
    const reader = gzip_stream.reader();
    const content = try reader.readAllAlloc(std.heap.c_allocator, std.math.maxInt(usize));
    var parser = XcodeLogParser.init();
    var infos = std.ArrayList(Swiftc).init(std.heap.c_allocator);

    var logs = try xclog.extract_compile_log(content);

    for (logs) |log| {
        var splitter = std.mem.split(u8, log, "\r");
        var lines = std.ArrayList([]const u8).init(std.heap.c_allocator);
        while (splitter.next()) |line| {
            var l = std.mem.trim(u8, line, " ");
            if (l.len > 0) try lines.append(l);
        }
        if (lines.items.len <= 1) {
            lines.deinit();
            continue;
        }
        var info = parser.parse(try lines.toOwnedSlice()) catch continue;
        // std.debug.print("module_name: {s}\n", .{info.module_name});
        // std.debug.print("directory: {s}\n", .{info.directory});
        // std.debug.print("filelists: {d}\n", .{info.filelists.len});
        try infos.append(info);
    }

    return infos.toOwnedSlice();
}

test "parse xclog" {
    const path = "/Users/miloas/Library/Developer/Xcode/DerivedData/final_input-begpicrvpfuaetexncumwacqbywz/Logs/Build/39932C67-9BAD-4F3E-B17C-2410AF4DC667.xcactivitylog";
    const infos = try parse(path);
    try std.testing.expect(infos.len > 0);
}
