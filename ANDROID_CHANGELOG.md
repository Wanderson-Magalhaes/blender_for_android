# Android Port Changelog

Everything this fork adds on top of the original Blender for Android port by
Simfeo, which targeted a Galaxy S22. This fork tracks Blender 5.3 on arm64 and
is developed and verified on a Galaxy S24 Ultra.

Add new entries at the top of the section they belong to. Keep one line per
change, say what it does for the user, and put the commit hash at the end.

## New Features

* Online Essentials and the other remote asset libraries work on Android. The HTTP downloader
  runs its background side on a thread there instead of a spawned process, and the pure-Python
  packages it needs are bundled. (uncommitted)

* Debug mode: `build_files/android/debug.sh`, and launch arguments read from the app's external
  files directory as well, so debug flags need no rebuild. (uncommitted)

* Synced with Blender 5.3 Beta (`blender-v5.3-release` at `fefcb557`), merged as a real
  three-way merge against the recovered anchor `b73c4e89` rather than 2,024 cherry-picks, so
  the next sync needs neither the anchor search nor a graft. 39 conflicts resolved toward this
  fork's intent with upstream's change inside it -- above all the Vulkan device setup, where
  upstream's own Vulkan 1.1 support replaced most of what was done here by hand and the
  render-pass fallback, the Android surface rotation and SPIR-V 1.3 on Qualcomm were kept on
  top. Jolt Physics and OpenTimelineIO are off until they are cross-compiled. The method, the
  evidence for the anchor and every resolution are in ANDROID_UPSTREAM.md. `4883ed7d3`

* The modifier wheel, from the official `android-demo` branch: latched Ctrl, Shift and Alt,
  Quick Favorites opened beside it, and Enter and Esc while the status bar shows them for a
  modal operator. Rebuilt on this port's pointer events and asked before the on-screen
  keyboard; it shares the window's modifier state with that keyboard, lifts above it while it
  is open, and ignores the pen. `5a02c47cd`

* Side panels resize with a finger, and tree view lists such as the Asset Browser's catalogs
  scroll with one. The Asset Browser's catalog list also opens narrower with the phone
  upright. `e3e819c5f`

* A quick three-finger tap toggles a maximized area (Ctrl+Space); the three-finger pan starts
  after a short travel so the two can be told apart. `88d14ac`

* Hardware and Bluetooth keyboards type: keys go through `BlenderActivity` with the character
  `KeyCharacterMap` resolves, dead keys and AltGr included. `73f2434`

* The on-screen keyboard has a function row. Esc heads it, then F1 to F12, none of
  which a phone could reach at all before: no rename, no menu search, no reopening
  the last operator's panel, no render. Moving Esc up out of the letters freed the
  space for the punctuation a script needs, so the letter rows now carry `[ ] \`
  and `; '`, and the portrait numeric layer carries the same five as a row of its
  own. The sixth row also brings portrait key height down by about a sixth without
  the keyboard growing, and the caps are drawn flat now rather than moulded with a
  dropped shadow and a wash of light. `f0e11d2`

* "Add Workspace" is back, at the foot of the folded top bar menu. Folding the tab
  strip away took the `+` at the end of it with it, and `workspace.add` has no
  shortcut and appears nowhere else, so there was no way to make a workspace at
  all. `2bcc779`

* A `.blend` tapped in a file manager opens in Blender. The activity declares one
  VIEW/EDIT intent filter, matched on the `.blend` suffix rather than on a MIME
  type, since Android has no registered type for the extension and no app can add
  one. Cold start passes the resolved path as a launch argument, the way a
  double-clicked file reaches `argv[1]` on macOS; a tap while Blender is already
  running goes through `GHOST_kEventOpenMainFile` and `WM_OT_open_mainfile`
  instead, so the unsaved-changes prompt still appears. `launchMode="singleTask"`
  keeps that from starting a second Blender inside the one process. A
  `content://` URI is turned back into a real path in five rungs, ending in a
  cache copy when nothing behind the URI is a file; Blender opens by path and a
  copy loses the relative paths to its textures. Two filters of that shape are
  declared, one with a wildcard type and one with none: a file manager builds the
  intent type from MimeTypeMap, which has no entry for .blend, so it sends the URI
  with no type at all, and a filter that declares a type never matches an intent
  that carries none. A third filter covers MediaStore, where the file name does not
  survive at all: Samsung's My Files hands the file over as
  `content://media/external/file/<row>`, with an empty MIME type, so neither the
  name nor the type can narrow it and the collection does instead. Images, video
  and audio never offer Blender; other non-media files now do, which is the price
  of being reachable from the phone's own file manager. `f3c1053` `8070ad3`
  `74586dc`

