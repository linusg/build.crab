const std = @import("std");

const Format = enum {
    coff,
    elf,
    macho,
};

fn printUsage() !void {
    try std.io.getStdOut().writeAll(
        "Usage: strip_symbols " ++
            "--archive libname.a " ++
            "--temp-dir tmp " ++
            "--remove-symbol ___chkstk_ms " ++
            "--output out-file " ++
            "[--format [coff,elf,macho]]" ++
            "[--os [macos,linux,windows]]\n",
    );
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next();
    var archive_path_opt: ?[]const u8 = null;
    var temp_dir_opt: ?[]const u8 = null;
    var output_opt: ?[]const u8 = null;
    var remove_symbol = std.ArrayList([]const u8).init(allocator);
    var format_opt: ?[]const u8 = null;
    var os_opt: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--archive")) {
            archive_path_opt = args.next() orelse return error.ArchiveArgMissing;
        }
        if (std.mem.eql(u8, arg, "--temp-dir")) {
            temp_dir_opt = args.next() orelse return error.TempDirArgMissing;
        }
        if (std.mem.eql(u8, arg, "--output")) {
            output_opt = args.next() orelse return error.OutputArgMissing;
        }
        if (std.mem.eql(u8, arg, "--remove-symbol") or std.mem.eql(u8, arg, "-rs")) {
            try remove_symbol.append(args.next() orelse return error.RemoveSymbolArgMissing);
        }
        if (std.mem.eql(u8, arg, "--format")) {
            format_opt = args.next() orelse return error.OutputArgMissing;
        }
        if (std.mem.eql(u8, arg, "--os")) {
            os_opt = args.next() orelse return error.OutputArgMissing;
        }
    }

    if (archive_path_opt == null or temp_dir_opt == null or output_opt == null or remove_symbol.items.len == 0) {
        std.log.err("One of the required arguments is missing", .{});
        try printUsage();
        return error.RequiredArgMissing;
    }

    const archive_path = archive_path_opt.?;
    const temp_dir = temp_dir_opt.?;
    const output = output_opt.?;
    const os = if (os_opt) |os_str|
        std.meta.stringToEnum(std.Target.Os.Tag, os_str) orelse std.debug.panic("os {s} not recognized", .{os_str})
    else
        @import("builtin").target.os.tag;
    const format = format_opt orelse switch (os) {
        .windows => "coff",
        .linux => "elf",
        .macos => "macho",
        else => {
            std.log.info("target os is not recognized, doing nothing", .{});
            try doNothing(archive_path, output);
            return;
        },
    };

    const format_enum = if (std.meta.stringToEnum(Format, format)) |fmt|
        fmt
    else
        std.debug.panic("format {s} not recognized", .{format});

    if (format_enum == .elf or format_enum == .macho) {
        std.log.info("format is not supported yer, doing nothing", .{});
        try doNothing(archive_path, output);
        return;
    }

    const ar_extract = try std.process.Child.run(.{ .allocator = allocator, .argv = &[_][]const u8{
        "zig",
        "ar",
        "x",
        archive_path,
        "--output",
        temp_dir,
    } });

    if (ar_extract.term != .Exited or ar_extract.term.Exited != 0) {
        try std.io.getStdErr().writeAll(ar_extract.stderr);
        return error.ArError;
    }

    const files_to_keep = switch (format_enum) {
        .coff => try filterObjFilesWindows(allocator, temp_dir, remove_symbol.items),
        .elf, .macho => unreachable,
    };

    var ar_repack_argv = std.ArrayList([]const u8).init(allocator);
    try ar_repack_argv.append("zig");
    try ar_repack_argv.append("ar");
    try ar_repack_argv.append("rcs");
    try ar_repack_argv.append(output);
    try ar_repack_argv.appendSlice(files_to_keep);

    const ar_repack = try std.process.Child.run(.{ .allocator = allocator, .argv = ar_repack_argv.items });

    if (ar_repack.term != .Exited or ar_repack.term.Exited != 0) {
        try std.io.getStdErr().writeAll(ar_repack.stderr);
        return error.ArError;
    }
}

fn doNothing(input: []const u8, output: []const u8) !void {
    const cwd = std.fs.cwd();
    try cwd.copyFile(input, cwd, output, .{});
}

fn filterObjFilesWindows(allocator: std.mem.Allocator, temp_dir: []const u8, remove_symbols: [][]const u8) ![][]const u8 {
    var tdir = try std.fs.cwd().openDir(temp_dir, .{ .iterate = true, .no_follow = true });
    defer tdir.close();

    var walker = try tdir.walk(allocator);
    defer walker.deinit();

    var files_to_keep = std.ArrayList([]const u8).init(allocator);

    while (try walker.next()) |entry| {
        // Don't go deeper
        if (entry.dir.fd != tdir.fd) {
            continue;
        }
        if (entry.kind != .file) {
            continue;
        }
        const extension = std.fs.path.extension(entry.path);
        if (!std.mem.eql(u8, extension, ".o")) {
            continue;
        }

        std.log.debug("Reading file {s}", .{entry.path});

        var file = try tdir.openFile(entry.path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 50 * 1024 * 1024);
        defer allocator.free(data);

        const coff = std.coff.Coff.init(data, false) catch std.coff.Coff{
            .data = data,
            .is_image = false,
            .is_loaded = false,
            .coff_header_offset = 0,
        };

        const symtab = coff.getSymtab() orelse continue;
        const strtab = try coff.getStrtab();

        var idx: usize = 0;
        const len = symtab.len();
        var remove_this_file = false;
        while (idx < len) : (idx += 1) {
            const symbol = symtab.at(idx, .symbol).symbol;
            if (symbol.type.complex_type != .FUNCTION or symbol.storage_class != .EXTERNAL) {
                continue;
            }

            var name: []const u8 = undefined;
            if (symbol.getName()) |short_name| {
                name = short_name;
            } else if (strtab) |string_tab| {
                const offset = symbol.getNameOffset().?;
                name = string_tab.get(offset);
            }

            std.log.debug("Found external function {s}", .{name});

            for (remove_symbols) |rem| {
                if (std.mem.eql(u8, rem, name)) {
                    remove_this_file = true;
                    break;
                }
            }
        }

        if (!remove_this_file) {
            try files_to_keep.append(try std.fs.path.join(allocator, &.{ temp_dir, entry.path }));
        }
    }

    return try files_to_keep.toOwnedSlice();
}
