-- ComboLab: research speed (run the battle faster than real time while the
-- research bot works). Everything ComboLab measures is counted in battle
-- frames, so a faster battle gives the same windows sooner, as long as the
-- game really runs more frames (not the same frames with faster animation).
--
-- We don't know for sure which knob SF6 uses, so this module finds candidates
-- at runtime and measures each one:
--   * "global":  via.Application GlobalSpeed (RE Engine's game-wide speed)
--   * "training:<path>": any number field with "speed" in its name under the
--     training manager (Training mode's own 100% / 50% game speed setting)
-- A test applies each candidate at 2x for ~2 seconds and counts battle frames
-- (from the input hook) against the clock. Only a candidate that really gives
-- more frames per second is used. Every change is undone on restore().
local Speed = {}

Speed.candidates = nil     -- { {key, label, get(), set(v), base, kind} }
Speed.results = {}         -- key -> { fps = n, ratio = r, ok = bool, note = str }
Speed.active = nil         -- { key, mult, orig }
Speed.test = nil           -- running test state
Speed.base_fps = nil
Speed.error = nil

local MAX_DEPTH, MAX_FIELDS = 4, 4000
Speed.log = function(_) end      -- set by ComboLab.lua (REFramework log)

local function safe(f, ...)
    local ok, a = pcall(f, ...)
    if ok then return a end
    return nil
end

-- ---------------------------------------------------------------- discovery
local function global_candidate()
    local app = safe(sdk.get_native_singleton, "via.Application")
    local td = safe(sdk.find_type_definition, "via.Application")
    if not app or not td then return nil end
    local get = function() return safe(sdk.call_native_func, app, td, "get_GlobalSpeed") end
    local v = get()
    if type(v) ~= "number" then return nil end
    return {
        key = "global", label = "via.Application.GlobalSpeed", kind = "mult", base = v,
        get = get,
        set = function(x) return pcall(sdk.call_native_func, app, td, "set_GlobalSpeed(System.Single)", x) end,
    }
end

local NUMERIC = {
    ["System.Single"] = true, ["System.Double"] = true, ["System.Int32"] = true, ["System.UInt32"] = true,
    ["System.Int16"] = true, ["System.UInt16"] = true, ["System.Byte"] = true, ["System.SByte"] = true,
}

local function walk(obj, path, depth, out, seen, budget)
    if not obj or depth > MAX_DEPTH or budget.n <= 0 then return end
    local addr = safe(obj.get_address, obj)
    if addr then
        if seen[addr] then return end
        seen[addr] = true
    end
    local td = safe(obj.get_type_definition, obj)
    if not td then return end
    -- fields of this type and its parents
    local t = td
    while t and budget.n > 0 do
        for _, f in ipairs(safe(t.get_fields, t) or {}) do
            budget.n = budget.n - 1
            if budget.n <= 0 then break end
            local ok_static, is_static = pcall(f.is_static, f)
            if not (ok_static and is_static) then
                local name = safe(f.get_name, f) or "?"
                local ft = safe(f.get_type, f)
                local tname = ft and safe(ft.get_full_name, ft) or ""
                local p = path .. "." .. name
                local is_enum = ft and safe(ft.is_a, ft, "System.Enum")
                if name:lower():find("speed") or name:lower():find("slow") then
                    if NUMERIC[tname] or is_enum then
                        local v = safe(obj.get_field, obj, name)
                        if type(v) == "number" then
                            out[#out + 1] = { obj = obj, field = name, path = p, type = tname, enum = is_enum and true or false, value = v }
                        end
                    end
                end
                if ft and not NUMERIC[tname] and not is_enum and not safe(ft.is_value_type, ft)
                    and tname ~= "System.String" and not tname:find("%[%]") then
                    local child = safe(obj.get_field, obj, name)
                    if type(child) == "userdata" or type(child) == "table" then walk(child, p, depth + 1, out, seen, budget) end
                end
            end
        end
        t = safe(t.get_parent_type, t)
        if t and (safe(t.get_full_name, t) or ""):find("^System%.") then break end
    end
end

function Speed.discover()
    local list = {}
    local g = global_candidate()
    if g then list[#list + 1] = g end
    local tm = safe(sdk.get_managed_singleton, "app.training.TrainingManager")
    if tm then
        local found = {}
        walk(tm, "TrainingManager", 0, found, {}, { n = MAX_FIELDS })
        for _, c in ipairs(found) do
            local obj, field = c.obj, c.field
            local cand = {
                key = "training:" .. c.path, label = c.path .. " (" .. c.type .. (c.enum and ", enum" or "") .. ")",
                base = c.value, enum = c.enum,
                get = function() return safe(obj.get_field, obj, field) end,
                set = function(x) return pcall(obj.set_field, obj, field, x) end,
            }
            -- a float near 1 is a multiplier, near 100 a percentage; an enum
            -- or small int is an index into the menu's choices (can't go past it)
            if c.type == "System.Single" or c.type == "System.Double" then
                cand.kind = (c.value > 10) and "percent" or "mult"
            elseif not c.enum and c.value >= 50 and c.value <= 200 then
                cand.kind = "percent"
            else
                cand.kind = "index"
            end
            list[#list + 1] = cand
        end
    end
    Speed.candidates = list
    Speed.log(string.format("found %d speed setting(s)", #list))
    for _, c in ipairs(list) do Speed.log(string.format("  %s = %s (%s)", c.label, tostring(c.base), c.kind)) end
    return list
end

local function value_for(c, mult)
    if c.kind == "percent" then return math.floor(100 * mult + 0.5) end
    if c.kind == "mult" then return (c.base ~= 0 and c.base or 1.0) * mult end
    return nil
end

-- ---------------------------------------------------------------- apply / restore
function Speed.apply(key, mult)
    Speed.restore()
    if not mult or mult <= 1.001 then return true end
    for _, c in ipairs(Speed.candidates or Speed.discover()) do
        if c.key == key then
            local v = value_for(c, mult)
            if v == nil then return false, "that setting can't go past the menu's choices" end
            local orig = c.get()
            local ok = c.set(v)
            if not ok then return false, "couldn't set " .. c.label end
            Speed.log(string.format("set %s to %s (reads back %s)", c.key, tostring(v), tostring(c.get())))
            Speed.active = { key = key, mult = mult, orig = orig, c = c }
            return true
        end
    end
    return false, "no such speed setting: " .. tostring(key)
end

function Speed.restore()
    local a = Speed.active
    if not a then return end
    Speed.active = nil
    if a.orig ~= nil then pcall(a.c.set, a.orig) end
end

-- the candidate the last test found to work (biggest real speed-up)
function Speed.best()
    local best, br = nil, 1.15
    for key, r in pairs(Speed.results or {}) do
        if type(r) == "table" and r.ok and (r.ratio or 0) > br then best, br = key, r.ratio end
    end
    return best
end

-- ---------------------------------------------------------------- test
-- Speed.start_test(get_tick, mult): each candidate in turn: settle 0.5 s,
-- measure 2 s, restore, settle. Call Speed.update() every rendered frame.
function Speed.start_test(get_tick, mult)
    Speed.restore()
    Speed.discover()
    Speed.results = {}
    Speed.error = nil
    local queue = { { key = nil } }            -- baseline first
    for _, c in ipairs(Speed.candidates) do
        if c.kind ~= "index" then queue[#queue + 1] = { key = c.key } end
    end
    Speed.test = { q = queue, i = 0, mult = mult or 2, get_tick = get_tick, phase = "next" }
end

local SETTLE, MEASURE = 0.5, 2.0

function Speed.update()
    local T = Speed.test
    if not T then return end
    local now = os.clock()
    if T.phase == "next" then
        Speed.restore()
        T.i = T.i + 1
        local item = T.q[T.i]
        if not item then Speed.test = nil; return end
        T.item = item
        if item.key then
            local ok, why = Speed.apply(item.key, T.mult)
            if not ok then
                Speed.results[item.key] = { ok = false, note = why }
                return
            end
        end
        T.phase, T.t0 = "settle", now
    elseif T.phase == "settle" and now - T.t0 >= SETTLE then
        T.phase, T.t0, T.k0 = "measure", now, T.get_tick()
    elseif T.phase == "measure" and now - T.t0 >= MEASURE then
        local fps = (T.get_tick() - T.k0) / (now - T.t0)
        local item = T.item
        Speed.restore()
        Speed.log(string.format("%s: %.1f frames/s", item.key or "normal speed", fps))
        if not item.key then
            Speed.base_fps = fps
            if fps < 20 then
                Speed.error = string.format("the battle isn't running (%.0f frames/s): unpause, stay in Training and run the test again", fps)
                Speed.test = nil
                return
            end
        else
            local ratio = fps / math.max(1, Speed.base_fps or 60)
            Speed.results[item.key] = {
                fps = fps, ratio = ratio, ok = ratio > 1.15,
                note = ratio > 1.15 and string.format("%.2fx real frames", ratio)
                    or "no extra frames (the game may only speed up animations here)",
            }
        end
        T.phase, T.t0 = "gap", now
    elseif T.phase == "gap" and now - T.t0 >= 0.3 then
        T.phase = "next"
    end
end

-- ---------------------------------------------------------------- scan
-- REFramework can't list every type, so this looks where SF6 must keep it:
--  * the speed enums found in the Training settings: their named values
--  * every type we can reach from the training manager and from gBattle's
--    static objects (the battle itself): all their number fields whose name
--    hints at speed / slow-down / frame skipping, with current values, and
--    the methods on those types with such names
-- Written to ComboLab/speed_scan.json. Best run once at 100% and once at 50%
-- game speed (Training menu): the field that changes is the one.
local HINT = { "speed", "slow", "skip", "rate", "scale", "step", "tick", "wait", "delay", "interval", "count" }

local function hinted(n)
    n = n:lower()
    for _, h in ipairs(HINT) do if n:find(h, 1, true) then return true end end
    return false
end

local function enum_values(tname)
    local td = safe(sdk.find_type_definition, tname)
    if not td then return nil end
    local vals = {}
    for _, f in ipairs(safe(td.get_fields, td) or {}) do
        if safe(f.is_static, f) then
            local v = safe(f.get_data, f, nil)
            vals[#vals + 1] = (safe(f.get_name, f) or "?") .. " = " .. tostring(v)
        end
    end
    return vals
end

local function dump_object(obj, path, depth, out, seen, budget, types)
    if not obj or depth > 3 or budget.n <= 0 then return end
    local addr = safe(obj.get_address, obj)
    if addr then
        if seen[addr] then return end
        seen[addr] = true
    end
    local td = safe(obj.get_type_definition, obj)
    if not td then return end
    local tn = safe(td.get_full_name, td) or "?"
    if not types[tn] then
        local ms = {}
        for _, m in ipairs(safe(td.get_methods, td) or {}) do
            local mn = safe(m.get_name, m) or ""
            if hinted(mn) then ms[#ms + 1] = mn end
        end
        types[tn] = ms
    end
    for _, f in ipairs(safe(td.get_fields, td) or {}) do
        budget.n = budget.n - 1
        if budget.n <= 0 then return end
        if not safe(f.is_static, f) then
            local name = safe(f.get_name, f) or "?"
            local ft = safe(f.get_type, f)
            local ftn = ft and safe(ft.get_full_name, ft) or ""
            local v = safe(obj.get_field, obj, name)
            if type(v) == "number" or type(v) == "boolean" then
                if hinted(name) then out[#out + 1] = string.format("%s.%s = %s (%s)", path, name, tostring(v), ftn) end
            elseif (type(v) == "userdata" or type(v) == "table") and not safe(ft.is_value_type, ft) and ftn ~= "System.String" then
                dump_object(v, path .. "." .. name, depth + 1, out, seen, budget, types)
            end
        end
    end
end

-- app.battle.uBattleCore runs the battle each frame (update / lateUpdate);
-- remember the instance so the scan can look inside it. Hooked lazily, the
-- first time a scan is asked for.
Speed.core = nil
local core_hooked = false
function Speed.watch_core()
    if core_hooked then return true end
    core_hooked = true
    local td = safe(sdk.find_type_definition, "app.battle.uBattleCore")
    local m = td and safe(td.get_method, td, "update")
    if not m then return false end
    pcall(sdk.hook, m, function(args)
        if not Speed.core then
            local ok, o = pcall(sdk.to_managed_object, args[2])
            if ok and o then Speed.core = o end
        end
    end, nil)
    return false
end

function Speed.scan(path)
    local res = { enums = {}, values = {}, methods = {}, roots = {} }
    -- named values of the speed enums we know about
    for _, en in ipairs({ "app.training.GameSpeed", "app.training.ComboTrialManager.ETrialGameSpeed" }) do
        res.enums[en] = enum_values(en)
    end
    local seen, budget, types = {}, { n = 20000 }, {}
    local tm = safe(sdk.get_managed_singleton, "app.training.TrainingManager")
    if tm then res.roots[#res.roots + 1] = "TrainingManager"; dump_object(tm, "TrainingManager", 0, res.values, seen, budget, types) end
    -- gBattle: the battle's static objects (Player, Team, Command, Resource, Game, ...)
    local gb = safe(sdk.find_type_definition, "gBattle")
    if gb then
        for _, f in ipairs(safe(gb.get_fields, gb) or {}) do
            if safe(f.is_static, f) then
                local name = safe(f.get_name, f) or "?"
                local holder = safe(f.get_data, f, nil)
                local obj = holder and (safe(holder.get_data, holder) or holder)
                if type(obj) == "userdata" or type(obj) == "table" then
                    res.roots[#res.roots + 1] = "gBattle." .. name
                    dump_object(obj, "gBattle." .. name, 0, res.values, seen, budget, types)
                end
            end
        end
    end
    -- the battle core itself (app.battle.uBattleCore, caught by Speed.watch_core)
    if Speed.core then
        res.roots[#res.roots + 1] = "uBattleCore"
        dump_object(Speed.core, "uBattleCore", 0, res.values, seen, budget, types)
    end
    for tn, ms in pairs(types) do if #ms > 0 then res.methods[tn] = ms end end
    local app = global_candidate()
    if app then res.values[#res.values + 1] = "via.Application.GlobalSpeed = " .. tostring(app.base) end
    json.dump_file(path, res)
    local nm = 0
    for _ in pairs(res.methods) do nm = nm + 1 end
    Speed.last_scan = { time = os.time(), types = nm, scanned = #res.roots, live = #res.values }
    Speed.log(string.format("scan: %d values, %d types with speed-ish methods, from %s; written to %s",
        #res.values, nm, table.concat(res.roots, ", "), path))
    return true, #res.values
end

-- ---------------------------------------------------------------- live rate
-- Battle frames per second over the last ~second (for the status / bot).
local rate = { t = nil, k = nil, fps = nil }
function Speed.sample(tick)
    local now = os.clock()
    if not rate.t then rate.t, rate.k = now, tick return end
    if now - rate.t >= 1.0 then
        rate.fps = (tick - rate.k) / (now - rate.t)
        rate.t, rate.k = now, tick
    end
end
function Speed.fps() return rate.fps end

function Speed.status()
    local cands = {}
    for _, c in ipairs(Speed.candidates or {}) do
        cands[#cands + 1] = { key = c.key, label = c.label, kind = c.kind, base = c.base, result = Speed.results[c.key] }
    end
    return {
        candidates = cands, base_fps = Speed.base_fps, testing = Speed.test ~= nil, error = Speed.error,
        active = Speed.active and { key = Speed.active.key, mult = Speed.active.mult } or nil,
        best = Speed.best(), fps = rate.fps, results = Speed.results, scan = Speed.last_scan,
    }
end

return Speed