* The Cycles device panel names the hardware. A phone offers one compute device
  type, "None", and the panel was otherwise empty under it, which reads as no
  hardware rather than as CPU rendering. It now shows the device, the processor,
  the GPU, the core count and the memory, as a table. Memory appears twice: what
  the phone was sold with, and the smaller figure the kernel is left with after
  the firmware and the modem take their reservations. `8709f5e` `e4b12ec`
  `ee86405`

* The top bar folds into a single button, in both orientations. It holds the
  editor pull-downs, then every workspace with the active one drawn depressed,
  then the Blender menu below Help. Undo and redo sit beside it as buttons,
  because Ctrl+Z on a phone means opening a keyboard to hold a modifier. Held
  upright the whole bar used to fit the Blender icon, "File", and the scene and
  view layer fields, and nothing else. `8bf3c4c` `8bc6e61`
* A finger can reach the bottom of a menu that is taller than the screen. Drag
  anywhere in it to pan, or tap the arrow band, which is twice as tall on
  Android. Modal dialogs behave the same way, since every popup in the program
  goes through the one handler. `8bf3c4c`
* Menu chrome is drawn half again as large as the rest of the interface, so a
  thumb can hit it without spending viewport on it. Headers, the top bar, the
  status bar, the Properties tab column, tool bars and every pull-down; editor
  content keeps every pixel. One preference, "Menu Scale", which multiplies
  Resolution Scale rather than sitting beside it. `f788f11`

* On-screen keyboard, drawn by Blender and opened from the status bar. It sends
  real key events, so it types into any native field without closing it, holds
  Ctrl, Shift and Alt, and fires every shortcut in the keymap, numpad view keys
  included. It works in every workspace and lays itself out for portrait or
  landscape. `cd18aa2`
* Open Image Denoise 2.5.0 cross compiled for arm64, so Cycles denoises on the
  CPU device and the compositor Denoise node works. `67d3247`
* Working internet access: the INTERNET permission, a bundled certificate
  store, and a Python interpreter the extension system can run. The Get
  Extensions panel now lists and installs add ons from extensions.blender.org.
  `862b4df` `1c9cd96`
* pip is bundled, as it is in the desktop builds, so add ons can pull their own
  pure Python dependencies. `4fba4db`
* Fluid simulation (Mantaflow), the Manifold boolean solver, camera and object
  tracking, PDF export from Grease Pencil, the Ocean modifier, and path guiding
  in Cycles. `5813ce0` `736cdc3`
* Exact boolean solver, the one that survives awkward intersections, through
  GMP. `b512b6b`
* Draco compressed glTF import and export, which most .glb files in the wild
  use. `bddcbce`
* The essentials asset library, so sculpt, paint, grease pencil and curves have
  their brushes and the bundled node groups exist. Also 49 interface
  translations and the USD plugins. `d4595a8`
* Drag with one finger to scroll panels, headers, tool bars, channel lists and
  the Properties editor. A tap still activates whatever is under it. `c8ba5de`
  `c13137e`
* Drag with three fingers to pan the 3D viewport. Two fingers still orbit and
  pinch to zoom. `d687afb`
* The interface rotates between portrait and landscape, following the device
  rotation setting. `1492052`
* Typing with the soft keyboard, including autocorrect and word suggestions.
  `1282552`
* Every build is archived under its own timestamp, with a latest link, so any
  earlier APK can be installed again. `d712351`

## Adjustments

* The platform keyboard stays down while a physical keyboard is connected. `d5cab19`

