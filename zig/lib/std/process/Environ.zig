const Environ = @This();

const builtin = @import("builtin");
const native_os = builtin.os.tag;

const std = @import("../std.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const unicode = std.unicode;
const posix = std.posix;
const mem = std.mem;

/// Unmodified, unprocessed data provided by the operating system.
block: Block,

pub const empty: Environ = .{
    .block = switch (Block) {
        void => {},
        else => &.{},
    },
};

/// On WASI without libc, this is `void` because the environment has to be
/// queried and heap-allocated at runtime.
///
/// On Windows, the memory pointed at by the PEB changes when the environment
/// is modified, so a long-lived pointer cannot be used. Therefore, on this
/// operating system `void` is also used.
pub const Block = switch (native_os) {
    .windows => void,
    .wasi => switch (builtin.link_libc) {
        false => void,
        true => [:null]const ?[*:0]const u8,
    },
    .freestanding, .other => void,
    else => [:null]const ?[*:0]const u8,
};

pub const Map = struct {
    array_hash_map: ArrayHashMap,
    allocator: Allocator,

    const ArrayHashMap = std.ArrayHashMapUnmanaged([]const u8, []const u8, EnvNameHashContext, false);

    pub const Size = usize;

    pub const EnvNameHashContext = struct {
        fn upcase(c: u21) u21 {
            if (c <= std.math.maxInt(u16))
                return std.os.windows.ntdll.RtlUpcaseUnicodeChar(@as(u16, @intCast(c)));
            return c;
        }

        pub fn hash(self: @This(), s: []const u8) u32 {
            _ = self;
            if (native_os == .windows) {
                var h = std.hash.Wyhash.init(0);
                var it = unicode.Wtf8View.initUnchecked(s).iterator();
                while (it.nextCodepoint()) |cp| {
                    const cp_upper = upcase(cp);
                    h.update(&[_]u8{
                        @as(u8, @intCast((cp_upper >> 16) & 0xff)),
                        @as(u8, @intCast((cp_upper >> 8) & 0xff)),
                        @as(u8, @intCast((cp_upper >> 0) & 0xff)),
                    });
                }
                return @truncate(h.final());
            }
            return std.array_hash_map.hashString(s);
        }

        pub fn eql(self: @This(), a: []const u8, b: []const u8, b_index: usize) bool {
            _ = self;
            _ = b_index;
            if (native_os == .windows) {
                var it_a = unicode.Wtf8View.initUnchecked(a).iterator();
                var it_b = unicode.Wtf8View.initUnchecked(b).iterator();
                while (true) {
                    const c_a = it_a.nextCodepoint() orelse break;
                    const c_b = it_b.nextCodepoint() orelse return false;
                    if (upcase(c_a) != upcase(c_b))
                        return false;
                }
                return if (it_b.nextCodepoint()) |_| false else true;
            }
            return std.array_hash_map.eqlString(a, b);
        }
    };

    /// Create a Map backed by a specific allocator.
    /// That allocator will be used for both backing allocations
    /// and string deduplication.
    pub fn init(allocator: Allocator) Map {
        return .{ .array_hash_map = .empty, .allocator = allocator };
    }

    /// Free the backing storage of the map, as well as all
    /// of the stored keys and values.
    pub fn deinit(self: *Map) void {
        const gpa = self.allocator;
        var it = self.array_hash_map.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.array_hash_map.deinit(gpa);
        self.* = undefined;
    }

    pub fn keys(m: *const Map) [][]const u8 {
        return m.array_hash_map.keys();
    }

    pub fn values(m: *const Map) [][]const u8 {
        return m.array_hash_map.values();
    }

    /// Same as `put` but the key and value become owned by the Map rather
    /// than being copied.
    /// If `putMove` fails, the ownership of key and value does not transfer.
    /// On Windows `key` must be a valid [WTF-8](https://wtf-8.codeberg.page/) string.
    pub fn putMove(self: *Map, key: []u8, value: []u8) !void {
        const gpa = self.allocator;
        assert(unicode.wtf8ValidateSlice(key));
        const get_or_put = try self.array_hash_map.getOrPut(gpa, key);
        if (get_or_put.found_existing) {
            gpa.free(get_or_put.key_ptr.*);
            gpa.free(get_or_put.value_ptr.*);
            get_or_put.key_ptr.* = key;
        }
        get_or_put.value_ptr.* = value;
    }

    /// `key` and `value` are copied into the Map.
    /// On Windows `key` must be a valid [WTF-8](https://wtf-8.codeberg.page/) string.
    pub fn put(self: *Map, key: []const u8, value: []const u8) !void {
        assert(unicode.wtf8ValidateSlice(key));
        const gpa = self.allocator;
        const value_copy = try gpa.dupe(u8, value);
        errdefer gpa.free(value_copy);
        const get_or_put = try self.array_hash_map.getOrPut(gpa, key);
        errdefer {
            if (!get_or_put.found_existing) assert(self.array_hash_map.pop() != null);
        }
        if (get_or_put.found_existing) {
            gpa.free(get_or_put.value_ptr.*);
        } else {
            get_or_put.key_ptr.* = try gpa.dupe(u8, key);
        }
        get_or_put.value_ptr.* = value_copy;
    }

    /// Find the address of the value associated with a key.
    /// The returned pointer is invalidated if the map resizes.
    /// On Windows `key` must be a valid [WTF-8](https://wtf-8.codeberg.page/) string.
    pub fn getPtr(self: Map, key: []const u8) ?*[]const u8 {
        assert(unicode.wtf8ValidateSlice(key));
        return self.array_hash_map.getPtr(key);
    }

    /// Return the map's copy of the value associated with
    /// a key.  The returned string is invalidated if this
    /// key is removed from the map.
    /// On Windows `key` must be a valid [WTF-8](https://wtf-8.codeberg.page/) string.
    pub fn get(self: Map, key: []const u8) ?[]const u8 {
        assert(unicode.wtf8ValidateSlice(key));
        return self.array_hash_map.get(key);
    }

    pub fn contains(m: *const Map, key: []const u8) bool {
        return m.array_hash_map.contains(key);
    }

    /// If there is an entry with a matching key, it is deleted from the hash
    /// map. The entry is removed from the underlying array by swapping it with
    /// the last element.
    ///
    /// Returns true if an entry was removed, false otherwise.
    ///
    /// This invalidates the value returned by get() for this key.
    /// On Windows `key` must be a valid [WTF-8](https://wtf-8.codeberg.page/) string.
    pub fn swapRemove(self: *Map, key: []const u8) bool {
        assert(unicode.wtf8ValidateSlice(key));
        const kv = self.array_hash_map.fetchSwapRemove(key) orelse return false;
        const gpa = self.allocator;
        gpa.free(kv.key);
        gpa.free(kv.value);
        return true;
    }

    /// If there is an entry with a matching key, it is deleted from the map.
    /// The entry is removed from the underlying array by shifting all elements
    /// forward, thereby maintaining the current ordering.
    ///
    /// Returns true if an entry was removed, false otherwise.
    ///
    /// This invalidates the value returned by get() for this key.
    /// On Windows `key` must be a valid [WTF-8](https://wtf-8.codeberg.page/) string.
    pub fn orderedRemove(self: *Map, key: []const u8) bool {
        assert(unicode.wtf8ValidateSlice(key));
        const kv = self.array_hash_map.fetchOrderedRemove(key) orelse return false;
        const gpa = self.allocator;
        gpa.free(kv.key);
        gpa.free(kv.value);
        return true;
    }

    /// Returns the number of KV pairs stored in the map.
    pub fn count(self: Map) Size {
        return self.array_hash_map.count();
    }

    /// Returns an iterator over entries in the map.
    pub fn iterator(self: *const Map) ArrayHashMap.Iterator {
        return self.array_hash_map.iterator();
    }

    /// Returns a full copy of `em` allocated with `gpa`, which is not necessarily
    /// the same allocator used to allocate `em`.
    pub fn clone(m: *const Map, gpa: Allocator) Allocator.Error!Map {
        // Since we need to dupe the keys and values, the only way for error handling to not be a
        // nightmare is to add keys to an empty map one-by-one. This could be avoided if this
        // abstraction were a bit less... OOP-esque.
        var new: Map = .init(gpa);
        errdefer new.deinit();
        try new.array_hash_map.ensureUnusedCapacity(gpa, m.array_hash_map.count());
        for (m.array_hash_map.keys(), m.array_hash_map.values()) |key, value| {
            try new.put(key, value);
        }
        return new;
    }

    /// Creates a null-delimited environment variable block in the format
    /// expected by POSIX, from a hash map plus options.
    pub fn createBlockPosix(
        map: *const Map,
        arena: Allocator,
        options: CreateBlockPosixOptions,
    ) Allocator.Error![:null]?[*:0]u8 {
        const ZigProgressAction = enum { nothing, edit, delete, add };
        const zig_progress_action: ZigProgressAction = a: {
            const fd = options.zig_progress_fd orelse break :a .nothing;
            const exists = map.get("ZIG_PROGRESS") != null;
            if (fd >= 0) {
                break :a if (exists) .edit else .add;
            } else {
                if (exists) break :a .delete;
            }
            break :a .nothing;
        };

        const envp_count: usize = c: {
            var c: usize = map.count();
            switch (zig_progress_action) {
                .add => c += 1,
                .delete => c -= 1,
                .nothing, .edit => {},
            }
            break :c c;
        };

        const envp_buf = try arena.allocSentinel(?[*:0]u8, envp_count, null);
        var i: usize = 0;

        if (zig_progress_action == .add) {
            envp_buf[i] = try std.fmt.allocPrintSentinel(arena, "ZIG_PROGRESS={d}", .{options.zig_progress_fd.?}, 0);
            i += 1;
        }

        {
            var it = map.iterator();
            while (it.next()) |pair| {
                if (mem.eql(u8, pair.key_ptr.*, "ZIG_PROGRESS")) switch (zig_progress_action) {
                    .add => unreachable,
                    .delete => continue,
                    .edit => {
                        envp_buf[i] = try std.fmt.allocPrintSentinel(arena, "{s}={d}", .{
                            pair.key_ptr.*, options.zig_progress_fd.?,
                        }, 0);
                        i += 1;
                        continue;
                    },
                    .nothing => {},
                };

                envp_buf[i] = try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ pair.key_ptr.*, pair.value_ptr.* }, 0);
                i += 1;
            }
        }

        assert(i == envp_count);
        return envp_buf;
    }

    /// Caller owns result.
    pub fn createBlockWindows(map: *const Map, gpa: Allocator) error{ OutOfMemory, InvalidWtf8 }![:0]u16 {
        // count bytes needed
        const max_chars_needed = x: {
            // Only need 2 trailing NUL code units for an empty environment
            var max_chars_needed: usize = if (map.count() == 0) 2 else 1;
            var it = map.iterator();
            while (it.next()) |pair| {
                // +1 for '='
                // +1 for null byte
                max_chars_needed += pair.key_ptr.len + pair.value_ptr.len + 2;
            }
            break :x max_chars_needed;
        };
        const result = try gpa.alloc(u16, max_chars_needed);
        errdefer gpa.free(result);

        var it = map.iterator();
        var i: usize = 0;
        while (it.next()) |pair| {
            i += try unicode.wtf8ToWtf16Le(result[i..], pair.key_ptr.*);
            result[i] = '=';
            i += 1;
            i += try unicode.wtf8ToWtf16Le(result[i..], pair.value_ptr.*);
            result[i] = 0;
            i += 1;
        }
        result[i] = 0;
        i += 1;
        // An empty environment is a special case that requires a redundant
        // NUL terminator. CreateProcess will read the second code unit even
        // though theoretically the first should be enough to recognize that the
        // environment is empty (see https://nullprogram.com/blog/2023/08/23/)
        if (map.count() == 0) {
            result[i] = 0;
            i += 1;
        }
        const reallocated = try gpa.realloc(result, i);
        return reallocated[0 .. i - 1 :0];
    }
};

