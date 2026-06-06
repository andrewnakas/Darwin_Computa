/*
 *  Copyright (C) 2012-2025  The BoxedWine Team
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 */

#include "boxedwine.h"

#include "startupArgs.h"

#ifdef BOXEDWINE_GUEST_X64
extern int runX64SelfTest();
extern "C" int runX64RunElf(const char* path);
#endif
#ifdef BOXEDWINE_DARWIN
extern int runDarwinSelfTest();
#endif
#ifndef BOXEDWINE_DISABLE_UI
#include "../ui/mainui.h"
#include "../ui/data/boxedwineData.h"
#include "../ui/data/globalSettings.h"
#endif
#include "knativesystem.h"

#ifdef BOXEDWINE_MSVC
#include <Windows.h>
#endif

#ifndef __TEST

U32 gensrc;

#if defined(__MACH__) && defined(BOXEDWINE_GUEST_X64)
#include <cstdio>
#include <cstdlib>
#include <array>
// ---- wine64 in-app GUI picker (the 64-bit analogue of the 32-bit "run a
// program" UI) ----
//
// Launched via `--wine-gui` (the .app bundle / run_wine64_gui.sh pass it). Pops
// a native macOS chooser listing the bundled Windows programs, then fills in the
// SAME root/zips/env/argv that tools/run_wine64_gui.sh builds, so the normal
// startupArgs.apply() launch path runs the chosen exe with a real window. No
// ImGui/SDL UI dependency — a one-shot AppleScript dialog keeps this fully
// decoupled from the (32-bit-only) ImGui container UI.

struct WineGuiApp { const char* name; const char* exe; const char* desc; };
// Curated list of bundled GUI programs worth one-click launching. Anything not
// here can still be run via "Choose your own .exe…" (which lists/copies any
// host exe). Heavier apps (WordPad, Task Manager, IE, dxdiag) boot slower — give
// them a minute; they are not hung. Order = menu order.
static const WineGuiApp kWineGuiApps[] = {
    { "Notepad",      "notepad.exe",  "Text editor (the proven-good GUI app)" },
    { "Minesweeper",  "winemine.exe", "Minesweeper" },
    { "Clock",        "clock.exe",    "Analog clock" },
    { "WordPad",      "write.exe",    "Rich-text editor (slower boot)" },
    { "Wine Config",  "winecfg.exe",  "Wine configuration panel" },
    { "Registry",     "regedit.exe",  "Registry editor" },
    { "Task Manager", "taskmgr.exe",  "Task manager (slower boot)" },
    { "Explorer",     "explorer.exe", "Wine desktop / file browser" },
    { "Control Panel","control.exe",  "Control panel" },
    { "Internet Explorer","iexplore.exe", "IE shell (slower boot)" },
    { "System Info",  "msinfo32.exe", "System information" },
    { "OLE Viewer",   "oleview.exe",  "COM/OLE object viewer" },
    { "DirectX Diag", "dxdiag.exe",   "DirectX diagnostics (slower boot)" },
    { "Help Viewer",  "hh.exe",       "HTML Help viewer" },
    { "Program Mgr",  "progman.exe",  "Program manager" },
    { "Uninstaller",  "uninstaller.exe","Add/Remove programs" },
    { "Command Prompt","cmd.exe",     "Console" },
};

// Run a shell command and capture its trimmed stdout.
static BString runCaptureMac(const BString& cmd) {
    std::array<char, 1024> buf{};
    std::string out;
    FILE* p = popen(cmd.c_str(), "r");
    if (!p) return BString();
    while (fgets(buf.data(), (int)buf.size(), p)) out += buf.data();
    pclose(p);
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r' || out.back() == ' '))
        out.pop_back();
    return BString::copy(out.c_str());
}

static const char* kPickOwnExe = "Choose your own .exe…";

