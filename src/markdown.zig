const c = @import("c");
const debug = std.debug;
const log = std.log.scoped(.markdown);
const math = std.math;
const mem = std.mem;
const std = @import("std");

const MdBlockType = enum(c.MD_BLOCKTYPE) {
    doc = 0,
    quote = 1,
    ul = 2,
    ol = 3,
    li = 4,
    hr = 5,
    h = 6,
    code = 7,
    html = 8,
    p = 9,
    table = 10,
    thead = 11,
    tbody = 12,
    tr = 13,
    th = 14,
    td = 15,
    _,

    pub fn from(t: c.MD_BLOCKTYPE) MdBlockType {
        return @enumFromInt(t);
    }
};

pub const RenderStreamConfig = struct {
    /// If url_prefix is not null, it will be prepended
    /// to the href attribute of all emitted A spans.
    url_prefix: ?[]const u8 = null,
};

/// Renders the provided markdown according to the config to the writer.
pub fn renderStream(markdown: []const u8, config: RenderStreamConfig, writer: anytype) !void {
    const parser: ParserType(@TypeOf(writer)) = .{
        .url_prefix = config.url_prefix,
        .writer = writer,
    };

    const result = c.md_parse(
        @ptrCast(markdown),
        @as(c_uint, @intCast(markdown.len)),
        parser.parser(),
        parser.ptr(),
    );

    if (result != 0) {
        return error.CouldNotTransformMarkdown;
    }
}

