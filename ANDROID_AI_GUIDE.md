# Blender for Android: Build and Change Guide

A reference for a person or an AI agent picking this fork up cold. It covers what
the port is, how to build it end to end, how to drive a device over ADB, and
where every change lives in the tree.

## Credits

This port did not start here. It started with **Simfeo**, whose Android alpha did
the hard bring up work and is the build this fork was derived from:

> https://github.com/simfeo/blender/releases/tag/android-alpha-1

**Blender** itself is made by the Blender Foundation and its community, and is
free and open source under the GPL. This fork inherits that license: if you
distribute a binary built from this tree, the matching source has to go with it.

The work described below, everything from the on-screen keyboard to the touch and
stylus handling and the dependencies that were cross compiled to turn features
back on, is by **Wanderson M. Pimenta**, continuing Simfeo's port on a Galaxy S24
Ultra, on Blender 5.3 alpha, arm64, Vulkan.

## Status: a study project, open to whoever wants it

This is a study project. It is not maintained, and there is no support: the
author does not have the time an open source project deserves, and would rather
say so plainly than leave anyone waiting on an answer that is not coming.

It is published because it works and because the ground it covers is worth
having. The community is welcome to take it anywhere: fork it, carry the changes
upstream, or use them as the starting point for a better port. Nothing here is
waiting on permission.

The best outcome would be an Android port with the Blender developers behind it,
built by the people who know that codebase best. Everything in this tree is one
person learning C++ against a codebase far larger than him, with the help of AI
assistants for the cross compilation and the debugging. It proves the hardware
can do it. It is not a substitute for the real thing.

## What you get

A single APK, around 240 MB, containing Blender with native audio output, Cycles,
EEVEE, Open Image Denoise, fluid simulation, motion tracking, USD, OpenVDB,
Alembic, MaterialX, FFmpeg, a full Python with pip, and the essentials asset
library. Two feature sets exist, `full` and `lite`; the numbers and features
above are `full`.

---

# Part 1: Building

## Prerequisites

| Thing | Requirement |
| --- | --- |
| Host | Linux or macOS. On Windows use WSL2 and keep the checkout inside the Linux filesystem. |
| Host compiler | GCC 14 or newer, or Clang 17 or newer. Blender's own code generators need it. `build_files/android/env.sh` picks the first of `gcc-15`, `gcc-14`, `clang-18`, `clang-17` it finds, so it does not have to be the system default. |
| Android SDK | With platform tools. Point `ANDROID_HOME` at it. |
| Android NDK | Version is pinned in [env.sh](build_files/android/env.sh) as `ANDROID_NDK_VERSION`. |
| JDK | 17. Needed for the APK tooling. |
| Disk | Around 60 GB for the dependency prefix, the build trees and the archived APKs. |

Target API levels: minimum 31 (Android 12), compiled against 34.

## Layout

Everything the build produces lives outside the checkout, under one directory
called `BUILD_BASE`:

```
$BUILD_BASE/lib/android_arm64          cross compiled dependencies
$BUILD_BASE/build_host_tools_<cfg>     native code generators (makesdna, makesrna, ...)
$BUILD_BASE/build_android_<cfg>        Blender itself
$BUILD_BASE/android_apk_stage_<cfg>    the APK being assembled
$BUILD_BASE/apk                        archived APKs, newest linked as <cfg>-latest.apk
```

`<cfg>` is `full` or `lite`. `build.py` resolves `BUILD_BASE` from an explicit
`--build-base`, then the environment, then the first candidate that actually
holds `lib/android_arm64`, and stops with a clear message when it finds nothing.

## Dependencies

[build_files/android/deps/build.sh](build_files/android/deps/build.sh) cross
compiles every library into `$BUILD_BASE/lib/android_arm64`. There are 73
recipes, from zlib and Python through OpenVDB, OpenImageIO, OpenSubdiv, Embree,
FFmpeg, GMP, Ceres, FFTW, OpenPGL, Manifold, Draco and Open Image Denoise.

Two of them need patches that live with the build files:

- Open Image Denoise, see [oidn_android.diff](build_files/build_environment/patches/oidn_android.diff): Bionic only exposes the pthread affinity calls from API 36, so they are redirected to the `sched_*` equivalents.
- glog, see [extern/glog/src/config_linux.h](extern/glog/src/config_linux.h): Android is `__linux__` and so claimed `HAVE_EXECINFO_H`, which selects a stack trace path that does not compile below API 33.

The dependency build is a one time cost of hours. Run it before the first
Blender build:

```bash
build_files/android/deps/build.sh
```

## Configurations

Feature toggles live in three files:

- [android_features_common.cmake](build_files/android/android_features_common.cmake)
- [android_features_full.cmake](build_files/android/android_features_full.cmake)
- [android_features_lite.cmake](build_files/android/android_features_lite.cmake)

`full` is everything. `lite` drops TBB, Cycles and the heavy IO, for weaker
devices and a much smaller APK.

The host code generators must be built with the **same** feature set as the
target, or the generated RNA and DNA disagree with the compiled binary, so each
configuration has its own host tools, build and stage directories.

## Building

```bash
python3 build_files/android/build.py full
```

Useful flags:

| Flag | Use |
| --- | --- |
| `--repackage` | Rebuild the runtime payload. Required for any change under `scripts/`, `assets/` or `release/datafiles`. |
| `--reconfigure` | Re-run CMake, keeping every object file. Required after a DNA header or version change, and after changing a feature flag. |
| `--clean` | Throw the build tree away and start over. |
| `--install`, `--run` | Push to a connected device and launch it. |
| `--keep N`, `--no-archive` | How many archived APKs to retain. |
| `--debuggable`, `--validation`, `--turnip` | Debug variants. |
| `-s SERIAL` | Which device, when more than one is attached. |

### Four traps, all of them silent

Each of these ends with a build that reports success while the device runs the
old code. They are the reason `.claude/skills/android-build/SKILL.md` exists.

1. **The fast path only swaps `libblender.so`.** A Python, keymap, datafile or
   manifest change does not reach the device without `--repackage`.
2. **A version or DNA change needs `--reconfigure`.** The fast path does not
   rebuild the host generators, so `makesdna` and `makesrna` keep whatever build
   they had and the generated DNA and RNA disagree with the binary. The result is
   not a compile error: the app installs, the activity starts, and the process
   dies before the first log line.
3. **The device unpacks the runtime once.** `BlenderActivity` writes a marker
   into its data directory and returns early while it exists. The marker now
   carries a hash of the payload, written by
   [package.sh](build_files/android/apk/package.sh), so a changed payload
   invalidates it on its own. If you ever suspect a stale payload,
   `adb shell pm clear <package>` erases it, and the user preferences with it.
4. **Exit codes are lost through `wsl.exe`.** Never trust `$?` for anything run
   that way. Grep the build log for the archive line instead.

A fifth is not silent, but it is easy to misread as something being wrong with
the build rather than with the change: adding a lone 4 byte field to a DNA struct
shifts every pointer after it off the 8 byte boundary DNA requires, and
`makesdna` stops with a page of `Align struct error` lines and
`Sizeerror in 64 bit struct: X (add 4 bytes)`. The fix is four bytes of padding
beside the new field, not anywhere else.

### Verifying a change actually made it in

```bash
# The object file was really recompiled
find "$BUILD_BASE/build_android_full" -name 'YOURFILE.cc.o' -newermt '-10 minutes'

# A payload change is really inside the packaged archive
unzip -p "$BUILD_BASE/android_apk_stage_full/assets/blender_runtime.zip" \
  scripts/path/to/file.py | grep 'your change'

# A string you added is really in the shipped library
strings "$BUILD_BASE/android_apk_stage_full/lib/arm64-v8a/libblender.so" | grep 'your marker'
```

That last one matters more than it looks. Instrumentation that logs nothing is
evidence only after you have confirmed it is in the binary.

---

# Part 2: Driving a device with ADB

Nothing here needs a specific machine or path. `adb` is in the SDK platform
tools; put that directory on `PATH`, or call it by its full path in your own
environment.

```bash
adb devices                       # confirm exactly one device is attached
adb install -r path/to/blender.apk
adb shell am start -n org.blender.blender/.BlenderActivity
adb shell pidof org.blender.blender      # still alive a few seconds later?
```

