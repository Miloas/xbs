const std = @import("std");

const Tokenizer = struct {
    const TokenType = enum {
        null,
        string,
        integer,
        double,
        array,
        class,
        instance,
    };

    input_stream: std.io.FixedBufferStream([]const u8),

    fn init(content: []const u8) !Tokenizer {
        var stream = std.io.fixedBufferStream(content);
        const reader = stream.reader();
        const head = try reader.readBytesNoEof(4);
        if (!std.mem.eql(u8, &head, "SLF0")) {
            return error.InvalidXcactivitylog;
        }
        return Tokenizer{ .input_stream = stream };
    }

    fn scanStream(self: *Tokenizer) !struct { TokenType, []const u8 } {
        const reader = self.input_stream.reader();
        var buffer: [1024]u8 = undefined;
        var index: usize = 0;
        while (reader.readByte()) |x| {
            switch (x) {
                '-' => {
                    index = 0;
                    return .{ .null, undefined };
                },
                '#' => {
                    var ret = .{ .integer, buffer[0..index] };
                    index = 0;
                    return ret;
                },
                '^' => {
                    var ret = .{ .double, buffer[0..index] };
                    index = 0;
                    return ret;
                },
                '(' => {
                    var ret = .{ .array, buffer[0..index] };
                    index = 0;
                    return ret;
                },
                '%' => {
                    const len = try std.fmt.parseUnsigned(u64, buffer[0..index], 10);
                    index = 0;
                    var v = try std.heap.c_allocator.alloc(u8, len);
                    _ = try reader.readAtLeast(v, len);
                    return .{ .class, v };
                },
                '"' => {
                    const len = try std.fmt.parseUnsigned(u64, buffer[0..index], 10);
                    index = 0;
                    var v = try std.heap.c_allocator.alloc(u8, len);
                    _ = try reader.readAtLeast(v, len);
                    return .{ .string, v };
                },
                '@' => {
                    var ret = .{ .instance, buffer[0..index] };
                    index = 0;
                    return ret;
                },
                else => {
                    buffer[index] = x;
                    index += 1;
                },
            }
        } else |_| {
            return error.InvalidXcactivitylog;
        }
    }
};

pub fn tokenize(content: []const u8) ![][]const u8 {
    var tokenizer = try Tokenizer.init(content);
    var tokens = std.ArrayList([]const u8).init(std.heap.c_allocator);
    while (try tokenizer.scanStream()) |token| {
        const tokenType = token[0];
        const value = token[1];

        if (tokenType != .string) continue;
        if (!std.mem.startsWith(u8, value, "CompileSwiftSources ")) continue;
        if (!std.mem.startsWith(u8, value, "SwiftDrive\\ Compilation ")) continue;
        if (!std.mem.startsWith(u8, value, "CompileC ")) continue;
        if (!std.mem.startsWith(u8, value, "ProcessPCH ")) continue;

        tokens.append(value);
    }
    return tokens;
}

pub fn extract_compile_log(content: []const u8) ![][]const u8 {
    var tokenizer = try Tokenizer.init(content);
    var logs = std.ArrayList([]const u8).init(std.heap.c_allocator);
    while (true) {
        const token = tokenizer.scanStream() catch {
            break;
        };
        const tokenType = token[0];
        const value = token[1];

        if (tokenType != .string) continue;

        if (std.mem.startsWith(u8, value, "CompileSwiftSources ") or
            std.mem.startsWith(u8, value, "SwiftDriver\\ Compilation ") or
            std.mem.startsWith(u8, value, "CompileC ") or
            std.mem.startsWith(u8, value, "ProcessPCH "))
        {
            // std.debug.print("type: {}\n", .{tokenType});
            // std.debug.print("value: {s}\n", .{value});
            try logs.append(value);
        }
    }
    return try logs.toOwnedSlice();
}

test "SLF tokenization" {
    const content =
        \\SLF010#21%IDEActivityLogSection1@0#39"Xcode.IDEActivityLogDomainType.BuildLog20"Build XCLogParserApp20"Build XCLogParserApp0074f8eaae48c141^8f19bcf4ae48c141^12(1@1#50"Xcode.IDEActivityLogDomainType.XCBuild.Preparation13"Prepare build13"Prepare build
    ;
    var tokenizer = try Tokenizer.init(content);
    var t = try tokenizer.scanStream();
    try std.testing.expectEqual(t[0], .integer);
    var v = try std.fmt.parseUnsigned(u64, t[1], 10);
    try std.testing.expectEqual(v, 10);
    t = try tokenizer.scanStream();
    try std.testing.expectEqual(t[0], .class);
    try std.testing.expectEqualSlices(u8, t[1], "IDEActivityLogSection");
    t = try tokenizer.scanStream();
    try std.testing.expectEqual(t[0], .instance);
    v = try std.fmt.parseUnsigned(u64, t[1], 10);
    try std.testing.expectEqual(v, 1);
    t = try tokenizer.scanStream();
    try std.testing.expectEqual(t[0], .integer);
    v = try std.fmt.parseUnsigned(u64, t[1], 10);
    try std.testing.expectEqual(v, 0);
    t = try tokenizer.scanStream();
    try std.testing.expectEqual(t[0], .string);
    try std.testing.expectEqualSlices(u8, t[1], "Xcode.IDEActivityLogDomainType.BuildLog");
    t = try tokenizer.scanStream();
    try std.testing.expectEqual(t[0], .string);
    try std.testing.expectEqualSlices(u8, t[1], "Build XCLogParserApp");
    t = try tokenizer.scanStream();
    try std.testing.expectEqual(t[0], .string);
    try std.testing.expectEqualSlices(u8, t[1], "Build XCLogParserApp");
    t = try tokenizer.scanStream();
    try std.testing.expectEqual(t[0], .double);
    try std.testing.expectEqualSlices(u8, t[1], "0074f8eaae48c141");
    t = try tokenizer.scanStream();
    try std.testing.expectEqual(t[0], .double);
    try std.testing.expectEqualSlices(u8, t[1], "8f19bcf4ae48c141");
    t = try tokenizer.scanStream();
    try std.testing.expectEqual(t[0], .array);
    v = try std.fmt.parseUnsigned(u64, t[1], 10);
    try std.testing.expectEqual(v, 12);
}