pub const CreateMapError = error{
    OutOfMemory,
    /// WASI-only. `environ_sizes_get` or `environ_get` failed for an
    /// unanticipated, undocumented reason.
    Unexpected,
};

/// Allocates a `Map` and copies environment block into it.
pub fn createMap(env: Environ, allocator: Allocator) CreateMapError!Map {
    if (native_os == .windows)
        return createMapWide(std.os.windows.peb().ProcessParameters.Environment, allocator);

    var result = Map.init(allocator);
    errdefer result.deinit();

    if (native_os == .wasi and !builtin.link_libc) {
        var environ_count: usize = undefined;
        var environ_buf_size: usize = undefined;

        const environ_sizes_get_ret = std.os.wasi.environ_sizes_get(&environ_count, &environ_buf_size);
        if (environ_sizes_get_ret != .SUCCESS) {
            return posix.unexpectedErrno(environ_sizes_get_ret);
        }

        if (environ_count == 0) {
            return result;
        }

        const environ = try allocator.alloc([*:0]u8, environ_count);
        defer allocator.free(environ);
        const environ_buf = try allocator.alloc(u8, environ_buf_size);
        defer allocator.free(environ_buf);

        const environ_get_ret = std.os.wasi.environ_get(environ.ptr, environ_buf.ptr);
        if (environ_get_ret != .SUCCESS) {
            return posix.unexpectedErrno(environ_get_ret);
        }

        for (environ) |line| {
            const pair = mem.sliceTo(line, 0);
            var parts = mem.splitScalar(u8, pair, '=');
            const key = parts.first();
            const value = parts.rest();
            try result.put(key, value);
        }
        return result;
    } else {
        for (env.block) |opt_line| {
            const line = opt_line.?;
            var line_i: usize = 0;
            while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
            const key = line[0..line_i];

            var end_i: usize = line_i;
            while (line[end_i] != 0) : (end_i += 1) {}
            const value = line[line_i + 1 .. end_i];

            try result.put(key, value);
        }
        return result;
    }
}

