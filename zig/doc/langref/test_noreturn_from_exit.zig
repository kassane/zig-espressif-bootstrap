const std = @import("std");
const builtin = @import("builtin");
const native_arch = builtin.cpu.arch;
const expectEqual = std.testing.expectEqual;

const WINAPI: std.builtin.CallingConvention = if (native_arch == .x86) .{ .x86_stdcall = .{} } else .c;
extern "kernel32" fn ExitProcess(exit_code: c_uint) callconv(WINAPI) noreturn;

test "foo" {
    const value = bar() catch ExitProcess(1);
    try expectEqual(1234, value);
}

fn bar() anyerror!u32 {
    return 1234;
}

// test
// target=x86_64-windows
