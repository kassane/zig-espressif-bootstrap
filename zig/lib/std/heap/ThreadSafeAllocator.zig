//! Deprecated. Thread safety should be built into each Allocator instance
//! directly rather than trying to do this "composable allocators" thing.
const ThreadSafeAllocator = @This();

const std = @import("../std.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

child_allocator: Allocator,
io: Io,
mutex: Io.Mutex = .init,

pub fn allocator(self: *ThreadSafeAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
    const io = self.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    return self.child_allocator.rawAlloc(n, alignment, ra);
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
    const io = self.io;

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    return self.child_allocator.rawResize(buf, alignment, new_len, ret_addr);
}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    const self: *ThreadSafeAllocator = @ptrCast(@alignCast(context));
    const io = self.io;

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    return self.child_allocator.rawRemap(memory, alignment, new_len, return_address);
}

fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
    const io = self.io;

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    return self.child_allocator.rawFree(buf, alignment, ret_addr);
}
