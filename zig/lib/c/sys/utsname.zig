const std = @import("std");
const common = @import("../common.zig");
const builtin = @import("builtin");

comptime {
    if (builtin.target.isMuslLibC()) {
        @export(&unameLinux, .{ .name = "uname", .linkage = common.linkage, .visibility = common.visibility });
    }

    if (builtin.target.isWasiLibC()) {
        @export(&unameWasi, .{ .name = "uname", .linkage = common.linkage, .visibility = common.visibility });
    }
}

fn unameLinux(uts: *std.os.linux.utsname) callconv(.c) c_int {
    return common.errno(std.os.linux.uname(uts));
}

fn unameWasi(uts: *std.c.utsname) callconv(.c) c_int {
    // note the @bitCast's for NUL termination!
    uts.sysname[0..5].* = @bitCast("wasi".*);
    uts.nodename[0..7].* = @bitCast("(none)".*);
    uts.release[0..6].* = @bitCast("0.0.0".*);
    uts.version[0..6].* = @bitCast("0.0.0".*);
    uts.machine[0..7].* = @bitCast(switch (builtin.target.cpu.arch) {
        .wasm32 => "wasm32",
        .wasm64 => "wasm64",
        else => comptime unreachable,
    }.*);
    uts.domainname[0..7].* = @bitCast("(none)".*);
    return 0;
}
