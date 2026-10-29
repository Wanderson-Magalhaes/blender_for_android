# Touch-sized menus, and a collapsed header in portrait

Two questions, and the answers this port arrived at:

1. How do you make **only** the menu chrome — headers, the top bar, the status
   bar, the Properties tab column, tool bars, pull-downs and popups — start at
   1.5x, while the editor content stays exactly where it is, and while the
   Resolution Scale preference still governs the whole thing?
2. How does the top bar collapse to a single button in portrait, so the menus
   stop being cut off and a workspace can still be switched?

Both are built. Parts 1 to 4 cover the scaling, Part 5 the collapsed top bar,
and Part 6 the one thing the scaling made worse: a menu too tall to reach the
bottom of with a finger.

Everything below was read out of this tree. File and line references are to the
state of the branch this document was written on.

---

# Part 1: How Blender sizes the interface today

## One number reaches everything

Every widget, font, icon, margin and region height in Blender is derived from a
single runtime float:

```c
/* source/blender/makesdna/DNA_theme_types.h:21 */
#define UI_SCALE_FAC ((void)0, U.scale_factor)
```

and from one integer derived from it:

```c
/* source/blender/editors/include/UI_interface_c.hh:2343 */
#define UI_UNIT_X ((void)0, U.widget_unit)
#define UI_UNIT_Y ((void)0, U.widget_unit)
```

Both are computed once per window, in `WM_window_dpi_set_userdef()`:

```c
/* source/blender/windowmanager/intern/wm_window.cc:770-785 */
U.dpi              = auto_dpi * U.ui_scale * (72.0 / 96.0f);
int pixelsize      = max_ii(1, (U.dpi / 64));
pixelsize          = max_ii(1, pixelsize + U.ui_line_width);
U.pixelsize        = pixelsize;
U.scale_factor     = U.dpi / 72.0f;
U.inv_scale_factor = 1.0f / U.scale_factor;
U.widget_unit      = int(roundf(18.0f * U.scale_factor)) + (2 * pixelsize);
```

`U.ui_scale` is the preference shown as **Resolution Scale**, and this port
already ships it at 1.10 (`USER_UI_SCALE_DEFAULT`,
[DNA_userdef_types.h:587-591](source/blender/makesdna/DNA_userdef_types.h)).

The reach of those two macros is the whole point:

```
$ grep -r 'UI_SCALE_FAC|U.widget_unit|UI_UNIT_X|UI_UNIT_Y' source/blender | wc -l
1784
```

1784 call sites. Nothing else has to be touched to make something bigger.

## The three things that follow from it

| What | Where | How it scales |
| --- | --- | --- |
| Font size | [interface_style.cc:600](source/blender/editors/interface/interface_style.cc) `fontstyle_set_ex()` | `BLF_size(font, fs->points * UI_SCALE_FAC)` |
| Icon size | [interface_widgets.cc:2994](source/blender/editors/interface/interface_widgets.cc) | `ICON_DEFAULT_HEIGHT / (aspect * UI_INV_SCALE_FAC)` |
| Layout spacing | [interface_style.cc:424](source/blender/editors/interface/interface_style.cc) `style_get_dpi()` | every `columnspace`, `buttonspacex`, `panelspace` multiplied by `UI_SCALE_FAC` |

The icons are the good news. In this version Blender's monochrome icons are
`ICON_TYPE_SVG_MONO` / `ICON_TYPE_SVG_COLOR`, drawn through
`BLF_draw_svg_icon()` at whatever pixel size is asked for
([interface_icons.cc:1749-1792](source/blender/editors/interface/interface_icons.cc)).
They rasterise per size in the font glyph cache, so a 1.5x icon is **sharp, not
blurry**. Only tool icons (`ICON_TYPE_GEOM`, the brush and tool `.dat` files
under `release/datafiles/icons`) go through `BKE_icon_geom_rasterize()`, which
caches exactly one size per icon and re-rasterises when a second size appears.
That is a real cost and it is discussed under Risks.

## Header height

Header, tool header, footer, top bar and status bar heights all come from one
function:

```c
/* source/blender/editors/screen/area.cc:4072 */
int ED_area_headersize()
{
  return U.widget_unit + int(UI_SCALE_FAC * HEADER_PADDING_Y);   /* HEADER_PADDING_Y == 6 */
}
```

- `ED_area_footersize()` ([area.cc:4078](source/blender/editors/screen/area.cc)) returns the same.
- `ED_region_global_size_y()` ([area.cc:4163](source/blender/editors/screen/area.cc)) returns the same.
- The top bar and the status bar size themselves from it, in unscaled units:

```c
/* source/blender/editors/screen/screen_edit.cc:1277 */
static int screen_global_header_size()
{
  return int(ceilf(ED_area_headersize() / UI_SCALE_FAC));
}
```

`screen_global_topbar_area_refresh()` uses that value directly; the status bar
uses `0.85f *` it ([screen_edit.cc:1283-1308](source/blender/editors/screen/screen_edit.cc)).
`ED_area_global_size_y()` multiplies it back by `UI_SCALE_FAC`
([area.cc:4083](source/blender/editors/screen/area.cc)).

So **one function governs every horizontal bar in the program**. That is the
lever for the bars.

## Region widths

Widths are different. `region_rect_recursive()` decides them
([area.cc:1616](source/blender/editors/screen/area.cc)), and at line 1666 it does:

```c
int prefsizex = UI_SCALE_FAC *
                ((region->sizex > 1) ? region->sizex + 0.5f : region->runtime->type->prefsizex);
```

with the header family special-cased just below (lines 1670-1695) to
`ED_area_headersize()` / `ED_area_footersize()` / `ED_region_global_size_y()` /
`asset::shelf::header_region_size()`.

The Properties tab column is **not** in that special case. It is
`RGN_TYPE_NAV_BAR` ([space_buttons.cc:90](source/blender/editors/space_buttons/space_buttons.cc)),
it is not `RGN_FLAG_DYNAMIC_SIZE`, and its width is `region->sizex` read from the
saved layout, times `UI_SCALE_FAC`. Same for the 3D view tool bar
(`RGN_TYPE_TOOLS`). Those need the multiplier applied at line 1666.