Wireless debugging works and is convenient on a phone. Pair once from the
device developer settings, then `adb connect <host>:<port>`. The connection
drops when the device sleeps or changes network; `adb devices` returning nothing
means reconnect, not a broken build.

## Watching what the app does

```bash
adb logcat -c                     # clear, then reproduce
adb logcat -d -s TAG -v time      # read one tag back
adb logcat -d -b crash | tail -40 # the crash buffer is separate and already holds the tombstone
```

A native crash never has to be reproduced under observation. Read `-b crash`
first.

### Debug mode: `build_files/android/debug.sh`

Blender's own debug flags without a rebuild. The native glue reads launch arguments
from `blender_args.txt` in the app's internal files directory and then in its external
one, `/sdcard/Android/data/org.blender.blender/files`, which adb can write on any build
(`ghost_android_read_launch_args()` in `GHOST_AndroidMain.cc`). Blender's stdout and
stderr already reach logcat under the tag `blender`, so `--debug-*` and `--log` output
lands there.

| Command | What it does |
| --- | --- |
| `debug.sh status` | Device, installed version, whether the APK is debuggable, the debug flags in effect |
| `debug.sh on <preset>` | Write a preset's flags and restart: `events`, `wm`, `gpu`, `vulkan`, `workarounds`, `python`, `depsgraph`, `log`, `all` (`debug.sh presets` lists them) |
| `debug.sh on -- <flags>` | Any flags, e.g. `on -- --debug-wm --log wm.*` |
| `debug.sh off` | Remove the flags and restart |
| `debug.sh log` | Follow logcat for Blender's process only |
| `debug.sh crash` | The last native crash from the crash buffer, with its backtrace |
| `debug.sh report [note]` | A `.tar.gz` under `$BUILD_BASE/debug_reports`: logcat (all, Blender, crash), meminfo, gfxinfo, `dumpsys input` (held keys and stuck modifiers), IME state, focus, a screenshot, the flags and the commit |
| `debug.sh build` | `build.py full --debuggable`: `run-as` and a native debugger work. Never for a release |

For temporary native logging, log directly rather than through Blender's CLOG,
which cannot be enabled without a command line:

```cpp
#ifdef __ANDROID__
#  include <android/log.h>
#  define DBG(...) __android_log_print(ANDROID_LOG_INFO, "DBG", __VA_ARGS__)
#endif
```

Remove it before committing.

## Injecting input

Injected events arrive as real touches and exercise the same path a finger does.

```bash
adb shell input tap X Y
adb shell input swipe X1 Y1 X2 Y2 DURATION_MS
adb shell input keyevent 111            # Esc
adb exec-out screencap -p > shot.png
adb shell dumpsys window | grep mCurrentFocus   # what is actually in the foreground
```

Two habits that save hours:

- **Check the foreground first.** The phone is somebody's personal device. If it
  is not Blender, your taps land somewhere they should not.
- **Coordinates from a screenshot are not the coordinates the app sees.** The
  system status bar offsets the y axis, and the port scales input. Log what
  arrives instead of assuming.

## Rotation as a variable

Some behaviour only breaks in one orientation. Force it rather than asking a
human to turn the phone, and put the setting back afterwards:

```bash
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 1      # 0 portrait, 1 landscape
# ... test ...
adb shell settings put system user_rotation 0
adb shell settings put system accelerometer_rotation 1
```

---

# Part 3: What was changed, and where

Every entry links the file the change lives in. Function names are given where
they help you find the code quickly.

**Read this part before deciding something is broken.** This is Blender with a few
hundred deliberate divergences in it, and every one of them looks like a defect
from the inside. A modifier that stays down after the finger lifts, a top bar with
one button where there were eleven tabs, a menu that scrolls under a drag: each is
either a design or a bug, and the code cannot tell you which. This table can.

Anything built, fixed or taken back out belongs here before it is committed. See
[.claude/skills/android-document-change/SKILL.md](.claude/skills/android-document-change/SKILL.md).

## Input, touch and stylus

| Change | Where |
| --- | --- |
| Android GHOST backend: touch, stylus, gestures, the soft keyboard bridge, window lifecycle | [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc), [GHOST_SystemAndroid.hh](intern/ghost/intern/GHOST_SystemAndroid.hh), [GHOST_AndroidMain.cc](intern/ghost/intern/GHOST_AndroidMain.cc) |
| One finger drag scrolls panels, headers, tool bars and the Properties editor. Widgets in those regions defer activation to `KM_CLICK`, so a tap still presses them and a drag pans. Scope is `but_touch_scroll_region()` | [interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc), [interface_panel.cc](source/blender/editors/interface/interface_panel.cc), [blender_default.py](scripts/presets/keyconfig/keymap_data/blender_default.py) |
| Dragging from plain buttons and tool bar icons too. The press is left unconsumed, the motion is let through `handler_region_menu()`, and the tool group popup waits longer | [interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc) |
| Three finger drag pans the 3D viewport. Shift is mirrored into the GHOST modifier state so the window manager does not cancel it, see `touchSendShift()` | [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc), [blender_default.py](scripts/presets/keyconfig/keymap_data/blender_default.py) |
| Two finger gestures commit to pan or zoom once, instead of emitting both every frame | [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc) |
| A finger press is reported where the finger landed, not where it has since travelled | [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc), `handleMotionEvent()` |
| Window focus is reported to Blender. Without it `wmWindow.active` stays 0 and the window manager overwrites the position of every press with the current cursor position, which is why a finger could never grab anything precise | [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc) `handleWindowFocus()`, [GHOST_AndroidMain.cc](intern/ghost/intern/GHOST_AndroidMain.cc) |
| A moving finger no longer becomes a right click at the long press deadline | [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc), `touchLongPressCheck()` |
| Editor borders can be grabbed with a finger. A press without tablet data that lands near a border is moved onto it before it is queued, from the main region of an editor only | [screen_geometry.cc](source/blender/editors/screen/screen_geometry.cc) `ED_screen_edge_snap_for_touch()`, [ED_screen.hh](source/blender/editors/include/ED_screen.hh), [wm_event_system.cc](source/blender/windowmanager/intern/wm_event_system.cc) |
| Stylus pressure reaches 100% with a comfortable press. Android normalises pressure against the range the digitiser declares, and an S Pen tops out around 0.77 | [DNA_userdef_types.h](source/blender/makesdna/DNA_userdef_types.h), [versioning_userdef.cc](source/blender/blenloader/intern/versioning_userdef.cc), [rna_userdef.cc](source/blender/makesrna/intern/rna_userdef.cc) |
| Typing with the platform keyboard. A soft keyboard sends composing text, not key events, so the composition is mirrored into the field | [BlenderActivity.java](build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java) |
| The interface rotates with the device | [GHOST_AndroidMain.cc](intern/ghost/intern/GHOST_AndroidMain.cc), [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc), [AndroidManifest.xml](build_files/android/apk/app/src/main/AndroidManifest.xml) |
| A hardware or Bluetooth keyboard types. The native input queue returns 0 for every key so the event reaches `BlenderActivity.dispatchKeyEvent()` (and `InputView.onKeyPreIme()` while the IME is bound), which forwards it with the character `KeyCharacterMap` resolves: dead keys compose (ABNT2), AltGr types, Ctrl/Super/left Alt make shortcuts. Native and Java share the `nativeOnKey(keycode, action, meta, unicode, repeat)` contract, so ship them together | [BlenderActivity.java](build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java) `forwardHardwareKey()`, [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc) `handleKeyEvent()`, `dispatchJavaKeyEvent()` |
| The platform keyboard stays down while an external alphabetic keyboard is connected, re-checked by an `InputDeviceListener` when one is paired or switched off mid-edit | [BlenderActivity.java](build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java) `updateSoftKeyboard()` |
| A quick three-finger tap sends Ctrl+Space (toggle maximized area) at the fingers' centroid. The three-finger pan now waits for `GESTURE_DECIDE_PX` of travel before it starts, which is what tells the two apart | [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc) `touchSendFullArea()`, `TOUCH_THREE_TAP_MS` |
| The modifier wheel: floating Ctrl/Shift/Alt (latched), Quick Favorites, and Enter/Esc while the status bar shows them for a modal operator. Ported from the official `android-demo` branch and rebuilt on this backend's pointer events, asked before the on-screen keyboard in `ghost_event_proc()`. Its modifiers are the window's own event state, which the on-screen keyboard now reads too (`vk.mods` is refreshed from it), so the two always agree. `GHOST_TButton` is an index, not a mask -- treating it as one left the wheel holding every press | [wm_modifier_wheel.cc](source/blender/windowmanager/intern/wm_modifier_wheel.cc), [wm_virtual_keyboard.cc](source/blender/windowmanager/intern/wm_virtual_keyboard.cc), [interface_template_status.cc](source/blender/editors/interface/templates/interface_template_status.cc), `popup_menu_invoke(..., anchor_xy)` in [interface_region_menu_popup.cc](source/blender/editors/interface/regions/interface_region_menu_popup.cc) |
| Side panels resize with a finger. The region edge action zone is widened for touch (into the panel by at most a fifth of its width, out of it only when it does not overlap), a press on it goes to the screen keymap before the region under it, and `screen.actionzone`'s poll also accepts the press position -- a finger's drag arrives all at once, so the event state is already past the edge when the press is handled | [area.cc](source/blender/editors/screen/area.cc) `region_azone_edge()`, [wm_event_system.cc](source/blender/windowmanager/intern/wm_event_system.cc) `ED_area_region_edge_at_xy()`, [screen_ops.cc](source/blender/editors/screen/screen_ops.cc) `actionzone_area_poll()` |
| Tree view lists scroll with a finger: in a touch-scroll region a drag on a row pans instead of starting a drag and drop (a stylus still drags), and `ui.view_item_select` acts on CLICK. The Asset Browser's catalog list opens at no more than 40% of the editor's width the first time | [interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc) `do_but_VIEW_ITEM()`, [blender_default.py](scripts/presets/keyconfig/keymap_data/blender_default.py), [area.cc](source/blender/editors/screen/area.cc) `region_rect_recursive()` |
| Folders open with one tap in the File Browser: "Open Folders on Single Click" defaults on when `sys.platform == "android"`, and `file.select` acts on CLICK so a drag that starts on a folder scrolls instead of opening it. A double tap had to land twice within a few pixels | [Blender.py](scripts/presets/keyconfig/Blender.py) `use_file_single_click`, [blender_default.py](scripts/presets/keyconfig/keymap_data/blender_default.py) `km_file_browser_main()` |

