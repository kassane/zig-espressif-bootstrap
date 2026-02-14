// Ported from musl, which is licensed under the MIT license:
// https://git.musl-libc.org/cgit/musl/tree/COPYRIGHT
//
// https://git.musl-libc.org/cgit/musl/tree/src/math/asinf.c
// https://git.musl-libc.org/cgit/musl/tree/src/math/asin.c
// https://git.musl-libc.org/cgit/musl/tree/src/math/asinl.c

const std = @import("../std.zig");
const math = std.math;
const mem = std.mem;
const testing = std.testing;
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

/// Returns the arc-sin of x.
///
/// Special Cases:
///  - asin(+-0) = +-0
///  - asin(x)   = nan if x < -1 or x > 1
pub fn asin(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    return switch (T) {
        f16 => asinBinary16(x),
        f32 => asinBinary32(x),
        f64 => asinBinary64(x),
        f80 => asinExtended80(x),
        f128 => asinBinary128(x),
        else => @compileError("asin not implemented for " ++ @typeName(T)),
    };
}

fn approxBinary16(z: f32) f32 {
    const S0: f32 = 1.0000001e0;
    const S1: f32 = 1.6664918e-1;
    const S2: f32 = 7.55022e-2;
    const S3: f32 = 3.9513987e-2;
    const S4: f32 = 5.0883885e-2;
    return S0 + z * (S1 + z * (S2 + z * (S3 + z * S4)));
}

fn asinBinary16(x: f16) f16 {
    const pio2: f32 = math.pi / 2.0;

    const hx: u16 = @bitCast(x);
    const ix = hx & 0x7fff;

    // |x| >= 1
    if (ix >= 0x3c00) {
        // |x| == 1
        if (ix == 0x3c00) {
            // asin(+-1) = +-pi/2 with inexact
            return @floatCast(x * pio2 + 0x1.0p-120);
        }
        // asin(|x| > 1) is nan
        return 0.0 / (x - x);
    }

    // |x| < 0.5
    if (ix < 0x3800) {
        return @floatCast(x * approxBinary16(x * x));
    }

    // 1 > |x| >= 0.5
    const z = (1.0 - @abs(x)) * 0.5;
    const s = @sqrt(z);
    const x_local = pio2 - 2.0 * s * approxBinary16(z);
    if (hx >> 15 != 0) {
        return @floatCast(-x_local);
    }
    return @floatCast(x_local);
}

fn rationalApproxBinary32(z: f32) f32 {
    const pS0: f32 = 1.6666586697e-01;
    const pS1: f32 = -4.2743422091e-02;
    const pS2: f32 = -8.6563630030e-03;
    const qS1: f32 = -7.0662963390e-01;

    const p = z * (pS0 + z * (pS1 + z * pS2));
    const q = 1.0 + z * qS1;
    return p / q;
}

fn asinBinary32(x: f32) f32 {
    const pio2: f64 = 1.570796326794896558e+00;

    const hx: u32 = @bitCast(x);
    const ix = hx & 0x7fff_ffff;

    // |x| >= 1
    if (ix >= 0x3f80_0000) {
        // |x| == 1
        if (ix == 0x3f80_0000) {
            // asin(+-1) = +-pi/2 with inexact
            return @floatCast(@as(f64, @floatCast(x)) * pio2 + 0x1.0p-120);
        }
        // asin(|x| > 1) is nan
        return 0.0 / (x - x);
    }

    // |x| < 0.5
    if (ix < 0x3f00_0000) {
        // 0x1p-126 <= |x| < 0x1p-12
        if (ix < 0x3980_0000 and ix >= 0x0080_0000) {
            return x;
        }
        return x + x * rationalApproxBinary32(x * x);
    }

    // 1 > |x| >= 0.5
    const z = (1.0 - @abs(x)) * 0.5;
    const s: f64 = @floatCast(@sqrt(z));
    const x_local: f32 = @floatCast(pio2 - 2.0 * (s + s * @as(f64, @floatCast(rationalApproxBinary32(z)))));
    return if (hx >> 31 != 0) -x_local else x_local;
}