---

# Part 2: Why Resolution Scale is the wrong knob

Raising `U.ui_scale` from 1.10 to 1.65 would make the menus the right size. It
would also:

- shrink the usable 3D viewport by the same 50%, on a screen that has none to spare;
- enlarge the node editor grid, the outliner rows, the timeline, the graph editor,
  the file browser thumbnails, and the text editor;
- change `U.pixelsize` (`max_ii(1, U.dpi / 64)`), which is the **line width** for
  every outline, wire, vertex and gizmo in the program;
- raise `AREAMINX` in real pixels, so fewer editors fit side by side.

The ask is the opposite: bigger targets **without** giving up canvas. That means
the multiplier has to be scoped to the chrome.

---

# Part 3: The mechanism — a scoped scale override

Blender already does exactly this, in its own code. When a `wmSurface` (the VR
mirror) is drawn it temporarily overwrites the same globals so the surface draws
at a constant size regardless of window DPI:

```c
/* source/blender/windowmanager/intern/wm_surface.cc:32-48 */
static void wm_surface_constant_dpi_set_userpref()
{
  U.dpi = 72.0f;
  U.pixelsize = 1.0f;
  U.virtual_pixel = VIRTUAL_PIXEL_NATIVE;
  U.scale_factor = 1.0f;
  U.inv_scale_factor = 1.0f;
  U.widget_unit = int(roundf(18.0f * U.scale_factor)) + (2 * U.pixelsize);
}
```

The design is the same idea with a multiplier instead of a constant, made
re-entrant and scoped with RAII.

## The primitive

It lives in [screen_menu_scale.cc](source/blender/editors/screen/screen_menu_scale.cc),
declared in [ED_screen.hh](source/blender/editors/include/ED_screen.hh):

```cpp
float ED_ui_menu_scale();                                    /* 1.0 + the preference */
bool ED_region_uses_menu_scale(const ARegion *, const ScrArea *);

class ScopedMenuScale {
 public:
  explicit ScopedMenuScale(float factor);                    /* no-op at 1.0 */
  ScopedMenuScale(const ARegion *region, const ScrArea *area);
  ~ScopedMenuScale();
  void reset();                                              /* end the scope early */
};
```

The body of the guard:

```cpp
U.scale_factor     *= factor;
U.inv_scale_factor  = 1.0f / U.scale_factor;
U.dpi               = int(roundf(U.scale_factor * 72.0f));
U.widget_unit       = int(roundf(18.0f * U.scale_factor)) + (2 * int(U.pixelsize));
```

Five deliberate choices, the last three of which were forced by the code rather
than chosen up front:

- **`U.pixelsize` is not touched.** It is the line width. A 1.5x menu wants a
  1.5x button, not a 1.5x outline around it. Leaving it alone also keeps every
  `U.pixelsize`-based separator crisp.
- **Multiply, do not assign.** `U.scale_factor *= factor` is what makes
  Resolution Scale still govern the result: at Resolution Scale 1.10 the menus
  come out at `1.10 * 1.5 = 1.65`, and raising the preference to 1.3 moves the
  menus to 1.95 with it. This is what was asked for — one control, a different
  starting point.
- **RAII, not paired calls.** `ED_region_do_draw()` has three early returns and
  `ED_region_do_layout()` has two. A destructor cannot be forgotten.
- **The guard does not nest.** A file-static flag makes an inner guard decline
  rather than compound. It has to, because #ED_area_headersize() carries its own
  guard (site 5 below) and is called from inside the guard in
  `region_rect_recursive()` (site 3). Applying twice there gives a header half
  again as tall as the buttons in it.
- **`reset()` exists for one caller.** `region_rect_recursive()` recurses into
  `region->next` from inside its own scope. The next region is a *sibling* and
  must pick its own scale, so the guard is handed back before the recursive
  call. It also has to still be held a few lines earlier, at
  `region->sizex = (winx + 0.5f) / UI_SCALE_FAC` — that line undoes the multiply,
  and dividing by a different number than you multiplied by makes the stored
  region size drift a little further on every screen refresh.

## Where the guard goes

Five sites, and only five:

| # | Site | File | Why |
| --- | --- | --- | --- |
| 1 | `ED_region_do_layout()` | [area.cc:465](source/blender/editors/screen/area.cc) | The `layout` callback for dynamically sized regions: top bar right, status bar, HUD, file browser execute region |
| 2 | `ED_region_do_draw()` | [area.cc:488](source/blender/editors/screen/area.cc) | For most editors the header **lays itself out inside its draw callback** — `ED_region_header()` at [area.cc:4051](source/blender/editors/screen/area.cc) calls layout then draw. Guarding the draw covers both |
| 3 | `region_rect_recursive()` prefsize block | [area.cc:1666-1697](source/blender/editors/screen/area.cc) | The width of the Properties tab column and the tool bars, which are `region->sizex * UI_SCALE_FAC` |
| 4 | `popup_block_refresh()` | [interface_region_popup.cc](source/blender/editors/interface/regions/interface_region_popup.cc) | Every pull-down, popover, pie, search box and context menu. Guarding here also covers `popup_block_create()`, which calls it directly rather than through `ED_region_do_layout()`. Popups that are not menus opt out through `PopupBlockHandle::use_menu_scale` — see below |
| 5 | `ED_area_headersize()` / `ED_area_footersize()` / `ED_region_global_size_y()` | [area.cc:4072-4165](source/blender/editors/screen/area.cc) | These three describe menu chrome and nothing else. Rather than guarding their callers, they should return the scaled value **unconditionally**. That fixes the top bar, the status bar, every editor header, and the minimum area heights in `screen_geometry.cc` in one move |

Site 5 deserves the argument spelled out. `ED_area_headersize()` has 21 callers
across five files:

```
8  source/blender/editors/screen/area.cc
6  source/blender/editors/screen/screen_geometry.cc
5  source/blender/editors/screen/screen_ops.cc
1  source/blender/editors/space_sequencer/space_sequencer.cc
1  source/blender/editors/screen/screen_edit.cc
```

Every one of them is asking "how tall is a header". The `screen_geometry.cc`
ones are minimum area heights when dragging a border; if headers get taller
those minimums **must** grow with them, or an area can be dragged smaller than
its own header. Baking the multiplier into the function is not a shortcut, it is
the correct answer for all 21.

