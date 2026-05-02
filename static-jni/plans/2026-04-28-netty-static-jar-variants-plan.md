# Netty Static JAR Variants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce per-platform static-archive (`.a`) classifier JARs for Netty's five in-scope native modules (`transport-native-{epoll,kqueue,io_uring}`, `codec-native-quic`, `resolver-dns-native-macos`), without changing the existing shared-library classifier JARs.

**Architecture:** Add one parameterised `static-jar` antrun execution to `netty-parent`'s `<pluginManagement>`, gated by the property `skipStaticJar` (default `true`, so it's a no-op for every module). Each in-scope module's per-platform Maven profile (a) passes `--enable-static --with-pic` to hawtjni's `<configureArgs>` so libtool emits `lib<name>.a` alongside the existing shared library, (b) sets `staticLib.libname` to match the hawtjni `<name>` value, (c) flips `skipStaticJar=false` to opt the profile in. The `maven-antrun-plugin` is already declared in `netty-parent`'s `<build><plugins>` (for the existing `write-version-properties` execution), so child modules inherit the plugin binding and pluginManagement merges the `static-jar` execution into every module — the property gate keeps it inert everywhere except opted-in profiles. Result: every existing `<classifier>` JAR is paired with a new `<classifier>-static` JAR containing the libtool-emitted `.a` plus the module's handwritten `.h` headers.

**Tech stack:** Maven, hawtjni-maven-plugin, maven-antrun-plugin, libtool, autoconf.

**Spec:** `/Volumes/VAULTROOM/labs/forks/netty-static-jni/specs/2026-04-28-netty-static-jar-variants-design.md`.

**Working directory for all commands:** `/Volumes/VAULTROOM/labs/forks/netty/`.

---

## File map

| File | Change |
|---|---|
| `pom.xml` (netty-parent) | Add `skipStaticJar=true` (default), `staticLib.classifier`, `staticLib.includeDir` to `<properties>`; add `static-jar` antrun execution under `<build><pluginManagement>` with `<skip>${skipStaticJar}</skip>`. |
| `transport-native-epoll/pom.xml` | Per profile (`linux`, `linux-aarch64`, `linux-riscv64`): `--enable-static --with-pic` to configureArgs, set `staticLib.libname` and `skipStaticJar=false` in profile `<properties>`. |
| `transport-native-kqueue/pom.xml` | Per profile (`mac`, `mac-m1-cross-compile`, `mac-intel-cross-compile`): same shape. |
| `transport-native-io_uring/pom.xml` | Module-level `staticLib.libname=${jniLibName}`. Per profile (`linux`, `linux-aarch64`, `linux-riscv64`): `--enable-static --with-pic` and `skipStaticJar=false`. |
| `codec-native-quic/pom.xml` | Module-level `staticLib.libname=${jniLibName}`. Per Linux/macOS profile (`linux`, `linux-aarch64`, `mac`, `mac-m1-cross-compile`, `mac-intel-cross-compile`): `skipStaticJar=false` in `<properties>`. Add `--enable-static --with-pic` once to the main hawtjni execution's `<configureArgs>` (around line 1133, in the top-level `<build><plugins>`, used by all non-android profiles). **Defer**: `windows` profile (cmake/msbuild) and `android-*` profiles (per-ABI build dir collides with the parent antrun's path assumption). |
| `resolver-dns-native-macos/pom.xml` | Per profile (`mac`, `mac-m1-cross-compile`, `mac-intel-cross-compile`): `--enable-static --with-pic`, set `staticLib.libname` and `skipStaticJar=false`. |

**Out of scope for this plan:** the `windows` profile of `codec-native-quic` uses cmake + msbuild rather than autoconf/libtool, so `--enable-static` does not apply. Producing a windows static archive needs a separate mechanism and is deferred to a follow-up. The plan does not touch the windows profile.

No new files. No changes to Java sources, native sources, or any test files.

---

## Task 1 — Empirical gate: confirm `--enable-static` produces a `.a`

