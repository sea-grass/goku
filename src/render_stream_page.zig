const std = @import("std");
const debug = std.debug;
const io = std.io;
const mem = std.mem;
const Markdown = @import("Markdown.zig");
const Page = @import("page.zig").Page;

// Write `page` as an html document to the `writer`.
pub fn renderStreamPage(allocator: mem.Allocator, page: Page, writer: anytype) !void {
    const Context = struct {
        page: Page,
        allocator: mem.Allocator,
    };
    const W = Writer(Context, @TypeOf(writer));
    var w: W = .{
        .writer = writer,
        .ctx = .{
            .page = page,
            .allocator = allocator,
        },
    };
    defer switch (w.deinit()) {
        .leak => {
            @panic("Malformed html. Missing a closing tag?");
        },
        .ok => {},
    };

    try writer.writeAll("<!doctype html>");
    const head = .{
        .head = .{
            .children = &.{
                .{
                    .link = .{
                        .attrs = .{
                            .rel = "stylesheet",
                            .lang = "text/css",
                            .href = "/style.css",
                        },
                    },
                },
            },
        },
    };
    const nav = .{
        .nav = .{
            .attrs = .{
                .@"hx-get" = "/_sitemap.html",
                .@"hx-swap" = "outerHTML",
                .@"hx-trigger" = "load",
            },
        },
    };
    const meta = .{
        .section = .{
            .attrs = .{
                .class = "meta",
            },
            .children = &.{
                .{
                    .dynamic = .{
                        .write = struct {
                            fn write(ctx: *W) !void {
                                try ctx.writer.writeAll(ctx.ctx.page.markdown.frontmatter);
                            }
                        }.write,
                    },
                },
            },
        },
    };
    const main = .{
        .main = .{
            .children = &.{
                .{
                    .dynamic = .{
                        .write = struct {
                            fn write(ctx: *W) !void {
                                var parser = Markdown.init(ctx.ctx.allocator);
                                defer parser.deinit();
                                try parser.renderStream(ctx.ctx.page.markdown.data, ctx.writer);
                            }
                        }.write,
                    },
                },
            },
        },
    };
    const body = .{
        .body = .{
            .children = &.{
                .{
                    .div = .{
                        .attrs = .{
                            .class = "page",
                        },
                        .children = &.{
                            nav,
                            meta,
                            main,
                        },
                    },
                },
                .{
                    .script = .{
                        .attrs = .{
                            .@"defer" = true,
                            .src = "htmx.js",
                        },
                    },
                },
            },
        },
    };

    try w.write(.{
        .html = .{
            .attrs = .{},
            .children = &.{
                head,
                body,
            },
        },
    });
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

pub fn Writer(comptime Context: type, comptime T: type) type {
    return struct {
        ctx: Context,
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

        pub const Element = union(enum) {
            body: struct {
                attrs: Attrs("body") = .{},
                children: []const Element,
            },
            div: struct {
                attrs: Attrs("div"),
                children: []const Element,
            },
            html: struct {
                attrs: Attrs("html"),
                children: []const Element,
            },
            head: struct {
                attrs: Attrs("head") = .{},
                children: []const Element,
            },
            link: struct {
                attrs: Attrs("link"),
            },
            main: struct {
                attrs: Attrs("main") = .{},
                children: []const Element,
            },
            nav: struct {
                attrs: Attrs("nav"),
                children: []const Element = &.{},
            },
            script: struct {
                attrs: Attrs("script"),
                children: []const Element = &.{},
            },
            section: struct {
                attrs: Attrs("section"),
                children: []const Element,
            },
            dynamic: struct {
                write: *const fn (*Self) anyerror!void,
            },
        };
        pub fn write(self: *Self, el: Element) !void {
            switch (el) {
                .link => |link| {
                    try self.selfClosing("link", link.attrs);
                },
                .body => |body| {
                    try self.open("body", body.attrs);
                    for (body.children) |child| {
                        try self.write(child);
                    }
                    try self.close("body");
                },
                .div => |div| {
                    try self.open("div", div.attrs);
                    for (div.children) |child| {
                        try self.write(child);
                    }
                    try self.close("div");
                },
                .html => |html| {
                    try self.open("html", html.attrs);
                    for (html.children) |child| {
                        try self.write(child);
                    }
                    try self.close("html");
                },
                .head => |head| {
                    try self.open("head", head.attrs);
                    for (head.children) |child| {
                        try self.write(child);
                    }
                    try self.close("head");
                },
                .main => |main| {
                    try self.open("main", main.attrs);
                    for (main.children) |child| {
                        try self.write(child);
                    }
                    try self.close("main");
                },
                .nav => |nav| {
                    try self.open("nav", nav.attrs);
                    for (nav.children) |child| {
                        try self.write(child);
                    }
                    try self.close("nav");
                },
                .script => |script| {
                    try self.open("script", script.attrs);
                    for (script.children) |child| {
                        try self.write(child);
                    }
                    try self.close("script");
                },
                .section => |section| {
                    try self.open("section", section.attrs);
                    for (section.children) |child| {
                        try self.write(child);
                    }
                    try self.close("section");
                },
                .dynamic => |dynamic| {
                    try dynamic.write(self);
                },
            }
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