pub fn createMapWide(ptr: [*:0]u16, gpa: Allocator) CreateMapError!Map {
    var result = Map.init(gpa);
    errdefer result.deinit();

    var i: usize = 0;
    while (ptr[i] != 0) {
        const key_start = i;

        // There are some special environment variables that start with =,
        // so we need a special case to not treat = as a key/value separator
        // if it's the first character.
        // https://devblogs.microsoft.com/oldnewthing/20100506-00/?p=14133
        if (ptr[key_start] == '=') i += 1;

        while (ptr[i] != 0 and ptr[i] != '=') : (i += 1) {}
        const key_w = ptr[key_start..i];
        const key = try unicode.wtf16LeToWtf8Alloc(gpa, key_w);
        errdefer gpa.free(key);

        if (ptr[i] == '=') i += 1;

        const value_start = i;
        while (ptr[i] != 0) : (i += 1) {}
        const value_w = ptr[value_start..i];
        const value = try unicode.wtf16LeToWtf8Alloc(gpa, value_w);
        errdefer gpa.free(value);

        i += 1; // skip over null byte

        try result.putMove(key, value);
    }
    return result;
}

pub const ContainsError = error{
    OutOfMemory,
    /// On Windows, environment variable keys provided by the user must be
    /// valid [WTF-8](https://wtf-8.codeberg.page/). This error is unreachable
    /// if the key is statically known to be valid.
    InvalidWtf8,
    /// WASI-only. `environ_sizes_get` or `environ_get` failed for an
    /// unexpected reason.
    Unexpected,
};