// Prompt for an arbitrary host .exe, copy it into the guest home so wine can
// reach it, and return its guest path (or empty on cancel). baseRoot = the
// guest fs root on the host. Copying (rather than referencing the host path)
// keeps the guest VFS simple and survives the run.
static BString pickOwnExe(const BString& baseRoot) {
    std::string cmd =
        "/usr/bin/osascript -e 'POSIX path of (choose file with prompt "
        "\"Select a Windows .exe to run in Boxedwine64:\")' 2>/dev/null";
    BString hostPath = runCaptureMac(BString::copy(cmd.c_str()));
    if (hostPath.length() == 0) return BString();    // cancelled

    // Basename of the chosen file.
    std::string hp = hostPath.c_str();
    std::string base = hp;
    size_t slash = base.find_last_of('/');
    if (slash != std::string::npos) base = base.substr(slash + 1);
    if (base.empty()) return BString();

    // Copy into the guest home (= guest /home/username). Use a quoted cp; the
    // user picked the file, so this is an explicit, authorized copy.
    BString destDir = baseRoot.stringByApppendingPath("home").stringByApppendingPath("username");
    std::string dest = std::string(destDir.c_str()) + "/" + base;
    std::string cp = std::string("cp '") + hp + "' '" + dest + "' 2>/dev/null";
    if (system(cp.c_str()) != 0) return BString();

    // Guest path: /home/username/<basename>
    std::string guest = std::string("/home/username/") + base;
    return BString::copy(guest.c_str());
}

// Show the chooser; return the selected guest exe path, or empty if cancelled.
// baseRoot lets the "choose your own" branch copy a host exe into the guest fs.
static BString pickWineGuiExe(const BString& baseRoot) {
    std::string listItems;
    for (size_t i = 0; i < sizeof(kWineGuiApps)/sizeof(kWineGuiApps[0]); i++) {
        listItems += "\"";
        listItems += kWineGuiApps[i].name;
        listItems += "\", ";
    }
    listItems += "\"";
    listItems += kPickOwnExe;
    listItems += "\"";
    std::string script =
        std::string("choose from list {") + listItems + "} " +
        "with title \"Boxedwine64\" with prompt \"Pick a Windows program to run:\" " +
        "default items {\"Notepad\"}";
    std::string cmd = std::string("/usr/bin/osascript -e '") + script + "' 2>/dev/null";
    BString picked = runCaptureMac(BString::copy(cmd.c_str()));
    if (picked.length() == 0 || picked == BString::copy("false"))
        return BString();   // cancelled
    if (picked == BString::copy(kPickOwnExe))
        return pickOwnExe(baseRoot);
    const char* exe = "notepad.exe";
    for (const auto& a : kWineGuiApps) {
        if (picked == BString::copy(a.name)) { exe = a.exe; break; }
    }
    std::string guest = std::string("/usr/lib/x86_64-linux-gnu/wine/x86_64-windows/") + exe;
    return BString::copy(guest.c_str());
}

