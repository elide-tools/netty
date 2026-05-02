# Netty-tcnative static-library JAR variants — design

Date: 2026-04-28
Repo: `netty-tcnative` (sibling to `netty/`).
Spec home: this file lives outside the source tree to avoid polluting upstream-bound diffs.

This is the tcnative-side implementation of the contract defined in the netty spec's coordination appendix. Inherits architecture, classifier scheme, JAR layout, fail-loud behavior, and implementation guardrails from `2026-04-28-netty-static-jar-variants-design.md`. This document captures only tcnative-specific deltas.

## Scope

In scope (this repo):
- `openssl-dynamic` — links against system OpenSSL/APR; produces shared lib.
- `boringssl-static` — bundles BoringSSL via cmake, then hawtjni autoconf builds the netty wrapper.
- `openssl-static` — bundles system OpenSSL via cmake/nmake, then hawtjni wrapper.
- `libressl-static` — bundles LibreSSL via cmake, then hawtjni wrapper.

Out of scope (this repo):
- `openssl-classes` — Java-only sibling.
- Any windows profile that drives the netty wrapper through `nmake`/MSVC instead of autoconf+libtool. Defer like quic/windows in netty.

## Key tcnative-specific facts

1. **Single hawtjni `<name>netty_tcnative</name>` for every native module and every profile.** The lib filename is `libnetty_tcnative.{so,dylib,a}` regardless of arch — Maven distinguishes variants via classifier only. So `staticLib.libname=netty_tcnative` lands at module level for all four native modules, with no per-profile overrides.

2. **Classifier convention is `${os.detected.classifier}`** (e.g. `osx-aarch_64`, `linux-x86_64`). Same form as netty's `${jni.classifier}`. The `static-jar` antrun execution uses `<staticLib.classifier>${os.detected.classifier}-static</staticLib.classifier>` (note the property reference difference vs. netty).

3. **Default activation behavior:** unlike netty (which has a `linux` profile activated only on Linux hosts), tcnative's `openssl-dynamic` default build path runs at the module level without an explicit profile. So `skipStaticJar=false` lands at module level for all four native modules — the platform profiles override only when arch-specific tweaks are needed (mac-x86_64, mac-aarch64, linux-aarch64).

4. **The bundled TLS libraries are NOT redistributed in the netty `.a`.** Same constraint as netty's quic: libtool's `--enable-static` archives only `netty_tcnative`'s own JNI wrapper objects. Static-JNI consumers needing TLS must source `libssl.a`/`libcrypto.a` (or `libtls.a` for libressl) separately. Document this in the spec; out of scope to bundle a fat archive.

5. **`-static` classifier suffix on `boringssl-static`/`openssl-static`/`libressl-static` modules creates a naming clash:** the artifact reads `netty-tcnative-boringssl-static:2.0.77.Final:linux-x86_64-static.jar` — two "static" tokens with different meanings (module-flavor vs classifier-flavor). Tolerable; functional; consistent with the netty-side classifier scheme. Not renaming the modules.

## Decisions (locked, mirror netty unless noted)

