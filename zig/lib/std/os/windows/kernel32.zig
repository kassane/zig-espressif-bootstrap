const std = @import("../../std.zig");
const windows = std.os.windows;

const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const LPCVOID = windows.LPCVOID;
const LPCWSTR = windows.LPCWSTR;
const LPVOID = windows.LPVOID;
const LPWSTR = windows.LPWSTR;
const PROCESS = windows.PROCESS;
const THREAD_START_ROUTINE = windows.THREAD_START_ROUTINE;
const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
const SIZE_T = windows.SIZE_T;
const STARTUPINFOW = windows.STARTUPINFOW;
const UINT = windows.UINT;
const va_list = windows.va_list;
const Win32Error = windows.Win32Error;

// I/O - Filesystem

pub extern "kernel32" fn GetSystemDirectoryW(
    lpBuffer: LPWSTR,
    uSize: UINT,
) callconv(.winapi) UINT;

// Process Management

pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?LPWSTR,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: windows.CreateProcessFlags,
    lpEnvironment: ?[*:0]const u16,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS.INFORMATION,
) callconv(.winapi) BOOL;

// Threading

// TODO: CreateRemoteThread with hProcess=NtCurrentProcess().
pub extern "kernel32" fn CreateThread(
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    dwStackSize: SIZE_T,
    lpStartAddress: *const THREAD_START_ROUTINE,
    lpParameter: ?LPVOID,
    dwCreationFlags: DWORD,
    lpThreadId: ?*DWORD,
) callconv(.winapi) ?HANDLE;

// Error Management

pub extern "kernel32" fn FormatMessageW(
    dwFlags: DWORD,
    lpSource: ?LPCVOID,
    dwMessageId: Win32Error,
    dwLanguageId: DWORD,
    lpBuffer: LPWSTR,
    nSize: DWORD,
    Arguments: ?*va_list,
) callconv(.winapi) DWORD;