fn rationalApproxBinary64(z: f64) f64 {
    const pS0: f64 = 1.66666666666666657415e-01;
    const pS1: f64 = -3.25565818622400915405e-01;
    const pS2: f64 = 2.01212532134862925881e-01;
    const pS3: f64 = -4.00555345006794114027e-02;
    const pS4: f64 = 7.91534994289814532176e-04;
    const pS5: f64 = 3.47933107596021167570e-05;
    const qS1: f64 = -2.40339491173441421878e+00;
    const qS2: f64 = 2.02094576023350569471e+00;
    const qS3: f64 = -6.88283971605453293030e-01;
    const qS4: f64 = 7.70381505559019352791e-02;

    const p = z * (pS0 + z * (pS1 + z * (pS2 + z * (pS3 + z * (pS4 + z * pS5)))));
    const q = 1.0 + z * (qS1 + z * (qS2 + z * (qS3 + z * qS4)));
    return p / q;
}

fn asinBinary64(x: f64) f64 {
    const pio2_hi: f64 = 1.57079632679489655800e+00;
    const pio2_lo: f64 = 6.12323399573676603587e-17;

    const hx: u32 = @intCast(@as(u64, @bitCast(x)) >> 32);
    const ix = hx & 0x7fffffff;

    // |x| >= 1 or nan
    if (ix >= 0x3ff0_0000) {
        const lx: u32 = @truncate(@as(u64, @bitCast(x)));
        // asin(1) = +-pi/2 with inexact
        if ((ix - 0x3ff0_0000 | lx) == 0) {
            return x * pio2_hi + 0x1.0p-120;
        }
        return 0.0 / (x - x);
    }

    // |x| < 0.5
    if (ix < 0x3fe0_0000) {
        // if 0x1p-1022 <= |x| < 0x1p-26 avoid raising overflow
        if (ix < 0x3e50_0000 and ix >= 0x0010_0000) {
            return x;
        }
        return x + x * rationalApproxBinary64(x * x);
    }

    // 1 > |x| >= 0.5
    const z = (1.0 - @abs(x)) * 0.5;
    const s = @sqrt(z);
    const r = rationalApproxBinary64(z);
    // |x| > 0.975
    if (ix >= 0x3fef_3333) {
        const x_local = pio2_hi - (2 * (s + s * r) - pio2_lo);
        return if (hx >> 31 != 0) -x_local else x_local;
    }
    // f+c = sqrt(z)
    const hs: u64 = @bitCast(s);
    const f: f64 = @bitCast(hs & 0xffff_ffff_0000_0000);
    const c: f64 = (z - f * f) / (s + f);
    const x_local = 0.5 * pio2_hi - (2.0 * s * r - (pio2_lo - 2.0 * c) - (0.5 * pio2_hi - 2.0 * f));
    return if (hx >> 31 != 0) -x_local else x_local;
}

fn rationalApproxExtended80(z: f80) f80 {
    const pS0: f80 = 1.66666666666666666631e-01;
    const pS1: f80 = -4.16313987993683104320e-01;
    const pS2: f80 = 3.69068046323246813704e-01;
    const pS3: f80 = -1.36213932016738603108e-01;
    const pS4: f80 = 1.78324189708471965733e-02;
    const pS5: f80 = -2.19216428382605211588e-04;
    const pS6: f80 = -7.10526623669075243183e-06;
    const qS1: f80 = -2.94788392796209867269e+00;
    const qS2: f80 = 3.27309890266528636716e+00;
    const qS3: f80 = -1.68285799854822427013e+00;
    const qS4: f80 = 3.90699412641738801874e-01;
    const qS5: f80 = -3.14365703596053263322e-02;

    const p = z * (pS0 + z * (pS1 + z * (pS2 + z * (pS3 + z * (pS4 + z * (pS5 + z * pS6))))));
    const q = 1.0 + z * (qS1 + z * (qS2 + z * (qS3 + z * (qS4 + z * qS5))));
    return p / q;
}

