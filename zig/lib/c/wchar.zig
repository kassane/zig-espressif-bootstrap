const std = @import("std");
const common = @import("common.zig");
const builtin = @import("builtin");
const wint_t = std.c.wint_t;
const wchar_t = std.c.wchar_t;

comptime {
    if (builtin.target.isMuslLibC() or builtin.target.isWasiLibC()) {
        @export(&wmemchr, .{ .name = "wmemchr", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wmemcmp, .{ .name = "wmemcmp", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wmemcpy, .{ .name = "wmemcpy", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wmemmove, .{ .name = "wmemmove", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wmemset, .{ .name = "wmemset", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcslen, .{ .name = "wcslen", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcsnlen, .{ .name = "wcsnlen", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcscmp, .{ .name = "wcscmp", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcsncmp, .{ .name = "wcsncmp", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcpcpy, .{ .name = "wcpcpy", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcpncpy, .{ .name = "wcpncpy", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcscpy, .{ .name = "wcscpy", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcsncpy, .{ .name = "wcsncpy", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcscat, .{ .name = "wcscat", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcsncat, .{ .name = "wcsncat", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcschr, .{ .name = "wcschr", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcsrchr, .{ .name = "wcsrchr", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcsspn, .{ .name = "wcsspn", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcscspn, .{ .name = "wcscspn", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcspbrk, .{ .name = "wcspbrk", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcstok, .{ .name = "wcstok", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcsstr, .{ .name = "wcsstr", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcswcs, .{ .name = "wcswcs", .linkage = common.linkage, .visibility = common.visibility });
    }

    if (builtin.target.isMinGW()) {
        @export(&wmemchr, .{ .name = "wmemchr", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wmemcmp, .{ .name = "wmemcmp", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wmemcpy, .{ .name = "wmemcpy", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wmempcpy, .{ .name = "wmempcpy", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wmemmove, .{ .name = "wmemmove", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wmemset, .{ .name = "wmemset", .linkage = common.linkage, .visibility = common.visibility });
        @export(&wcsnlen, .{ .name = "wcsnlen", .linkage = common.linkage, .visibility = common.visibility });
    }
}

fn wmemchr(ptr: [*]const wchar_t, value: wchar_t, len: usize) callconv(.c) ?[*]wchar_t {
    return @constCast(ptr[std.mem.findScalar(wchar_t, ptr[0..len], value) orelse return null ..]);
}

fn wmemcmp(a: [*]const wchar_t, b: [*]const wchar_t, len: usize) callconv(.c) c_int {
    return switch (std.mem.order(wchar_t, a[0..len], b[0..len])) {
        .eq => 0,
        .gt => 1,
        .lt => -1,
    };
}

fn wmemcpy(noalias dest: [*]wchar_t, noalias src: [*]const wchar_t, len: usize) callconv(.c) [*]wchar_t {
    @memcpy(dest[0..len], src[0..len]);
    return dest;
}

fn wmempcpy(noalias dest: [*]wchar_t, noalias src: [*]const wchar_t, len: usize) callconv(.c) [*]wchar_t {
    @memcpy(dest[0..len], src[0..len]);
    return dest + len;
}

fn wmemmove(dest: [*]wchar_t, src: [*]const wchar_t, len: usize) callconv(.c) [*]wchar_t {
    @memmove(dest[0..len], src[0..len]);
    return dest;
}

fn wmemset(dest: [*]wchar_t, elem: wchar_t, len: usize) callconv(.c) [*]wchar_t {
    @memset(dest[0..len], elem);
    return dest;
}

fn wcslen(str: [*:0]const wchar_t) callconv(.c) usize {
    return wcsnlen(str, std.math.maxInt(usize));
}

fn wcsnlen(str: [*:0]const wchar_t, max: usize) callconv(.c) usize {
    return std.mem.findScalar(wchar_t, str[0..max], 0) orelse max;
}

fn wcscmp(a: [*:0]const wchar_t, b: [*:0]const wchar_t) callconv(.c) c_int {
    return wcsncmp(a, b, std.math.maxInt(usize));
}

fn wcsncmp(a: [*:0]const wchar_t, b: [*:0]const wchar_t, max: usize) callconv(.c) c_int {
    return switch (std.mem.boundedOrderZ(wchar_t, a, b, max)) {
        .eq => 0,
        .gt => 1,
        .lt => -1,
    };
}

fn wcpcpy(noalias dst: [*]wchar_t, noalias src: [*:0]const wchar_t) callconv(.c) [*]wchar_t {
    const src_len = std.mem.len(src);
    @memcpy(dst[0 .. src_len + 1], src[0 .. src_len + 1]);
    return dst + src_len;
}

fn wcpncpy(noalias dst: [*]wchar_t, noalias src: [*:0]const wchar_t, max: usize) callconv(.c) [*]wchar_t {
    const src_len = wcsnlen(src, max);
    const copying_len = @min(max, src_len);
    @memcpy(dst[0..copying_len], src[0..copying_len]);
    @memset(dst[copying_len..][0 .. max - copying_len], 0x00);
    return dst + copying_len;
}

fn wcscpy(noalias dst: [*]wchar_t, noalias src: [*:0]const wchar_t) callconv(.c) [*]wchar_t {
    _ = wcpcpy(dst, src);
    return dst;
}

fn wcsncpy(noalias dst: [*]wchar_t, noalias src: [*:0]const wchar_t, max: usize) callconv(.c) [*]wchar_t {
    _ = wcpncpy(dst, src, max);
    return dst;
}

fn wcscat(noalias dst: [*:0]wchar_t, noalias src: [*:0]const wchar_t) callconv(.c) [*:0]wchar_t {
    return wcsncat(dst, src, std.math.maxInt(usize));
}

fn wcsncat(noalias dst: [*:0]wchar_t, noalias src: [*:0]const wchar_t, max: usize) callconv(.c) [*:0]wchar_t {
    const dst_len = std.mem.len(dst);
    const src_len = std.mem.len(src);
    const copying_len = @min(max, src_len);

    @memcpy(dst[dst_len..][0..copying_len], src[0..copying_len]);
    dst[dst_len + copying_len] = 0;
    return dst[0..(dst_len + copying_len) :0].ptr;
}

fn wcschr(str: [*:0]const wchar_t, value: wchar_t) callconv(.c) ?[*:0]wchar_t {
    const len = std.mem.len(str);

    if (value == 0) return @constCast(str + len);
    return @constCast(str[std.mem.findScalar(wchar_t, str[0..len], value) orelse return null ..]);
}

fn wcsrchr(str: [*:0]const wchar_t, value: wchar_t) callconv(.c) ?[*:0]wchar_t {
    // std.mem.len(str) + 1 to not special case '\0'
    return @constCast(str[std.mem.findScalarLast(wchar_t, str[0..(std.mem.len(str) + 1)], value) orelse return null ..]);
}

fn wcsspn(dst: [*:0]const wchar_t, values: [*:0]const wchar_t) callconv(.c) usize {
    const dst_slice = std.mem.span(dst);
    return std.mem.findNone(wchar_t, dst_slice, std.mem.span(values)) orelse dst_slice.len;
}

fn wcscspn(dst: [*:0]const wchar_t, values: [*:0]const wchar_t) callconv(.c) usize {
    const dst_slice = std.mem.span(dst);
    return std.mem.findAny(wchar_t, dst_slice, std.mem.span(values)) orelse dst_slice.len;
}

fn wcspbrk(haystack: [*:0]const wchar_t, needle: [*:0]const wchar_t) callconv(.c) ?[*:0]wchar_t {
    return @constCast(haystack[std.mem.findAny(wchar_t, std.mem.span(haystack), std.mem.span(needle)) orelse return null ..]);
}

fn wcstok(noalias maybe_str: ?[*:0]wchar_t, noalias values: [*:0]const wchar_t, noalias state: *?[*:0]wchar_t) callconv(.c) ?[*:0]wchar_t {
    const str = if (maybe_str) |str|
        str
    else if (state.*) |state_str|
        state_str
    else
        return null;

    const str_chars = std.mem.span(str);
    const values_chars = std.mem.span(values);
    const tok_start = std.mem.findNone(wchar_t, str_chars, values_chars) orelse return null;

    if (std.mem.findAnyPos(wchar_t, str_chars, tok_start, values_chars)) |tok_end| {
        str[tok_end] = 0;
        state.* = str[tok_end + 1 ..];
    } else {
        state.* = str[str_chars.len..];
    }

    return str[tok_start..];
}

fn wcsstr(noalias haystack: [*:0]const wchar_t, noalias needle: [*:0]const wchar_t) callconv(.c) ?[*:0]wchar_t {
    return @constCast(haystack[std.mem.find(wchar_t, std.mem.span(haystack), std.mem.span(needle)) orelse return null ..]);
}

fn wcswcs(noalias haystack: [*:0]const wchar_t, noalias needle: [*:0]const wchar_t) callconv(.c) ?[*:0]wchar_t {
    return wcsstr(haystack, needle);
}