## The on-screen keyboard

A keyboard drawn by Blender itself, opened from a button at the far left of the
status bar. It exists because an add-on cannot do this: a pointer event that
reaches the interface layer ends whatever text field is being edited, and no
overlay can sit in front of that.

| Piece | Where |
| --- | --- |
| State, layout, drawing, hit testing, key injection | [wm_virtual_keyboard.cc](source/blender/windowmanager/intern/wm_virtual_keyboard.cc) |
| The interception, above every handler in Blender | [wm_window.cc](source/blender/windowmanager/intern/wm_window.cc), in `ghost_event_proc()` |
| Holding back the platform keyboard while it is open, and reporting the edited field | [interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc), `textedit_begin()` and `textedit_end()` |
| The status bar button | [space_statusbar.py](scripts/startup/bl_ui/space_statusbar.py) |
| Public API and operator registration | [WM_api.hh](source/blender/windowmanager/WM_api.hh), [wm.hh](source/blender/windowmanager/wm.hh), [wm_operators.cc](source/blender/windowmanager/intern/wm_operators.cc) |
| Why it is native rather than Python, with the anchor points it was built from | [ANDROID_VIRTUAL_KEYBOARD_STUDY.md](ANDROID_VIRTUAL_KEYBOARD_STUDY.md) |

It sends real key events, so it types into any field, holds Ctrl, Shift and Alt,
and fires every shortcut in the keymap including the numpad view keys. It works
in every workspace and lays itself out for portrait or landscape.

Six rows, laid out like a laptop's: **Esc and F1 to F12** across the top, then the
numbers, then the letters carrying `[ ] \` and `; '`. Without the function row a
phone has no way at all to reach F2 to rename, F3 to search, F9 to reopen the last
operator's panel or F12 to render, and without the bracket and quote keys a script
cannot be typed at all. Esc sits at the head of the function row rather than at
the head of the letters, which is what freed the space the punctuation went into.

**Every row in a block totals the same number of units**, and that is what makes
the columns line up: 14 for the letters, 4 for the numeric block beside them in
landscape, 5 for the numeric layer that replaces them in portrait. Widen one key
and the row it is in has to give the same amount back somewhere else, or that row
alone comes out staggered against the rest. All three blocks are also six rows
deep on purpose: two of them share a height in landscape and the other two swap
places in portrait, so a block one row shorter than its neighbour shows it as
taller keys.

**With Shift on, every key that types swaps its label for the character it will
actually produce, drawn in blue.** The alternative was printing both characters on
each cap the way a physical keyboard does, which at this size means two glyphs
where one is already small; swapping keeps every label in the same place and the
same size. Keys with nothing else to give -- Esc, the function row, Tab, Enter,
the modifiers -- keep their label and their colour, so the blue marks exactly the
keys whose meaning changed.

**Caps is not a modifier and deliberately not one of the modifier slots.** Those
three are mirrored into the window's real modifier state, and `vk_sync_ghost_mods`
reads that state back to correct itself; Caps has no counterpart there, so a bit
for it in the same mask would be one the sync could never find on the other side.
It lives in `VirtualKeyboard::caps`, reaches letters only the way a real Caps Lock
does -- it will not turn 1 into ! -- and does not colour anything, since a capital
is what those caps already read as. It exists because a latched Shift is cleared
by the first character it types, which is right for one capital and useless for a
word of them. It clears when the keyboard closes.

The keys are drawn flat, in one pass. They used to take three -- a dropped shadow,
the cap, then a white wash over the top 45% -- and the palette now carries each
cap with that wash already folded in, so a key reads at the brightness it always
did without the moulded look that nothing else in Blender has.

Modifiers latch. A tap turns one on and it stays on, one, two or three together,
until it is tapped again -- and it is held down rather than sent around each key,
so it reaches touches as well as keys: Shift and a tap extend a selection, Ctrl
and a tap add to one, Ctrl once then NumpadPlus as often as the selection needs.
A **held** key does nothing on purpose; see the study for why the obvious fix was
tried and taken back out.

The sync reads the window's own `eventstate->modifier` rather than remembering
what it sent, because the keyboard is not the only thing that presses a modifier
-- `touchSendShift()` does too -- and a cache could only release what it had
pressed itself. Opening the keyboard releases everything held, which is the way
out if a modifier ever does get stuck.

## Interface defaults for a phone

**The rule the rows below keep running into: anything measured in scale units has
to be measured once, where the scale is held, and the pixels kept.**

The touch menu scale is applied by a scoped guard around the code that lays a menu
out and draws it. Every other path -- an operator's invoke, a region's creation, a
hit test on a release -- runs outside it, where `UI_UNIT_Y`, `UI_SCALE_FAC` and
everything built on them mean something else. The same expression on two sides of
that guard gives two answers, and the failure is never a crash: a row lands at two
thirds the height it was drawn at, a tap picks the item three rows down, a box asks
for a size it will not be given. Four separate defects in this table are that one
mistake. Compute the geometry once inside the guard, store the pixels, and let
everything else read them.

**And a second rule, for regions: a global area is restored from the file, so
`SpaceType.create` is not where you change one.** The window manager writes
`wmWindow.global_areas` (see `wm.cc`, `BKE_screen_area_map_blend_write`), and the
bundled `startup.blend` predates every region this fork adds. `statusbar_create()`
grew a second region and it never ran once: every launch read the old one-region
bar back out of the file, the code looked right, and three builds went by before
anything was measured. Change a global area where a restored one passes as well --
`ED_screen_global_areas_refresh()` and the functions under it -- and keep it
idempotent. Region **order** matters there too: `region_rect_recursive()` forces the
last region in the list to `RGN_ALIGN_NONE`, so the aligned one cannot be last.

**And a third: `scale_y` on a layout reaches every item added while that layout is open, artwork
included.** A picture added with `uiDefButImage()` looks like it is placed at its own size -- the
call takes the bitmap's width and height -- but if a layout is open it is a layout item like any
other, and a vertical scale stretches it. That is how raising the row pitch in the About box came
out as a Blender logo squeezed narrow: the splash gets away with scaling its outer layout only
because its artwork is created *before* `block_layout()` is called, and the About box's logo is
created after. Put the scale on an inner layout that holds no artwork, or create the artwork
first. The general form: a scale applies to a scope, so check what else is in the scope.

