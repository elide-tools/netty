# Netty-tcnative Static JAR Variants Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Mirror the netty-side static-archive classifier work in `netty-tcnative`. Each existing classifier JAR (e.g. `linux-x86_64`, `osx-aarch_64`) gains a parallel `<classifier>-static` JAR containing `libnetty_tcnative.a` plus the module's handwritten `.h` headers.

**Architecture:** Same pattern as netty. Add a parameterised `static-jar` antrun execution to `tcnative-parent`'s `<pluginManagement>` (gated by `skipStaticJar=true` default). Each native module flips `skipStaticJar=false` at module level, sets `staticLib.libname=netty_tcnative` (constant across all profiles since tcnative uses one lib name), and appends `--enable-static --with-pic` to every autoconf-driven hawtjni `<configureArgs>` block.

**Tech stack:** Maven, hawtjni-maven-plugin, maven-antrun-plugin, libtool, autoconf.

**Spec:** `/Volumes/VAULTROOM/labs/forks/netty-static-jni/specs/2026-04-28-netty-tcnative-static-jar-variants-design.md`.

**Working directory:** `/Volumes/VAULTROOM/labs/forks/netty-tcnative/`.

---

## File map

| File | Change |
|---|---|
| `pom.xml` (tcnative-parent) | Add `skipStaticJar=true`, `staticLib.classifier=${os.detected.classifier}-static`, `staticLib.includeDir=${nativeSourceDirectory}` to `<properties>`; add `static-jar` antrun execution to existing `maven-antrun-plugin` entry under `<build><pluginManagement>`. |
| `openssl-dynamic/pom.xml` | Module-level `staticLib.libname=netty_tcnative` and `skipStaticJar=false`. `--enable-static --with-pic` added to 4 `<configureArgs>` blocks (default + `mac-x86_64` + `mac-aarch64` + `linux-aarch64`). |
| `boringssl-static/pom.xml` | Module-level `staticLib.libname=netty_tcnative` and `skipStaticJar=false`. `--enable-static --with-pic` added to 5 `<configureArgs>` blocks (`fips-boringssl-static` + `boringssl-static-default` + `linux-aarch64` + `mac-m1-cross-compile` + `mac-intel-cross-compile`). |
| `openssl-static/pom.xml` | Module-level `staticLib.libname=netty_tcnative` and `skipStaticJar=false`. `--enable-static --with-pic` added to the single `<configureArgs>` block. |
| `libressl-static/pom.xml` | Module-level `staticLib.libname=netty_tcnative` and `skipStaticJar=false`. `--enable-static --with-pic` added to the single `<configureArgs>` block. |

**Out of scope:** any module/profile combination that drives the netty wrapper through `nmake`/MSVC instead of autoconf+libtool (likely the windows variants of `openssl-static` and `libressl-static`). Verify at implementation time; skip those wirings — defer to a separate plan for windows tcnative static archives.

---

## Task T1 — Empirical gate: validate `--enable-static` produces `.a`

Pick a Mac-buildable target with the lightest dependencies. `openssl-dynamic` + `mac-aarch64` is the right gate: links system OpenSSL/APR (no cmake-driven SSL build), so the autoconf+libtool path is exercised in isolation. If this works, the same flag works for the heavier modules (`boringssl-static`, etc.).

**Files:** `openssl-dynamic/pom.xml` only.

- [ ] **Step 1: Confirm `mac-aarch64` profile builds today (baseline).**

```bash
cd openssl-dynamic
rm -rf target/native-build
../mvnw -Pmac-aarch64 package -DskipTests -q
ls target/native-build/.libs/*.{a,dylib,jnilib} 2>&1 | head -5
cd ..
```

