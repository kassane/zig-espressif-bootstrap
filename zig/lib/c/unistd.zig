const std = @import("std");
const common = @import("common.zig");
const builtin = @import("builtin");
const linux = std.os.linux;

comptime {
    if (builtin.target.isMuslLibC()) {
        @export(&_exit, .{ .name = "_exit", .linkage = common.linkage, .visibility = common.visibility });

        @export(&accessLinux, .{ .name = "access", .linkage = common.linkage, .visibility = common.visibility });
        @export(&acctLinux, .{ .name = "acct", .linkage = common.linkage, .visibility = common.visibility });
        @export(&chdirLinux, .{ .name = "chdir", .linkage = common.linkage, .visibility = common.visibility });
        @export(&chownLinux, .{ .name = "chown", .linkage = common.linkage, .visibility = common.visibility });
        @export(&fchownatLinux, .{ .name = "fchownat", .linkage = common.linkage, .visibility = common.visibility });
        @export(&lchownLinux, .{ .name = "lchown", .linkage = common.linkage, .visibility = common.visibility });
        @export(&chrootLinux, .{ .name = "chroot", .linkage = common.linkage, .visibility = common.visibility });
        @export(&ctermidLinux, .{ .name = "ctermid", .linkage = common.linkage, .visibility = common.visibility });
        @export(&dupLinux, .{ .name = "dup", .linkage = common.linkage, .visibility = common.visibility });

        @export(&getegidLinux, .{ .name = "getegid", .linkage = common.linkage, .visibility = common.visibility });
        @export(&geteuidLinux, .{ .name = "geteuid", .linkage = common.linkage, .visibility = common.visibility });
        @export(&getgidLinux, .{ .name = "getgid", .linkage = common.linkage, .visibility = common.visibility });
        @export(&getgroupsLinux, .{ .name = "getgroups", .linkage = common.linkage, .visibility = common.visibility });
        @export(&getpgidLinux, .{ .name = "getpgid", .linkage = common.linkage, .visibility = common.visibility });
        @export(&getpgrpLinux, .{ .name = "getpgrp", .linkage = common.linkage, .visibility = common.visibility });
        @export(&setpgidLinux, .{ .name = "setpgid", .linkage = common.linkage, .visibility = common.visibility });
        @export(&setpgrpLinux, .{ .name = "setpgrp", .linkage = common.linkage, .visibility = common.visibility });
        @export(&getsidLinux, .{ .name = "getsid", .linkage = common.linkage, .visibility = common.visibility });
        @export(&getpidLinux, .{ .name = "getpid", .linkage = common.linkage, .visibility = common.visibility });
        @export(&getppidLinux, .{ .name = "getppid", .linkage = common.linkage, .visibility = common.visibility });
        @export(&getuidLinux, .{ .name = "getuid", .linkage = common.linkage, .visibility = common.visibility });

        @export(&rmdirLinux, .{ .name = "rmdir", .linkage = common.linkage, .visibility = common.visibility });
        @export(&linkLinux, .{ .name = "link", .linkage = common.linkage, .visibility = common.visibility });
        @export(&linkatLinux, .{ .name = "linkat", .linkage = common.linkage, .visibility = common.visibility });
        @export(&pipeLinux, .{ .name = "pipe", .linkage = common.linkage, .visibility = common.visibility });
        @export(&renameatLinux, .{ .name = "renameat", .linkage = common.linkage, .visibility = common.visibility });
        @export(&symlinkLinux, .{ .name = "symlink", .linkage = common.linkage, .visibility = common.visibility });
        @export(&symlinkatLinux, .{ .name = "symlinkat", .linkage = common.linkage, .visibility = common.visibility });
        @export(&syncLinux, .{ .name = "sync", .linkage = common.linkage, .visibility = common.visibility });
        @export(&unlinkLinux, .{ .name = "unlink", .linkage = common.linkage, .visibility = common.visibility });
        @export(&unlinkatLinux, .{ .name = "unlinkat", .linkage = common.linkage, .visibility = common.visibility });

        @export(&execveLinux, .{ .name = "execve", .linkage = common.linkage, .visibility = common.visibility });
    }
}

fn _exit(exit_code: c_int) callconv(.c) noreturn {
    std.c._Exit(exit_code);
}

fn accessLinux(path: [*:0]const c_char, amode: c_int) callconv(.c) c_int {
    return common.errno(linux.access(@ptrCast(path), @bitCast(amode)));
}

fn acctLinux(path: [*:0]const c_char) callconv(.c) c_int {
    return common.errno(linux.acct(@ptrCast(path)));
}

fn chdirLinux(path: [*:0]const c_char) callconv(.c) c_int {
    return common.errno(linux.chdir(@ptrCast(path)));
}

fn chownLinux(path: [*:0]const c_char, uid: linux.uid_t, gid: linux.gid_t) callconv(.c) c_int {
    return common.errno(linux.chown(@ptrCast(path), uid, gid));
}

