const std = @import("std");
const URI = @import("uri.zig");
const cdb = @import("compile_database.zig");
const BuildServerConfig = @import("config.zig").BuildServerConfig;

const BuildClientCapabilities = struct {
    languageIds: []const []const u8,
};

const InitializeBuildParams = struct {
    displayName: []const u8,
    version: []const u8,
    bspVersion: []const u8,
    rootUri: []const u8,
    capabilities: BuildClientCapabilities,

    data: std.json.Value = .Null,
};

const InitializeBuildRequestMessage = struct {
    jsonrpc: []const u8,
    id: u32,
    method: []const u8,
    params: InitializeBuildParams,
};

const InitializeBuildResult = struct { displayName: []const u8, version: []const u8, bspVersion: []const u8, rootUri: []const u8, capabilities: BuildClientCapabilities, data: struct {
    indexDatabasePath: []const u8,
    indexStorePath: []const u8,
} };

const RegisterForChangesRequestMessage = struct {
    jsonrpc: []const u8,
    id: u32,
    method: []const u8,
    params: struct { uri: []const u8, action: []const u8 },
};

fn expandUser(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return null;
    }
    var t = path;
    if (t[0] == '~') {
        t = t[2..];
    }
    const home_dir = std.os.getenv("HOME") orelse "";
    return std.fs.path.join(allocator, &[_][]const u8{ home_dir, t }) catch null;
}

// test "expandUser" {
//     const path1 = "/123";
//     const a1 = expandUser(std.testing.allocator, path1) orelse path1;
//     try std.testing.expectEqualSlices(u8, "/123", a1);
//
//     const path2 = "~/123";
//     const a2 = expandUser(std.testing.allocator, path2) orelse path2;
//     defer std.testing.allocator.free(a2);
//     try std.testing.expectEqualSlices(u8, "/Users/miloas/123", a2);
//
//     const path3 = "123";
//     const a3 = expandUser(std.testing.allocator, path3) orelse path3;
//     defer std.testing.allocator.free(a3);
//     try std.testing.expectEqualSlices(u8, "/Users/miloas/123", a3);
// }

fn send(msg: []const u8) !void {
    var stdout = std.io.getStdOut().writer();
    var buffered_writer = std.io.bufferedWriter(stdout);
    const stdout_writer = buffered_writer.writer();
    try stdout_writer.print("Content-Length: {d}\r\n\r\n", .{msg.len});
    try stdout_writer.writeAll(msg);
    try buffered_writer.flush();
}

