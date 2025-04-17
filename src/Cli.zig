//! The Goku CLI
//!
//! Commands:
//! - init
//! - build
//! - preview

pub fn printHelp() void {
    const stderr = io.getStdErr().writer();

    stderr.print(
        "{s}",
        .{standard_help},
    ) catch {};
}

pub const Command = union(enum) {
    build: Build,
    help: void,
    init: Init,
    preview: Preview,

    pub const Build = struct {
        site_root: union(enum) {
            absolute: []const u8,
            relative: []const u8,
        },
        out_dir: []const u8 = "build",
        url_prefix: ?[]const u8 = null,
    };
    pub const Init = struct {};
    pub const Preview = struct {
        site_root: union(enum) {
            absolute: []const u8,
            relative: []const u8,
        },
        out_dir: []const u8 = "build",
        url_prefix: ?[]const u8 = null,
    };

    /// Assumes the exe name has already been consumed in the iterator
    pub fn parse(args: *process.ArgIterator) !?Command {
        const command = args.next() orelse return null;

        if (mem.eql(u8, command, "build")) {
            return try parseBuildArgs(args);
        } else if (mem.eql(u8, command, "help")) {
            return .help;
        } else if (mem.eql(u8, command, "init")) {
            @panic("TODO");
            //return parseInitArgs(args);
        } else if (mem.eql(u8, command, "preview")) {
            return try parsePreviewArgs(args);
        }

        return null;
    }

    pub fn parseBuildArgs(args: *process.ArgIterator) !Command {
        var site_root: ?[]const u8 = null;
        var out_dir: ?[]const u8 = null;
        var url_prefix: ?[]const u8 = null;

        while (args.next()) |arg| {
            if (mem.eql(u8, arg, "-o")) {
                if (out_dir != null) return error.TooManyArguments;
                out_dir = args.next() orelse return error.MissingOutDir;
            } else if (mem.eql(u8, arg, "-p")) {
                if (url_prefix != null) return error.TooManyArguments;
                url_prefix = args.next() orelse return error.MissingUrlPrefix;
            } else {
                if (site_root != null) return error.TooManyArguments;
                site_root = arg;
            }
        }

        if (site_root == null) return error.MissingSiteRoot;
        var build: Build = .{
            .site_root = if (fs.path.isAbsolute(site_root.?))
                .{ .absolute = site_root.? }
            else
                .{ .relative = site_root.? },
        };
        if (out_dir) |path| build.out_dir = path;
        if (url_prefix) |prefix| build.url_prefix = prefix;
        return .{ .build = build };
    }

    pub fn parsePreviewArgs(args: *process.ArgIterator) !Command {
        var site_root: ?[]const u8 = null;
        var out_dir: ?[]const u8 = null;
        var url_prefix: ?[]const u8 = null;

        while (args.next()) |arg| {
            if (mem.eql(u8, arg, "-o")) {
                if (out_dir != null) return error.TooManyArguments;
                out_dir = args.next() orelse return error.MissingOutDir;
            } else if (mem.eql(u8, arg, "-p")) {
                if (url_prefix != null) return error.TooManyArguments;
                url_prefix = args.next() orelse return error.MissingUrlPrefix;
            } else {
                if (site_root != null) return error.TooManyArguments;
                site_root = arg;
            }
        }

        if (site_root == null) return error.MissingSiteRoot;

        var preview: Preview = .{ .site_root = if (fs.path.isAbsolute(site_root.?))
            .{ .absolute = site_root.? }
        else
            .{ .relative = site_root.? } };
        if (out_dir) |path| preview.out_dir = path;
        if (url_prefix) |prefix| preview.url_prefix = prefix;
        return .{ .preview = preview };
    }
};

const size_of_alice_txt = 1189000;

const standard_help =
    \\Goku - A static site generator
    \\----
    \\Usage:
    \\    goku -h
    \\    goku init [<site_root>]
    \\    goku build <site_root> -o <out_dir> [-p <url_prefix>]
    \\    goku preview <site_root> -o <out_dir> [-p <url_prefix>]
    \\
;

const SubCommand = enum {
    build,
    help,
    init,
    preview,

    const main_parsers = .{
        .command = clap.parsers.enumeration(SubCommand),
    };

    const main_params = clap.parseParamsComptime(
        \\-h, --help  Display this help text and exit.
        \\<command> The subcommand - can be one of build, help, init
        \\
    );

    const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

    pub fn parse(allocator: mem.Allocator, iter: *process.ArgIterator) !SubCommand {
        var diag: clap.Diagnostic = .{};
        var res = clap.parseEx(clap.Help, &main_params, main_parsers, iter, .{
            .diagnostic = &diag,
            .allocator = allocator,

            // Terminate the parsing of arguments after the first positional,
            // the subcommand. This will leave the rest of the iter args unconsumed,
            // so the iter can be reused for parsing the subcommand arguments.
            .terminating_positional = 0,
        }) catch |err| {
            diag.report(io.getStdErr().writer(), err) catch {};
            return err;
        };
        defer res.deinit();

        if (res.args.help != 0) {
            printHelp();
            process.exit(0);
        }

        return res.positionals[0] orelse return error.MissingCommand;
    }
};

pub fn initMain(unlimited_allocator: mem.Allocator, iter: *process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help Display this help text and exit.
        \\<str>  The directory to initialize (defaults to the current working directory).
    );

    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = unlimited_allocator,
    }) catch |err| {
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    const site_root = res.positionals[0] orelse ".";

    if (res.args.help != 0) {
        log.info("THelp", .{});
        process.exit(0);
    }

    log.info("init ({s})", .{site_root});

    var dir = try fs.cwd().makeOpenPath(site_root, .{});
    defer dir.close();

    try scaffold.check(&dir);
    try scaffold.write(&dir);

    log.info("Site scaffolded at ({s}).", .{site_root});
}

const clap = @import("clap");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const log = std.log.scoped(.goku);
const mem = std.mem;
const httpz = @import("httpz");
const page = @import("page.zig");
const process = std.process;
const filesystem = @import("source/filesystem.zig");
const scaffold = @import("scaffold.zig");
const std = @import("std");
const storage = @import("storage.zig");
const testing = std.testing;
const time = std.time;
const Database = @import("Database.zig");
const Site = @import("Site.zig");
