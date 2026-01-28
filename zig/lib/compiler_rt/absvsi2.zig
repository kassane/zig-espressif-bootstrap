const common = @import("./common.zig");
const absv = @import("./absv.zig").absv;

comptime {
    @export(&__absvsi2, .{ .name = "__absvsi2", .linkage = common.linkage, .visibility = common.visibility });
}

pub fn __absvsi2(a: i32) callconv(.c) i32 {
    return absv(i32, a);
}
