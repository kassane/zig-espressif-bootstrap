//! A cross-platform interface that abstracts all I/O operations and
//! concurrency. It includes:
//! * file system
//! * networking
//! * processes
//! * time and sleeping
//! * randomness
//! * async, await, concurrent, and cancel
//! * concurrent queues
//! * wait groups and select
//! * mutexes, futexes, events, and conditions
//! * memory mapped files
//! This interface allows programmers to write optimal, reusable code while
//! participating in these operations.
const Io = @This();

const builtin = @import("builtin");

const std = @import("std.zig");
const math = std.math;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

userdata: ?*anyopaque,
vtable: *const VTable,

pub const Threaded = @import("Io/Threaded.zig");

pub const fiber = @import("Io/fiber.zig");
pub const Evented = if (fiber.supported) switch (builtin.os.tag) {
    .linux => Uring,
    .dragonfly, .freebsd, .netbsd, .openbsd => Kqueue,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => Dispatch,
    else => void,
} else void; // context-switching code not implemented yet
pub const Dispatch = @import("Io/Dispatch.zig");
pub const Kqueue = @import("Io/Kqueue.zig");
pub const Uring = @import("Io/Uring.zig");

pub const Reader = @import("Io/Reader.zig");
pub const Writer = @import("Io/Writer.zig");
pub const net = @import("Io/net.zig");
pub const Dir = @import("Io/Dir.zig");
pub const File = @import("Io/File.zig");
pub const Terminal = @import("Io/Terminal.zig");

pub const RwLock = @import("Io/RwLock.zig");
pub const Semaphore = @import("Io/Semaphore.zig");