fn fchownatLinux(fd: c_int, path: [*:0]const c_char, uid: linux.uid_t, gid: linux.gid_t, flags: c_int) callconv(.c) c_int {
    return common.errno(linux.fchownat(fd, @ptrCast(path), uid, gid, @bitCast(flags)));
}

fn lchownLinux(path: [*:0]const c_char, uid: linux.uid_t, gid: linux.gid_t) callconv(.c) c_int {
    return common.errno(linux.lchown(@ptrCast(path), uid, gid));
}

fn chrootLinux(path: [*:0]const c_char) callconv(.c) c_int {
    return common.errno(linux.chroot(@ptrCast(path)));
}

fn ctermidLinux(maybe_path: ?[*]c_char) callconv(.c) [*:0]c_char {
    const default_tty = "/dev/tty";

    return if (maybe_path) |path| blk: {
        path[0..(default_tty.len + 1)].* = @bitCast(default_tty.*);
        break :blk path[0..default_tty.len :0].ptr;
    } else @ptrCast(@constCast(default_tty));
}

fn dupLinux(fd: c_int) callconv(.c) c_int {
    return common.errno(linux.dup(fd));
}

fn getegidLinux() callconv(.c) linux.gid_t {
    return linux.getegid();
}

fn geteuidLinux() callconv(.c) linux.uid_t {
    return linux.geteuid();
}

fn getgidLinux() callconv(.c) linux.gid_t {
    return linux.getgid();
}

fn getgroupsLinux(size: c_int, list: ?[*]linux.gid_t) callconv(.c) c_int {
    return common.errno(linux.getgroups(@intCast(size), list));
}

fn getpgidLinux(pid: linux.pid_t) callconv(.c) linux.pid_t {
    return common.errno(linux.getpgid(pid));
}

fn getpgrpLinux() callconv(.c) linux.pid_t {
    return @intCast(linux.getpgid(0)); // @intCast as it cannot fail
}

fn setpgidLinux(pid: linux.pid_t, pgid: linux.pid_t) callconv(.c) c_int {
    return common.errno(linux.setpgid(pid, pgid));
}

fn setpgrpLinux() callconv(.c) linux.pid_t {
    return @intCast(linux.setpgid(0, 0)); // @intCast as it cannot fail
}

fn getpidLinux() callconv(.c) linux.pid_t {
    return linux.getpid();
}

fn getppidLinux() callconv(.c) linux.pid_t {
    return linux.getppid();
}

fn getsidLinux(pid: linux.pid_t) callconv(.c) linux.pid_t {
    return common.errno(linux.getsid(pid));
}

fn getuidLinux() callconv(.c) linux.uid_t {
    return linux.getuid();
}

fn linkLinux(old: [*:0]const c_char, new: [*:0]const c_char) callconv(.c) c_int {
    return common.errno(linux.link(@ptrCast(old), @ptrCast(new)));
}

fn linkatLinux(old_fd: c_int, old: [*:0]const c_char, new_fd: c_int, new: [*:0]const c_char, flags: c_int) callconv(.c) c_int {
    return common.errno(linux.linkat(old_fd, @ptrCast(old), new_fd, @ptrCast(new), @bitCast(flags)));
}

fn pipeLinux(fd: *[2]c_int) callconv(.c) c_int {
    return common.errno(linux.pipe(@ptrCast(fd)));
}

fn renameatLinux(old_fd: c_int, old: [*:0]const c_char, new_fd: c_int, new: [*:0]const c_char) callconv(.c) c_int {
    return common.errno(linux.renameat(old_fd, @ptrCast(old), new_fd, @ptrCast(new)));
}

fn rmdirLinux(path: [*:0]const c_char) callconv(.c) c_int {
    return common.errno(linux.rmdir(@ptrCast(path)));
}

fn symlinkLinux(existing: [*:0]const c_char, new: [*:0]const c_char) callconv(.c) c_int {
    return common.errno(linux.symlink(@ptrCast(existing), @ptrCast(new)));
}

fn symlinkatLinux(existing: [*:0]const c_char, fd: c_int, new: [*:0]const c_char) callconv(.c) c_int {
    return common.errno(linux.symlinkat(@ptrCast(existing), fd, @ptrCast(new)));
}

fn syncLinux() callconv(.c) void {
    linux.sync();
}

fn unlinkLinux(path: [*:0]const c_char) callconv(.c) c_int {
    return common.errno(linux.unlink(@ptrCast(path)));
}

fn unlinkatLinux(fd: c_int, path: [*:0]const c_char, flags: c_int) callconv(.c) c_int {
    return common.errno(linux.unlinkat(fd, @ptrCast(path), @bitCast(flags)));
}

fn execveLinux(path: [*:0]const c_char, argv: [*:null]const ?[*:0]c_char, envp: [*:null]const ?[*:0]c_char) callconv(.c) c_int {
    return common.errno(linux.execve(@ptrCast(path), @ptrCast(argv), @ptrCast(envp)));
}
