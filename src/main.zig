const std = @import("std");

fn printUsage(io: std.Io) !void {
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        "Usage: build_crab " ++
            "--manifest-path <path/to/Cargo.toml> " ++
            "--target-dir <directory> " ++
            "[--deps <.d file path>] " ++
            "[--command <build (default) / rustc / zigbuild etc>] " ++
            "[-- <cargo <command> args>]\n",
    );
}

const CargoMessage = struct {
    reason: []const u8,
    package_id: ?[]const u8 = null,
    filenames: ?[][]const u8 = null,
    manifest_path: ?[]const u8 = null,
    target: ?CargoTarget = null,
};

const CargoTarget = struct {
    name: []const u8,
    kind: [][]const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(arena);
    var command: ?[]const u8 = null;
    var deps_file: ?[]const u8 = null;
    var target_dir: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var cargo_args: std.ArrayList([]const u8) = .empty;
    defer cargo_args.deinit(gpa);

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--command")) {
            command = args.next() orelse break;
        }
        if (std.mem.eql(u8, arg, "--target-dir")) {
            target_dir = args.next() orelse break;
        }
        if (std.mem.eql(u8, arg, "--manifest-path")) {
            manifest_path = args.next() orelse break;
        }
        if (std.mem.eql(u8, arg, "--deps")) {
            deps_file = args.next() orelse break;
        }
        if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |cargo_arg| {
                try cargo_args.append(gpa, cargo_arg);
            }
            break;
        }
    }

    std.log.debug("Received:", .{});
    std.log.debug("target-dir = {?s}", .{target_dir});
    std.log.debug("manifest-path = {?s}", .{manifest_path});
    std.log.debug("deps = {?s}", .{deps_file});
    std.log.debug("cargo args = {f}", .{std.json.fmt(cargo_args.items, .{})});

    if (target_dir == null or manifest_path == null) {
        try printUsage(io);
        return;
    }

    var cargo_cmd: std.ArrayList([]const u8) = .empty;
    defer cargo_cmd.deinit(gpa);
    try cargo_cmd.appendSlice(gpa, &.{
        "cargo",
        command orelse "build",
        "--message-format=json-render-diagnostics",
        "--target-dir",
        target_dir.?,
        "--manifest-path",
        manifest_path.?,
    });
    for (cargo_args.items) |arg| {
        if (std.mem.containsAtLeast(u8, arg, 1, "--message-format")) {
            continue;
        }
        try cargo_cmd.append(gpa, arg);
    }

    std.log.debug("about to execute {f}", .{std.json.fmt(cargo_cmd.items, .{})});

    var progress = std.Progress.start(io, .{
        .root_name = "cargo build",
    });
    defer progress.end();
    const root_node = progress;

    var child = try std.process.spawn(io, .{
        .argv = cargo_cmd.items,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);

    var messages: std.ArrayList(CargoMessage) = .empty;
    defer messages.deinit(gpa);

    const stdout_buffer = try gpa.alloc(u8, 1 * 1024 * 1024);
    defer gpa.free(stdout_buffer);
    var reader = child.stdout.?.reader(io, stdout_buffer);

    var current_crate_node: std.Progress.Node = .none;
    defer current_crate_node.end();

    while (true) {
        const line = try reader.interface.takeDelimiter('\n') orelse break;

        std.log.debug("parsing cargo output: {s}", .{line});
        const message = std.json.parseFromSliceLeaky(CargoMessage, arena, line, .{ .ignore_unknown_fields = true }) catch |err| {
            std.log.debug("failed to parse cargo output as JSON: {any} (line: {s})", .{ err, line });
            continue;
        };

        if (std.mem.eql(u8, message.reason, "compiler-artifact")) {
            if (message.target) |target| {
                current_crate_node.end();
                current_crate_node = root_node.start(target.name, 0);
            }
            try messages.append(gpa, message);
        } else if (std.mem.eql(u8, message.reason, "build-script-executed")) {
            if (message.package_id) |id| {
                current_crate_node.end();
                current_crate_node = root_node.start(id, 0);
            }
        }
    }

    const term = try child.wait(io);
    std.log.debug("cargo exit status {any}", .{term});
    switch (term) {
        .exited => |exit_code| if (exit_code != 0) std.process.exit(1),
        else => std.process.exit(1),
    }

    outer: for (messages.items) |message| {
        const artifact_manifest = message.manifest_path orelse @panic("expected 'manifest_path' to contain a path to artifact's Cargo.toml");
        if (!std.mem.eql(u8, artifact_manifest, manifest_path.?)) {
            std.log.debug("artifact's manifest-path [{s}] does not equal to package's manifest-path, ignored", .{artifact_manifest});
            continue;
        }

        for (message.target.?.kind) |kind| {
            if (std.mem.eql(u8, kind, "custom-build")) {
                std.log.debug("artifact is a custom build script, ignored", .{});
                continue :outer;
            }
        }

        const filenames = message.filenames orelse @panic("expected 'compiler-artifact' to contains a list of filenames");

        if (filenames.len == 0) {
            @panic(try std.fmt.allocPrint(arena, "no filenames provided by Cargo", .{}));
        }

        const cwd = std.Io.Dir.cwd();
        const dst_dir = try cwd.openDir(io, target_dir.?, .{});
        for (filenames) |artifact| {
            const basename = std.fs.path.basename(artifact);
            std.log.debug("About to copy '{s}' to '{s}/{s}'", .{ artifact, target_dir.?, basename });
            _ = try cwd.updateFile(io, artifact, dst_dir, basename, .{});
        }

        if (deps_file) |deps_path| {
            const artifact = filenames[0];
            const dirname = std.fs.path.dirname(artifact) orelse @panic("dirname cannot be null");
            const stem = std.fs.path.stem(artifact);

            const without_extension = std.fs.path.join(gpa, &.{ dirname, stem }) catch @panic("OOM");
            defer gpa.free(without_extension);
            const artifact_d = try std.mem.concat(gpa, u8, &.{ without_extension, ".d" });
            defer gpa.free(artifact_d);

            std.log.debug("About to copy '{s}' to '{s}'", .{ artifact_d, deps_path });

            const dst = cwd.openFile(io, deps_path, .{ .mode = .read_write }) catch |e| switch (e) {
                error.FileNotFound => try cwd.createFile(io, deps_path, .{ .read = true }),
                else => return e,
            };
            defer dst.close(io);
            const stat = try dst.stat(io);
            var dst_writer: std.Io.File.Writer = .init(.{ .handle = dst.handle, .flags = .{ .nonblocking = false } }, io, &.{});
            try dst_writer.seekTo(stat.size);
            try write_dep_file(gpa, io, cwd, artifact_d, &dst_writer.interface);
        }
    }
}