| Change | Where |
| --- | --- |
| The status bar is two header regions, not one: the on-screen keyboard button alone in a left-aligned region, the hints and figures in the region after it. The bar overflows on a phone and this fork lets a finger drag a header sideways, which used to carry the keyboard button off the left edge -- the one control that has to stay reachable. The button region is the aligned one because #RGN_FLAG_DYNAMIC_SIZE makes a region take the width its content asks for: a button is one button wide, while the figures ask for more than the bar has and squeeze the other side to nothing. It is also **first**, because the last region in the list is forced to `RGN_ALIGN_NONE`. Restored bars get the region added back at refresh time, since `create` never runs for them. Upstream's own spacers stay inside that region, and they are load-bearing twice over: they hold the figures against the right end of the bar, and they keep the figures still. `template_input_status()` draws mouse and modifier hints that exist only while a finger is down, so the row changes width constantly; anchored by their own spacer the hints appear and vanish at the left end and nothing else moves, while packing everything behind one leading spacer instead made the figures jump a hint's width every touch and release, which read as the scroll losing its place mid-drag. `UILayout.alignment = 'RIGHT'` is no substitute -- a header layout is only as wide as its own content, so there is nothing to push against | [space_statusbar.cc](source/blender/editors/space_statusbar/space_statusbar.cc) `statusbar_create()` and `statusbar_header_region_init()`, [screen_edit.cc](source/blender/editors/screen/screen_edit.cc) `screen_global_statusbar_area_ensure_regions()`, [space_statusbar.py](scripts/startup/bl_ui/space_statusbar.py) |
| The "back to previous window" button in the top bar is icon-only upright and carries its label with the phone turned. Upright there is no room for the words beside the menu button, the undo pair and the scene and view layer fields | [space_topbar.py](scripts/startup/bl_ui/space_topbar.py) `_topbar_is_upright()` |
| The splash and the About box are fitted to the window, and their contents scaled with them. Upstream asks for a box 45 em wide and clamps it to a fraction of the window; the clamp moved the box and left the type where it was, so on a phone the splash was drawn at a scale meant for a box a sixth wider than the one it got -- 907 px of type in 756 px of box, rows crowding each other, nothing like the desktop the design came from. The box is now allowed a wider fraction of an upright phone, and where even that is not enough the whole block is scaled down rather than squeezed, so the proportions are always the ones upstream drew. Their **rows** are a separate decision: the block stays out of the menu scale because it is fixed-proportion artwork, but its list is not artwork, and at 1.0 it was the one list in the program drawn tighter than every menu beside it -- 40 px a row against 54 in the top bar. `scale_y` gives the rows the pitch without touching the type, which a scale guard would have enlarged inside a box whose width is already settled, truncating the file names further. The height bound uses a measured constant, because a block's height is not known until it has been laid out | [wm_splash_screen.cc](source/blender/windowmanager/intern/wm_splash_screen.cc) `wm_splash_fit_factor()`, `wm_splash_max_width()`, `wm_block_splash_create()`, `wm_block_about_create()` |
| Action zones are reachable with a finger. Collapsed-panel tabs are drawn and hit-tested at menu scale, and touch edge snapping respects action zones. Side-panel resize strips are widened without taking button taps. Android region action-zone events run immediately after the triggering press, before queued motion/release, and keep that press position; a continuous first drag now resizes instead of merely arming a modal operator. `region_scale_invoke()` and `region_scale_modal()` use the resized region's `ScopedMenuScale` for size limits, pointer conversion, snapping and collapse thresholds, matching layout. Without it, Menu Scale 0.50 made the border move 1.5 times faster than the finger. S24 measurements and limits are in the 2026-10-29 follow-up study | [screen_ops.cc](source/blender/editors/screen/screen_ops.cc) `actionzone_apply()`, `region_scale_invoke()`, `region_scale_modal()`; [area.cc](source/blender/editors/screen/area.cc) `region_azone_tab_plus()`, `region_azone_edge()`; [screen_geometry.cc](source/blender/editors/screen/screen_geometry.cc) `ED_screen_edge_snap_for_touch()`; [ANDROID_TOUCH_UI_SCALE_STUDY.md](ANDROID_TOUCH_UI_SCALE_STUDY.md) |
| An editor border can be grabbed from half again as far away, `BORDERPADDING * 1.5` on Android. Measured on the device: about 13 pixels before, about 19 after, against a fingertip some 8 mm across. Two things worth knowing before changing it. The reach of the border is `BORDERPADDING` and **not** the radius in `ED_screen_edge_snap_for_touch()`, which looks like the touch-specific lever and is not -- raising that from 12 to 16 units changed nothing at 22 pixels out, measured. And the cost is real: content within this distance of a border cannot be tapped, because the press is taken as an edge grab, which is why it is half again rather than double. Unlike the snap, this reach is shared with the stylus and the mouse, which on a phone is wanted -- a stylus misses a 13 pixel target too | [screen_intern.hh](source/blender/editors/screen/screen_intern.hh) `BORDERPADDING` |
| A finger held on a button that has a hold action gets the hold, not the context menu. A tool with variants -- Select Box holding Circle and Lasso, and every tool with the small corner mark -- opens them through `but->hold_func`, and a finger could not reach it: GHOST withholds a touch press until it has moved past the slop and turns a press held still into a **right**-click at `TOUCH_LONG_PRESS_MS`, so no left press ever arrives and the hold timer never starts. Holding a tool opened "Add to Quick Favorites" instead, and the variants had no route at all. The redirect is in the RIGHTMOUSE branch and applies only to a pointer with no tablet data: a stylus tip already sends a left press and reaches the hold the ordinary way, and its side button is a real right-click. The cost, which is the design and not an oversight: on a button that has a hold action a finger can no longer reach the context menu -- one press cannot mean two things -- while the variants are otherwise unreachable and the menu is not | [interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc), the `RIGHTMOUSE` branch of `handle_button_event()`, [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc) `touchLongPressCheck()` |
| A tooltip is measured at the scale it is drawn at. It lives in a `RGN_TYPE_TEMPORARY` region, which `ED_region_uses_menu_scale()` counts as chrome, so it is drawn at the menu scale -- but its box is measured in `tooltip_create_with_data()`, which runs outside any guard: `BLF_size()` from `UI_SCALE_FAC`, then `BLF_width()` per field. The box came out sized for type a third smaller than the type put into it, and the text ran off the right edge. The same mistake as the squeezed context menus and search boxes, in a fourth place | [interface_region_tooltip.cc](source/blender/editors/interface/regions/interface_region_tooltip.cc) `tooltip_create_with_data()` |
| Resolution scale 1.10, editor borders 4 pixels, temporary editors maximized instead of a new window, which Android cannot open | [DNA_userdef_types.h](source/blender/makesdna/DNA_userdef_types.h), [screen_edit.cc](source/blender/editors/screen/screen_edit.cc) |
| Menu chrome is drawn half again as large as the rest of the interface, so a thumb can hit it without spending viewport. Headers, the top bar, the status bar, the Properties tab column, tool bars and every pull-down; editor content is untouched. One preference, "Menu Scale", multiplied by Resolution Scale rather than separate from it. The splash and the About box opt out | [screen_menu_scale.cc](source/blender/editors/screen/screen_menu_scale.cc), [area.cc](source/blender/editors/screen/area.cc), [interface_region_popup.cc](source/blender/editors/interface/regions/interface_region_popup.cc), [wm_splash_screen.cc](source/blender/windowmanager/intern/wm_splash_screen.cc), [ANDROID_TOUCH_UI_SCALE_STUDY.md](ANDROID_TOUCH_UI_SCALE_STUDY.md) |
| "Add Workspace" at the foot of the folded menu, which is the `+` at the end of the desktop tab strip that folding the strip away took with it. It references `WORKSPACE_MT_add` rather than calling `workspace.add`: that operator exists only to pop the same menu up, so calling it from inside a menu would close this one to open that one, while a submenu nests like every other entry | [space_topbar.py](scripts/startup/bl_ui/space_topbar.py) `TOPBAR_MT_touch_menu` |
| The top bar folds into one button in both orientations: the five pull-downs, then the workspaces with the active one depressed, then the Blender menu below Help. Undo and redo sit beside it as buttons, since Ctrl+Z on a phone means opening a keyboard to hold a modifier. `WorkSpace.order` is exposed to RNA so the list keeps tab order rather than alphabetical | [space_topbar.py](scripts/startup/bl_ui/space_topbar.py), [rna_workspace.cc](source/blender/makesrna/intern/rna_workspace.cc), [interface_query.cc](source/blender/editors/interface/interface_query.cc) `button_icon()` for the COLLAPSEMENU/KEY_MENU_FILLED swap |
| A finger can reach the bottom of a menu taller than the screen. Drag anywhere in a popup to pan it, tap the arrow band to step; the band is twice as tall on Android. Covers dialogs too, because every popup shares one handler and the scroll offset lives on the handle | [interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc) `handle_menu_touch_scroll_event()`, [interface_intern.hh](source/blender/editors/interface/interface_intern.hh), [interface_widgets.cc](source/blender/editors/interface/interface_widgets.cc) `draw_clip_tri()` |
| "Save changes before closing?" stacks its buttons in a column upright. The block sets `BLOCK_NO_WIN_CLIP`, so nothing trimmed it to the window and Save was simply drawn off the edge | [wm_files.cc](source/blender/windowmanager/intern/wm_files.cc) |
| The Cycles device panel says what the device is. "None" is the only compute type a phone offers and on its own it reads as "no hardware", so underneath it goes a small table: device, processor, GPU, core count and memory. The device and chip names come from `android.os.Build` through environment variables, because nothing on the Linux side can see them -- no model name in `/proc/cpuinfo` on arm64, and the sysfs and device-tree paths that carry it are closed to apps. Memory is shown three times, because the three figures disagree and none of the disagreements is a mistake: what the phone was sold with, inferred by rounding; the `MemTotal` it was inferred from; and what Blender may actually allocate, which is the only one that decides whether a scene fits. The third is live and comes from the same call the status bar uses, so the two cannot drift apart | [space_userpref.py](scripts/startup/bl_ui/space_userpref.py) `_device_hardware_groups()`, [BlenderActivity.java](build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java) `publishHardwareNames()` |
| A search popup is sized to the room left for it and lifted clear of the on-screen keyboard. Both halves are needed: the height decides how many rows there can be, the lift decides where they land. `SEARCH_ITEMS` was a fixed ten and the row height is the box divided by that count, so a short window gave ten unreadable rows rather than a few readable ones; the count now comes from the height, floored at two, and `SearchItems::maxitem` is set to match, which is what keeps `totitem` from ever running past the rows there is room to draw. Two things eat the room and both are counted: the keyboard, and the window itself -- Blender in Android's split screen has half the height and no keyboard to blame. The **floor wins over the fit**: the search field stays whole even when that means the popup reaches the keyboard again, because a search you cannot type into is worse than one whose last row is covered | [interface_region_search.cc](source/blender/editors/interface/regions/interface_region_search.cc) `searchbox_rows_for_height()` and `uiSearchboxData::rows`, [wm_operators.cc](source/blender/windowmanager/intern/wm_operators.cc) `wm_search_menu_invoke()`, [interface_region_popup.cc](source/blender/editors/interface/regions/interface_region_popup.cc) `popup_block_refresh()` |
| The count is settled in the **layout**, which then re-gathers, rather than estimated at creation. The order is creation, first gather, layout, draw: a count settled in the layout alone arrives one step too late, so the gather had already filled ten items into a box with room for six and the four extra drew below it -- and healed themselves the moment anything scrolled and forced a second gather. Estimating the box at creation instead came out short by a row or two, because the height the popup asks for and the box the region ends up with are separated by a chain of margins that do not cancel. Measuring where the answer is certain and simply gathering again costs one extra pass as the box opens | [interface_region_search.cc](source/blender/editors/interface/regions/interface_region_search.cc) `searchbox_region_layout_fn()` |
| Row height and the end bands are settled there too and kept as pixels on `uiSearchboxData`, because `searchbox_butrect()` is called from both sides of the menu scale -- the draw holds it, the hit test on a release does not -- and both `UI_UNIT_Y` and `UI_SEARCHBOX_TRIA_H` move with it. Recomputing them at hit-test time measured rows at less than half the height they were drawn at, so **a tap landed three rows below the one it was aimed at** | [interface_region_search.cc](source/blender/editors/interface/regions/interface_region_search.cc) `uiSearchboxData::row_h` |
| Rows sit at their natural height, top aligned, rather than stretched to fill the box. The popup paints its background from the block's own height while the bbox comes from the region around it, and dividing the box by the count spread that difference into the rows until the last one hung below the background behind it. Slack stays empty at the bottom | [interface_region_search.cc](source/blender/editors/interface/regions/interface_region_search.cc) `searchbox_butrect()` |
| A search box on a field in a panel -- an IK constraint's Target, a data-block picker -- **picks the side of the field with room and takes its height from that side's room**. It is anchored to one edge of the field and grows away from it, and is never moved across it. That last part is the design and not a detail: a box placed first and then slid vertically to fit the screen can end up over the very field that opened it, and then the press that opens it lands on the box instead -- the list appears and vanishes in the same instant and the field cannot be used at all. Only two of the four edges were watched before, the right and the bottom, the latter through a flip that moves the box above the field when nothing fits beneath it. Nothing watched the top, and the window height was not even read: the line fetching it sat commented out as unused, which is how a field near the top of the Properties editor flipped upwards and ran its rows off the ceiling. Shrink rather than clamp, in whole rows, or the rows are squeezed back to the heights the row count exists to avoid; sideways is the only axis it is still moved on. **Android's own keyboard is outside all of this**: the port is a `NativeActivity` and the platform IME's insets never reach this window, so nothing in Blender knows the system keyboard is up and a list opening downwards while it shows can still land behind it. Reaching it would mean reading the insets on the Java side and publishing them the way the device names already are | [interface_region_search.cc](source/blender/editors/interface/regions/interface_region_search.cc) `searchbox_region_layout_fn()`, the `else` branch |
| Where the keyboard is, for whatever has to keep out of its way. Read rather than cached, because the panel can be slid up its band | [wm_virtual_keyboard.cc](source/blender/windowmanager/intern/wm_virtual_keyboard.cc) `WM_virtual_keyboard_rect_get()` |
| A finger, a stylus or a held mouse button scrolls the search results by dragging them, and the wheel still steps as it did. It moves `items.offset` by hand rather than going through `searchbox_select()`, which steps the *highlight* and only shifts the list once that highlight has run into an end: driving a drag through it made the selection race down a list that sat still and then lurched. Movement is accumulated **between one motion event and the next**, never measured from the press -- `prev_press_xy` can still hold the previous press when the first motion of a new one arrives, and a distance measured from there is applied in a single jump. Content follows the hand, same sign as the pull-downs | [interface_region_search.cc](source/blender/editors/interface/regions/interface_region_search.cc) `searchbox_touch_scroll()` |
| The drag is armed by a press inside the results and disarmed by the release, **wherever that release lands**. Asking the event which button was pressed last does not work: `prev_press_type` names the last press there ever was, so after any click a mouse merely crossing the list or a stylus merely hovering over it scrolled as though it were dragging. A finger never showed it, because a finger between taps generates no motion at all | [interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc), [interface_region_search.cc](source/blender/editors/interface/regions/interface_region_search.cc) `searchbox_drag_press()` and `searchbox_drag_consume_release()` |
| The release that ends a drag lets go of the list rather than choosing from it, and a tap applies **what was pressed** rather than what is highlighted. A pointer drags the highlight along with it and arrives on the right row; a finger and a stylus land and let go with no motion in between, so a tap used to apply whatever the last arrow key had selected. Arrow keys and Return are untouched -- for them the highlight *is* the choice. The drag threshold is half a row rather than `WM_event_drag_threshold`, because a finger always wobbles on the way down and a wobble that counted as a drag ate the release, leaving the tap choosing nothing at all. A release on no row at all takes nothing rather than the stale highlight | [interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc), [interface_region_search.cc](source/blender/editors/interface/regions/interface_region_search.cc) `searchbox_select_at()` |
| Search boxes hold the menu scale too, and in two places, because they are the one piece of menu chrome not built inside `popup_block_refresh()`. The results are a temporary region of their own, laid out and drawn by its own callbacks with no scale applied, so `searchbox_size_y()` -- `SEARCH_ITEMS * UI_UNIT_Y` -- measured the unscaled widget unit. And the F3 menu search takes its block size from the operator's invoke, which also ran outside any scale. The row count is fixed, so an unscaled height divided by ten put the rows at two thirds of the text drawn in them: the same squeeze and the same 1.45 ratio as the context menus below | [interface_region_search.cc](source/blender/editors/interface/regions/interface_region_search.cc) `searchbox_region_layout_fn()` and `searchbox_region_draw_fn()`, [wm_operators.cc](source/blender/windowmanager/intern/wm_operators.cc) `wm_search_menu_invoke()` |
| Menus built between `popup_menu_begin()` and `popup_menu_end()` -- button and header context menus -- hold the menu scale for as long as the caller is adding items. They are built during event handling rather than inside `popup_block_refresh()`, so their rows came out at the unscaled widget unit inside a popup drawn at the scaled one | [interface_region_menu_popup.cc](source/blender/editors/interface/regions/interface_region_menu_popup.cc) |
| Viewport texture limit defaults to 1024 rather than unlimited | [DNA_userdef_types.h](source/blender/makesdna/DNA_userdef_types.h), [gpu_capabilities.cc](source/blender/gpu/intern/gpu_capabilities.cc) |
| Node editor keymaps stay ahead of the generic View2D one, so box select, link dragging and node moving survive drag to scroll | [space_node.cc](source/blender/editors/space_node/space_node.cc) |
| Splash artwork and launcher icon | [splash.png](release/datafiles/splash.png), [ic_launcher.xml](build_files/android/apk/app/src/main/res/drawable/ic_launcher.xml), [ic_splash_logo.xml](build_files/android/apk/app/src/main/res/drawable/ic_splash_logo.xml) |

