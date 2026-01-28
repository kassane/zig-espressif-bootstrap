const std = @import("std");
const common = @import("../common.zig");
const builtin = @import("builtin");

comptime {
    if (builtin.target.isMuslLibC()) {
        @export(&flockLinux, .{ .name = "flock", .linkage = common.linkage, .visibility = common.visibility });
    }
}

fn flockLinux(fd: c_int, operation: c_int) callconv(.c) c_int {
    return common.errno(std.os.linux.flock(fd, operation));
}