fn write_dep_file(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, dep_file_path: []const u8, writer: *std.Io.Writer) !void {
    const dep_file = try cwd.openFile(io, dep_file_path, .{});
    defer dep_file.close(io);
    var dep_file_reader = dep_file.reader(io, &.{});
    const dep_file_content = try dep_file_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(dep_file_content);

    // std.Build.Cache does not support directories in the dep file.
    // Iterate over prerequisite and recursively replace any directories with the list of files inside.
    var first_target: bool = true;
    var it: std.Build.Cache.DepTokenizer = .{ .bytes = dep_file_content };
    while (it.next()) |token| {
        switch (token) {
            .target, .target_must_resolve => {
                if (first_target) {
                    first_target = false;
                } else {
                    try writer.writeAll("\n");
                }
                const target_path = if (token == .target) token.target else token.target_must_resolve;
                try writer.writeAll(target_path);
                try writer.writeAll(":");
            },
            .prereq, .prereq_must_resolve => {
                var resolve_buf: std.ArrayList(u8) = .empty;
                defer resolve_buf.deinit(allocator);

                const prereq_path = switch (token) {
                    .prereq => token.prereq,
                    .prereq_must_resolve => resolved: {
                        try token.resolve(allocator, &resolve_buf);
                        break :resolved resolve_buf.items;
                    },
                    else => unreachable,
                };

                const fstat = try cwd.statFile(io, prereq_path, .{});
                switch (fstat.kind) {
                    // TODO: Symlinks?
                    .file => {
                        try writer.writeAll(" ");
                        try writer.writeAll(prereq_path);
                    },
                    .directory => {
                        try walk_dep_directory(allocator, io, try cwd.openDir(io, prereq_path, .{
                            .iterate = true,
                            .follow_symlinks = false, // TODO: Symlinks?
                        }), writer);
                    },
                    else => {},
                }
            },
            else => |err| {
                var error_buf: std.ArrayList(u8) = .empty;
                defer error_buf.deinit(allocator);
                try err.printError(allocator, &error_buf);
                @panic(try std.fmt.allocPrint(allocator, "failed parsing {s}: {s}", .{ dep_file_path, error_buf.items }));
            },
        }
    }
    try writer.writeAll("\n");
}

fn walk_dep_directory(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, dep_writer: *std.Io.Writer) !void {
    var stack: std.ArrayList(std.Io.Dir) = .empty;
    try stack.append(allocator, root);

    while (stack.items.len > 0) {
        const directory: std.Io.Dir = stack.pop().?;
        const directory_old: std.Io.Dir = .{ .handle = directory.handle };
        var it = directory_old.iterate();
        while (try it.next(io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    try stack.append(allocator, try directory.openDir(io, entry.name, .{
                        .iterate = true,
                        .follow_symlinks = false, // TODO: Symlinks?
                    }));
                },
                // TODO: Symlinks?
                .file => {
                    try dep_writer.writeAll(" ");
                    const full_path = try directory_old.realPathFileAlloc(io, entry.name, allocator);
                    defer allocator.free(full_path);
                    try render_filename(full_path, dep_writer);
                },
                else => {
                    const full_path = try directory_old.realPathFileAlloc(io, entry.name, allocator);
                    defer allocator.free(full_path);
                    std.log.debug("Dep file: ignored {s} (not a file)", .{full_path});
                },
            }
        }
    }
    return;
}

fn render_filename(token: []const u8, writer: *std.Io.Writer) !void {
    for (token) |c| {
        switch (c) {
            ' ' => try writer.writeByte('\\'),
            else => {},
        }
        try writer.writeByte(c);
    }
}