## GPU and memory

| Change | Where |
| --- | --- |
| Beta 2 selectively backports 18 fixes from Blender's 5.3 release branch through 2026-10-29, keeping the complete-sync anchor at `fefcb557`. Fixes cover static-viewport pipeline caching, clip-distance emulation, buffer alignment and copying, safe texture-pool teardown, builtin shaders, File/Asset Browser switching, startup Python GPU access and CPU memory bounds. The larger Vulkan resource-reference rewrite is deliberately deferred to preserve the render-pass fallback's framebuffer retirement rules. Native canary tests reproduce the path overflows before the update and pass after it; startup GPU drawing and File/Asset Browser transitions also pass on the S24 Ultra | [ANDROID_UPSTREAM_BETA2_STUDY.md](ANDROID_UPSTREAM_BETA2_STUDY.md), [upstream_regressions.py](build_files/android/tests/upstream_regressions.py) |
| Android initializes the window background to opaque `TH_EDITOR_BORDER` before composing regions on every redraw. Region blits and antialiased borders do not cover every pixel: the small gap below the top bar can otherwise expose undefined Vulkan back-buffer contents. Tested on the S24 Ultra at startup, in both orientations, after resizing horizontal/vertical editor boundaries and after background/resume. The original intermittent blue/magenta symptom did not reproduce in the baseline session, so the study distinguishes corrected pixel coverage from proof that every occurrence is resolved | [wm_draw.cc](source/blender/windowmanager/intern/wm_draw.cc) `wm_draw_window_onscreen()`, [ANDROID_EDITOR_BORDER_GLITCH_STUDY.md](ANDROID_EDITOR_BORDER_GLITCH_STUDY.md) |
| The graphics memory figure counts only what Blender can allocate. It summed the size of every device-local heap, which on a phone means two mistakes at once: the first heap is all of system memory, shared with Android, and the second is a protected heap for DRM content that Blender can never allocate from. Measured on an Adreno 750: 11084 MiB + 4095 MiB, reported as "VRAM: 14.8 GiB" on a phone sold with 12 GB. Heaps reachable only through `VK_MEMORY_PROPERTY_PROTECTED_BIT` types are skipped, and the figure is `VmaBudget::budget` -- what the driver will actually promise this process -- rather than the raw heap size. Reads 8.7 GiB there now. Exposed to Python as `gpu.capabilities.memory_statistics_get()` so the Cycles device panel shows the same number as the status bar by construction | [vk_device.cc](source/blender/gpu/vulkan/vk_device.cc) `memory_statistics_get()` and `memory_heap_is_allocatable()`, [gpu_py_capabilities.cc](source/blender/python/gpu/gpu_py_capabilities.cc), [space_userpref.py](scripts/startup/bl_ui/space_userpref.py) `_device_memory_available()` |
| Qualcomm is asked for SPIR-V 1.3 whatever version it reports supporting. Its compiler refuses compute modules emitted as 1.5, which are the ones EEVEE uses for shadows and light culling | [vk_shader_compiler.cc](source/blender/gpu/vulkan/vk_shader_compiler.cc) |
| GPU subdivision falls back to the CPU when the driver refuses the compute pipeline, instead of handing back empty buffers | [subdiv_modifier.cc](source/blender/blenkernel/intern/subdiv_modifier.cc), [GPU_capabilities.hh](source/blender/gpu/GPU_capabilities.hh), [draw_cache_impl_subdivision.cc](source/blender/draw/intern/draw_cache_impl_subdivision.cc) |
| EEVEE shadow pool capped at 64 MB on Android regardless of system RAM, because the constraint is the GPU budget a mobile part shares with the device | [eevee_shadow.cc](source/blender/draw/engines/eevee/eevee_shadow.cc) |
| GPU workarounds are no longer forced at startup. The flag skipped feature detection and left the Qualcomm tile memory extension off, worth 25% of the frame while orbiting | [GHOST_AndroidMain.cc](intern/ghost/intern/GHOST_AndroidMain.cc) |

