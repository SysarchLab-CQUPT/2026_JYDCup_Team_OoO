# LLVM compiler-rt provenance

The `builtins` subtree and `LICENSE.TXT` are from the official LLVM
`llvmorg-22.1.7` release. Only the RV32 soft-double objects explicitly listed
by `software/build_firmware.ps1` are linked into the firmware.

These builtins provide the freestanding IEEE-754 operations needed by the
CoreMark `HAS_FLOAT=1` reporting path without installing a roughly 1 GiB GCC
cross-toolchain.