/// On Windows, if `key` is not valid [WTF-8](https://wtf-8.codeberg.page/),
/// then `error.InvalidWtf8` is returned.
///
/// See also:
/// * `createMap`
/// * `containsConstant`
/// * `containsUnempty`
pub fn contains(environ: Environ, gpa: Allocator, key: []const u8) ContainsError!bool {
    var map = try createMap(environ, gpa);
    defer map.deinit();
    return map.contains(key);
}

/// On Windows, if `key` is not valid [WTF-8](https://wtf-8.codeberg.page/),
/// then `error.InvalidWtf8` is returned.
///
/// See also:
/// * `createMap`
/// * `containsUnemptyConstant`
/// * `contains`
pub fn containsUnempty(environ: Environ, gpa: Allocator, key: []const u8) ContainsError!bool {
    var map = try createMap(environ, gpa);
    defer map.deinit();
    const value = map.get(key) orelse return false;
    return value.len != 0;
}

/// This function is unavailable on WASI without libc due to the memory
/// allocation requirement.
///
/// On Windows, `key` must be valid [WTF-8](https://wtf-8.codeberg.page/),
///
/// See also:
/// * `contains`
/// * `containsUnemptyConstant`
/// * `createMap`
pub inline fn containsConstant(environ: Environ, comptime key: []const u8) bool {
    if (native_os == .windows) {
        const key_w = comptime unicode.wtf8ToWtf16LeStringLiteral(key);
        return getWindows(environ, key_w) != null;
    } else {
        return getPosix(environ, key) != null;
    }
}

