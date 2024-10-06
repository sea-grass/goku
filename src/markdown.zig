const c = @import("c");
const debug = std.debug;
const log = std.log.scoped(.markdown);
const math = std.math;
const mem = std.mem;
const std = @import("std");

pub fn renderStream(markdown: []const u8, writer: anytype) !void {
    const parser: ParserType(@TypeOf(writer)) = .{ .writer = writer };
    const result = c.md_parse(
        @ptrCast(markdown),
        @as(c_uint, @intCast(markdown.len)),
        &parser.parser,
        @constCast(@ptrCast(&parser)),
    );

    if (result != 0) {
        return error.CouldNotTransformMarkdown;
    }
}

fn ParserType(comptime Writer: type) type {
    return struct {
        writer: Writer,

        parser: c.MD_PARSER = .{
            // Reserved. Set to zero.
            .abi_version = 0,
            // Dialect options. Bitmask of MD_FLAG_xxxx values.
            .flags = 0,
            .enter_block = enter_block,
            .leave_block = leave_block,
            .enter_span = enter_span,
            .leave_span = leave_span,
            .text = text,
            .debug_log = null,
            .syntax = null,
        },

        fn debug_log(buf: [*c]const u8, userdata: ?*anyopaque) c_int {
            const msg = mem.sliceTo(buf, 0);
            _ = msg;
            _ = userdata;
            return 0;
        }

        fn text(@"type": c.MD_TEXTTYPE, buf: [*c]const c.MD_CHAR, len: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
            const writer: *Writer = @ptrCast(@alignCast(userdata));

            _ = @"type";
            const value = buf[0..len];
            writer.writeAll(value) catch return -1;

            return 0;
        }

        fn enter_block(@"type": c.MD_BLOCKTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
            const writer: *Writer = @ptrCast(@alignCast(userdata));

            switch (@"type") {
                c.MD_BLOCK_DOC => {},
                c.MD_BLOCK_QUOTE => writer.writeAll("<blockquote>\n") catch return -1,
                c.MD_BLOCK_UL => writer.writeAll("<ul>\n") catch return -1,
                c.MD_BLOCK_OL => {
                    const detail: *c.MD_BLOCK_OL_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.writeAll("<ol>\n") catch return -1;
                },
                c.MD_BLOCK_LI => {
                    const detail: *c.MD_BLOCK_LI_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.writeAll("<li>\n") catch return -1;
                },
                c.MD_BLOCK_HR => {
                    writer.writeAll("<hr>\n") catch return -1;
                },
                c.MD_BLOCK_H => {
                    const detail: *c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail_ptr));

                    // The template is expected to print the page title.
                    debug.assert(detail.level != 1);

                    writer.print("<h{d}>\n", .{detail.level}) catch return -1;
                },
                c.MD_BLOCK_CODE => {
                    const detail: *c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("<code>", .{}) catch return -1;
                },
                c.MD_BLOCK_HTML => {},
                c.MD_BLOCK_P => writer.writeAll("<p>\n") catch return -1,
                c.MD_BLOCK_TABLE => writer.writeAll("<table>\n") catch return -1,
                c.MD_BLOCK_THEAD => writer.writeAll("<thead>\n") catch return -1,
                c.MD_BLOCK_TBODY => writer.writeAll("<tbody>\n") catch return -1,
                c.MD_BLOCK_TR => writer.writeAll("<tr>\n") catch return -1,
                c.MD_BLOCK_TH => {
                    const detail: *c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("<th>\n", .{}) catch return -1;
                },
                c.MD_BLOCK_TD => {
                    const detail: *c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("<td>\n", .{}) catch return -1;
                },
                else => unreachable,
            }

            return 0;
        }

        fn leave_block(@"type": c.MD_BLOCKTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
            const writer: *Writer = @ptrCast(@alignCast(userdata));

            switch (@"type") {
                c.MD_BLOCK_DOC => {},
                c.MD_BLOCK_QUOTE => writer.writeAll("</blockquote>\n") catch return -1,
                c.MD_BLOCK_UL => writer.writeAll("</ul>\n") catch return -1,
                c.MD_BLOCK_OL => {
                    const detail: *c.MD_BLOCK_OL_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.writeAll("</ol>") catch return -1;
                },
                c.MD_BLOCK_LI => {
                    const detail: *c.MD_BLOCK_LI_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.writeAll("</li>") catch return -1;
                },
                c.MD_BLOCK_H => {
                    const detail: *c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    writer.print("</h{d}>\n", .{detail.level}) catch return -1;
                },
                c.MD_BLOCK_CODE => {
                    const detail: *c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("</code>", .{}) catch return -1;
                },
                c.MD_BLOCK_HTML => {},
                c.MD_BLOCK_P => writer.writeAll("</p>") catch return -1,
                c.MD_BLOCK_TABLE => writer.writeAll("</table>") catch return -1,
                c.MD_BLOCK_THEAD => writer.writeAll("</thead>") catch return -1,
                c.MD_BLOCK_TBODY => writer.writeAll("</tbody>") catch return -1,
                c.MD_BLOCK_TR => writer.writeAll("</tr>") catch return -1,
                c.MD_BLOCK_TH => {
                    const detail: *c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("</th>", .{}) catch return -1;
                },
                c.MD_BLOCK_TD => {
                    const detail: *c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    _ = detail;
                    writer.print("</td>", .{}) catch return -1;
                },
                else => unreachable,
            }
            return 0;
        }
        fn enter_span(@"type": c.MD_SPANTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
            const writer: *Writer = @ptrCast(@alignCast(userdata));

            switch (@"type") {
                c.MD_SPAN_A => {
                    const detail: *c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail_ptr));
                    const href = detail.href.text[0..detail.href.size];
                    writer.print(
                        \\<a href="{s}">
                    ,
                        .{href},
                    ) catch return -1;
                },
                c.MD_SPAN_CODE => {},
                c.MD_SPAN_DEL => {},
                c.MD_SPAN_EM => {},
                c.MD_SPAN_IMG => {},
                c.MD_SPAN_STRONG => {},
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

            const writer: *Writer = @ptrCast(@alignCast(userdata));

            switch (@"type") {
                c.MD_SPAN_A => writer.writeAll("</a>") catch return -1,
                c.MD_SPAN_CODE => {},
                c.MD_SPAN_DEL => {},
                c.MD_SPAN_EM => {},
                c.MD_SPAN_IMG => {},
                c.MD_SPAN_STRONG => {},
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