## Features and dependencies

| Feature | Where it was turned on |
| --- | --- |
| Open Image Denoise 2.5.0 | [android_features_full.cmake](build_files/android/android_features_full.cmake), [deps/build.sh](build_files/android/deps/build.sh), [platform_android.cmake](build_files/cmake/platform/platform_android.cmake) |
| Fluid simulation, Manifold boolean solver, motion tracking, PDF export, Ocean modifier, path guiding | [android_features_full.cmake](build_files/android/android_features_full.cmake), [deps/build.sh](build_files/android/deps/build.sh) |
| Native audio output in the `full` build. Audaspace was already compiled but had no device capable of sending its mix to Android; `AAudioDevice` now registers as a static Android-only backend with the highest device priority and links the NDK's platform `libaaudio.so`, so it needs neither a dependency recipe nor a feature option. AAudio exists since API 26 and this port already requires API 31, so no runtime fallback is needed. Its callback mixes directly into the shared output stream, writes silence while stopped, accepts 16-bit PCM or falls back to 32-bit float, and records the rate, channel count and format AAudio actually opened so sound does not play at the wrong pitch. The non-low-latency performance mode is deliberate: Blender mixes arbitrary sources and effects, and a slightly larger buffer is safer than gaps from missing a real-time deadline. Route changes such as unplugging headphones or connecting Bluetooth reach an error callback that deliberately does no recovery work because AAudio forbids closing or reopening a stream there; automatic recovery is not implemented, so output remains stopped until Blender recreates the device. The `lite` build still sets `WITH_AUDASPACE=OFF` | [CMakeLists.txt](extern/audaspace/CMakeLists.txt), [AAudioDevice.h](extern/audaspace/plugins/aaudio/AAudioDevice.h), [AAudioDevice.cpp](extern/audaspace/plugins/aaudio/AAudioDevice.cpp) `AAudioDevice()`, `mix_callback()`, `playing()`, `error_callback()` and `AAudioDeviceFactory::getPriority()`, [android_features_lite.cmake](build_files/android/android_features_lite.cmake) |
| Exact boolean solver, through GMP | [deps/build.sh](build_files/android/deps/build.sh), [platform_android.cmake](build_files/cmake/platform/platform_android.cmake) |
| Draco compressed glTF | [deps/build.sh](build_files/android/deps/build.sh), [package.sh](build_files/android/apk/package.sh) |
| Internet access: the permission, a bundled certificate store, and an interpreter the extension system can run | [AndroidManifest.xml](build_files/android/apk/app/src/main/AndroidManifest.xml), [BlenderActivity.java](build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java), [python/intern/CMakeLists.txt](source/blender/python/intern/CMakeLists.txt), [deps/build.sh](build_files/android/deps/build.sh) |
| pip | [deps/build.sh](build_files/android/deps/build.sh) |
| Remote asset libraries, including Online Essentials, are switched **off**. They cannot work: the listing downloader is built on `multiprocessing` with the 'spawn' start method, and `_multiprocessing` is not in this Python -- CPython refuses to build it without `sem_open`, which Bionic does not have (`ac_cv_func_sem_open=no`, `MODULE__MULTIPROCESSING_STATE=missing` in the CPython build). Even built it would fail at run time for the same reason, and 'spawn' re-runs `sys.executable`, which does not exist when Blender is a library inside a NativeActivity. Left alone the failure surfaced three steps from its cause, as "file does not exist: `_asset-library-meta.json`", because the C++ caller still carries a "TODO: report errors in the UI somehow". This is separate from the extension system, which does its own networking and works | [AS_remote_library.hh](source/blender/asset_system/AS_remote_library.hh) `remote_libraries_supported()`, [remote_library.cc](source/blender/asset_system/intern/library_types/remote_library.cc), [asset_library.cc](source/blender/asset_system/intern/asset_library.cc), [asset_library_service.cc](source/blender/asset_system/intern/asset_library_service.cc), [userpref_asset_libraries_list.cc](source/blender/editors/space_userpref/userpref_asset_libraries_list.cc), [bl_pkg/__init__.py](scripts/addons_core/bl_pkg/__init__.py) `remote_asset_library_sync()` |
| Essentials assets, 49 translations, USD plugins | [package.sh](build_files/android/apk/package.sh), [GHOST_SystemPathsAndroid.cc](intern/ghost/intern/GHOST_SystemPathsAndroid.cc) |
| Remote asset libraries, Online Essentials included -- where the default geometry, materials and node groups come from; the bundled `assets/` holds only brushes and node groups, the same in 5.2 and 5.3. The downloader runs on a thread on Android (`_ThreadContext`: no `_multiprocessing`, nothing to spawn), and requests, urllib3, idna, charset_normalizer, attrs and cattrs are bundled as pure-Python wheels. Downloads only with Online Access allowed | [downloader.py](scripts/modules/_bpy_internal/http/downloader.py), [AS_remote_library.hh](source/blender/asset_system/AS_remote_library.hh) `remote_libraries_supported()`, [deps/build.sh](build_files/android/deps/build.sh) `build_remote_asset_python_deps` |

