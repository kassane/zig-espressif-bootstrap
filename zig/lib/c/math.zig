const builtin = @import("builtin");

const std = @import("std");
const math = std.math;

const symbol = @import("../c.zig").symbol;

comptime {
    if (builtin.target.isMinGW()) {
        symbol(&isnan, "isnan");
        symbol(&isnan, "__isnan");
        symbol(&isnanf, "isnanf");
        symbol(&isnanf, "__isnanf");
        symbol(&isnanl, "isnanl");
        symbol(&isnanl, "__isnanl");

        symbol(&math.nan(f64), "__QNAN");
        symbol(&math.snan(f64), "__SNAN");
        symbol(&math.inf(f64), "__INF");
        symbol(&math.floatTrueMin(f64), "__DENORM");

        symbol(&math.nan(f32), "__QNANF");
        symbol(&math.snan(f32), "__SNANF");
        symbol(&math.inf(f32), "__INFF");
        symbol(&math.floatTrueMin(f32), "__DENORMF");

        symbol(&math.nan(c_longdouble), "__QNANL");
        symbol(&math.snan(c_longdouble), "__SNANL");
        symbol(&math.inf(c_longdouble), "__INFL");
        symbol(&math.floatTrueMin(c_longdouble), "__DENORML");
    }

    if (builtin.target.isMinGW() or builtin.target.isMuslLibC() or builtin.target.isWasiLibC()) {
        symbol(&hypotf, "hypotf");
        symbol(&hypotl, "hypotl");
        symbol(&nan, "nan");
        symbol(&nanf, "nanf");
        symbol(&nanl, "nanl");
    }

    if (builtin.target.isMuslLibC() or builtin.target.isWasiLibC()) {
        symbol(&acos, "acos");
        symbol(&atanf, "atanf");
        symbol(&atan, "atan");
        symbol(&atanl, "atanl");
        symbol(&cbrt, "cbrt");
        symbol(&cbrtf, "cbrtf");
        symbol(&exp10, "exp10");
        symbol(&exp10f, "exp10f");
        symbol(&hypot, "hypot");
        symbol(&pow, "pow");
        symbol(&pow10, "pow10");
        symbol(&pow10f, "pow10f");
        symbol(&acosf, "acosf");
    }

    if (builtin.target.isMuslLibC()) {
        symbol(&copysignf, "copysignf");
        symbol(&copysign, "copysign");
        symbol(&rint, "rint");
    }
    symbol(&copysignl, "copysignl");
}

fn acos(x: f64) callconv(.c) f64 {
    return math.acos(x);
}

fn atanf(x: f32) callconv(.c) f32 {
    return math.atan(x);
}

fn atan(x: f64) callconv(.c) f64 {
    return math.atan(x);
}

fn atanl(x: c_longdouble) callconv(.c) c_longdouble {
    return switch (@typeInfo(@TypeOf(x)).float.bits) {
        16 => math.atan(@as(f16, @floatCast(x))),
        32 => math.atan(@as(f32, @floatCast(x))),
        64 => math.atan(@as(f64, @floatCast(x))),
        80 => math.atan(@as(f80, @floatCast(x))),
        128 => math.atan(@as(f128, @floatCast(x))),
        else => unreachable,
    };
}

fn acosf(x: f32) callconv(.c) f32 {
    return std.math.acos(x);
}

fn isnan(x: f64) callconv(.c) c_int {
    return if (math.isNan(x)) 1 else 0;
}

fn isnanf(x: f32) callconv(.c) c_int {
    return if (math.isNan(x)) 1 else 0;
}

fn isnanl(x: c_longdouble) callconv(.c) c_int {
    return if (math.isNan(x)) 1 else 0;
}

fn nan(_: [*:0]const c_char) callconv(.c) f64 {
    return math.nan(f64);
}

fn nanf(_: [*:0]const c_char) callconv(.c) f32 {
    return math.nan(f32);
}

fn nanl(_: [*:0]const c_char) callconv(.c) c_longdouble {
    return math.nan(c_longdouble);
}

fn copysignf(x: f32, y: f32) callconv(.c) f32 {
    return math.copysign(x, y);
}

fn copysign(x: f64, y: f64) callconv(.c) f64 {
    return math.copysign(x, y);
}

fn copysignl(x: c_longdouble, y: c_longdouble) callconv(.c) c_longdouble {
    return math.copysign(x, y);
}

fn cbrt(x: f64) callconv(.c) f64 {
    return math.cbrt(x);
}

fn cbrtf(x: f32) callconv(.c) f32 {
    return math.cbrt(x);
}

fn exp10(x: f64) callconv(.c) f64 {
    return math.pow(f64, 10.0, x);
}

fn exp10f(x: f32) callconv(.c) f32 {
    return math.pow(f32, 10.0, x);
}

fn hypot(x: f64, y: f64) callconv(.c) f64 {
    return math.hypot(x, y);
}

fn hypotf(x: f32, y: f32) callconv(.c) f32 {
    return math.hypot(x, y);
}

fn hypotl(x: c_longdouble, y: c_longdouble) callconv(.c) c_longdouble {
    return math.hypot(x, y);
}

fn pow(x: f64, y: f64) callconv(.c) f64 {
    return math.pow(f64, x, y);
}

fn pow10(x: f64) callconv(.c) f64 {
    return exp10(x);
}

fn pow10f(x: f32) callconv(.c) f32 {
    return exp10f(x);
}

fn rint(x: f64) callconv(.c) f64 {
    const toint: f64 = 1.0 / @as(f64, std.math.floatEps(f64));
    const a: u64 = @bitCast(x);
    const e = a >> 52 & 0x7ff;
    const s = a >> 63;
    var y: f64 = undefined;

    if (e >= 0x3ff + 52) {
        return x;
    }
    if (s == 1) {
        y = x - toint + toint;
    } else {
        y = x + toint - toint;
    }
    if (y == 0) {
        return if (s == 1) -0.0 else 0;
    }
    return y;
}

test "rint" {
    // Positive numbers round correctly
    try std.testing.expectEqual(@as(f64, 42.0), rint(42.2));
    try std.testing.expectEqual(@as(f64, 42.0), rint(41.8));

    // Negative numbers round correctly
    try std.testing.expectEqual(@as(f64, -6.0), rint(-5.9));
    try std.testing.expectEqual(@as(f64, -6.0), rint(-6.1));

    // No rounding needed test
    try std.testing.expectEqual(@as(f64, 5.0), rint(5.0));
    try std.testing.expectEqual(@as(f64, -10.0), rint(-10.0));
    try std.testing.expectEqual(@as(f64, 0.0), rint(0.0));

    // Very large numbers return unchanged
    const large: f64 = 9007199254740992.0; // 2^53
    try std.testing.expectEqual(large, rint(large));
    try std.testing.expectEqual(-large, rint(-large));

    // Small positive numbers round to zero
    const pos_result = rint(0.3);
    try std.testing.expectEqual(@as(f64, 0.0), pos_result);
    try std.testing.expect(@as(u64, @bitCast(pos_result)) == 0);

    // Small negative numbers round to negative zero
    const neg_result = rint(-0.3);
    try std.testing.expectEqual(@as(f64, 0.0), neg_result);
    const bits: u64 = @bitCast(neg_result);
    try std.testing.expect((bits >> 63) == 1);

    // Exact half rounds to nearest even (banker's rounding)
    try std.testing.expectEqual(@as(f64, 2.0), rint(2.5));
    try std.testing.expectEqual(@as(f64, 4.0), rint(3.5));
}
