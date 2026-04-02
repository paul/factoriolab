#!/usr/bin/env lua
--[[
  extract-desynced.lua

  Extracts all Desynced game data and generates:
    src/data/dsy/data.json  — FactorioLab mod data file
    src/data/dsy/icons.webp — sprite sheet (64x64 icons, 20 per row, 66px stride)

  After running this script, fill in icon colors with:
    npm run calculate-color dsy

  Usage:
    lua scripts/extract-desynced.lua <desynced_install_dir>

  Example:
    lua scripts/extract-desynced.lua \
      ~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/Desynced/Desynced

  Requirements: lua, unzip, magick (ImageMagick 7)
]]

-- ---------------------------------------------------------------------------
-- Argument parsing
-- ---------------------------------------------------------------------------

local install_dir = arg[1]
if not install_dir then
  io.stderr:write("Usage: lua scripts/extract-desynced.lua <desynced_install_dir>\n")
  os.exit(1)
end

install_dir = install_dir:gsub("[/\\]+$", "")
local zip_path = install_dir .. "/Content/mods/main.zip"

-- Resolve the repo root relative to this script's location so output paths
-- work regardless of cwd.
local script_path = arg[0]
-- arg[0] may be just the filename if run from the repo root; normalise it
local repo_root = script_path:match("^(.*)/scripts/[^/]+$") or "."

local output_dir  = repo_root .. "/src/data/dsy"
local data_json   = output_dir .. "/data.json"
local icons_webp  = output_dir .. "/icons.webp"

-- ---------------------------------------------------------------------------
-- Shell helpers
-- ---------------------------------------------------------------------------

local function run(cmd)
  local ok, _, code = os.execute(cmd)
  if not ok then
    io.stderr:write(("Command failed (exit %s): %s\n"):format(tostring(code), cmd))
    os.exit(1)
  end
end

local function mktemp()
  local h = io.popen("mktemp -d")
  local d = h:read("*l")
  h:close()
  if not d or d == "" then
    io.stderr:write("Failed to create temp directory\n")
    os.exit(1)
  end
  return d
end

-- ---------------------------------------------------------------------------
-- Extract game files
-- ---------------------------------------------------------------------------

local tmp_dir = mktemp()

run(("unzip -q %q def.json data/utilities.lua data/items.lua "
     .. "data/components.lua data/frames.lua -d %q"):format(zip_path, tmp_dir))

-- ---------------------------------------------------------------------------
-- Read game version from def.json
-- ---------------------------------------------------------------------------

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

-- Minimal JSON string extraction — def.json is small and regular
local def_json    = read_file(tmp_dir .. "/def.json")
local game_version = def_json:match('"version_name"%s*:%s*"([^"]+)"') or "1.0"

-- ---------------------------------------------------------------------------
-- Mock game engine globals
-- ---------------------------------------------------------------------------

data = {
  items                      = {},
  components                 = {},
  frames                     = {},
  update_mapping             = {},
  settings                   = {},
  text_vars                  = {},
  component_register_filters = {},
}

local _noop_mt = { __index = function() return function() end end }
Debug         = setmetatable({}, _noop_mt)
Action        = setmetatable({}, _noop_mt)
EntityAction  = setmetatable({}, _noop_mt)
FactionAction = setmetatable({}, _noop_mt)
Game          = setmetatable({}, _noop_mt)
Tool          = setmetatable({}, _noop_mt)
UI            = setmetatable({}, _noop_mt)
UIMsg         = setmetatable({}, _noop_mt)
View          = setmetatable({}, _noop_mt)
Notification  = setmetatable({}, _noop_mt)
Delay         = setmetatable({}, _noop_mt)
Resimulator   = setmetatable({}, _noop_mt)
IMAGE         = setmetatable({}, _noop_mt)

L = function(fmt, ...) return fmt end

TICKS_PER_SECOND = 5

local _map_settings = setmetatable({}, { __index = function() return 0 end })
Map = setmetatable({ GetSettings = function() return _map_settings end }, _noop_mt)

