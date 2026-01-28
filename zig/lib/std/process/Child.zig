const Child = @This();

const builtin = @import("builtin");
const native_os = builtin.os.tag;

const std = @import("../std.zig");
const Io = std.Io;
const process = std.process;
const File = std.Io.File;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const Id = switch (native_os) {
    .windows => std.os.windows.HANDLE,
    .wasi => void,
    else => std.posix.pid_t,
};

/// After `wait` or `kill` is called, this becomes `null`.
/// On Windows this is the hProcess.
/// On POSIX this is the pid.
id: ?Id,
thread_handle: if (native_os == .windows) std.os.windows.HANDLE else void,
/// The writing end of the child process's standard input pipe.
/// Usage requires `process.SpawnOptions.StdIo.pipe`.
stdin: ?File,
/// The reading end of the child process's standard output pipe.
/// Usage requires `process.SpawnOptions.StdIo.pipe`.
stdout: ?File,
/// The reading end of the child process's standard error pipe.
/// Usage requires `process.SpawnOptions.StdIo.pipe`.
stderr: ?File,
/// This is available after calling wait if
/// `request_resource_usage_statistics` was set to `true` before calling
/// `spawn`.
/// TODO move this data into `Term`
resource_usage_statistics: ResourceUsageStatistics = .{},
request_resource_usage_statistics: bool,

pub const ResourceUsageStatistics = struct {
    rusage: @TypeOf(rusage_init) = rusage_init,

    /// Returns the peak resident set size of the child process, in bytes,
    /// if available.
    pub inline fn getMaxRss(rus: ResourceUsageStatistics) ?usize {
        switch (native_os) {
            .dragonfly, .freebsd, .netbsd, .openbsd, .illumos, .linux, .serenity => {
                if (rus.rusage) |ru| {
                    return @as(usize, @intCast(ru.maxrss)) * 1024;
                } else {
                    return null;
                }
            },
            .windows => {
                if (rus.rusage) |ru| {
                    return ru.PeakWorkingSetSize;
                } else {
                    return null;
                }
            },
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
                if (rus.rusage) |ru| {
                    // Darwin oddly reports in bytes instead of kilobytes.
                    return @as(usize, @intCast(ru.maxrss));
                } else {
                    return null;
                }
            },
            else => return null,
        }
    }

    const rusage_init = switch (native_os) {
        .dragonfly,
        .freebsd,
        .netbsd,
        .openbsd,
        .illumos,
        .linux,
        .serenity,
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => @as(?std.posix.rusage, null),
        .windows => @as(?std.os.windows.VM_COUNTERS, null),
        else => {},
    };
};

pub const Term = union(enum) {
    exited: u8,
    signal: std.posix.SIG,
    stopped: u32,
    unknown: u32,
};

/// Requests for the operating system to forcibly terminate the child process,
/// then blocks until it terminates, then cleans up all resources.
///
/// Idempotent and does nothing after `wait` returns.
///
/// Uncancelable. Ignores unexpected errors from the operating system.
pub fn kill(child: *Child, io: Io) void {
    if (child.id == null) {
        assert(child.stdin == null);
        assert(child.stdout == null);
        assert(child.stderr == null);
        return;
    }
    io.vtable.childKill(io.userdata, child);
    assert(child.id == null);
}

pub const WaitError = error{
    AccessDenied,
} || Io.Cancelable || Io.UnexpectedError;

/// Blocks until child process terminates and then cleans up all resources.
pub fn wait(child: *Child, io: Io) WaitError!Term {
    assert(child.id != null);
    return io.vtable.childWait(io.userdata, child);
}

/// Collect the output from the process's stdout and stderr. Will return once all output
/// has been collected. This does not mean that the process has ended. `wait` should still
/// be called to wait for and clean up the process.
///
/// The process must have been started with stdout and stderr set to
/// `process.SpawnOptions.StdIo.pipe`.
pub fn collectOutput(
    child: *const Child,
    /// Used for `stdout` and `stderr`.
    allocator: Allocator,
    stdout: *ArrayList(u8),
    stderr: *ArrayList(u8),
    max_output_bytes: usize,
) !void {
    var poller = std.Io.poll(allocator, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    const stdout_r = poller.reader(.stdout);
    stdout_r.buffer = stdout.allocatedSlice();
    stdout_r.seek = 0;
    stdout_r.end = stdout.items.len;

    const stderr_r = poller.reader(.stderr);
    stderr_r.buffer = stderr.allocatedSlice();
    stderr_r.seek = 0;
    stderr_r.end = stderr.items.len;

    defer {
        stdout.* = .{
            .items = stdout_r.buffer[0..stdout_r.end],
            .capacity = stdout_r.buffer.len,
        };
        stderr.* = .{
            .items = stderr_r.buffer[0..stderr_r.end],
            .capacity = stderr_r.buffer.len,
        };
        stdout_r.buffer = &.{};
        stderr_r.buffer = &.{};
    }

    while (try poller.poll()) {
        if (stdout_r.bufferedLen() > max_output_bytes)
            return error.StdoutStreamTooLong;
        if (stderr_r.bufferedLen() > max_output_bytes)
            return error.StderrStreamTooLong;
    }
}