pub const VTable = struct {
    crashHandler: *const fn (?*anyopaque) void,

    /// If it returns `null` it means `result` has been already populated and
    /// `await` will be a no-op.
    ///
    /// When this function returns non-null, the implementation guarantees that
    /// a unit of concurrency has been assigned to the returned task.
    ///
    /// Thread-safe.
    async: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// The pointer of this slice is an "eager" result value.
        /// The length is the size in bytes of the result type.
        /// This pointer's lifetime expires directly after the call to this function.
        result: []u8,
        result_alignment: std.mem.Alignment,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ?*AnyFuture,
    /// Thread-safe.
    concurrent: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ConcurrentError!*AnyFuture,
    /// This function is only called when `async` returns a non-null value.
    ///
    /// Thread-safe.
    await: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// The same value that was returned from `async`.
        any_future: *AnyFuture,
        /// Points to a buffer where the result is written.
        /// The length is equal to size in bytes of result type.
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void,
    /// Equivalent to `await` but initiates cancel request.
    ///
    /// This function is only called when `async` returns a non-null value.
    ///
    /// Thread-safe.
    cancel: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// The same value that was returned from `async`.
        any_future: *AnyFuture,
        /// Points to a buffer where the result is written.
        /// The length is equal to size in bytes of result type.
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void,

    /// When this function returns, implementation guarantees that `start` has
    /// either already been called, or a unit of concurrency has been assigned
    /// to the task of calling the function.
    ///
    /// Thread-safe.
    groupAsync: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// Owner of the spawned async task.
        group: *Group,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) Cancelable!void,
    ) void,
    /// Thread-safe.
    groupConcurrent: *const fn (
        /// Corresponds to `Io.userdata`.
        userdata: ?*anyopaque,
        /// Owner of the spawned async task.
        group: *Group,
        /// Copied and then passed to `start`.
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) Cancelable!void,
    ) ConcurrentError!void,
    groupAwait: *const fn (?*anyopaque, *Group, token: *anyopaque) Cancelable!void,
    groupCancel: *const fn (?*anyopaque, *Group, token: *anyopaque) void,

    recancel: *const fn (?*anyopaque) void,
    swapCancelProtection: *const fn (?*anyopaque, new: CancelProtection) CancelProtection,
    checkCancel: *const fn (?*anyopaque) Cancelable!void,

    /// Blocks until one of the futures from the list has a result ready, such
    /// that awaiting it will not block. Returns that index.
    select: *const fn (?*anyopaque, futures: []const *AnyFuture) Cancelable!usize,

    futexWait: *const fn (?*anyopaque, ptr: *const u32, expected: u32, Timeout) Cancelable!void,
    futexWaitUncancelable: *const fn (?*anyopaque, ptr: *const u32, expected: u32) void,
    futexWake: *const fn (?*anyopaque, ptr: *const u32, max_waiters: u32) void,

    operate: *const fn (?*anyopaque, Operation) Cancelable!Operation.Result,
    batchAwaitAsync: *const fn (?*anyopaque, *Batch) Cancelable!void,
    batchAwaitConcurrent: *const fn (?*anyopaque, *Batch, Timeout) Batch.AwaitConcurrentError!void,
    batchCancel: *const fn (?*anyopaque, *Batch) void,

    dirCreateDir: *const fn (?*anyopaque, Dir, []const u8, Dir.Permissions) Dir.CreateDirError!void,
    dirCreateDirPath: *const fn (?*anyopaque, Dir, []const u8, Dir.Permissions) Dir.CreateDirPathError!Dir.CreatePathStatus,
    dirCreateDirPathOpen: *const fn (?*anyopaque, Dir, []const u8, Dir.Permissions, Dir.OpenOptions) Dir.CreateDirPathOpenError!Dir,
    dirOpenDir: *const fn (?*anyopaque, Dir, []const u8, Dir.OpenOptions) Dir.OpenError!Dir,
    dirStat: *const fn (?*anyopaque, Dir) Dir.StatError!Dir.Stat,
    dirStatFile: *const fn (?*anyopaque, Dir, []const u8, Dir.StatFileOptions) Dir.StatFileError!File.Stat,
    dirAccess: *const fn (?*anyopaque, Dir, []const u8, Dir.AccessOptions) Dir.AccessError!void,
    dirCreateFile: *const fn (?*anyopaque, Dir, []const u8, File.CreateFlags) File.OpenError!File,
    dirCreateFileAtomic: *const fn (?*anyopaque, Dir, []const u8, Dir.CreateFileAtomicOptions) Dir.CreateFileAtomicError!File.Atomic,
    dirOpenFile: *const fn (?*anyopaque, Dir, []const u8, File.OpenFlags) File.OpenError!File,
    dirClose: *const fn (?*anyopaque, []const Dir) void,
    dirRead: *const fn (?*anyopaque, *Dir.Reader, []Dir.Entry) Dir.Reader.Error!usize,
    dirRealPath: *const fn (?*anyopaque, Dir, out_buffer: []u8) Dir.RealPathError!usize,
    dirRealPathFile: *const fn (?*anyopaque, Dir, path_name: []const u8, out_buffer: []u8) Dir.RealPathFileError!usize,
    dirDeleteFile: *const fn (?*anyopaque, Dir, []const u8) Dir.DeleteFileError!void,
    dirDeleteDir: *const fn (?*anyopaque, Dir, []const u8) Dir.DeleteDirError!void,
    dirRename: *const fn (?*anyopaque, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) Dir.RenameError!void,
    dirRenamePreserve: *const fn (?*anyopaque, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) Dir.RenamePreserveError!void,
    dirSymLink: *const fn (?*anyopaque, Dir, target_path: []const u8, sym_link_path: []const u8, Dir.SymLinkFlags) Dir.SymLinkError!void,
    dirReadLink: *const fn (?*anyopaque, Dir, sub_path: []const u8, buffer: []u8) Dir.ReadLinkError!usize,
    dirSetOwner: *const fn (?*anyopaque, Dir, ?File.Uid, ?File.Gid) Dir.SetOwnerError!void,
    dirSetFileOwner: *const fn (?*anyopaque, Dir, []const u8, ?File.Uid, ?File.Gid, Dir.SetFileOwnerOptions) Dir.SetFileOwnerError!void,
    dirSetPermissions: *const fn (?*anyopaque, Dir, Dir.Permissions) Dir.SetPermissionsError!void,
    dirSetFilePermissions: *const fn (?*anyopaque, Dir, []const u8, File.Permissions, Dir.SetFilePermissionsOptions) Dir.SetFilePermissionsError!void,
    dirSetTimestamps: *const fn (?*anyopaque, Dir, []const u8, Dir.SetTimestampsOptions) Dir.SetTimestampsError!void,
    dirHardLink: *const fn (?*anyopaque, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8, Dir.HardLinkOptions) Dir.HardLinkError!void,

    fileStat: *const fn (?*anyopaque, File) File.StatError!File.Stat,
    fileLength: *const fn (?*anyopaque, File) File.LengthError!u64,
    fileClose: *const fn (?*anyopaque, []const File) void,
    fileWritePositional: *const fn (?*anyopaque, File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) File.WritePositionalError!usize,
    fileWriteFileStreaming: *const fn (?*anyopaque, File, header: []const u8, *Io.File.Reader, Io.Limit) File.Writer.WriteFileError!usize,
    fileWriteFilePositional: *const fn (?*anyopaque, File, header: []const u8, *Io.File.Reader, Io.Limit, offset: u64) File.WriteFilePositionalError!usize,
    /// Returns 0 if reading at or past the end.
    fileReadPositional: *const fn (?*anyopaque, File, data: []const []u8, offset: u64) File.ReadPositionalError!usize,
    fileSeekBy: *const fn (?*anyopaque, File, relative_offset: i64) File.SeekError!void,
    fileSeekTo: *const fn (?*anyopaque, File, absolute_offset: u64) File.SeekError!void,
    fileSync: *const fn (?*anyopaque, File) File.SyncError!void,
    fileIsTty: *const fn (?*anyopaque, File) Cancelable!bool,
    fileEnableAnsiEscapeCodes: *const fn (?*anyopaque, File) File.EnableAnsiEscapeCodesError!void,
    fileSupportsAnsiEscapeCodes: *const fn (?*anyopaque, File) Cancelable!bool,
    fileSetLength: *const fn (?*anyopaque, File, u64) File.SetLengthError!void,
    fileSetOwner: *const fn (?*anyopaque, File, ?File.Uid, ?File.Gid) File.SetOwnerError!void,
    fileSetPermissions: *const fn (?*anyopaque, File, File.Permissions) File.SetPermissionsError!void,
    fileSetTimestamps: *const fn (?*anyopaque, File, File.SetTimestampsOptions) File.SetTimestampsError!void,
    fileLock: *const fn (?*anyopaque, File, File.Lock) File.LockError!void,
    fileTryLock: *const fn (?*anyopaque, File, File.Lock) File.LockError!bool,
    fileUnlock: *const fn (?*anyopaque, File) void,
    fileDowngradeLock: *const fn (?*anyopaque, File) File.DowngradeLockError!void,
    fileRealPath: *const fn (?*anyopaque, File, out_buffer: []u8) File.RealPathError!usize,
    fileHardLink: *const fn (?*anyopaque, File, Dir, []const u8, File.HardLinkOptions) File.HardLinkError!void,

    fileMemoryMapCreate: *const fn (?*anyopaque, File, File.MemoryMap.CreateOptions) File.MemoryMap.CreateError!File.MemoryMap,
    fileMemoryMapDestroy: *const fn (?*anyopaque, *File.MemoryMap) void,
    fileMemoryMapSetLength: *const fn (?*anyopaque, *File.MemoryMap, usize) File.MemoryMap.SetLengthError!void,
    fileMemoryMapRead: *const fn (?*anyopaque, *File.MemoryMap) File.ReadPositionalError!void,
    fileMemoryMapWrite: *const fn (?*anyopaque, *File.MemoryMap) File.WritePositionalError!void,

    processExecutableOpen: *const fn (?*anyopaque, File.OpenFlags) std.process.OpenExecutableError!File,
    processExecutablePath: *const fn (?*anyopaque, buffer: []u8) std.process.ExecutablePathError!usize,
    lockStderr: *const fn (?*anyopaque, ?Terminal.Mode) Cancelable!LockedStderr,
    tryLockStderr: *const fn (?*anyopaque, ?Terminal.Mode) Cancelable!?LockedStderr,
    unlockStderr: *const fn (?*anyopaque) void,
    processCurrentPath: *const fn (?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize,
    processSetCurrentDir: *const fn (?*anyopaque, Dir) std.process.SetCurrentDirError!void,
    processReplace: *const fn (?*anyopaque, std.process.ReplaceOptions) std.process.ReplaceError,
    processReplacePath: *const fn (?*anyopaque, Dir, std.process.ReplaceOptions) std.process.ReplaceError,
    processSpawn: *const fn (?*anyopaque, std.process.SpawnOptions) std.process.SpawnError!std.process.Child,
    processSpawnPath: *const fn (?*anyopaque, Dir, std.process.SpawnOptions) std.process.SpawnError!std.process.Child,
    childWait: *const fn (?*anyopaque, *std.process.Child) std.process.Child.WaitError!std.process.Child.Term,
    childKill: *const fn (?*anyopaque, *std.process.Child) void,

    progressParentFile: *const fn (?*anyopaque) std.Progress.ParentFileError!File,

    now: *const fn (?*anyopaque, Clock) Timestamp,
    clockResolution: *const fn (?*anyopaque, Clock) Clock.ResolutionError!Duration,
    sleep: *const fn (?*anyopaque, Timeout) Cancelable!void,

    random: *const fn (?*anyopaque, buffer: []u8) void,
    randomSecure: *const fn (?*anyopaque, buffer: []u8) RandomSecureError!void,

    netListenIp: *const fn (?*anyopaque, address: net.IpAddress, net.IpAddress.ListenOptions) net.IpAddress.ListenError!net.Server,
    netAccept: *const fn (?*anyopaque, server: net.Socket.Handle) net.Server.AcceptError!net.Stream,
    netBindIp: *const fn (?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.BindOptions) net.IpAddress.BindError!net.Socket,
    netConnectIp: *const fn (?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Stream,
    netListenUnix: *const fn (?*anyopaque, *const net.UnixAddress, net.UnixAddress.ListenOptions) net.UnixAddress.ListenError!net.Socket.Handle,
    netConnectUnix: *const fn (?*anyopaque, *const net.UnixAddress) net.UnixAddress.ConnectError!net.Socket.Handle,
    netSocketCreatePair: *const fn (?*anyopaque, net.Socket.CreatePairOptions) net.Socket.CreatePairError![2]net.Socket,
    netSend: *const fn (?*anyopaque, net.Socket.Handle, []net.OutgoingMessage, net.SendFlags) struct { ?net.Socket.SendError, usize },
    netReceive: *const fn (?*anyopaque, net.Socket.Handle, message_buffer: []net.IncomingMessage, data_buffer: []u8, net.ReceiveFlags, Timeout) struct { ?net.Socket.ReceiveTimeoutError, usize },
    /// Returns 0 on end of stream.
    netRead: *const fn (?*anyopaque, src: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize,
    netWrite: *const fn (?*anyopaque, dest: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize,
    netWriteFile: *const fn (?*anyopaque, net.Socket.Handle, header: []const u8, *Io.File.Reader, Io.Limit) net.Stream.Writer.WriteFileError!usize,
    netClose: *const fn (?*anyopaque, handle: []const net.Socket.Handle) void,
    netShutdown: *const fn (?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void,
    netInterfaceNameResolve: *const fn (?*anyopaque, *const net.Interface.Name) net.Interface.Name.ResolveError!net.Interface,
    netInterfaceName: *const fn (?*anyopaque, net.Interface) net.Interface.NameError!net.Interface.Name,
    netLookup: *const fn (?*anyopaque, net.HostName, *Queue(net.HostName.LookupResult), net.HostName.LookupOptions) net.HostName.LookupError!void,
};

pub const Operation = union(enum) {
    file_read_streaming: FileReadStreaming,
    file_write_streaming: FileWriteStreaming,
    /// On Windows this is NtDeviceIoControlFile. On POSIX this is ioctl. On
    /// other systems this tag is unreachable.
    device_io_control: DeviceIoControl,

    pub const Tag = @typeInfo(Operation).@"union".tag_type.?;

    /// May return 0 reads which is different than `error.EndOfStream`.
    pub const FileReadStreaming = struct {
        file: File,
        data: []const []u8,

        pub const Error = UnendingError || error{EndOfStream};
        pub const UnendingError = error{
            InputOutput,
            SystemResources,
            /// Trying to read a directory file descriptor as if it were a file.
            IsDir,
            ConnectionResetByPeer,
            /// File was not opened with read capability.
            NotOpenForReading,
            SocketUnconnected,
            /// Non-blocking has been enabled, and reading from the file descriptor
            /// would block.
            WouldBlock,
            /// In WASI, this error occurs when the file descriptor does
            /// not hold the required rights to read from it.
            AccessDenied,
            /// Unable to read file due to lock. Depending on the `Io` implementation,
            /// reading from a locked file may return this error, or may ignore the
            /// lock.
            LockViolation,
        } || Io.UnexpectedError;

        pub const Result = Error!usize;
    };

    pub const FileWriteStreaming = struct {
        file: File,
        header: []const u8 = &.{},
        data: []const []const u8,
        splat: usize = 1,

        pub const Error = error{
            DiskQuota,
            FileTooBig,
            InputOutput,
            NoSpaceLeft,
            DeviceBusy,
            /// File descriptor does not hold the required rights to write to it.
            AccessDenied,
            PermissionDenied,
            /// File is an unconnected socket, or closed its read end.
            BrokenPipe,
            /// Insufficient kernel memory to read from in_fd.
            SystemResources,
            NotOpenForWriting,
            /// The process cannot access the file because another process has locked
            /// a portion of the file. Windows-only.
            LockViolation,
            /// Non-blocking has been enabled and this operation would block.
            WouldBlock,
            /// This error occurs when a device gets disconnected before or mid-flush
            /// while it's being written to - errno(6): No such device or address.
            NoDevice,
            FileBusy,
        } || Io.UnexpectedError;

        pub const Result = Error!usize;
    };

    pub const DeviceIoControl = switch (builtin.os.tag) {
        .wasi => noreturn,
        .windows => struct {
            file: File,
            code: std.os.windows.CTL_CODE,
            in: []const u8 = &.{},
            out: []u8 = &.{},

            pub const Result = std.os.windows.IO_STATUS_BLOCK;
        },
        else => struct {
            file: File,
            /// Device-dependent operation code.
            code: u32,
            arg: ?*anyopaque,

            /// Device and operation dependent result. Negative values are
            /// negative errno.
            pub const Result = i32;
        },
    };

    pub const Result = Result: {
        const operation_fields = @typeInfo(Operation).@"union".fields;
        var field_names: [operation_fields.len][]const u8 = undefined;
        var field_types: [operation_fields.len]type = undefined;
        for (operation_fields, &field_names, &field_types) |field, *field_name, *field_type| {
            field_name.* = field.name;
            field_type.* = if (field.type == noreturn) noreturn else field.type.Result;
        }
        break :Result @Union(.auto, Tag, &field_names, &field_types, &@splat(.{}));
    };

    pub const Storage = union {
        unused: List.DoubleNode,
        submission: Submission,
        pending: Pending,
        completion: Completion,

        pub const Submission = struct {
            node: List.SingleNode,
            operation: Operation,
        };

        pub const Pending = struct {
            node: List.DoubleNode,
            tag: Tag,
            userdata: Userdata align(@max(@alignOf(usize), 4)),

            pub const Userdata = [7]usize;
        };

        pub const Completion = struct {
            node: List.SingleNode,
            result: Result,
        };
    };

    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn fromIndex(i: usize) OptionalIndex {
            const oi: OptionalIndex = @enumFromInt(i);
            assert(oi != .none);
            return oi;
        }

        pub fn toIndex(oi: OptionalIndex) u32 {
            assert(oi != .none);
            return @intFromEnum(oi);
        }
    };
    pub const List = struct {
        head: OptionalIndex,
        tail: OptionalIndex,

        pub const empty: List = .{ .head = .none, .tail = .none };

        pub const SingleNode = struct { next: OptionalIndex };
        pub const DoubleNode = struct { prev: OptionalIndex, next: OptionalIndex };
    };
};

/// Performs one `Operation`.
pub fn operate(io: Io, operation: Operation) Cancelable!Operation.Result {
    return io.vtable.operate(io.userdata, operation);
}

/// Submits many operations together without waiting for all of them to
/// complete.
///
/// This is a low-level abstraction based on `Operation`. For a higher
/// level API that operates on `Future`, see `Select` and `Group`.
pub const Batch = struct {
    storage: []Operation.Storage,
    unused: Operation.List,
    submitted: Operation.List,
    pending: Operation.List,
    completed: Operation.List,
    userdata: ?*anyopaque align(@max(@alignOf(?*anyopaque), 4)),

    /// After calling this, it is safe to unconditionally defer a call to
    /// `cancel`. `storage` is a pre-allocated buffer of undefined memory that
    /// determines the maximum number of active operations that can be
    /// submitted via `add` and `addAt`.
    pub fn init(storage: []Operation.Storage) Batch {
        var prev: Operation.OptionalIndex = .none;
        for (storage, 0..) |*operation, index| {
            operation.* = .{ .unused = .{ .prev = prev, .next = .fromIndex(index + 1) } };
            prev = .fromIndex(index);
        }
        storage[storage.len - 1].unused.next = .none;
        return .{
            .storage = storage,
            .unused = .{
                .head = .fromIndex(0),
                .tail = .fromIndex(storage.len - 1),
            },
            .submitted = .empty,
            .pending = .empty,
            .completed = .empty,
            .userdata = null,
        };
    }

    /// Adds an operation to be performed at the next await call.
    /// Returns the index that will be returned by `next` after the operation completes.
    /// Asserts that no more than `storage.len` operations are active at a time.
    pub fn add(batch: *Batch, operation: Operation) u32 {
        const index = batch.unused.next;
        batch.addAt(index.toIndex(), operation);
        return index;
    }

    /// Adds an operation to be performed at the next await call.
    /// After the operation completes, `next` will return `index`.
    /// Asserts that the operation at `index` is not active.
    pub fn addAt(batch: *Batch, index: u32, operation: Operation) void {
        const storage = &batch.storage[index];
        const unused = storage.unused;
        switch (unused.prev) {
            .none => batch.unused.head = unused.next,
            else => |prev_index| batch.storage[prev_index.toIndex()].unused.next = unused.next,
        }
        switch (unused.next) {
            .none => batch.unused.tail = unused.prev,
            else => |next_index| batch.storage[next_index.toIndex()].unused.prev = unused.prev,
        }

        switch (batch.submitted.tail) {
            .none => batch.submitted.head = .fromIndex(index),
            else => |tail_index| batch.storage[tail_index.toIndex()].submission.node.next = .fromIndex(index),
        }
        storage.* = .{ .submission = .{ .node = .{ .next = .none }, .operation = operation } };
        batch.submitted.tail = .fromIndex(index);
    }

    pub const Completion = struct {
        /// The element within the provided operation storage that completed.
        /// `addAt` can be used to re-arm the `Batch` using this `index`.
        index: u32,
        /// The return value of the operation.
        result: Operation.Result,
    };

    /// After calling `awaitAsync`, `awaitConcurrent`, or `cancel`, this
    /// function iterates over the completed operations.
    ///
    /// Each completion returned from this function dequeues from the `Batch`.
    /// It is not required to dequeue all completions before awaiting again.
    pub fn next(batch: *Batch) ?Completion {
        const index = batch.completed.head;
        if (index == .none) return null;
        const storage = &batch.storage[index.toIndex()];
        const completion = storage.completion;
        const next_index = completion.node.next;
        batch.completed.head = next_index;
        if (next_index == .none) batch.completed.tail = .none;

        const tail_index = batch.unused.tail;
        switch (tail_index) {
            .none => batch.unused.head = index,
            else => batch.storage[tail_index.toIndex()].unused.next = index,
        }
        storage.* = .{ .unused = .{ .prev = tail_index, .next = .none } };
        batch.unused.tail = index;
        return .{ .index = index.toIndex(), .result = completion.result };
    }

    /// Waits for at least one of the submitted operations to complete. After
    /// this function returns the completed operations can be iterated with
    /// `next`.
    ///
    /// This function provides opportunity for the implementation to introduce
    /// concurrency into the batched operations, but unlike `awaitConcurrent`,
    /// does not require it, and therefore cannot fail with
    /// `error.ConcurrencyUnavailable`.
    pub fn awaitAsync(batch: *Batch, io: Io) Cancelable!void {
        return io.vtable.batchAwaitAsync(io.userdata, batch);
    }

    pub const AwaitConcurrentError = ConcurrentError || Cancelable || Timeout.Error;

    /// Waits for at least one of the submitted operations to complete. After
    /// this function returns the completed operations can be iterated with
    /// `next`.
    ///
    /// Unlike `awaitAsync`, this function requires the implementation to
    /// perform the operations concurrently and therefore can fail with
    /// `error.ConcurrencyUnavailable`.
    pub fn awaitConcurrent(batch: *Batch, io: Io, timeout: Timeout) AwaitConcurrentError!void {
        return io.vtable.batchAwaitConcurrent(io.userdata, batch, timeout);
    }

    /// Requests all pending operations to be interrupted, then waits for all
    /// pending operations to complete. After this returns, the `Batch` is in a
    /// well-defined state, ready to be iterated with `next`. Successfully
    /// canceled operations will be absent from the iteration. Some operations
    /// may have successfully completed regardless of the cancel request and
    /// will appear in the iteration.
    pub fn cancel(batch: *Batch, io: Io) void {
        { // abort pending submissions
            var tail_index = batch.unused.tail;
            defer batch.unused.tail = tail_index;
            var index = batch.submitted.head;
            errdefer batch.submissions.head = index;
            while (index != .none) {
                const next_index = batch.storage[index.toIndex()].submission.node.next;
                switch (tail_index) {
                    .none => batch.unused.head = index,
                    else => batch.storage[tail_index.toIndex()].unused.next = index,
                }
                batch.storage[index.toIndex()] = .{ .unused = .{ .prev = tail_index, .next = .none } };
                tail_index = index;
                index = next_index;
            }
            batch.submitted = .{ .head = .none, .tail = .none };
        }
        io.vtable.batchCancel(io.userdata, batch);
        assert(batch.submitted.head == .none and batch.submitted.tail == .none);
        assert(batch.pending.head == .none and batch.pending.tail == .none);
        assert(batch.userdata == null); // that was the last chance to deallocate resources
    }
};

pub const Limit = enum(usize) {
    nothing = 0,
    unlimited = math.maxInt(usize),
    _,

    /// `math.maxInt(usize)` is interpreted to mean `.unlimited`.
    pub fn limited(n: usize) Limit {
        return @enumFromInt(n);
    }

    /// Any value grater than `math.maxInt(usize)` is interpreted to mean
    /// `.unlimited`.
    pub fn limited64(n: u64) Limit {
        return @enumFromInt(@min(n, math.maxInt(usize)));
    }

    pub fn countVec(data: []const []const u8) Limit {
        var total: usize = 0;
        for (data) |d| total += d.len;
        return .limited(total);
    }

    pub fn min(a: Limit, b: Limit) Limit {
        return @enumFromInt(@min(@intFromEnum(a), @intFromEnum(b)));
    }

    pub fn max(a: Limit, b: Limit) Limit {
        if (a == .unlimited or b == .unlimited) {
            return .unlimited;
        }

        return @enumFromInt(@max(@intFromEnum(a), @intFromEnum(b)));
    }

    pub fn minInt(l: Limit, n: usize) usize {
        return @min(n, @intFromEnum(l));
    }

    pub fn minInt64(l: Limit, n: u64) usize {
        return @min(n, @intFromEnum(l));
    }

    pub fn slice(l: Limit, s: []u8) []u8 {
        return s[0..l.minInt(s.len)];
    }

    pub fn sliceConst(l: Limit, s: []const u8) []const u8 {
        return s[0..l.minInt(s.len)];
    }

    pub fn toInt(l: Limit) ?usize {
        return switch (l) {
            else => @intFromEnum(l),
            .unlimited => null,
        };
    }

    /// Reduces a slice to account for the limit, leaving room for one extra
    /// byte above the limit, allowing for the use case of differentiating
    /// between end-of-stream and reaching the limit.
    pub fn slice1(l: Limit, non_empty_buffer: []u8) []u8 {
        assert(non_empty_buffer.len >= 1);
        return non_empty_buffer[0..@min(@intFromEnum(l) +| 1, non_empty_buffer.len)];
    }

    pub fn nonzero(l: Limit) bool {
        return l != .nothing;
    }

    /// Return a new limit reduced by `amount` or return `null` indicating
    /// limit would be exceeded.
    pub fn subtract(l: Limit, amount: usize) ?Limit {
        if (l == .unlimited) return .unlimited;
        if (amount > @intFromEnum(l)) return null;
        return @enumFromInt(@intFromEnum(l) - amount);
    }
};

pub const Cancelable = error{
    /// Caller has requested the async operation to stop.
    Canceled,
};

pub const UnexpectedError = error{
    /// The Operating System returned an undocumented error code.
    ///
    /// This error is in theory not possible, but it would be better
    /// to handle this error than to invoke undefined behavior.
    ///
    /// When this error code is observed, it usually means the Zig Standard
    /// Library needs a small patch to add the error code to the error set for
    /// the respective function.
    Unexpected,
};

pub const Clock = enum {
    /// A settable system-wide clock that measures real (i.e. wall-clock)
    /// time. This clock is affected by discontinuous jumps in the system
    /// time (e.g., if the system administrator manually changes the
    /// clock), and by frequency adjustments performed by NTP and similar
    /// applications.
    ///
    /// This clock normally counts the number of seconds since 1970-01-01
    /// 00:00:00 Coordinated Universal Time (UTC) except that it ignores
    /// leap seconds; near a leap second it is typically adjusted by NTP to
    /// stay roughly in sync with UTC.
    ///
    /// Timestamps returned by implementations of this clock represent time
    /// elapsed since 1970-01-01T00:00:00Z, the POSIX/Unix epoch, ignoring
    /// leap seconds. This is colloquially known as "Unix time". If the
    /// underlying OS uses a different epoch for native timestamps (e.g.,
    /// Windows, which uses 1601-01-01) they are translated accordingly.
    real,
    /// A nonsettable system-wide clock that represents time since some
    /// unspecified point in the past.
    ///
    /// Monotonic: Guarantees that the time returned by consecutive calls
    /// will not go backwards, but successive calls may return identical
    /// (not-increased) time values.
    ///
    /// Not affected by discontinuous jumps in the system time (e.g., if
    /// the system administrator manually changes the clock), but may be
    /// affected by frequency adjustments.
    ///
    /// This clock expresses intent to **exclude time that the system is
    /// suspended**. However, implementations may be unable to satisify
    /// this, and may include that time.
    ///
    /// * On Linux, corresponds `CLOCK_MONOTONIC`.
    /// * On macOS, corresponds to `CLOCK_UPTIME_RAW`.
    awake,
    /// Identical to `awake` except it expresses intent to **include time
    /// that the system is suspended**, however, due to limitations it may
    /// behave identically to `awake`.
    ///
    /// * On Linux, corresponds `CLOCK_BOOTTIME`.
    /// * On macOS, corresponds to `CLOCK_MONOTONIC_RAW`.
    boot,
    /// Tracks the amount of CPU in user or kernel mode used by the calling
    /// process.
    cpu_process,
    /// Tracks the amount of CPU in user or kernel mode used by the calling
    /// thread.
    cpu_thread,

    /// This function is not cancelable because it does not block.
    ///
    /// Resolution is determined by `resolution` which may be 0 if the
    /// clock is unsupported.
    ///
    /// See also:
    /// * `Clock.Timestamp.now`
    pub fn now(clock: Clock, io: Io) Io.Timestamp {
        return io.vtable.now(io.userdata, clock);
    }

    pub const ResolutionError = error{
        ClockUnavailable,
        Unexpected,
    };

    /// Reveals the granularity of `clock`. May be zero, indicating
    /// unsupported clock.
    pub fn resolution(clock: Clock, io: Io) ResolutionError!Io.Duration {
        return io.vtable.clockResolution(io.userdata, clock);
    }

    pub const Timestamp = struct {
        raw: Io.Timestamp,
        clock: Clock,

        /// This function is not cancelable because it does not block.
        ///
        /// Resolution is determined by `resolution` which may be 0 if
        /// the clock is unsupported.
        ///
        /// See also:
        /// * `Clock.now`
        pub fn now(io: Io, clock: Clock) Clock.Timestamp {
            return .{
                .raw = io.vtable.now(io.userdata, clock),
                .clock = clock,
            };
        }

        /// Sleeps until the timestamp arrives.
        ///
        /// See also:
        /// * `Io.sleep`
        /// * `Clock.Duration.sleep`
        /// * `Timeout.sleep`
        pub fn wait(t: Clock.Timestamp, io: Io) Cancelable!void {
            return io.vtable.sleep(io.userdata, .{ .deadline = t });
        }

        pub fn durationTo(from: Clock.Timestamp, to: Clock.Timestamp) Clock.Duration {
            assert(from.clock == to.clock);
            return .{
                .raw = from.raw.durationTo(to.raw),
                .clock = from.clock,
            };
        }

        pub fn addDuration(from: Clock.Timestamp, duration: Clock.Duration) Clock.Timestamp {
            assert(from.clock == duration.clock);
            return .{
                .raw = from.raw.addDuration(duration.raw),
                .clock = from.clock,
            };
        }

        pub fn subDuration(from: Clock.Timestamp, duration: Clock.Duration) Clock.Timestamp {
            assert(from.clock == duration.clock);
            return .{
                .raw = from.raw.subDuration(duration.raw),
                .clock = from.clock,
            };
        }

        /// Resolution is determined by `resolution` which may be 0 if
        /// the clock is unsupported.
        pub fn fromNow(io: Io, duration: Clock.Duration) Clock.Timestamp {
            return .{
                .clock = duration.clock,
                .raw = duration.clock.now(io).addDuration(duration.raw),
            };
        }

        /// Resolution is determined by `resolution` which may be 0 if
        /// the clock is unsupported.
        pub fn untilNow(timestamp: Clock.Timestamp, io: Io) Clock.Duration {
            const now_ts = Clock.Timestamp.now(io, timestamp.clock);
            return timestamp.durationTo(now_ts);
        }

        /// Resolution is determined by `resolution` which may be 0 if
        /// the clock is unsupported.
        pub fn durationFromNow(timestamp: Clock.Timestamp, io: Io) Clock.Duration {
            const now_ts = timestamp.clock.now(io);
            return .{
                .clock = timestamp.clock,
                .raw = now_ts.durationTo(timestamp.raw),
            };
        }

        /// Resolution is determined by `resolution` which may be 0 if
        /// the clock is unsupported.
        pub fn toClock(t: Clock.Timestamp, io: Io, clock: Clock) Clock.Timestamp {
            if (t.clock == clock) return t;
            const now_old = t.clock.now(io);
            const now_new = clock.now(io);
            const duration = now_old.durationTo(t);
            return .{
                .clock = clock,
                .raw = now_new.addDuration(duration),
            };
        }

        pub fn compare(lhs: Clock.Timestamp, op: math.CompareOperator, rhs: Clock.Timestamp) bool {
            assert(lhs.clock == rhs.clock);
            return math.compare(lhs.raw.nanoseconds, op, rhs.raw.nanoseconds);
        }
    };

    pub const Duration = struct {
        raw: Io.Duration,
        clock: Clock,

        /// Waits until a specified amount of time has passed on `clock`.
        ///
        /// See also:
        /// * `Io.sleep`
        /// * `Clock.Timestamp.wait`
        /// * `Timeout.sleep`
        pub fn sleep(duration: Clock.Duration, io: Io) Cancelable!void {
            return io.vtable.sleep(io.userdata, .{ .duration = duration });
        }
    };
};

pub const Timestamp = struct {
    nanoseconds: i96,

    pub fn now(io: Io, clock: Clock) Io.Timestamp {
        return io.vtable.now(io.userdata, clock);
    }

    pub const zero: Timestamp = .{ .nanoseconds = 0 };

    pub fn durationTo(from: Timestamp, to: Timestamp) Duration {
        return .{ .nanoseconds = to.nanoseconds - from.nanoseconds };
    }

    pub fn addDuration(from: Timestamp, duration: Duration) Timestamp {
        return .{ .nanoseconds = from.nanoseconds + duration.nanoseconds };
    }

    pub fn subDuration(from: Timestamp, duration: Duration) Timestamp {
        return .{ .nanoseconds = from.nanoseconds - duration.nanoseconds };
    }

    pub fn withClock(t: Timestamp, clock: Clock) Clock.Timestamp {
        return .{ .raw = t, .clock = clock };
    }

    pub fn fromNanoseconds(x: i96) Timestamp {
        return .{ .nanoseconds = x };
    }

    pub fn toMilliseconds(t: Timestamp) i64 {
        return @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_ms));
    }

    pub fn toSeconds(t: Timestamp) i64 {
        return @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_s));
    }

    pub fn toNanoseconds(t: Timestamp) i96 {
        return t.nanoseconds;
    }

    pub fn formatNumber(t: Timestamp, w: *std.Io.Writer, n: std.fmt.Number) std.Io.Writer.Error!void {
        return w.printInt(t.nanoseconds, n.mode.base() orelse 10, n.case, .{
            .precision = n.precision,
            .width = n.width,
            .alignment = n.alignment,
            .fill = n.fill,
        });
    }

    /// Resolution is determined by `Clock.resolution` which may be 0 if
    /// the clock is unsupported.
    pub fn untilNow(t: Timestamp, io: Io, clock: Clock) Duration {
        const now_ts = clock.now(io);
        return t.durationTo(now_ts);
    }
};

