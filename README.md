# SurrealUI — Custom WoW 3.3.5 Interface

A complete custom UI suite for AzerothCore WoTLK 3.3.5a servers, built with [AIO (mod-aio)](https://github.com/Rochet2/AIO) and [Eluna (mod-ale)](https://github.com/azerothcore/mod-eluna).

All UI scripts are server-pushed to the client on login — **no client addons required**.

---

## Scripts

| File | Keybind | Description |
|------|---------|-------------|
| `SurrealCharacter_AIO.lua` | `C` / `/char` | Custom character panel — 3D model, equipment slots with drag/drop, dual stat dropdowns, title selector, embedded gem socketing, skin system |
| `SurrealTalentFrame_AIO.lua` | `N` | Custom talent tree with choice nodes and glyph bar |
| `SurrealSpellBook_AIO.lua` | `P` | Custom spellbook with tabs and click-to-cast |
| `SurrealCollections_AIO.lua` | `Y` | AtlasLoot-style item browser replacing Achievements UI |
| `SurrealStats_AIO.lua` | — | Tooltip stat name replacements (Dodge→Crit, Parry→Mastery, etc.) |
| `SurrealPlayerFrame_AIO.lua` | — | Hooks mana bar color for Demonology Warlock |
| `IDtip_AIO.lua` | — | Shows item/spell IDs in tooltips |

All panels are 980×640, centered, with mutual exclusion (opening one closes the others).

---

## Installation

1. Place all `*_AIO.lua` files in your server's `lua_scripts/` directory
2. Ensure the following modules are installed:
   - [mod-ale (Eluna)](https://github.com/azerothcore/mod-eluna) — Lua scripting engine
   - [mod-aio](https://github.com/Rochet2/AIO) — Server→client Lua push system
3. Restart or reload the worldserver: `reload ale`
4. Players relog to receive the UI

---

## Renamed Stats (mod-stats-expanded)

The UI integrates with a custom stat renaming system:

| Original Stat | Renamed To |
|---------------|------------|
| Defense Rating | Haste |
| Dodge Rating | Crit |
| Parry Rating | Mastery |
| Block Rating | Multistrike |
| Hit Rating | Versatility |

---

## Character Panel Features

- **Equipment Slots** — Drag-and-drop equip/unequip using native `PickupInventoryItem` API
- **Right-click Socketing** — Right-click any equipped item to open the gem socketing UI (embedded in-frame)
- **3D Model** — Mouse-drag to rotate, auto-refreshes on gear changes (ClearModel + deferred SetUnit)
- **Dual Stat Dropdowns** — Two independent columns: Base Stats, Melee, Ranged, Spell, Defenses
- **Title Selector** — Dropdown of server-validated earned titles (uses Eluna `Player:HasTitle()`)
- **Quality Borders** — Colored rarity borders on equipped items
- **Equipment Manager** — Coming Soon placeholder

---

## Custom Skin System (4-File Border)

The character panel includes a `ApplySurrealSkin()` function that supports custom border art using 4 texture files. This system is reusable across all Surreal panels.

### How It Works

When `SKIN_CUSTOM = true` in the Lua, the frame draws its border from 4 manually-placed textures instead of the default `SetBackdrop` edge. This gives full artistic control over corners and edges at any frame size.

### Files Required

Place these in a patch MPQ at `Interface\SurrealUI\`:

| File | Dimensions | Content |
|------|-----------|---------|
| `Border_Special.tga` | 128×128 | Unique top-left corner ("hero" piece) |
| `Border_Corners.tga` | 256×128 | Atlas containing TR, BL, and BR corners |
| `Border_Edge_H.tga` | 64×128 | Horizontally tileable strip (top/bottom edges) |
| `Border_Edge_V.tga` | 128×64 | Vertically tileable strip (left/right edges) |

### Corner Atlas Layout (`Border_Corners.tga`)

```
256px wide × 128px tall

┌──────────────┬──────────────┐
│   TR corner  │              │
│   (128×64)   │  BR corner   │
│              │  (128×128)   │
├──────────────┤              │
│   BL corner  │              │
│   (128×64)   │              │
└──────────────┴──────────────┘
```

TexCoord mapping:
- **TR** = `(0, 0.5, 0, 0.5)`
- **BL** = `(0, 0.5, 0.5, 1)`
- **BR** = `(0.5, 1, 0, 1)`

### Creating Your Art

1. **Design** in Photoshop/GIMP at the sizes listed above
   - Use the Info Panel set to **Percent** — selection percentages map directly to `SetTexCoord` values
   - Use `wow.export` to browse Blizzard's existing UI textures as reference/templates
2. **Save** as 32-bit TGA (uncompressed, with alpha channel for transparency)
3. **Convert** TGA → BLP using [BLP Lab](https://www.hiveworkshop.com/threads/blp-lab-v0-5-0.137599/) or BLPNG Converter
   - Use DXT3 or DXT5 compression (supports alpha)
4. **Pack** into a patch MPQ (e.g., `patch-S.mpq`) with path `Interface\SurrealUI\`
5. **Deploy** — players place the MPQ in their WoW `Data/` folder
6. **Activate** — set `SKIN_CUSTOM = true` in `SurrealCharacter_AIO.lua`

### Configuration

In `SurrealCharacter_AIO.lua`, adjust these values:

```lua
local SKIN_CUSTOM  = false              -- Set true when art files are ready
local SKIN_PATH    = "Interface\\SurrealUI\\"  -- Path in the MPQ
local CORNER_SIZE  = 64                 -- Pixel size of corner textures on screen
local EDGE_THICK   = 16                 -- Pixel thickness of edge strips on screen
```

---

## Technical Notes

- **WoW 3.3.5 API Limitations:**
  - `SetShown()` does not exist — use `Show()`/`Hide()` toggle
  - `C_Timer` does not exist — use OnUpdate-based deferred calls
  - `GetEquipmentSetIDs()` does not exist (Cataclysm+)
  - Protected functions (`PickupInventoryItem`, etc.) only work from hardware event handlers

- **Reloading:** `reload ale` on the worldserver reloads server-side Lua. Players must relog to receive updated client-side AIO scripts.

- **Mutual Exclusion:** All Surreal panels hide each other on show. The Blizzard CharacterFrame, AchievementsFrame, SpellBookFrame, and PlayerTalentFrame are suppressed/overridden.

---

## License

MIT
