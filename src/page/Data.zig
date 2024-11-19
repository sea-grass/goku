const c = @import("c");
const debug = std.debug;
const fmt = std.fmt;
const io = std.io;
const log = std.log.scoped(.@"page.Data");
const math = std.math;
const mem = std.mem;
const CodeFence = @import("CodeFence.zig");
const std = @import("std");
const testing = std.testing;
const tracy = @import("tracy");

slug: []const u8,
collection: ?[]const u8 = null,
title: ?[]const u8 = null,
date: ?[]const u8 = null,
template: ?[]const u8 = null,
description: ?[]const u8 = null,
allow_html: bool = false,
options_toc: bool = false,

const Data = @This();

pub fn fromReader(allocator: mem.Allocator, reader: anytype, max_len: usize) error{ ParseError, ReadError, MissingFrontmatter }!Data {
    const bytes: []const u8 = reader.readAllAlloc(allocator, max_len) catch return error.ReadError;
    defer allocator.free(bytes);

    const code_fence_result = CodeFence.parse(bytes) orelse return error.MissingFrontmatter;

    return fromYamlString(
        allocator,
        code_fence_result.within,
        null,
    ) catch {
        return error.ParseError;
    };
}

pub const Diagnostics = struct {
    reason: []const u8,
    line: usize,
    col: usize,

    pub fn printErr(self: Diagnostics, logger: anytype) void {
        logger.err("Encountered a yaml parsing error: {s}\nLine: {d} Column: {d}\n", .{
            self.reason,
            self.line,
            self.col,
        });
    }
};