* An editor border can be grabbed from half again as far away, `BORDERPADDING`
  times 1.5 on Android. Measured by dragging the border between the 3D view and
  the timeline with injected touch: about 13 pixels of reach before, about 19
  after, against a fingertip some 8 mm across. A press 14 pixels out missed
  before and takes the border now; 19 still misses. Half again rather than
  double because the cost lands on the user -- content within that distance of a
  border cannot be tapped, since the press moves the border instead. Sharing the
  wider reach with the stylus and the mouse is deliberate on a phone, where a
  stylus misses a 13 pixel target too. Noted for whoever changes this next: the
  reach is `BORDERPADDING` and **not** the radius in
  `ED_screen_edge_snap_for_touch()`, which looks like the touch-specific lever
  and is not -- raising that from 12 to 16 units changed nothing at 22 pixels
  out, with the value confirmed in the built object. That radius only decides how
  far a press may be moved onto a border it would otherwise miss entirely.
  `969d3db`

* The top bar's back-to-previous button shows its icon alone when the phone is
  upright and carries its label again when it is turned. Upright there is no room
  for the words beside the menu button, the undo pair and the scene and view layer
  fields. `c2623e3`

* Keyboard modifiers latch and are held down rather than sent around each key,
  so they reach touches as well as keys: Shift and a tap extend a selection,
  Ctrl and a tap add to one, and Ctrl once then NumpadPlus as often as the
  selection needs. One, two or three can be on together. `0a78c27`
* "Save changes before closing?" stacks its buttons in a column when the window
  is taller than it is wide, where the row ran off the edge. `0a78c27`
* The scene and view layer fields in the top bar are held to a width that takes
  the difference out of the typable part, upright. Both sat at a four unit floor
  whatever the name was. `8bc6e61` `0a78c27`
* Press and hold on the on-screen keyboard was added and then removed. Making it
  work meant accepting the right click that a held finger actually produces, and
  toggling the modifier on the press rather than the release, which cost the
  cancel that sliding off a key used to give. A tap that latches was always what
  it was reaching for. `923e9bc` `d977128`

* The stylus pressure threshold starts at 0.5 instead of 1.0. Android reports
  pressure against the range the digitizer declares, and an S Pen tops out
  around 0.77, so full pressure was unreachable. `1ee8fe5`
* GPU workarounds are no longer forced at startup, which was costing the
  Qualcomm specific tile memory extension. Orbiting a 292k vertex scene went
  from 48.9 ms to 36.3 ms per frame in EEVEE material preview. `8e2f1bc`
* EEVEE reserves phone sized amounts of GPU memory. The shadow pool is capped
  at 64 MB on Android regardless of how much system RAM the device has.
  `2c8ca3a`
* The viewport texture limit defaults to 1024 rather than unlimited, so a scene
  full of 4K maps does not reserve several gigabytes before its first frame.
  `0499cc8` `c91589d`
* Interface defaults suited to a phone: 1.10 resolution scale, 4 pixel editor
  borders, and the temporary editors set to a maximized area instead of a new
  window, which Android cannot open. `8f38ba9`
* The node editor keeps its own keymaps ahead of the generic View2D one, so box
  select, link dragging, node resizing and node moving survive the drag to
  scroll binding. `3dcebc9`
* New splash screen artwork and a launcher icon on Blender interface gray, with
  the logo scaled to keep a margin inside the launcher mask. `3378888`
  `65456ad` `d4dd06a` `bddcbce`
* build.py resolves the dependency prefix instead of guessing it, and stops
  with a clear message when it is wrong. `4bf9575`
* build.py can re apply the feature flags with --reconfigure, which turns a
  WITH_* change from an hour into a few minutes. `854d519`
* The build guide is in English, the feature gap document was rewritten against
  the real build, and the build and crash debugging procedures are recorded as
  skills. `ac53bbf` `b2ee538` `f468494` `f885f93` `7771727`

## Bug Fixes

* Beta 2: region resizing uses the resized region's menu scale for pointer deltas,
  size limits and snapping. At Menu Scale 0.50 the toolbar previously advanced about
  1.5 pixels per pixel dragged. Android region action-zone events now run immediately
  after their triggering press, before queued motion/release, and retain its coordinates;
  resizing starts with one continuous gesture instead of a tap followed by a second drag.
  S24 Ultra measurements: before, a 100 px drag changed width by 148 px; after, the first
  355 px drag changed width by 355 px and subsequent 100 px drags changed it by 99 px
  in either direction. With Menu Scale 0.00, a 100 px drag also changed width by 99 px.
  See the 2026-10-29 follow-up in `ANDROID_TOUCH_UI_SCALE_STUDY.md`. `1276da69c`