FF_ALL=0; FF_OWNFACTION=0; FF_ENEMYFACTION=0; FF_NEUTRALFACTION=0
FF_ALLYFACTION=0; FF_WORLDFACTION=0; FF_OPERATING=0; FF_RESOURCE=0
FF_DROPPEDITEM=0; FF_CONSTRUCTION=0; FF_FOUNDATION=0; FF_WALL=0; FF_GATE=0
FRAMEREG_GOTO=0; FRAMEREG_VISUAL=0; REG_NOT=0; REG_INFINITE=0

-- Comp stub (overwritten by components.lua)
Comp = {
  slot_type  = "storage",
  stack_size = 1,
  texture    = "Main/textures/icons/frame/replace.png",
}
function Comp:RegisterComponent(id, comp)
  comp.id      = id
  comp.base_id = self.base_id or self.id or id
  if not comp.name then comp.name = id end
  data.components[id] = setmetatable(comp, { __index = self })
  return comp
end

-- Frame stub (overwritten by frames.lua)
Frame = {
  texture       = "Main/textures/icons/frame/replace.png",
  minimap_color = { 0.8, 0.8, 0.8 },
  shield_type   = "alloy",
}
function Frame:RegisterFrame(id, frame)
  data.frames[id] = setmetatable(frame, { __index = self })
  return data.frames[id]
end

-- ---------------------------------------------------------------------------
-- Load game data
-- ---------------------------------------------------------------------------

dofile(tmp_dir .. "/data/utilities.lua")
dofile(tmp_dir .. "/data/items.lua")
dofile(tmp_dir .. "/data/components.lua")
dofile(tmp_dir .. "/data/frames.lua")

run(("rm -rf %q"):format(tmp_dir))

-- ---------------------------------------------------------------------------
-- Deprecation detection (items only)
-- Deprecated items share the exact same table object reference.
-- ---------------------------------------------------------------------------

local item_ref_count = {}
for _, def in pairs(data.items) do
  local addr = tostring(def)
  item_ref_count[addr] = (item_ref_count[addr] or 0) + 1
end
local deprecated_refs = {}
for addr, count in pairs(item_ref_count) do
  if count > 1 then deprecated_refs[addr] = true end
end
local function is_deprecated_item(def)
  return deprecated_refs[tostring(def)] == true
end

-- ---------------------------------------------------------------------------
-- JSON encoder
-- ---------------------------------------------------------------------------

local function json_str(s)
  s = s:gsub('\\', '\\\\'); s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n'); s = s:gsub('\r', '\\r'); s = s:gsub('\t', '\\t')
  return '"' .. s .. '"'
end

local OBJECT_MT = {}
local function as_object(t) return setmetatable(t, OBJECT_MT) end

local function json_encode(val, indent, cur)
  indent = indent or 2; cur = cur or 0
  local nxt = cur + indent
  local pad, npad = string.rep(" ", cur), string.rep(" ", nxt)
  local t = type(val)
  if t == "nil" then return "null"
  elseif t == "boolean" then return val and "true" or "false"
  elseif t == "number" then
    return val == math.floor(val) and string.format("%d", val) or tostring(val)
  elseif t == "string" then return json_str(val)
  elseif t == "table" then
    local force_obj = getmetatable(val) == OBJECT_MT
    local is_arr = not force_obj
    local max_n = 0
    if is_arr then
      for k in pairs(val) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then is_arr = false; break end
        if k > max_n then max_n = k end
      end
      if is_arr and max_n ~= #val then is_arr = false end
    end
    if is_arr then
      if max_n == 0 then return "[]" end
      local parts = {}
      for i = 1, max_n do parts[i] = npad .. json_encode(val[i], indent, nxt) end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    else
      local keys = {}
      for k in pairs(val) do keys[#keys+1] = k end
      table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
      if #keys == 0 then return "{}" end
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts+1] = npad .. json_str(tostring(k))
                          .. ": " .. json_encode(val[k], indent, nxt)
      end
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
    end
  else error("Cannot encode type: " .. t) end
end

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

local function strip_main(path)
  return (path:gsub("^Main/", ""))
end

