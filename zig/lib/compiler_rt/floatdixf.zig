const common = @import("./common.zig");
const floatFromInt = @import("./float_from_int.zig").floatFromInt;

comptime {
    @export(&__floatdixf, .{ .name = "__floatdixf", .linkage = common.linkage, .visibility = common.visibility });
}

fn __floatdixf(a: i64) callconv(.c) f80 {
    return floatFromInt(f80, a);
}
