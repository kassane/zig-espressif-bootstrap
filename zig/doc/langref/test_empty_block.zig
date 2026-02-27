const std = @import("std");
const expectEqual = std.testing.expectEqual;

test {
    const a = {};
    const b = void{};
    try expectEqual(void, @TypeOf(a));
    try expectEqual(void, @TypeOf(b));
    try expectEqual(a, b);
}

// test