* Beta 2: selectively backported 18 upstream Blender 5.3 fixes reviewed through 2026-10-29.
  Vulkan pipeline/cache, clip-distance, buffer alignment/copy and teardown fixes; builtin point
  shader corrections; File/Asset Browser switching and startup Python GPU crashes; bounds checks
  for paths, text, animation, RNA defaults/overrides and multilayer EXR names. Existing Android
  workarounds and the full-sync anchor are preserved. Native frame/path-range overflow tests
  fail on the previous APK and pass on the updated S24 Ultra build; GPU startup/readback and
  five File/Asset Browser transitions pass. Exact upstream SHAs and scope are in
  `ANDROID_UPSTREAM_BETA2_STUDY.md`. `5dce8c3b7`

* Beta 2: Android paints the window background in the editor-border theme color before composing regions.
  Region blits and blended outlines leave gaps, including the row below the top bar; without a
  clear these can expose undefined Vulkan image contents. Installed and checked on the S24 Ultra
  at startup, in portrait/landscape, while resizing both editor boundaries and after resume.
  The reported intermittent blue/magenta pixels did not reproduce in the baseline test, so this
  fixes the uncovered background but does not establish that every reported occurrence is gone.
  See `ANDROID_EDITOR_BORDER_GLITCH_STUDY.md`. `01d2c2dcc`

* One tap opens a folder in the File Browser: single click opening defaults on for Android, and
  selection acts on click so a scroll does not open the folder it starts on. (uncommitted)

* `fastdeploy.sh` rebuilds the dex when `BlenderActivity.java` changed. It reused the staged
  one, so a Java edit never reached the device and a new native side shipped beside old Java,
  which broke Backspace. `a5db064`

* Tooltips are no longer cut off mid-word. The box is measured in
  `tooltip_create_with_data()` -- `BLF_size()` from `UI_SCALE_FAC`, then
  `BLF_width()` per field -- and that runs outside any scale guard, while the
  `RGN_TYPE_TEMPORARY` region it goes into is drawn at the menu scale, so the box
  was sized for type a third smaller than the type put into it. The same mistake
  as the squeezed context menus and search boxes, in a fourth place. A short press
  now shows the whole description and a press held past `TOUCH_LONG_PRESS_MS`
  opens the tool variants, without the two colliding. `fd25a79`

* A tool's variants can be opened with a finger. Select Box holding Circle and
  Lasso, and every other tool with the small corner mark, opens them by pressing
  and holding, through `but->hold_func` -- and a finger could not reach it at all.
  GHOST withholds a touch press until the finger moves past the slop and turns a
  press held still into a right-click at `TOUCH_LONG_PRESS_MS`, so no left press
  arrives and the hold timer never starts; the comment on that timer already said
  "This only ever applies to a stylus." Holding a tool opened "Add to Quick
  Favorites" instead. A button with a hold action now runs it from the RIGHTMOUSE
  branch of `handle_button_event()`, for a pointer with no tablet data only: a
  stylus tip already sends a left press and reaches the hold the ordinary way, and
  its side button stays a real right-click. The cost is the design rather than an
  oversight -- on such a button a finger can no longer reach the context menu,
  since one press cannot mean two things, while the variants had no other route
  and the menu does. `78c7971`

* The tab that reopens a collapsed side panel can be hit with a finger. Two
  causes. It is drawn one widget unit by half a unit, about 37x18 px on this
  phone, which is a stylus target rather than a thumb one, and it is the only way
  into a collapsed region -- so it is now drawn at the menu scale, the multiplier
  the other thumb targets already use. `az->rect` is both what is drawn and what
  is hit-tested, so one multiplier moves both. And the press was being taken off
  it: `ED_screen_edge_snap_for_touch()` pulls a touch press onto a nearby editor
  border so a finger can resize editors, it already declines inside headers and
  tool bars, but the tab sits on the region border inside a `RGN_TYPE_WINDOW`
  region and that test let it through. A stylus and a mouse never reach that
  function -- the caller gates on `EVT_TABLET_NONE` -- which is exactly why they
  worked and a finger never did. It now declines when the press is already on an
  action zone. Left deliberately: a tap arms rather than completes, because
  `actionzone_apply()` posts its event to the queue tail and a finger's release
  is dispatched before `region_scale_invoke()` installs the modal handler, so the
  modal stays armed until the next gesture drives it. Tap, then drag. While
  armed, the next drag anywhere goes to the region rather than the viewport.
  `cc4005e`

