const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.parse);
const mem = std.mem;
const testing = std.testing;

const Allocator = mem.Allocator;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const TokenIndex = Tokenizer.TokenIndex;
const TokenIterator = Tokenizer.TokenIterator;

pub const ParseError = error{
    MalformedYaml,
    NestedDocuments,
    UnexpectedEof,
    UnexpectedToken,
    Unhandled,
} || Allocator.Error;

pub const Node = struct {
    tag: Tag,
    tree: *const Tree,
    start: TokenIndex,
    end: TokenIndex,

    pub const Tag = enum {
        doc,
        map,
        list,
        value,
    };

    pub fn cast(self: *const Node, comptime T: type) ?*const T {
        if (self.tag != T.base_tag) {
            return null;
        }
        return @fieldParentPtr(T, "base", self);
    }

    pub fn deinit(self: *Node, allocator: Allocator) void {
        switch (self.tag) {
            .doc => @fieldParentPtr(Node.Doc, "base", self).deinit(allocator),
            .map => @fieldParentPtr(Node.Map, "base", self).deinit(allocator),
            .list => @fieldParentPtr(Node.List, "base", self).deinit(allocator),
            .value => @fieldParentPtr(Node.Value, "base", self).deinit(allocator),
        }
    }

    pub fn format(
        self: *const Node,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        return switch (self.tag) {
            .doc => @fieldParentPtr(Node.Doc, "base", self).format(fmt, options, writer),
            .map => @fieldParentPtr(Node.Map, "base", self).format(fmt, options, writer),
            .list => @fieldParentPtr(Node.List, "base", self).format(fmt, options, writer),
            .value => @fieldParentPtr(Node.Value, "base", self).format(fmt, options, writer),
        };
    }

    pub const Doc = struct {
        base: Node = Node{
            .tag = Tag.doc,
            .tree = undefined,
            .start = undefined,
            .end = undefined,
        },
        directive: ?TokenIndex = null,
        value: ?*Node = null,

        pub const base_tag: Node.Tag = .doc;

        pub fn deinit(self: *Doc, allocator: Allocator) void {
            if (self.value) |node| {
                node.deinit(allocator);
                allocator.destroy(node);
            }
        }

        pub fn format(
            self: *const Doc,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            if (self.directive) |id| {
                try std.fmt.format(writer, "{{ ", .{});
                const directive = self.base.tree.getRaw(id, id + 1);
                try std.fmt.format(writer, ".directive = {s}, ", .{directive});
            }
            if (self.value) |node| {
                try std.fmt.format(writer, "{}", .{node});
            }
            if (self.directive != null) {
                try std.fmt.format(writer, " }}", .{});
            }
        }
    };

    pub const Map = struct {
        base: Node = Node{
            .tag = Tag.map,
            .tree = undefined,
            .start = undefined,
            .end = undefined,
        },
        values: std.ArrayListUnmanaged(Entry) = .{},

        pub const base_tag: Node.Tag = .map;

        pub const Entry = struct {
            key: TokenIndex,
            value: *Node,
        };

        pub fn deinit(self: *Map, allocator: Allocator) void {
            for (self.values.items) |entry| {
                entry.value.deinit(allocator);
                allocator.destroy(entry.value);
            }
            self.values.deinit(allocator);
        }

        pub fn format(
            self: *const Map,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            try std.fmt.format(writer, "{{ ", .{});
            for (self.values.items) |entry| {
                const key = self.base.tree.getRaw(entry.key, entry.key + 1);
                try std.fmt.format(writer, "{s} => {}, ", .{ key, entry.value });
            }
            return std.fmt.format(writer, " }}", .{});
        }
    };

    pub const List = struct {
        base: Node = Node{
            .tag = Tag.list,
            .tree = undefined,
            .start = undefined,
            .end = undefined,
        },
        values: std.ArrayListUnmanaged(*Node) = .{},

        pub const base_tag: Node.Tag = .list;

        pub fn deinit(self: *List, allocator: Allocator) void {
            for (self.values.items) |node| {
                node.deinit(allocator);
                allocator.destroy(node);
            }
            self.values.deinit(allocator);
        }

        pub fn format(
            self: *const List,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            try std.fmt.format(writer, "[ ", .{});
            for (self.values.items) |node| {
                try std.fmt.format(writer, "{}, ", .{node});
            }
            return std.fmt.format(writer, " ]", .{});
        }
    };

    pub const Value = struct {
        base: Node = Node{
            .tag = Tag.value,
            .tree = undefined,
            .start = undefined,
            .end = undefined,
        },
        string_value: std.ArrayListUnmanaged(u8) = .{},

        pub const base_tag: Node.Tag = .value;

        pub fn deinit(self: *Value, allocator: Allocator) void {
            self.string_value.deinit(allocator);
        }

        pub fn format(
            self: *const Value,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            const raw = self.tree.getRaw(self.base.start, self.base.end);
            return std.fmt.format(writer, "{s}", .{raw});
        }
    };
};

