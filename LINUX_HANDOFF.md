# Darwin_Computa — Linux Handoff: Recompiling Darling Frameworks to Close the Remaining Gaps

**Written:** 2026-07-01
**Purpose:** Everything a Linux machine needs to pick up where the macOS work stopped — build Darling from source, then patch/rebuild the specific frameworks whose bugs the macOS emulator work could *identify* but not *fix* (because Darling only builds on Linux).

**TL;DR:** The Darwin_Computa emulator (Darling-on-Boxedwine-on-macOS) is feature-complete for what a macOS host can produce — 4 real emulator fixes landed, full Foundation/objc-runtime/crypto/net/persistence/concurrency/GUI stack working. The remaining gaps live **inside prebuilt Cocotron/Darling frameworks** and can only be fixed by recompiling those frameworks, which **requires a 64-bit x86 Linux host** (Darling's hard requirement). This doc hands off those framework fixes with exact source locations.

---

## 0. Why this is a Linux job (the wall we hit on macOS)

Darling's official build docs (https://docs.darlinghq.org/build-instructions.html) state:

> **"You must be running a 64-bit x86 Linux distribution."**

Requirements: Linux 5.0+, Clang 11+, `cmake`, `bison`, `flex`, `xz-utils`, `libfuse-dev`, `libudev-dev`, `pkg-config`, `libc6-dev-i386`, ≥4 GB RAM. Darling is a Linux-native project that produces a Darwin userland *on Linux*; `cmake` fails immediately on macOS (missing FUSE/udev/Linux glibc). The framework source is fine — the *toolchain* needs Linux.

(On macOS we confirmed the source clones fine but cannot configure/build. A 128GB SD card solved the disk constraint but not the OS constraint.)

---

## 1. What already works (do NOT redo — it's committed & pushed)

Repo: **https://github.com/andrewnakas/Darwin_Computa**, branch **`phase-c-dserver-checkin`**, tip **`900f2bd`**.

That repo is the **Boxedwine-based emulator** (runs a Darling Darwin userland on emulated Linux, on macOS). It already contains **4 real emulator fixes**:

| Fix | Commit | Files | What it fixed |
|-----|--------|-------|---------------|
| M16 filesystem-removal | `91e03e1` | `source/kernel/…FsFileNode` | dir removal dispatches to `rmdir` |
| M67 symlink | `537e544` | `source/kernel/…getMode` | `symlink()` works for darling paths (chroot-prefix write-gate) |
| M77 GUI mouse-button | `380cc66` | `include/knativescreen.h`, `platform/sdl/knativescreenSDL.{h,cpp}`, `source/opengl/gl64bridge.cpp` | hidden GL window stole macOS key-focus → `raiseMainWindow()` after GL init; **verified live: guest AppKit receives clicks** |
| M88 timerfd type-check | `900f2bd` | `source/kernel/kprocess.cpp` | `timerfd_settime/gettime` checked `KTYPE_SIGNAL` not `KTYPE_TIMER` → every arm `-EINVAL` → repeating timers fired once; **now re-arm** |

Also working (verified live via ~86 capability milestones): the whole Foundation data/collections/serialization tier, objc-runtime (introspection, KVO, NSInvocation, libobjc C-API, dynamic class creation, swizzling — all clean), crypto (SHA/HMAC/AES/Base64), networking (raw sockets → HTTP → HTTPS/TLS 1.2), SQLite/zlib/libarchive/libxml2, GCD/dispatch (incl. repeating timers after M88), JavaScriptCore, and interactive Mac GUI `.app` bundles. Full inventory: `memory/darwin-computa-ceiling-report.md` in the session (or ask the macOS agent).

**These emulator fixes are macOS-Boxedwine-specific — they do NOT need to go upstream to Darling.** They stay in the Darwin_Computa repo. This handoff is only about the *framework* gaps below.

---

## 2. The remaining gaps → exact Darling source locations to fix on Linux

Clone: `git clone --recursive https://github.com/darlinghq/darling.git` (needs ~15–30 GB with submodules incl. LLVM/WebKit; a Foundation-only fix needs the `src/external/{foundation,corefoundation,icu,objc4,libclosure,libdispatch}` submodules). Framework source repos: `darlinghq/darling-foundation`, `darlinghq/darling-corefoundation`, `darlinghq/darling-icu`.

### Gap A — Text segmentation broken (M72 ByWords + M81 ByLines)
- **Symptom:** `enumerateSubstringsInRange:options:NSStringEnumerationByWords` returns 1 substring not N; `enumerateLinesUsingBlock:` fires per-character not per-line.
- **Location:** `darling-foundation/src/NSString.m`, `-enumerateSubstringsInRange:options:usingBlock:` (~line 1960) and `-enumerateLinesUsingBlock:` (~line 2003).
- **Root cause:** it uses `CFStringTokenizer` (`CFStringTokenizerCreate` + `CFStringTokenizerAdvanceToNextToken`), which delegates to **ICU's tokenizer**. Under Boxedwine emulation the tokenizer returns per-character tokens. The source even carries `#warning TODO …apportable/issues/272` and a `// this is incorrect and should be fixed` on the `enclosingRange` arg.
- **Where the real bug is:** likely `darling-corefoundation` `CFStringTokenizer.c` and/or `darling-icu` (ICU brk/word-break data or the `ubrk_*` calls). Investigate whether ICU's break-iterator data is present/loaded. Fix = make `CFStringTokenizer` word/line units produce correct ranges (or fall back to a manual `\n`/whitespace splitter for Line/Word units when ICU break data is unavailable).
- **Known-good workaround (already used in the emulator probes):** `componentsSeparatedByString:@"\n"` / `componentsSeparatedByCharactersInSet:` — those always work.

### Gap B — Calendar weekday / date fields wrong (M17)
- **Symptom:** `NSCalendar` day-of-week is wrong (weekday=Sun for a date whose Y/M/D correctly extract to Thu; internally consistent off-by-4, not a TZ/mmap bug).
- **Location:** `darling-foundation/src/NSCalendar.m` delegates to CoreFoundation `CFCalendar` → `darling-corefoundation/…CFCalendar.c` → **ICU `ucal_get(UCAL_DAY_OF_WEEK)`**.
- **Root cause:** embedded ICU-66 day-of-week under emulation. Fix is in **ICU** (`darling-icu`) or the CFCalendar↔ICU glue. Verify ICU's calendar data + the `ucal_*` path.
- **Workaround (proven in-guest):** compute weekday via Zeller's congruence on the correctly-extracted Y/M/D.

### Gap C — NSDecimalNumberHandler rounding broken (M53)
- **Symptom:** `decimalNumberByDividingBy:withBehavior:` ignores scale/rounding (10/3 → 3.33333 not 3.33).
- **Location:** `darling-foundation/src/NSDecimalNumber.m` + `src/NSDecimal.m`. Check the handler's scale/roundingMode application in the divide path.
- **Note:** the by-value `NSDecimal` C-struct bridge HANGS the guest under Boxedwine (separate emulator issue, S113 dead-end) — but the *rounding logic* is a Foundation code issue independent of that.
- **Workaround:** scale-by-powers-of-10 via `NSDecimalNumber` multiply; or `NSNumberFormatter` rounding (which works).

### Gap D — Stubbed subsystems (bodies are placeholders)
- **CoreData** (`darling-*` CoreData) — class/selectors present, implementation is a stub.
- **NSXMLDocument** — `darling-foundation/src/NSXMLDocument.m` logs "unimplemented … at 48" + returns nil. (libxml2 DOM+XPath works as a substitute.)
- **NSLinguisticTagger** — stub logger, 0 tokens.
- These need real implementations upstream (large). Lower priority than A–C.

### Gap E — Pre-10.9 vintage: absent modern APIs
- `stringByAddingPercentEncodingWithAllowedCharacters:`, `NSURLComponents`/`NSURLQueryItem`, `NSInputStream`, `NSData` compression categories, various higher-order NSDictionary/NSArray selectors, `NSProcessInfo` thermal/lowPowerMode, `NSDateInterval`/`NSDateComponentsFormatter`/`NSLengthFormatter`/`NSMeasurement`.
- **Fix:** port these from a newer swift-corelibs-foundation / apple-oss-distributions Foundation into `darling-foundation`. Substantial but mechanical.

### Gap F — WebKit rendering (M5b)
- WebCore is absent from the rootfs (only JavaScriptCore is present). Rendering needs building/obtaining WebCore — very large. JSC alone already executes JS in-guest.

---

## 3. Suggested Linux workflow

1. **Provision:** Ubuntu 22.04/24.04 x86-64 (or Debian 12/13), ≥8 GB RAM, ~60 GB disk.
   ```
   sudo apt install cmake automake clang-15 bison flex libfuse-dev libudev-dev pkg-config \
       libc6-dev-i386 gcc-multilib xz-utils   # (see docs for the full current list)
   git clone --recursive https://github.com/darlinghq/darling.git
   ```
2. **Baseline build** per docs (build + `sudo make install`), confirm `darling shell` runs.
3. **Reproduce a gap** inside `darling shell` with a tiny ObjC probe (the Darwin_Computa repo's `tools/darwin-app/*.m` are ready-made — e.g. `strlinecli.m` for Gap A, `datecli.m` for Gap B, `deccli2.m` for Gap C). Compile with `clang -fno-objc-arc -framework Foundation`.
4. **Patch** the source file identified above; rebuild just that framework (`make` in its build dir), re-run the probe.
5. **Prioritize:** Gap A (text seg) and Gap B (calendar) are the highest-value and most likely tractable — both trace to ICU/CFStringTokenizer, so investigate `darling-icu` break-iterator + calendar data first (they may share a root cause: ICU data not loaded/wrong version). Gap C is a self-contained Foundation logic fix. D/E/F are large.
6. **Feed fixes back:** rebuilt framework `.dylib`s can be re-staged into the Darwin_Computa rootfs (`tools/rootfs-darling/dist/stage/usr/libexec/darling/System/Library/Frameworks/…`) and the macOS emulator will pick them up — closing the gap end-to-end.

---

## 4. Key references (in the Darwin_Computa repo / session memory)

- `memory/darwin-computa-ceiling-report.md` — full capability inventory + gap list + this feasibility finding.
- `memory/darwin-computa-lessons.md` — build/host recipe, the CF-by-path link rule, instrument-before-hypothesizing discipline, all dead-ends.
- `memory/darwin-computa-milestone-ladder.md` — per-milestone detail (what each of ~86 probes proved).
- `tools/darwin-app/*.m` — ready-made ObjC probes for every gap (reproduce + verify fixes).
- `tools/rootfs-darling/build-darling-zip.sh` — how the Darwin userland is staged into the emulator (Docker-based; header has the base-image recipe).

**Bottom line for the Linux picker-upper:** start with `darling-icu` — Gaps A and B both route through ICU (word/line break iterator + calendar day-of-week). If ICU's data or version is the root cause, one fix there may close both. Gap C is an independent Foundation rounding fix. Everything else is large/optional.
