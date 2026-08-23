#!/usr/bin/env python3
"""check-archive-format.py — assert static archives hold the right object kind.

macOS archives MUST contain regular Mach-O objects, not LLVM bitcode. The
Mach-O NETTY_JNI_ALIAS aliases are assembler `.set` directives that bind to the
local implementation symbol at assembly time; under ThinLTO the implementation
is internalized during the final link and the alias dangles. Nothing fails at
build or link time — the archive still *lists* the symbol — so the breakage
only shows up when a downstream Native Image dylib is loaded:

    dyld: Symbol not found: _Java_io_netty_channel_kqueue_KQueueEventArray_evSet
      Referenced from: .../libelideengine.dylib
      Expected in:     .../libelideengine.dylib

Linux/ELF is the opposite: it uses IR-level `__attribute__((alias))`, which is
LTO-safe, so bitcode members are expected and fine there.

Usage:
  check-archive-format.py --os darwin  <dir-or-archive> [...]
  check-archive-format.py --os linux   <dir-or-archive> [...]
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile
import zipfile

BITCODE_MARKERS = ("LLVM bitcode", "LLVM IR bitcode")


def members(archive: pathlib.Path):
    out = subprocess.run(["ar", "t", str(archive)], capture_output=True, text=True)
    return [m for m in out.stdout.split() if m]


def member_kind(archive: pathlib.Path, member: str) -> str:
    obj = subprocess.run(["ar", "p", str(archive), member], capture_output=True).stdout
    # `file` reads the object from stdin; keep the pipe binary (no text=True) and
    # decode the description afterwards.
    kind = subprocess.run(["file", "-b", "-"], input=obj, capture_output=True)
    return kind.stdout.decode("utf-8", "replace").strip()


def archives(paths, workdir: pathlib.Path):
    """Yield .a paths from directories, bare archives, and `*-static` JARs.

    Staged output is JARs, so accept them directly and extract the archives
    under META-INF/native/lib/ rather than making every caller unzip first.
    """
    def from_jar(jar: pathlib.Path):
        with zipfile.ZipFile(jar) as z:
            for entry in z.namelist():
                if entry.startswith("META-INF/native/lib/") and entry.endswith(".a"):
                    dest = workdir / jar.stem / pathlib.Path(entry).name
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(z.read(entry))
                    yield dest

    for p in paths:
        path = pathlib.Path(p)
        if path.is_dir():
            for a in sorted(path.rglob("*.a")):
                yield a
            for jar in sorted(path.rglob("*-static.jar")):
                yield from from_jar(jar)
        elif path.suffix == ".a":
            yield path
        elif path.suffix == ".jar":
            yield from from_jar(path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--os", required=True, choices=["darwin", "linux"])
    ap.add_argument("paths", nargs="+")
    args = ap.parse_args()

    tmp = tempfile.TemporaryDirectory(prefix="archive-format-")
    found = list(archives(args.paths, pathlib.Path(tmp.name)))
    if not found:
        print(f"No .a archives under {args.paths}", file=sys.stderr)
        return 1

    bad = []
    for a in found:
        kinds = {m: member_kind(a, m) for m in members(a)}
        bitcode = [m for m, k in kinds.items() if any(b in k for b in BITCODE_MARKERS)]
        if args.os == "darwin" and bitcode:
            bad.append((a, bitcode, len(kinds)))
            print(f"  FAIL {a}: {len(bitcode)}/{len(kinds)} members are LLVM bitcode")
        else:
            sample = next(iter(kinds.values()), "empty")
            print(f"  ok   {a}: {len(kinds)} members ({sample.split(',')[0]})")

    if bad:
        print(
            f"\n{len(bad)} archive(s) contain LLVM bitcode but target macOS.\n"
            "ThinLTO internalizes the NETTY_JNI_ALIAS implementation symbols, so the\n"
            "Mach-O `.set` aliases dangle and dyld fails at load with\n"
            "`Symbol not found: _Java_io_netty_...`.\n"
            "Ensure -flto is not reaching the darwin compile (see stage-natives.sh).",
            file=sys.stderr,
        )
        return 1
    print(f"\n{len(found)} archive(s) OK for {args.os}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