fn ParserType(comptime Writer: type) type {
    return struct {
        pub const Parser = @This();

        writer: Writer,
        url_prefix: ?[]const u8,

        image_nesting_level: u8 = 0,

        _parser: c.MD_PARSER = .{
            // Reserved. Set to zero.
            .abi_version = 0,
            // Dialect options. Bitmask of MD_FLAG_xxxx values.
            .flags = 0,
            .enter_block = enter_block,
            .leave_block = leave_block,
            .enter_span = enter_span,
            .leave_span = leave_span,
            .text = text,
            .debug_log = debug_log,
            .syntax = null,
        },

        pub fn parser(self: *const Parser) *const c.MD_PARSER {
            return &self._parser;
        }

        pub fn ptr(self: *const Parser) ?*anyopaque {
            return @constCast(@ptrCast(self));
        }

        pub fn fromPtr(from_ptr: ?*anyopaque) *Parser {
            return @ptrCast(@alignCast(from_ptr));
        }

        fn debug_log(buf: [*c]const u8, userdata: ?*anyopaque) callconv(.C) void {
            const self = fromPtr(userdata);
            const msg = mem.sliceTo(buf, 0);

            self.writer.print("{s}\n", .{msg}) catch @panic("Could not debug_log");
        }

        fn text(@"type": c.MD_TEXTTYPE, buf: [*c]const c.MD_CHAR, len: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
            const self = fromPtr(userdata);
            const writer = self.writer;

            switch (@"type") {
                c.MD_TEXT_NULLCHAR => {
                    // TODO render null ut8 codepoint
                },
                c.MD_TEXT_BR => {
                    writer.writeAll(if (self.image_nesting_level == 0) "<br>" else " ") catch return -1;
                },
                c.MD_TEXT_SOFTBR => {
                    writer.writeAll(if (self.image_nesting_level == 0) "\n" else " ") catch return -1;
                },
                c.MD_TEXT_ENTITY => {
                    log.warn("TODO not sure what it means to render a text entity...", .{});
                    renderEscaped(buf[0..len], writer) catch return -1;
                },
                c.MD_TEXT_HTML => {
                    writer.writeAll(buf[0..len]) catch return -1;
                },
                c.MD_TEXT_LATEXMATH,
                c.MD_TEXT_NORMAL,
                c.MD_TEXT_CODE,
                => {
                    renderEscaped(buf[0..len], writer) catch return -1;
                },
                else => unreachable,
            }

            return 0;
        }

        fn renderEscaped(buf: []const u8, writer: Writer) !void {
            for (buf) |byte| {
                switch (byte) {
                    '>' => try writer.writeAll("&gt;"),
                    '<' => try writer.writeAll("&lt;"),
                    else => try writer.writeByte(byte),
                }
            }
        }

        fn enter_block(@"type": c.MD_BLOCKTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
            const md_block_type = MdBlockType.from(@"type");
            const self = fromPtr(userdata);
            const writer = self.writer;

            log.debug("Enter block {s}", .{@tagName(md_block_type)});

            switch (md_block_type) {
                .doc => {},
                .quote => writer.writeAll("<blockquote>\n") catch return -1,
                .ul => writer.writeAll("<ul>\n") catch return -1,
                .ol => {
                    const detail: *c.MD_BLOCK_OL_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.writeAll("<ol>\n") catch return -1;
                },
                .li => {
                    const detail: *c.MD_BLOCK_LI_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.writeAll("<li>\n") catch return -1;
                },
                .hr => {
                    writer.writeAll("<hr>\n") catch return -1;
                },
                .h => {
                    const detail: *c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail_ptr));

                    // The template is expected to print the page title.
                    debug.assert(detail.level != 1);

                    writer.print("<h{d}>\n", .{detail.level}) catch return -1;
                },
                .code => {
                    const detail: *c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("<pre><code>", .{}) catch return -1;
                },
                .html => {},
                .p => writer.writeAll("<p>\n") catch return -1,
                .table => writer.writeAll("<table>\n") catch return -1,
                .thead => writer.writeAll("<thead>\n") catch return -1,
                .tbody => writer.writeAll("<tbody>\n") catch return -1,
                .tr => writer.writeAll("<tr>\n") catch return -1,
                .th => {
                    const detail: *c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("<th>\n", .{}) catch return -1;
                },
                .td => {
                    const detail: *c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("<td>\n", .{}) catch return -1;
                },
                else => unreachable,
            }

            return 0;
        }

        fn leave_block(@"type": c.MD_BLOCKTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
            const md_block_type = MdBlockType.from(@"type");
            const self = fromPtr(userdata);
            const writer = self.writer;

            log.debug("Leave block {s}", .{@tagName(md_block_type)});

            switch (md_block_type) {
                .doc => {},
                .quote => writer.writeAll("</blockquote>\n") catch return -1,
                .ul => writer.writeAll("</ul>\n") catch return -1,
                .ol => {
                    const detail: *c.MD_BLOCK_OL_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.writeAll("</ol>") catch return -1;
                },
                .li => {
                    const detail: *c.MD_BLOCK_LI_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.writeAll("</li>") catch return -1;
                },
                .hr => {},
                .h => {
                    const detail: *c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    writer.print("</h{d}>\n", .{detail.level}) catch return -1;
                },
                .code => {
                    const detail: *c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("</code></pre>", .{}) catch return -1;
                },
                .html => {},
                .p => writer.writeAll("</p>") catch return -1,
                .table => writer.writeAll("</table>") catch return -1,
                .thead => writer.writeAll("</thead>") catch return -1,
                .tbody => writer.writeAll("</tbody>") catch return -1,
                .tr => writer.writeAll("</tr>") catch return -1,
                .th => {
                    const detail: *c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("</th>", .{}) catch return -1;
                },
                .td => {
                    const detail: *c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("</td>", .{}) catch return -1;
                },
                else => unreachable,
            }
            return 0;
        }
        fn enter_span(@"type": c.MD_SPANTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
            const self = fromPtr(userdata);
            const writer = self.writer;

            switch (@"type") {
                c.MD_SPAN_A => {
                    const detail: *c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    const href = detail.href.text[0..detail.href.size];
                    if (mem.startsWith(u8, href, "/")) {
                        if (self.url_prefix) |prefix| {
                            writer.print(
                                \\<a href="{s}{s}">
                            ,
                                .{ prefix, href },
                            ) catch return -1;
                        } else {
                            writer.print(
                                \\<a href="{s}">
                            ,
                                .{href},
                            ) catch return -1;
                        }
                    } else {
                        writer.print(
                            \\<a href="{s}">
                        ,
                            .{href},
                        ) catch return -1;
                    }
                },
                c.MD_SPAN_CODE => writer.writeAll("<code>") catch return -1,
                c.MD_SPAN_DEL => {},
                c.MD_SPAN_EM => {},
                c.MD_SPAN_IMG => {
                    const detail: *c.MD_SPAN_IMG_DETAIL = @ptrCast(@alignCast(detail_ptr));

                    const title: ?[]const u8 = if (detail.title.text == null) null else detail.title.text[0..detail.title.size];
                    const src: ?[]const u8 = if (detail.src.text == null) null else detail.src.text[0..detail.src.size];

                    writer.print("<img ", .{}) catch return -1;
                    if (title) |t| writer.print("title=\"{s}\" ", .{t}) catch return -1;
                    if (src) |s| writer.print("src=\"{s}\" ", .{s}) catch return -1;
                    writer.print("/>", .{}) catch return -1;
                },
                c.MD_SPAN_STRONG => writer.writeAll("<strong>") catch return -1,
                c.MD_SPAN_U => {},

                c.MD_SPAN_LATEXMATH,
                c.MD_SPAN_LATEXMATH_DISPLAY,
                c.MD_SPAN_WIKILINK,
                => {
                    log.debug("Goku doesn't currently support rendering Latex math or wikilinks.", .{});
                },
                else => unreachable,
            }

            return 0;
        }
        fn leave_span(@"type": c.MD_SPANTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
            _ = detail_ptr;

            const self = fromPtr(userdata);
            const writer = self.writer;

            switch (@"type") {
                c.MD_SPAN_A => writer.writeAll("</a>") catch return -1,
                c.MD_SPAN_CODE => writer.writeAll("</code>") catch return -1,
                c.MD_SPAN_DEL => {},
                c.MD_SPAN_EM => {},
                c.MD_SPAN_IMG => {
                    std.log.info("why leave an image...", .{});
                },
                c.MD_SPAN_STRONG => writer.writeAll("</strong>") catch return -1,
                c.MD_SPAN_U => {},

                c.MD_SPAN_LATEXMATH,
                c.MD_SPAN_LATEXMATH_DISPLAY,
                c.MD_SPAN_WIKILINK,
                => {
                    log.debug("Goku doesn't currently support rendering Latex math or wikilinks.", .{});
                },
                else => unreachable,
            }
            return 0;
        }
    };
}
