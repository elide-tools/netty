# Netty static-library JAR variants — design

Date: 2026-04-28
Repos in scope: `netty` (this design); `netty-tcnative` (coordination appendix).
Spec home: this file lives outside both repos to avoid contaminating either source tree.

## Goal

Produce per-platform static-archive (`.a`) JAR variants of Netty's native modules so a downstream Static JNI build can roll them up into a single static binary. Existing shared-library classifier JARs (the runtime artifacts) are unchanged.

## Scope

In scope (this repo):
- `transport-native-epoll`
- `transport-native-kqueue`
- `transport-native-io_uring`
- `codec-native-quic` — Linux + macOS profiles (`linux`, `linux-aarch64`, `mac`, `mac-m1-cross-compile`, `mac-intel-cross-compile`). Two profile families are **deferred** to follow-up plans:
  - `windows`: uses cmake + msbuild instead of autoconf/libtool, so `--enable-static` does not apply.
  - `android-*`: per-ABI hawtjniBuildDir (`target/native-build/${androidAbi}/`) and a single `jniLibName=netty_quiche` shared across ABIs — both diverge from the parent antrun's path assumption (`target/native-build/.libs/lib<name>.a` per Maven build) and would collide if multiple ABIs are built in one reactor invocation. Needs a separate design pass.
- `resolver-dns-native-macos`

Out of scope (this repo):
- `transport-native-unix-common` — already publishes `.a` + headers via its existing classifier JAR; intentionally untouched.
- All Java-only sibling artifacts (`transport-classes-*`, `codec-classes-quic`, `resolver-dns-classes-macos`).

Coordination only (sibling repo):
- `netty-tcnative` — separate PR, mirrors this contract. See appendix.

## Decisions (locked)

| # | Decision | Choice |
|---|---|---|
| 1 | Classifier scheme | Suffix `-static` on every existing classifier (e.g. `linux-x86_64-static`, `osx-aarch_64-static`). Same `groupId:artifactId` as the shared-lib variant. |
| 2 | JAR contents | `.a` + handwritten public `.h` headers from the module's `src/main/c/`. No Java classes, no `.so`/`.dylib`, no third-party headers. |
| 3 | Build trigger | Always-on inside each existing per-platform Maven profile. No new profile, no opt-in flag. |
| 4 | How to obtain `.a` | Pass `--enable-static` to hawtjni's `<configureArgs>`. Libtool then emits `lib<name>.a` into `target/native-build/.libs/`. Fall back to a per-module antrun + Makefile path mirroring `transport-native-unix-common` only if `--enable-static` proves not to work. |
| 5 | unix-common naming | Leave alone. No rename of its existing classifier. |
| 6 | Failure mode | If the expected `.a` is missing at JAR-assembly time, the build fails loudly with a clear message naming the missing path. |

## JAR layout

```
io.netty:<artifactId>:<version>:<existingClassifier>-static
└── META-INF/
    ├── MANIFEST.MF
    └── native/
        ├── lib/
        │   └── lib<basename>_<arch>.a
        └── include/
            └── *.h
```

Manifest is minimal:

```
Manifest-Version: 1.0
Implementation-Title: <artifactId>
Implementation-Version: <version>
Bundle-SymbolicName: <maven-symbolicname>.<existingClassifier>-static
```

No `Bundle-NativeCode`, no `Multi-Release`, no `Fragment-Host` — these are runtime-loader directives that don't apply to a build-time-only artifact.

## Implementation shape

### `netty-parent/pom.xml`

Add a single `maven-antrun-plugin` entry under `<build><pluginManagement>` with execution id `static-jar`, phase `package`. The execution's antrun script is parameterised by Maven properties:

| Property | Default in `netty-parent` | Notes |
|---|---|---|
| `staticLib.basename` | *(none — required)* | e.g. `netty_transport_native_epoll` |
| `staticLib.arch` | `${os.detected.arch}` | overridden in `codec-native-quic` Android profiles |
| `staticLib.includeDir` | `${nativeSourceDirectory}` | path to handwritten `.h` files |
| `staticLib.classifier` | `${jni.classifier}-static` | derived |

Antrun steps:
1. Create `${project.build.directory}/static-jar-work/META-INF/native/{lib,include}`.
2. Copy `${project.build.directory}/native-build/.libs/lib${staticLib.basename}_${staticLib.arch}.a` → `lib/`. Fail with a clear message if absent.
3. Copy `${staticLib.includeDir}/*.h` → `include/`.
4. `<jar>` → `${project.build.directory}/${project.build.finalName}-${staticLib.classifier}.jar` with the minimal manifest above.
5. `<attachartifact>` with `classifier="${staticLib.classifier}"`, `type="jar"`.

### Each in-scope module's pom

Per existing platform profile (Linux x86_64/aarch_64/riscv64; macOS x86_64/aarch_64 and cross-compile variants; Android ABIs for `codec-native-quic`):