Expected: a `.dylib` or `.jnilib` exists, but no `.a` (we haven't enabled static yet). If the build itself fails, you may need `brew install apr openssl@3` first — see tcnative README. Resolve any tool-chain issues before continuing.

- [ ] **Step 2: Add `--enable-static --with-pic` to the `mac-aarch64` profile's hawtjni `<configureArgs>` (around line 306).**

Find `<id>mac-aarch64</id>` in `openssl-dynamic/pom.xml`, then its hawtjni execution's `<configureArgs>`. Append two lines before `</configureArgs>` matching surrounding indent (~20 spaces):

```xml
                    <configureArg>--enable-static</configureArg>
                    <configureArg>--with-pic</configureArg>
```

- [ ] **Step 3: Rebuild and verify the `.a` is produced.**

```bash
cd openssl-dynamic
rm -rf target
../mvnw -Pmac-aarch64 package -DskipTests -q
ls -l target/native-build/.libs/libnetty_tcnative.a
cd ..
```

Expected: a single line printing `target/native-build/.libs/libnetty_tcnative.a` (non-empty). If the file is absent: STOP; the configure-arg approach may not work for tcnative. Report BLOCKED.

- [ ] **Step 4: Commit.**

```bash
git add openssl-dynamic/pom.xml
git commit -m "OpenSSL: Enable static archive in mac-aarch64 build"
```

(Match tcnative's commit-message style: capitalized prefix per module, terse subject. No body, no trailers.)

---

## Task T2 — Parent extraction: add `static-jar` to tcnative-parent

**Files:** `pom.xml` (root, tcnative-parent).

- [ ] **Step 1: Add three default properties to top-level `<properties>` block.**

Find the `<properties>` block (around line 90–135). Append:

```xml
    <skipStaticJar>true</skipStaticJar>
    <staticLib.classifier>${os.detected.classifier}-static</staticLib.classifier>
    <staticLib.includeDir>${nativeSourceDirectory}</staticLib.includeDir>
```

(`${nativeSourceDirectory}` resolves at child-pom time. tcnative modules already define this — verify by searching for it across modules; if any module doesn't, that module needs to set it locally.)

- [ ] **Step 2: Add the `static-jar` execution to the existing `maven-antrun-plugin` entry under `<build><pluginManagement>`.**

Find the `<plugin><artifactId>maven-antrun-plugin</artifactId>` block under pluginManagement (around line 195–225 — has `<version>1.8</version>` and `<dependencies>` for ant-contrib). Inside that `<plugin>` block, add an `<executions>` element after `</dependencies>` and before `</plugin>`:

```xml
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
```

- [ ] **Step 3: Verify the parent change is inert until a module opts in.**

```bash
cd openssl-classes  # any module that doesn't opt in; openssl-classes is Java-only
../mvnw validate -q
cd ..
```

Expected: BUILD SUCCESS. The execution is in pluginManagement and `skipStaticJar=true` by default, so no module triggers it yet.

Then build openssl-dynamic mac-aarch64 again — should still produce only the existing classifier JAR (no `*-static.jar`), since module hasn't opted in yet:

```bash
cd openssl-dynamic
rm -rf target
../mvnw -Pmac-aarch64 package -DskipTests -q
ls target/*.jar
cd ..
```

Expected: only the existing classifier JARs. No `*-osx-aarch_64-static.jar` yet.

- [ ] **Step 4: Commit.**

```bash
git add pom.xml
git commit -m "Build: Add static-jar antrun execution to parent pluginManagement"
```

---

## Task T3 — Wire `openssl-dynamic`

**Files:** `openssl-dynamic/pom.xml`.

- [ ] **Step 1: Add module-level properties.**

In the top-level `<properties>` block (around line 33–~50), append:

```xml
    <staticLib.libname>netty_tcnative</staticLib.libname>
    <skipStaticJar>false</skipStaticJar>
```

(`netty_tcnative` matches the hawtjni `<name>` value used in every configureArgs block in this pom.)

- [ ] **Step 2: Add `--enable-static --with-pic` to the three remaining `<configureArgs>` blocks.**

Task T1 already added them to `mac-aarch64` (around line 306). Now append the same two lines to:

- The default `<build>` config (around line 142).
- `<id>mac-x86_64</id>` (around line 267).
- `<id>linux-aarch64</id>` (around line 418).

Same XML, same indent:

```xml
                <configureArg>--enable-static</configureArg>
                <configureArg>--with-pic</configureArg>
```

(Adjust leading whitespace per block — the default block is shallower than the per-profile ones.)

- [ ] **Step 3: Build and verify on mac-aarch64.**

```bash
cd openssl-dynamic
rm -rf target
../mvnw -Pmac-aarch64 clean package -DskipTests -q
ls target/*.jar
unzip -l target/*-osx-aarch_64-static.jar
cd ..
```

Expected: both `…-osx-aarch_64.jar` and `…-osx-aarch_64-static.jar` exist. The `-static` jar contains `META-INF/native/lib/libnetty_tcnative.a` and `META-INF/native/include/*.h`.

If the static jar is absent or `<fail>` fires, STOP and report BLOCKED.

Linux + mac-x86_64 verification deferred to T7 / user's runners.

- [ ] **Step 4: Commit.**

```bash
git add openssl-dynamic/pom.xml
git commit -m "OpenSSL: Produce <classifier>-static JAR with libtool .a"
```

---

## Task T4 — Wire `boringssl-static`

**Files:** `boringssl-static/pom.xml`.

- [ ] **Step 1: Add module-level properties.**

In the top-level `<properties>` block (around line ~40), append:

```xml
    <staticLib.libname>netty_tcnative</staticLib.libname>
    <skipStaticJar>false</skipStaticJar>
```

- [ ] **Step 2: Add `--enable-static --with-pic` to all five `<configureArgs>` blocks.**

The blocks live at lines 374, 682, 1013, 1435, 1683 (verify with `grep -n "<configureArgs>" boringssl-static/pom.xml`). They sit inside profiles `fips-boringssl-static`, `boringssl-static-default`, `linux-aarch64`, `mac-m1-cross-compile`, `mac-intel-cross-compile` respectively. Append the same two `<configureArg>` lines to each. (Skip any block inside the `boringssl-static-asan` profile — that's a developer-debugging profile, not a release classifier.)

- [ ] **Step 3: Build and verify on mac-aarch64 (boringssl-static-default flavor).**

The boringssl-static module has a long build (BoringSSL cmake build), expect ~5–15 min:

```bash
cd boringssl-static
rm -rf target
../mvnw -Pboringssl-static-default clean package -DskipTests -q
ls target/*.jar
unzip -l target/*-osx-aarch_64-static.jar
cd ..
```

Expected: both classifier JARs; the `-static` JAR contains `META-INF/native/lib/libnetty_tcnative.a` (only the JNI wrapper objects — not the full BoringSSL static archive, which lives elsewhere).

- [ ] **Step 4: Commit.**

```bash
git add boringssl-static/pom.xml
git commit -m "BoringSSL: Produce <classifier>-static JAR with libtool .a"
```

---

## Task T5 — Wire `openssl-static`

**Files:** `openssl-static/pom.xml`.

- [ ] **Step 1: Add module-level properties.**

```xml
    <staticLib.libname>netty_tcnative</staticLib.libname>
    <skipStaticJar>false</skipStaticJar>
```

- [ ] **Step 2: Verify the windows path and decide scope.**

Read the `build-openssl-windows` profile (around line 236). If it drives the netty wrapper through nmake/MSVC (no autoconf), do NOT modify any windows-only configureArgs. The single `<configureArgs>` block at line 181 is the autoconf/libtool one used by linux + mac.

- [ ] **Step 3: Add `--enable-static --with-pic` to the single `<configureArgs>` block (around line 181).**

```xml
                <configureArg>--enable-static</configureArg>
                <configureArg>--with-pic</configureArg>
```

- [ ] **Step 4: Build and verify on Mac (with `brew install openssl@3 apr` prerequisites).**

```bash
cd openssl-static
rm -rf target
../mvnw -Pbuild-openssl-mac clean package -DskipTests -q
ls target/*.jar
unzip -l target/*-osx-aarch_64-static.jar
cd ..
```

If the `build-openssl-mac` profile fails due to missing prerequisites, document the requirement and skip local verification — it'll be picked up by Linux/CI runners.

- [ ] **Step 5: Commit.**

```bash
git add openssl-static/pom.xml
git commit -m "OpenSSL/Static: Produce <classifier>-static JAR with libtool .a"
```

---

## Task T6 — Wire `libressl-static`

**Files:** `libressl-static/pom.xml`.

- [ ] **Step 1: Add module-level properties.**

```xml
    <staticLib.libname>netty_tcnative</staticLib.libname>
    <skipStaticJar>false</skipStaticJar>
```

- [ ] **Step 2: Verify the windows path and decide scope.**

Read the `build-libressl-windows` profile (around line 242). If MSVC-only, skip its configureArgs.

- [ ] **Step 3: Add `--enable-static --with-pic` to the single `<configureArgs>` block (around line 184).**

```xml
                <configureArg>--enable-static</configureArg>
                <configureArg>--with-pic</configureArg>
```

- [ ] **Step 4: Build and verify on Mac (build-libressl-non-windows profile).**

```bash
cd libressl-static
rm -rf target
../mvnw -Pbuild-libressl-non-windows clean package -DskipTests -q
ls target/*.jar
unzip -l target/*-osx-aarch_64-static.jar
cd ..
```

- [ ] **Step 5: Commit.**

```bash
git add libressl-static/pom.xml
git commit -m "LibreSSL: Produce <classifier>-static JAR with libtool .a"
```

---

## Task T7 — End-to-end verification

No file changes. Confirms the change set produces the expected JARs across modules.

- [ ] **Step 1: List all `-static` JARs produced locally.**

```bash
ls openssl-dynamic/target/*-static.jar boringssl-static/target/*-static.jar 2>/dev/null
ls openssl-static/target/*-static.jar 2>/dev/null   # may be absent if mac brew openssl wasn't installed
ls libressl-static/target/*-static.jar 2>/dev/null
```

Expected: each module's `target/` has one `*-osx-aarch_64-static.jar` if the module's mac profile was buildable on this host.

- [ ] **Step 2: Confirm shared-lib JARs unchanged in shape.**

```bash
for jar in $(ls */target/*.jar 2>/dev/null | grep -v -- '-static\.jar$' | grep -v sources | grep -v javadoc); do
  echo "== $jar ==" && unzip -l "$jar" | grep -E '\.(so|dylib|jnilib)$' | head -1
done
```

Expected: each shared-lib classifier JAR contains exactly one `.dylib`/`.jnilib`. None empty.

- [ ] **Step 3: Smoke-test one `.a` with `nm` (optional).**

```bash
ar x openssl-dynamic/target/native-build/.libs/libnetty_tcnative.a -o /tmp/tcaextract && \
  nm -g /tmp/tcaextract/*.o | grep -E ' T Java_io_netty' | head -5
```

Expected: at least a few `T Java_io_netty_internal_tcnative_*` symbols. Verifies the `.a` exports the JNI bindings as expected.

No commit on this task.

---

## Task T8 — Adapt staging script for tcnative

**Files:** `scripts/stage-natives-tcnative.sh` (new, in tcnative repo) AND a sibling at `/Volumes/VAULTROOM/labs/forks/netty-static-jni/scripts/stage-natives-tcnative.sh`.

- [ ] **Step 1: Write the script.**

Mirror `stage-natives.sh` but:
- `NETTY_DIR` → `TCNATIVE_DIR` (auto-detected from script location's parent).
- Module list per profile:
  - `mac-aarch64`/`mac-x86_64`/`mac-m1-cross-compile`/`mac-intel-cross-compile`: `openssl-dynamic`, `boringssl-static`, `openssl-static`, `libressl-static`.
  - `linux-aarch64`: same four.
  - `linux` (default, no `-P`): same four.
  - `windows`: deferred — script errors with "windows static archives not yet implemented for tcnative".
- For `boringssl-static`, the script needs a "flavor" decision: `boringssl-static-default` vs `fips-boringssl-static`. Pass as `-P` to the inner mvn. For now, default to `boringssl-static-default`.

- [ ] **Step 2: Place a copy in the tcnative repo and commit (TEMPORARY).**

```bash
cp /Volumes/VAULTROOM/labs/forks/netty-static-jni/scripts/stage-natives-tcnative.sh \
   /Volumes/VAULTROOM/labs/forks/netty-tcnative/scripts/stage-natives.sh
chmod +x /Volumes/VAULTROOM/labs/forks/netty-tcnative/scripts/stage-natives.sh
cd /Volumes/VAULTROOM/labs/forks/netty-tcnative
git add scripts/stage-natives.sh
git commit -m "TEMPORARY: Add scripts/stage-natives.sh helper"
```

- [ ] **Step 3: Smoke-test from the script.**

```bash
STAGE=/Volumes/VAULTROOM/labs/forks/tcnative-stage
/Volumes/VAULTROOM/labs/forks/netty-tcnative/scripts/stage-natives.sh \
  $STAGE mac-aarch64 --prep-deps
```

Expected: the script installs Java-only siblings (just `openssl-classes`), then deploys each native module's mac-aarch64 build to `$STAGE`.

---

## Out-of-tree follow-ups (not part of this plan)

1. **Windows tcnative static archives** — for any module/profile that drives the netty wrapper through nmake/MSVC instead of autoconf+libtool. Same shape as the netty quic windows follow-up.

2. **Pre-release publishing check** — verify the staged Maven repo contains `-static` classifier artifacts for every existing tcnative classifier before cutting a release.

3. **Fat archive option** — if a downstream consumer wants a single `libnetty_tcnative_full.a` that bundles BoringSSL/OpenSSL/LibreSSL, design that as a separate optional artifact. Out of scope here.