// Populate startupArgs to launch the chosen exe under wine64, mirroring
// tools/run_wine64_gui.sh. resourceDir = where the rootfs + zips are staged.
// Returns false if cancelled.
static bool setupWineGui(StartUpArgs& a, const BString& resourceDir) {
    BString rf = resourceDir.stringByApppendingPath("rootfs64");
    BString dist = rf.stringByApppendingPath("dist");
    BString baseRoot = rf.stringByApppendingPath("root");

    BString guestExe = pickWineGuiExe(baseRoot);
    if (guestExe.length() == 0) return false;     // user cancelled -> exit cleanly

    // Clear transient wineserver state before launching, exactly as
    // tools/run_wine64_gui.sh does. A crashed/incomplete previous run leaves
    // wineserver's O_EXCL registry temp files (regf*.tmp) and per-boot
    // server-1-XXX socket dirs behind; on the next launch the new wineserver
    // collides with the stale socket and blocks (the "hang on loading" seen
    // when launching from the picker), and the temp-create loop can corrupt its
    // heap. Wipe everything except the committed server-1-4ee. Best-effort.
    {
        BString prefix = baseRoot.stringByApppendingPath("home")
                                 .stringByApppendingPath("username")
                                 .stringByApppendingPath(".wine");
        BString run = baseRoot.stringByApppendingPath("run")
                              .stringByApppendingPath("user")
                              .stringByApppendingPath("1000")
                              .stringByApppendingPath("wine");
        std::string clean =
            std::string("rm -f '") + prefix.c_str() + "'/regf*.tmp '" +
            prefix.c_str() + "/.update-timestamp' 2>/dev/null; " +
            "find '" + run.c_str() + "' -maxdepth 1 -name 'server-1-*' " +
            "! -name 'server-1-4ee' -exec rm -rf {} + 2>/dev/null";
        int rc = system(clean.c_str());
        (void)rc;
    }

    a.setRoot(baseRoot);
    a.addZip(dist.stringByApppendingPath("glibc-rootfs64.zip"));
    a.addZip(dist.stringByApppendingPath("wine64.zip"));
    a.envValues.push_back(BString::copy("HOME=/home/username"));
    a.envValues.push_back(BString::copy("USER=username"));
    a.envValues.push_back(BString::copy("WINEPREFIX=/home/username/.wine"));
    a.envValues.push_back(BString::copy("WINELOADER=/usr/lib/wine/wine64"));
    a.envValues.push_back(BString::copy("WINESERVER=/usr/lib/wine/wineserver64"));
    a.envValues.push_back(BString::copy("WINEDLLPATH=/usr/lib/x86_64-linux-gnu/wine"));
    a.envValues.push_back(BString::copy("DISPLAY=:0"));
    a.addArg(BString::copy("/usr/lib/wine/wine64"));
    a.addArg(guestExe);
    return true;
}
#endif // __MACH__ && BOXEDWINE_GUEST_X64

#ifdef GENERATE_SOURCE
void writeSource();
#endif

