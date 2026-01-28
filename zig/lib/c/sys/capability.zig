const std = @import("std");
const common = @import("../common.zig");
const builtin = @import("builtin");

comptime {
    if (builtin.target.isMuslLibC()) {
        @export(&capsetLinux, .{ .name = "capset", .linkage = common.linkage, .visibility = common.visibility });
        @export(&capgetLinux, .{ .name = "capget", .linkage = common.linkage, .visibility = common.visibility });
    }
}

fn capsetLinux(hdrp: *anyopaque, datap: *anyopaque) callconv(.c) c_int {
    return common.errno(std.os.linux.capset(@ptrCast(@alignCast(hdrp)), @ptrCast(@alignCast(datap))));
}

fn capgetLinux(hdrp: *anyopaque, datap: *anyopaque) callconv(.c) c_int {
    return common.errno(std.os.linux.capget(@ptrCast(@alignCast(hdrp)), @ptrCast(@alignCast(datap))));
}
