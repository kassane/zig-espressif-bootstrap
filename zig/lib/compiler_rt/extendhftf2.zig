const common = @import("./common.zig");
const extendf = @import("./extendf.zig").extendf;

comptime {
    @export(&__extendhftf2, .{ .name = "__extendhftf2", .linkage = common.linkage, .visibility = common.visibility });
}

pub fn __extendhftf2(a: common.F16T(f128)) callconv(.c) f128 {
    return extendf(f128, f16, @as(u16, @bitCast(a)));
}
