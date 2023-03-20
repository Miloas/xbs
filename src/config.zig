const std = @import("std");

pub const BuildServerConfig = struct {
    name: []const u8,
    version: []const u8,
    bspVersion: []const u8,
    languages: []const []const u8,
    argv: []const []const u8,
    indexStorePath: []const u8,
};

pub fn dumpServerConfig(index_store_path: []const u8) !void {
    const build_server_config = try std.fs.openFileAbsolute("buildServer.json", .{ .mode = .write_only });
    try std.json.stringify(.{
        .name = "xbs",
        .version = "0.1",
        .bspVersion = "2.0",
        .languages = .{ "c", "cpp", "objective-c", "objective-cpp", "swift" },
        .argv = std.os.argv[0],
        .indexStorePath = index_store_path,
    }, .{ .whitespace = .{ .indent = .Tab } }, build_server_config.writer());
}
