const std = @import("std");
const abi = std.Build.abi.fuzz;
const native_endian = @import("builtin").cpu.arch.endian();

fn testOne(in: abi.Slice) callconv(.c) void {
    std.debug.assertReadable(in.toSlice());
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip(); // executable name

    const cache_dir_path = args.next() orelse @panic("expected cache directory path argument");
    var cache_dir = try std.Io.Dir.cwd().openDir(io, cache_dir_path, .{});
    defer cache_dir.close(io);

    abi.fuzzer_init(.fromSlice(cache_dir_path));
    abi.fuzzer_init_test(testOne, .fromSlice("test"));
    abi.fuzzer_new_input(.fromSlice(""));
    abi.fuzzer_new_input(.fromSlice("hello"));

    const pc_digest = abi.fuzzer_coverage().id;
    const coverage_file_path = "v/" ++ std.fmt.hex(pc_digest);
    const coverage_file = try cache_dir.openFile(io, coverage_file_path, .{});
    defer coverage_file.close(io);

    var read_buf: [@sizeOf(abi.SeenPcsHeader)]u8 = undefined;
    var r = coverage_file.reader(io, &read_buf);
    const pcs_header = r.interface.takeStruct(abi.SeenPcsHeader, native_endian) catch return r.err.?;

    if (pcs_header.pcs_len == 0)
        return error.ZeroPcs;
    const expected_len = @sizeOf(abi.SeenPcsHeader) +
        try std.math.divCeil(usize, pcs_header.pcs_len, @bitSizeOf(usize)) * @sizeOf(usize) +
        pcs_header.pcs_len * @sizeOf(usize);
    if (try coverage_file.length(io) != expected_len)
        return error.WrongEnd;
}
