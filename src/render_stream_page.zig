const std = @import("std");
const debug = std.debug;
const io = std.io;
const mem = std.mem;
const Markdown = @import("Markdown.zig");
const Page = @import("page.zig").Page;

// Write `page` as an html document to the `writer`.
pub fn renderStreamPage(allocator: mem.Allocator, page: Page, writer: anytype) !void {
    var w: Writer(@TypeOf(writer)) = .{ .writer = writer };
    defer switch (w.deinit()) {
        .leak => {
            @panic("Malformed html. Missing a closing tag?");
        },
        .ok => {},
    };

    try writer.writeAll("<!doctype html>");
    {
        try w.open("html", .{});
        defer w.close("html") catch @panic("Failed to write HTML output");

        {
            try w.open("head", .{});
            defer w.close("head") catch @panic("Failed to write HTML output");

            if (false) {
                try w.open("script", .{});
                try writer.writeAll(
                    \\setTimeout(() => { let l = 'location'; document[l] = document[l]; }, 2000);
                );
                try w.close("script");
            }

            try w.selfClosing("link", .{
                .rel = "stylesheet",
                .lang = "text/css",
                .href = "/style.css",
            });
        }

        {
            try w.open("body", .{});
            defer w.close("body") catch @panic("Could not write HTML output.");

            try w.open("div", .{ .class = "page" });

            try w.open("nav", .{
                .@"hx-get" = "/_sitemap.html",
                .@"hx-swap" = "outerHTML",
                .@"hx-trigger" = "load",
            });
            try w.close("nav");

            try w.open("section", .{ .class = "meta" });
            try writer.writeAll(page.markdown.frontmatter);
            try w.close("section");

            try w.open("main", .{});

            try w.open("a", .{ .href = "#main-content", .id = "main-content", .@"tab-index" = "-1" });
            try w.close("a");

            {
                var parser = Markdown.init(allocator);
                defer parser.deinit();

                try parser.renderStream(page.markdown.data, writer);
            }

            try w.close("main");

            try w.close("div");

            try w.open("script", .{
                .@"defer" = true,
                .src = "htmx.js",
            });
            try w.close("script");
        }
    }
}

// Produce a type to enable type checking of element attributes.
//
// This is by no means a comprehensive list of html tags to their
// allowed attributes. Currently the only tags and attributes are
// implemented out of necessity. For example, at some point we'll
// need to deal with optional attributes, custom elements, etc.
fn Attrs(comptime tag: []const u8) type {
    if (mem.eql(u8, "script", tag)) {
        return struct {
            @"defer": bool,
            src: []const u8,
        };
    } else if (mem.eql(u8, "link", tag)) {
        return struct {
            rel: []const u8,
            lang: []const u8,
            href: []const u8,
        };
    } else if (mem.eql(u8, "html", tag)) {
        return struct {};
    } else if (mem.eql(u8, "head", tag)) {
        return struct {};
    } else if (mem.eql(u8, "body", tag)) {
        return struct {};
    } else if (mem.eql(u8, "div", tag)) {
        return struct {
            class: []const u8,
        };
    } else if (mem.eql(u8, "nav", tag)) {
        return struct {
            @"hx-get": []const u8,
            @"hx-swap": []const u8,
            @"hx-trigger": []const u8,
        };
    } else if (mem.eql(u8, "section", tag)) {
        return struct {
            class: []const u8,
        };
    } else if (mem.eql(u8, "main", tag)) {
        return struct {};
    } else if (mem.eql(u8, "a", tag)) {
        return struct {
            href: []const u8,
            id: []const u8,
            @"tab-index": []const u8,
        };
    }

    @compileError("Cannot produce an attrs type for unknown tag " ++ tag ++ ".");
}

pub fn Writer(comptime T: type) type {
    return struct {
        writer: T,
        num_open: u64 = 0,

        const Self = @This();

        const WriterResult = union(enum) {
            // TODO find a nice way to provide failure details
            leak,
            ok,
        };
        pub fn deinit(self: Self) WriterResult {
            return if (self.num_open > 0) .leak else .ok;
        }

        pub fn selfClosing(self: Self, comptime tag: []const u8, attrs: Attrs(tag)) !void {
            const info = @typeInfo(@TypeOf(attrs));
            switch (info) {
                .Struct => {},
                else => @compileError("attrs must be a struct"),
            }

            if (info.Struct.fields.len == 0) {
                try self.writer.print("<{s} />", .{tag});
            } else {
                try self.writer.print("<{s}", .{tag});

                inline for (info.Struct.fields) |f| {
                    try self.writer.print(" ", .{});

                    switch (@typeInfo(f.type)) {
                        .Bool => {
                            try self.writer.print("{s}", .{f.name});
                        },
                        else => {
                            try self.writer.print(
                                "{s}=\"{s}\"",
                                .{
                                    f.name,
                                    @field(attrs, f.name),
                                },
                            );
                        },
                    }
                }

                try self.writer.print(" />", .{});
            }
        }

        pub fn open(self: *Self, comptime tag: []const u8, attrs: Attrs(tag)) !void {
            const type_info = @typeInfo(@TypeOf(attrs));
            switch (type_info) {
                .Struct => {},
                else => @compileError("attrs must be a struct"),
            }

            defer self.num_open += 1;

            if (type_info.Struct.fields.len == 0) {
                try self.writer.print("<{s}>", .{tag});
            } else {
                try self.writer.print("<{s}", .{tag});
                inline for (type_info.Struct.fields) |f| {
                    try self.writer.print(" ", .{});

                    switch (@typeInfo(f.type)) {
                        .Bool => {
                            try self.writer.print("{s}", .{f.name});
                        },
                        else => {
                            try self.writer.print(
                                "{s}=\"{s}\"",
                                .{
                                    f.name,
                                    @field(attrs, f.name),
                                },
                            );
                        },
                    }
                }
                try self.writer.print(">", .{});
            }
        }

        pub fn close(self: *Self, comptime tag: []const u8) !void {
            debug.assert(self.num_open > 0);

            defer self.num_open -= 1;

            try self.writer.print("</{s}>", .{tag});
        }
    };
}