## The popups that are not menus

Site 4 catches every popup, and two of them should not be caught: the **splash
screen** and the **About box**. They are fixed-proportion artwork, not something
a finger aims at, and the splash sizes itself as

```c
/* source/blender/windowmanager/intern/wm_splash_screen.cc */
int splash_width = style->widget.points * 45 * UI_SCALE_FAC;
CLAMP_MAX(splash_width, WM_window_native_pixel_x(CTX_wm_window(C)) * 0.7f);
```

The **width** is clamped to the window. The height is not — it follows the image
aspect. So extra scale does not make the splash easier to read, it pushes the
artwork off the top and bottom of a landscape phone, which is exactly what
happened the first time this was built.

They opt out through a `use_menu_scale` flag on `PopupBlockHandle`, threaded from
`popup_block_invoke()` as a defaulted argument so no other caller changes. The
flag has to live on the handle rather than be set afterwards, because
`popup_block_create()` lays the block out once before it returns.

Operator dialogs are deliberately left **in**: a confirmation with a Yes and a No
in it is something a thumb aims at.

## What a guarded region gets, for free

Because the guard moves `U.scale_factor` and `U.widget_unit`, everything
downstream follows without a single further edit:

- `UI_UNIT_X` / `UI_UNIT_Y` — button width and height
- `fontstyle_set()` — label text, 1.5x
- `icon_draw_size()` — icons, 1.5x, rasterised sharp from SVG
- `style_get_dpi()` — every spacing constant in the layout engine
- `UI_PANEL_MARGIN_X/Y`, `UI_HEADER_OFFSET`, `V2D_SCROLL_*`, `UI_SEARCHBOX_*`,
  `UI_TOOLBAR_COLUMN`, the header's own vertical centring at
  [area.cc:3924-3928](source/blender/editors/screen/area.cc)
- The Properties tab column, the tool bar columns, the asset shelf header
- Every popup, because its block is built under the guard

That is the whole reason for choosing this design over editing call sites: there
are 1784 of them.

---

# Part 4: The region map — what counts as a menu

`ED_region_uses_menu_scale()` is the entire policy. Blender already has a
predicate for part of it:

```c
/* source/blender/makesdna/DNA_screen_types.h:710 */
#define RGN_TYPE_IS_HEADER_ANY(regiontype) \
  (((1 << (regiontype)) & \
    ((1 << RGN_TYPE_HEADER) | 1 << (RGN_TYPE_TOOL_HEADER) | (1 << RGN_TYPE_FOOTER) | \
     (1 << RGN_TYPE_ASSET_SHELF_HEADER) | (1 << RGN_TYPE_SCRUBBING))) != 0)
```

Proposed policy:

| Region type | Scaled | What the user sees |
| --- | --- | --- |
| `RGN_TYPE_HEADER` | yes | Every editor header. Editor Type dropdown, mode selector, all of it. Also the top bar, which is a header in `SPACE_TOPBAR`, and the status bar, a header in `SPACE_STATUSBAR` |
| `RGN_TYPE_TOOL_HEADER` | yes | The tool settings strip under the 3D view header |
| `RGN_TYPE_FOOTER` | yes | Editor footers |
| `RGN_TYPE_NAV_BAR` | yes | **The Properties editor tab column**, and the Preferences nav bar |
| `RGN_TYPE_TOOLS` | yes | The 3D view / image editor tool bar icons |
| `RGN_TYPE_TOOL_PROPS` | yes | Tool settings side region |
| `RGN_TYPE_ASSET_SHELF_HEADER` | yes | Asset shelf header |
| `RGN_TYPE_TEMPORARY` | yes | Every pull-down, popover, pie menu, search box, context menu, tooltip. Handled at site 4, not by this predicate |
| `RGN_TYPE_EXECUTE` | yes | The file browser's Open/Cancel bar. It is a button bar, and it is a touch target |
| `RGN_TYPE_HUD` | open question | The redo panel. It floats over the viewport. Arguably chrome, arguably content |
| `RGN_TYPE_SCRUBBING` | yes | The time scrub bar. Its height comes from the footer, so leaving it out gives a taller strip with the old small numbers. Safe: frame positions along it come from the View2D mapping it shares with the editor below, not from the interface scale |
| Anything in a **global area** | yes | Whatever its region type says. The top bar's tool settings row registers as `RGN_TYPE_WINDOW` but draws through `ED_region_header_layout()`. This is why the predicate takes the `ScrArea` as well |
| `RGN_TYPE_UI` | **no** | The N sidebar. This is panel content — sliders and values, not navigation. Scaling it would eat a third of the viewport width |
| `RGN_TYPE_WINDOW` | **no** | The 3D viewport, the node canvas, the outliner, the Properties panel body, the timeline. This is the content that must not move |
| `RGN_TYPE_CHANNELS` | no | Dope sheet / NLA channel list, content |
| `RGN_TYPE_PREVIEW` | no | Content |

`RGN_TYPE_UI` and `RGN_TYPE_HUD` are the two to decide on after seeing it on the
phone. Both are one line in the predicate.

## The preference

Add to [DNA_userdef_types.h](source/blender/makesdna/DNA_userdef_types.h),
beside `ui_scale`:

```c
/** Extra size given to menu chrome only, as a fraction on top of `ui_scale`.
 *  0.5 draws them half again as large, 0 leaves them at the raw `ui_scale`.
 *  Shown in the preferences as "Menu Scale". */
float ui_scale_menu = USER_UI_SCALE_MENU_DEFAULT;
char _pad9[4] = {};
```

and to the platform block:

```c
#define USER_UI_SCALE_MENU_ANDROID 0.5f      /* outside the test, so makesrna sees it */

#ifdef __ANDROID__
#  define USER_UI_SCALE_MENU_DEFAULT USER_UI_SCALE_MENU_ANDROID
#else
#  define USER_UI_SCALE_MENU_DEFAULT 0.0f
#endif
```

**The stored value is the extra fraction, not the multiplier.** `ED_ui_menu_scale()`
returns `1.0f + clamp(ui_scale_menu, 0, 1)`, and the conversion lives in that one
function. Two reasons it is stored this way:

- 0 reads as "off" and gives the raw Resolution Scale, which is the value someone
  reaches for when they want the feature out of the way.
- A 0..1 factor cannot be set to a number that draws the menus *smaller* than the
  rest of the interface. A multiplier field with a range starting at 1.0 invites
  exactly that question, and there is no answer to it that anyone wants.

It renders as a `PROP_FACTOR` slider directly under Resolution Scale.

Four follow-ups, all of which this tree has hit before and documented:

1. **RNA default.** `makesrna` is a **host** tool. It reads this header compiled
   for the build machine, where `__ANDROID__` is not defined, and bakes whatever
   it finds into the generated source. Without the workaround already used for
   `pressure_threshold_max`, "Reset to Default Value" would hand back 1.0 on the
   phone. See the comment at
   [DNA_userdef_types.h:575-586](source/blender/makesdna/DNA_userdef_types.h) and
   the fix in [rna_userdef.cc](source/blender/makesrna/intern/rna_userdef.cc).
2. **Versioning.** An existing `userpref.blend` has this field at 0. Add an
   `if (userdef->ui_scale_menu == 0.0f) userdef->ui_scale_menu = USER_UI_SCALE_MENU_DEFAULT;`
   clause to [versioning_userdef.cc](source/blender/blenloader/intern/versioning_userdef.cc),
   next to the `border_width` one at line 1615.
3. **DNA change.** A new field in `UserDef` is a DNA change, which means
   `--reconfigure` is **mandatory**. Trap 2 in the build guide: without it the
   app installs, the activity starts, and the process dies before the first log
   line.
4. **DNA alignment.** A lone `float` added to `UserDef` shifts every pointer and
   `ListBase` after it off the 8 byte boundary DNA requires, and `makesdna`
   refuses the build with a page of `Align struct error` lines and
   `Sizeerror in 64 bit struct: UserDef (add 4 bytes)`. Pair the field with four
   bytes of padding. This one is at least loud rather than silent.

RNA property, next to `ui_scale` at
[rna_userdef.cc:5064](source/blender/makesrna/intern/rna_userdef.cc):

```c
prop = RNA_def_property(srna, "ui_scale_menu", PROP_FLOAT, PROP_NONE);
RNA_def_property_ui_text(prop, "Menu Scale",
    "Extra size for headers, menus and tool bars only, multiplied by Resolution Scale");
RNA_def_property_range(prop, 1.0f, 3.0f);
RNA_def_property_ui_range(prop, 1.0f, 2.0f, 1, 2);
RNA_def_property_update(prop, 0, "rna_userdef_gpu_and_text_update");
```

`rna_userdef_gpu_and_text_update` is the right callback: it clears the BLF cache
(new font sizes), sends `NC_WINDOW` for a full redraw and `NC_SCREEN|NA_EDITED`
to recompute region sizes ([rna_userdef.cc:370-385](source/blender/makesrna/intern/rna_userdef.cc)).

Preferences UI, one line under Resolution Scale at
[space_userpref.py:231](scripts/startup/bl_ui/space_userpref.py):

```python
col.prop(view, "ui_scale_menu", text="Menu Scale")
```

---

# Part 5: The collapsed top bar

Held upright the top bar could show the Blender icon, "File", and the scene and
view layer fields. Edit, Render, Window and Help, and all eleven workspace tabs,
were pushed off the end. Landscape was not much better: three and a half tabs,
with "UV Editin" cut mid-word.

Both halves of the bar are to blame and both had to give.

It started as an answer to the upright case only, and did not stay that way. A
tab strip showing three and a half of eleven, cut mid-word, is not much better
than one showing none, and a bar that rearranges itself when the device turns is
worse than one that always behaves the same. **The menu is folded in both
orientations.** The window shape still decides one thing -- how hard the scene
and view layer fields are squeezed -- because that is where the width actually
runs out.

## What was already there

`Menu.draw_collapsible()` is upstream, and it already collapses to the icon this
port wanted:

```python
# scripts/modules/_bpy_types.py:1465
@classmethod
def draw_collapsible(cls, context, layout):
    if context.area.show_menus:
        layout.row(align=True).menu_contents(cls.__name__)
    else:
        layout.menu(cls.__name__, icon='COLLAPSEMENU')
```

`area.show_menus` is the RNA face of `HEADER_NO_PULLDOWN` on `ScrArea::flag`
([rna_screen.cc:480](source/blender/makesrna/intern/rna_screen.cc),
[DNA_screen_types.h:574](source/blender/makesdna/DNA_screen_types.h)), toggled
from the header context menu by `SCREEN_OT_header_toggle_menus`.

It was not used, for two reasons. It only folds the pull-downs, and the workspace
tabs are the wider half. And driving it from orientation would mean writing that
flag, which is **saved in the `.blend`** and copied on area duplication
([screen.cc:973](source/blender/blenkernel/intern/screen.cc)) -- so rotating the
phone would quietly overwrite a choice the user had made, and keep it.

## What was built

A menu of its own, in [space_topbar.py](scripts/startup/bl_ui/space_topbar.py),
holding both halves:

```python
class TOPBAR_MT_touch_menu(Menu):
    def draw(self, context):
        layout = self.layout
        layout.menu("TOPBAR_MT_file", icon='FILE')
        layout.menu("TOPBAR_MT_edit", icon='GREASEPENCIL')
        layout.menu("TOPBAR_MT_render", icon='RENDER_STILL')
        layout.menu("TOPBAR_MT_window", icon='WINDOW')
        layout.menu("TOPBAR_MT_help", icon='QUESTION')

        layout.separator()

        active = context.window.workspace
        for workspace in bpy.data.workspaces:
            props = layout.operator("wm.context_set_id", text=workspace.name,
                                    translate=False, depress=(workspace == active))
            props.data_path = "window.workspace"
            props.value = workspace.name
```

Three things worth naming:

- **`wm.context_set_id` already exists**, in
  [wm.py:804](scripts/startup/bl_operators/wm.py). It matches the target
  property's type against the collections on `bpy.data`, looks the name up, and
  assigns. Setting `window.workspace` needed no new operator.