fn asinExtended80(x: f80) f80 {
    const pio2_hi: f80 = 1.57079632679489661926;
    const pio2_lo: f80 = -2.50827880633416601173e-20;

    const hx: u80 = @bitCast(x);
    const se: u16 = @truncate(hx >> 64);
    const e = se & 0x7fff;
    const sign = se >> 15 != 0;

    // |x| >= 1 or nan
    if (e >= 0x3fff) {
        // asin(+-1)=+-pi/2 with inexact
        if (x == 1.0 or x == -1.0) {
            return x * pio2_hi + 0x1p-120;
        }
        return 0.0 / (x - x);
    }

    // |x| < 0.5
    if (e < 0x3fff - 1) {
        if (e < 0x3fff - (math.floatMantissaBits(f80) + 1) / 2) {
            // return x with inexact if x!=0
            mem.doNotOptimizeAway(x + 0x1p120);
            return x;
        }
        return x + x * rationalApproxExtended80(x * x);
    }

    // 1 > |x| >= 0.5
    const z = (1.0 - @abs(x)) * 0.5;
    const s = @sqrt(z);
    const r = rationalApproxExtended80(z);

    const m: u64 = @truncate(hx & 0x0000_ffff_ffff_ffff_ffff);
    if ((m >> 56) >= 0xf7) {
        const x_local = pio2_hi - (2.0 * (s + s * r) - pio2_lo);
        return if (sign) -x_local else x_local;
    }

    const hs: u80 = @bitCast(s);
    const f: f80 = @bitCast(hs & 0xffff_ffff_ffff_0000_0000);
    const c = (z - f * f) / (s + f);
    const x_local = 0.5 * pio2_hi - (2.0 * s * r - (pio2_lo - 2.0 * c) - (0.5 * pio2_hi - 2.0 * f));
    return if (sign) -x_local else x_local;
}

fn rationalApproxBinary128(z: f128) f128 {
    const pS0: f128 = 1.66666666666666666666666666666700314e-01;
    const pS1: f128 = -7.32816946414566252574527475428622708e-01;
    const pS2: f128 = 1.34215708714992334609030036562143589e+00;
    const pS3: f128 = -1.32483151677116409805070261790752040e+00;
    const pS4: f128 = 7.61206183613632558824485341162121989e-01;
    const pS5: f128 = -2.56165783329023486777386833928147375e-01;
    const pS6: f128 = 4.80718586374448793411019434585413855e-02;
    const pS7: f128 = -4.42523267167024279410230886239774718e-03;
    const pS8: f128 = 1.44551535183911458253205638280410064e-04;
    const pS9: f128 = -2.10558957916600254061591040482706179e-07;
    const qS1: f128 = -4.84690167848739751544716485245697428e+00;
    const qS2: f128 = 9.96619113536172610135016921140206980e+00;
    const qS3: f128 = -1.13177895428973036660836798461641458e+01;
    const qS4: f128 = 7.74004374389488266169304117714658761e+00;
    const qS5: f128 = -3.25871986053534084709023539900339905e+00;
    const qS6: f128 = 8.27830318881232209752469022352928864e-01;
    const qS7: f128 = -1.18768052702942805423330715206348004e-01;
    const qS8: f128 = 8.32600764660522313269101537926539470e-03;
    const qS9: f128 = -1.99407384882605586705979504567947007e-04;

    const p = z * (pS0 + z * (pS1 + z * (pS2 + z * (pS3 + z * (pS4 + z * (pS5 + z * (pS6 + z * (pS7 + z * (pS8 + z * pS9)))))))));
    const q = 1.0 + z * (qS1 + z * (qS2 + z * (qS3 + z * (qS4 + z * (qS5 + z * (qS6 + z * (qS7 + z * (qS8 + z * qS9))))))));
    return p / q;
}

fn asinBinary128(x: f128) f128 {
    const pio2_hi: f128 = 1.57079632679489661923132169163975140;
    const pio2_lo: f128 = 4.33590506506189051239852201302167613e-35;

    const hx: u128 = @bitCast(x);
    const se: u16 = @truncate(hx >> 112);
    const e = se & 0x7fff;
    const sign = se >> 15 != 0;

    // |x| >= 1 or nan
    if (e >= 0x3fff) {
        // asin(+-1)=+-pi/2 with inexact
        if (x == 1.0 or x == -1.0) {
            return x * pio2_hi + 0x1p-120;
        }
        return 0.0 / (x - x);
    }

    // |x| < 0.5
    if (e < 0x3fff - 1) {
        if (e < 0x3fff - (math.floatMantissaBits(f128) + 2) / 2) {
            // return x with inexact if x!=0
            mem.doNotOptimizeAway(x + 0x1p120);
            return x;
        }
        return x + x * rationalApproxBinary128(x * x);
    }

    // 1 > |x| >= 0.5
    const z = (1.0 - @abs(x)) * 0.5;
    const s = @sqrt(z);
    const r = rationalApproxBinary128(z);

    const top: u16 = @truncate((hx >> 96) & 0x0000_ffff);
    if (top >= 0xee00) {
        const x_local = pio2_hi - (2.0 * (s + s * r) - pio2_lo);
        return if (sign) -x_local else x_local;
    }

    const hs: u128 = @bitCast(s);
    const f: f128 = @bitCast(hs & 0xffff_ffff_ffff_ffff_0000_0000_0000_0000);
    const c = (z - f * f) / (s + f);
    const x_local = 0.5 * pio2_hi - (2.0 * s * r - (pio2_lo - 2.0 * c) - (0.5 * pio2_hi - 2.0 * f));
    return if (sign) -x_local else x_local;
}

