const std = @import("std");
const builtin = @import("builtin");
const expectEqual = std.testing.expectEqual;

test "variable alignment" {
    var x: i32 = 1234;
    const align_of_i32 = @alignOf(@TypeOf(x));
    try expectEqual(*i32, @TypeOf(&x));
    try expectEqual(*align(align_of_i32) i32, *i32);
    if (builtin.target.cpu.arch == .x86_64) {
        try expectEqual(4, @typeInfo(*i32).pointer.alignment);
    }
}

// test
