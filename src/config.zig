const std = @import("std");

pub fn dumpServerConfig(index_store_path: []const u8) !void {
    const build_server_config = try std.fs.openFileAbsolute("build-server-config.json", .{ .mode = .write_only });
    try std.json.stringify(.{
        .name = "xbs",
        .version = "0.1",
        .bspVersion = "2.0",
        .languages = .{ "c", "cpp", "objective-c", "objective-cpp", "swift" },
        .argv = std.os.argv[0],
        .indexStorePath = index_store_path,
    }, .{ .whitespace = .{ .indent = .Tab } }, build_server_config.writer());
}