pub const Duration = struct {
    nanoseconds: i96,

    pub const zero: Duration = .{ .nanoseconds = 0 };
    pub const max: Duration = .{ .nanoseconds = math.maxInt(i96) };

    pub fn fromNanoseconds(x: i96) Duration {
        return .{ .nanoseconds = x };
    }

    pub fn fromMilliseconds(x: i64) Duration {
        return .{ .nanoseconds = @as(i96, x) * std.time.ns_per_ms };
    }

    pub fn fromSeconds(x: i64) Duration {
        return .{ .nanoseconds = @as(i96, x) * std.time.ns_per_s };
    }

    pub fn toMilliseconds(d: Duration) i64 {
        return @intCast(@divTrunc(d.nanoseconds, std.time.ns_per_ms));
    }

    pub fn toSeconds(d: Duration) i64 {
        return @intCast(@divTrunc(d.nanoseconds, std.time.ns_per_s));
    }

    pub fn toNanoseconds(d: Duration) i96 {
        return d.nanoseconds;
    }
};

/// Declares under what conditions an operation should return `error.Timeout`.
pub const Timeout = union(enum) {
    none,
    duration: Clock.Duration,
    deadline: Clock.Timestamp,

    pub const Error = error{Timeout};

    pub fn toTimestamp(t: Timeout, io: Io) ?Clock.Timestamp {
        return switch (t) {
            .none => null,
            .duration => |d| .fromNow(io, d),
            .deadline => |d| d,
        };
    }

    pub fn toDeadline(t: Timeout, io: Io) Timeout {
        return switch (t) {
            .none => .none,
            .duration => |d| .{ .deadline = .fromNow(io, d) },
            .deadline => |d| .{ .deadline = d },
        };
    }

    pub fn toDurationFromNow(t: Timeout, io: Io) ?Clock.Duration {
        return switch (t) {
            .none => null,
            .duration => |d| d,
            .deadline => |d| d.durationFromNow(io),
        };
    }

    /// Waits until the timeout has passed.
    ///
    /// See also:
    /// * `Io.sleep`
    /// * `Clock.Duration.sleep`
    /// * `Clock.Timestamp.wait`
    pub fn sleep(timeout: Timeout, io: Io) Cancelable!void {
        return io.vtable.sleep(io.userdata, timeout);
    }
};