-- Build recipe entries from a def's production_recipe and/or mining_recipe.
-- Returns array of { producer_id, ticks, inputs, output_count }.
local function raw_recipes(def)
  local out = {}
  if def.production_recipe and def.production_recipe ~= false then
    local r = def.production_recipe
    local inputs = as_object({})
    for k, v in pairs(r.ingredients) do inputs[k] = v end
    for pid, ticks in pairs(r.producers) do
      out[#out+1] = { producer_id=pid, ticks=ticks, inputs=inputs, output_count=r.amount }
    end
    table.sort(out, function(a,b) return a.producer_id < b.producer_id end)
  end
  if def.mining_recipe then
    local mining = {}
    for pid, ticks in pairs(def.mining_recipe) do
      mining[#mining+1] = { producer_id=pid, ticks=ticks, inputs=as_object({}), output_count=1 }
    end
    table.sort(mining, function(a,b) return a.producer_id < b.producer_id end)
    for _, r in ipairs(mining) do out[#out+1] = r end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Extraction recipes (blight_extraction, blight_plasma, etc.)
-- Components with `extracts` + `extraction_time` synthesise recipes.
-- ---------------------------------------------------------------------------

local extraction_recipes = {}  -- item_id -> [{producer_id, ticks}]
for id, comp_def in pairs(data.components) do
  local target, ticks = comp_def.extracts, comp_def.extraction_time
  if target and ticks then
    extraction_recipes[target] = extraction_recipes[target] or {}
    extraction_recipes[target][#extraction_recipes[target]+1] =
      { producer_id=id, ticks=ticks, inputs=as_object({}), output_count=1 }
  end
end
for _, list in pairs(extraction_recipes) do
  table.sort(list, function(a,b) return a.producer_id < b.producer_id end)
end

-- ---------------------------------------------------------------------------
-- Collect all producer IDs (for machines list and recipe name lookup)
-- ---------------------------------------------------------------------------

local producer_ids = {}
local function collect_producers(def)
  if def.production_recipe and def.production_recipe ~= false then
    for pid in pairs(def.production_recipe.producers) do producer_ids[pid] = true end
  end
  if def.mining_recipe then
    for pid in pairs(def.mining_recipe) do producer_ids[pid] = true end
  end
end
for _, def in pairs(data.items)      do collect_producers(def) end
for _, def in pairs(data.components) do collect_producers(def) end
for _, def in pairs(data.frames)     do collect_producers(def) end
for _, list in pairs(extraction_recipes) do
  for _, r in ipairs(list) do producer_ids[r.producer_id] = true end
end
-- Buildings use the synthetic "player" producer
producer_ids["player"] = true

-- Build a lookup: producer_id -> display name
local function producer_name(pid)
  if pid == "player" then return "Player" end
  local c = data.components[pid]
  return c and c.name or pid
end

-- ---------------------------------------------------------------------------
-- Category mapping
-- ---------------------------------------------------------------------------

-- All item tags collapse into a single "item" category; the tag itself drives
-- the row assignment within that tab.
local TAG_TO_CATEGORY = {
  resource          = "item",
  simple_material   = "item",
  advanced_material = "item",
  hitech_material   = "item",
  research          = "item",
}

-- Row index for each item tag within the "item" category
-- (resource → 0, simple_material → 1, …, research → 4)
local TAG_ROW = {
  resource          = 0,
  simple_material   = 1,
  advanced_material = 2,
  hitech_material   = 3,
  research          = 4,
}

-- Row index for component attachment_size within the "component" category
local COMPONENT_SIZE_ROW = {
  Small    = 0,
  Medium   = 1,
  Large    = 2,
  Internal = 3,
}

-- Row index for frame race within "bot" and "building" categories
local RACE_ROW = {
  human = 0,
  alien = 1,
  robot = 2,
  virus = 3,
}

local CATEGORY_NAMES = {
  item      = "Items",
  component = "Components",
  bot       = "Bots",
  building  = "Buildings",
  machine   = "Machines",
}

-- Representative icon for each category tab (must exist in the data sprite sheet)
local CATEGORY_ICONS = {
  item      = "circuit_board",
  component = "c_fabricator",
  bot       = "f_bot_1s_a",
  building  = "f_amac",
  machine   = "c_mission_human_aicenter",
}

-- Category order for sort position
local CATEGORY_ORDER = {
  item=1, component=2, bot=3, building=4, machine=5,
}

-- ---------------------------------------------------------------------------
-- Build unified entity list
-- Each entity: { id, name, category, icon_path, stack_size, recipes,
--               machine (opt), module (opt) }
-- ---------------------------------------------------------------------------

local FRAME_SKIP_TYPES = { Decoration=true, Resource=true, DroppedItem=true, Construction=true }

local entities = {}  -- flat list, in section order

-- Helper: append entity if it has recipes (or is forced, e.g. machines)
local function push(id, name, category, icon_path, stack_size, recipes, extra)
  local e = {
    id         = id,
    name       = name,
    category   = category,
    icon_path  = icon_path,
    stack_size = stack_size,
    recipes    = recipes,
  }
  if extra then
    for k, v in pairs(extra) do e[k] = v end
  end
  entities[#entities+1] = e
end

-- Items
-- First pass: collect all ingredient IDs referenced across all recipe inputs
-- (items, components, frames) so we can include no-recipe items that are
-- used as ingredients (e.g. unstable_matter, virus_source_code).
local referenced_ingredients = {}
local function mark_ingredients(def)
  if def.production_recipe and def.production_recipe ~= false then
    for k in pairs(def.production_recipe.ingredients) do
      referenced_ingredients[k] = true
    end
  end
  if def.construction_recipe and type(def.construction_recipe) == "table" then
    for k in pairs(def.construction_recipe.ingredients) do
      referenced_ingredients[k] = true
    end
  end
end
for _, def in pairs(data.items)      do mark_ingredients(def) end
for _, def in pairs(data.components) do mark_ingredients(def) end
for _, def in pairs(data.frames)     do mark_ingredients(def) end

for id, def in pairs(data.items) do
  if is_deprecated_item(def) then goto skip end
  -- Items with production_recipe = false are non-craftable story items.
  -- Skip them unless they appear as an ingredient in another recipe.
  if def.production_recipe == false and not referenced_ingredients[id] then goto skip end
  local recipes = {}
  if def.production_recipe ~= false then
    recipes = raw_recipes(def)
  end
  -- Append extraction recipes
  if extraction_recipes[id] then
    for _, r in ipairs(extraction_recipes[id]) do recipes[#recipes+1] = r end
    table.sort(recipes, function(a,b) return a.producer_id < b.producer_id end)
  end
  -- Skip items with no recipes that aren't used as ingredients
  if #recipes == 0 and not referenced_ingredients[id] then goto skip end
  local tag = def.tag
  push(id, def.name, TAG_TO_CATEGORY[tag] or "item",
       strip_main(def.texture), def.stack_size, recipes,
       { row_group = TAG_ROW[tag] or 0, sort_index = def.index or 0 })
  ::skip::
end

-- Components
for id, def in pairs(data.components) do
  if type(def.production_recipe) ~= "table" then goto skip end
  if id:match("^c_mission_") then goto skip end
  local recipes = raw_recipes(def)
  local att = def.attachment_size
  local extra = { row_group = COMPONENT_SIZE_ROW[att] or 0, sort_index = def.index or 0 }
  -- Overclocking module field
  if def.base_id == "c_moduleefficiency"
     and (att == "Small" or att == "Medium" or att == "Large") then
    extra.module = as_object({ speed = def.boost / 100 })
  end
  push(id, def.name, "component", strip_main(def.texture), def.stack_size, recipes, extra)
  ::skip::
end

-- Bots
for id, def in pairs(data.frames) do
  if FRAME_SKIP_TYPES[def.type] then goto skip end
  if not def.movement_speed then goto skip end
  if type(def.production_recipe) ~= "table" then goto skip end
  local recipes = raw_recipes(def)
  if #recipes == 0 then goto skip end
  push(id, def.name, "bot", strip_main(def.texture), 1, recipes,
       { row_group = RACE_ROW[def.race] or 4, sort_index = def.index or 0 })
  ::skip::
end

-- Buildings
for id, def in pairs(data.frames) do
  if FRAME_SKIP_TYPES[def.type] then goto skip end
  if def.movement_speed then goto skip end
  if type(def.construction_recipe) ~= "table" then goto skip end
  local cr = def.construction_recipe
  local inputs = as_object({})
  for k, v in pairs(cr.ingredients) do inputs[k] = v end
  local recipes = {
    { producer_id="player", ticks=cr.ticks, inputs=inputs, output_count=1 }
  }
  push(id, def.name, "building", strip_main(def.texture), 1, recipes,
       { row_group = RACE_ROW[def.race] or 4, sort_index = def.index or 0 })
  ::skip::
end

-- Machines (producer components + synthetic "player")
--
-- Components that already appear in the entities list (because they have a
-- production_recipe) are NOT added again as machine-category items. Instead,
-- we tag them for a post-pass that adds the machine field to their existing
-- entry. Only pure producers (no production_recipe of their own) get a
-- separate machine-category item.

-- Build a set of component ids already added to entities
local component_entity_ids = {}
for _, e in ipairs(entities) do
  if e.category == "component" then
    component_entity_ids[e.id] = e
  end
end

-- Sort for deterministic output
local sorted_pids = {}
for pid in pairs(producer_ids) do sorted_pids[#sorted_pids+1] = pid end
table.sort(sorted_pids)

for _, pid in ipairs(sorted_pids) do
  local machine_def = as_object({
    speed   = 1,
    modules = 1,
    type    = "electric",
  })

  local icon_path, usage
  if pid == "player" then
    icon_path = "textures/icons/values/explorable.png"
    usage = 0
  else
    local c = data.components[pid]
    if not c then
      io.stderr:write(("Warning: producer %q not found in components\n"):format(pid))
      goto skip_machine
    end
    icon_path = strip_main(c.texture)
    usage = math.abs(c.power or 0)
  end

  machine_def.usage = usage

  if component_entity_ids[pid] then
    -- Already in entities as a component — just attach the machine field
    component_entity_ids[pid].machine = machine_def
  else
    -- Pure producer with no buildable recipe of its own — add as machine item
    push(pid, producer_name(pid), "machine", icon_path, 1, {},
         { machine = machine_def })
  end

  ::skip_machine::
end

-- Sort entities: by category order, then by row group, then by game index
table.sort(entities, function(a, b)
  local oa = CATEGORY_ORDER[a.category] or 99
  local ob = CATEGORY_ORDER[b.category] or 99
  if oa ~= ob then return oa < ob end
  local ra = a.row_group or 99
  local rb = b.row_group or 99
  if ra ~= rb then return ra < rb end
  local ia = a.sort_index or 0
  local ib = b.sort_index or 0
  if ia ~= ib then return ia < ib end
  return a.name < b.name  -- name as stable tiebreaker
end)

-- Assign row numbers based on semantic grouping:
--   item      → TAG_ROW[tag]
--   component → COMPONENT_SIZE_ROW[attachment_size]
--   bot/bld   → RACE_ROW[race]  (unknown race → 4)
--   machine   → 0
for _, e in ipairs(entities) do
  e.row = e.row_group or 0
end

-- ---------------------------------------------------------------------------
-- Build icon grid
-- 20 icons per row, 66px stride (64px + 1px padding each side)
-- ---------------------------------------------------------------------------

local ICONS_PER_ROW = 20
local ICON_STRIDE   = 66

local icon_path_list  = {}
local icon_path_index = {}

local function register_icon(path)
  if not icon_path_index[path] then
    local idx = #icon_path_list   -- 0-based
    icon_path_list[#icon_path_list+1] = path
    icon_path_index[path] = idx
  end
end

-- Walk entities in current (sorted) order to assign grid positions
for _, e in ipairs(entities) do
  register_icon(e.icon_path)
end

local function icon_position(path)
  local idx = icon_path_index[path]
  local col = idx % ICONS_PER_ROW
  local row = math.floor(idx / ICONS_PER_ROW)
  return (-(col * ICON_STRIDE) .. "px " .. -(row * ICON_STRIDE) .. "px")
end

-- ---------------------------------------------------------------------------
-- Build FactorioLab data.json sections
-- ---------------------------------------------------------------------------

-- Categories
local categories = {}
local seen_cats = {}
for _, e in ipairs(entities) do
  local cat = e.category
  if not seen_cats[cat] then
    seen_cats[cat] = true
    local cat_obj = as_object({
      id   = cat,
      name = CATEGORY_NAMES[cat] or cat,
    })
    if CATEGORY_ICONS[cat] then
      cat_obj.icon = CATEGORY_ICONS[cat]
    end
    categories[#categories+1] = cat_obj
  end
end

-- Icons  (color filled later by calculate-color.ts)
local icons_out = {}
for _, e in ipairs(entities) do
  icons_out[#icons_out+1] = as_object({
    id       = e.id,
    position = icon_position(e.icon_path),
  })
end
table.sort(icons_out, function(a,b) return a.id < b.id end)

-- Items
local items_out = {}
for _, e in ipairs(entities) do
  local item = as_object({
    id       = e.id,
    name     = e.name,
    category = e.category,
    row      = e.row,
  })
  if e.stack_size and e.stack_size > 0 then
    item.stack = e.stack_size
  end
  if e.machine then item.machine = e.machine end
  if e.module  then item.module  = e.module  end
  items_out[#items_out+1] = item
end

-- Recipes
-- Single producer  → id = item_id,             name = item_name
-- Multi producer   → id = item_id-producer_id, name = item_name (Producer Name)
local recipes_out = {}

for _, e in ipairs(entities) do
  if #e.recipes == 0 then goto skip_recipe end

  local multi = #e.recipes > 1

  for _, r in ipairs(e.recipes) do
    local rid  = multi and (e.id .. "-" .. r.producer_id) or e.id
    local rname = multi
      and (e.name .. " (" .. producer_name(r.producer_id) .. ")")
      or  e.name

    local recipe = as_object({
      id        = rid,
      name      = rname,
      category  = e.category,
      row       = e.row,
      time      = r.ticks * 0.2,
      producers = { r.producer_id },
      ["in"]    = r.inputs,
      out       = as_object({ [e.id] = r.output_count }),
    })
    recipes_out[#recipes_out+1] = recipe
  end

  ::skip_recipe::
end

-- ---------------------------------------------------------------------------
-- Assemble data.json
-- ---------------------------------------------------------------------------

local mod_data = as_object({
  version    = as_object({ Desynced = game_version }),
  categories = categories,
  icons      = icons_out,
  items      = items_out,
  recipes    = recipes_out,
})

-- ---------------------------------------------------------------------------
-- Write data.json
-- ---------------------------------------------------------------------------

run(("mkdir -p %q"):format(output_dir))

local json_str_out = json_encode(mod_data)
local f = assert(io.open(data_json, "w"))
f:write(json_str_out)
f:write("\n")
f:close()
io.stderr:write(("Wrote %s (%d items, %d recipes, %d icons)\n"):format(
  data_json, #items_out, #recipes_out, #icons_out))

-- ---------------------------------------------------------------------------
-- Write defaults.json
-- ---------------------------------------------------------------------------

local defaults = as_object({
  moduleRank    = {},
  minMachineRank = {},
  maxMachineRank = {},
  excludedRecipes = {},
})

local defaults_path = output_dir .. "/defaults.json"
local df = assert(io.open(defaults_path, "w"))
df:write(json_encode(defaults))
df:write("\n")
df:close()
io.stderr:write(("Wrote %s\n"):format(defaults_path))

-- ---------------------------------------------------------------------------
-- Write hash.json
-- ---------------------------------------------------------------------------

local hash = as_object({
  items        = {},
  beacons      = {},
  belts        = {},
  fuels        = {},
  wagons       = {},
  machines     = {},
  modules      = {},
  technologies = {},
  recipes      = {},
  locations    = {},
})

for _, item in ipairs(items_out) do
  hash.items[#hash.items+1] = item.id
  if item.machine then hash.machines[#hash.machines+1] = item.id end
  if item.module  then hash.modules[#hash.modules+1]  = item.id end
end

for _, recipe in ipairs(recipes_out) do
  hash.recipes[#hash.recipes+1] = recipe.id
end

local hash_path = output_dir .. "/hash.json"
local hf = assert(io.open(hash_path, "w"))
hf:write(json_encode(hash))
hf:write("\n")
hf:close()
io.stderr:write(("Wrote %s\n"):format(hash_path))

-- ---------------------------------------------------------------------------
-- Build icons.webp
-- ---------------------------------------------------------------------------

io.stderr:write(("Building sprite sheet from %d icons...\n"):format(#icon_path_list))

local img_tmp = mktemp()

-- Extract icon PNGs from zip
-- Build a list file for xargs
local list_file = img_tmp .. "/icon_list.txt"
local lf = assert(io.open(list_file, "w"))
for _, path in ipairs(icon_path_list) do lf:write(path .. "\n") end
lf:close()

run(("xargs -a %q unzip -o -q %q -d %q"):format(list_file, zip_path, img_tmp))

-- Resize each icon to 64x64 (Lanczos)
local resized_dir = img_tmp .. "/resized"
run(("mkdir -p %q"):format(resized_dir))

for _, path in ipairs(icon_path_list) do
  local src  = img_tmp .. "/" .. path
  -- Flatten path to a filename: replace / with __
  local name = path:gsub("/", "__") .. ".png"
  local dst  = resized_dir .. "/" .. name
  run(("magick %q -filter Lanczos -resize 64x64! %q"):format(src, dst))
end

-- Build ordered image list file for montage
local ordered_file = img_tmp .. "/ordered.txt"
local of = assert(io.open(ordered_file, "w"))
for _, path in ipairs(icon_path_list) do
  local name = path:gsub("/", "__") .. ".png"
  of:write(resized_dir .. "/" .. name .. "\n")
end
of:close()

-- magick montage: 20 per row, 64x64 + 1px padding each side = 66px stride
-- Use ImageMagick's @listfile syntax so paths are treated as inputs (not
-- appended after the output path as xargs would do).
local sheet_png = img_tmp .. "/sheet.png"
run(("magick montage @%q -tile 20x -geometry 64x64+1+1 "
     .. "-background none -gravity NorthWest %q"):format(ordered_file, sheet_png))

-- Convert to webp
run(("magick %q -quality 90 %q"):format(sheet_png, icons_webp))

run(("rm -rf %q"):format(img_tmp))

io.stderr:write(("Wrote %s\n"):format(icons_webp))

-- ---------------------------------------------------------------------------
-- Update app-level icons.webp with Desynced game icon
-- ---------------------------------------------------------------------------
-- Expects desynced-icon.ico in the current working directory (extracted from
-- Desynced.exe via icoextract or equivalent). The .ico contains a 64x64 frame
-- at index [2] which we use directly — no resize needed.
--
-- The existing app sprite sheet is 320x320 (5x5 grid of 64x64 cells, all
-- occupied). We extend it by one row to 320x384 and place the Desynced game
-- icon at position (0, 320) — first cell of the new bottom row.
-- CSS: .game-desynced::before { background-position: 0 -320px; }

local app_icons = repo_root .. "/src/assets/icons/icons.webp"
local ico_src   = "./desynced-icon.ico"

-- Check that the .ico exists
local test = io.open(ico_src, "r")
if not test then
  io.stderr:write("Warning: desynced-icon.ico not found in current directory — skipping app icon update.\n")
  io.stderr:write("Run: icoextract Desynced.exe desynced-icon.ico\n")
else
  test:close()
  local icon_tmp = mktemp()

  -- Extract the 64x64 frame from the .ico (frame index [2])
  local icon_64 = icon_tmp .. "/desynced-64.png"
  run(("magick %q[2] %q"):format(ico_src, icon_64))

  -- Extend the existing sprite sheet canvas by 64px downward (320x320 → 320x384)
  -- then composite the 64x64 icon at offset (0, 320)
  local expanded_webp = icon_tmp .. "/icons-expanded.webp"
  run(("magick %q -background none -gravity NorthWest "
       .. "-extent 320x384 "
       .. "%q -geometry +0+320 -composite "
       .. "-quality 90 %q"):format(app_icons, icon_64, expanded_webp))

  -- Replace the app sprite sheet
  run(("cp %q %q"):format(expanded_webp, app_icons))
  run(("rm -rf %q"):format(icon_tmp))

  io.stderr:write(("Updated %s with Desynced game icon at (0, 320).\n"):format(app_icons))
end

io.stderr:write("Done. Run 'npm run calculate-color dsy' to fill in icon colors.\n")
