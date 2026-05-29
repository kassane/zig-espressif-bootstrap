const std = @import("std");
const Type = @import("../../Type.zig");
const Zcu = @import("../../Zcu.zig");

pub const Class = enum { memory, byval, i32_array };

/// Classify a type for the Xtensa windowed and call0 C ABIs.
///
/// Xtensa C ABI rules (identical for both windowed and call0):
///   - Scalars, pointers, booleans, floats: passed by value in a-registers.
///   - Structs/unions ≤ 24 bytes (6 × 32-bit words): flattened to [N x i32]
///     in registers a2..a7, regardless of field alignment.
///   - Structs/unions > 24 bytes: passed by hidden pointer (memory).
///
/// The alignment-independence is the key difference from LLVM's default
/// lowering, which stack-spills under-aligned (align < 4) aggregates.
pub fn classifyType(ty: Type, zcu: *Zcu) Class {
    std.debug.assert(ty.hasRuntimeBits(zcu));
    const max_reg_bytes: u64 = 24; // 6 argument registers × 4 bytes

    switch (ty.zigTypeTag(zcu)) {
        .@"struct", .@"union" => {
            if (ty.containerLayout(zcu) == .@"packed") {
                const bit_size = ty.bitSize(zcu);
                if (bit_size > max_reg_bytes * 8) return .memory;
                return .byval;
            }
            const byte_size = ty.abiSize(zcu);
            if (byte_size > max_reg_bytes) return .memory;
            // All ≤24-byte aggregates go in registers as [N x i32].
            return .i32_array;
        },
        .bool,
        .float,
        .int,
        .@"enum",
        .error_set,
        .pointer,
        .optional,
        => return .byval,
        .vector => {
            const byte_size = ty.abiSize(zcu);
            if (byte_size > max_reg_bytes) return .memory;
            return .byval;
        },
        else => unreachable,
    }
}

/// Number of i32 words needed to hold `byte_size` bytes.
pub fn i32Count(byte_size: u64) u8 {
    return @intCast((byte_size + 3) / 4);
}