pub const AnyFuture = opaque {};

pub fn Future(Result: type) type {
    return struct {
        any_future: ?*AnyFuture,
        result: Result,

        /// Equivalent to `await` but places a cancelation request. This causes the task to receive
        /// `error.Canceled` from its next "cancelation point" (if any). A cancelation point is a
        /// call to a function in `Io` which can return `error.Canceled`.
        ///
        /// After cancelation of a task is requested, only the next cancelation point in that task
        /// will return `error.Canceled`: future points will not re-signal the cancelation. As such,
        /// it is usually a bug to ignore `error.Canceled`. However, to defer handling cancelation
        /// requests, see also `recancel` and `CancelProtection`.
        ///
        /// Idempotent. Not threadsafe.
        pub fn cancel(f: *@This(), io: Io) Result {
            const any_future = f.any_future orelse return f.result;
            io.vtable.cancel(io.userdata, any_future, @ptrCast(&f.result), .of(Result));
            f.any_future = null;
            return f.result;
        }

        /// Idempotent. Not threadsafe.
        pub fn await(f: *@This(), io: Io) Result {
            const any_future = f.any_future orelse return f.result;
            io.vtable.await(io.userdata, any_future, @ptrCast(&f.result), .of(Result));
            f.any_future = null;
            return f.result;
        }
    };
}

