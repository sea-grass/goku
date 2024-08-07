const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const c = @import("c");
const tracy = @import("tracy");

slug: []const u8,
collection: ?[]const u8 = null,
title: ?[]const u8 = null,
date: ?[]const u8 = null,
options_toc: bool = false,

const PageData = @This();

// Duplicates slices from the input data. Caller is responsible for
// calling page_data.deinit(allocator) afterwards.
pub fn fromYamlString(allocator: mem.Allocator, data: [*c]const u8, len: usize) !PageData {
    const zone = tracy.initZone(@src(), .{ .name = "PageData.fromYamlString" });
    defer zone.deinit();

    var parser: c.yaml_parser_t = undefined;
    const ptr: [*c]c.yaml_parser_t = &parser;

    if (c.yaml_parser_initialize(ptr) == 0) {
        return error.YamlParserInitFailed;
    }
    defer c.yaml_parser_delete(ptr);

    c.yaml_parser_set_input_string(ptr, data, len);

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
        tags,
    } = .key;
    var slug: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    while (!done) {
        if (c.yaml_parser_parse(ptr, ev_ptr) == 0) {
            debug.print("Encountered a yaml parsing error: {s}\nLine: {d} Column: {d}\n", .{
                parser.problem,
                parser.problem_mark.line + 1,
                parser.problem_mark.column + 1,
            });
            return error.YamlParseFailed;
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
                        } else {
                            next_scalar_expected = .discard;
                        }
                    },
                    .slug => {
                        slug = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .title => {
                        title = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .collection => {
                        next_scalar_expected = .key;
                    },
                    .tags => {
                        next_scalar_expected = .key;
                    },
                    .date => {
                        next_scalar_expected = .key;
                    },
                    .description => {
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
    };
}

pub fn deinit(self: PageData, allocator: mem.Allocator) void {
    allocator.free(self.slug);
    if (self.title) |title| {
        allocator.free(title);
    }
}