#ifdef BOXEDWINE_DARWIN
// ---- Darwin_Computa: run a Mach-O under emulated Darling ----
//
// `--darwin-run <guest-macho-path> [extra args...]` populates startupArgs to
// boot the Darling userland (mldr -> dyld -> libSystem -> the Mach-O) on the
// emulated-Linux substrate, then falls through to the normal apply() launch
// path (exactly like --wine-gui does for wine64).
//
// The Darling rootfs is staged like the wine64 rootfs: a base "root" tree plus
// layered zips, under <resourceDir>/rootfs-darling/. resourceDir defaults to
// the directory the executable lives in (KNativeSystem::getLocalDirectory()),
// overridable with `-root`/`-zip` on the command line as usual.
//
// In Phase A neither the rootfs nor /dev/mach exist yet, so this is expected to
// fail when mldr does open("/dev/mach") — which is precisely the signal we want
// from the SYS64 tracer to confirm the entry path reaches the kernel handshake.
//
// The path to mldr inside the guest follows Darling's install layout
// (/usr/libexec/darling/mldr). Overridable with $DARWIN_MLDR.
static bool setupDarwinRun(StartUpArgs& a, int argc, const char** argv,
                           int flagIndex) {
    // Collect the guest args that follow --darwin-run.
    std::vector<BString> guestArgs;
    for (int i = flagIndex + 1; i < argc; i++) {
        if (!argv[i]) break;
        guestArgs.push_back(BString::copy(argv[i]));
    }
    if (guestArgs.empty()) {
        printf("--darwin-run: usage: --darwin-run <guest-macho-path> [args...]\n");
        return false;
    }
    KSystem::darwinMode = true;   // Darling needs uid/gid 0 (darlingserver)

    BString resourceDir = KNativeSystem::getLocalDirectory();
    BString rf = resourceDir.stringByApppendingPath("rootfs-darling");
    BString baseRoot = rf.stringByApppendingPath("root");
    BString dist = rf.stringByApppendingPath("dist");

    a.setRoot(baseRoot);
    // Layered zips, mounted in order. Phase E's build-darling-zip.sh produces
    // these; if absent, FsZip mounting is a no-op and the base root is used.
    a.addZip(dist.stringByApppendingPath("glibc-rootfs64.zip"));
    a.addZip(dist.stringByApppendingPath("darling.zip"));

    a.envValues.push_back(BString::copy("HOME=/home/username"));
    a.envValues.push_back(BString::copy("USER=username"));
    a.envValues.push_back(BString::copy("DISPLAY=:0"));
    // We deliberately DO NOT set DARLING_NOOVERLAYFS, so darlingserver's
    // shouldUseOverlayFs() defaults true (we are not WSL1) and it takes the cheap
    // overlay path: a single mount("overlay", prefix, ...) call. Our emulated
    // mount/unshare are no-op->0, so that mount is free. The alternative
    // (DARLING_NOOVERLAYFS=1) path runs copyAndSetAttributes(), a recursive walk
    // of the ENTIRE 375MB prefix re-stamping owner/perm/mtime on every file
    // (~400k syscalls, minutes under the interpreter, every launch) — and since
    // its source LIBEXEC_PATH is compiled as /usr/libexec/darling == our DPREFIX,
    // it mirrors the tree onto itself: provably pointless work. The overlay's
    // only job is write-isolation, which our private per-guest VFS + writable
    // root already provide. DPREFIX is the Darwin prefix root inside the rootfs.
    // The Darwin prefix is staged at its real install path so darlingserver's
    // compiled-in mldr/vchroot/launchd paths resolve (it execs e.g.
    // `mldr vchroot /usr/libexec/darling /sbin/launchd`).
    a.envValues.push_back(BString::copy("DPREFIX=/usr/libexec/darling"));

    // If the target is darlingserver itself, run it DIRECTLY (it is a Linux ELF,
    // not a Mach-O) with the 6-arg contract its main() requires:
    //   argv = darlingserver <prefix> <uid> <gid> <lifetime-pipe-fd> <fixperms>
    // (argc>=6 or it prints "not meant to be started manually"; it also requires
    // uid/gid 0 — provided by KSystem::darwinMode). This is how the bring-up
    // harness drives the server independently of mldr. pipe fd -1 = none.
    // BW64_DSLOG: surface darlingserver's own log (calls/procmem/etc. error
    // lines) on stderr so it lands in our boot log inline, instead of the
    // prefix's private/var/log/dserver.log. Invaluable for seeing which RPC the
    // server rejected when launchd aborts.
    if (std::getenv("BW64_DSLOG")) {
        a.envValues.push_back(BString::copy("DSERVER_LOG_STDERR=1"));
        const char* lvl = std::getenv("BW64_DSLOG_LEVEL");
        a.envValues.push_back(BString::copy(lvl && lvl[0]
            ? (std::string("DSERVER_LOG_LEVEL=") + lvl).c_str()
            : "DSERVER_LOG_LEVEL=debug"));
    }
    // BW64_DYLDLOG: ask the guest dyld to narrate image loading + initializers
    // + API calls. When launchd aborts inside an image initializer, the last
    // "running initializer for <dylib>" line names the culprit image directly.
    if (std::getenv("BW64_DYLDLOG")) {
        a.envValues.push_back(BString::copy("DYLD_PRINT_INITIALIZERS=1"));
        a.envValues.push_back(BString::copy("DYLD_PRINT_LIBRARIES=1"));
        a.envValues.push_back(BString::copy("DYLD_PRINT_APIS=1"));
        a.envValues.push_back(BString::copy("DYLD_PRINT_SEGMENTS=1"));
    }

    BString first = guestArgs[0];
    if (first.endsWith("darlingserver")) {
        a.addArg(first);
        a.addArg(BString::copy("/usr/libexec/darling")); // argv[1] prefix
        a.addArg(BString::copy("0"));                  // argv[2] originalUID
        a.addArg(BString::copy("0"));                  // argv[3] originalGID
        a.addArg(BString::copy("-1"));                 // argv[4] lifetime pipe fd
        a.addArg(BString::copy("0"));                  // argv[5] fix_permissions
        return true;
    }

    const char* mldr = std::getenv("DARWIN_MLDR");
    a.addArg(BString::copy(mldr && mldr[0] ? mldr : "/usr/libexec/darling/mldr"));
    a.addArgs(guestArgs);
    return true;
}
#endif // BOXEDWINE_DARWIN