/// An unordered set of tasks which can only be awaited or canceled as a whole.
/// Tasks are spawned in the group with `Group.async` and `Group.concurrent`.
///
/// The resources associated with each task are *guaranteed* to be released when
/// the individual task returns, as opposed to when the whole group completes or
/// is awaited. For this reason, it is not a resource leak to have a long-lived
/// group which concurrent tasks are repeatedly added to. However, asynchronous
/// tasks are not guaranteed to run until `Group.await` or `Group.cancel` is
/// called, so adding async tasks to a group without ever awaiting it may leak
/// resources.
pub const Group = struct {
    /// This value indicates whether or not a group has pending tasks. `null`
    /// means there are no pending tasks, and no resources associated with the
    /// group, so `await` and `cancel` return immediately without calling the
    /// implementation. This means that `token` must be accessed atomically to
    /// avoid racing with the check in `await` and `cancel`.
    token: std.atomic.Value(?*anyopaque),
    /// This value is available for the implementation to use as it wishes.
    state: usize,

    pub const init: Group = .{ .token = .init(null), .state = 0 };

    /// Equivalent to `Io.async`, except the task is spawned in this `Group`
    /// instead of becoming associated with a `Future`.
    ///
    /// The return type of `function` must be coercible to `Cancelable!void`.
    ///
    /// Once this function is called, there are resources associated with the
    /// group. To release those resources, `Group.await` or `Group.cancel` must
    /// eventually be called.
    ///
    /// If `error.Canceled` is returned from any operation this task performs,
    /// it is asserted that `function` returns `error.Canceled`.
    pub fn async(g: *Group, io: Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
        const Args = @TypeOf(args);
        const TypeErased = struct {
            fn start(context: *const anyopaque) Cancelable!void {
                const args_casted: *const Args = @ptrCast(@alignCast(context));
                return @call(.auto, function, args_casted.*);
            }
        };
        io.vtable.groupAsync(io.userdata, g, @ptrCast(&args), .of(Args), TypeErased.start);
    }

    /// Equivalent to `Io.concurrent`, except the task is spawned in this
    /// `Group` instead of becoming associated with a `Future`.
    ///
    /// The return type of `function` must be coercible to `Cancelable!void`.
    ///
    /// Once this function is called, there are resources associated with the
    /// group. To release those resources, `Group.await` or `Group.cancel` must
    /// eventually be called.
    ///
    /// If `error.Canceled` is returned from any operation this task performs,
    /// it is asserted that `function` returns `error.Canceled`.
    pub fn concurrent(g: *Group, io: Io, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) ConcurrentError!void {
        const Args = @TypeOf(args);
        const TypeErased = struct {
            fn start(context: *const anyopaque) Cancelable!void {
                const args_casted: *const Args = @ptrCast(@alignCast(context));
                return @call(.auto, function, args_casted.*);
            }
        };
        return io.vtable.groupConcurrent(io.userdata, g, @ptrCast(&args), .of(Args), TypeErased.start);
    }

    /// Blocks until all tasks of the group finish. During this time,
    /// cancelation requests propagate to all members of the group, and
    /// will also cause `error.Canceled` to be returned when the group
    /// does ultimately finish.
    ///
    /// Idempotent. Not threadsafe.
    ///
    /// It is safe to call this function concurrently with `Group.async` or
    /// `Group.concurrent`, provided that the group does not complete until
    /// the call to `Group.async` or `Group.concurrent` returns.
    pub fn await(g: *Group, io: Io) Cancelable!void {
        const token = g.token.load(.acquire) orelse return;
        try io.vtable.groupAwait(io.userdata, g, token);
        assert(g.token.raw == null);
    }

    /// Equivalent to `await` but immediately requests cancelation on all
    /// members of the group.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    ///
    /// Idempotent. Not threadsafe.
    ///
    /// It is safe to call this function concurrently with `Group.async` or
    /// `Group.concurrent`, provided that the group does not complete until
    /// the call to `Group.async` or `Group.concurrent` returns.
    pub fn cancel(g: *Group, io: Io) void {
        const token = g.token.load(.acquire) orelse return;
        io.vtable.groupCancel(io.userdata, g, token);
        assert(g.token.raw == null);
    }
};

/// Asserts that `error.Canceled` was returned from a prior cancelation point, and "re-arms" the
/// cancelation request, so that `error.Canceled` will be returned again from the next cancelation
/// point.
///
/// For a description of cancelation and cancelation points, see `Future.cancel`.
pub fn recancel(io: Io) void {
    io.vtable.recancel(io.userdata);
}

/// In rare cases, it is desirable to completely block cancelation notification, so that a region
/// of code can run uninterrupted before `error.Canceled` is potentially observed. Therefore, every
/// task has a "cancel protection" state which indicates whether or not `Io` functions can introduce
/// cancelation points.
///
/// To modify a task's cancel protection state, see `swapCancelProtection`.
///
/// For a description of cancelation and cancelation points, see `Future.cancel`.
pub const CancelProtection = enum(u1) {
    /// Any call to an `Io` function with `error.Canceled` in its error set is a cancelation point.
    ///
    /// This is the default state, which all tasks are created in.
    unblocked = 0,
    /// No `Io` function introduces a cancelation point (`error.Canceled` will never be returned).
    blocked = 1,
};
/// Updates the current task's cancel protection state (see `CancelProtection`).
///
/// The typical usage for this function is to protect a block of code from cancelation:
/// ```
/// const old_cancel_protect = io.swapCancelProtection(.blocked);
/// defer _ = io.swapCancelProtection(old_cancel_protect);
/// doSomeWork() catch |err| switch (err) {
///     error.Canceled => unreachable,
/// };
/// ```
///
/// For a description of cancelation and cancelation points, see `Future.cancel`.
pub fn swapCancelProtection(io: Io, new: CancelProtection) CancelProtection {
    return io.vtable.swapCancelProtection(io.userdata, new);
}

/// This function acts as a pure cancelation point (subject to protection; see `CancelProtection`)
/// and does nothing else. In other words, it returns `error.Canceled` if there is an outstanding
/// non-blocked cancelation request, but otherwise is a no-op.
///
/// It is rarely necessary to call this function. The primary use case is in long-running CPU-bound
/// tasks which may need to respond to cancelation before completing. Short tasks, or those which
/// perform other `Io` operations (and hence have other cancelation points), will typically already
/// respond quickly to cancelation requests.
///
/// For a description of cancelation and cancelation points, see `Future.cancel`.
pub fn checkCancel(io: Io) Cancelable!void {
    return io.vtable.checkCancel(io.userdata);
}

pub fn Select(comptime U: type) type {
    return struct {
        io: Io,
        group: Group,
        queue: Queue(U),
        outstanding: usize,

        const S = @This();

        pub const Union = U;

        pub const Field = std.meta.FieldEnum(U);

        pub fn init(io: Io, buffer: []U) S {
            return .{
                .io = io,
                .queue = .init(buffer),
                .group = .init,
                .outstanding = 0,
            };
        }

        /// Calls `function` with `args` asynchronously. The resource spawned is
        /// owned by the select.
        ///
        /// `function` must have return type matching the `field` field of `Union`.
        ///
        /// `function` *may* be called immediately, before `async` returns.
        ///
        /// When this function returns, it is guaranteed that `function` has
        /// already been called and completed, or it has successfully been
        /// assigned a unit of concurrency.
        ///
        /// After this is called, `wait` or `cancel` must be called before the
        /// select is deinitialized.
        ///
        /// Threadsafe.
        ///
        /// Related:
        /// * `Io.async`
        /// * `Group.async`
        pub fn async(
            s: *S,
            comptime field: Field,
            function: anytype,
            args: std.meta.ArgsTuple(@TypeOf(function)),
        ) void {
            const Context = struct {
                select: *S,
                args: @TypeOf(args),
                fn start(type_erased_context: *const anyopaque) Cancelable!void {
                    const context: *const @This() = @ptrCast(@alignCast(type_erased_context));
                    const elem = @unionInit(U, @tagName(field), @call(.auto, function, context.args));
                    context.select.queue.putOneUncancelable(context.select.io, elem) catch |err| switch (err) {
                        error.Closed => unreachable,
                    };
                }
            };
            const context: Context = .{ .select = s, .args = args };
            _ = @atomicRmw(usize, &s.outstanding, .Add, 1, .monotonic);
            s.io.vtable.groupAsync(s.io.userdata, &s.group, @ptrCast(&context), .of(Context), Context.start);
        }

        /// Blocks until another task of the select finishes.
        ///
        /// Asserts there is at least one more `outstanding` task.
        ///
        /// Not threadsafe.
        pub fn await(s: *S) Cancelable!U {
            s.outstanding -= 1;
            return s.queue.getOne(s.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => unreachable,
            };
        }

        /// Equivalent to `wait` but requests cancelation on all remaining
        /// tasks owned by the select.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        ///
        /// It is illegal to call `wait` after this.
        ///
        /// Idempotent. Not threadsafe.
        pub fn cancel(s: *S) void {
            s.outstanding = 0;
            s.group.cancel(s.io);
        }
    };
}

/// Atomically checks if the value at `ptr` equals `expected`, and if so, blocks until either:
///
/// * a matching (same `ptr` argument) `futexWake` call occurs, or
/// * a spurious ("random") wakeup occurs.
///
/// Typically, `futexWake` should be called immediately after updating the value at `ptr.*`, to
/// unblock tasks using `futexWait` to wait for the value to change from what it previously was.
///
/// The caller is responsible for identifying spurious wakeups if necessary, typically by checking
/// the value at `ptr.*`.
///
/// Asserts that `T` is 4 bytes in length and has a well-defined layout with no padding bits.
pub fn futexWait(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T) Cancelable!void {
    return futexWaitTimeout(io, T, ptr, expected, .none);
}
/// Same as `futexWait`, except also unblocks if `timeout` expires. As with `futexWait`, spurious
/// wakeups are possible. It remains the caller's responsibility to differentiate between these
/// three possible wake-up reasons if necessary.
pub fn futexWaitTimeout(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T, timeout: Timeout) Cancelable!void {
    const expected_int: u32 = switch (@typeInfo(T)) {
        .@"enum" => @bitCast(@intFromEnum(expected)),
        else => @bitCast(expected),
    };
    return io.vtable.futexWait(io.userdata, @ptrCast(ptr), expected_int, timeout);
}
/// Same as `futexWait`, except does not introduce a cancelation point.
///
/// For a description of cancelation and cancelation points, see `Future.cancel`.
pub fn futexWaitUncancelable(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T) void {
    const expected_int: u32 = switch (@typeInfo(T)) {
        .@"enum" => @bitCast(@intFromEnum(expected)),
        else => @bitCast(expected),
    };
    io.vtable.futexWaitUncancelable(io.userdata, @ptrCast(ptr), expected_int);
}
/// Unblocks pending futex waits on `ptr`, up to a limit of `max_waiters` calls.
pub fn futexWake(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, max_waiters: u32) void {
    comptime assert(@sizeOf(T) == @sizeOf(u32));
    if (max_waiters == 0) return;
    return io.vtable.futexWake(io.userdata, @ptrCast(ptr), max_waiters);
}

