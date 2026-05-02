/*
 * Copyright 2026 The Netty Project
 *
 * The Netty Project licenses this file to you under the Apache License,
 * version 2.0 (the "License"); you may not use this file except in compliance
 * with the License. You may obtain a copy of the License at:
 *
 *   https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 */
#ifndef NETTY_JNI_STATIC_H
#define NETTY_JNI_STATIC_H

#include <jni.h>

/*
 * NETTY_JNI_ALIAS — emit a JNI-spec entry symbol Java_<class>_<method> as an
 * alias for an existing internal C function.
 *
 * Used in the static-archive build path (gated by NETTY_BUILD_STATIC; this
 * header is only pulled in under that gate) to expose JNI methods at default
 * visibility for a JVM that resolves them via dlsym on the program image.
 *
 * Implementation:
 *   - ELF (Linux/BSD): __attribute__((alias, visibility("default"))). This
 *     creates a proper symbol alias in the LLVM IR, so it appears in both the
 *     bitcode and the archive symbol index — required for LTO archives that
 *     LLD scans before pulling in object files. The visibility override is
 *     critical when the translation unit is compiled with -fvisibility=hidden:
 *     without it the alias inherits hidden visibility and the linker can't
 *     resolve external references to Java_*.
 *   - Mach-O (macOS): clang rejects __attribute__((alias)) with "aliases are
 *     not supported on darwin". Fall back to a `.set` assembler directive at
 *     file scope. Mach-O archives don't get LTO-bitcode-index issues because
 *     Mach-O linkers always read the .o symbol tables (post-asm).
 *
 * Arguments:
 *   java_class  — Fully qualified Java class with '_' separators
 *                 (e.g. io_netty_channel_kqueue_Native).
 *   method      — Bare method name (e.g. kqueueCreate).
 *   internal_fn — Existing C function name (e.g. netty_kqueue_native_kqueueCreate).
 */
#if defined(__APPLE__)
#  define NETTY_JNI_ALIAS(java_class, method, internal_fn) \
       __asm__(".globl _Java_" #java_class "_" #method "\n" \
               ".set _Java_" #java_class "_" #method ", _" #internal_fn);
#else
#  define NETTY_JNI_ALIAS(java_class, method, internal_fn) \
       extern __typeof__(internal_fn) Java_##java_class##_##method \
           __attribute__((alias(#internal_fn), visibility("default")));
#endif

#endif /* NETTY_JNI_STATIC_H */