* The splash screen and the About box are fitted to the window, and their type
  no longer crowds itself. Upstream asks for a box 45 em wide and clamps it to a
  fraction of the window; on a desktop the clamp never bites, on a phone it
  always did, and it moved the box while leaving the type where it was. Measured
  on a Galaxy S24 Ultra: 11 pt at `UI_SCALE_FAC` 1.833 asks for 907 px of width
  and the clamp gave it 756, so the splash was drawn a sixth too large for its
  space -- the same shape of defect as the cramped context menus and search
  boxes, a size and the scale it was computed at disagreeing. Landscape never
  clamped (0.7 of 2244 is 1570), which is why only the upright splash looked
  wrong. The box now takes a wider fraction of an upright phone, and where even
  that will not fit, the whole block is scaled down rather than the box alone
  being squeezed. Height is bounded the same way so the artwork cannot run off a
  landscape phone; the bound needs a constant, since a block's height is unknown
  until laid out, measured from the drawn block at 1.20 upright and 1.26 turned.
  Their rows are separate: the block stays out of the menu scale because it is
  fixed-proportion artwork, but its file list is not, and at 1.0 it was the one
  list in the program drawn tighter than every menu beside it -- 40 px a row
  against 54 in the top bar. Layout `scale_y` gives the rows the pitch without
  touching the type, which a scale guard would have enlarged inside a box whose
  width is already settled, truncating the file names further. The About box
  carried no width clamp at all upstream. `4a9f1b9`

* The Blender logo in the About box is not stretched. Raising the row pitch above
  put `scale_y` on the layout the logo is added to, and a layout scale reaches
  every item added while that layout is open -- `uiDefButImage()` looks like it
  places a picture at its own size, and does, right up until a layout is open to
  catch it. The splash escapes this only because its artwork is created before
  `block_layout()` is called; the About box's logo is created after. The pitch
  moved to the column holding the text and buttons, which is created after the
  logo. `81f85ba`

* The status bar no longer reports more graphics memory than the phone has. It
  claimed "VRAM: 0.3/14.8 GiB" on a device sold with 12 GB, because
  `VKDevice::memory_statistics_get()` summed the size of every device-local heap.
  Measured on an Adreno 750, the driver reports two: 11084 MiB, and a second of
  4095 MiB reachable only through a memory type carrying
  `VK_MEMORY_PROPERTY_PROTECTED_BIT`. That second one is for DRM-protected
  content and Blender can never allocate from it; the first is not video memory
  at all, since a phone has none -- it is system memory, all of it, shared with
  Android and every other app, so its size is not an amount Blender can ever
  have. A discrete card has one device-local heap and no protected one, which is
  why summing them looked right everywhere else. Protected heaps are now skipped
  and the figure is `VmaBudget::budget`, what the driver will promise this
  process, rather than the raw heap size: 8.7 GiB on the same device. The Cycles
  device panel gained the same figure as a third line -- what was fitted, what
  the kernel kept, what Blender may allocate -- and its middle line no longer
  calls `MemTotal` "usable", which it is not. Both read the one call, exposed as
  `gpu.capabilities.memory_statistics_get()`, so they cannot drift apart. Note
  that this driver does not expose `VK_EXT_memory_budget`, so the budget is VMA's
  80% heuristic: a ceiling on what Blender may ask for, not a live account of
  what Android is using. `becb93b`

