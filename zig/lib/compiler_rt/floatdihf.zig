const common = @import("./common.zig");
const floatFromInt = @import("./float_from_int.zig").floatFromInt;

comptime {
    @export(&__floatdihf, .{ .name = "__floatdihf", .linkage = common.linkage, .visibility = common.visibility });
}

fn __floatdihf(a: i64) callconv(.c) f16 {
    return floatFromInt(f16, a);
}