int boxedmain(int argc, const char **argv) {
    StartUpArgs startupArgs;

    klog("Starting ...");
#ifdef BOXEDWINE_GUEST_X64
    // --x64-selftest: run the CPU64/KMemory64/syscall64 smoke test and exit.
    // Checked first, before any argv substitution (Mac args.txt) or startup
    // parsing, so it stays a pure diagnostic.
    for (int i = 1; i < argc; i++) {
        if (argv[i] && std::string(argv[i]) == "--x64-selftest") {
            return runX64SelfTest();
        }
        if (argv[i] && std::string(argv[i]) == "--x64-run-elf") {
            // Optional next arg = ELF path on host disk. Without it the
            // runner uses an embedded hand-built static hello-world ELF.
            const char* path = (i + 1 < argc && argv[i+1] && argv[i+1][0] != '-')
                                 ? argv[i+1] : nullptr;
            return runX64RunElf(path);
        }
    }
#endif
#ifdef BOXEDWINE_DARWIN
    // --darwin-selftest: smoke-test the Darwin/_dev/mach trap layer and exit.
    for (int i = 1; i < argc; i++) {
        if (argv[i] && std::string(argv[i]) == "--darwin-selftest") {
            return runDarwinSelfTest();
        }
    }
    // --darwin-run <guest-macho> [args...]: boot the Mach-O under emulated
    // Darling. Populates startupArgs then falls through to apply() below.
    bool darwinRunMode = false;
    for (int i = 1; i < argc; i++) {
        if (argv[i] && std::string(argv[i]) == "--darwin-run") {
            if (!setupDarwinRun(startupArgs, argc, argv, i)) {
                return 1;
            }
            darwinRunMode = true;
            break;
        }
    }
#endif

#if defined(__MACH__) && defined(BOXEDWINE_GUEST_X64)
    // --wine-gui [resourceDir]: show the native app picker, then launch the
    // chosen Windows program under wine64. The 64-bit analogue of the 32-bit
    // "run a program" UI. resourceDir defaults to the directory the rootfs is
    // staged in (an explicit path arg, else next to the executable). Run BEFORE
    // startup parsing so it can populate startupArgs directly; then fall through
    // to the normal Platform::init / KNativeSystem::init / apply() flow below
    // (which returns this->args.size()!=0 → shouldStartUI() false → launches).
    bool wineGuiMode = false;
    for (int i = 1; i < argc; i++) {
        if (argv[i] && std::string(argv[i]) == "--wine-gui") {
            wineGuiMode = true;
            BString resourceDir = (i + 1 < argc && argv[i+1] && argv[i+1][0] != '-')
                ? BString::copy(argv[i+1])
                : KNativeSystem::getLocalDirectory();
            if (!setupWineGui(startupArgs, resourceDir)) {
                return 0;     // user cancelled the picker
            }
            break;
        }
    }
#endif
#if defined(__MACH__)
    std::vector<BString> lines;
    std::vector<const char*> args;
    BString dataPath = KNativeSystem::getLocalDirectory();
    BString argsPath = dataPath.stringByApppendingPath("args.txt");
    readLinesFromFile(argsPath, lines);
    Fs::deleteNativeFile(argsPath);
    if (lines.size()) {
        KSystem::showWindowTimestamp = dataPath.stringByApppendingPath(lines[0]+".txt");
        U32 createdTime = lines[0].toInt();
        U32 now = (U32)(KSystem::getSystemTimeAsMicroSeconds() / 100000);
        if (createdTime + 10 > now) {
            args.push_back(argv[0]);
            
            for (int i=1;i<(int)lines.size();i++) {
                args.push_back(lines[i].c_str());
            }
            argc = (int)args.size();
            argv = args.data();
        }
    }
#endif
    KSystem::startMicroCounter();
    KSystem::exePath = BString::copy(argv[0]);
    if (KSystem::exePath.contains("\\")) {
        KSystem::exePath = KSystem::exePath.substr(0, KSystem::exePath.lastIndexOf('\\')+1);
    } else {
        KSystem::exePath = KSystem::exePath.substr(0, KSystem::exePath.lastIndexOf('/')+1);
    }
    bool skipArgParse = false;
#if defined(__MACH__) && defined(BOXEDWINE_GUEST_X64)
    skipArgParse = wineGuiMode;   // startupArgs already populated by the picker
#endif
#ifdef BOXEDWINE_DARWIN
    if (darwinRunMode) skipArgParse = true;   // startupArgs filled by setupDarwinRun
#endif
    if (skipArgParse) {
        // nothing — startupArgs was filled by setupWineGui()
    } else if (argc == 1) {
        if (!startupArgs.loadDefaultResource(argv[0])) {
            return 1;
        }

    } else if (!startupArgs.parseStartupArgs(argc, argv)) {
        return 1;
    }
    
#ifdef BOXEDWINE_MSVC
#ifdef BOXEDWINE_DISABLE_UI    
    if (startupArgs.dpiAware) {
        SetProcessDPIAware();
    }
#else
    if (startupArgs.shouldStartUI() || startupArgs.dpiAware) {
        SetProcessDPIAware();
    }
#endif
#endif

#ifdef _DEBUG
    U32 cpuCount = Platform::getCpuCount();
    if (cpuCount==1) {
        klog_fmt("%d MHz CPU detected", Platform::getCpuFreqMHz());
    } else {
        klog_fmt("%dx %d MHz CPUs detected", cpuCount, Platform::getCpuFreqMHz());
    }
#endif

    Platform::init();
    // currently to fake sound, we really need to play it and just silence it right before it goes to speaker, 
    // this way the timing of the callback to get the audio from wine are correct.  Without this timing, things can hange.
    if (!KNativeSystem::init(startupArgs.videoOption, true/* startupArgs.soundEnabled */)) {
        return 1;
    }
#ifndef BOXEDWINE_DISABLE_UI
    BoxedwineData::init(argc, argv);
#endif
    if (!startupArgs.shouldStartUI()) {
        if (!startupArgs.apply()) {
            return 1;
        }
    } else {
#ifndef BOXEDWINE_DISABLE_UI

#ifdef BOXEDWINE_MSVC
        if (StartUpArgs::uiType == UI_TYPE_UNSET) {
#ifdef BOXEDWINE_IMGUI_DX9
            StartUpArgs::uiType = UI_TYPE_DX9;
#else
            StartUpArgs::uiType = UI_TYPE_OPENGL;
#endif
        }
#else
        if (StartUpArgs::uiType == UI_TYPE_UNSET) {
            StartUpArgs::uiType = UI_TYPE_OPENGL;
        }
#endif
        while (true) {
            if (GlobalSettings::keepUIRunning) {
                GlobalSettings::keepUIRunning();
                GlobalSettings::keepUIRunning = nullptr;
                if (!uiContinue()) {
                    break;
                }
            } else {
                if (!uiShow(GlobalSettings::getExePath() + Fs::nativePathSeperator)) {
                    break;
                }
            }
            if (GlobalSettings::restartUI) {
                GlobalSettings::restartUI = false;
                if (GlobalSettings::reinit) {
                    GlobalSettings::reinit = false;
                    GlobalSettings::init(argc, argv);
                } else {
                    GlobalSettings::startUp();
                }
                continue;
            }
            BoxedwineData::startApp();
            GlobalSettings::startUpArgs.readyToLaunch = false;

            KNativeSystem::preReturnToUI();
            if (!GlobalSettings::keepUIRunning) {
                GlobalSettings::startUp(); // we we come back in after launching a game, we will need to create icons, like the demo icons
            }
        }
#endif
    }              

    klog("Boxedwine shutdown");
    KNativeSystem::cleanup();
    return BOXEDWINE_RECORDER_QUIT();
}

#endif