pub const LineCol = struct {
    line: usize,
    col: usize,
};

pub const Tree = struct {
    allocator: Allocator,
    source: []const u8,
    tokens: []Token,
    line_cols: std.AutoHashMap(TokenIndex, LineCol),
    docs: std.ArrayListUnmanaged(*Node) = .{},

    pub fn init(allocator: Allocator) Tree {
        return .{
            .allocator = allocator,
            .source = undefined,
            .tokens = undefined,
            .line_cols = std.AutoHashMap(TokenIndex, LineCol).init(allocator),
        };
    }

    pub fn deinit(self: *Tree) void {
        self.allocator.free(self.tokens);
        self.line_cols.deinit();
        for (self.docs.items) |doc| {
            doc.deinit(self.allocator);
            self.allocator.destroy(doc);
        }
        self.docs.deinit(self.allocator);
    }

    pub fn getRaw(self: Tree, start: TokenIndex, end: TokenIndex) []const u8 {
        assert(start <= end);
        assert(start < self.tokens.len and end < self.tokens.len);
        const start_token = self.tokens[start];
        const end_token = self.tokens[end];
        return self.source[start_token.start..end_token.end];
    }

    pub fn parse(self: *Tree, source: []const u8) !void {
        var tokenizer = Tokenizer{ .buffer = source };
        var tokens = std.ArrayList(Token).init(self.allocator);
        defer tokens.deinit();

        var line: usize = 0;
        var prev_line_last_col: usize = 0;

        while (true) {
            const token = tokenizer.next();
            const tok_id = tokens.items.len;
            try tokens.append(token);

            try self.line_cols.putNoClobber(tok_id, .{
                .line = line,
                .col = token.start - prev_line_last_col,
            });

            switch (token.id) {
                .eof => break,
                .new_line => {
                    line += 1;
                    prev_line_last_col = token.end;
                },
                else => {},
            }
        }

        self.source = source;
        self.tokens = tokens.toOwnedSlice();

        var it = TokenIterator{ .buffer = self.tokens };
        var parser = Parser{
            .allocator = self.allocator,
            .tree = self,
            .token_it = &it,
            .line_cols = &self.line_cols,
        };

        parser.eatCommentsAndSpace(&.{});

        while (parser.token_it.next()) |token| {
            log.warn("(main) next {s}@{d}", .{ @tagName(token.id), parser.token_it.pos - 1 });
            switch (token.id) {
                .eof => break,
                else => {
                    parser.token_it.seekBy(-1);
                    const doc = try parser.doc();
                    try self.docs.append(self.allocator, &doc.base);
                },
            }
        }
    }
};

