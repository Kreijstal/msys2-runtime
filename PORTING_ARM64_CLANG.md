# MSYS2 runtime ARM64/Clang port attempt

Target: native Windows ARM64 (`aarch64-pc-msys`) using LLVM-MinGW Clang.

## Bootstrap order

1. Build GNU binutils for `aarch64-w64-mingw32`.
2. Use Clang as the C/C++ frontend with the ARM64 PE/COFF target.
3. Build newlib plus the MSYS/Cygwin public headers and w32api surface.
4. Build and link `msys-2.0.dll`.
5. Build the shell and core packages against that runtime.

GNU binutils was cloned separately from sourceware because the MSYS2 runtime
repository does not carry the `bfd`, `gas`, `ld`, or `binutils` source trees.
Upstream binutils commit `ebf22fc26326ad138bea9dee536cf081e46dd6e1`
built successfully on macOS for `aarch64-w64-mingw32`.  The resulting GNU ld
2.46.50 exposes both `aarch64pe` and `arm64pe` emulations, along with GAS,
`dlltool`, `windres`, `objcopy`, `objdump`, `nm`, and archive tools.

## Baseline

- Upstream commit: `01d6c708f9221334d18ab332621b6d87eb12d37e`
- The top-level configure accepts `aarch64-pc-msys` when Clang is supplied as
  `CC_FOR_TARGET`.
- ARM64 newlib compiles substantially before the first failure.

## First failure

LLVM-MinGW's compiler wrapper injects its UCRT sysroot while the runtime build
also injects newlib.  The two header worlds disagree about `ssize_t` on LLP64:

```text
LLVM-MinGW corecrt.h: typedef __int64 ssize_t;
newlib sys/types.h:  typedef long _ssize_t;
```

The port toolchain wrapper uses LLVM's ARM64 PE/COFF backend and builtin headers
but suppresses the UCRT include tree with `-nostdinc`.

## Second failure

Windows ARM64 uses 64-bit `long double` (`long double == double`).  Newlib
detected `_LDBL_EQ_DBL` correctly but still selected `libm/ld`, whose sources
require an 80-bit or 128-bit `fpmath.h` layout.  The port adds an Automake
conditional so those extended-format sources are skipped when double and long
double have the same ABI representation.

The same condition must cover AArch64's `libm/ld128` selection.  Upstream
normally assumes AArch64 uses IEEE binary128 `long double`, while the Windows
ARM64 ABI used by LLVM-MinGW represents it as ordinary binary64 `double`.

## Explicit upstream architecture gates found

- `winsup/configure.ac` rejected every target except `x86_64`.
- MinGW helper discovery required GCC-named executables.
- `winsup/cygwin/cygwin.sc.in` only emitted `pei-x86-64`.
- Runtime startup, context switching, TLS, exception unwinding, fork, and math
  still contain numerous x86-64 assembly and register-layout assumptions.

This is an early bring-up branch, not yet a production runtime.

## Third failure

After excluding UCRT, newlib reaches its MSYS/Windows allocator and requires
`windows.h`.  The wrapper therefore searches LLVM-MinGW's Win32 headers with
`-idirafter` (after newlib), while defining the UCRT compatibility guards for
the ABI types already owned by newlib.

Generic LLVM-MinGW also defines the build as ordinary Win32, selecting
newlib's obsolete 32-bit `VirtualAlloc`-based `wsbrk`.  The port driver defines
the Cygwin/MSYS target macros so newlib follows the runtime-provided `sbrk`
path, matching what an eventual `aarch64-pc-msys-clang` target should do
natively inside Clang.

Defining the runtime identity also makes newlib include `cygwin/config.h`, so
the bootstrap driver stages `winsup/cygwin/include` before the full winsup
install exists.

## First runtime architecture primitive

`cygwin/config.h::__getreent()` obtains the per-thread newlib state through
the Windows TEB.  x86-64 reads `GS:8`; Windows ARM64 reserves `x18` as the TEB
pointer, so the ARM64 implementation loads the corresponding pointer from
`x18 + 8` before applying `__CYGTLS_PADSIZE__`.

The next newlib dependency is the public signal/ucontext ABI.  The port adds an
ARM64 `__mcontext` matching Windows `ARM64_NT_CONTEXT` (X0-X30, SP, PC, NEON,
FP status/control, breakpoint and watchpoint registers), followed by Cygwin's
`oldmask` and `cr2` extension fields.

## Current result

The complete target newlib stage succeeds with Clang and ARM64 PE/COFF
binutils.  The winsup build starts but stops at the x86-64-only lazy import
trampolines in `winsup/cygwin/autoload.cc`.  Correct ARM64 trampolines and
Windows unwind metadata are required before an `msys-2.0.dll` can be linked.

The lazy-import stubs and initial thread/process stack switches now compile as
ARM64 PE/COFF.  A later audit found the bootstrap compiler was still using
Windows LLP64.  The paired LLVM patch adds an LP64 `CygwinARM64TargetInfo`;
all libraries must be rebuilt with that compiler before this port is ABI-valid.

## MSYS newlib target recognition

`newlib/configure.host` carried Cygwin-specific runtime flags only for
`*-*-cygwin*`; the `aarch64-pc-msys` target therefore tried to compile its own
allocator and syscalls.  MSYS uses the same integration contract, so the MSYS
patterns now receive `MALLOC_PROVIDED`, `GETREENT_PROVIDED`, signal/syscall
flags, POSIX/XDR directories, and the winsup include staging.

Clang's resource headers are placed with `-idirafter`.  Its builtin `float.h`
uses `include_next` and otherwise reaches LLVM-MinGW's UCRT `float.h` ahead of
newlib, causing macro and ABI collisions.