const BuildServer = struct {
    const method_map = .{.{ "build/initialize", initializeHandler }};

    allocator: std.mem.Allocator,
    compile_path: []const u8,
    db: cdb.CompilationDatabase,

    fn init(allocator: std.mem.Allocator) !BuildServer {
        return BuildServer{
            .allocator = allocator,
            .compile_path = "",
            .db = cdb.CompilationDatabase.init(allocator),
        };
    }

    fn initializeHandler(self: *BuildServer, request_message: InitializeBuildRequestMessage) !void {
        const root_uri = request_message.params.rootUri;

        var cache_path_suffix = self.allocator.alloc(u8, root_uri.len) catch unreachable;
        defer self.allocator.free(cache_path_suffix);
        const cache_dir = expandUser(self.allocator, "~/Library/Caches/xbs") orelse "";
        defer self.allocator.free(cache_dir);
        _ = std.mem.replace(u8, root_uri, "/", "-", cache_path_suffix);
        _ = std.mem.replace(u8, cache_path_suffix, "%", "X", cache_path_suffix);
        const cache_path = try std.fs.path.join(self.allocator, &[_][]const u8{ cache_dir, cache_path_suffix });
        defer self.allocator.free(cache_path);

        const root_path = try URI.parse(self.allocator, root_uri);
        defer self.allocator.free(root_path);
        const compile_path = try std.fs.path.join(self.allocator, &[_][]const u8{ root_path, ".compile" });
        defer self.allocator.free(compile_path);

        var exists = true;
        std.fs.accessAbsolute(compile_path, .{}) catch {
            exists = false;
        };
        if (exists and self.compile_path.len == 0) {
            self.compile_path = compile_path;
        }
        const config_path = try std.fs.path.join(self.allocator, &[_][]const u8{ root_path, "buildServer.json" });
        defer self.allocator.free(config_path);
        var index_store_path: []u8 = "";
        exists = true;
        std.fs.accessAbsolute(config_path, .{}) catch {
            exists = false;
        };
        if (exists) {
            const config_file = try std.fs.openFileAbsolute(config_path, .{ .mode = .read_only });
            defer config_file.close();
            const stat = try config_file.stat();
            const contents = try config_file.readToEndAlloc(self.allocator, stat.size);
            defer self.allocator.free(contents);
            var token_stream = std.json.TokenStream.init(contents);
            const parse_options = std.json.ParseOptions{ .allocator = self.allocator, .ignore_unknown_fields = true };
            var config = try std.json.parse(BuildServerConfig, &token_stream, parse_options);
            defer std.json.parseFree(BuildServerConfig, config, parse_options);
            index_store_path = try self.allocator.alloc(u8, config.indexStorePath.len);
            std.mem.copy(u8, index_store_path, config.indexStorePath);
        }
        if (index_store_path.len == 0) {
            index_store_path = try std.fs.path.join(self.allocator, &[_][]const u8{ cache_path, "indexStorePath" });
        }

        defer self.allocator.free(index_store_path);

        const index_database_path = try std.fs.path.join(self.allocator, &[_][]const u8{ cache_path, "indexDatabasePath" });
        defer self.allocator.free(index_database_path);

        var buffer = std.ArrayListUnmanaged(u8){};
        var writer = buffer.writer(self.allocator);
        try writer.writeAll(
            \\{"jsonrpc":"2.0",
        );
        try writer.print(
            \\"id":{d},
        , .{request_message.id});
        try writer.writeAll(
            \\"result":{
        );
        try writer.writeAll(
            \\"displayName":"xbs",
            \\"version":"0.1",
            \\"bspVersion":"2.0",
        );
        try writer.print(
            \\"rootUri":"{s}",
        , .{root_uri});
        try writer.writeAll(
            \\"capabilities":{
            \\"languageIds":["c","cpp","objective-c","objective-cpp","swift"]
            \\},
            \\"data":{
        );
        try writer.print(
            \\"indexDatabasePath":"{s}",
        , .{index_database_path});
        try writer.print(
            \\"indexStorePath":"{s}"
        , .{index_store_path});
        try writer.writeAll(
            \\}}}
        );

        const message = try buffer.toOwnedSlice(self.allocator);
        defer self.allocator.free(message);
        try send(message);
    }

    fn registerForChangesHandler(self: *BuildServer, request_message: RegisterForChangesRequestMessage) !void {
        var buffer = std.ArrayListUnmanaged(u8){};
        var writer = buffer.writer(self.allocator);
        try writer.writeAll(
            \\{"jsonrpc":"2.0",
        );
        try writer.print("id:{d},", .{request_message.id});
        try writer.writeAll(
            \\"result":null}
        );

        const response_msg = try buffer.toOwnedSlice(self.allocator);
        defer self.allocator.free(response_msg);
        try send(response_msg);

        if (std.mem.eql(u8, request_message.params.action, "register")) {
            const uri = request_message.params.uri;
            try writer.writeAll(
                \\{"jsonrpc":"2.0",
            );
            try writer.writeAll(
                \\"method":"build/sourceKitOptionsChanged",
            );
            try writer.writeAll(
                \\"params":{
            );
            try writer.print(
                \\"uri":"{s}",
            , .{uri});

            const update_options = try self.optionsForFile(uri);
            try writer.writeAll(
                \\"updateOptons":{
            );
            try writer.writeAll(
                \\"options":[
            );
            if (update_options.options.len > 0) {
                try writer.print(
                    \\"{s}"
                , .{update_options.options[0]});
            }
            if (update_options.options.len > 1) {
                for (update_options.options[1..]) |option| {
                    try writer.print(
                        \\",{s}"
                    , .{option});
                }
            }
            try writer.writeAll(
                \\],
            );
            try writer.print(
                \\"workingDirectory":"{s}"
            , .{update_options.working_directory});
            try writer.writeAll(
                \\}}
            );
            const notification_msg = try buffer.toOwnedSlice(self.allocator);
            defer self.allocator.free(notification_msg);
            try send(notification_msg);
        }
    }

    fn optionsForFile(self: *BuildServer, uri: []const u8) !struct { options: []const []const u8, working_directory: []const u8 } {
        self.compile_path = "/Users/miloas/Desktop/final input/.compile";
        const file_path = try URI.parse(self.allocator, uri);
        defer self.allocator.free(file_path);
        const flags = (try self.db.getFlags(file_path, self.compile_path)).flags;
        var workdir: []const u8 = "";
        for (flags, 0..) |flag, i| {
            if (std.mem.eql(u8, flag, "-working-directory")) {
                workdir = flags[i + 1];
                break;
            }
        }
        if (workdir.len == 0) {
            var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            workdir = try std.os.getcwd(&cwd_buf);
        }
        return .{
            .options = flags,
            .working_directory = workdir,
        };
    }
};

// test "build server register for changes handler" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     var server = try BuildServer.init(arena.allocator());
//     const request_msg = RegisterForChangesRequestMessage{
//         .jsonrpc = "2.0",
//         .id = 1,
//         .method = "build/registerForChanges",
//         .params = .{
//             .action = "register",
//             .uri = "file:///Users/miloas/Desktop/final input/final input/ContentView.swift",
//         },
//     };
//     try server.registerForChangesHandler(request_msg);
// }

// test "build server init handler" {
//     var server = try BuildServer.init(std.testing.allocator);
//     const request_msg = InitializeBuildRequestMessage{
//         .jsonrpc = "2.0",
//         .id = 1,
//         .method = "build/initialize",
//         .params = InitializeBuildParams{
//             .displayName = "xbs",
//             .version = "0.1",
//             .bspVersion = "2.0",
//             .capabilities = .{
//                 .languageIds = &[_][]const u8{ "c", "cpp", "objective-c", "objective-cpp", "swift" },
//             },
//             .rootUri = "file:///Users/miloas/Desktop/final input",
//         },
//     };
//     try server.initializeHandler(request_msg);
// }
