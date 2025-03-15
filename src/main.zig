const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const clap = @import("clap");
const pages = @import("pages.zig");
const pretty = @import("pretty.zig");
const color = @import("color.zig");

const Pages = pages.Pages;
const DebugAllocator = std.heap.DebugAllocator;
const Allocator = std.mem.Allocator;

const params = clap.parseParamsComptime(
    \\-h, --help                 Display this help and exit.
    \\-v, --version              Display version information and exit.
    \\-L, --language <language>  Page language.
    \\-p, --platform <platform>  Platform target.
    \\-u, --update               Update local TLDR pages cache.
    \\-l, --list                 List all available pages with descriptons.
    \\-R, --random               Fetch a random page.
    \\--list-languages           List all supported languages.
    \\--list-platforms           List all supported operating systems.
    \\--color <color>            Enable or disable colored output.
    \\<page>...
);

var update: bool = undefined;
var lang: []const u8 = undefined;
var platform: []const u8 = undefined;
var prog_name: []const u8 = "";

const ColorChoices = enum { auto, off, on };

pub fn main() anyerror!void {
    const stdout = std.io.getStdOut().writer();
    var gpa = DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var allocator = gpa.allocator();

    const parsers = comptime .{
        .language = clap.parsers.string,
        .platform = clap.parsers.string,
        .color = clap.parsers.enumeration(ColorChoices),
        .page = clap.parsers.string,
        .help = clap.parsers.int,
        .random = clap.parsers.int,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .allocator = allocator,
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch unreachable;
        helpExit();
    };
    defer res.deinit();

    prog_name = res.exe_arg orelse return error.NoExeName;

    update = res.args.update != 0;
    lang = try setLang(allocator, res.args.language);
    defer allocator.free(lang);

    platform = setPlatform(res.args.platform);

    const positionals: ?[]const []const u8 = pos: {
        const pos = res.positionals;
        break :pos if (pos.len > 0) pos[0] else null;
    };

    if (res.args.help != 0) helpExit();

    if (res.args.version != 0) {
        try stdout.print("outfieldr {s}\n", .{build_options.version});
        std.process.exit(0);
    }

    try setColoredOutput(res.args.color);

    if (update) {
        Pages.update(allocator, stdout) catch |err| return errorExit(err);
        if (positionals == null) std.process.exit(0);
        _ = try stdout.write("--\n");
    }

    var tldr_pages = Pages.open(lang, platform) catch |err| return errorExit(err);
    defer tldr_pages.close();

    if (res.args.list != 0) {
        try tldr_pages.listPages(allocator, stdout);
        std.process.exit(0);
    }

    if (res.args.@"list-languages" != 0) {
        try tldr_pages.listLangs(allocator, stdout);
        std.process.exit(0);
    }

    if (res.args.@"list-platforms" != 0) {
        try tldr_pages.listPlatforms(allocator, stdout);
        std.process.exit(0);
    }

    if (res.args.random != 0) {
        const page_contents = tldr_pages.randomPageContents(allocator) catch |err|
            return errorExit(err);
        try pretty.prettify(allocator, page_contents, stdout);
        std.process.exit(0);
    }

    if (positionals) |pos| {
        if (pos.len == 0) helpExit();
        const page_contents = tldr_pages.pageContents(allocator, pos) catch |err|
            return errorExit(err);
        defer allocator.free(page_contents);

        try pretty.prettify(allocator, page_contents, stdout);
    } else helpExit();
}

fn errorExit(e: anyerror) !void {
    const err = std.log.err;
    switch (e) {
        error.DownloadFailedZeroSize => err("Updating returned zero bytes", .{}),
        error.AppdataNotFound => err("Appdata directory not found. Rerun with `--update`.", .{}),
        error.RepoDirNotFound => err("TLDR pages cache not found. Rerun with `--update`.", .{}),
        error.LanguageNotSupported => err("Language '{s}' not supported.", .{lang}),
        error.PlatformNotSupported => err("Platform '{s}' not supported for langauge '{s}'.", .{ platform, lang }),
        error.PageNotFound => {
            if (update)
                err("Page doesn't exist in tldr-main. Consider contributing it!", .{})
            else
                err("Page not found. Perhaps try with `--update`", .{});
        },
        error.HostLacksNetworkAddresses,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.AddressFamilyNotSupported,
        error.UnknownHostName,
        error.ServiceUnavailable,
        error.NotConnected,
        error.AddressInUse,
        error.NetworkStreamTooLong,
        error.StreamTooLong,
        => err("Network error '{s}'", .{@errorName(e)}),
        else => {
            err("Unknown error '{s}'", .{@errorName(e)});
            return e;
        },
    }
    std.process.exit(1);
}

fn setColoredOutput(color_enable: ?ColorChoices) !void {
    color.enabled = en: {
        if (color_enable) |c| {
            switch (c) {
                ColorChoices.auto => break :en colorAuto(),
                ColorChoices.on => break :en true,
                ColorChoices.off => break :en false,
            }
        } else break :en colorAuto();
    };
}

fn colorAuto() bool {
    if (std.io.getStdOut().isTty()) return true else return false;
}

fn setLang(allocator: Allocator, lang_flag: ?[]const u8) ![]const u8 {
    if (lang_flag) |l| return allocator.dupe(u8, l);
    if (builtin.os.tag == .windows) return allocator.dupe(u8, "en");

    const lang_var = std.process.getEnvVarOwned(allocator, "LANG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            return allocator.dupe(u8, "en");
        },
        else => return err,
    };
    defer allocator.free(lang_var);

    return try allocator.dupe(u8, std.mem.sliceTo(lang_var, '_'));
}

fn setPlatform(platform_flag: ?[]const u8) []const u8 {
    return if (platform_flag) |p| p else switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "osx",
        .solaris => "sunos",
        .windows => "windows",
        else => @compileError("Unsupported platform"),
    };
}

fn helpExit() noreturn {
    const stderr = std.io.getStdErr().writer();

    stderr.print("Usage: {s} ", .{prog_name}) catch unreachable;
    clap.usage(stderr, clap.Help, &params) catch unreachable;
    stderr.print("\nFlags: \n", .{}) catch unreachable;
    clap.help(stderr, clap.Help, &params, .{}) catch unreachable;
    _ = stderr.write(
        \\
        \\Examples:
        \\
        \\ # View the TLDR page for ip:
        \\ tldr ip
        \\
        \\ # View a multi-word TLDR page:
        \\ tldr git rebase
        \\
        \\ # Specify the languge and OS of the page
        \\ tldr --language es --platform osx brew
        \\
        \\ # Update fresh TLDR pages and view page for chown
        \\ tldr --update chown
        \\
        \\
    ) catch unreachable;

    std.process.exit(1);
}
