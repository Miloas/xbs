const std = @import("std");
const shlx = @import("shlex.zig");
const Swiftc = @import("xclog_parser.zig").Swiftc;

pub fn dump_database(items: []const Swiftc, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const writer = file.writer();
    try std.json.stringify(items, .{ .whitespace = .{ .indent = .Tab } }, writer);
}

// test "dump database" {
//     const items = [_]Swiftc{
//         Swiftc{
//             .command = "swiftc -use-frontend-parseable-output -c -primary-file",
//             .directory = "/Users/xxx/xxx",
//             .module_name = "a",
//             .files = &[_][]const u8{ "a.swift", "b.swift" },
//             .fileLists = &[_][]const u8{ "a.txt", "b.txt" },
//         },
//     };
//     const path = "test.json";
//     try dump_database(&items, path);
// }

pub fn merge_database(items: []const Swiftc, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const contents = try file.readToEndAlloc(std.heap.c_allocator, stat.size);
    var token_stream = std.json.TokenStream.init(contents);
    const parse_options = std.json.ParseOptions{ .allocator = std.heap.c_allocator, .ignore_unknown_fields = true };
    const old_items = try std.json.parse([]Swiftc, &token_stream, parse_options);
    errdefer std.json.parseFree([]Swiftc, old_items, parse_options);

    // module name -> Swiftc
    var module_map = std.StringHashMap(Swiftc).init(std.heap.c_allocator);
    for (old_items) |item| {
        try module_map.put(item.identifier(), item);
    }
    for (items) |item| {
        if (item.identifier().len == 0) continue;
        try module_map.put(item.identifier(), item);
    }
    var it = module_map.valueIterator();
    var ret = std.ArrayList(Swiftc).init(std.heap.c_allocator);
    while (it.next()) |item| {
        try ret.append(item.*);
    }
    try dump_database(try ret.toOwnedSlice(), path);
}

// test "merge database" {
//     const items = [_]Swiftc{
//         Swiftc{
//             .command = "swiftc -use-frontend-parseable-output -c -primary-file",
//             .directory = "/Users/xxx/xxx/a",
//             .module_name = "a",
//             .files = &[_][]const u8{ "a.swift", "b.swift", "c.swift" },
//             .fileLists = &[_][]const u8{ "a.txt", "b.txt" },
//         },
//         Swiftc{
//             .command = "swiftc -use-frontend-parseable-output -c -primary-file",
//             .directory = "/Users/xxx/xxx/b",
//             .module_name = "b",
//             .files = &[_][]const u8{"b.swift"},
//             .fileLists = &[_][]const u8{"b.txt"},
//         },
//     };
//     const path = "test.json";
//     try merge_database(&items, path);
// }

fn trans2Lowercase(s: []const u8) ![]const u8 {
    var ret = std.ArrayList(u8).init(std.heap.c_allocator);
    for (s) |c| {
        try ret.append(std.ascii.toLower(c));
    }
    return try ret.toOwnedSlice();
}

test "trans to lowercase" {
    const s = "ABC";
    const t = try trans2Lowercase(s);
    try std.testing.expectEqualSlices(u8, "abc", t);
}