- **`depress=True` draws the active workspace as a pressed button**, which is the
  blue row in the mock-up. The list is its own indicator, so nothing is lost by
  dropping the tab strip.
- **Nothing persistent is written.** Nothing is stored at all: the menu is simply
  what the top bar draws, and the one remaining shape test is evaluated at draw
  time:

```python
def _topbar_is_upright(context):
    window = context.window
    return window is not None and window.height > window.width
```

The test is the shape rather than the platform, because that is what the problem
actually is -- a desktop window this narrow has it too, and wants the same
answer. The same reading as `wm_virtual_keyboard.cc`, which decides its layout
with `win_w < win_h`.

## Undo and redo, where the room went

Folding the menu frees most of the left half of the bar, and the two things worth
spending it on are undo and redo. Not because they are hard to reach on a
desktop, but because they are the two the keyboard is worst at here: Ctrl+Z means
opening the on-screen keyboard, holding a modifier and finding Z, for the
operation people reach for more than any other.

```python
row = layout.row(align=True)
row.operator("ed.undo", text="", icon='LOOP_BACK')
row.operator("ed.redo", text="", icon='LOOP_FORWARDS')
```

Both operators poll, so each greys itself out when there is nothing to undo or
redo, and the icons are the ones the Edit menu already uses for them.

## The icon has to say whether it is open

`COLLAPSEMENU` closed, `KEY_MENU_FILLED` open. Python cannot do this half:
`layout.menu()` fixes the icon when the block is built, and the open state lives
on `HandleButtonData::state == BUTTON_STATE_MENU_OPEN`, private to
`interface_handlers.cc`.

What makes it cheap is that the header **rebuilds its layout on every redraw** --
`ED_region_header()` runs layout and draw together -- so an icon decided at build
time tracks the state on its own, with nothing to invalidate.

So: one query exported from where the state lives, and one swap where the icon is
resolved.

```cpp
/* interface_handlers.cc */
bool ui_but_menu_is_open(const Button *but)
{
  return but->active && but->active->state == BUTTON_STATE_MENU_OPEN;
}

/* interface_query.cc, in button_icon() */
if (but->icon == ICON_COLLAPSEMENU && ui_but_menu_is_open(but)) {
  return ICON_KEY_MENU_FILLED;
}
```

`button_icon()` is the single place every icon in the interface is resolved
([interface_query.cc:171](source/blender/editors/interface/interface_query.cc)),
so the swap reaches drawing and sizing both. The alternative -- an `icon_open`
argument on `Layout.menu()` -- is more general and changes the public Python API
of a program whose add-on ecosystem this fork does not control. Fifteen lines
against that was not a close call.

## The scene and view layer fields

The right half of the bar is the other reason nothing fit. Both fields sit at a
floor rather than at their text width:

```c
/* interface_templates.cc:47 */
return std::clamp(estimated_width,
                  TEMPLATE_SEARCH_TEXTBUT_MIN_WIDTH,          /* UI_UNIT_X * 4 */
                  TEMPLATE_SEARCH_TEXTBUT_MIN_WIDTH * 4);
```

"Scene" and "ViewLayer" are far shorter than four units, so both fields sit at
the floor -- and at the touch menu scale four units is around 128 px each, on a
1080 px screen, before the browse, pin, new and unlink icons beside them.

Upright, each is put in a row with `ui_units_x` set. That is the idiom Blender's
own UI uses for this ([space_filebrowser.py:42](scripts/startup/bl_ui/space_filebrowser.py),
[properties_paint_common.py:1704](scripts/startup/bl_ui/properties_paint_common.py)),
and it takes the difference out of the flexible part -- the typable field -- while
the fixed-width icons beside it keep their size, which is what was asked for.

The scene row is given **one unit less** than the view layer row, and that is not
a fudge: `template_search` reserves room for a type icon that `template_ID` has
no equivalent of, so the same number on both would leave the view layer field
visibly less text than the scene field. One unit apart is what makes the two
typable fields come out the same size.

Done in the layout rather than in `template_search_textbut_width()` because that
function has no context: it cannot tell the top bar from a material selector in
the Properties editor, and only the top bar has this problem.

## What is still open

`TOPBAR_MT_editor_menus` and `TOPBAR_MT_workspace_menu` are still registered and
no longer drawn by the top bar. They are left alone deliberately: they are
upstream classes an add-on may reference, and removing them buys nothing.

---

# Part 6: Reaching a tall menu with a finger

Open File on a phone and the menu is taller than the screen. A mouse has two ways
through that. A finger had neither.

## Why the arrows did nothing

They are not buttons. They are two triangles drawn straight onto the block:

```c
/* interface_widgets.cc, draw_clip_tri() */
if (block->flag & BLOCK_CLIPTOP) {
  draw_icon_tri(BLI_rcti_cent_x(rect), rect->ymax - (6 * UI_SCALE_FAC) / block->aspect, ...);
}
```

What makes the mouse work is not the triangle but the band behind it. Resting the
cursor there passes `menu_scroll_test()`, which starts
`PopupBlockHandle::scrolltimer`, and the timer walks the menu a row at a time
([interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc),
`handle_menu_event`). A finger cannot hover, so the timer never starts.

Worse, the band swallows presses by design:

```c
/* interface_query.cc:349, in but_find_mouse_over_ex() */
/* Skip when the mouse is hovering auto-scroll handlers. */
if ((block.flag & BLOCK_CLIPTOP && block.rect.ymax - UI_MENU_SCROLL_MOUSE < my) || ...) {
  continue;
}
```

No button is ever found under the arrows. That is right for a mouse -- it stops
you clicking a half-scrolled item -- and it is exactly why a tap there did
nothing at all.

The second route is `menu->mmb_panning`: hold the middle mouse button and drag,
and `menu_scroll_apply_offset_y()` follows the cursor. The gesture is the right
one. It was simply bound to a button no phone has.

## What was built

Three changes, all inert unless the block is actually clipped, so a menu that
fits behaves exactly as it did.

**The band is twice as tall**, and the triangle with it:

```c
#ifdef __ANDROID__
#  define UI_MENU_SCROLL_ARROW (24 * UI_SCALE_FAC)
#else
#  define UI_MENU_SCROLL_ARROW (12 * UI_SCALE_FAC)
#endif
```

