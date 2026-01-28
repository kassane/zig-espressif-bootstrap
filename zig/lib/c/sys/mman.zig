const std = @import("std");
const common = @import("../common.zig");
const builtin = @import("builtin");

comptime {
    if (builtin.target.isMuslLibC()) {
        @export(&madviseLinux, .{ .name = "madvise", .linkage = common.linkage, .visibility = common.visibility });
        @export(&madviseLinux, .{ .name = "__madvise", .linkage = common.linkage, .visibility = common.visibility });

        @export(&mincoreLinux, .{ .name = "mincore", .linkage = common.linkage, .visibility = common.visibility });

        @export(&mlockLinux, .{ .name = "mlock", .linkage = common.linkage, .visibility = common.visibility });
        @export(&mlockallLinux, .{ .name = "mlockall", .linkage = common.linkage, .visibility = common.visibility });

        @export(&mprotectLinux, .{ .name = "mprotect", .linkage = common.linkage, .visibility = common.visibility });
        @export(&mprotectLinux, .{ .name = "__mprotect", .linkage = common.linkage, .visibility = common.visibility });

        @export(&munlockLinux, .{ .name = "munlock", .linkage = common.linkage, .visibility = common.visibility });
        @export(&munlockallLinux, .{ .name = "munlockall", .linkage = common.linkage, .visibility = common.visibility });

        @export(&posix_madviseLinux, .{ .name = "posix_madvise", .linkage = common.linkage, .visibility = common.visibility });
    }
}

fn madviseLinux(addr: *anyopaque, len: usize, advice: c_int) callconv(.c) c_int {
    return common.errno(std.os.linux.madvise(@ptrCast(addr), len, @bitCast(advice)));
}

fn mincoreLinux(addr: *anyopaque, len: usize, vec: [*]u8) callconv(.c) c_int {
    return common.errno(std.os.linux.mincore(@ptrCast(addr), len, vec));
}

fn mlockLinux(addr: *const anyopaque, len: usize) callconv(.c) c_int {
    return common.errno(std.os.linux.mlock(@ptrCast(addr), len));
}

fn mlockallLinux(flags: c_int) callconv(.c) c_int {
    return common.errno(std.os.linux.mlockall(@bitCast(flags)));
}

fn mprotectLinux(addr: *anyopaque, len: usize, prot: c_int) callconv(.c) c_int {
    const page_size = std.heap.pageSize();
    const start = std.mem.alignBackward(usize, @intFromPtr(addr), page_size);
    const aligned_len = std.mem.alignForward(usize, len, page_size);
    return common.errno(std.os.linux.mprotect(@ptrFromInt(start), aligned_len, @bitCast(prot)));
}

fn munlockLinux(addr: *const anyopaque, len: usize) callconv(.c) c_int {
    return common.errno(std.os.linux.munlock(@ptrCast(addr), len));
}

fn munlockallLinux() callconv(.c) c_int {
    return common.errno(std.os.linux.munlockall());
}

fn posix_madviseLinux(addr: *anyopaque, len: usize, advice: c_int) callconv(.c) c_int {
    if (advice == std.os.linux.MADV.DONTNEED) return 0;
    return @intCast(-@as(isize, @bitCast(std.os.linux.madvise(@ptrCast(addr), len, @bitCast(advice)))));
}