/// Mutex is a synchronization primitive which enforces atomic access to a
/// shared region of code known as the "critical section".
///
/// Mutex is an extern struct so that it may be used as a field inside another
/// extern struct.
pub const Mutex = extern struct {
    state: std.atomic.Value(State),

    pub const init: Mutex = .{ .state = .init(.unlocked) };

    pub const State = enum(u32) {
        unlocked,
        locked_once,
        contended,
    };

    pub fn tryLock(m: *Mutex) bool {
        return m.state.cmpxchgWeak(.unlocked, .locked_once, .acquire, .monotonic) == null;
    }

    pub fn lock(m: *Mutex, io: Io) Cancelable!void {
        const initial_state = m.state.cmpxchgWeak(
            .unlocked,
            .locked_once,
            .acquire,
            .monotonic,
        ) orelse {
            @branchHint(.likely);
            return;
        };
        if (initial_state == .contended) {
            try io.futexWait(State, &m.state.raw, .contended);
        }
        while (m.state.swap(.contended, .acquire) != .unlocked) {
            try io.futexWait(State, &m.state.raw, .contended);
        }
    }

    /// Same as `lock`, except does not introduce a cancelation point.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    pub fn lockUncancelable(m: *Mutex, io: Io) void {
        const initial_state = m.state.cmpxchgWeak(
            .unlocked,
            .locked_once,
            .acquire,
            .monotonic,
        ) orelse {
            @branchHint(.likely);
            return;
        };
        if (initial_state == .contended) {
            io.futexWaitUncancelable(State, &m.state.raw, .contended);
        }
        while (m.state.swap(.contended, .acquire) != .unlocked) {
            io.futexWaitUncancelable(State, &m.state.raw, .contended);
        }
    }

    pub fn unlock(m: *Mutex, io: Io) void {
        switch (m.state.swap(.unlocked, .release)) {
            .unlocked => unreachable,
            .locked_once => {},
            .contended => {
                @branchHint(.unlikely);
                io.futexWake(State, &m.state.raw, 1);
            },
        }
    }
};

pub const Condition = struct {
    state: std.atomic.Value(State),
    /// Incremented whenever the condition is signaled
    epoch: std.atomic.Value(u32),

    const State = packed struct(u32) {
        waiters: u16,
        signals: u16,
    };

    pub const init: Condition = .{
        .state = .init(.{ .waiters = 0, .signals = 0 }),
        .epoch = .init(0),
    };

    pub fn wait(cond: *Condition, io: Io, mutex: *Mutex) Cancelable!void {
        try waitInner(cond, io, mutex, false);
    }

    /// Same as `wait`, except does not introduce a cancelation point.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    pub fn waitUncancelable(cond: *Condition, io: Io, mutex: *Mutex) void {
        waitInner(cond, io, mutex, true) catch |err| switch (err) {
            error.Canceled => unreachable,
        };
    }

    fn waitInner(cond: *Condition, io: Io, mutex: *Mutex, uncancelable: bool) Cancelable!void {
        var epoch = cond.epoch.load(.acquire); // `.acquire` to ensure ordered before state load

        {
            const prev_state = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
            assert(prev_state.waiters < math.maxInt(u16)); // overflow caused by too many waiters
        }

        mutex.unlock(io);
        defer mutex.lockUncancelable(io);

        while (true) {
            const result = if (uncancelable)
                io.futexWaitUncancelable(u32, &cond.epoch.raw, epoch)
            else
                io.futexWait(u32, &cond.epoch.raw, epoch);

            epoch = cond.epoch.load(.acquire); // `.acquire` to ensure ordered before `state` laod

            // Even on error, try to consume a pending signal first. Otherwise a race might
            // cause a signal to get stuck in the state with no corresponding waiter.
            {
                var prev_state = cond.state.load(.monotonic);
                while (prev_state.signals > 0) {
                    prev_state = cond.state.cmpxchgWeak(prev_state, .{
                        .waiters = prev_state.waiters - 1,
                        .signals = prev_state.signals - 1,
                    }, .acquire, .monotonic) orelse {
                        // We successfully consumed a signal.
                        return;
                    };
                }
            }

            // There are no more signals available; this was a spurious wakeup or an error. If it
            // was an error, we will remove ourselves as a waiter and return that error. Otherwise,
            // we'll loop back to the futex wait.
            result catch |err| {
                const prev_state = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
                assert(prev_state.waiters > 0); // underflow caused by illegal state
                return err;
            };
        }
    }

    pub fn signal(cond: *Condition, io: Io) void {
        var prev_state = cond.state.load(.monotonic);
        while (prev_state.waiters > prev_state.signals) {
            @branchHint(.unlikely);
            prev_state = cond.state.cmpxchgWeak(prev_state, .{
                .waiters = prev_state.waiters,
                .signals = prev_state.signals + 1,
            }, .release, .monotonic) orelse {
                // Update the epoch to tell the waiting threads that there are new signals for them.
                // Note that a waiting thread could miss a take if *exactly* (1<<32)-1 wakes happen
                // between it observing the epoch and sleeping on it, but this is extraordinarily
                // unlikely due to the precise number of calls required.
                _ = cond.epoch.fetchAdd(1, .release); // `.release` to ensure ordered after `state` update
                io.futexWake(u32, &cond.epoch.raw, 1);
                return;
            };
        }
    }

    pub fn broadcast(cond: *Condition, io: Io) void {
        var prev_state = cond.state.load(.monotonic);
        while (prev_state.waiters > prev_state.signals) {
            @branchHint(.unlikely);
            prev_state = cond.state.cmpxchgWeak(prev_state, .{
                .waiters = prev_state.waiters,
                .signals = prev_state.waiters,
            }, .release, .monotonic) orelse {
                // Update the epoch to tell the waiting threads that there are new signals for them.
                // Note that a waiting thread could miss a take if *exactly* (1<<32)-1 wakes happen
                // between it observing the epoch and sleeping on it, but this is extraordinarily
                // unlikely due to the precise number of calls required.
                _ = cond.epoch.fetchAdd(1, .release); // `.release` to ensure ordered after `state` update
                io.futexWake(u32, &cond.epoch.raw, prev_state.waiters - prev_state.signals);
                return;
            };
        }
    }
};

/// Logical boolean flag which can be set and unset and supports a "wait until set" operation.
pub const Event = enum(u32) {
    unset,
    waiting,
    is_set,

    /// Returns whether the logical boolean is `true`.
    pub fn isSet(event: *const Event) bool {
        return switch (@atomicLoad(Event, event, .acquire)) {
            .unset, .waiting => false,
            .is_set => true,
        };
    }

    /// Blocks until the logical boolean is `true`.
    pub fn wait(event: *Event, io: Io) Io.Cancelable!void {
        if (@cmpxchgStrong(Event, event, .unset, .waiting, .acquire, .acquire)) |prev| switch (prev) {
            .unset => unreachable,
            .waiting => {},
            .is_set => return,
        };
        errdefer {
            // Ideally we would restore the event back to `.unset` instead of `.waiting`, but there
            // might be other threads waiting on the event. In theory we could track the *number* of
            // waiting threads in the unused bits of the `Event`, but that has its own problem: the
            // waiters would wake up when a *new waiter* was added. So it's easiest to just leave
            // the state at `.waiting`---at worst it causes one redundant call to `futexWake`.
        }
        while (true) {
            try io.futexWait(Event, event, .waiting);
            switch (@atomicLoad(Event, event, .acquire)) {
                .unset => unreachable, // `reset` called before pending `wait` returned
                .waiting => continue,
                .is_set => return,
            }
        }
    }

    /// Same as `wait`, except does not introduce a cancelation point.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    pub fn waitUncancelable(event: *Event, io: Io) void {
        if (@cmpxchgStrong(Event, event, .unset, .waiting, .acquire, .acquire)) |prev| switch (prev) {
            .unset => unreachable,
            .waiting => {},
            .is_set => return,
        };
        while (true) {
            io.futexWaitUncancelable(Event, event, .waiting);
            switch (@atomicLoad(Event, event, .acquire)) {
                .unset => unreachable, // `reset` called before pending `wait` returned
                .waiting => continue,
                .is_set => return,
            }
        }
    }

    pub const WaitTimeoutError = error{Timeout} || Cancelable;

    /// Blocks the calling thread until either the logical boolean is set, the timeout expires, or a
    /// spurious wakeup occurs. If the timeout expires or a spurious wakeup occurs, `error.Timeout`
    /// is returned.
    pub fn waitTimeout(event: *Event, io: Io, timeout: Timeout) WaitTimeoutError!void {
        if (@cmpxchgStrong(Event, event, .unset, .waiting, .acquire, .acquire)) |prev| switch (prev) {
            .unset => unreachable,
            .waiting => {},
            .is_set => return,
        };
        errdefer {
            // Ideally we would restore the event back to `.unset` instead of `.waiting`, but there
            // might be other threads waiting on the event. In theory we could track the *number* of
            // waiting threads in the unused bits of the `Event`, but that has its own problem: the
            // waiters would wake up when a *new waiter* was added. So it's easiest to just leave
            // the state at `.waiting`---at worst it causes one redundant call to `futexWake`.
        }
        try io.futexWaitTimeout(Event, event, .waiting, timeout);
        switch (@atomicLoad(Event, event, .acquire)) {
            .unset => unreachable, // `reset` called before pending `wait` returned
            .waiting => return error.Timeout,
            .is_set => return,
        }
    }

    /// Sets the logical boolean to true, and hence unblocks any pending calls to `wait`. The
    /// logical boolean remains true until `reset` is called, so future calls to `set` have no
    /// semantic effect.
    ///
    /// Any memory accesses prior to a `set` call are "released", so that if this `set` call causes
    /// `isSet` to return `true` or a wait to finish, those tasks will be able to observe those
    /// memory accesses.
    pub fn set(e: *Event, io: Io) void {
        switch (@atomicRmw(Event, e, .Xchg, .is_set, .release)) {
            .unset, .is_set => {},
            .waiting => io.futexWake(Event, e, math.maxInt(u32)),
        }
    }

    /// Sets the logical boolean to false.
    ///
    /// Assumes that there is no pending call to `wait` or `waitUncancelable`.
    ///
    /// However, concurrent calls to `isSet`, `set`, and `reset` are allowed.
    pub fn reset(e: *Event) void {
        @atomicStore(Event, e, .unset, .monotonic);
    }
};

pub const QueueClosedError = error{Closed};

