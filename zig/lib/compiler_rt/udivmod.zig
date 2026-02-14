const builtin = @import("builtin");

const std = @import("std");
const Log2Int = std.math.Log2Int;

const compiler_rt = @import("../compiler_rt.zig");
const symbol = compiler_rt.symbol;
const HalveInt = compiler_rt.HalveInt;

comptime {
    if (compiler_rt.want_windows_v2u64_abi) {
        symbol(&__umodti3_windows_x86_64, "__umodti3");
        symbol(&__modti3_windows_x86_64, "__modti3");
        symbol(&__udivti3_windows_x86_64, "__udivti3");
        symbol(&__divti3_windows_x86_64, "__divti3");
        symbol(&__udivmodti4_windows_x86_64, "__udivmodti4");
    } else {
        symbol(&__umodti3, "__umodti3");
        symbol(&__modti3, "__modti3");
        symbol(&__udivti3, "__udivti3");
        symbol(&__divti3, "__divti3");
        symbol(&__udivmodti4, "__udivmodti4");
    }
}

const v128 = @Vector(2, u64);
const v2u64 = @Vector(2, u64);

pub fn __udivmodti4(a: u128, b: u128, maybe_rem: ?*u128) callconv(.c) u128 {
    return udivmod(u128, a, b, maybe_rem);
}

fn __udivmodti4_windows_x86_64(a: v2u64, b: v2u64, maybe_rem: ?*u128) callconv(.c) v2u64 {
    return @bitCast(udivmod(u128, @bitCast(a), @bitCast(b), maybe_rem));
}

pub fn __divti3(a: i128, b: i128) callconv(.c) i128 {
    return div(a, b);
}

fn __divti3_windows_x86_64(a: v128, b: v128) callconv(.c) v128 {
    return @bitCast(div(@bitCast(a), @bitCast(b)));
}

inline fn div(a: i128, b: i128) i128 {
    const s_a = a >> (128 - 1);
    const s_b = b >> (128 - 1);

    const an = (a ^ s_a) -% s_a;
    const bn = (b ^ s_b) -% s_b;

    const r = udivmod(u128, @bitCast(an), @bitCast(bn), null);
    const s = s_a ^ s_b;
    return (@as(i128, @bitCast(r)) ^ s) -% s;
}

pub fn __udivti3(a: u128, b: u128) callconv(.c) u128 {
    return udivmod(u128, a, b, null);
}

fn __udivti3_windows_x86_64(a: v2u64, b: v2u64) callconv(.c) v2u64 {
    return @bitCast(udivmod(u128, @bitCast(a), @bitCast(b), null));
}

pub fn __modti3(a: i128, b: i128) callconv(.c) i128 {
    return mod(a, b);
}

fn __modti3_windows_x86_64(a: v2u64, b: v2u64) callconv(.c) v2u64 {
    return @bitCast(mod(@as(i128, @bitCast(a)), @as(i128, @bitCast(b))));
}

inline fn mod(a: i128, b: i128) i128 {
    const s_a = a >> (128 - 1); // s = a < 0 ? -1 : 0
    const s_b = b >> (128 - 1); // s = b < 0 ? -1 : 0

    const an = (a ^ s_a) -% s_a; // negate if s == -1
    const bn = (b ^ s_b) -% s_b; // negate if s == -1

    var r: u128 = undefined;
    _ = udivmod(u128, @as(u128, @bitCast(an)), @as(u128, @bitCast(bn)), &r);
    return (@as(i128, @bitCast(r)) ^ s_a) -% s_a; // negate if s == -1
}

pub fn __umodti3(a: u128, b: u128) callconv(.c) u128 {
    var r: u128 = undefined;
    _ = udivmod(u128, a, b, &r);
    return r;
}

fn __umodti3_windows_x86_64(a: v2u64, b: v2u64) callconv(.c) v2u64 {
    var r: u128 = undefined;
    _ = udivmod(u128, @bitCast(a), @bitCast(b), &r);
    return @bitCast(r);
}

const lo = switch (builtin.cpu.arch.endian()) {
    .big => 1,
    .little => 0,
};
const hi = 1 - lo;

