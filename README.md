# zig-espressif-bootstrap

**Note:** This fork adds new CPUs for xtensa targets, replacing llvm-upstream to espressif-llvm fork.

- **Xtensa**
   - esp32
   - esp32s2
   - esp32s3
   - esp8266
   - cannon lake
- **RISC-V**
   - esp32p4 (based on riscv32-imafc)
   - esp32h4 (based on riscv32-imafc + xespdsp)

The purpose of this project is to start with minimum system dependencies and
end with a fully operational Zig compiler for any target.

## Version Information

This repository copies sources from upstream. Patches listed below. Use git
to find and inspect the patch diffs.

 * LLVM, LLD, Clang 21.1.0 ([espressif fork](https://github.com/espressif/llvm-project))
 * zlib 1.3.1
 * zstd 1.5.2
 * zig 0.16.0-dev

For other versions, check the git tags of this repository.

### Patches

 * all: Deleted unused files.
 * LLVM: Support .lib extension for static zstd.
 * LLVM: Portable handling of .def linker flag
 * Clang: Disable building of libclang-cpp.so.
 * LLD: Added additional include directory to Zig's libunwind.
 * LLD: Respect `LLD_BUILD_TOOLS=OFF`
 * zlib: Delete the ability to build a shared library.

## Host System Dependencies

 * C++ compiler capable of building LLVM, Clang, and LLD from source (GCC 5.1+
   or Clang)
 * CMake 3.19 or later
 * make, ninja, or any other build system supported by CMake
 * POSIX system (bash, mkdir, cd)
 * Python 3

## Build Instructions

```
./build <arch>-<os>-<abi> <mcpu>
```

All parameters are required:

 * `<arch>-<os>-<abi>`: Replace with one of the Supported Triples below, or use
   `native` for the `<arch>` value (e.g. `native-linux-gnu`) to use the native
   architecture.
 * `<mcpu>`: Replace with a `-mcpu` parameter of Zig. `baseline` is recommended
   and means it will target a generic CPU for the target. `native` means it
   will target the native CPU. See the Zig documentation for more details.

Please be aware of the following two CMake environment variables that can
significantly affect how long it takes to build:

 * `CMAKE_GENERATOR` can be used to select a different generator instead of the
   default. For example, `CMAKE_GENERATOR=Ninja`.
 * `CMAKE_BUILD_PARALLEL_LEVEL` can be used to introduce parallelism to build
   systems (such as make) which do not default to parallel builds. This option
   is irrelevant when using Ninja.

When it succeeds, output can be found in `out/zig-<triple>-<cpu>/`.

## Windows Build Instructions

Bootstrapping on Windows with MSVC is also possible via `build.bat`, which
takes the same arguments as `build` above.

This script requires that the "C++ CMake tools for Windows" component be
installed via the Visual Studio installer.

The script must be run within the `Developer Command Prompt for VS 2019` shell:

```
build.bat <arch>-<os>-<abi> <mcpu>
```

To build for x86 Windows, run the script within the `x86 Native Tools Command Prompt for VS 2019`.
