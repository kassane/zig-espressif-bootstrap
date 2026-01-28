const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const path_max = std.fs.max_path_bytes;

pub fn main(init: std.process.Init) !void {
    switch (builtin.target.os.tag) {
        .wasi => return, // WASI doesn't support changing the working directory at all.
        .windows => return, // POSIX is not implemented by Windows
        else => {},
    }
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const tmp_dir_path = args[1];

    var tmp_dir = try Io.Dir.cwd().openDir(init.io, tmp_dir_path, .{});
    defer tmp_dir.close(init.io);

    try test_chdir_self();
    try test_chdir_absolute();
    try test_chdir_relative(init.gpa, init.io, tmp_dir);
}

// get current working directory and expect it to match given path
fn expect_cwd(expected_cwd: []const u8) !void {
    var cwd_buf: [path_max]u8 = undefined;
    const actual_cwd = try std.posix.getcwd(cwd_buf[0..]);
    try std.testing.expectEqualStrings(actual_cwd, expected_cwd);
}

fn test_chdir_self() !void {
    var old_cwd_buf: [path_max]u8 = undefined;
    const old_cwd = try std.posix.getcwd(old_cwd_buf[0..]);

    // Try changing to the current directory
    try std.Io.Threaded.chdir(old_cwd);
    try expect_cwd(old_cwd);
}

fn test_chdir_absolute() !void {
    var old_cwd_buf: [path_max]u8 = undefined;
    const old_cwd = try std.posix.getcwd(old_cwd_buf[0..]);

    const parent = std.fs.path.dirname(old_cwd) orelse unreachable; // old_cwd should be absolute

    // Try changing to the parent via a full path
    try std.Io.Threaded.chdir(parent);

    try expect_cwd(parent);
}

fn test_chdir_relative(gpa: Allocator, io: Io, tmp_dir: Io.Dir) !void {
    const subdir_path = "subdir";
    try tmp_dir.createDir(io, "subdir", .default_dir);

    // Use the tmp dir as the "base" for the test. Then cd into the child
    try std.process.setCurrentDir(io, tmp_dir);

    // Capture base working directory path, to build expected full path
    var base_cwd_buf: [path_max]u8 = undefined;
    const base_cwd = try std.posix.getcwd(base_cwd_buf[0..]);

    const expected_path = try std.fs.path.resolve(gpa, &.{ base_cwd, subdir_path });
    defer gpa.free(expected_path);

    // change current working directory to new test directory
    try std.Io.Threaded.chdir(subdir_path);

    var new_cwd_buf: [path_max]u8 = undefined;
    const new_cwd = try std.posix.getcwd(new_cwd_buf[0..]);

    // On Windows, fs.path.resolve returns an uppercase drive letter, but the drive letter returned by getcwd may be lowercase
    const resolved_cwd = try std.fs.path.resolve(gpa, &.{new_cwd});
    defer gpa.free(resolved_cwd);

    try std.testing.expectEqualStrings(expected_path, resolved_cwd);
}