/// This function is unavailable on WASI without libc due to the memory
/// allocation requirement.
///
/// On Windows, `key` must be valid [WTF-8](https://wtf-8.codeberg.page/),
///
/// See also:
/// * `containsUnempty`
/// * `containsConstant`
/// * `createMap`
pub inline fn containsUnemptyConstant(environ: Environ, comptime key: []const u8) bool {
    if (native_os == .windows) {
        const key_w = comptime unicode.wtf8ToWtf16LeStringLiteral(key);
        const value = getWindows(environ, key_w) orelse return false;
        return value.len != 0;
    } else {
        const value = getPosix(environ, key) orelse return false;
        return value.len != 0;
    }
}

/// This function is unavailable on WASI without libc due to the memory
/// allocation requirement.
///
/// See also:
/// * `getWindows`
/// * `createMap`
pub fn getPosix(environ: Environ, key: []const u8) ?[:0]const u8 {
    if (mem.findScalar(u8, key, '=') != null) return null;
    for (environ.block) |opt_line| {
        const line = opt_line.?;
        var line_i: usize = 0;
        while (line[line_i] != 0) : (line_i += 1) {
            if (line_i == key.len) break;
            if (line[line_i] != key[line_i]) break;
        }
        if ((line_i != key.len) or (line[line_i] != '=')) continue;

        return mem.sliceTo(line + line_i + 1, 0);
    }
    return null;
}

/// Windows-only. Get an environment variable with a null-terminated, WTF-16
/// encoded name.
///
/// This function performs a Unicode-aware case-insensitive lookup using
/// RtlEqualUnicodeString.
///
/// See also:
/// * `createMap`
/// * `containsConstant`
/// * `contains`
pub fn getWindows(environ: Environ, key: [*:0]const u16) ?[:0]const u16 {
    comptime assert(native_os == .windows);
    comptime assert(@TypeOf(environ.block) == void);

    // '=' anywhere but the start makes this an invalid environment variable name.
    const key_slice = mem.sliceTo(key, 0);
    if (key_slice.len > 0 and mem.findScalar(u16, key_slice[1..], '=') != null) return null;

    const ptr = std.os.windows.peb().ProcessParameters.Environment;

    var i: usize = 0;
    while (ptr[i] != 0) {
        const key_value = mem.sliceTo(ptr[i..], 0);

        // There are some special environment variables that start with =,
        // so we need a special case to not treat = as a key/value separator
        // if it's the first character.
        // https://devblogs.microsoft.com/oldnewthing/20100506-00/?p=14133
        const equal_search_start: usize = if (key_value[0] == '=') 1 else 0;
        const equal_index = mem.findScalarPos(u16, key_value, equal_search_start, '=') orelse {
            // This is enforced by CreateProcess.
            // If violated, CreateProcess will fail with INVALID_PARAMETER.
            unreachable; // must contain a =
        };

        const this_key = key_value[0..equal_index];
        if (std.os.windows.eqlIgnoreCaseWtf16(key_slice, this_key)) {
            return key_value[equal_index + 1 ..];
        }

        // skip past the NUL terminator
        i += key_value.len + 1;
    }
    return null;
}

pub const GetAllocError = error{
    OutOfMemory,
    EnvironmentVariableMissing,
    /// On Windows, environment variable keys provided by the user must be
    /// valid [WTF-8](https://wtf-8.codeberg.page/). This error is unreachable
    /// if the key is statically known to be valid.
    InvalidWtf8,
};

/// Caller owns returned memory.
///
/// On Windows:
/// * If `key` is not valid [WTF-8](https://wtf-8.codeberg.page/), then
///   `error.InvalidWtf8` is returned.
/// * The returned value is encoded as [WTF-8](https://wtf-8.codeberg.page/).
///
/// On other platforms, the value is an opaque sequence of bytes with no
/// particular encoding.
///
/// See also:
/// * `createMap`
pub fn getAlloc(environ: Environ, gpa: Allocator, key: []const u8) GetAllocError![]u8 {
    var map = createMap(environ, gpa) catch return error.OutOfMemory;
    defer map.deinit();
    const val = map.get(key) orelse return error.EnvironmentVariableMissing;
    return gpa.dupe(u8, val);
}

