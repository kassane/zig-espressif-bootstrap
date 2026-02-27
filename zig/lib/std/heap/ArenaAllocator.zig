//! This allocator takes an existing allocator, wraps it, and provides an interface where
//! you can allocate and then free it all together. Calls to free an individual item only
//! free the item if it was the most recent allocation, otherwise calls to free do
//! nothing.
//!
//! The `Allocator` implementation provided is threadsafe, given that `child_allocator`
//! is threadsafe as well.
const ArenaAllocator = @This();

child_allocator: Allocator,
state: State,

/// Inner state of ArenaAllocator. Can be stored rather than the entire ArenaAllocator
/// as a memory-saving optimization.
///
/// Default initialization of this struct is deprecated; use `init` instead.
pub const State = struct {
    used_list: ?*Node = null,
    free_list: ?*Node = null,

    pub const init: State = .{
        .used_list = null,
        .free_list = null,
    };

    pub fn promote(state: State, child_allocator: Allocator) ArenaAllocator {
        return .{
            .child_allocator = child_allocator,
            .state = state,
        };
    }
};

pub fn allocator(arena: *ArenaAllocator) Allocator {
    return .{
        .ptr = arena,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub fn init(child_allocator: Allocator) ArenaAllocator {
    return State.init.promote(child_allocator);
}

/// Not threadsafe.
pub fn deinit(arena: ArenaAllocator) void {
    // NOTE: When changing this, make sure `reset()` is adjusted accordingly!

    for ([_]?*Node{ arena.state.used_list, arena.state.free_list }) |first_node| {
        var it = first_node;
        while (it) |node| {
            // this has to occur before the free because the free frees node
            it = node.next;
            arena.child_allocator.rawFree(node.allocatedSliceUnsafe(), .of(Node), @returnAddress());
        }
    }
}

/// Queries the current memory use of this arena.
/// This will **not** include the storage required for internal keeping.
///
/// Not threadsafe.
pub fn queryCapacity(arena: ArenaAllocator) usize {
    var capacity: usize = 0;
    for ([_]?*Node{ arena.state.used_list, arena.state.free_list }) |first_node| {
        capacity += countListCapacity(first_node);
    }
    return capacity;
}
fn countListCapacity(first_node: ?*Node) usize {
    var capacity: usize = 0;
    var it = first_node;
    while (it) |node| : (it = node.next) {
        // Compute the actually allocated size excluding the
        // linked list node.
        capacity += node.size.toInt() - @sizeOf(Node);
    }
    return capacity;
}

pub const ResetMode = union(enum) {
    /// Releases all allocated memory in the arena.
    free_all,
    /// This will pre-heat the arena for future allocations by allocating a
    /// large enough buffer for all previously done allocations.
    /// Preheating will speed up the allocation process by invoking the backing allocator
    /// less often than before. If `reset()` is used in a loop, this means that after the
    /// biggest operation, no memory allocations are performed anymore.
    retain_capacity,
    /// This is the same as `retain_capacity`, but the memory will be shrunk to
    /// this value if it exceeds the limit.
    retain_with_limit: usize,
};
/// Resets the arena allocator and frees all allocated memory.
///
/// `mode` defines how the currently allocated memory is handled.
/// See the variant documentation for `ResetMode` for the effects of each mode.
///
/// The function will return whether the reset operation was successful or not.
/// If the reallocation  failed `false` is returned. The arena will still be fully
/// functional in that case, all memory is released. Future allocations just might
/// be slower.
///
/// Not threadsafe.
///
/// NOTE: If `mode` is `free_all`, the function will always return `true`.
pub fn reset(arena: *ArenaAllocator, mode: ResetMode) bool {
    // Some words on the implementation:
    // The reset function can be implemented with two basic approaches:
    // - Counting how much bytes were allocated since the last reset, and storing that
    //   information in State. This will make reset fast and alloc only a teeny tiny bit
    //   slower.
    // - Counting how much bytes were allocated by iterating the chunk linked list. This
    //   will make reset slower, but alloc() keeps the same speed when reset() as if reset()
    //   would not exist.
    //
    // The second variant was chosen for implementation, as with more and more calls to reset(),
    // the function will get faster and faster. At one point, the complexity of the function
    // will drop to amortized O(1), as we're only ever having a single chunk that will not be
    // reallocated, and we're not even touching the backing allocator anymore.
    //
    // Thus, only the first hand full of calls to reset() will actually need to iterate the linked
    // list, all future calls are just taking the first node, and only resetting the `end_index`
    // value.

    const limit: ?usize = switch (mode) {
        .retain_capacity => null,
        .retain_with_limit => |limit| limit,
        .free_all => 0,
    };
    if (limit == 0) {
        // just reset when we don't have anything to reallocate
        arena.deinit();
        arena.state = .init;
        return true;
    }

    const used_capacity = countListCapacity(arena.state.used_list);
    const free_capacity = countListCapacity(arena.state.free_list);

    const new_used_capacity = if (limit) |lim| @min(lim, used_capacity) else used_capacity;
    const new_free_capacity = if (limit) |lim| @min(lim - new_used_capacity, free_capacity) else free_capacity;

    var ok = true;

    for (
        [_]*?*Node{ &arena.state.used_list, &arena.state.free_list },
        [_]usize{ new_used_capacity, new_free_capacity },
    ) |first_node_ptr, new_capacity| {
        // Free all nodes except for the last one
        var it = first_node_ptr.*;
        const node: *Node = while (it) |node| {
            // this has to occur before the free because the free frees node
            it = node.next;
            if (it == null) break node;
            arena.child_allocator.rawFree(node.allocatedSliceUnsafe(), .of(Node), @returnAddress());
        } else {
            continue;
        };
        const allocated_slice = node.allocatedSliceUnsafe();

        // Align backwards to always stay below limit.
        const new_size = mem.alignBackward(usize, @sizeOf(Node) + new_capacity, 2);

        if (new_size == @sizeOf(Node)) {
            arena.child_allocator.rawFree(allocated_slice, .of(Node), @returnAddress());
            first_node_ptr.* = null;
            continue;
        }

        node.end_index = 0;
        first_node_ptr.* = node;

        if (allocated_slice.len == new_size) {
            // perfect, no need to invoke the child_allocator
            continue;
        }

        if (arena.child_allocator.rawResize(allocated_slice, .of(Node), new_size, @returnAddress())) {
            // successful resize
            node.size = .fromInt(new_size);
        } else {
            // manual realloc
            const new_ptr = arena.child_allocator.rawAlloc(new_size, .of(Node), @returnAddress()) orelse {
                // we failed to preheat the arena properly, signal this to the user.
                ok = false;
                continue;
            };
            arena.child_allocator.rawFree(allocated_slice, .of(Node), @returnAddress());
            const new_first_node: *Node = @ptrCast(@alignCast(new_ptr));
            new_first_node.* = .{
                .size = .fromInt(new_size),
                .end_index = 0,
                .next = null,
            };
            first_node_ptr.* = new_first_node;
        }
    }

    return ok;
}

/// Concurrent accesses to node pointers generally have to have acquire/release
/// semantics to guarantee that newly allocated notes are in a valid state when
/// being inserted into a list. Exceptions are possible, e.g. a CAS loop that
/// never accesses the node returned on failure can use monotonic semantics on
/// failure, but must still use release semantics on success to protect the node
/// it's trying to push.
const Node = struct {
    /// Only meant to be accessed indirectly via the methods supplied by this type,
    /// except if the node is owned by the thread accessing it.
    /// Must always be an even number to accomodate `resize` bit.
    size: Size,
    /// Concurrent accesses to `end_index` can be monotonic as long as its value
    /// is compared to a version of `size` before using it to access memory.
    /// Since `size` can only grow and never shrink, memory access depending on
    /// any `end_index` <= any `size` can never be OOB.
    end_index: usize,
    /// This field should only be accessed if the node is owned by the thread
    /// accessing it.
    next: ?*Node,

    const Size = packed struct(usize) {
        resizing: bool,
        _: @Int(.unsigned, @bitSizeOf(usize) - 1) = 0,

        fn fromInt(int: usize) Size {
            assert(int >= @sizeOf(Node));
            const size: Size = @bitCast(int);
            assert(!size.resizing);
            return size;
        }

        fn toInt(size: Size) usize {
            var int = size;
            int.resizing = false;
            return @bitCast(int);
        }

        comptime {
            assert(Size{ .resizing = true } == @as(Size, @bitCast(@as(usize, 1))));
        }
    };

    fn loadBuf(node: *Node) []u8 {
        // monotonic is fine since `size` can only ever grow, so the buffer returned
        // by this function is always valid memory.
        const size = @atomicLoad(Size, &node.size, .monotonic);
        return @as([*]u8, @ptrCast(node))[0..size.toInt()][@sizeOf(Node)..];
    }

    /// Returns allocated slice or `null` if node is already (being) resized.
    fn beginResize(node: *Node) ?[]u8 {
        const size = @atomicRmw(Size, &node.size, .Or, .{ .resizing = true }, .acquire); // syncs with release in `endResize`
        if (size.resizing) return null;
        return @as([*]u8, @ptrCast(node))[0..size.toInt()];
    }

    fn endResize(node: *Node, size: usize) void {
        return @atomicStore(Size, &node.size, .fromInt(size), .release); // syncs with acquire in `beginResize`
    }

    /// Not threadsafe.
    fn allocatedSliceUnsafe(node: *Node) []u8 {
        return @as([*]u8, @ptrCast(node))[0..node.size.toInt()];
    }
};

fn loadFirstNode(arena: *ArenaAllocator) ?*Node {
    return @atomicLoad(?*Node, &arena.state.used_list, .acquire); // syncs with release in successful `tryPushNode`
}

const PushResult = union(enum) {
    success,
    failure: ?*Node,
};
fn tryPushNode(arena: *ArenaAllocator, node: *Node) PushResult {
    assert(node != node.next);
    if (@cmpxchgStrong( // strong because retrying means discarding a fitting node -> expensive
        ?*Node,
        &arena.state.used_list,
        node.next,
        node,
        .release, // syncs with acquire in failure path or `loadFirstNode`
        .acquire, // syncs with release in success path
    )) |old_node| {
        return .{ .failure = old_node };
    } else {
        return .success;
    }
}

fn stealFreeList(arena: *ArenaAllocator) ?*Node {
    // syncs with acq_rel in other `stealFreeList` calls or release in `pushFreeList`
    return @atomicRmw(?*Node, &arena.state.free_list, .Xchg, null, .acq_rel);
}

fn pushFreeList(arena: *ArenaAllocator, first: *Node, last: *Node) void {
    assert(first != last.next);
    while (@cmpxchgWeak(
        ?*Node,
        &arena.state.free_list,
        last.next,
        first,
        .release, // syncs with acquire part of acq_rel in `stealFreeList`
        .monotonic, // we never access any fields of `old_free_list`, we only care about the pointer
    )) |old_free_list| {
        last.next = old_free_list;
    }
}

fn alignedIndex(buf_ptr: [*]u8, end_index: usize, alignment: Alignment) usize {
    return end_index +
        mem.alignPointerOffset(buf_ptr + end_index, alignment.toByteUnits()).?;
}

fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = ret_addr;

    assert(n > 0);

    var cur_first_node = arena.loadFirstNode();

    var cur_new_node: ?*Node = null;
    defer if (cur_new_node) |node| {
        node.next = null; // optimize for empty free list
        arena.pushFreeList(node, node);
    };

    retry: while (true) {
        const first_node: ?*Node, const prev_size: usize = first_node: {
            const node = cur_first_node orelse break :first_node .{ null, 0 };
            const buf = node.loadBuf();

            // To avoid using a CAS loop in the hot path we atomically increase
            // `end_index` by a large enough amount to be able to always provide
            // the required alignment within the reserved memory. To recover the
            // space this potentially wastes we try to subtract the 'overshoot'
            // with a single cmpxchg afterwards, which may fail.

            const alignable = n + alignment.toByteUnits() - 1;
            const end_index = @atomicRmw(usize, &node.end_index, .Add, alignable, .monotonic);
            const aligned_index = alignedIndex(buf.ptr, end_index, alignment);
            assert(end_index + alignable >= aligned_index + n);
            _ = @cmpxchgStrong(usize, &node.end_index, end_index + alignable, aligned_index + n, .monotonic, .monotonic);

            if (aligned_index + n > buf.len) break :first_node .{ node, buf.len };
            return buf[aligned_index..][0..n].ptr;
        };

        resize: {
            // Before attempting to get our hands on a new node, we try to resize
            // the one we're currently holding. This is an exclusive operation;
            // if another thread is already in this section we can never resize.

            const node = first_node orelse break :resize;
            const allocated_slice = node.beginResize() orelse break :resize;
            var size = allocated_slice.len;
            defer node.endResize(size);

            const buf = allocated_slice[@sizeOf(Node)..];
            const end_index = @atomicLoad(usize, &node.end_index, .monotonic);
            const aligned_index = alignedIndex(buf.ptr, end_index, alignment);
            const new_size = mem.alignForward(usize, @sizeOf(Node) + aligned_index + n, 2);

            if (new_size <= allocated_slice.len) {
                // a `resize` or `free` call managed to sneak in and we need to
                // guarantee that `size` is only ever increased; retry!
                continue :retry;
            }

            if (arena.child_allocator.rawResize(allocated_slice, .of(Node), new_size, @returnAddress())) {
                size = new_size;

                if (@cmpxchgStrong( // strong because a spurious failure could result in suboptimal usage of this node
                    usize,
                    &node.end_index,
                    end_index,
                    aligned_index + n,
                    .monotonic,
                    .monotonic,
                ) == null) {
                    const new_buf = allocated_slice.ptr[0..new_size][@sizeOf(Node)..];
                    return new_buf[aligned_index..][0..n].ptr;
                }
            }
        }

        // We need a new node! First, we search `free_list` for one that's big
        // enough, if we don't find one there we fall back to allocating a new
        // node with `child_allocator` (if we haven't already done that!).

        from_free_list: {
            // We 'steal' the entire free list to operate on it without other
            // threads getting up into our business.
            // This is a rather pragmatic approach, but since the free list isn't
            // used very frequently it's fine performance-wise, even under load.
            // Also this avoids the ABA problem; stealing the list with an atomic
            // swap doesn't introduce any potentially stale `next` pointers.

            const free_list = arena.stealFreeList();
            var first_free: ?*Node = free_list;
            var last_free: ?*Node = free_list;
            defer {
                // Push remaining stolen free list back onto `arena.state.free_list`.
                if (first_free) |first| {
                    const last = last_free.?;
                    assert(last.next == null); // optimize for no new nodes added during steal
                    arena.pushFreeList(first, last);
                }
            }

            const candidate: ?*Node, const prev: ?*Node = candidate: {
                var best_fit_prev: ?*Node = null;
                var best_fit: ?*Node = null;
                var best_fit_diff: usize = std.math.maxInt(usize);

                var it_prev: ?*Node = null;
                var it = free_list;
                while (it) |node| : ({
                    it_prev = it;
                    it = node.next;
                }) {
                    last_free = node;
                    assert(!node.size.resizing);
                    const buf = node.allocatedSliceUnsafe()[@sizeOf(Node)..];
                    const aligned_index = alignedIndex(buf.ptr, 0, alignment);

                    if (aligned_index + n <= buf.len) {
                        break :candidate .{ node, it_prev };
                    }

                    const diff = aligned_index + n - buf.len;
                    if (diff <= best_fit_diff) {
                        best_fit_prev = it_prev;
                        best_fit = node;
                        best_fit_diff = diff;
                    }
                } else {
                    // Ideally we want to use all nodes in `free_list` eventually,
                    // so even if none fit we'll try to resize the one that was the
                    // closest to being large enough.
                    if (best_fit) |node| {
                        const allocated_slice = node.allocatedSliceUnsafe();
                        const buf = allocated_slice[@sizeOf(Node)..];
                        const aligned_index = alignedIndex(buf.ptr, 0, alignment);
                        const new_size = mem.alignForward(usize, @sizeOf(Node) + aligned_index + n, 2);

                        if (arena.child_allocator.rawResize(allocated_slice, .of(Node), new_size, @returnAddress())) {
                            node.size = .fromInt(new_size);
                            break :candidate .{ node, best_fit_prev };
                        }
                    }
                    break :from_free_list;
                }
            };

            {
                var it = last_free;
                while (it) |node| : (it = node.next) {
                    last_free = node;
                }
            }

            const node = candidate orelse break :from_free_list;
            const old_next = node.next;

            const buf = node.allocatedSliceUnsafe()[@sizeOf(Node)..];
            const aligned_index = alignedIndex(buf.ptr, 0, alignment);

            node.end_index = aligned_index + n;
            node.next = first_node;

            switch (arena.tryPushNode(node)) {
                .success => {
                    // finish removing node from free list
                    if (prev) |p| p.next = old_next;
                    if (node == first_free) first_free = old_next;
                    if (node == last_free) last_free = prev;
                    return buf[aligned_index..][0..n].ptr;
                },
                .failure => |old_first_node| {
                    cur_first_node = old_first_node;
                    // restore free list to as we found it
                    node.next = old_next;
                    continue :retry;
                },
            }
        }

        const new_node: *Node = new_node: {
            if (cur_new_node) |new_node| {
                break :new_node new_node;
            } else {
                @branchHint(.cold);
            }

            const size: usize = size: {
                const min_size = @sizeOf(Node) + alignment.toByteUnits() + n;
                const big_enough_size = prev_size + min_size + 16;
                break :size mem.alignForward(usize, big_enough_size + big_enough_size / 2, 2);
            };
            const ptr = arena.child_allocator.rawAlloc(size, .of(Node), @returnAddress()) orelse
                return null;
            const new_node: *Node = @ptrCast(@alignCast(ptr));
            new_node.* = .{
                .size = .fromInt(size),
                .end_index = undefined, // set below
                .next = undefined, // set below
            };
            cur_new_node = new_node;
            break :new_node new_node;
        };

        const buf = new_node.allocatedSliceUnsafe()[@sizeOf(Node)..];
        const aligned_index = alignedIndex(buf.ptr, 0, alignment);
        assert(new_node.size.toInt() >= @sizeOf(Node) + aligned_index + n);

        new_node.end_index = aligned_index + n;
        new_node.next = first_node;

        switch (arena.tryPushNode(new_node)) {
            .success => {
                cur_new_node = null;
                return buf[aligned_index..][0..n].ptr;
            },
            .failure => |old_first_node| {
                cur_first_node = old_first_node;
            },
        }
    }
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;

    assert(buf.len > 0);
    assert(new_len > 0);
    if (buf.len == new_len) return true;

    const node = arena.loadFirstNode().?;
    const cur_buf_ptr = @as([*]u8, @ptrCast(node)) + @sizeOf(Node);

    var cur_end_index = @atomicLoad(usize, &node.end_index, .monotonic);
    while (true) {
        if (cur_buf_ptr + cur_end_index != buf.ptr + buf.len) {
            // It's not the most recent allocation, so it cannot be expanded,
            // but it's fine if they want to make it smaller.
            return new_len <= buf.len;
        }

        const new_end_index: usize = new_end_index: {
            if (buf.len >= new_len) {
                break :new_end_index cur_end_index - (buf.len - new_len);
            }
            const cur_buf_len: usize = node.loadBuf().len;
            // Saturating arithmetic because `end_index` and `size` are not
            // guaranteed to be in sync.
            if (cur_buf_len -| cur_end_index >= new_len - buf.len) {
                break :new_end_index cur_end_index + (new_len - buf.len);
            }
            return false;
        };

        cur_end_index = @cmpxchgWeak(
            usize,
            &node.end_index,
            cur_end_index,
            new_end_index,
            .monotonic,
            .monotonic,
        ) orelse {
            return true;
        };
    }
}

fn remap(
    context: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
}

fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
    const arena: *ArenaAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = ret_addr;

    assert(buf.len > 0);

    const node = arena.loadFirstNode().?;
    const cur_buf_ptr: [*]u8 = @as([*]u8, @ptrCast(node)) + @sizeOf(Node);

    var cur_end_index = @atomicLoad(usize, &node.end_index, .monotonic);
    while (true) {
        if (cur_buf_ptr + cur_end_index != buf.ptr + buf.len) {
            // Not the most recent allocation; we cannot free it.
            return;
        }
        const new_end_index = cur_end_index - buf.len;

        cur_end_index = @cmpxchgWeak(
            usize,
            &node.end_index,
            cur_end_index,
            new_end_index,
            .monotonic,
            .monotonic,
        ) orelse {
            return;
        };
    }
}

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

