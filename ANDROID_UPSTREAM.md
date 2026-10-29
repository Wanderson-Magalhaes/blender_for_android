# Upstream tracking

What this fork has taken from upstream Blender, and from where. The
**android-upstream-sync** skill is the procedure; this file is its bookkeeping,
because nothing in a snapshot-seeded history records it otherwise.

## Current state

| | |
| --- | --- |
| Tracking | `blender-v5.3-release` (5.3 **beta**), not `main` |
| Last synced upstream commit | `fefcb557` "Fix: UI: Crash when interacting with menus after losing focus" (2026-10-14) |
| Synthetic parent in history | `b28ade62` = that tree minus `tests/files` |
| Original anchor | `b73c4e89` "Fix: IME positioning in the sequencer applied aspect twice" (2026-07-30) |
| File version after sync | 5.3 beta, subversion 29 |

## Selective Beta 2 stability backports (2026-10-29)

Reviewed `blender-v5.3-release` through `fb11a08147140eac42dcee76eed70ff59a7fcd8f`,
377 commits after the last full sync. Applied 18 focused fixes for Vulkan pipelines,
buffer alignment/copies, resource teardown without an active context, builtin shaders,
File/Asset Browser switching, startup Python GPU access, and memory bounds in paths,
text, animation, RNA and EXR handling. This is not a full sync: retain `fefcb557` and
`b28ade62` as the complete-sync anchors for a future merge.

Every included upstream SHA, exclusions and validation results are recorded in
[ANDROID_UPSTREAM_BETA2_STUDY.md](ANDROID_UPSTREAM_BETA2_STUDY.md). The resource
reference-counting rewrite (`da78405cd`) and dependent image-view caching fix
(`3e9bfb97c`) are deferred for a separate review of the Android render-pass fallback.
The separate depth/stencil feature fix (`b756b72bf`) is already implemented by the port.
No dependency, DNA or file subversion change was made. `5dce8c3b7`

## How the anchor was found

The history starts at `897d654 Initial commit`, a snapshot with no parent, so
there is no merge base with anything. The anchor was recovered by comparing trees,
not by trusting the version header:

1. Upstream `main` and `blender-v5.3-release` were fetched with
   `--filter=blob:none --shallow-since=2026-06-15` (trees only, seconds).
2. Every upstream commit from 2026-07-27 to 2026-08-03 (131 of them) was diffed
   against `897d654` by name only, excluding `tests/files` and `lib/`, which this
   fork does not carry.
3. `b73c4e89` (2026-07-30 08:34) gave the smallest difference: **236 files**, all
   of them simfeo's port or this fork's own changes. Its neighbours gave 237-238.
   The core directories (`blenkernel`, `blenlib`, `makesdna`, `nodes`, `geometry`,
   `blenloader`, `makesrna`) differ in only 8 files, all build-system or port
   changes (`BLI_subprocess.hh`, `BLI_mmap.cc`, `system.cc`, the DNA/RNA
   `CMakeLists.txt`, the RNA cleanup scripts).

This also explains the subversion puzzle the skill flagged: the anchor is
5.3 alpha subversion **10**, and this fork's **14** was bumped by hand for its own
preferences versioning (menu scale, stylus pressure). See "Known consequences".

## How the 5.3 beta sync was done (2026-10-14)

`git cherry-pick` of 2,024 commits was not practical, so the sync is a real
three-way merge against the anchor:

```bash
# Synthetic commits: the anchor and the upstream tip, both without tests/files
# (LFS test data on projects.blender.org, refused by its upload-pack).
A2=<anchor tree without tests/files>          # 2a46ee30
U2=<5.3 tip tree without tests/files, parent A2>  # b28ade62
git replace --graft 897d654 $A2               # local only, gives the merge a base
GIT_LFS_SKIP_SMUDGE=1 git merge --no-ff upstream-5.3-synthetic
```

The merge commit has `U2` as its second parent, so **the next sync needs no graft
and no anchor search**: its merge base is `U2`. Make `U3` the same way (the new
upstream tip minus `tests/files`, with `U2` as its parent) and merge it.

`GIT_LFS_SKIP_SMUDGE=1` because upstream's assets are LFS pointers. The nine LFS
files the merge changed were then fetched from upstream's LFS server:

```bash
git lfs fetch upstream upstream-5.3-synthetic --include="<the 9 paths>"
git lfs checkout <the 9 paths>
```

Check for pointer text left on disk after any future sync: a `.blend` under
300 bytes that starts with `version https://git-lfs` is a pointer, not a file.

## Conflict resolutions (39 files)

Resolved toward the fork's intent with upstream's change inside it.