pub const CreateBlockPosixOptions = struct {
    /// `null` means to leave the `ZIG_PROGRESS` environment variable unmodified.
    /// If non-null, negative means to remove the environment variable, and >= 0
    /// means to provide it with the given integer.
    zig_progress_fd: ?i32 = null,
};

/// Creates a null-delimited environment variable block in the format expected
/// by POSIX, from a different one.
pub fn createBlockPosix(
    existing: Environ,
    arena: Allocator,
    options: CreateBlockPosixOptions,
) Allocator.Error![:null]?[*:0]u8 {
    const contains_zig_progress = for (existing.block) |opt_line| {
        if (mem.eql(u8, mem.sliceTo(opt_line.?, '='), "ZIG_PROGRESS")) break true;
    } else false;

    const ZigProgressAction = enum { nothing, edit, delete, add };
    const zig_progress_action: ZigProgressAction = a: {
        const fd = options.zig_progress_fd orelse break :a .nothing;
        if (fd >= 0) {
            break :a if (contains_zig_progress) .edit else .add;
        } else {
            if (contains_zig_progress) break :a .delete;
        }
        break :a .nothing;
    };

    const envp_count: usize = c: {
        var count: usize = existing.block.len;
        switch (zig_progress_action) {
            .add => count += 1,
            .delete => count -= 1,
            .nothing, .edit => {},
        }
        break :c count;
    };

    const envp_buf = try arena.allocSentinel(?[*:0]u8, envp_count, null);
    var i: usize = 0;
    var existing_index: usize = 0;

    if (zig_progress_action == .add) {
        envp_buf[i] = try std.fmt.allocPrintSentinel(arena, "ZIG_PROGRESS={d}", .{options.zig_progress_fd.?}, 0);
        i += 1;
    }

    while (existing.block[existing_index]) |line| : (existing_index += 1) {
        if (mem.eql(u8, mem.sliceTo(line, '='), "ZIG_PROGRESS")) switch (zig_progress_action) {
            .add => unreachable,
            .delete => continue,
            .edit => {
                envp_buf[i] = try std.fmt.allocPrintSentinel(arena, "ZIG_PROGRESS={d}", .{options.zig_progress_fd.?}, 0);
                i += 1;
                continue;
            },
            .nothing => {},
        };
        envp_buf[i] = try arena.dupeZ(u8, mem.span(line));
        i += 1;
    }

    assert(i == envp_count);
    return envp_buf;
}

test "Map.createBlock" {
    const allocator = testing.allocator;
    var envmap = Map.init(allocator);
    defer envmap.deinit();

    try envmap.put("HOME", "/home/ifreund");
    try envmap.put("WAYLAND_DISPLAY", "wayland-1");
    try envmap.put("DISPLAY", ":1");
    try envmap.put("DEBUGINFOD_URLS", " ");
    try envmap.put("XCURSOR_SIZE", "24");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const environ = try envmap.createBlockPosix(arena.allocator(), .{});

    try testing.expectEqual(@as(usize, 5), environ.len);

    inline for (.{
        "HOME=/home/ifreund",
        "WAYLAND_DISPLAY=wayland-1",
        "DISPLAY=:1",
        "DEBUGINFOD_URLS= ",
        "XCURSOR_SIZE=24",
    }) |target| {
        for (environ) |variable| {
            if (mem.eql(u8, mem.span(variable orelse continue), target)) break;
        } else {
            try testing.expect(false); // Environment variable not found
        }
    }
}

