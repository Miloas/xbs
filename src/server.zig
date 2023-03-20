const std = @import("std");
const URI = @import("uri.zig");
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

const BuildServer = struct {
    const method_map = .{.{ "build/initialize", initializeHandler }};

    allocator: std.mem.Allocator,
    compile_path: []const u8,

    fn init(allocator: std.mem.Allocator) !BuildServer {
        return BuildServer{
            .allocator = allocator,
            .compile_path = "",
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

        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll(
            \\{"jsonrpc":"2.0",
        );
        try stdout.print(
            \\"id":{d},
        , .{request_message.id});
        try stdout.writeAll(
            \\"result":{
        );
        try stdout.writeAll(
            \\"displayName":"xbs",
            \\"version":"0.1",
            \\"bspVersion":"2.0",
        );
        try stdout.print(
            \\"rootUri":"{s}",
        , .{root_uri});
        try stdout.writeAll(
            \\"capabilities":{
            \\"languageIds":["c","cpp","objective-c","objective-cpp","swift"]
            \\},
            \\"data":{
        );
        try stdout.print(
            \\"indexDatabasePath":"{s}",
        , .{index_database_path});
        try stdout.print(
            \\"indexStorePath":"{s}"
        , .{index_store_path});
        try stdout.writeAll(
            \\}}}
        );
    }
};

// test "build server init" {
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
