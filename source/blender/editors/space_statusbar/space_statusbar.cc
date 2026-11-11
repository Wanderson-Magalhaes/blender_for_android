/* SPDX-FileCopyrightText: 2023 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup spstatusbar
 */

#include <cstring>

#include "DNA_space_types.h"
#include "MEM_guardedalloc.h"

#include "BLI_listbase.hh"
#include "BLI_string_utf8.hh"

#include "BKE_context.hh"
#include "BKE_screen.hh"

#include "ED_screen.hh"
#include "ED_space_api.hh"

#include "UI_interface.hh"

#include "BLO_read_write.hh"

#include "WM_message.hh"
#include "WM_types.hh"

namespace blender {

/* ******************** default callbacks for statusbar space ******************** */

static SpaceLink *statusbar_create(const ScrArea * /*area*/, const Scene * /*scene*/)
{
  ARegion *region;
  SpaceStatusBar *sstatusbar;

  sstatusbar = MEM_new<SpaceStatusBar>("init statusbar");
  sstatusbar->spacetype = SPACE_STATUSBAR;

  /* Touch: two header regions, so the far left of the status bar can hold something that does not
   * move.
   *
   * The bar overflows on a phone -- the input hints and the memory figures together are wider than
   * the screen -- and this fork lets a finger drag a header sideways to read the rest. One region
   * means everything travels together, including the on-screen keyboard button at the far left,
   * which is the one control that has to stay reachable: scrolling far enough to read the VRAM
   * figure pushed it off the edge.
   *
   * The button region comes **first** and the figures come last, and that order is not cosmetic.
   * region_rect_recursive() forces the last region in the list to RGN_ALIGN_NONE -- the "user
   * errors" line in area.cc -- so whichever region is last cannot be the aligned one. Built the
   * other way round, with the button last and RGN_SPLIT_PREV on it, the button region was handed
   * the whole of its neighbour rect and the figures came out zero wide and invisible.
   *
   * The button region is the aligned one for a second reason: it is flagged
   * #RGN_FLAG_DYNAMIC_SIZE in statusbar_header_region_init() and so takes the width its own
   * content asks for. The button is one button wide and never changes. The figures cannot be that
   * region -- with the hints and the memory and the VRAM in them they ask for more than the bar
   * has, and squeeze the other side away to nothing. */
  region = BKE_area_region_new();
  BLI_addtail(&sstatusbar->regionbase, region);
  region->regiontype = RGN_TYPE_HEADER;
  region->alignment = RGN_ALIGN_LEFT;

  /* header region */
  region = BKE_area_region_new();
  BLI_addtail(&sstatusbar->regionbase, region);
  region->regiontype = RGN_TYPE_HEADER;
  region->alignment = RGN_ALIGN_NONE;

  return reinterpret_cast<SpaceLink *>(sstatusbar);
}

/* Doesn't free the space-link itself. */
static void statusbar_free(SpaceLink * /*sl*/) {}

/* spacetype; init callback */
static void statusbar_init(wmWindowManager * /*wm*/, ScrArea * /*area*/) {}

static SpaceLink *statusbar_duplicate(SpaceLink *sl)
{
  SpaceStatusBar *sstatusbarn = MEM_dupalloc(reinterpret_cast<SpaceStatusBar *>(sl));

  /* clear or remove stuff from old */

  return reinterpret_cast<SpaceLink *>(sstatusbarn);
}

/* add handlers, stuff you only do once or on area/region changes */
static void statusbar_header_region_init(wmWindowManager * /*wm*/, ARegion *region)
{
  /* Touch: LEFT joins RIGHT here. The keyboard button sits in a left-aligned split region and has
   * to be exactly as wide as itself; see statusbar_create(). */
  if (ELEM(RGN_ALIGN_ENUM_FROM_MASK(region->alignment), RGN_ALIGN_RIGHT, RGN_ALIGN_LEFT)) {
    region->flag |= RGN_FLAG_DYNAMIC_SIZE;
  }
  else {
    /* Touch: and the other region must not have it. Upstream set it on the one header this space
     * used to have, so a file saved before the split -- the bundled startup.blend included --
     * restores the figures region with the flag already on. Sized to its own content, and with
     * spacers in it asking for whatever is going spare, it came out empty. */
    region->flag &= ~RGN_FLAG_DYNAMIC_SIZE;
  }
  ED_region_header_init(region);
}

static void statusbar_operatortypes() {}

static void statusbar_keymap(wmKeyConfig * /*keyconf*/) {}

static void statusbar_header_region_listener(const wmRegionListenerParams *params)
{
  ARegion *region = params->region;
  const wmNotifier *wmn = params->notifier;

  /* context changes */
  switch (wmn->category) {
    case NC_SCREEN:
      if (ELEM(wmn->data, ND_LAYER, ND_ANIMPLAY)) {
        ED_region_tag_redraw(region);
      }
      break;
    case NC_WM:
      if (wmn->data == ND_JOB) {
        ED_region_tag_redraw(region);
      }
      break;
    case NC_SCENE:
      if (wmn->data == ND_RENDER_RESULT) {
        ED_region_tag_redraw(region);
      }
      break;
    case NC_SPACE:
      if (wmn->data == ND_SPACE_INFO) {
        ED_region_tag_redraw(region);
      }
      break;
    case NC_ID:
      if (wmn->action == NA_RENAME) {
        ED_region_tag_redraw(region);
      }
      break;
  }
}

static void statusbar_header_region_message_subscribe(const wmRegionMessageSubscribeParams *params)
{
  wmMsgBus *mbus = params->message_bus;
  ARegion *region = params->region;

  wmMsgSubscribeValue msg_sub_value_region_tag_redraw{};
  msg_sub_value_region_tag_redraw.owner = region;
  msg_sub_value_region_tag_redraw.user_data = region;
  msg_sub_value_region_tag_redraw.notify = ED_region_do_msg_notify_tag_redraw;

  WM_msg_subscribe_rna_anon_prop(mbus, Window, view_layer, &msg_sub_value_region_tag_redraw);
  WM_msg_subscribe_rna_anon_prop(mbus, ViewLayer, name, &msg_sub_value_region_tag_redraw);
}

static void statusbar_space_blend_write(BlendWriter *writer, SpaceLink *sl)
{
  writer->write_struct_cast<SpaceStatusBar>(sl);
}

void ED_spacetype_statusbar()
{
  std::unique_ptr<SpaceType> st = std::make_unique<SpaceType>();
  ARegionType *art;

  st->spaceid = SPACE_STATUSBAR;
  STRNCPY_UTF8(st->name, "Status Bar");
  st->struct_size = sizeof(SpaceStatusBar);

  st->create = statusbar_create;
  st->free = statusbar_free;
  st->init = statusbar_init;
  st->duplicate = statusbar_duplicate;
  st->operatortypes = statusbar_operatortypes;
  st->keymap = statusbar_keymap;
  st->blend_write = statusbar_space_blend_write;

  /* regions: header window */
  art = MEM_new_zeroed<ARegionType>("spacetype statusbar header region");
  art->regionid = RGN_TYPE_HEADER;
  art->prefsizey = 0.8f * HEADERY;
  art->prefsizex = UI_UNIT_X * 5; /* Mainly to avoid glitches */
  art->keymapflag = ED_KEYMAP_UI | ED_KEYMAP_VIEW2D | ED_KEYMAP_HEADER;
  art->init = statusbar_header_region_init;
  art->layout = ED_region_header_layout;
  art->draw = ED_region_header_draw;
  art->listener = statusbar_header_region_listener;
  art->message_subscribe = statusbar_header_region_message_subscribe;
  BLI_addhead(&st->regiontypes, art);

  BKE_spacetype_register(std::move(st));
}

}  // namespace blender
