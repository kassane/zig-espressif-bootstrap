const common = @import("./common.zig");
const trunc_f80 = @import("./truncf.zig").trunc_f80;

comptime {
    @export(&__truncxfhf2, .{ .name = "__truncxfhf2", .linkage = common.linkage, .visibility = common.visibility });
}

fn __truncxfhf2(a: f80) callconv(.c) common.F16T(f80) {
    return @bitCast(trunc_f80(f16, a));
}
