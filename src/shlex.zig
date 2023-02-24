const std = @import("std");

pub const Tokenizer = struct {
    const ReadError = std.io.FixedBufferStream([]u8).ReadError;
    const Reader = std.io.FixedBufferStream([]u8).Reader;

    const Token = struct { token_type: TokenType, value: []u8 };

    const State = enum {
        start_state,
        in_word_state,
        escaping_state,
        escaping_quoted_state,
        quoting_escaping_state,
        quoting_state,
        comment_state,
    };

    const TokenType = enum {
        unknown_token,
        word_token,
        space_token,
        comment_token,
    };

    const RuneTokenClass = enum {
        unknown_rune_class,
        space_rune_class,
        escaping_quote_rune_class,
        non_escaping_quote_rune_class,
        escaping_rune_class,
        comment_rune_class,
        eof_rune_class,
    };

    const token_classifier = std.ComptimeStringMap(RuneTokenClass, .{
        .{ " ", RuneTokenClass.space_rune_class },
        .{ "\t", RuneTokenClass.space_rune_class },
        .{ "\r", RuneTokenClass.space_rune_class },
        .{ "\n", RuneTokenClass.space_rune_class },
        .{ "\"", RuneTokenClass.escaping_quote_rune_class },
        .{ "\'", RuneTokenClass.non_escaping_quote_rune_class },
        .{ "\\", RuneTokenClass.escaping_rune_class },
        .{ "#", RuneTokenClass.comment_rune_class },
    });

    buffer: []const u8,
    index: usize,

    fn init(s: []const u8) Tokenizer {
        return Tokenizer{
            .buffer = s,
            .index = 0,
        };
    }

    fn classifyRune(rune: u8) RuneTokenClass {
        return token_classifier.get(&[_]u8{rune}) orelse RuneTokenClass.unknown_rune_class;
    }

    fn scanStream(self: *Tokenizer) !Token {
        var state = State.start_state;
        var token_type: TokenType = undefined;
        var value = std.ArrayList(u8).init(std.heap.c_allocator);
        var next_rune: u8 = undefined;
        var next_rune_type: RuneTokenClass = undefined;

        while (true) : (self.index += 1) {
            if (self.index == self.buffer.len) {
                next_rune_type = RuneTokenClass.eof_rune_class;
            } else {
                next_rune = self.buffer[self.index];
                next_rune_type = classifyRune(next_rune);
            }
            switch (state) {
                .start_state => switch (next_rune_type) {
                    .eof_rune_class => return error.EndOfStream,
                    .space_rune_class => {},
                    .escaping_quote_rune_class => {
                        state = .quoting_escaping_state;
                        token_type = .word_token;
                    },
                    .non_escaping_quote_rune_class => {
                        state = .quoting_state;
                        token_type = .word_token;
                    },
                    .escaping_rune_class => {
                        state = .escaping_state;
                        token_type = .word_token;
                    },
                    .comment_rune_class => {
                        state = .comment_state;
                        token_type = .comment_token;
                    },
                    else => {
                        state = .in_word_state;
                        token_type = .word_token;
                        try value.append(next_rune);
                    },
                },
                .in_word_state => switch (next_rune_type) {
                    .eof_rune_class => {
                        return Token{ .token_type = token_type, .value = try value.toOwnedSlice() };
                    },
                    .space_rune_class => {
                        return Token{ .token_type = token_type, .value = try value.toOwnedSlice() };
                    },
                    .escaping_quote_rune_class => {
                        state = .quoting_escaping_state;
                    },
                    .non_escaping_quote_rune_class => {
                        state = .quoting_state;
                    },
                    .escaping_rune_class => {
                        state = .escaping_state;
                    },
                    else => {
                        try value.append(next_rune);
                    },
                },
                .escaping_state => switch (next_rune_type) {
                    .eof_rune_class => {
                        return error.EndOfStream;
                    },
                    else => {
                        try value.append(next_rune);
                        state = .in_word_state;
                    },
                },
                .escaping_quoted_state => switch (next_rune_type) {
                    .eof_rune_class => {
                        return error.EndOfStream;
                    },
                    else => {
                        try value.append(next_rune);
                        state = .quoting_escaping_state;
                    },
                },
                .quoting_escaping_state => switch (next_rune_type) {
                    .eof_rune_class => {
                        return error.EndOfStream;
                    },
                    .escaping_quote_rune_class => {
                        state = .in_word_state;
                    },
                    .escaping_rune_class => {
                        state = .escaping_quoted_state;
                    },
                    else => {
                        try value.append(next_rune);
                    },
                },
                .quoting_state => switch (next_rune_type) {
                    .eof_rune_class => {
                        return error.EndOfStream;
                    },
                    .non_escaping_quote_rune_class => {
                        state = .in_word_state;
                    },
                    else => {
                        try value.append(next_rune);
                    },
                },
                .comment_state => switch (next_rune_type) {
                    .eof_rune_class => {
                        return error.EndOfStream;
                    },
                    .space_rune_class => {
                        if (next_rune == '\n') {
                            state = .start_state;
                            return .{ .token_type = token_type, .value = try value.toOwnedSlice() };
                        } else {
                            try value.append(next_rune);
                        }
                    },
                    else => {
                        try value.append(next_rune);
                    },
                },
            }
        }
    }

    pub fn next(self: *Tokenizer) !Token {
        return self.scanStream();
    }
};

pub fn split(s: []const u8) ![][]u8 {
    var tokenizer = Tokenizer.init(s);
    var tokens = std.ArrayList([]u8).init(std.heap.c_allocator);
    while (true) {
        const token = tokenizer.next() catch |err| {
            switch (err) {
                error.EndOfStream => return tokens.toOwnedSlice(),
                else => unreachable,
            }
        };
        try tokens.append(token.value);
    }
}

test "split" {
    var input = "one two \"three four\" \"five \\\"six\\\"\" seven#eight # nine # ten\n eleven 'twelve\\' thirteen=13 fourteen/14";
    var xs = try split(input);
    try std.testing.expectEqualSlices(u8, xs[0], "one");
    try std.testing.expectEqualSlices(u8, xs[1], "two");
    try std.testing.expectEqualSlices(u8, xs[2], "three four");
    try std.testing.expectEqualSlices(u8, xs[3], "five \"six\"");
    try std.testing.expectEqualSlices(u8, xs[4], "seven#eight");
    try std.testing.expectEqualSlices(u8, xs[5], " nine # ten");
    try std.testing.expectEqualSlices(u8, xs[6], "eleven");
    try std.testing.expectEqualSlices(u8, xs[7], "twelve\\");
    try std.testing.expectEqualSlices(u8, xs[8], "thirteen=13");
    try std.testing.expectEqualSlices(u8, xs[9], "fourteen/14");
}