This task validates the central assumption that lets the rest of the plan work. If it fails, stop the plan and switch the spec to the `transport-native-unix-common`-style fallback.

The validation runs against whichever module/profile pair the dev host can natively build. Both choices below validate the same assumption (libtool emits `.a` when `--enable-static` is passed at configure time, despite the `disable-static` default in hawtjni's generated `configure.ac`):

- **macOS host:** target `transport-native-kqueue` + the `mac` profile.
- **Linux host:** target `transport-native-epoll` + the `linux` profile.

Pick the one matching the dev host. The instructions below show the kqueue+mac path; for epoll+linux substitute the obvious analogues (`transport-native-epoll`, profile `linux`, lib name `netty_transport_native_epoll_<arch>`, classifier `linux-x86_64`).

**Files:**
- Modify: `transport-native-kqueue/pom.xml` (only the `mac` profile's hawtjni `<configureArgs>`) — or `transport-native-epoll/pom.xml`'s `linux` profile if on Linux.

- [ ] **Step 1: Confirm baseline — no `.a` exists today.**

```bash
rm -rf transport-native-kqueue/target/native-build
mvn -Pmac package -pl transport-native-kqueue -am -DskipTests -q
ls transport-native-kqueue/target/native-build/.libs/*.a 2>&1 | head -5
```

Expected: `ls: ...: No such file or directory`. (If a `.a` already exists, the assumption is already validated; proceed anyway.)

- [ ] **Step 2: Add `--enable-static --with-pic` to the `mac` profile's hawtjni configureArgs.**

In `transport-native-kqueue/pom.xml`, find the `mac` profile (search `<id>mac</id>`) → its `<configureArgs>` block. Append two args; the resulting block should look like:

```xml
                  <configureArgs>
                    <arg>${jni.compiler.args.ldflags}</arg>
                    <arg>${jni.compiler.args.libs}</arg>
                    <arg>${jni.compiler.args.cflags}</arg>
                    <configureArg>--libdir=${project.build.directory}/native-build/target/lib</configureArg>
                    <configureArg>--enable-static</configureArg>
                    <configureArg>--with-pic</configureArg>
                  </configureArgs>
```

(The pre-existing args may differ slightly from this exact ordering; match the existing block, just append the two new lines before `</configureArgs>`.)

- [ ] **Step 3: Rebuild and verify the static archive exists.**

```bash
rm -rf transport-native-kqueue/target
mvn -Pmac package -pl transport-native-kqueue -am -DskipTests -q
ls -l transport-native-kqueue/target/native-build/.libs/lib*.a
```

Expected: a line printing `libnetty_transport_native_kqueue_<arch>.a` (where `<arch>` is `aarch_64` on Apple Silicon, `x86_64` on Intel).

If the `.a` is absent: STOP. The configure-arg approach is not viable on this hawtjni version. Revert this commit, revise the spec to use the per-module antrun + Makefile fallback (mirroring `transport-native-unix-common`), and write a new plan. Do not proceed past this step.

If the `.a` is present: continue.

- [ ] **Step 4: Commit.**

```bash
git add transport-native-kqueue/pom.xml
git commit -m "Kqueue: Enable static archive in mac build"
```

---

## Task 2 — Parent extraction: add `static-jar` to `netty-parent`

**Files:**
- Modify: `pom.xml` (root, `netty-parent`)

- [ ] **Step 1: Add three default properties to `netty-parent`'s `<properties>`.**

In `pom.xml` (root), find the existing top-level `<properties>` block (around line 707). Add these three entries inside the block (placement: at the bottom of the block, just before `</properties>`):

```xml
    <skipStaticJar>true</skipStaticJar>
    <staticLib.classifier>${jni.classifier}-static</staticLib.classifier>
    <staticLib.includeDir>${nativeSourceDirectory}</staticLib.includeDir>
```

`skipStaticJar=true` is the default, which makes the `static-jar` execution (added in Step 2) a no-op for every module. In-scope modules opt in by overriding `skipStaticJar=false` in their profile properties (Tasks 3–7).

`staticLib.libname` is intentionally not given a default — modules that opt in must set it.

- [ ] **Step 2: Add the `static-jar` execution under `<build><pluginManagement><plugins>`.**

In the same `pom.xml`, locate `<build><pluginManagement>` (around line 1846) → its `<plugins>` block. Append a new `<plugin>` entry. Use the exact XML below verbatim (match the surrounding 8-space indent for `<plugin>`):

```xml
        <plugin>
          <artifactId>maven-antrun-plugin</artifactId>
          <executions>
            <execution>
              <id>static-jar</id>
              <phase>package</phase>
              <goals><goal>run</goal></goals>
              <configuration>
                <skip>${skipStaticJar}</skip>
                <target>
                  <fail message="Expected static archive missing: ${project.build.directory}/native-build/.libs/lib${staticLib.libname}.a">
                    <condition><not><available file="${project.build.directory}/native-build/.libs/lib${staticLib.libname}.a" /></not></condition>
                  </fail>
                  <mkdir dir="${project.build.directory}/static-jar-work/META-INF/native/lib" />
                  <mkdir dir="${project.build.directory}/static-jar-work/META-INF/native/include" />
                  <copy file="${project.build.directory}/native-build/.libs/lib${staticLib.libname}.a"
                        todir="${project.build.directory}/static-jar-work/META-INF/native/lib" />
                  <copy todir="${project.build.directory}/static-jar-work/META-INF/native/include" failonerror="false">
                    <fileset dir="${staticLib.includeDir}" includes="*.h" />
                  </copy>
                  <jar destfile="${project.build.directory}/${project.build.finalName}-${staticLib.classifier}.jar"
                       basedir="${project.build.directory}/static-jar-work">
                    <manifest>
                      <attribute name="Implementation-Title" value="${project.artifactId}" />
                      <attribute name="Implementation-Version" value="${project.version}" />
                    </manifest>
                  </jar>
                  <attachartifact file="${project.build.directory}/${project.build.finalName}-${staticLib.classifier}.jar"
                                  classifier="${staticLib.classifier}"
                                  type="jar" />
                </target>
              </configuration>
            </execution>
          </executions>
        </plugin>
```

- [ ] **Step 3: Verify the parent change is inert (skip=true is honored everywhere).**

Pick one module that already builds locally (kqueue on Mac) and run a package without opting in:

```bash
cd transport-native-kqueue
mvn -Pmac package -DskipTests -q
cd ..
ls transport-native-kqueue/target/*.jar
```

Expected: BUILD SUCCESS. The shared-lib classifier JAR (`*-osx-aarch_64.jar`) is produced. **No `*-osx-aarch_64-static.jar` is produced** (because `skipStaticJar=true` by default — kqueue hasn't opted in yet; that's Task 4). If the static JAR appears here, the skip gate isn't working — STOP and report so we can revise the design.

- [ ] **Step 4: Commit.**

```bash
git add pom.xml
git commit -m "Build: Add static-jar antrun execution to parent pluginManagement"
```

---

## Task 3 — Wire `transport-native-epoll`

**Files:**
- Modify: `transport-native-epoll/pom.xml`

Three platform profiles to wire: `linux`, `linux-aarch64`, `linux-riscv64`. Note: Task 1 added `--enable-static --with-pic` to **kqueue's** `mac` profile (not epoll's `linux`); epoll has not been touched yet.

- [ ] **Step 1: Add `--enable-static --with-pic` to all three profiles' hawtjni `<configureArgs>`.**

For each of `linux`, `linux-aarch64`, `linux-riscv64`, append two args to the existing `<configureArgs>` block:

```xml
                    <configureArg>--enable-static</configureArg>
                    <configureArg>--with-pic</configureArg>
```

- [ ] **Step 2: Set `staticLib.libname` and `skipStaticJar=false` in each profile's `<properties>` block.**

Each profile already has its own `<properties>` block (next to `<id>`/`<activation>`). Add two lines per profile.

In `linux`:
```xml
        <staticLib.libname>netty_transport_native_epoll_${os.detected.arch}</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

In `linux-aarch64`:
```xml
        <staticLib.libname>netty_transport_native_epoll_aarch_64</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

In `linux-riscv64`:
```xml
        <staticLib.libname>netty_transport_native_epoll_riscv64</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

(If the `<name>` element in any profile's hawtjni config differs from the literal above, copy that value verbatim instead. Search `<name>netty_transport_native_epoll_` in the pom to verify.)

- [ ] **Step 3: Validate the pom is well-formed.**

```bash
cd transport-native-epoll
mvn validate -q
cd ..
```

Expected: BUILD SUCCESS. (No native compilation runs at the `validate` phase; this just exercises Maven's pom parser and effective-pom resolution to catch malformed XML or property typos.)

Native build verification on linux is deferred to Task 8 (or to the user's Linux runner / Docker). Mac hosts cannot natively build epoll's linux profile; we accept that and trust the parent extraction works the same way for epoll as it does for kqueue.

- [ ] **Step 4: Commit.**

```bash
git add transport-native-epoll/pom.xml
git commit -m "Epoll: Produce <classifier>-static JAR with libtool .a"
```

---

## Task 4 — Wire `transport-native-kqueue`

**Files:**
- Modify: `transport-native-kqueue/pom.xml`

Five native-build profiles: `mac`, `mac-m1-cross-compile`, `mac-intel-cross-compile`, `openbsd`, `freebsd`. The `Linux` and `Windows` profiles in this pom are skip-tests-only (no native build), so they are NOT touched.

Note: Task 1 already added `--enable-static --with-pic` to the `mac` profile's hawtjni `<configureArgs>`. For `mac` we only need to add the two `<properties>`. The other four profiles need both the configureArgs and the properties.

- [ ] **Step 1: Add `--enable-static --with-pic` to the four profiles that don't yet have them.**

For each of `mac-m1-cross-compile`, `mac-intel-cross-compile`, `openbsd`, `freebsd`, append to the existing `<configureArgs>` block (preserve all existing args):

```xml
                    <configureArg>--enable-static</configureArg>
                    <configureArg>--with-pic</configureArg>
```

Do NOT touch the `mac` profile's `<configureArgs>` — Task 1 already added these two args.

- [ ] **Step 2: Set `staticLib.libname` and `skipStaticJar=false` in each profile's `<properties>` block.**

For all five profiles. The values match each profile's hawtjni `<name>` exactly:

In `mac`:
```xml
        <staticLib.libname>netty_transport_native_kqueue_${os.detected.arch}</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

In `mac-m1-cross-compile`:
```xml
        <staticLib.libname>netty_transport_native_kqueue_aarch_64</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

In `mac-intel-cross-compile`:
```xml
        <staticLib.libname>netty_transport_native_kqueue_x86_64</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

In `openbsd`:
```xml
        <staticLib.libname>netty_transport_native_kqueue_${os.detected.arch}</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

In `freebsd`:
```xml
        <staticLib.libname>netty_transport_native_kqueue_${os.detected.arch}</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

If a profile lacks a `<properties>` block today, add one (place it after `<activation>` and before `<build>`).

- [ ] **Step 3: Build and verify on macOS.**

```bash
cd transport-native-kqueue
rm -rf target
mvn -Pmac package -DskipTests -q
cd ..
ls transport-native-kqueue/target/*.jar
unzip -l transport-native-kqueue/target/netty-transport-native-kqueue-4.2.12.Final-osx-aarch_64-static.jar | head -20
```

(Substitute `osx-x86_64-static` if you are on Intel.)

Expected:
- Both `…-osx-aarch_64.jar` (existing shared-lib classifier) and `…-osx-aarch_64-static.jar` (new) exist.
- The `-static` JAR contains `META-INF/native/lib/libnetty_transport_native_kqueue_aarch_64.a` and `META-INF/native/include/*.h`.

If the `-static` JAR does not appear or the `<fail>` in the antrun fires: STOP and report BLOCKED.

`openbsd` and `freebsd` profiles cannot be natively built on macOS; their verification is deferred to a CI runner / appropriate VM.

- [ ] **Step 4: Commit.**

```bash
git add transport-native-kqueue/pom.xml
git commit -m "Kqueue: Produce <classifier>-static JAR with libtool .a"
```

---

## Task 5 — Wire `transport-native-io_uring`

**Files:**
- Modify: `transport-native-io_uring/pom.xml`

io_uring's structure differs from epoll/kqueue: only the `linux` profile declares the hawtjni execution. The `linux-aarch64` and `linux-riscv64` profiles are activated *alongside* `linux` and only override property values (`jniArch`, `extraConfigureArg`, etc.) which flow into `linux`'s hawtjni configureArgs at evaluation time. So the wiring concentrates in the `linux` profile (plus one module-level property).

io_uring already defines `<jniLibName>netty_transport_native_io_uring42_${jniArch}</jniLibName>` at module level (line 44).

- [ ] **Step 1: Add `staticLib.libname` to module-level `<properties>`.**

In the top-level `<properties>` block (above `<profiles>`, around line 39–46), add:

```xml
    <staticLib.libname>${jniLibName}</staticLib.libname>
```

This propagates to every profile via property inheritance and resolves to the right per-arch name (because `${jniArch}` is profile-overridden).

- [ ] **Step 2: Add `--enable-static --with-pic` to the `linux` profile's hawtjni `<configureArgs>`.**

Find `<id>linux</id>` → its `<configureArgs>` block (around line 125–131). Append two new args before `</configureArgs>`:

```xml
                    <configureArg>--enable-static</configureArg>
                    <configureArg>--with-pic</configureArg>
```

Do not touch `linux-aarch64` or `linux-riscv64` configureArgs — they don't have any.

- [ ] **Step 3: Set `skipStaticJar=false` in the `linux` profile's `<properties>` block.**

The `linux` profile already has a `<properties>` block (with `<skipTests>false</skipTests>` etc., around line 65–68). Append:

```xml
        <skipStaticJar>false</skipStaticJar>
```

The cross-compile profiles (`linux-aarch64`, `linux-riscv64`) inherit this from `linux` since they activate alongside it. No need to set it there.

- [ ] **Step 4: Validate the pom is well-formed.**

```bash
cd transport-native-io_uring
mvn validate -q
cd ..
```

Expected: BUILD SUCCESS.

Native build verification on Linux is deferred to Task 8 / user's Docker. Mac hosts cannot natively build io_uring.

- [ ] **Step 5: Commit.**

```bash
git add transport-native-io_uring/pom.xml
git commit -m "IoUring: Produce <classifier>-static JAR with libtool .a"
```

---

## Task 6 — Wire `codec-native-quic`

**Files:**
- Modify: `codec-native-quic/pom.xml`

codec-native-quic defines `<jniLibName>${jniLibPrefix}_${os.detected.name}_${os.detected.arch}</jniLibName>` at module level (`jniLibPrefix=netty_quiche42`). Linux and macOS profiles share a single hawtjni execution declared in the top-level `<build><plugins>` (around line 1118), so `--enable-static --with-pic` lands there once. Per-profile cross-compile overrides set `<jniLibName>` directly.

**In scope:** `linux`, `linux-aarch64`, `mac`, `mac-m1-cross-compile`, `mac-intel-cross-compile`.

**Deferred (out of scope for this task):**
- `windows` profile uses cmake + msbuild; `--enable-static` does not apply.
- `android-*` profiles use a per-ABI hawtjniBuildDir (`target/native-build/${androidAbi}/`) and override `jniLibName` to a single bare `netty_quiche` shared across ABIs. The parent antrun's path assumption (`target/native-build/.libs/lib<name>.a`, single per Maven build) doesn't fit; multi-ABI builds would also collide on the same `${jni.classifier}-static` JAR. Needs a separate design.

Leave `windows` and all `android*` profiles untouched.

- [ ] **Step 1: Add `staticLib.libname` to module-level `<properties>`.**

In the top-level `<properties>` block (the one containing `jniLibPrefix` and `jniLibName`, around line 32–46), append:

```xml
    <staticLib.libname>${jniLibName}</staticLib.libname>
```

- [ ] **Step 2: Add `--enable-static --with-pic` to the main (non-profile) hawtjni execution's `<configureArgs>`.**

Find the `<plugin><groupId>org.fusesource.hawtjni</groupId>` block in the top-level `<build><plugins>` (around line 1118 — the one whose `<configureArgs>` already contains `${extraConfigureArg}`, `${extraConfigureArg2}`, and `--libdir=...`). Append two args before `</configureArgs>`, matching the existing 16-space indent:

```xml
                <configureArg>--enable-static</configureArg>
                <configureArg>--with-pic</configureArg>
```

This covers all five Linux/macOS profiles since they all use the main hawtjni execution.

- [ ] **Step 3: Set `skipStaticJar=false` in each in-scope profile's `<properties>` block.**

For each of `linux`, `linux-aarch64`, `mac`, `mac-m1-cross-compile`, `mac-intel-cross-compile`, append to its `<properties>` block (each profile already has one):

```xml
        <skipStaticJar>false</skipStaticJar>
```

Do NOT touch `windows`, `oss-fuzz`, `android-armeabi-v7a`, `android-arm64-v8a`, `android-x86`, `android-x86_64`, `android`, `leak`, `noUnsafe`, `native-image-agent`.

- [ ] **Step 4: Build and verify on macOS.**

```bash
cd codec-native-quic
rm -rf target
mvn -Pmac package -DskipTests -q
cd ..
ls codec-native-quic/target/*.jar
unzip -l codec-native-quic/target/netty-codec-native-quic-4.2.12.Final-osx-aarch_64-static.jar | head -30
```

(Substitute `osx-x86_64-static` if Intel.)

Expected: both classifier JARs; the `-static` JAR contains `META-INF/native/lib/libnetty_quiche42_osx_<arch>.a` plus headers. Note the static JAR will be substantially larger than other modules — BoringSSL + quiche statically archived can be tens of MB.

Linux verification deferred to Task 8 / user's Docker.

- [ ] **Step 5: Commit.**

```bash
git add codec-native-quic/pom.xml
git commit -m "Quic: Produce <classifier>-static JAR with libtool .a"
```

---

## Task 7 — Wire `resolver-dns-native-macos`

**Files:**
- Modify: `resolver-dns-native-macos/pom.xml`

Three profiles: `mac`, `mac-m1-cross-compile`, `mac-intel-cross-compile`. The hawtjni `<name>` is hardcoded per profile (no `${jniLibName}`), so we set `staticLib.libname` per profile.

- [ ] **Step 1: Add `--enable-static --with-pic` to each profile's hawtjni `<configureArgs>`.**

Append to the existing block in each of the three profiles:

```xml
                    <configureArg>--enable-static</configureArg>
                    <configureArg>--with-pic</configureArg>
```

- [ ] **Step 2: Set `staticLib.libname` and `skipStaticJar=false` in each profile's `<properties>` block.**

In `mac`:
```xml
        <staticLib.libname>netty_resolver_dns_native_macos_${os.detected.arch}</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

In `mac-m1-cross-compile`:
```xml
        <staticLib.libname>netty_resolver_dns_native_macos_aarch_64</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

In `mac-intel-cross-compile`:
```xml
        <staticLib.libname>netty_resolver_dns_native_macos_x86_64</staticLib.libname>
        <skipStaticJar>false</skipStaticJar>
```

If a profile lacks a `<properties>` block, add one (after `<activation>`, before `<build>`).

- [ ] **Step 3: Build and verify natively on macOS.**

```bash
cd resolver-dns-native-macos
rm -rf target
mvn -Pmac package -DskipTests -q
cd ..
ls resolver-dns-native-macos/target/*.jar
unzip -l resolver-dns-native-macos/target/netty-resolver-dns-native-macos-4.2.12.Final-osx-aarch_64-static.jar
```

(Substitute `osx-x86_64-static` if Intel.) Expected: both classifier JARs; the `-static` JAR contains `META-INF/native/lib/libnetty_resolver_dns_native_macos_<arch>.a` and headers.

- [ ] **Step 4: Commit.**

```bash
git add resolver-dns-native-macos/pom.xml
git commit -m "Resolver/DNS: Produce <classifier>-static JAR with libtool .a"
```

---

## Task 8 — End-to-end verification

No file changes. This task confirms shared-lib JARs are unaffected and all `-static` JARs landed correctly.

- [ ] **Step 1: Confirm shared-lib classifier JARs still contain a `.so`/`.dylib`/`.jnilib`.**

For every shared-lib classifier JAR you produced in Tasks 3–7, list its native-lib entries. The simplest way is to glob for non-static jars:

```bash
for jar in $(ls transport-native-*/target/*.jar codec-native-quic/target/*.jar resolver-dns-native-macos/target/*.jar 2>/dev/null | grep -v -- '-static\.jar$'); do
  echo "== $jar =="
  unzip -l "$jar" | grep -E '\.(so|dylib|jnilib)$' || echo "  (no native lib found — investigate)"
done
```

Expected: each shared-lib classifier JAR prints exactly one matching line. Any "no native lib found" line is a regression — investigate before continuing.

- [ ] **Step 2: Confirm `-static` classifier JARs contain a `.a` and headers.**

```bash
for jar in transport-native-{epoll,kqueue,io_uring}/target/*-static.jar codec-native-quic/target/*-static.jar resolver-dns-native-macos/target/*-static.jar; do
  [ -f "$jar" ] && echo "== $jar ==" && unzip -l "$jar" | grep -E 'META-INF/native/(lib|include)/'
done
```

Expected: each `-static` JAR prints at least one `META-INF/native/lib/lib*.a` line and one or more `META-INF/native/include/*.h` lines.

- [ ] **Step 3: Run one module's existing test suite to catch any inadvertent regression.**

```bash
mvn test -Plinux -pl transport-native-epoll -am -q   # or -Pmac for kqueue, etc.
```

Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 4: Sanity-check `nm` symbols on one `.a` (optional, local only — not part of CI).**

```bash
ar x transport-native-epoll/target/native-build/.libs/libnetty_transport_native_epoll_x86_64.a -o /tmp/aextract && \
  nm -g /tmp/aextract/*.o | grep -E ' T Java_io_netty_' | head -5
```

Expected: at least a few `T Java_io_netty_channel_epoll_*` symbols. (If 0, the static archive may be missing exported JNI bindings — investigate before relying on it for Static JNI.)

No commit on this task.

---

## Out-of-tree follow-ups (not part of this plan)

After this plan lands and the netty fork builds clean across all platform CI:

1. **`netty-tcnative` mirror.** Apply the same shape to the sibling repo at `/Volumes/VAULTROOM/labs/forks/netty-tcnative/`, per the spec's tcnative coordination appendix. Same classifier scheme, same JAR layout, same `--enable-static --with-pic` approach. Separate plan.

2. **`codec-native-quic` windows-x86_64 static archive.** Requires a cmake/msbuild-side change (`-DBUILD_SHARED_LIBS=OFF` for boringssl/quiche; emit a `.lib` for the netty wrapper itself; package as `windows-x86_64-static`). Separate plan.

3. **Pre-release publishing check.** On the first snapshot deployment after this lands, verify the staged Maven repo contains `-static` classifier artifacts for every existing classifier of every in-scope module.