pub const TypeErasedQueue = struct {
    mutex: Mutex,
    closed: bool,

    /// Ring buffer. This data is logically *after* queued getters.
    buffer: []u8,
    start: usize,
    len: usize,

    putters: std.DoublyLinkedList,
    getters: std.DoublyLinkedList,

    const Put = struct {
        remaining: []const u8,
        needed: usize,
        condition: Condition,
        node: std.DoublyLinkedList.Node,
    };

    const Get = struct {
        remaining: []u8,
        needed: usize,
        condition: Condition,
        node: std.DoublyLinkedList.Node,
    };

    pub fn init(buffer: []u8) TypeErasedQueue {
        return .{
            .mutex = .init,
            .closed = false,
            .buffer = buffer,
            .start = 0,
            .len = 0,
            .putters = .{},
            .getters = .{},
        };
    }

    pub fn close(q: *TypeErasedQueue, io: Io) void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        q.closed = true;
        {
            var it = q.getters.first;
            while (it) |node| : (it = node.next) {
                const getter: *Get = @alignCast(@fieldParentPtr("node", node));
                getter.condition.signal(io);
            }
        }
        {
            var it = q.putters.first;
            while (it) |node| : (it = node.next) {
                const putter: *Put = @alignCast(@fieldParentPtr("node", node));
                putter.condition.signal(io);
            }
        }
    }

    pub fn put(q: *TypeErasedQueue, io: Io, elements: []const u8, min: usize) (QueueClosedError || Cancelable)!usize {
        assert(elements.len >= min);
        if (elements.len == 0) return 0;
        try q.mutex.lock(io);
        defer q.mutex.unlock(io);
        return q.putLocked(io, elements, min, false);
    }

    /// Same as `put`, except does not introduce a cancelation point.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    pub fn putUncancelable(q: *TypeErasedQueue, io: Io, elements: []const u8, min: usize) QueueClosedError!usize {
        assert(elements.len >= min);
        if (elements.len == 0) return 0;
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.putLocked(io, elements, min, true) catch |err| switch (err) {
            error.Canceled => unreachable,
            error.Closed => |e| return e,
        };
    }

    fn puttableSlice(q: *const TypeErasedQueue) ?[]u8 {
        const unwrapped_index = q.start + q.len;
        const wrapped_index, const overflow = @subWithOverflow(unwrapped_index, q.buffer.len);
        const slice = switch (overflow) {
            1 => q.buffer[unwrapped_index..],
            0 => q.buffer[wrapped_index..q.start],
        };
        return if (slice.len > 0) slice else null;
    }

    fn putLocked(q: *TypeErasedQueue, io: Io, elements: []const u8, target: usize, uncancelable: bool) (QueueClosedError || Cancelable)!usize {
        // A closed queue cannot be added to, even if there is space in the buffer.
        if (q.closed) return error.Closed;

        // Getters have first priority on the data, and only when the getters
        // queue is empty do we start populating the buffer.

        // The number of elements we add immediately, before possibly blocking.
        var n: usize = 0;

        while (q.getters.popFirst()) |getter_node| {
            const getter: *Get = @alignCast(@fieldParentPtr("node", getter_node));
            const copy_len = @min(getter.remaining.len, elements.len - n);
            assert(copy_len > 0);
            @memcpy(getter.remaining[0..copy_len], elements[n..][0..copy_len]);
            getter.remaining = getter.remaining[copy_len..];
            getter.needed -|= copy_len;
            n += copy_len;
            if (getter.needed == 0) {
                getter.condition.signal(io);
            } else {
                assert(n == elements.len); // we didn't have enough elements for the getter
                q.getters.prepend(getter_node);
            }
            if (n == elements.len) return elements.len;
        }

        while (q.puttableSlice()) |slice| {
            const copy_len = @min(slice.len, elements.len - n);
            assert(copy_len > 0);
            @memcpy(slice[0..copy_len], elements[n..][0..copy_len]);
            q.len += copy_len;
            n += copy_len;
            if (n == elements.len) return elements.len;
        }

        // Don't block if we hit the target.
        if (n >= target) return n;

        var pending: Put = .{
            .remaining = elements[n..],
            .needed = target - n,
            .condition = .init,
            .node = .{},
        };
        q.putters.append(&pending.node);
        defer if (pending.needed > 0) q.putters.remove(&pending.node);

        while (pending.needed > 0 and !q.closed) {
            if (uncancelable) {
                pending.condition.waitUncancelable(io, &q.mutex);
                continue;
            }
            pending.condition.wait(io, &q.mutex) catch |err| switch (err) {
                error.Canceled => if (pending.remaining.len == elements.len) {
                    // Canceled while waiting, and appended no elements.
                    return error.Canceled;
                } else {
                    // Canceled while waiting, but appended some elements, so report those first.
                    io.recancel();
                    return elements.len - pending.remaining.len;
                },
            };
        }
        if (pending.remaining.len == elements.len) {
            // The queue was closed while we were waiting. We appended no elements.
            assert(q.closed);
            return error.Closed;
        }
        return elements.len - pending.remaining.len;
    }

    pub fn get(q: *TypeErasedQueue, io: Io, buffer: []u8, min: usize) (QueueClosedError || Cancelable)!usize {
        assert(buffer.len >= min);
        if (buffer.len == 0) return 0;
        try q.mutex.lock(io);
        defer q.mutex.unlock(io);
        return q.getLocked(io, buffer, min, false);
    }

    /// Same as `get`, except does not introduce a cancelation point.
    ///
    /// For a description of cancelation and cancelation points, see `Future.cancel`.
    pub fn getUncancelable(q: *TypeErasedQueue, io: Io, buffer: []u8, min: usize) QueueClosedError!usize {
        assert(buffer.len >= min);
        if (buffer.len == 0) return 0;
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.getLocked(io, buffer, min, true) catch |err| switch (err) {
            error.Canceled => unreachable,
            error.Closed => |e| return e,
        };
    }

    fn gettableSlice(q: *const TypeErasedQueue) ?[]const u8 {
        const overlong_slice = q.buffer[q.start..];
        const slice = overlong_slice[0..@min(overlong_slice.len, q.len)];
        return if (slice.len > 0) slice else null;
    }

    fn getLocked(q: *TypeErasedQueue, io: Io, buffer: []u8, target: usize, uncancelable: bool) (QueueClosedError || Cancelable)!usize {
        // The ring buffer gets first priority, then data should come from any
        // queued putters, then finally the ring buffer should be filled with
        // data from putters so they can be resumed.

        // The number of elements we received immediately, before possibly blocking.
        var n: usize = 0;

        while (q.gettableSlice()) |slice| {
            const copy_len = @min(slice.len, buffer.len - n);
            assert(copy_len > 0);
            @memcpy(buffer[n..][0..copy_len], slice[0..copy_len]);
            q.start += copy_len;
            if (q.buffer.len - q.start == 0) q.start = 0;
            q.len -= copy_len;
            n += copy_len;
            if (n == buffer.len) {
                q.fillRingBufferFromPutters(io);
                return buffer.len;
            }
        }

        // Copy directly from putters into buffer.
        while (q.putters.popFirst()) |putter_node| {
            const putter: *Put = @alignCast(@fieldParentPtr("node", putter_node));
            const copy_len = @min(putter.remaining.len, buffer.len - n);
            assert(copy_len > 0);
            @memcpy(buffer[n..][0..copy_len], putter.remaining[0..copy_len]);
            putter.remaining = putter.remaining[copy_len..];
            putter.needed -|= copy_len;
            n += copy_len;
            if (putter.needed == 0) {
                putter.condition.signal(io);
            } else {
                assert(n == buffer.len); // we didn't have enough space for the putter
                q.putters.prepend(putter_node);
            }
            if (n == buffer.len) {
                q.fillRingBufferFromPutters(io);
                return buffer.len;
            }
        }

        // No need to call `fillRingBufferFromPutters` from this point onwards,
        // because we emptied the ring buffer *and* the putter queue!

        // Don't block if we hit the target or if the queue is closed. Return how
        // many elements we could get immediately, unless the queue was closed and
        // empty, in which case report `error.Closed`.
        if (n == 0 and q.closed) return error.Closed;
        if (n >= target or q.closed) return n;

        var pending: Get = .{
            .remaining = buffer[n..],
            .needed = target - n,
            .condition = .init,
            .node = .{},
        };
        q.getters.append(&pending.node);
        defer if (pending.needed > 0) q.getters.remove(&pending.node);

        while (pending.needed > 0 and !q.closed) {
            if (uncancelable) {
                pending.condition.waitUncancelable(io, &q.mutex);
                continue;
            }
            pending.condition.wait(io, &q.mutex) catch |err| switch (err) {
                error.Canceled => if (pending.remaining.len == buffer.len) {
                    // Canceled while waiting, and received no elements.
                    return error.Canceled;
                } else {
                    // Canceled while waiting, but received some elements, so report those first.
                    io.recancel();
                    return buffer.len - pending.remaining.len;
                },
            };
        }
        if (pending.remaining.len == buffer.len) {
            // The queue was closed while we were waiting. We received no elements.
            assert(q.closed);
            return error.Closed;
        }
        return buffer.len - pending.remaining.len;
    }

    /// Called when there is nonzero space available in the ring buffer and
    /// potentially putters waiting. The mutex is already held and the task is
    /// to copy putter data to the ring buffer and signal any putters whose
    /// buffers been fully copied.
    fn fillRingBufferFromPutters(q: *TypeErasedQueue, io: Io) void {
        while (q.putters.popFirst()) |putter_node| {
            const putter: *Put = @alignCast(@fieldParentPtr("node", putter_node));
            while (q.puttableSlice()) |slice| {
                const copy_len = @min(slice.len, putter.remaining.len);
                assert(copy_len > 0);
                @memcpy(slice[0..copy_len], putter.remaining[0..copy_len]);
                q.len += copy_len;
                putter.remaining = putter.remaining[copy_len..];
                putter.needed -|= copy_len;
                if (putter.needed == 0) {
                    putter.condition.signal(io);
                    break;
                }
            } else {
                q.putters.prepend(putter_node);
                break;
            }
        }
    }
};