const Parser = struct {
    allocator: Allocator,
    tree: *Tree,
    token_it: *TokenIterator,
    line_cols: *const std.AutoHashMap(TokenIndex, LineCol),

    fn doc(self: *Parser) ParseError!*Node.Doc {
        const node = try self.allocator.create(Node.Doc);
        errdefer self.allocator.destroy(node);
        node.* = .{};
        node.base.tree = self.tree;
        node.base.start = self.token_it.pos;

        log.warn("(doc) begin {s}@{d}", .{ @tagName(self.tree.tokens[node.base.start].id), node.base.start });

        // Parse header
        const explicit_doc: bool = if (self.eatToken(.doc_start, &.{})) |_| explicit_doc: {
            if (self.eatToken(.tag, &.{ .new_line, .comment })) |_| {
                node.directive = try self.expectToken(.literal, &.{ .new_line, .comment });
            }
            break :explicit_doc true;
        } else false;

        // Parse value
        self.eatCommentsAndSpace(&.{});
        const pos = self.token_it.pos;
        const token = self.token_it.next() orelse return error.UnexpectedEof;

        log.warn("(doc) next {s}@{d}", .{ @tagName(token.id), pos });

        switch (token.id) {
            .literal => if (self.eatToken(.map_value_ind, &.{ .new_line, .comment })) |_| {
                // TODO
                return error.Unhandled;
            } else {
                // leaf value
                self.token_it.seekBy(-1);
                const leaf_node = try self.leaf_value();
                node.value = &leaf_node.base;
            },
            .single_quote, .double_quote => {
                // leaf value
                self.token_it.seekBy(-1);
                const leaf_node = try self.leaf_value();
                node.value = &leaf_node.base;
            },
            // .seq_item_ind => {
            //     const list_node = try self.list(pos);
            //     node.value = &list_node.base;
            // },
            // .flow_seq_start => {
            //     const list_node = try self.list_bracketed(pos);
            //     node.value = &list_node.base;
            // },
            else => {
                self.token_it.seekBy(-1);
            },
        }
        errdefer if (node.value) |value| {
            value.deinit(self.allocator);
            self.allocator.destroy(value);
        };

        // Parse footer
        self.eatCommentsAndSpace(&.{});

        if (self.token_it.next()) |tok| switch (tok.id) {
            .doc_start => if (explicit_doc) {
                self.token_it.seekBy(-1);
            } else return error.UnexpectedToken,
            .doc_end => if (!explicit_doc) return error.UnexpectedToken,
            .eof => {},
            else => return error.UnexpectedToken,
        } else return error.UnexpectedEof;

        node.base.end = self.token_it.pos - 1;

        log.warn("(doc) end {s}@{d}", .{ @tagName(self.tree.tokens[node.base.end].id), node.base.end });

        return node;
    }

    fn map(self: *Parser, start: TokenIndex) ParseError!*Node.Map {
        const node = try self.allocator.create(Node.Map);
        errdefer self.allocator.destroy(node);
        node.* = .{ .start = start };
        node.base.tree = self.tree;

        self.token_it.seekTo(start);

        const col = self.getCol(start);

        while (true) {
            // Parse key.
            const key_pos = self.token_it.pos;
            if (self.getCol(key_pos) != col) {
                break;
            }

            const key = self.token_it.next();
            switch (key.id) {
                .literal => {},
                else => {
                    self.token_it.seekBy(-1);
                    break;
                },
            }

            log.warn("key={s}", .{self.tree.source[key.start..key.end]});

            // Separator
            _ = try self.expectToken(.map_value_ind);
            self.eatCommentsAndSpace();

            log.warn("value=", .{});

            // Parse value.
            const value: *Node = value: {
                // Explicit, complex value such as list or map.
                const value_pos = self.token_it.pos;
                const value = self.token_it.next();
                switch (value.id) {
                    .literal, .single_quote, .double_quote => {
                        // Assume nested map.
                        const map_node = try self.map(value_pos);
                        break :value &map_node.base;
                    },
                    .seq_item_ind => {
                        // Assume list of values.
                        const list_node = try self.list(value_pos);
                        break :value &list_node.base;
                    },
                    .flow_seq_start => {
                        const list_node = try self.list_bracketed(value_pos);
                        break :value &list_node.base;
                    },
                    else => {
                        log.err("{}", .{key});
                        return error.Unhandled;
                    },
                }
            };

            try node.values.append(self.allocator, .{
                .key = key_pos,
                .value = value,
            });

            _ = self.eatToken(.new_line);
        }

        node.end = self.token_it.pos - 1;

        return node;
    }

    fn list(self: *Parser, start: TokenIndex) ParseError!*Node.List {
        const node = try self.allocator.create(Node.List);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .start = start,
        };
        node.base.tree = self.tree;

        self.token_it.seekTo(start);

        const col = self.getCol(start);

        while (true) {
            if (self.getCol(self.token_it.pos) != col) {
                break;
            }
            _ = self.eatToken(.seq_item_ind) orelse {
                break;
            };

            const pos = self.token_it.pos;
            const token = self.token_it.next();
            const value: *Node = value: {
                switch (token.id) {
                    .literal, .single_quote, .double_quote => {
                        if (self.eatToken(.map_value_ind)) |_| {
                            // nested map
                            const map_node = try self.map(pos);
                            break :value &map_node.base;
                        } else {
                            // standalone (leaf) value
                            const leaf_node = try self.leaf_value(pos);
                            break :value &leaf_node.base;
                        }
                    },
                    .flow_seq_start => {
                        const list_node = try self.list_bracketed(pos);
                        break :value &list_node.base;
                    },
                    else => {
                        log.err("{}", .{token});
                        return error.Unhandled;
                    },
                }
            };
            try node.values.append(self.allocator, value);

            _ = self.eatToken(.new_line);
        }

        node.end = self.token_it.pos - 1;

        return node;
    }

    fn list_bracketed(self: *Parser, start: TokenIndex) ParseError!*Node.List {
        const node = try self.allocator.create(Node.List);
        errdefer self.allocator.destroy(node);
        node.* = .{ .start = start };
        node.base.tree = self.tree;

        self.token_it.seekTo(start);

        log.warn("List start: {}, {}", .{ start, self.tree.tokens[start] });

        _ = try self.expectToken(.flow_seq_start);

        while (true) {
            _ = self.eatToken(.new_line);
            self.eatCommentsAndSpace();

            const pos = self.token_it.pos;
            const token = self.token_it.next();

            log.warn("Next token: {}, {}", .{ pos, token });

            const value: *Node = value: {
                switch (token.id) {
                    .flow_seq_start => {
                        const list_node = try self.list_bracketed(pos);
                        break :value &list_node.base;
                    },
                    .flow_seq_end => {
                        break;
                    },
                    .literal, .single_quote, .double_quote => {
                        const leaf_node = try self.leaf_value(pos);
                        _ = self.eatToken(.comma);
                        // TODO newline
                        break :value &leaf_node.base;
                    },
                    else => {
                        log.err("{}", .{token});
                        return error.Unhandled;
                    },
                }
            };
            try node.values.append(self.allocator, value);
        }

        node.end = self.token_it.pos - 1;

        log.warn("List end: {}, {}", .{ node.end.?, self.tree.tokens[node.end.?] });

        return node;
    }

    fn leaf_value(self: *Parser) ParseError!*Node.Value {
        const node = try self.allocator.create(Node.Value);
        errdefer self.allocator.destroy(node);
        node.* = .{ .string_value = .{} };
        errdefer node.string_value.deinit(self.allocator);
        node.base.tree = self.tree;
        node.base.start = self.token_it.pos;

        parse: {
            if (self.eatToken(.single_quote, &.{})) |_| {
                node.base.start = node.base.start + 1;
                while (self.token_it.next()) |tok| {
                    switch (tok.id) {
                        .single_quote => {
                            node.base.end = self.token_it.pos - 2;
                            break :parse;
                        },
                        .new_line => return error.UnexpectedToken,
                        .escape_seq => {
                            const ch = self.tree.source[tok.start + 1];
                            try node.string_value.append(self.allocator, ch);
                        },
                        else => {
                            const str = self.tree.source[tok.start..tok.end];
                            try node.string_value.appendSlice(self.allocator, str);
                        },
                    }
                }
            }

            if (self.eatToken(.double_quote, &.{})) |_| {
                node.base.start = node.base.start + 1;
                while (self.token_it.next()) |tok| {
                    switch (tok.id) {
                        .double_quote => {
                            node.base.end = self.token_it.pos - 2;
                            break :parse;
                        },
                        .new_line => return error.UnexpectedToken,
                        .escape_seq => {
                            switch (self.tree.source[tok.start + 1]) {
                                'n' => {
                                    try node.string_value.append(self.allocator, '\n');
                                },
                                't' => {
                                    try node.string_value.append(self.allocator, '\t');
                                },
                                '"' => {
                                    try node.string_value.append(self.allocator, '"');
                                },
                                else => {},
                            }
                        },
                        else => {
                            const str = self.tree.source[tok.start..tok.end];
                            try node.string_value.appendSlice(self.allocator, str);
                        },
                    }
                }
            }

            // TODO handle multiline strings in new block scope
            while (self.token_it.next()) |tok| {
                switch (tok.id) {
                    .literal => {},
                    .space => {
                        const trailing = self.token_it.pos - 2;
                        self.eatCommentsAndSpace(&.{});
                        if (self.token_it.peek()) |peek| {
                            if (peek.id != .literal) {
                                node.base.end = trailing;
                                const raw = self.tree.getRaw(node.base.start, node.base.end);
                                try node.string_value.appendSlice(self.allocator, raw);
                                break;
                            }
                        }
                    },
                    else => {
                        self.token_it.seekBy(-1);
                        node.base.end = self.token_it.pos - 1;
                        const raw = self.tree.getRaw(node.base.start, node.base.end);
                        try node.string_value.appendSlice(self.allocator, raw);
                        break;
                    },
                }
            }
        }

        log.warn("(leaf) {s}", .{self.tree.getRaw(node.base.start, node.base.end)});

        return node;
    }

    fn eatCommentsAndSpace(self: *Parser, comptime exclusions: []const Token.Id) void {
        log.warn("eatCommentsAndSpace", .{});
        outer: while (self.token_it.next()) |token| {
            log.warn("  (token '{s}')", .{@tagName(token.id)});
            switch (token.id) {
                .comment, .space, .new_line => |space| {
                    inline for (exclusions) |excl| {
                        if (excl == space) {
                            self.token_it.seekBy(-1);
                            break :outer;
                        }
                    } else continue;
                },
                else => {
                    self.token_it.seekBy(-1);
                    break;
                },
            }
        }
    }

    fn eatToken(self: *Parser, id: Token.Id, comptime exclusions: []const Token.Id) ?TokenIndex {
        log.warn("eatToken('{s}')", .{@tagName(id)});
        self.eatCommentsAndSpace(exclusions);
        const pos = self.token_it.pos;
        const token = self.token_it.next() orelse return null;
        if (token.id == id) {
            log.warn("  (found at {d})", .{pos});
            return pos;
        } else {
            log.warn("  (not found)", .{});
            self.token_it.seekBy(-1);
            return null;
        }
    }

    fn expectToken(self: *Parser, id: Token.Id, comptime exclusions: []const Token.Id) ParseError!TokenIndex {
        log.warn("expectToken('{s}')", .{@tagName(id)});
        return self.eatToken(id, exclusions) orelse error.UnexpectedToken;
    }

    fn getLine(self: *Parser, index: TokenIndex) usize {
        return self.line_cols.get(index).?.line;
    }

    fn getCol(self: *Parser, index: TokenIndex) usize {
        return self.line_cols.get(index).?.col;
    }
};

test {
    _ = @import("parse/test.zig");
}
