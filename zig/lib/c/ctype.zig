const std = @import("std");
const common = @import("common.zig");
const builtin = @import("builtin");

comptime {
    if (builtin.target.isMuslLibC() or builtin.target.isWasiLibC()) {
        // Functions specific to musl and wasi-libc.
        @export(&isalnum, .{ .name = "isalnum", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isalpha, .{ .name = "isalpha", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isblank, .{ .name = "isblank", .linkage = common.linkage, .visibility = common.visibility });
        @export(&iscntrl, .{ .name = "iscntrl", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isdigit, .{ .name = "isdigit", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isgraph, .{ .name = "isgraph", .linkage = common.linkage, .visibility = common.visibility });
        @export(&islower, .{ .name = "islower", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isprint, .{ .name = "isprint", .linkage = common.linkage, .visibility = common.visibility });
        @export(&ispunct, .{ .name = "ispunct", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isspace, .{ .name = "isspace", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isupper, .{ .name = "isupper", .linkage = common.linkage, .visibility = common.visibility });
        @export(&isxdigit, .{ .name = "isxdigit", .linkage = common.linkage, .visibility = common.visibility });
        @export(&tolower, .{ .name = "tolower", .linkage = common.linkage, .visibility = common.visibility });
        @export(&toupper, .{ .name = "toupper", .linkage = common.linkage, .visibility = common.visibility });

        @export(&__isalnum_l, .{ .name = "__isalnum_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isalpha_l, .{ .name = "__isalpha_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isblank_l, .{ .name = "__isblank_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__iscntrl_l, .{ .name = "__iscntrl_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isdigit_l, .{ .name = "__isdigit_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isgraph_l, .{ .name = "__isgraph_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__islower_l, .{ .name = "__islower_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isprint_l, .{ .name = "__isprint_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__ispunct_l, .{ .name = "__ispunct_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isspace_l, .{ .name = "__isspace_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isupper_l, .{ .name = "__isupper_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isxdigit_l, .{ .name = "__isxdigit_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__tolower_l, .{ .name = "__tolower_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__toupper_l, .{ .name = "__toupper_l", .linkage = common.linkage, .visibility = common.visibility });

        @export(&__isalnum_l, .{ .name = "isalnum_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isalpha_l, .{ .name = "isalpha_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isblank_l, .{ .name = "isblank_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__iscntrl_l, .{ .name = "iscntrl_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isdigit_l, .{ .name = "isdigit_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isgraph_l, .{ .name = "isgraph_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__islower_l, .{ .name = "islower_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isprint_l, .{ .name = "isprint_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__ispunct_l, .{ .name = "ispunct_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isspace_l, .{ .name = "isspace_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isupper_l, .{ .name = "isupper_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__isxdigit_l, .{ .name = "isxdigit_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__tolower_l, .{ .name = "tolower_l", .linkage = common.linkage, .visibility = common.visibility });
        @export(&__toupper_l, .{ .name = "toupper_l", .linkage = common.linkage, .visibility = common.visibility });

        @export(&isascii, .{ .name = "isascii", .linkage = common.linkage, .visibility = common.visibility });
        @export(&toascii, .{ .name = "toascii", .linkage = common.linkage, .visibility = common.visibility });
    }
}

// NOTE: If the input is not representable as an unsigned char or is not EOF (which is a negative integer value) the behaviour is undefined.

fn isalnum(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isAlphanumeric(@truncate(@as(c_uint, @bitCast(c))))); // @truncate instead of @intCast as we have to handle EOF
}

fn __isalnum_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return isalnum(c);
}

fn isalpha(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isAlphabetic(@truncate(@as(c_uint, @bitCast(c)))));
}

fn __isalpha_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return isalpha(c);
}

fn isblank(c: c_int) callconv(.c) c_int {
    return @intFromBool(c == ' ' or c == '\t');
}

fn __isblank_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return isblank(c);
}

fn iscntrl(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isControl(@truncate(@as(c_uint, @bitCast(c)))));
}

fn __iscntrl_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return iscntrl(c);
}

fn isdigit(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isDigit(@truncate(@as(c_uint, @bitCast(c)))));
}

fn __isdigit_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return isdigit(c);
}

fn isgraph(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isGraphical(@truncate(@as(c_uint, @bitCast(c)))));
}

fn __isgraph_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return isgraph(c);
}

fn islower(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isLower(@truncate(@as(c_uint, @bitCast(c)))));
}

fn __islower_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return islower(c);
}

fn isprint(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isPrint(@truncate(@as(c_uint, @bitCast(c)))));
}

fn __isprint_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return isprint(c);
}

fn ispunct(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isPunctuation(@truncate(@as(c_uint, @bitCast(c)))));
}

fn __ispunct_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return ispunct(c);
}

fn isspace(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isWhitespace(@truncate(@as(c_uint, @bitCast(c)))));
}

fn __isspace_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return isspace(c);
}

fn isupper(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isUpper(@truncate(@as(c_uint, @bitCast(c)))));
}

fn __isupper_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return isupper(c);
}

fn isxdigit(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isHex(@truncate(@as(c_uint, @bitCast(c)))));
}

fn __isxdigit_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return isxdigit(c);
}

fn tolower(c: c_int) callconv(.c) c_int {
    return std.ascii.toLower(@truncate(@as(c_uint, @bitCast(c))));
}

fn __tolower_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return tolower(c);
}

fn toupper(c: c_int) callconv(.c) c_int {
    return std.ascii.toUpper(@truncate(@as(c_uint, @bitCast(c))));
}

fn __toupper_l(c: c_int, locale: *anyopaque) callconv(.c) c_int {
    _ = locale;
    return toupper(c);
}

fn isascii(c: c_int) callconv(.c) c_int {
    return @intFromBool(std.ascii.isAscii(@truncate(@as(c_uint, @bitCast(c)))));
}

fn toascii(c: c_int) callconv(.c) c_int {
    return c & 0x7F;
}
