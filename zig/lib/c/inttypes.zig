const std = @import("std");
const common = @import("common.zig");
const builtin = @import("builtin");
const intmax_t = std.c.intmax_t;
const imaxdiv_t = std.c.imaxdiv_t;

comptime {
    if (builtin.target.isMuslLibC() or builtin.target.isWasiLibC()) {
        // Functions specific to musl and wasi-libc.
        @export(&imaxabs, .{ .name = "imaxabs", .linkage = common.linkage, .visibility = common.visibility });
        @export(&imaxdiv, .{ .name = "imaxdiv", .linkage = common.linkage, .visibility = common.visibility });
    }
}

fn imaxabs(a: intmax_t) callconv(.c) intmax_t {
    return @intCast(@abs(a));
}

fn imaxdiv(a: intmax_t, b: intmax_t) callconv(.c) imaxdiv_t {
    return .{
        .quot = @divTrunc(a, b),
        .rem = @rem(a, b),
    };
}

test imaxabs {
    const val: intmax_t = -10;
    try std.testing.expectEqual(10, imaxabs(val));
}

test imaxdiv {
    const expected: imaxdiv_t = .{ .quot = 9, .rem = 0 };
    try std.testing.expectEqual(expected, imaxdiv(9, 1));
}
