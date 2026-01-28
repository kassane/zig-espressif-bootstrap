const std = @import("std");
const common = @import("common.zig");
const builtin = @import("builtin");

comptime {
    if (builtin.target.isMinGW()) {
        @export(&isnan, .{ .name = "isnan", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isnan, .{ .name = "__isnan", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isnanf, .{ .name = "isnanf", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isnanf, .{ .name = "__isnanf", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isnanl, .{ .name = "isnanl", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isnanl, .{ .name = "__isnanl", .linkage = common.linkage, .visibility = common.visibility });

        @export(&std.math.nan(f64), .{ .name = "__QNAN", .linkage = common.linkage, .visibility = common.visibility });
        @export(&std.math.snan(f64), .{ .name = "__SNAN", .linkage = common.linkage, .visibility = common.visibility });
        @export(&std.math.inf(f64), .{ .name = "__INF", .linkage = common.linkage, .visibility = common.visibility });
        @export(&std.math.floatTrueMin(f64), .{ .name = "__DENORM", .linkage = common.linkage, .visibility = common.visibility });

        @export(&std.math.nan(f32), .{ .name = "__QNANF", .linkage = common.linkage, .visibility = common.visibility });
        @export(&std.math.snan(f32), .{ .name = "__SNANF", .linkage = common.linkage, .visibility = common.visibility });
        @export(&std.math.inf(f32), .{ .name = "__INFF", .linkage = common.linkage, .visibility = common.visibility });
        @export(&std.math.floatTrueMin(f32), .{ .name = "__DENORMF", .linkage = common.linkage, .visibility = common.visibility });

        @export(&std.math.nan(c_longdouble), .{ .name = "__QNANL", .linkage = common.linkage, .visibility = common.visibility });
        @export(&std.math.snan(c_longdouble), .{ .name = "__SNANL", .linkage = common.linkage, .visibility = common.visibility });
        @export(&std.math.inf(c_longdouble), .{ .name = "__INFL", .linkage = common.linkage, .visibility = common.visibility });
        @export(&std.math.floatTrueMin(c_longdouble), .{ .name = "__DENORML", .linkage = common.linkage, .visibility = common.visibility });
    }

    if (builtin.target.isMinGW() or builtin.target.isMuslLibC() or builtin.target.isWasiLibC()) {
        @export(&nan, .{ .name = "nan", .linkage = common.linkage, .visibility = common.visibility });
        @export(&nanf, .{ .name = "nanf", .linkage = common.linkage, .visibility = common.visibility });
        @export(&nanl, .{ .name = "nanl", .linkage = common.linkage, .visibility = common.visibility });
    }

    if (builtin.target.isMuslLibC() or builtin.target.isWasiLibC()) {
        @export(&acos, .{ .name = "acos", .linkage = common.linkage, .visibility = common.visibility });
    }

    if (builtin.target.isMuslLibC()) {
        @export(&copysignf, .{ .name = "copysignf", .linkage = common.linkage, .visibility = common.visibility });
        @export(&copysign, .{ .name = "copysign", .linkage = common.linkage, .visibility = common.visibility });
    }
    @export(&copysignl, .{ .name = "copysignl", .linkage = common.linkage, .visibility = common.visibility });
}

fn acos(x: f64) callconv(.c) f64 {
    return std.math.acos(x);
}

fn isnan(x: f64) callconv(.c) c_int {
    return if (std.math.isNan(x)) 1 else 0;
}

fn isnanf(x: f32) callconv(.c) c_int {
    return if (std.math.isNan(x)) 1 else 0;
}

fn isnanl(x: c_longdouble) callconv(.c) c_int {
    return if (std.math.isNan(x)) 1 else 0;
}

fn nan(_: [*:0]const c_char) callconv(.c) f64 {
    return std.math.nan(f64);
}

fn nanf(_: [*:0]const c_char) callconv(.c) f32 {
    return std.math.nan(f32);
}

fn nanl(_: [*:0]const c_char) callconv(.c) c_longdouble {
    return std.math.nan(c_longdouble);
}

fn copysignf(x: f32, y: f32) callconv(.c) f32 {
    return std.math.copysign(x, y);
}

fn copysign(x: f64, y: f64) callconv(.c) f64 {
    return std.math.copysign(x, y);
}

fn copysignl(x: c_longdouble, y: c_longdouble) callconv(.c) c_longdouble {
    return std.math.copysign(x, y);
}