1. Append `<configureArg>--enable-static</configureArg>` to the existing hawtjni `<configureArgs>`.
2. Set `<staticLib.basename>` (and `<staticLib.arch>` where Android profiles use `${platform}` instead of `${os.detected.arch}`) under the profile's `<properties>`.
3. Reference the inherited execution:
   ```xml
   <plugin>
     <artifactId>maven-antrun-plugin</artifactId>
     <executions>
       <execution><id>static-jar</id></execution>
     </executions>
   </plugin>
   ```

No changes to existing `maven-jar-plugin` `native-jar` execution, `maven-bundle-plugin` `native-manifest` execution, or classifier dependency declarations. Shared-lib JARs remain bit-for-bit identical to today.

### Headers shipped per module

| Module | Source dir | Files |
|---|---|---|
| `transport-native-epoll` | `src/main/c/` | `*.h` (e.g. `netty_epoll_linuxsocket.h`, `netty_epoll_vmsocket.h`) |
| `transport-native-kqueue` | `src/main/c/` | `*.h` |
| `transport-native-io_uring` | `src/main/c/` | `*.h` |
| `codec-native-quic` | `src/main/c/` | `*.h`. Vendored BoringSSL/quiche headers are **not** shipped. |
| `resolver-dns-native-macos` | `src/main/c/` | `*.h` |

**Note on `codec-native-quic`'s `.a` contents:** libtool's `--enable-static` archives only the project's own compiled object files. For codec-native-quic, this is the JNI-wrapper layer (`netty_quic.c`, `netty_quic_boringssl.c`) — roughly 300 KB. The vendored BoringSSL (`libssl.a`, `libcrypto.a`) and quiche (`libquiche.a`) static archives that the shared library transitively links against are **not** bundled into netty-quic's `.a`. Static-JNI consumers must source BoringSSL and quiche statics independently (e.g. from `netty-tcnative`'s boringssl-static module, or by re-linking with `ar` to produce a fat archive). Producing a fat archive at netty's build time is out of scope for this spec; consumer-side tooling is the right layer for that decision.

`netty-jni-util` headers are not shipped; consumers needing them depend on `transport-native-unix-common`'s existing classifier JAR.

## Verification

1. **Empirical gate (implementation step 1).** Add `--enable-static` to `transport-native-epoll`'s `linux` profile, run the platform build, confirm `target/native-build/.libs/libnetty_transport_native_epoll_x86_64.a` exists. If yes: extend the configure-arg approach across all in-scope modules. If no: implement the per-module antrun + Makefile fallback (mirroring `transport-native-unix-common`); JAR layout, classifier scheme, and parent extraction are unchanged.
2. **Per-build gate.** The static-jar antrun fails the build if the expected `.a` is missing.
3. **Per-build sanity check.** After `<jar>`, assert the produced JAR contains `META-INF/native/lib/<expected>.a` (zipfileset assertion in the same antrun).
4. **CI matrix.** No new jobs. The existing per-platform CI matrix produces the new `-static` JAR alongside the existing classifier JAR.
5. **Pre-release publishing check.** On the first snapshot deployment after this lands, verify the staged Maven repo contains the `-static` classifier artifacts for every existing classifier.

## Implementation guardrails

- **Diffs are minimal.** Each per-profile pom change is ~6 lines. No drive-by reformatting, no unrelated refactoring, no comment churn.
- **No new explanatory comments in poms unless they document a non-obvious constraint.** Existing patterns are self-documenting.
- **Commit messages are terse and factual.** No marketing language. Match existing Netty commit style (e.g. matching `<area>: <change> (#<pr>)`).
- **No new top-level docs** added to the netty repo as part of this change. This spec lives outside the repo.

## tcnative coordination appendix

`netty-tcnative` is checked out as a sibling directory. The PR there must satisfy the same contract:

1. **Classifier scheme.** Every existing classifier that publishes a shared library gets a parallel `<existingClassifier>-static` artifact. No new artifactIds.
2. **JAR layout.** Identical: `META-INF/native/lib/lib<name>.a` + `META-INF/native/include/*.h`. Minimal manifest. No Java classes, no shared lib, no OSGi runtime directives.
3. **Headers shipped.** Public `.h` from tcnative's own `src/main/c/`. Vendored BoringSSL/OpenSSL headers are **not** shipped.
4. **Build trigger.** Always-on inside existing platform profiles. No new profile, no opt-in.
5. **`.a` production.** First try `--enable-static` via configureArgs. Fall back to per-module antrun + Makefile only if needed.
6. **Strict fail-loud check** on missing `.a`, identical to the netty-side check.
7. **Module structure.** Treat each module that publishes a native classifier JAR independently. No collapsing or restructuring of `boringssl-static`, `openssl`, etc.

Open questions for the tcnative PR (deferred until checkout):
- Build driver in tcnative (hawtjni vs. hand-rolled).
- MSVC/Windows static-archive handling for `windows-x86_64` classifiers.
- Whether vendored TLS libraries' own `.a` files should union into the netty-side `.a` or remain separate.

These shape the implementation, not the contract.