const Filelists = struct {
    // filelist -> files
    cache: std.StringHashMap([]const []const u8),
    files: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Filelists {
        return Filelists{
            .cache = std.StringHashMap([]const []const u8).init(allocator),
            .files = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Filelists) void {
        self.files.deinit();
        self.cache.deinit();
    }

    pub fn get_files(self: *Filelists, filelists: []const []const u8) ![]const []const u8 {
        for (filelists) |filelist| {
            var files: []const []const u8 = undefined;
            if (self.cache.contains(filelist)) {
                files = self.cache.get(filelist) orelse undefined;
            } else {
                const file = std.fs.openFileAbsolute(filelist, .{ .mode = .read_only }) catch {
                    continue;
                };
                defer file.close();
                const stat = try file.stat();
                if (stat.kind == .Directory) continue;
                const contents = try file.readToEndAlloc(std.heap.c_allocator, stat.size);
                files = try shlx.split(contents);

                try self.cache.put(filelist, files);
            }
            for (files) |f| {
                var realpath = try std.fs.realpathAlloc(self.allocator, f);

                const trimed_realpath = std.mem.trim(u8, realpath, &std.ascii.whitespace);

                try self.files.append(trimed_realpath);
            }
        }
        return try self.files.toOwnedSlice();
    }
};

// test "filelists.get_files" {
//     const file = try std.fs.openFileAbsolute("/Users/miloas/Desktop/final input/.compile", .{ .mode = .read_only });
//     defer file.close();
//     const stat = try file.stat();
//     const contents = try file.readToEndAlloc(std.testing.allocator, stat.size);
//     defer std.testing.allocator.free(contents);
//     var token_stream = std.json.TokenStream.init(contents);
//     const parse_options = std.json.ParseOptions{ .allocator = std.testing.allocator, .ignore_unknown_fields = true };
//     const items = try std.json.parse([]Swiftc, &token_stream, parse_options);
//     defer std.json.parseFree([]Swiftc, items, parse_options);
//     const filelists = items[0].fileLists;
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     var fl = Filelists.init(arena.allocator());
//     defer fl.deinit();
//     const files = try fl.get_files(filelists);
//     const epect_files = &[_][]const u8{ "/Users/miloas/Desktop/final input/final input/ContentView.swift", "/Users/miloas/Desktop/final input/final input/FinalInputApp.swift" };
//     for (files, epect_files) |f, expect_f| {
//         try std.testing.expectEqualSlices(u8, expect_f, f);
//     }
// }

const CompilationDatabase = struct {
    // filename -> command
    cache: std.StringHashMap([]const u8),
    fl: Filelists,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CompilationDatabase {
        return CompilationDatabase{
            .cache = std.StringHashMap([]const u8).init(allocator),
            .fl = Filelists.init(allocator),
            .allocator = allocator,
        };
    }

    fn getCommandForFilename(self: *CompilationDatabase, filename: []const u8, compile_file_path: []const u8) ![]const u8 {
        if (self.cache.count() == 0) {
            const compile_file = try std.fs.openFileAbsolute(compile_file_path, .{ .mode = .read_only });
            defer compile_file.close();
            const stat = try compile_file.stat();
            const contents = try compile_file.readToEndAlloc(self.allocator, stat.size);
            var token_stream = std.json.TokenStream.init(contents);

            const parse_options = std.json.ParseOptions{ .allocator = self.allocator, .ignore_unknown_fields = true };
            const items = try std.json.parse([]Swiftc, &token_stream, parse_options);
            errdefer std.json.parseFree([]Swiftc, items, .{});

            for (items) |item| {
                const command = item.command;
                if (command.len == 0) continue;
                var files = item.files;
                for (files) |file| {
                    var realpath = try std.fs.realpathAlloc(self.allocator, file);
                    const path = try trans2Lowercase(realpath);
                    try self.cache.put(path, command);
                }
                files = try self.fl.get_files(item.fileLists);
                for (files) |file| {
                    const path = try trans2Lowercase(file);
                    try self.cache.put(path, command);
                }
            }
        }
        const name = try trans2Lowercase(filename);
        return self.cache.get(name) orelse "";
    }

    fn filterFlags(self: *CompilationDatabase, flags: []const []const u8) ![]const []const u8 {
        var ret = std.ArrayList([]const u8).init(self.allocator);
        var i: usize = 0;
        while (i < flags.len) {
            const flag = flags[i];
            i += 1;
            if (std.mem.eql(u8, flag, "-use-frontend-parseable-output")) continue;
            if (std.mem.eql(u8, flag, "-filelist")) {
                _ = try self.fl.get_files(&[_][]const u8{flags[i]});
                i += 1;
                continue;
            }
            try ret.append(flag);
        }
        return try ret.toOwnedSlice();
    }

    fn getFlagsForFilename(self: *CompilationDatabase, filename: []const u8, compile_file_path: []const u8) ![]const []const u8 {
        if (compile_file_path.len == 0) return &[_][]const u8{};
        const command = try self.getCommandForFilename(filename, compile_file_path);
        if (command.len == 0) return &[_][]const u8{};
        const flags = (try shlx.split(command))[1..];
        return try self.filterFlags(flags);
    }

    pub fn getFlags(self: *CompilationDatabase, filename: []const u8, compile_file_path: []const u8) !struct { flags: []const []const u8, do_cache: bool } {
        const flags = try self.getFlagsForFilename(filename, compile_file_path);
        return .{ .flags = flags, .do_cache = true };
    }
};

test "get flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var db = CompilationDatabase.init(arena.allocator());
    const ret = try db.getFlags("/Users/miloas/Desktop/final input/final input/ContentView.swift", "/Users/miloas/Desktop/final input/.compile");
    // std.debug.print("len: {d}\n", .{ret.flags.len});
    // for (ret.flags) |f| {
    //     std.debug.print("flag: {s}\n", .{f});
    // }
    try std.testing.expect(ret.flags.len > 0);
}