test "asinBinary16.special" {
    try testing.expectApproxEqAbs(asinBinary16(0x1p+0), 0x1.92p0, math.floatEpsAt(f16, 0x1.92p0));
    try testing.expectApproxEqAbs(asinBinary16(-0x1p+0), -0x1.92p0, math.floatEpsAt(f16, -0x1.92p0));
    try testing.expectEqual(asinBinary16(0x0p+0), 0x0p+0);
    try testing.expectEqual(asinBinary16(-0x0p+0), 0x0p+0);
    try testing.expect(math.isNan(asinBinary16(0x1.004p0)));
    try testing.expect(math.isNan(asinBinary16(-0x1.004p0)));
    try testing.expect(math.isNan(asinBinary16(math.inf(f16))));
    try testing.expect(math.isNan(asinBinary16(-math.inf(f16))));
    try testing.expect(math.isNan(asinBinary16(math.nan(f16))));
}

test "asinBinary16" {
    try testing.expectApproxEqAbs(asinBinary16(-0x1.e4cp-6), -0x1.e4cp-6, math.floatEpsAt(f16, -0x1.e4cp-6));
    try testing.expectApproxEqAbs(asinBinary16(0x1.d68p-1), 0x1.2a8p0, math.floatEpsAt(f16, 0x1.2a8p0));
    try testing.expectApproxEqAbs(asinBinary16(-0x1.a4cp-1), -0x1.eep-1, math.floatEpsAt(f16, -0x1.eep-1));
    try testing.expectApproxEqAbs(asinBinary16(-0x1.0a4p-2), -0x1.0d4p-2, math.floatEpsAt(f16, -0x1.0d4p-2));
    try testing.expectApproxEqAbs(asinBinary16(0x1.28cp-1), 0x1.3c8p-1, math.floatEpsAt(f16, 0x1.3c8p-1));
    try testing.expectApproxEqAbs(asinBinary16(0x1.284p-3), 0x1.298p-3, math.floatEpsAt(f16, 0x1.298p-3));
    try testing.expectApproxEqAbs(asinBinary16(-0x1.574p-1), -0x1.784p-1, math.floatEpsAt(f16, -0x1.784p-1));
    try testing.expectApproxEqAbs(asinBinary16(-0x1.4ccp-1), -0x1.6a4p-1, math.floatEpsAt(f16, -0x1.6a4p-1));
    try testing.expectApproxEqAbs(asinBinary16(0x1.a18p-1), 0x1.e84p-1, math.floatEpsAt(f16, 0x1.e84p-1));
    try testing.expectApproxEqAbs(asinBinary16(0x1.7a8p-2), 0x1.83cp-2, math.floatEpsAt(f16, 0x1.83cp-2));
}

test "asinBinary32.special" {
    try testing.expectApproxEqAbs(asinBinary32(0x1p+0), 0x1.921fb6p+0, math.floatEpsAt(f32, 0x1.921fb6p+0));
    try testing.expectApproxEqAbs(asinBinary32(-0x1p+0), -0x1.921fb6p+0, math.floatEpsAt(f32, -0x1.921fb6p+0));
    try testing.expectEqual(asinBinary32(0x0p+0), 0x0p+0);
    try testing.expectEqual(asinBinary32(-0x0p+0), 0x0p+0);
    try testing.expect(math.isNan(asinBinary32(0x1.000002p+0)));
    try testing.expect(math.isNan(asinBinary32(-0x1.000002p+0)));
    try testing.expect(math.isNan(asinBinary32(math.inf(f32))));
    try testing.expect(math.isNan(asinBinary32(-math.inf(f32))));
    try testing.expect(math.isNan(asinBinary32(math.nan(f32))));
}