test Map {
    var env = Map.init(testing.allocator);
    defer env.deinit();

    try env.put("SOMETHING_NEW", "hello");
    try testing.expectEqualStrings("hello", env.get("SOMETHING_NEW").?);
    try testing.expectEqual(@as(Map.Size, 1), env.count());

    // overwrite
    try env.put("SOMETHING_NEW", "something");
    try testing.expectEqualStrings("something", env.get("SOMETHING_NEW").?);
    try testing.expectEqual(@as(Map.Size, 1), env.count());

    // a new longer name to test the Windows-specific conversion buffer
    try env.put("SOMETHING_NEW_AND_LONGER", "1");
    try testing.expectEqualStrings("1", env.get("SOMETHING_NEW_AND_LONGER").?);
    try testing.expectEqual(@as(Map.Size, 2), env.count());

    // case insensitivity on Windows only
    if (native_os == .windows) {
        try testing.expectEqualStrings("1", env.get("something_New_aNd_LONGER").?);
    } else {
        try testing.expect(null == env.get("something_New_aNd_LONGER"));
    }

    var it = env.iterator();
    var count: Map.Size = 0;
    while (it.next()) |entry| {
        const is_an_expected_name = mem.eql(u8, "SOMETHING_NEW", entry.key_ptr.*) or mem.eql(u8, "SOMETHING_NEW_AND_LONGER", entry.key_ptr.*);
        try testing.expect(is_an_expected_name);
        count += 1;
    }
    try testing.expectEqual(@as(Map.Size, 2), count);

    try testing.expect(env.swapRemove("SOMETHING_NEW"));
    try testing.expect(!env.swapRemove("SOMETHING_NEW"));
    try testing.expect(env.get("SOMETHING_NEW") == null);

    try testing.expectEqual(@as(Map.Size, 1), env.count());

    if (native_os == .windows) {
        // test Unicode case-insensitivity on Windows
        try env.put("КИРиллИЦА", "something else");
        try testing.expectEqualStrings("something else", env.get("кириллица").?);

        // and WTF-8 that's not valid UTF-8
        const wtf8_with_surrogate_pair = try unicode.wtf16LeToWtf8Alloc(testing.allocator, &[_]u16{
            mem.nativeToLittle(u16, 0xD83D), // unpaired high surrogate
        });
        defer testing.allocator.free(wtf8_with_surrogate_pair);

        try env.put(wtf8_with_surrogate_pair, wtf8_with_surrogate_pair);
        try testing.expectEqualSlices(u8, wtf8_with_surrogate_pair, env.get(wtf8_with_surrogate_pair).?);
    }
}

test "convert from Environ to Map and back again" {
    if (native_os == .windows) return;
    if (native_os == .wasi and !builtin.link_libc) return;

    const gpa = testing.allocator;

    var map: Map = .init(gpa);
    defer map.deinit();
    try map.put("FOO", "BAR");
    try map.put("A", "");
    try map.put("", "B");

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const environ: Environ = .{ .block = try map.createBlockPosix(arena, .{}) };

    try testing.expectEqual(true, environ.contains(gpa, "FOO"));
    try testing.expectEqual(false, environ.contains(gpa, "BAR"));
    try testing.expectEqual(true, environ.contains(gpa, "A"));
    try testing.expectEqual(true, environ.containsConstant("A"));
    try testing.expectEqual(false, environ.containsUnempty(gpa, "A"));
    try testing.expectEqual(false, environ.containsUnemptyConstant("A"));
    try testing.expectEqual(true, environ.contains(gpa, ""));
    try testing.expectEqual(false, environ.contains(gpa, "B"));

    try testing.expectError(error.EnvironmentVariableMissing, environ.getAlloc(gpa, "BOGUS"));
    {
        const value = try environ.getAlloc(gpa, "FOO");
        defer gpa.free(value);
        try testing.expectEqualStrings("BAR", value);
    }

    var map2 = try environ.createMap(gpa);
    defer map2.deinit();

    try testing.expectEqualDeep(map.keys(), map2.keys());
    try testing.expectEqualDeep(map.values(), map2.values());
}

test createMapWide {
    if (builtin.cpu.arch.endian() == .big) return error.SkipZigTest; // TODO

    const gpa = testing.allocator;

    var map: Map = .init(gpa);
    defer map.deinit();
    try map.put("FOO", "BAR");
    try map.put("A", "");
    try map.put("", "B");

    const environ: [:0]u16 = try map.createBlockWindows(gpa);
    defer gpa.free(environ);

    var map2 = try createMapWide(environ, gpa);
    defer map2.deinit();

    try testing.expectEqualDeep(&[_][]const u8{ "FOO", "A", "=B" }, map2.keys());
    try testing.expectEqualDeep(&[_][]const u8{ "BAR", "", "" }, map2.values());
}
