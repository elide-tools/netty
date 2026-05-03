# Elide netty static-JNI alias gaps — `epoll.NativeStaticallyReferencedJniMethods`

## Goal

Add three missing `NETTY_JNI_ALIAS` entries so the static archive
(`libnetty_transport_native_epoll_<arch>.a`) exports the full set of
`Java_<class>_<method>` symbols that SVM's static-JNI prefix lookup expects for the Java class
`io.netty.channel.epoll.NativeStaticallyReferencedJniMethods`.

The fix is three additional alias macros pointing at C functions that already exist in the
archive (they come from `transport-native-unix-common/src/main/c/netty_unix_limits.c` and are
already linked into the epoll static archive). The aliases must be emitted from
`netty_unix_limits.c` itself — see "What to change" below for why.

## Symptom on the consumer side

Elide's native-image link fails with:

```
ld.lld: error: undefined symbol: Java_io_netty_channel_epoll_NativeStaticallyReferencedJniMethods_ssizeMax
ld.lld: error: undefined symbol: Java_io_netty_channel_epoll_NativeStaticallyReferencedJniMethods_uioMaxIov
ld.lld: error: undefined symbol: Java_io_netty_channel_epoll_NativeStaticallyReferencedJniMethods_iovMax
>>> referenced by elide.o:(.data+...)
```

SVM emits a `.data` relocation against `Java_<class>_<method>` for every native method on a class
registered for static-JNI prefix lookup that's reachable in the image's call graph. Those three
relocations target symbols that don't exist in any archive on the link line.

## Why those three specifically

The Java class `io.netty.channel.epoll.NativeStaticallyReferencedJniMethods`
(`transport-classes-epoll/src/main/java/io/netty/channel/epoll/NativeStaticallyReferencedJniMethods.java`)
declares 13 native methods. The corresponding alias block in
`transport-native-epoll/src/main/c/netty_epoll_native.c` (lines 877-886 in the current state of
the fork) covers 10 of them and omits exactly these three:

| Java native (declared in `epoll.NativeStaticallyReferencedJniMethods`) | C alias under `io_netty_channel_epoll_NativeStaticallyReferencedJniMethods` prefix |
|------------------------------------------------------------------------|------------------------------------------------------------------------------------|
| epollin / epollout / epollrdhup / epollet / epollerr                  | ✅ present                                                                          |
| tcpMd5SigMaxKeyLen                                                     | ✅ present                                                                          |
| isSupportingSendmmsg / isSupportingRecvmmsg                            | ✅ present                                                                          |
| tcpFastopenMode / kernelVersion                                        | ✅ present                                                                          |
| **ssizeMax**                                                           | **❌ missing**                                                                       |
| **iovMax**                                                             | **❌ missing**                                                                       |
| **uioMaxIov**                                                          | **❌ missing**                                                                       |

The Java class is `final` and extends nothing, so these three native declarations aren't
inherited from the unix-common `LimitsStaticallyReferencedJniMethods` class — they're declared
directly on `epoll.NativeStaticallyReferencedJniMethods` and therefore need their own
`Java_io_netty_channel_epoll_NativeStaticallyReferencedJniMethods_<method>` symbol. Static-JNI
prefix lookup at image-build link time treats every (class, method) pair as a separate symbol;
the unix-common class's aliases don't satisfy the epoll class's references.

The C function bodies the aliases need to point at are already present in the epoll archive
(`netty_unix_limits.c` is bundled into the same static archive via `transport-native-unix-common`):

- `netty_unix_limits_ssizeMax`
- `netty_unix_limits_iovMax`
- `netty_unix_limits_uioMaxIov`

Verified with `llvm-nm`:

```
$ llvm-nm libnetty_transport_native_epoll_x86_64.a | grep -E 'ssizeMax|iovMax|uioMaxIov'
T Java_io_netty_channel_unix_LimitsStaticallyReferencedJniMethods_iovMax
T Java_io_netty_channel_unix_LimitsStaticallyReferencedJniMethods_ssizeMax
T Java_io_netty_channel_unix_LimitsStaticallyReferencedJniMethods_uioMaxIov
t netty_unix_limits_iovMax
t netty_unix_limits_ssizeMax
t netty_unix_limits_uioMaxIov
```

So the C bodies are already linked in; only three more `Java_*` aliases are needed under the
epoll class prefix.

## What to change

In `transport-native-unix-common/src/main/c/netty_unix_limits.c`, locate the existing
`NETTY_JNI_ALIAS(io_netty_channel_unix_LimitsStaticallyReferencedJniMethods, ...)` alias block at
the bottom of the file and append three new entries under the epoll class prefix pointing at the
same C bodies:

```c
NETTY_JNI_ALIAS(io_netty_channel_epoll_NativeStaticallyReferencedJniMethods, ssizeMax,  netty_unix_limits_ssizeMax)
NETTY_JNI_ALIAS(io_netty_channel_epoll_NativeStaticallyReferencedJniMethods, iovMax,    netty_unix_limits_iovMax)
NETTY_JNI_ALIAS(io_netty_channel_epoll_NativeStaticallyReferencedJniMethods, uioMaxIov, netty_unix_limits_uioMaxIov)
```

### Why netty_unix_limits.c and not netty_epoll_native.c

`__attribute__((alias))` is a compile-time directive: clang/gcc both require the alias target to
be defined in the same translation unit as the alias declaration. The target's linkage (static
vs. extern) does not matter — but the *definition* must be in the same TU. The `netty_unix_limits_*`
function bodies live in `netty_unix_limits.c`, so the only TU where `NETTY_JNI_ALIAS(...,
netty_unix_limits_*)` compiles cleanly is `netty_unix_limits.c` itself.

(An alternative would be to convert the static functions to extern + add forwarder functions in
`netty_epoll_native.c` that call them through the function pointer. That works but adds an extra
indirection per JNI call and changes the surface area of `netty_unix_limits.c` for no benefit;
emitting the alias from the same TU is the cleaner solution.)

The aliases coexist harmlessly with the `RegisterNatives` flow that runs at JNI_OnLoad time —
`RegisterNatives` overrides the JNI dispatch table at runtime, while the aliases stay as
additional link-time entries needed by the static-JNI prefix lookup at native-image link time.

## Verification

After rebuild, the missing aliases should be present:

```bash
llvm-nm .../libnetty_transport_native_epoll_<arch>.a \
  | grep -E 'T Java_io_netty_channel_epoll_NativeStaticallyReferencedJniMethods_(ssizeMax|iovMax|uioMaxIov)'
```

Expected output (3 lines):

```
                 T Java_io_netty_channel_epoll_NativeStaticallyReferencedJniMethods_iovMax
                 T Java_io_netty_channel_epoll_NativeStaticallyReferencedJniMethods_ssizeMax
                 T Java_io_netty_channel_epoll_NativeStaticallyReferencedJniMethods_uioMaxIov
```

After re-staging the archive into Elide, the native-image link should succeed for these three
symbols.

## Optional follow-up

io_uring's equivalent class
(`transport-classes-io_uring/src/main/java/io/netty/channel/uring/NativeStaticallyReferencedJniMethods.java`)
already has a complete alias surface in `transport-native-io_uring/src/main/c/netty_io_uring_native.c`
(67 aliases verified) — no change needed there.

kqueue should be audited symmetrically before its archive is staged, but that hasn't been built
yet in this environment so we haven't observed link failures from it.

The audit query for any transport is:

```bash
# diff Java declarations against C aliases for a class:
diff <(grep -oE 'native [A-Za-z]+ ([a-zA-Z]+)' \
        transport-classes-<x>/src/main/java/io/netty/channel/<x>/NativeStaticallyReferencedJniMethods.java \
      | awk '{print $NF}' | tr -d '()' | sort -u) \
     <(grep -oE 'NETTY_JNI_ALIAS\(io_netty_channel_<x>_NativeStaticallyReferencedJniMethods, *([a-zA-Z]+),' \
        transport-native-<x>/src/main/c/netty_<x>_native.c \
      | sed 's/.*JniMethods, *\([a-zA-Z]*\),.*/\1/' | sort -u)
```

## Companion changes

- `static-jni/cflags/base.txt` — adds `-DNETTY_JNI_UTIL_BUILD_STATIC` so netty-jni-util's
  `JNI_OnLoad` skips the dladdr branch in static-link builds (dladdr fails on a stripped binary).
  Required for the static-JNI link to bootstrap cleanly downstream; the alias gap fix above
  is independently required for the link to succeed at all.

## Out of scope

- No changes to the Java class declarations. The Elide build consumes the published Java classes
  unmodified.
- No changes to the C function bodies in `netty_unix_limits.c`. The function bodies don't need a
  second copy — the second `Java_*` symbol just points at the existing one. (We do add three
  `NETTY_JNI_ALIAS` macro lines at the bottom of the file, alongside the existing ones, but the
  static C functions they alias are unmodified.)
- No changes to how the static archive is assembled. The `netty_unix_limits.o` member is already
  in `libnetty_transport_native_epoll_<arch>.a`.
