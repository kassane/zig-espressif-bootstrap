//===--- Xtensa.h - Xtensa-specific Tool Helpers -----------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_CLANG_LIB_DRIVER_TOOLCHAINS_ARCH_XTENSA_H
#define LLVM_CLANG_LIB_DRIVER_TOOLCHAINS_ARCH_XTENSA_H

#include "clang/Driver/Driver.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Option/Option.h"
// #include <string>
#include <vector>

namespace clang {
namespace driver {
namespace tools {
namespace xtensa {
void getXtensaTargetFeatures(const Driver &D, const llvm::Triple &Triple,
                            const llvm::opt::ArgList &Args,
                            std::vector<llvm::StringRef> &Features);
} // end namespace xtensa
} // namespace tools
} // end namespace driver
} // end namespace clang

#endif // LLVM_CLANG_LIB_DRIVER_TOOLCHAINS_ARCH_XTENSA_H