/// Many producer, many consumer, thread-safe, runtime configurable buffer size.
/// When buffer is empty, consumers suspend and are resumed by producers.
/// When buffer is full, producers suspend and are resumed by consumers.
pub fn Queue(Elem: type) type {
    return struct {
        type_erased: TypeErasedQueue,

        pub fn init(buffer: []Elem) @This() {
            return .{ .type_erased = .init(@ptrCast(buffer)) };
        }

        pub fn close(q: *@This(), io: Io) void {
            q.type_erased.close(io);
        }

        /// Appends elements to the end of the queue, potentially blocking if
        /// there is insufficient capacity. Returns when any one of the
        /// following conditions is satisfied:
        ///
        /// * At least `target` elements have been added to the queue
        /// * The queue is closed
        /// * The current task is canceled
        ///
        /// Returns how many of `elements` have been added to the queue, if any.
        /// If an error is returned, no elements have been added.
        ///
        /// If the queue is closed or the task is canceled, but some items were
        /// already added before the closure or cancelation, then `put` may
        /// return a number lower than `target`, in which case future calls are
        /// guaranteed to return `error.Canceled` or `error.Closed`.
        ///
        /// A return value of 0 is only possible if `target` is 0, in which case
        /// the call is guaranteed to queue as many of `elements` as is possible
        /// *without* blocking.
        ///
        /// Asserts that `elements.len >= target`.
        pub fn put(q: *@This(), io: Io, elements: []const Elem, target: usize) (QueueClosedError || Cancelable)!usize {
            return @divExact(try q.type_erased.put(io, @ptrCast(elements), target * @sizeOf(Elem)), @sizeOf(Elem));
        }

        /// Same as `put` but blocks until all elements have been added to the queue.
        ///
        /// If the queue is closed or canceled, `error.Closed` or `error.Canceled`
        /// is returned, and it is unspecified how many, if any, of `elements` were
        /// added to the queue prior to cancelation or closure.
        pub fn putAll(q: *@This(), io: Io, elements: []const Elem) (QueueClosedError || Cancelable)!void {
            const n = try q.put(io, elements, elements.len);
            if (n != elements.len) {
                _ = try q.put(io, elements[n..], elements.len - n);
                unreachable; // partial `put` implies queue was closed or we were canceled
            }
        }

        /// Same as `put`, except does not introduce a cancelation point.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        pub fn putUncancelable(q: *@This(), io: Io, elements: []const Elem, min: usize) QueueClosedError!usize {
            return @divExact(try q.type_erased.putUncancelable(io, @ptrCast(elements), min * @sizeOf(Elem)), @sizeOf(Elem));
        }

        /// Appends `item` to the end of the queue, blocking if the queue is full.
        pub fn putOne(q: *@This(), io: Io, item: Elem) (QueueClosedError || Cancelable)!void {
            assert(try q.put(io, &.{item}, 1) == 1);
        }

        /// Same as `putOne`, except does not introduce a cancelation point.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        pub fn putOneUncancelable(q: *@This(), io: Io, item: Elem) QueueClosedError!void {
            assert(try q.putUncancelable(io, &.{item}, 1) == 1);
        }

        /// Receives elements from the beginning of the queue, potentially blocking
        /// if there are insufficient elements currently in the queue. Returns when
        /// any one of the following conditions is satisfied:
        ///
        /// * At least `target` elements have been received from the queue
        /// * The queue is closed and contains no buffered elements
        /// * The current task is canceled
        ///
        /// Returns how many elements of `buffer` have been populated, if any.
        /// If an error is returned, no elements have been populated.
        ///
        /// If the queue is closed or the task is canceled, but some items were
        /// already received before the closure or cancelation, then `get` may
        /// return a number lower than `target`, in which case future calls are
        /// guaranteed to return `error.Canceled` or `error.Closed`.
        ///
        /// A return value of 0 is only possible if `target` is 0, in which case
        /// the call is guaranteed to fill as much of `buffer` as is possible
        /// *without* blocking.
        ///
        /// Asserts that `buffer.len >= target`.
        pub fn get(q: *@This(), io: Io, buffer: []Elem, target: usize) (QueueClosedError || Cancelable)!usize {
            return @divExact(try q.type_erased.get(io, @ptrCast(buffer), target * @sizeOf(Elem)), @sizeOf(Elem));
        }

        /// Same as `get`, except does not introduce a cancelation point.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        pub fn getUncancelable(q: *@This(), io: Io, buffer: []Elem, min: usize) QueueClosedError!usize {
            return @divExact(try q.type_erased.getUncancelable(io, @ptrCast(buffer), min * @sizeOf(Elem)), @sizeOf(Elem));
        }

        /// Receives one element from the beginning of the queue, blocking if the queue is empty.
        pub fn getOne(q: *@This(), io: Io) (QueueClosedError || Cancelable)!Elem {
            var buf: [1]Elem = undefined;
            assert(try q.get(io, &buf, 1) == 1);
            return buf[0];
        }

        /// Same as `getOne`, except does not introduce a cancelation point.
        ///
        /// For a description of cancelation and cancelation points, see `Future.cancel`.
        pub fn getOneUncancelable(q: *@This(), io: Io) QueueClosedError!Elem {
            var buf: [1]Elem = undefined;
            assert(try q.getUncancelable(io, &buf, 1) == 1);
            return buf[0];
        }

        /// Returns buffer length in `Elem` units.
        pub fn capacity(q: *const @This()) usize {
            return @divExact(q.type_erased.buffer.len, @sizeOf(Elem));
        }
    };
}

/// Calls `function` with `args`, such that the return value of the function is
/// not guaranteed to be available until `await` is called.
///
/// `function` *may* be called immediately, before `async` returns. This has
/// weaker guarantees than `concurrent`, making more portable and reusable.
///
/// When this function returns, it is guaranteed that `function` has already
/// been called and completed, or it has successfully been assigned a unit of
/// concurrency.
///
/// See also:
/// * `Group`
pub fn async(
    io: Io,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const args_casted: *const Args = @ptrCast(@alignCast(context));
            const result_casted: *Result = @ptrCast(@alignCast(result));
            result_casted.* = @call(.auto, function, args_casted.*);
        }
    };
    var future: Future(Result) = undefined;
    future.any_future = io.vtable.async(
        io.userdata,
        @ptrCast(&future.result),
        .of(Result),
        @ptrCast(&args),
        .of(Args),
        TypeErased.start,
    );
    return future;
}

pub const ConcurrentError = error{
    /// May occur due to a temporary condition such as resource exhaustion, or
    /// to the Io implementation not supporting concurrency.
    ConcurrencyUnavailable,
};

/// Calls `function` with `args`, such that the return value of the function is
/// not guaranteed to be available until `await` is called, allowing the caller
/// to progress while waiting for any `Io` operations.
///
/// This has stronger guarantee than `async`, placing restrictions on what kind
/// of `Io` implementations are supported. By calling `async` instead, one
/// allows, for example, stackful single-threaded blocking I/O.
pub fn concurrent(
    io: Io,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) ConcurrentError!Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Args = @TypeOf(args);
    const TypeErased = struct {
        fn start(context: *const anyopaque, result: *anyopaque) void {
            const args_casted: *const Args = @ptrCast(@alignCast(context));
            const result_casted: *Result = @ptrCast(@alignCast(result));
            result_casted.* = @call(.auto, function, args_casted.*);
        }
    };
    var future: Future(Result) = undefined;
    future.any_future = try io.vtable.concurrent(
        io.userdata,
        @sizeOf(Result),
        .of(Result),
        @ptrCast(&args),
        .of(Args),
        TypeErased.start,
    );
    return future;
}

/// Waits until a specified amount of time has passed on `clock`.
///
/// See also:
/// * `Clock.Duration.sleep`
/// * `Clock.Timestamp.wait`
/// * `Timeout.sleep`
pub fn sleep(io: Io, duration: Duration, clock: Clock) Cancelable!void {
    return io.vtable.sleep(io.userdata, .{ .duration = .{
        .raw = duration,
        .clock = clock,
    } });
}

/// Given a struct with each field a `*Future`, returns a union with the same
/// fields, each field type the future's result.
pub fn SelectUnion(S: type) type {
    const struct_fields = @typeInfo(S).@"struct".fields;
    var names: [struct_fields.len][]const u8 = undefined;
    var types: [struct_fields.len]type = undefined;
    for (struct_fields, &names, &types) |struct_field, *union_field_name, *UnionFieldType| {
        const FieldFuture = @typeInfo(struct_field.type).pointer.child;
        union_field_name.* = struct_field.name;
        UnionFieldType.* = @FieldType(FieldFuture, "result");
    }
    return @Union(.auto, std.meta.FieldEnum(S), &names, &types, &@splat(.{}));
}

/// `s` is a struct with every field a `*Future(T)`, where `T` can be any type,
/// and can be different for each field.
pub fn select(io: Io, s: anytype) Cancelable!SelectUnion(@TypeOf(s)) {
    const U = SelectUnion(@TypeOf(s));
    const S = @TypeOf(s);
    const fields = @typeInfo(S).@"struct".fields;
    var futures: [fields.len]*AnyFuture = undefined;
    inline for (fields, &futures) |field, *any_future| {
        const future = @field(s, field.name);
        any_future.* = future.any_future orelse return @unionInit(U, field.name, future.result);
    }
    switch (try io.vtable.select(io.userdata, &futures)) {
        inline 0...(fields.len - 1) => |selected_index| {
            const field_name = fields[selected_index].name;
            return @unionInit(U, field_name, @field(s, field_name).await(io));
        },
        else => unreachable,
    }
}

pub const LockedStderr = struct {
    file_writer: *File.Writer,
    terminal_mode: Terminal.Mode,

    pub fn terminal(ls: LockedStderr) Terminal {
        return .{
            .writer = &ls.file_writer.interface,
            .mode = ls.terminal_mode,
        };
    }

    pub fn clear(ls: LockedStderr, buffer: []u8) Cancelable!void {
        const fw = ls.file_writer;
        std.Progress.clearWrittenWithEscapeCodes(fw) catch |err| switch (err) {
            error.WriteFailed => switch (fw.err.?) {
                error.Canceled => |e| return e,
                else => {},
            },
        };
        fw.interface.flush() catch |err| switch (err) {
            error.WriteFailed => switch (fw.err.?) {
                error.Canceled => |e| return e,
                else => {},
            },
        };
        fw.interface.buffer = buffer;
    }
};

/// For doing application-level writes to the standard error stream.
/// Coordinates also with debug-level writes that are ignorant of Io interface
/// and implementations.
///
/// See also:
/// * `tryLockStderr`
pub fn lockStderr(io: Io, buffer: []u8, terminal_mode: ?Terminal.Mode) Cancelable!LockedStderr {
    const ls = try io.vtable.lockStderr(io.userdata, terminal_mode);
    try ls.clear(buffer);
    return ls;
}

/// Same as `lockStderr` but non-blocking.
pub fn tryLockStderr(io: Io, buffer: []u8, terminal_mode: ?Terminal.Mode) Cancelable!?LockedStderr {
    const ls = (try io.vtable.tryLockStderr(io.userdata, buffer, terminal_mode)) orelse return null;
    try ls.clear(buffer);
    return ls;
}

pub fn unlockStderr(io: Io) void {
    return io.vtable.unlockStderr(io.userdata);
}

/// Obtains entropy from a cryptographically secure pseudo-random number
/// generator.
///
/// The implementation *may* store RNG state in process memory and use it to
/// fill `buffer`.
///
/// The randomness is seeded by `randomSecure`, or a less secure mechanism upon
/// failure.
///
/// Threadsafe.
///
/// See also `randomSecure`.
pub fn random(io: Io, buffer: []u8) void {
    return io.vtable.random(io.userdata, buffer);
}

pub const RandomSecureError = error{EntropyUnavailable} || Cancelable;

/// Obtains cryptographically secure entropy from outside the process.
///
/// Always makes a syscall, or otherwise avoids dependency on process memory,
/// in order to obtain fresh randomness. Does not rely on stored RNG state.
///
/// Does not have any fallback mechanisms; returns `error.EntropyUnavailable`
/// if any problems occur.
///
/// Threadsafe.
///
/// See also `random`.
pub fn randomSecure(io: Io, buffer: []u8) RandomSecureError!void {
    return io.vtable.randomSecure(io.userdata, buffer);
}

test {
    _ = net;
    _ = File;
    _ = Dir;
    _ = Reader;
    _ = Writer;
    _ = Evented;
    _ = Threaded;
    _ = RwLock;
    _ = Semaphore;
    _ = @import("Io/test.zig");
}
