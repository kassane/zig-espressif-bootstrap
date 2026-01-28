const c = @cImport({
    @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("stdio.h");
});
pub fn main() void {
    if (@import("builtin").os.tag == .netbsd) return; // https://github.com/Vexu/arocc/issues/960
    _ = c;
}

// exe=succeed
// link_libc
// verbose_cimport
