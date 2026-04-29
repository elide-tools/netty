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
 * This is used in the static-archive build path (gated by NETTY_BUILD_STATIC;
 * this header is only pulled in under that gate) to expose JNI methods at
 * default visibility for a JVM that resolves them via dlsym on the program
 * image.
 *
 * Implementation note: Clang on Mach-O does NOT support __attribute__((alias))
 * (it errors with "aliases are not supported on darwin"). To stay portable
 * across ELF (Linux/BSD) and Mach-O (macOS) we emit the alias as an assembler
 * directive at file scope: `.globl <Java_*>` exports the new symbol and
 * `.set <Java_*>, <internal_fn>` makes it equivalent to the existing target.
 * Both forms are accepted by GNU as and Apple's as. The leading underscore
 * required for Mach-O symbol names (and absent on ELF) is handled by the
 * NETTY_JNI_SYMBOL_PREFIX macro.
 *
 * Arguments:
 *   java_class  — Fully qualified Java class with '_' separators
 *                 (e.g. io_netty_channel_kqueue_Native).
 *   method      — Bare method name (e.g. kqueueCreate).
 *   internal_fn — Existing C function name (e.g. netty_kqueue_native_kqueueCreate).
 */
#if defined(__APPLE__)
#  define NETTY_JNI_SYMBOL_PREFIX "_"
#else
#  define NETTY_JNI_SYMBOL_PREFIX ""
#endif

#define NETTY_JNI_ALIAS(java_class, method, internal_fn) \
    __asm__(".globl " NETTY_JNI_SYMBOL_PREFIX "Java_" #java_class "_" #method "\n" \
            ".set "   NETTY_JNI_SYMBOL_PREFIX "Java_" #java_class "_" #method ", " \
                      NETTY_JNI_SYMBOL_PREFIX #internal_fn);

#endif /* NETTY_JNI_STATIC_H */