* Allowing online access no longer fills the report banner with two errors about
  a missing `_asset-library-meta.json`. Blender was trying to sync its Online
  Essentials asset library, which cannot work on Android at all: the listing
  downloader is built on `multiprocessing` with the 'spawn' start method, and
  `_multiprocessing` is not in this Python -- CPython refuses to build it without
  `sem_open`, which Bionic does not have (`ac_cv_func_sem_open=no`,
  `MODULE__MULTIPROCESSING_STATE=missing` in the CPython build). Even built it
  would fail at run time for the same reason, and 'spawn' re-runs
  `sys.executable`, which does not exist when Blender is a library inside a
  NativeActivity. The failure surfaced three steps from its cause because
  `remote_library_request_download()` discards the exception -- it still carries a
  "TODO: report errors in the UI somehow" -- so nothing was downloaded and the
  asset system then read a file that was never going to exist. Remote asset
  libraries are switched off instead, in one place,
  `remote_libraries_supported()`, asked by the library list, the library service
  and the "Include Online Essentials" checkbox; the periodic sync in `bl_pkg` is
  guarded separately because it runs before any library is listed. Unrelated to
  the extension system, which does its own networking and still lists and
  installs. `fde4a5a`

* The on-screen keyboard button no longer scrolls off the left edge of the status
  bar. The bar overflows on a phone and a finger can drag a header sideways to
  read the rest, which carried the button away with the figures -- worse the more
  of them were turned on. The bar is two header regions now: the button alone in a
  left-aligned one, the hints and figures in the one after it, which is the only
  one that scrolls. Three things had to hold together. The button's region is the
  aligned one because `RGN_FLAG_DYNAMIC_SIZE` sizes a region to its own content,
  and a button is one button wide while the figures ask for more than the bar has
  and squeezed the other side to nothing. It is also first, because
  `region_rect_recursive()` forces the last region to `RGN_ALIGN_NONE`: built the
  other way round with `RGN_SPLIT_PREV`, the button's region took the whole of its
  neighbour's rect and the figures came out zero wide. And `statusbar_create()`
  alone does nothing, because the window manager writes `wmWindow.global_areas`
  into the file and the bundled `startup.blend` predates the split, so every
  launch restored the old one-region bar and `create()` never ran --
  `screen_global_statusbar_area_ensure_regions()` adds the region to a restored
  bar instead. Upstream's spacers stay inside the figures region and are
  load-bearing: `template_input_status()` draws hints that exist only while a
  finger is down, so anchoring them at the left with their own spacer is what
  keeps the figures still. Packed behind one leading spacer, as a first attempt at
  right-aligning them, the figures jumped a hint's width on every touch and
  release and it read as the scroll losing its place. `alignment = 'RIGHT'` is no
  substitute -- a header layout is only as wide as its own content. `c2623e3`

* A search box on a field in a panel -- an IK constraint's Target, a data-block
  picker -- no longer runs off the screen, and no longer opens over the field that
  opened it. It picks the side of the field with room, takes its height from that
  side's room, and grows away from the field rather than being placed first and
  then pushed to fit. Only two of the four edges were watched before, so a field
  near the top of the Properties editor flipped upwards and ran its rows off the
  ceiling -- and pushing it back down covered the field, which meant the press that
  opened the list also closed it. Android's own keyboard is still outside this: its
  insets never reach the window, so nothing in Blender knows it is up. `f1d9115`

* The search popup no longer lands under the on-screen keyboard, and no longer
  insists on ten rows when there is room for six. It is sized to the space between
  the top of the window and the top of the keyboard, and lifted into it. The row
  count used to be fixed, and the row height is the box divided by that count, so a
  short window gave ten rows too thin to read instead of a few readable ones. The
  window counts as well as the keyboard, so Blender sharing the screen in Android's
  split view gets the same treatment. Two rows and a whole search field are the
  floor; below that the field wins, because a search that cannot be typed into is
  worse than one whose last row is covered.

  The results can be dragged with a finger, a stylus or a held mouse button, and
  the wheel still steps as it did. A tap applies what was pressed rather than what
  is highlighted -- a pointer drags the highlight along with it and arrives on the
  right row, a finger lands and lets go with no motion in between -- while arrow
  keys and Return keep using the highlight, which for them is the choice. Merely
  moving a mouse across the list or holding a stylus above it no longer scrolls
  anything.

  Four separate defects along the way were one mistake: geometry measured in scale
  units on the far side of the guard that applies the scale. The worst of them put
  a tap three rows below the row it was aimed at. The row geometry is settled once,
  where the scale is held, and kept as pixels. `d64bdfb`