test "reset with preheating" {
    var arena_allocator = ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    // provides some variance in the allocated data
    var rng_src = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = rng_src.random();
    var rounds: usize = 25;
    while (rounds > 0) {
        rounds -= 1;
        _ = arena_allocator.reset(.retain_capacity);
        var alloced_bytes: usize = 0;
        const total_size: usize = random.intRangeAtMost(usize, 256, 16384);
        while (alloced_bytes < total_size) {
            const size = random.intRangeAtMost(usize, 16, 256);
            const alignment: Alignment = .@"32";
            const slice = try arena_allocator.allocator().alignedAlloc(u8, alignment, size);
            try std.testing.expect(alignment.check(@intFromPtr(slice.ptr)));
            try std.testing.expectEqual(size, slice.len);
            alloced_bytes += slice.len;
        }
    }
}

test "reset while retaining a buffer" {
    var arena_allocator = ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const a = arena_allocator.allocator();

    // Create two internal buffers
    _ = try a.alloc(u8, 1);
    _ = try a.alloc(u8, 1000);

    try std.testing.expect(arena_allocator.state.used_list != null);

    // Check that we have at least two buffers
    try std.testing.expect(arena_allocator.state.used_list.?.next != null);

    // This retains the first allocated buffer
    try std.testing.expect(arena_allocator.reset(.{ .retain_with_limit = 2 }));
    try std.testing.expect(arena_allocator.state.used_list.?.next == null);
    try std.testing.expectEqual(2, arena_allocator.queryCapacity());
}