| Area | Resolution |
| --- | --- |
| Vulkan device setup (`GHOST_ContextVK.cc`, `vk_backend.cc`, `vk_device.*`) | Upstream's 5.3 rework for Vulkan 1.1 devices (`e3a49cdeb`) supersedes most of what the fork had done by hand and was taken. **Kept on top**: dynamic rendering stays optional with the classic render-pass fallback (upstream requires it), including detection through 1.3 core; `separateDepthStencilLayouts` enabled when its extension is; `preTransform` IDENTITY for Android rotation; composite alpha chosen from what the surface offers (Turnip), merged with upstream's new `use_alpha`; the Android surface extension. The fork's `logic_ops` flag was dropped: 5.3 no longer enables logic ops anywhere. |
| SPIR-V target (`vk_shader_compiler.cc`) | Upstream's rule (SPIR-V 1.4 when the device has it) plus the fork's: Qualcomm always gets SPIR-V 1.3. The disk cache key follows the same choice. |
| Semaphore wait (`vk_device_submission.cc`) | The fork's sliced wait that turns a wedged GPU into a lost device, calling upstream's `vkWaitSemaphoresKHR`. |
| Qualcomm EEVEE shadows | Upstream's fix (`e271ab38b`, static viewport/scissor) taken alongside the fork's render-pass fallback in `vk_command_buffer_wrapper`. |
| `but_drag_init` | Both guards: the fork's release check and upstream's timer check (#161044). |
| `area.cc` IME drawing | Upstream's new IME overlay, inside the fork's menu-scale scope. |
| Asset library preferences | Upstream moved the settings to `custom_asset_library_list_ui.cc`; the fork's `remote_libraries_supported()` gate was re-applied there. |
| Keymap | The fork's CLICK-for-touch on strip modifiers, extended to upstream's new compositor effects list. |
| Overlay grid shader | Upstream's zero-step discard plus the fork's explicit component selection for Adreno. |
| EEVEE sphere probe group size | Upstream's `constexpr` form with the fork's 16 (and the loop counts in `eevee_lightprobe_sphere_bake.bsl.hh` still at 8). |
| `DNA_userdef_types.h`, `versioning_userdef.cc` | Upstream's new `sequencer_default_strip_length` and its versioning, with the fork's Android defaults and its 503.13/503.14 blocks. |
| Fixes the fork had cherry-picked | `compositor.cc`, `colormanagement.cc`, `list_function_eval.cc`, `editmesh_select.cc`, `interface_widgets.cc` (the same trim fix): upstream's later form taken. |
| Deleted by the fork | `.gitea/CODEOWNERS`, `.github/README.md`, the desktop `lib/*` submodules: stay deleted. |
| `release/datafiles/splash.png` | The fork's splash. |

Compile fixes the merge needed, none of them conflicts:

- `kdtree.cc`: `allocator->template allocate_array<Node>` -- NDK clang 19 requires
  the keyword desktop compilers do not.
- `draw_command.cc`: 5.3 made `DrawCommand` a union with `array`/`indexed`
  fields; the fork's CPU command fallback (Adreno 750) used the old accessors.
- `interface_handlers.cc`: `uiblocks.first` is a method on 5.3's `ListBaseT`.
- SPIR-V headers: 5.3 includes `spirv/unified1/spirv.h`. The desktop libraries
  ship it inside shaderc; `deps/build.sh` now installs it there too.

## Configuration changes for 5.3

| Option | Android | Why |
| --- | --- | --- |
| `WITH_JOLT` | OFF | New library, not cross-compiled yet |
| `WITH_OPENTIMELINEIO` | OFF | New library (sequencer `.otio` import/export), not cross-compiled yet |
| `WITH_EMBREE` | as before | Renamed from `WITH_CYCLES_EMBREE`; the Android feature files were updated |
| `WITH_IO_SPZ` | ON | Gaussian splat `.spz` import; needs only zlib and zstd |

## Known consequences

- **Files saved by this fork before the sync are marked 503.14**, but were really
  anchor-era (503.10) data. Opening them now skips upstream's 503.11-503.14
  versioning: a Sculpt defaults fix (harmless, it only fills zeros), a weight/vertex
  paint brush falloff conversion (block 12), attribute active index validation,
  and the Outliner "expand on focus" flag (block 14). Re-running them was rejected
  because block 12 is not idempotent and would overwrite brush settings people
  have since changed.
- The fork's own preferences versioning still uses 503.13 and 503.14. Preferences
  written by official Blender 5.3 builds (503.15+) skip it, so they come in
  without the touch menu scale default.

## Not taken

- The official Android build system (PR !164188, still WIP): a different
  cross-compilation approach from simfeo's, and adopting it would be a re-fork.
- The `android-demo` branch's gestures (two-finger undo, three-finger redo,
  one-finger orbit): they conflict with this fork's touch model. Only its
  modifier wheel was ported, adapted to this fork's GHOST backend.