test "asinBinary32" {
    try testing.expectApproxEqAbs(asinBinary32(-0x1.4c2906p-4), -0x1.4c868p-4, math.floatEpsAt(f32, -0x1.4c868p-4));
    try testing.expectApproxEqAbs(asinBinary32(0x1.05fcfap-1), 0x1.130648p-1, math.floatEpsAt(f32, 0x1.130648p-1));
    try testing.expectApproxEqAbs(asinBinary32(0x1.fab976p-2), 0x1.090abcp-1, math.floatEpsAt(f32, 0x1.090abcp-1));
    try testing.expectApproxEqAbs(asinBinary32(0x1.8b4b8cp-1), 0x1.c39fa2p-1, math.floatEpsAt(f32, 0x1.c39fa2p-1));
    try testing.expectApproxEqAbs(asinBinary32(0x1.7117c2p-1), 0x1.9c332p-1, math.floatEpsAt(f32, 0x1.9c332p-1));
    try testing.expectApproxEqAbs(asinBinary32(0x1.e5e112p-5), 0x1.e62a1cp-5, math.floatEpsAt(f32, 0x1.e62a1cp-5));
    try testing.expectApproxEqAbs(asinBinary32(-0x1.07673p-2), -0x1.0a65dep-2, math.floatEpsAt(f32, -0x1.0a65dep-2));
    try testing.expectApproxEqAbs(asinBinary32(-0x1.2108dep-2), -0x1.25046p-2, math.floatEpsAt(f32, -0x1.25046p-2));
    try testing.expectApproxEqAbs(asinBinary32(-0x1.4e6e6cp-1), -0x1.6c6f0cp-1, math.floatEpsAt(f32, -0x1.6c6f0cp-1));
    try testing.expectApproxEqAbs(asinBinary32(0x1.22a16ap-1), 0x1.350f7ap-1, math.floatEpsAt(f32, 0x1.350f7ap-1));
}

test "asinBinary64.special" {
    try testing.expectApproxEqAbs(asinBinary64(0x1p+0), 0x1.921fb54442d18p+0, math.floatEpsAt(f64, 0x1.921fb54442d18p+0));
    try testing.expectApproxEqAbs(asinBinary64(-0x1p+0), -0x1.921fb54442d18p+0, math.floatEpsAt(f64, -0x1.921fb54442d18p+0));
    try testing.expectEqual(asinBinary64(0x0p+0), 0x0p+0);
    try testing.expectEqual(asinBinary64(-0x0p+0), 0x0p+0);
    try testing.expect(math.isNan(asinBinary64(0x1.000002p+0)));
    try testing.expect(math.isNan(asinBinary64(-0x1.000002p+0)));
    try testing.expect(math.isNan(asinBinary64(math.inf(f64))));
    try testing.expect(math.isNan(asinBinary64(-math.inf(f64))));
    try testing.expect(math.isNan(asinBinary64(math.nan(f64))));
}

test "asinBinary64" {
    try testing.expectApproxEqAbs(asinBinary64(0x1.e674fba3e40d5p-2), 0x1.fae86c5941692p-2, math.floatEpsAt(f64, 0x1.fae86c5941692p-2));
    try testing.expectApproxEqAbs(asinBinary64(-0x1.30fd0566fd979p-1), -0x1.46b6ad730c93ap-1, math.floatEpsAt(f64, -0x1.46b6ad730c93ap-1));
    try testing.expectApproxEqAbs(asinBinary64(0x1.6444a25abfeaap-2), 0x1.6be0be8074eep-2, math.floatEpsAt(f64, 0x1.6be0be8074eep-2));
    try testing.expectApproxEqAbs(asinBinary64(0x1.40a53228d1a13p-1), 0x1.5a7e98f53f717p-1, math.floatEpsAt(f64, 0x1.5a7e98f53f717p-1));
    try testing.expectApproxEqAbs(asinBinary64(-0x1.ccc6d64845cfdp-1), -0x1.1ea2602d14e8p0, math.floatEpsAt(f64, -0x1.1ea2602d14e8p0));
    try testing.expectApproxEqAbs(asinBinary64(-0x1.94bd91b7fc74bp-1), -0x1.d2c2634193158p-1, math.floatEpsAt(f64, -0x1.d2c2634193158p-1));
    try testing.expectApproxEqAbs(asinBinary64(-0x1.8d741b5797fccp-2), -0x1.982d5f1895d2p-2, math.floatEpsAt(f64, -0x1.982d5f1895d2p-2));
    try testing.expectApproxEqAbs(asinBinary64(-0x1.3e8e7e15881c5p-3), -0x1.3fdaf7dfdc864p-3, math.floatEpsAt(f64, -0x1.3fdaf7dfdc864p-3));
    try testing.expectApproxEqAbs(asinBinary64(-0x1.88222d8ab8ca9p-2), -0x1.9269540735b7bp-2, math.floatEpsAt(f64, -0x1.9269540735b7bp-2));
    try testing.expectApproxEqAbs(asinBinary64(-0x1.41c0e9babcbd2p-2), -0x1.474c4c6625527p-2, math.floatEpsAt(f64, -0x1.474c4c6625527p-2));
}