// Duplicates slices from the input data. Caller is responsible for
// calling page_data.deinit(allocator) afterwards.
pub fn fromYamlString(allocator: mem.Allocator, data: []const u8, diag: ?*Diagnostics) !Data {
    const zone = tracy.initZone(@src(), .{ .name = "PageData.fromYamlString" });
    defer zone.deinit();

    var parser: c.yaml_parser_t = undefined;
    const ptr: [*c]c.yaml_parser_t = &parser;

    if (c.yaml_parser_initialize(ptr) == 0) {
        return error.YamlParserInit;
    }
    defer c.yaml_parser_delete(ptr);

    c.yaml_parser_set_input_string(ptr, @ptrCast(data), data.len);

    var done: bool = false;

    var ev: c.yaml_event_t = undefined;
    const ev_ptr: [*c]c.yaml_event_t = &ev;
    var next_scalar_expected: enum {
        key,
        slug,
        title,
        discard,
        date,
        collection,
        description,
        template,
        allow_html,
        tags,
    } = .key;
    var slug: ?[]const u8 = null;
    errdefer if (slug) |f| allocator.free(f);

    var title: ?[]const u8 = null;
    errdefer if (title) |f| allocator.free(f);

    var template: ?[]const u8 = null;
    errdefer if (template) |f| allocator.free(f);

    var collection: ?[]const u8 = null;
    errdefer if (collection) |f| allocator.free(f);

    var description: ?[]const u8 = null;
    errdefer if (description) |f| allocator.free(f);

    var date: ?[]const u8 = null;
    errdefer if (date) |f| allocator.free(f);

    var allow_html: bool = false;

    while (!done) {
        if (c.yaml_parser_parse(ptr, ev_ptr) == 0) {
            if (diag) |d| {
                // Populate diagnostics info for later reporting
                d.* = .{
                    .reason = mem.sliceTo(parser.problem, 0),
                    .line = parser.problem_mark.line + 1,
                    .col = parser.problem_mark.column + 1,
                };
            }
            return error.Parse;
        }

        switch (ev.type) {
            c.YAML_STREAM_START_EVENT => {},
            c.YAML_STREAM_END_EVENT => {},
            c.YAML_DOCUMENT_START_EVENT => {},
            c.YAML_DOCUMENT_END_EVENT => {},
            c.YAML_SCALAR_EVENT => {
                const scalar = ev.data.scalar;
                const value = scalar.value[0..scalar.length];

                switch (next_scalar_expected) {
                    .key => {
                        if (mem.eql(u8, value, "slug")) {
                            next_scalar_expected = .slug;
                        } else if (mem.eql(u8, value, "title")) {
                            next_scalar_expected = .title;
                        } else if (mem.eql(u8, value, "collection")) {
                            next_scalar_expected = .collection;
                        } else if (mem.eql(u8, value, "date")) {
                            next_scalar_expected = .date;
                        } else if (mem.eql(u8, value, "tags")) {
                            next_scalar_expected = .tags;
                        } else if (mem.eql(u8, value, "description")) {
                            next_scalar_expected = .description;
                        } else if (mem.eql(u8, value, "template")) {
                            next_scalar_expected = .template;
                        } else if (mem.eql(u8, value, "allow_html")) {
                            next_scalar_expected = .allow_html;
                        } else {
                            next_scalar_expected = .discard;
                        }
                    },
                    .slug => {
                        slug = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .template => {
                        template = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .title => {
                        title = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .allow_html => {
                        if (mem.eql(u8, value, "true")) {
                            allow_html = true;
                        } else if (mem.eql(u8, value, "false")) {
                            allow_html = false;
                        } else {
                            return error.UnexpectedValue;
                        }
                        next_scalar_expected = .key;
                    },
                    .collection => {
                        collection = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .tags => {
                        next_scalar_expected = .key;
                    },
                    .date => {
                        date = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .description => {
                        description = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .discard => {
                        next_scalar_expected = .key;
                    },
                }
            },
            c.YAML_SEQUENCE_START_EVENT => {},
            c.YAML_SEQUENCE_END_EVENT => {},
            c.YAML_MAPPING_START_EVENT => {},
            c.YAML_MAPPING_END_EVENT => {},
            c.YAML_ALIAS_EVENT => {},
            c.YAML_NO_EVENT => {},
            else => {},
        }

        done = (ev.type == c.YAML_STREAM_END_EVENT);

        c.yaml_event_delete(ev_ptr);
    }

    if (slug == null) return error.MissingSlug;

    return .{
        .slug = slug.?,
        .title = title,
        .template = template,
        .collection = collection,
        .allow_html = allow_html,
        .date = date,
        .description = description,
    };
}

pub fn deinit(self: Data, allocator: mem.Allocator) void {
    allocator.free(self.slug);
    if (self.title) |title| {
        allocator.free(title);
    }
    if (self.template) |template| {
        allocator.free(template);
    }

    if (self.collection) |collection| {
        allocator.free(collection);
    }

    if (self.date) |date| {
        allocator.free(date);
    }

    if (self.description) |description| {
        allocator.free(description);
    }
}

test fromReader {
    const input =
        \\---
        \\slug: /
        \\title: Home page
        \\---
    ;

    var fbs = std.io.fixedBufferStream(input);
    const reader = fbs.reader();

    const yaml = try fromReader(
        testing.allocator,
        reader,
        std.math.maxInt(usize),
    );

    defer yaml.deinit(testing.allocator);

    try testing.expectEqualStrings("/", yaml.slug);
    try testing.expectEqualStrings("Home page", yaml.title.?);
}

test "fromReader - fail(empty frontmatter)" {
    var fbs = io.fixedBufferStream(
        \\---
        \\---
        ,
    );
    const reader = fbs.reader();

    const result = fromReader(
        testing.allocator,
        reader,
        math.maxInt(usize),
    );

    try testing.expectError(
        error.MissingFrontmatter,
        result,
    );
}

test "fromReader - fail(invalid yaml)" {
    var fbs = io.fixedBufferStream(
        \\---
        \\:
        \\---
        ,
    );
    const reader = fbs.reader();

    const result = fromReader(
        testing.allocator,
        reader,
        math.maxInt(usize),
    );

    try testing.expectError(
        error.ParseError,
        result,
    );
}

test fromYamlString {
    const input =
        \\slug: /
        \\title: Home page
    ;

    const yaml = try fromYamlString(
        testing.allocator,
        input,
        null,
    );

    defer yaml.deinit(testing.allocator);

    try testing.expectEqualStrings("/", yaml.slug);
    try testing.expectEqualStrings("Home page", yaml.title.?);
}

test "fromYamlString - Error" {
    const invalid_input =
        \\: 
    ;

    const result = fromYamlString(
        testing.allocator,
        invalid_input,
        null,
    );

    try testing.expectError(error.Parse, result);
}

test "correct diagnostics" {
    const invalid_input =
        \\:
    ;

    var diag: Diagnostics = undefined;
    const result = fromYamlString(
        testing.allocator,
        invalid_input,
        &diag,
    );

    try testing.expectError(error.Parse, result);
    try testing.expectEqualStrings("did not find expected key", diag.reason);
}