| # | Decision | Choice |
|---|---|---|
| 1 | Classifier scheme | Suffix `-static` on every existing classifier (e.g. `osx-aarch_64-static`). |
| 2 | JAR contents | `.a` + handwritten public `.h` headers from the module's `src/main/c/`. No Java classes, no `.so`/`.dylib`, no third-party headers. |
| 3 | Build trigger | Always-on inside each existing per-platform Maven profile, plus the module's default build path. No new profile, no opt-in flag. |
| 4 | How to obtain `.a` | Pass `--enable-static --with-pic` to hawtjni's `<configureArgs>`. |
| 5 | Failure mode | If the expected `.a` is missing at JAR-assembly time, the build fails loudly. |
| 6 | Property naming | `skipStaticJar` (default `true`), `staticLib.libname` (`netty_tcnative` at module level, no per-profile override needed), `staticLib.classifier` (`${os.detected.classifier}-static` — note the `os.detected` prefix vs netty's `jni.classifier`), `staticLib.includeDir` (`${nativeSourceDirectory}` — same as netty). |

## JAR layout

Same as netty:
```
META-INF/MANIFEST.MF                  (minimal: Implementation-Title, Implementation-Version)
META-INF/native/lib/libnetty_tcnative.a
META-INF/native/include/*.h           (public headers from src/main/c/)
```

## Implementation shape

### `pom.xml` (tcnative-parent)

Add to `<properties>`:
```xml
<skipStaticJar>true</skipStaticJar>
<staticLib.classifier>${os.detected.classifier}-static</staticLib.classifier>
<staticLib.includeDir>${nativeSourceDirectory}</staticLib.includeDir>
```

Add the `static-jar` execution to the existing `maven-antrun-plugin` entry under `<build><pluginManagement>` (the entry already exists for ant-contrib version pinning). Same antrun body as netty's parent — `<fail>` on missing `.a`, copy `.a` and `*.h`, `<jar>` with minimal manifest, `<attachartifact>` with `${staticLib.classifier}`.

### Each native module's pom (`openssl-dynamic`, `boringssl-static`, `openssl-static`, `libressl-static`)

At module-level `<properties>`:
```xml
<staticLib.libname>netty_tcnative</staticLib.libname>
<skipStaticJar>false</skipStaticJar>
```

In every `<configureArgs>` block (the one in the module's main `<build><plugins>` hawtjni execution + any per-platform profile overrides), append:
```xml
<configureArg>--enable-static</configureArg>
<configureArg>--with-pic</configureArg>
```

No per-profile property overrides needed (because `staticLib.libname` is constant across all tcnative profiles).

### Profile inventory per module (to be confirmed at implementation time)

| Module | Profiles touched | Profiles deferred |
|---|---|---|
| `openssl-dynamic` | default (no -P), `mac-x86_64`, `mac-aarch64`, `linux-aarch64`, possibly `linux-aarch64`/`linux-x86_64` cross | windows (if nmake) |
| `boringssl-static` | `boringssl-static-default`, `fips-boringssl-static`, plus their per-platform sub-profiles | windows |
| `openssl-static` | default + per-platform profiles | windows (`build-openssl-windows` uses nmake) |
| `libressl-static` | default + per-platform profiles | windows (cmake but MSVC-driven — TBD at implementation time) |

The implementer verifies at edit time which profiles drive the netty wrapper through autoconf+libtool vs. an MSVC-only path; only the autoconf-driven ones get `--enable-static --with-pic`.

## Verification

1. **Empirical gate (T1):** add `--enable-static --with-pic` to one mac-buildable module/profile pair (e.g. `openssl-dynamic` + `mac-aarch64`), run the platform build, confirm `target/native-build/.libs/libnetty_tcnative.a` exists. If yes: roll out across all in-scope modules. If no: implement the per-module antrun + Makefile fallback (mirrors netty's contingency); JAR layout/classifier scheme/parent extraction unchanged.

2. **Per-build gate:** the static-jar antrun fails loudly if the expected `.a` is missing (inherited from netty parent execution).

3. **Per-build sanity check:** zipfileset assertion on the produced JAR (inherited).

4. **CI matrix:** no new CI jobs needed — Netty-tcnative's existing per-platform build matrix produces the new `-static` JAR alongside each existing classifier JAR.

## Implementation guardrails (inherited verbatim from netty spec)

- Diffs are minimal. Each per-profile pom change is small (typically 4–6 lines).
- No drive-by reformatting, no comment churn, no unrelated refactoring.
- Commit messages are terse and factual, matching tcnative's existing style. No AI sign-off, no `Co-Authored-By` trailers, no marketing language.
- No new top-level docs added to the tcnative repo. This spec lives outside it.

## Out-of-band (not part of this implementation)

- **Windows static archives** for any nmake/MSVC-driven profile — separate plan.
- **Fat archive** that bundles BoringSSL/OpenSSL/LibreSSL `.a` into a single `libnetty_tcnative_full.a` — out of scope; consumers of the static JAR source TLS statics independently.
- **Pre-release publishing check:** verify the staged Maven repo contains `-static` classifier artifacts before cutting a tcnative release.