test "asinExtended80.special" {
    try testing.expectApproxEqAbs(asinExtended80(0x1p+0), 0x1.921fb54442d1846ap+0, math.floatEpsAt(f80, 0x1.921fb54442d1846ap+0));
    try testing.expectApproxEqAbs(asinExtended80(-0x1p+0), -0x1.921fb54442d1846ap+0, math.floatEpsAt(f80, -0x1.921fb54442d1846ap+0));
    try testing.expectEqual(asinExtended80(0x0p+0), 0x0p+0);
    try testing.expectEqual(asinExtended80(-0x0p+0), 0x0p+0);
    try testing.expect(math.isNan(asinExtended80(0x1.0000000000000002p+0)));
    try testing.expect(math.isNan(asinExtended80(-0x1.0000000000000002p+0)));
    try testing.expect(math.isNan(asinExtended80(math.inf(f80))));
    try testing.expect(math.isNan(asinExtended80(-math.inf(f80))));
    try testing.expect(math.isNan(asinExtended80(math.nan(f80))));
}

test "asinExtended80" {
    try testing.expectApproxEqAbs(asinExtended80(0x1.63cf98bc52ce0da8p-9), 0x1.63cfb560149daa9p-9, math.floatEpsAt(f80, 0x1.63cfb560149daa9p-9));
    try testing.expectApproxEqAbs(asinExtended80(-0x1.0473756f7ae930dp-1), -0x1.113cbacd8cd1b96cp-1, math.floatEpsAt(f80, -0x1.113cbacd8cd1b96cp-1));
    try testing.expectApproxEqAbs(asinExtended80(-0x1.2310057e005cc288p-2), -0x1.2721b231d197b064p-2, math.floatEpsAt(f80, -0x1.2721b231d197b064p-2));
    try testing.expectApproxEqAbs(asinExtended80(0x1.f13b03bd685d96eap-1), 0x1.547c408c5d2b05aap0, math.floatEpsAt(f80, 0x1.547c408c5d2b05aap0));
    try testing.expectApproxEqAbs(asinExtended80(-0x1.d5c507e3ef84041cp-1), -0x1.296b76bfadbb5cecp0, math.floatEpsAt(f80, -0x1.296b76bfadbb5cecp0));
    try testing.expectApproxEqAbs(asinExtended80(0x1.8222cbc9147153d8p-1), 0x1.b572da8729a84f2ap-1, math.floatEpsAt(f80, 0x1.b572da8729a84f2ap-1));
    try testing.expectApproxEqAbs(asinExtended80(-0x1.42c9e6b4a088a246p-11), -0x1.42c9e80ac0524dap-11, math.floatEpsAt(f80, -0x1.42c9e80ac0524dap-11));
    try testing.expectApproxEqAbs(asinExtended80(-0x1.8f78d49deadb521cp-3), -0x1.920ca86aef6c3028p-3, math.floatEpsAt(f80, -0x1.920ca86aef6c3028p-3));
    try testing.expectApproxEqAbs(asinExtended80(-0x1.ab98792783515774p-2), -0x1.b91cb4f7204d92fp-2, math.floatEpsAt(f80, -0x1.b91cb4f7204d92fp-2));
    try testing.expectApproxEqAbs(asinExtended80(-0x1.104fe30cef6800aap-1), -0x1.1f20815fdc4c5304p-1, math.floatEpsAt(f80, -0x1.1f20815fdc4c5304p-1));
}