## Opening files from the system

A `.blend` tapped in a file manager opens in Blender -- from Samsung's My Files
without even offering a chooser, because nothing else on the device matches.

Three filters, and none of them is redundant: what a file manager hands over
varies in both of the things a filter can match on. Two of the three were written
after a build that looked correct and did not work, so read the whole table before
deciding one of them is dead weight. The last row of the three carries a
deliberate cost, stated there.

| Change | Where |
| --- | --- |
| The first filter, matching on the file name rather than the MIME type: there is no registered type for `.blend` and an app cannot add one, so a document provider reports `application/octet-stream`. `android:host="*"` is load-bearing and not decoration -- `IntentFilter.matchData` only reaches the path patterns in the branch it takes when the filter declares an authority, so a filter without a host never checks the suffix and matches every URI of its scheme. A `file://` URI has no authority at all and `AuthorityEntry.match()` rejects a null host, so that scheme can only be all-files or no-files; it is therefore not declared, and nothing is lost because an app handing a `file://` URI to another app has thrown `FileUriExposedException` since API 24. `pathSuffix` rather than `pathPattern` because `PatternMatcher` does not backtrack over `.*` | [AndroidManifest.xml](build_files/android/apk/app/src/main/AndroidManifest.xml) |
| A second filter of the same shape with **no** `mimeType`, which is not a duplicate. A filter that declares a type matches only an intent that carries one: `matchData` answers `NO_MATCH_TYPE` both for a null type against a typed filter and for a typed intent against an untyped filter, so the two cases need two filters. The untyped one is the common case -- a file manager builds the type from `MimeTypeMap`, which has no entry for `.blend`, and sends the URI with no type at all. Without it Samsung's My Files answered "You don't have any apps that can open this type of file" while `adb`, which was passing a type, resolved to Blender perfectly well | [AndroidManifest.xml](build_files/android/apk/app/src/main/AndroidManifest.xml) |
| A third filter for MediaStore, `host="media"` with `pathPrefix` on the non-media collections and no suffix at all, because a MediaStore URI names a row by number: the same file that a document provider spells `.../document/primary:Download/Astronaut/Astronaut_v003.blend` arrives as `content://media/external/file/1000109705`. Nothing in it to match a suffix against. This is not an edge case, it is what Samsung's My Files sends, and it is why tapping a `.blend` there answered "You don't have any apps that can open this type of file" while every document-provider check resolved. `mimeType="*/*"` is forced: My Files sends the type as the **empty string**, which `findMimeType()` answers only through its "matches every type" branch, and which no manifest can declare literally -- an untyped filter does not match it either, since `""` is not the same as absent. **The deliberate cost:** with neither the name nor the type able to narrow it, only the collection can, so any non-media file opened through a MediaStore URI now lists Blender -- `.zip`, `.txt`, `.pdf`. Images, video and audio never do, and `.obj`, `.fbx`, `.gltf`, `.stl`, `.abc` and `.usd` land in that same collection for the same reason `.blend` does, so some of the breadth is earned | [AndroidManifest.xml](build_files/android/apk/app/src/main/AndroidManifest.xml) |
| Preferences has no "Operating System Settings" panel. Android reports as `linux`, so the panel offered the freedesktop path, which shells out to `xdg-mime` -- a program that does not exist here and has no per-user MIME database to write to, so Register could only ever report an error. Nothing is missing: the association is an intent filter fixed at build time, which no app can register or unregister at runtime. Gated on `sys.getandroidapilevel`, CPython's own marker, present only on an Android build of the interpreter | [space_userpref.py](scripts/startup/bl_ui/space_userpref.py) `USERPREF_PT_system_os_settings.poll()` |
| `launchMode="singleTask"`, so a second tap reaches `onNewIntent` in the running instance. This is a `NativeActivity`: a second instance runs `ANativeActivity_onCreate` again and starts a second `android_main` and a second Blender init inside the one process | [AndroidManifest.xml](build_files/android/apk/app/src/main/AndroidManifest.xml) |
| Turning a `content://` URI back into a path, in five rungs: the `file` scheme, the storage provider's document id, `MediaStore.DATA`, `readlink` on `/proc/self/fd/N` for the descriptor the provider hands back, and a copy into the cache when nothing else names a real file. Blender opens by path and never by stream, and a `.blend` opened from a copy loses the relative paths to its textures and linked libraries. Each rung accepts its answer only if `isFile() && canRead()`, which is also what covers the first launch from a file manager: all-files access is only requested after `onCreate()`, so every direct rung fails and the copy is taken instead of erroring | [BlenderActivity.java](build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java) `resolveUriToPath()` |
| Cold start passes the path as a launch argument, through `BLENDER_ANDROID_OPEN_FILE` set before `super.onCreate()`. Blender's own fall-through argument handler opens it, the same route a double-clicked file takes into `argv[1]` on macOS. Not the event below, because that would load the startup file and then replace it: a visible double load and a prompt about discarding an empty scene | [BlenderActivity.java](build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java) `publishLaunchFile()`, [GHOST_AndroidMain.cc](intern/ghost/intern/GHOST_AndroidMain.cc) |
| Warm start queues the path on the mutex the soft keyboard already uses and turns it into `GHOST_kEventOpenMainFile` in `processEvents()`. That event is not Cocoa-only: its handler in `wm_window.cc` carries no platform macro and calls `WM_OT_open_mainfile`, so the unsaved-changes prompt and the recent files list behave as everywhere else | [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc) `handleOpenMainFile()` and `drainJavaInput()`, [GHOST_AndroidMain.cc](intern/ghost/intern/GHOST_AndroidMain.cc) |

Deliberately not done: no `ACTION_SEND` filter, because a share intent carries no
path to match on, and a `*/*` one would put Blender in the share sheet of every
file on the device -- including the images, video and audio that the MediaStore
filter above is shaped to avoid.

Still not reached: the downloads document provider, whose ids are opaque
(`content://com.android.providers.downloads.documents/document/msf:1000000123`).
It is a different authority from MediaStore, so the collection trick does not
apply, and there is nothing else in the URI to match. A file manager browsing the
same file through storage or MediaStore opens it.

