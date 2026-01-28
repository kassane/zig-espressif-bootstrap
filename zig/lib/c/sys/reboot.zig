const std = @import("std");
const common = @import("../common.zig");
const builtin = @import("builtin");

comptime {
    if (builtin.target.isMuslLibC()) {
        @export(&rebootLinux, .{ .name = "reboot", .linkage = common.linkage, .visibility = common.visibility });
    }
}

fn rebootLinux(cmd: c_int) callconv(.c) c_int {
    return common.errno(std.os.linux.reboot(.MAGIC1, .MAGIC2, @enumFromInt(cmd), null));
}