test "asinBinary128.special" {
    try testing.expectApproxEqAbs(asinBinary128(0x1p+0), 0x1.921fb54442d18469898cc51701b8p0, math.floatEpsAt(f128, 0x1.921fb54442d18469898cc51701b8p0));
    try testing.expectApproxEqAbs(asinBinary128(-0x1p+0), -0x1.921fb54442d18469898cc51701b8p0, math.floatEpsAt(f128, -0x1.921fb54442d18469898cc51701b8p0));
    try testing.expectEqual(asinBinary128(0x0p+0), 0x0p+0);
    try testing.expectEqual(asinBinary128(-0x0p+0), 0x0p+0);
    try testing.expect(math.isNan(asinBinary128(0x1.0000000000000000000000000001p0)));
    try testing.expect(math.isNan(asinBinary128(-0x1.0000000000000000000000000001p0)));
    try testing.expect(math.isNan(asinBinary128(math.inf(f128))));
    try testing.expect(math.isNan(asinBinary128(-math.inf(f128))));
    try testing.expect(math.isNan(asinBinary128(math.nan(f128))));
}

test "asinBinary128" {
    try testing.expectApproxEqAbs(asinBinary128(0x1.85868ce287ca0196b01c25fec5ffp-3), 0x1.87e9c740d7837f8e8fa667988fbep-3, math.floatEpsAt(f128, 0x1.87e9c740d7837f8e8fa667988fbep-3));
    try testing.expectApproxEqAbs(asinBinary128(0x1.8718d6d30b4daed08d04ef59f478p-1), 0x1.bd11a474e864213b48e0f005f1f4p-1, math.floatEpsAt(f128, 0x1.bd11a474e864213b48e0f005f1f4p-1));
    try testing.expectApproxEqAbs(asinBinary128(0x1.11a67640cd7f0ba5d5e362f3abfap-1), 0x1.20b56f8b42649fe72d1f8d68a378p-1, math.floatEpsAt(f128, 0x1.20b56f8b42649fe72d1f8d68a378p-1));
    try testing.expectApproxEqAbs(asinBinary128(-0x1.bd13bf14a9dce22188e52650daa7p-1), -0x1.0dc3a7ddb9736e5ad699bf338566p0, math.floatEpsAt(f128, -0x1.0dc3a7ddb9736e5ad699bf338566p0));
    try testing.expectApproxEqAbs(asinBinary128(-0x1.dee0bc217fc462af57c484eefa71p-2), -0x1.f250716038f70fa50a5826c03802p-2, math.floatEpsAt(f128, -0x1.f250716038f70fa50a5826c03802p-2));
    try testing.expectApproxEqAbs(asinBinary128(-0x1.ea7df9139371c10b9d6fd2bbccd3p-1), -0x1.47a8b4cdd327f90056722feddbabp0, math.floatEpsAt(f128, -0x1.47a8b4cdd327f90056722feddbabp0));
    try testing.expectApproxEqAbs(asinBinary128(0x1.04aaea6de3b5a616460702f26dfcp-2), 0x1.079178d52be662dec67e2cd7f6e9p-2, math.floatEpsAt(f128, 0x1.079178d52be662dec67e2cd7f6e9p-2));
    try testing.expectApproxEqAbs(asinBinary128(-0x1.c7ea85e6b61be666435a7d99444cp-1), -0x1.192df5a8d71702cf1e27014887b2p0, math.floatEpsAt(f128, -0x1.192df5a8d71702cf1e27014887b2p0));
    try testing.expectApproxEqAbs(asinBinary128(-0x1.6e210214e40edf6c8479998189d1p-1), -0x1.97f1092fd94ac0fdfddae2e1222bp-1, math.floatEpsAt(f128, -0x1.97f1092fd94ac0fdfddae2e1222bp-1));
    try testing.expectApproxEqAbs(asinBinary128(-0x1.95061bf93ed6986a45d20f0e1064p-3), -0x1.97b62bc5ae6512093828828325e1p-3, math.floatEpsAt(f128, -0x1.97b62bc5ae6512093828828325e1p-3));
}