If you are about to add a filter here, measure first, and measure the *negative*
case. Two rounds of this were built against `adb` intents that no file manager
sends: `adb` passes a MIME type unless told not to, and it addresses files through
the storage document provider, which is the one shape where the name survives in
the URI. `ANDROID_FILE_ASSOCIATION_STUDY.md` has the query-activities calls that
reproduce each failure from the shell.

## Links and the browser

| Change | Where |
| --- | --- |
| Links open in the device's browser. Every link in the program -- the splash, the About box, "Online Manual" on a property's context menu, the manual and community buttons in Preferences -- ends at `wm.url_open`, which calls Python's `webbrowser.open()`. That module builds its browser list by hunting for `xdg-open`, `gio` and `x-www-browser` with `shutil.which()`; Android has none of them, so the list came out empty and `open()` returned False. **No exception, no report, no log line** -- every link in Blender did nothing at all, silently, which is why this reads as a dead button rather than a missing feature | [bl_android_browser.py](scripts/startup/bl_android_browser.py) |
| The fix is registered with `webbrowser` rather than wired into `wm.url_open`, so add-ons and the pre-filled bug report in `url_prefill_startup` reach it too, and the upstream operator is left alone. `sys.getandroidapilevel` gates it, and the registration is skipped if it already ran, since reloading scripts would otherwise stack copies in `_tryorder` | [bl_android_browser.py](scripts/startup/bl_android_browser.py) `register()` |
| The work itself: a native operator that hands the URL to an `ACTION_VIEW` intent over JNI. It **reports an error when the intent is refused**, which matters more than it looks -- the failure it replaces was completely silent, and a link that fails loudly is a bug report instead of a shrug | [wm_operators.cc](source/blender/windowmanager/intern/wm_operators.cc) `WM_OT_platform_url_open`, [GHOST_SystemAndroid.cc](intern/ghost/intern/GHOST_SystemAndroid.cc) `GHOST_android_open_url()`, [BlenderActivity.java](build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java) `openUrl()` |
| `GHOST_android_open_url` is declared at its use site rather than in a header, because the window manager cannot include GHOST's private headers. `creator.cc` reaches `GHOST_HACK_getFirstFile` the same way on macOS | [wm_operators.cc](source/blender/windowmanager/intern/wm_operators.cc) |

## Bug fixes

| Fix | Where |
| --- | --- |
| Out of bounds write when a label trims away to nothing, which killed the process the moment the 2D Animation or Storyboarding template opened in portrait. Not Android specific | [interface_widgets.cc](source/blender/editors/interface/interface_widgets.cc), `text_clip_middle_ex()` |
| Widgets in modifier panels needed several taps and the drop-down never opened. The Property Editor keymap bound `object.modifier_set_active` to a press, which consumed the press the click was waiting on | [blender_default.py](scripts/presets/keyconfig/keymap_data/blender_default.py) |
| "Reset to Default Value" disagreed with the value a fresh install starts on, because RNA defaults are baked in by a host tool that never sees `__ANDROID__` | [rna_userdef.cc](source/blender/makesrna/intern/rna_userdef.cc), [DNA_userdef_types.h](source/blender/makesdna/DNA_userdef_types.h) |
| The device kept running a payload it had unpacked weeks earlier | [package.sh](build_files/android/apk/package.sh), [BlenderActivity.java](build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java) |
| The extension system child interpreter died before running a line, because isolated mode ignored the environment set for it | [BlenderActivity.java](build_files/android/apk/app/src/main/java/org/blender/blender/BlenderActivity.java) |
| glog selecting stack traces that do not compile below API 33 | [config_linux.h](extern/glog/src/config_linux.h) |

## Where else to look

| Document | Contents |
| --- | --- |
| [ANDROID_UPSTREAM_BETA2_STUDY.md](ANDROID_UPSTREAM_BETA2_STUDY.md) | The 18 upstream stability patches selected for Beta 2, the deferred Vulkan rewrite and device regression results |
| [ANDROID_EDITOR_BORDER_GLITCH_STUDY.md](ANDROID_EDITOR_BORDER_GLITCH_STUDY.md) | Beta 2 editor separator background initialization, pixel measurements and S24 validation limits |
| [ANDROID_CHANGELOG.md](ANDROID_CHANGELOG.md) | Every change with the commit that made it, as features, adjustments and fixes |
| [ANDROID_WHATS_NEW.md](ANDROID_WHATS_NEW.md) | The same in plain language, one row per change |
| [ANDROID_BUILD_GUIDE.md](ANDROID_BUILD_GUIDE.md) | The long form build walkthrough, step by step |
| [build_files/android/BUILDING.md](build_files/android/BUILDING.md) | Building from scratch, including the manual steps `build.py` wraps |
| [ANDROID_UPSTREAM.md](ANDROID_UPSTREAM.md) | Which upstream Blender this tracks, how the anchor was found, how the 5.3 beta sync was merged and its conflicts resolved, and how to do the next one |
| [ANDROID_MISSING_FEATURES.md](ANDROID_MISSING_FEATURES.md) | What is still missing, audited against the real build |
| [ANDROID_VIRTUAL_KEYBOARD_STUDY.md](ANDROID_VIRTUAL_KEYBOARD_STUDY.md) | Why the on-screen keyboard is native, and the event path it relies on |
| [ANDROID_TOUCH_UI_SCALE_STUDY.md](ANDROID_TOUCH_UI_SCALE_STUDY.md) | How only the menus are scaled for a thumb, how the top bar folds into one button, and how a finger scrolls a menu taller than the screen. All built |
| [ANDROID_FILE_ASSOCIATION_STUDY.md](ANDROID_FILE_ASSOCIATION_STUDY.md) | How a `.blend` tapped in a file manager reaches this port: the intent filter and why `android:host` decides whether the suffix is checked at all, the five-rung URI-to-path resolver, and the argv and GHOST-event halves. All built |
| [.claude/skills/android-document-change/SKILL.md](.claude/skills/android-document-change/SKILL.md) | How to add to these documents when something is built, fixed or taken back out, and why the taken-back-out ones matter most |

## Known gaps

One, as of the last audit:

- **OSL.** Needs a second host toolchain to generate shader bitcode.

## Working habits that paid off

Written down because each one was learned by losing time to its absence.

- Verify on the device before committing. A build that compiles has proved nothing.
- **A held finger can be injected, but read the screen before believing it did
  nothing.** A zero-distance `adb shell input swipe` does reach GHOST as a press
  held still, and does fire the long press. It first looked as though it did not:
  two runs showed only the hover tooltip and no hold menu, which was written down
  here as a limit of injection and was wrong. The tooltip had opened over the
  button and was what the screenshot caught. What the tool cannot do is tell you
  *when* to look -- the tooltip arrives around 200 ms and the hold at 500 ms, so a
  screenshot has to be aimed at the moment being tested, and one taken at the
  wrong instant reads exactly like a feature that does not work.
- One hypothesis at a time, and instrument rather than guess after the first miss.
  The search box cost five rounds of guessing at how touch arrives -- a row count
  settled too late, `prev_press_type` read as "a button is down now", a highlight
  assumed to be under the finger, a hit test measured outside the scale it was
  drawn in. None was visible in the code and every one showed up in the first
  minute of somebody using it. After the first miss, print what actually arrives.
- **Measure once, where the scale is held.** See the note above the interface
  defaults table; four defects in it are that single mistake.
- The word "sometimes" in a report is an instruction to stop reasoning. Intermittent
  means a threshold or an ordering, and neither yields to reading the code.
- "Cannot reproduce" is a result. It locates the trigger in a condition not yet set.
- When a change seems to have no effect, check the two payload traps before re-reading any code.
- Measure the real input. A synthetic swipe and a human finger are not the same gesture, and the difference is where the bug usually is.
