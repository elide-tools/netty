#!/usr/bin/env python3
"""check-jni-aliases.py — fail if a Java `native` method has no NETTY_JNI_ALIAS.

The static-JNI build exports `Java_<class>_<method>` symbols by emitting
`NETTY_JNI_ALIAS(...)` entries alongside each JNINativeMethod table. Those lists
are hand-maintained, so a new upstream native method silently ships without an
alias — and the failure only appears much later, as
`ld.lld: undefined symbol: Java_io_netty_...` when a downstream Native Image
links the archive. Run this after a fork rebase to catch it at the source.

Usage:
  check-jni-aliases.py [--netty-dir DIR] [--tcnative-dir DIR]

Exits non-zero and lists the missing symbols if any alias is absent.
"""
import argparse
import pathlib
import re
import sys

# A Java declaration carrying the `native` modifier and no body. Deliberately
# strict: it must terminate in `;` and must not span a parenthesised expression,
# so ordinary call sites (`nativeArrays.free();`) are not mistaken for decls.
DECL = re.compile(
    r"(?:^|[;{}])\s*(?:(?:public|private|protected|static|final|synchronized|abstract)\s+)*"
    r"native\s+[\w\[\]<>,.\s]+?\s+(\w+)\s*\([^)]*\)\s*(?:throws\s[\w,.\s]+)?;",
    re.M,
)
ALIAS = re.compile(r"NETTY_JNI_ALIAS\(\s*([A-Za-z0-9_]+)\s*,\s*([A-Za-z0-9_]+)\s*,")


def jni_mangle(fqcn: str) -> str:
    """JNI short-name mangling for a class: `_` -> `_1`, then `.` -> `_`."""
    return fqcn.replace("_", "_1").replace(".", "_")


def collect_aliases(cdirs) -> set:
    found = set()
    for cd in cdirs:
        d = pathlib.Path(cd)
        if not d.is_dir():
            continue
        for cf in sorted(list(d.glob("*.c")) + list(d.glob("*.h"))):
            found |= set(ALIAS.findall(cf.read_text()))
    return found


def check(label, jdir, pkg, cdirs):
    jp = pathlib.Path(jdir)
    if not jp.is_dir():
        print(f"  {label}: skipped (no {jdir})")
        return []
    aliased = collect_aliases(cdirs)
    missing = []
    for jf in sorted(jp.glob("*.java")):
        mangled = jni_mangle(f"{pkg}.{jf.stem}")
        declared = set(DECL.findall(jf.read_text()))
        if not declared:
            continue
        have = {m for cls, m in aliased if cls == mangled}
        for m in sorted(declared - have):
            missing.append((f"{pkg}.{jf.stem}", m, f"Java_{mangled}_{m}"))
    verdict = "OK" if not missing else f"MISSING {len(missing)}"
    print(f"  {label}: {len(aliased)} aliases, {verdict}")
    return missing


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--netty-dir", default=".")
    ap.add_argument("--tcnative-dir", default=None)
    args = ap.parse_args()

    n = pathlib.Path(args.netty_dir)
    units = [
        ("io_uring", n / "transport-classes-io_uring/src/main/java/io/netty/channel/uring",
         "io.netty.channel.uring",
         [n / "transport-native-io_uring/src/main/c", n / "transport-native-unix-common/src/main/c"]),
        ("epoll", n / "transport-classes-epoll/src/main/java/io/netty/channel/epoll",
         "io.netty.channel.epoll",
         [n / "transport-native-epoll/src/main/c", n / "transport-native-unix-common/src/main/c"]),
        ("kqueue", n / "transport-classes-kqueue/src/main/java/io/netty/channel/kqueue",
         "io.netty.channel.kqueue",
         [n / "transport-native-kqueue/src/main/c", n / "transport-native-unix-common/src/main/c"]),
    ]
    if args.tcnative_dir:
        t = pathlib.Path(args.tcnative_dir)
        units.append(
            ("tcnative", t / "openssl-classes/src/main/java/io/netty/internal/tcnative",
             "io.netty.internal.tcnative", [t / "openssl-dynamic/src/main/c"]))

    print("Checking NETTY_JNI_ALIAS coverage for Java native methods:")
    missing = []
    for label, jdir, pkg, cdirs in units:
        missing += check(label, jdir, pkg, cdirs)

    if missing:
        print(f"\n{len(missing)} Java native method(s) have no NETTY_JNI_ALIAS:\n")
        for cls, method, symbol in missing:
            print(f"  {cls}.{method}")
            print(f"    -> add NETTY_JNI_ALIAS for {symbol}")
        print("\nA downstream static-JNI link will fail with `undefined symbol` for each.")
        return 1
    print("\nAll Java native methods have a NETTY_JNI_ALIAS.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