// Let _u1 and _u0 be the high and low limbs of U respectively.
// Returns U / v_ and sets r = U % v_.
fn divwide_generic(comptime T: type, _u1: T, _u0: T, v_: T, r: *T) T {
    const HalfT = HalveInt(T, false).HalfT;
    @setRuntimeSafety(compiler_rt.test_safety);
    var v = v_;

    const b = @as(T, 1) << (@bitSizeOf(T) / 2);
    var un64: T = undefined;
    var un10: T = undefined;

    const s: Log2Int(T) = @intCast(@clz(v));
    if (s > 0) {
        // Normalize divisor
        v <<= s;
        un64 = (_u1 << s) | (_u0 >> @intCast((@bitSizeOf(T) - @as(T, @intCast(s)))));
        un10 = _u0 << s;
    } else {
        // Avoid undefined behavior of (u0 >> @bitSizeOf(T))
        un64 = _u1;
        un10 = _u0;
    }

    // Break divisor up into two 32-bit digits
    const vn1 = v >> (@bitSizeOf(T) / 2);
    const vn0 = v & std.math.maxInt(HalfT);

    // Break right half of dividend into two digits
    const un1 = un10 >> (@bitSizeOf(T) / 2);
    const un0 = un10 & std.math.maxInt(HalfT);

    // Compute the first quotient digit, q1
    var q1 = un64 / vn1;
    var rhat = un64 -% q1 *% vn1;

    // q1 has at most error 2. No more than 2 iterations
    while (q1 >= b or q1 * vn0 > b * rhat + un1) {
        q1 -= 1;
        rhat += vn1;
        if (rhat >= b) break;
    }

    const un21 = un64 *% b +% un1 -% q1 *% v;

    // Compute the second quotient digit
    var q0 = un21 / vn1;
    rhat = un21 -% q0 *% vn1;

    // q0 has at most error 2. No more than 2 iterations.
    while (q0 >= b or q0 * vn0 > b * rhat + un0) {
        q0 -= 1;
        rhat += vn1;
        if (rhat >= b) break;
    }

    r.* = (un21 *% b +% un0 -% q0 *% v) >> s;
    return q1 *% b +% q0;
}

fn divwide(comptime T: type, _u1: T, _u0: T, v: T, r: *T) T {
    @setRuntimeSafety(compiler_rt.test_safety);
    if (T == u64 and builtin.target.cpu.arch == .x86_64 and builtin.target.os.tag != .windows) {
        var rem: T = undefined;
        const quo = asm (
            \\divq %[v]
            : [_] "={rax}" (-> T),
              [_] "={rdx}" (rem),
            : [v] "r" (v),
              [_] "{rax}" (_u0),
              [_] "{rdx}" (_u1),
        );
        r.* = rem;
        return quo;
    } else {
        return divwide_generic(T, _u1, _u0, v, r);
    }
}

// Returns a_ / b_ and sets maybe_rem = a_ % b.
pub fn udivmod(comptime T: type, a_: T, b_: T, maybe_rem: ?*T) T {
    @setRuntimeSafety(compiler_rt.test_safety);
    const HalfT = HalveInt(T, false).HalfT;
    const SignedT = std.meta.Int(.signed, @bitSizeOf(T));

    if (b_ > a_) {
        if (maybe_rem) |rem| {
            rem.* = a_;
        }
        return 0;
    }

    const a: [2]HalfT = @bitCast(a_);
    const b: [2]HalfT = @bitCast(b_);
    var q: [2]HalfT = undefined;
    var r: [2]HalfT = undefined;

    // When the divisor fits in 64 bits, we can use an optimized path
    if (b[hi] == 0) {
        r[hi] = 0;
        if (a[hi] < b[lo]) {
            // The result fits in 64 bits
            q[hi] = 0;
            q[lo] = divwide(HalfT, a[hi], a[lo], b[lo], &r[lo]);
        } else {
            // First, divide with the high part to get the remainder. After that a_hi < b_lo.
            q[hi] = a[hi] / b[lo];
            q[lo] = divwide(HalfT, a[hi] % b[lo], a[lo], b[lo], &r[lo]);
        }
        if (maybe_rem) |rem| {
            rem.* = @bitCast(r);
        }
        return @bitCast(q);
    }

    // 0 <= shift <= 63
    const shift: Log2Int(T) = @clz(b[hi]) - @clz(a[hi]);
    var af: T = @bitCast(a);
    var bf = @as(T, @bitCast(b)) << shift;
    q = @bitCast(@as(T, 0));

    for (0..shift + 1) |_| {
        q[lo] <<= 1;
        // Branchless version of:
        // if (af >= bf) {
        //     af -= bf;
        //     q[lo] |= 1;
        // }
        const s = @as(SignedT, @bitCast(bf -% af -% 1)) >> (@bitSizeOf(T) - 1);
        q[lo] |= @intCast(s & 1);
        af -= bf & @as(T, @bitCast(s));
        bf >>= 1;
    }
    if (maybe_rem) |rem| {
        rem.* = @bitCast(af);
    }
    return @bitCast(q);
}

test {
    _ = @import("modti3_test.zig");
    _ = @import("divti3_test.zig");
    _ = @import("udivmodti4_test.zig");
}