`UI_MENU_SCROLL_MOUSE` derives from it, and that is what both the hit test and
the drawing use, so one constant moves the band, the reserved space and the hit
zone together. The glyph is scaled by dividing `block->aspect` -- `draw_icon_tri()`
takes its size from the widget unit over the aspect and has no size argument.

**A tap on the band steps**, by three rows rather than one: at one row per tap it
would take a dozen taps to cross File.

**A drag anywhere in the popup pans it.** A press arms the gesture and is *not*
consumed, so a tap still presses the item under it, exactly as this port already
does for headers and panels. Once the drag threshold is crossed the active button
is cancelled -- so it neither fires nor stays highlighted under a moving finger --
and from there the content follows the finger, same sign as the middle mouse pan.
The release is swallowed only if a pan happened, so the item the finger drifted
onto is not pressed.

It lives in `handle_menu_touch_scroll_event()`, called from `handle_menu_event()`
just before the middle-mouse handler, and the state is four fields on
`PopupBlockHandle`.

## Why the dialogs came for free

The request named modal dialogs separately, and they needed no separate work.

Every popup in the program -- menus, popovers, pies, search boxes, context menus
and operator dialogs -- is created by `popup_block_create()`, laid out by
`popup_block_refresh()`, and handled by `popup_handler()` then
`handle_menus_recursive()` then `handle_menu_event()`. And the scroll state is on
the **handle**, not on anything menu-specific:

```c
/* interface_region_popup.cc:889, for every non-pie popup */
handle->scrollmin = std::round(std::min(block->rect.ymax - (ymax + bounds), 0.0f));
handle->scrollmax = std::round(std::max(block->rect.ymin - (ymin - bounds), 0.0f));
```

`popup_block_clip()` clips any of them to the window and `popup_block_scrolltest()`
sets `BLOCK_CLIPTOP` / `BLOCK_CLIPBOTTOM` on whatever overflows. One handler at
that junction reaches all of them.

---

# Part 7: The dialog that would not be clipped

"Save changes before closing?" was cut off at the right edge upright, with the
Save button -- the one it wants you to press -- the half that fell off.

It is not the text. The block asks not to be clipped:

```c
/* wm_files.cc, block_create__close_file_dialog() */
block_flag_enable(block, BLOCK_KEEP_OPEN | BLOCK_LOOP | BLOCK_NO_WIN_CLIP | BLOCK_NUMSELECT);
```

`popup_block_clip()` trims every other popup to the window. This one opts out, so
when three buttons side by side at the touch menu scale come to more than the
1080 px of a phone held upright, the surplus is simply drawn past the edge.

Upright, then: a narrower alert box, and the buttons in a column rather than a
row. The column keeps the order the row read in -- Don't Save, Cancel, Save -- so
the button someone already knows to reach for is still the last one.

The orientation is read with `WM_window_native_pixel_x/y`, the same test the top
bar and the on-screen keyboard use, and nothing is stored.

Worth noting what was *not* done: `BLOCK_NO_WIN_CLIP` was left alone. Clipping
the dialog would have hidden the same button rather than dropping it off the
edge, which is not an improvement, and the flag is there because a dialog that
slides under the window edge is worse than one that overflows it. Making it fit
is the fix; making it clip is not.

---

# Part 8: Risks, in the order they are likely to bite