* Search boxes are no longer drawn with their rows squeezed to two thirds of the
  text in them. A search box is the one piece of menu chrome not built inside the
  popup refresh, so the touch menu scale never reached it: the results region sized
  itself against the unscaled widget unit, and the F3 menu search took its block
  size from the operator, which ran outside the scale as well. The same defect, and
  the same ratio, as the context menus. `75b900b`

* Links open in the phone's browser. Every link in the program goes through
  `wm.url_open`, which calls Python's `webbrowser.open()`; that module looks for
  `xdg-open` and friends, finds none of them on Android and returns False without
  raising, reporting or logging anything, so the splash links, the About box, the
  manual buttons in Preferences and "Online Manual" on a property's context menu
  all did nothing at all. A `webbrowser` controller is registered on Android that
  hands the URL to an `ACTION_VIEW` intent, which covers add-ons and the pre-filled
  bug report as well, and it reports an error if no browser takes it rather than
  failing silently the way it used to. `11bec7e`

* Preferences no longer offers an "Operating System Settings" panel whose Register
  button could only report `Could not find "xdg-mime", unable to associate
  mime-types`. Android reports as linux, so the panel took the freedesktop path,
  which shells out to a program the platform does not have and a MIME database it
  does not keep. Nothing is lost with it: the file association is an intent filter
  fixed when the APK is built, and no app can register or unregister a file type at
  runtime on Android. `8070ad3`

* Context menus on buttons and headers are no longer drawn with their rows at two
  thirds height, text crowding its own lines. They are built while an event is
  being handled rather than inside the popup refresh, so they missed the touch
  menu scale the popup around them was drawn at. `ee86405`

* A modifier left down by anything other than the on-screen keyboard is released
  rather than staying invisible. The keyboard used to release against a cache of
  what it had sent, and the three finger viewport pan sends Shift too, so one
  left down by a gesture could not be cleared -- every click in the program then
  carried it, and with Emulate 3 Button Mouse on a stuck Alt turns every left
  click into a middle click, which reads as the interface having died. Opening
  the keyboard now releases whatever is held. `923e9bc`

* Widgets inside modifier panels needed several taps, and the modifier drop
  down never opened at all, because the keymap consumed the press that the
  click was waiting on. Affected a connected mouse as much as touch. `e70d979`
* Reset to Default Value handed back 1.0 for the pressure threshold while a
  fresh install started at 0.5, because RNA defaults are baked in by a tool
  that runs on the build machine. `1ee8fe5`
* A label that trims away to nothing wrote about a gigabyte past its buffer,
  killing the process the moment the 2D Animation or Storyboarding template
  opened in portrait. Not Android specific, just routine on a narrow panel.
  `3185bd0`
* GPU subdivision handed back empty buffers when the driver refused the compute
  pipeline. It falls back to the CPU evaluator instead. `8a84eab`
* EEVEE shadow and light culling shaders failed to compile on Adreno. Qualcomm
  is now asked for SPIR-V 1.3, which it accepts, whatever version it reports
  supporting. `3298139`
* Loading a heavy scene killed the app with no crash log, because GPU memory
  never appears in the process RSS. `2c8ca3a` `c91589d`
* Text fields ignored everything typed except a tapped autocorrect suggestion,
  because the soft keyboard sends composing text rather than key events.
  `1282552`
* The device kept running a runtime payload it had unpacked weeks earlier, so
  Python and keymap changes appeared to have no effect. The payload hash now
  invalidates the marker by itself. `f3b0e68`
* glog picked Android up as plain Linux and selected stack traces that do not
  compile below API 33. `d4ef1b6`
* Two finger gestures emitted pan and zoom on the same frame, so scrolling a
  panel zoomed it as well. `c8ba5de`
* git-lfs hooks written to a literal NUL path were committed by accident and
  are now ignored. `da0af94` `b512b6b`

## Known Gaps

Tracked in ANDROID_MISSING_FEATURES.md. As of the last audit there are two:
audio output, which needs an AAudio device written against audaspace, and OSL,
which needs a second host toolchain to generate shader bitcode. `b2ee538`