**1. Tool icon cache thrash.** `ICON_TYPE_GEOM` icons cache exactly one
rasterised size and re-rasterise when asked for a different one
([interface_icons.cc:1729-1741](source/blender/editors/interface/interface_icons.cc),
with the upstream comment "This could re-generate often if rendered at different
sizes in the one interface"). If the same tool icon appears both in a scaled
region and an unscaled one in the same frame, it re-rasterises **twice per
frame**. Check the 3D view with the tool bar open and the tool header visible.
If it shows up in the frame time, the answer is to scale `RGN_TYPE_TOOLS` and
`RGN_TYPE_TOOL_HEADER` together, or to teach the cache two sizes.

**2. Font cache growth.** Two `UI_SCALE_FAC` values means two BLF glyph caches
per font. Bounded and small, but worth a look at RSS on the device.

**3. Regions that lay out outside the guard.** Any region whose geometry is
computed somewhere other than the five sites will come out at the wrong size and
will look subtly misaligned rather than obviously broken. The way to catch these
is not to read code: set the multiplier to something absurd like 2.5 in a debug
build and look at the screen. Anything that did not move is a missing site.

**4. Hit testing.** Nothing needs doing here, and it is worth knowing why.
Button rects are stored in region pixel space at layout time and hit-tested
against the stored values. The event path never recomputes a size from
`UI_UNIT_*`. This holds as long as the guard covers layout and draw as one unit
— which is why sites 1 and 2 are both needed even though most headers only use
one of them.

**5. `style_get_dpi()` returns a pointer to a function-local `static`**
([interface_style.cc:424-449](source/blender/editors/interface/interface_style.cc)).
It is recomputed on every call, so a pointer held across a scale change goes
stale. This is already true upstream and no current code does it, but new code
under the guard must not cache it either.

**6. Editor minimum sizes.** Taller headers raise `ED_area_headersize()`, which
raises the minimum area height in
[screen_geometry.cc:225-267](source/blender/editors/screen/screen_geometry.cc)
and the join and snap thresholds in `screen_ops.cc`. At 1.65x effective scale a
header is around 43 px instead of 26. On a 1080-wide portrait phone that is
fine; it is worth re-checking against the four-way splits in the Animation and
Compositing workspaces.

**7. Interaction with the touch border grab.** This tree already moves a press
onto a nearby editor border before queuing it
(`ED_screen_edge_snap_for_touch()`,
[screen_geometry.cc](source/blender/editors/screen/screen_geometry.cc)). Its
threshold is in scaled pixels via `U.border_width * UI_SCALE_FAC`. Taller headers
mean a finger near a header/content boundary is now near a **bigger** button as
well as the border. Test that a tap on the leftmost header button still presses
it rather than grabbing the edge.

**8. `--reconfigure` and `--repackage`.** The DNA field needs the first. Any
change under `scripts/` needs the second. Both traps are silent, both are in
[ANDROID_AI_GUIDE.md](ANDROID_AI_GUIDE.md).

---

# Part 9: The change list

Ordered so each step can be built and looked at on the device before the next.
All six are built.

### Step 1 — the preference and the primitive

| File | Change |
| --- | --- |
| [DNA_userdef_types.h](source/blender/makesdna/DNA_userdef_types.h) | `USER_UI_SCALE_MENU_DEFAULT` in the platform block (587); `float ui_scale_menu` beside `ui_scale` (1054) |
| [versioning_userdef.cc](source/blender/blenloader/intern/versioning_userdef.cc) | Default an existing preferences file, beside `border_width` (1615) |
| [rna_userdef.cc](source/blender/makesrna/intern/rna_userdef.cc) | The property beside `ui_scale` (5064), plus the host-tool default workaround already used for `pressure_threshold_max` |
| [space_userpref.py](scripts/startup/bl_ui/space_userpref.py) | One `col.prop` under Resolution Scale (231) — **needs `--repackage`** |
| new [screen_menu_scale.cc](source/blender/editors/screen/screen_menu_scale.cc) + [ED_screen.hh](source/blender/editors/include/ED_screen.hh) | `ED_ui_menu_scale()`, `ED_region_uses_menu_scale()`, `ScopedMenuScale` |
| [BKE_blender_version.h](source/blender/blenkernel/BKE_blender_version.h) | Subversion bump, so versioning can tell "no extra size" from "field did not exist" |

**Build with `--reconfigure --repackage`.** Nothing changes on screen yet.

### Step 2 — the bars

| File | Change |
| --- | --- |
| [area.cc:4072](source/blender/editors/screen/area.cc) | `ED_area_headersize()` multiplies by `ED_ui_menu_scale()` |

Everything with a horizontal bar gets taller: every editor header, the tool
header, footers, the top bar, the status bar, and the minimum area heights that
follow them. The **buttons inside** are still the old size — that is expected at
this step, and it is the proof that height and content are separately
controlled.

### Step 3 — the content of the bars, and the popups

| File | Change |
| --- | --- |
| [area.cc](source/blender/editors/screen/area.cc) | `ScopedMenuScale` in `ED_region_do_layout()` |
| [area.cc](source/blender/editors/screen/area.cc) | `ScopedMenuScale` in `ED_region_do_draw()`, scoped to end before `region_draw_azones()` — the action zones are positioned outside any guard, so a scaled glyph on an unmoved hit area is the bug that avoids |
| [interface_region_popup.cc](source/blender/editors/interface/regions/interface_region_popup.cc) | `ScopedMenuScale` in `popup_block_refresh()`, honouring `PopupBlockHandle::use_menu_scale` |
| [interface_intern.hh](source/blender/editors/interface/interface_intern.hh), [UI_interface_c.hh](source/blender/editors/include/UI_interface_c.hh), [interface_region_menu_popup.cc](source/blender/editors/interface/regions/interface_region_menu_popup.cc) | The `use_menu_scale` flag and its defaulted argument |
| [wm_splash_screen.cc](source/blender/windowmanager/intern/wm_splash_screen.cc) | Splash and About opt out |

Buttons, labels, icons and menus reach 1.5x. This is the step to look hard at on
the phone.

### Step 4 — the vertical regions

| File | Change |
| --- | --- |
| [area.cc](source/blender/editors/screen/area.cc) | `ScopedMenuScale` in `region_rect_recursive()`, released with `reset()` before it recurses into `region->next` |

The Properties tab column and the tool bars get wider to match the icons that
step 3 already enlarged.

### Step 5 — the collapsed top bar

| File | Change |
| --- | --- |
| [space_topbar.py](scripts/startup/bl_ui/space_topbar.py) | `TOPBAR_MT_touch_menu` with the pull-downs and the workspaces, the single button and the undo/redo pair in `draw_left()`, `_topbar_is_upright()` and `ui_units_x` on the scene and view layer rows in `draw_right()` — **needs `--repackage`** |
| [interface_intern.hh](source/blender/editors/interface/interface_intern.hh) | Declare `ui_but_menu_is_open()` |
| [interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc) | Define it against `BUTTON_STATE_MENU_OPEN` |
| [interface_query.cc](source/blender/editors/interface/interface_query.cc) | `button_icon()` returns `ICON_KEY_MENU_FILLED` in place of `ICON_COLLAPSEMENU` while the menu is open |

No DNA change: the condition is the window shape, read at draw time, and nothing
is stored.

### Step 6 — reaching a tall menu with a finger

| File | Change |
| --- | --- |
| [interface_intern.hh](source/blender/editors/interface/interface_intern.hh) | `UI_MENU_SCROLL_ARROW` doubled on Android; four `touch_scroll_*` fields on `PopupBlockHandle` |
| [interface_widgets.cc](source/blender/editors/interface/interface_widgets.cc) | `draw_clip_tri()` draws the glyph at twice the size, centred in the taller band |
| [interface_handlers.cc](source/blender/editors/interface/interface_handlers.cc) | `handle_menu_touch_scroll_event()`, called from `handle_menu_event()` before the middle-mouse handler |

Covers dialogs as well as menus, because every popup shares that handler and the
scroll state lives on the handle. See Part 6.

### Step 7 — the save dialog upright

| File | Change |
| --- | --- |
| [wm_files.cc](source/blender/windowmanager/intern/wm_files.cc) | A narrower alert box and the buttons in a column when the window is taller than it is wide |

See Part 7 for why the dialog was never clipped to the window in the first place.

---

# Part 10: How to check it on the device

Rotation is a variable, so force it rather than turning the phone
([ANDROID_AI_GUIDE.md](ANDROID_AI_GUIDE.md), Part 2):

```bash
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 0     # portrait
adb exec-out screencap -p > portrait.png
adb shell settings put system user_rotation 1     # landscape
adb exec-out screencap -p > landscape.png
adb shell settings put system accelerometer_rotation 1
```

The checklist, per step:

Steps 1 to 4, all confirmed on a Galaxy S24 Ultra:

- Header height changed but the 3D viewport keeps its pixels. **Confirmed.**
- Menu Scale dragged from 0.50 to 0.00: the top bar, the navigation bar and the
  status bar shrink live, and the panel content beside them does not move a
  pixel. Back up again and they grow. **Confirmed** — this is the single test
  that proves the scope is right and the guard is not leaking.
- "Reset to Default Value" on Menu Scale hands back **0.50**, not 0.0. That is
  the makesrna host-tool trap, and it is worth re-testing whenever the default
  moves.
- Properties editor: the tab icons on the left are bigger, the panel content on
  the right is not. **Confirmed.**
- Pull-down from the top bar: menu items one comfortable thumb apart.
  **Confirmed.**
- Splash and About fit in landscape and are not scaled. **Confirmed.**

Still to check:

- Resolution Scale at 1.0 / 1.4 with Menu Scale left alone: the menus should move
  **with** it. This is the specific thing a `=` instead of a `*=` would break.
- Portrait: one `COLLAPSEMENU` button, and it becomes `KEY_MENU_FILLED` while
  open. Landscape: the menus are back inline. (Step 5, not built.)
- Portrait: a workspace can be switched without scrolling the top bar.
- Set the preference to 1.0 in a scratch build and take one screenshot per
  workspace. Anything that did not grow is a region the guard is not reaching.
- Frame time while orbiting with the tool bar open, against a build without the
  change. This is risk 1.

Verify the change is actually in the binary before believing any of it:

```bash
find "$BUILD_BASE/build_android_full" -name 'area.cc.o' -newermt '-10 minutes'
unzip -p "$BUILD_BASE/android_apk_stage_full/assets/blender_runtime.zip" \
  scripts/modules/_bpy_types.py | grep -n 'portrait'
```

---

# Summary

| Question | Answer |
| --- | --- |
| One knob or many? | One. `U.scale_factor` and `U.widget_unit` reach all 1784 sizing call sites |
| How is it scoped? | An RAII guard that multiplies those globals, at five sites |
| Does Resolution Scale still govern it? | Yes — `*=`, not `=`. The preference stores the extra fraction (0.5), and `ED_ui_menu_scale()` returns `1.0 + it` |
| Does the editor content move? | No. `RGN_TYPE_WINDOW`, `RGN_TYPE_UI`, `RGN_TYPE_CHANNELS` and `RGN_TYPE_PREVIEW` are outside the guard |
| Will the icons blur? | No. Blender's icons are SVG here and rasterise per size. Only tool `.dat` icons have a cache concern |
| Is the collapsed menu new work? | Mostly not. `Menu.draw_collapsible()` already collapses to `COLLAPSEMENU`. What is new: making portrait force it without writing the saved flag, the `KEY_MENU_FILLED` open state, and a workspace switcher to replace the tab strip |
| What it cost to find | Three builds: one lost to DNA alignment, one to the splash growing with everything else |
| Biggest unknown | Tool-icon cache thrash when the same geom icon is drawn at two sizes in one frame |
| Build traps | New DNA field means `--reconfigure`, and a lone `float` in `UserDef` needs 4 bytes of padding beside it or makesdna refuses. Python and preferences UI mean `--repackage` |

---

## Follow-up: toolbar resizing, 2026-10-29

The toolbar's stored `ARegion.sizex/sizey` values are logical units. The guard in
`region_rect_recursive()` multiplies them by the region's effective scale to lay
out the physical rectangle, then divides by that same scale when writing back.
`region_scale_modal()` instead divided pointer deltas by the base UI scale, so
at Menu Scale 0.50 each physical pixel dragged produced about 1.5 pixels of width.
`region_scale_invoke()` also calculated the maximum size at the base scale.

Both operator callbacks now hold `ScopedMenuScale(rmd->region, rmd->area)`. The
target region matters: the event context can be the neighboring canvas, which
deliberately does not use menu scaling. The guard covers size limits, delta
conversion, snap callbacks and collapse thresholds, and restores the global
scale before returning. Content regions retain their base scale. Existing
one/two-column toolbar snapping remains in place.

The earlier observation that a tap merely armed resizing was a separate event
ordering defect. Android can queue a touch press together with its motion and
release. `actionzone_apply()` appended `EVT_ACTIONZONE_REGION` behind them and
initialized its coordinates from the latest event state. The modal operator
therefore started too late and could use the end of the gesture as its origin.
On Android only, region action-zone events are now inserted immediately after
the event being handled and use `sActionzoneData.x/y`, the triggering press.
The existing operator receives the pending motion and release in order. Other
action-zone event types retain their existing dispatch order.

Device evidence: SM-S928B (S24 Ultra), portrait 1080 x 2340, Resolution Scale
1.10, Menu Scale 0.50. Baseline APK `blender-full-20261029-180013.apk`, final
APK `blender-full-20261029-183530.apk`, source based on `9027fbc0d` plus this
operator patch and the pre-existing local changes. Both native
rebuilds recompiled `screen_ops.cc.o`; the final APK signature verified and
installation used `adb install -r`.

Measurements use ADB touch swipes and a temporary Python timer recording actual
region rectangles, rather than estimating positions in scaled screenshots:

| Case | Pointer displacement | Toolbar width before → after |
| --- | --- | --- |
| Baseline, extra scale 0.50 | +100 px | 540 → 688 px (+148) |
| Fixed, first gesture, no preceding tap | +355 px | 155 → 510 px (+355) |
| Fixed, further expansion | +100 px | 510 → 609 px (+99) |
| Fixed, contraction | -100 px | 609 → 510 px (-99) |
| Fixed, extra scale 0.00 | +100 px | 340 → 439 px (+99) |

The user confirmed movement speed in the scale-only APK, then confirmed the bug
fixed after the follow-up gesture patch. No project or preferences were saved by the probe.
The right-sidebar attempt did not produce a reliable resize measurement, so it
is not counted as a device pass. Extra scale 1.00, vertical region resizing,
stylus/mouse and landscape remain unmeasured for this specific change.

An early test pressing Escape at startup encountered a separate popup handler
null-window crash (`handle_menu_event()`, `interface_handlers.cc:12014`), before
the probe produced samples or region resizing ran. Subsequent measurements
disabled the splash for the test session. That crash is not claimed fixed here.
