-- ComboLab: Training settings by path, for settings ComboLab doesn't know by
-- name (character-specific ones like Juri's unlimited Feng Shui Engine).
--
--   snapshot()            every number / bool under TrainingManager._tData, by path
--   diff(a, b)            what changed between two snapshots
--   set(path, v)          write one (paths like "CharacterSetting.List[0].Flag")
--   apply_combo(list)     set a combo's saved settings; restore() puts back the
--                         player's own values
--
-- After writing, the training function for that settings group applies it
-- (tf_<Group>:bApply(), as the menu does), falling back to a training refresh.
local TS = {}

local function safe(f, ...)
    local ok, a = pcall(f, ...)
    if ok then return a end
    return nil
end

local function tdata()
    local tm = safe(sdk.get_managed_singleton, "app.training.TrainingManager")
    return tm and safe(tm.get_field, tm, "_tData"), tm
end

-- ---------------------------------------------------------------- walking
local function count_of(obj)
    local n = safe(obj.call, obj, "get_Count")
    if type(n) == "number" then return n, "list" end
    n = safe(obj.get_size, obj)
    if type(n) == "number" then return n, "array" end
    return nil
end

local function item_of(obj, kind, i)
    if kind == "list" then return safe(obj.call, obj, "get_Item", i) end
    return safe(obj.get_element, obj, i)
end

local function walk(obj, path, depth, out, seen, budget)
    if obj == nil or depth > 6 or budget.n <= 0 then return end
    local addr = safe(obj.get_address, obj)
    if addr then
        if seen[addr] then return end
        seen[addr] = true
    end
    local td = safe(obj.get_type_definition, obj)
    if not td then return end
    local tn = safe(td.get_full_name, td) or ""
    -- lists and arrays: their items
    if tn:find("%[%]$") or tn:find("^System%.Collections%.Generic%.List") then
        local n, kind = count_of(obj)
        for i = 0, math.min((n or 0) - 1, 63) do
            local it = item_of(obj, kind, i)
            local ti = type(it)
            if ti == "number" or ti == "boolean" then out[path .. "[" .. i .. "]"] = it
            elseif ti == "userdata" or ti == "table" then walk(it, path .. "[" .. i .. "]", depth + 1, out, seen, budget) end
        end
        return
    end
    for _, f in ipairs(safe(td.get_fields, td) or {}) do
        budget.n = budget.n - 1
        if budget.n <= 0 then return end
        if not safe(f.is_static, f) then
            local name = safe(f.get_name, f) or "?"
            local v = safe(obj.get_field, obj, name)
            local t = type(v)
            local p = (path == "" and name) or (path .. "." .. name)
            if t == "number" or t == "boolean" then out[p] = v
            elseif t == "userdata" or t == "table" then
                local ft = safe(f.get_type, f)
                if (ft and safe(ft.get_full_name, ft) or "") ~= "System.String" then walk(v, p, depth + 1, out, seen, budget) end
            end
        end
    end
end

function TS.snapshot()
    local td = tdata()
    local out = {}
    if td then walk(td, "", 0, out, {}, { n = 30000 }) end
    return out
end

function TS.diff(a, b)
    local ch = {}
    for p, v in pairs(b or {}) do
        local o = a and a[p]
        if o ~= nil and o ~= v then ch[#ch + 1] = { path = p, from = o, to = v } end
    end
    table.sort(ch, function(x, y) return x.path < y.path end)
    return ch
end

-- ---------------------------------------------------------------- read / write by path
local function segments(path)
    local segs = {}
    for part in path:gmatch("[^%.]+") do
        local name, rest = part:match("^([^%[]*)(.*)$")
        if name ~= "" then segs[#segs + 1] = { field = name } end
        for idx in rest:gmatch("%[(%d+)%]") do segs[#segs + 1] = { index = tonumber(idx) } end
    end
    return segs
end

local function step(obj, seg)
    if seg.field then return safe(obj.get_field, obj, seg.field) end
    local _, kind = count_of(obj)
    return item_of(obj, kind or "list", seg.index)
end

function TS.get(path)
    local obj = tdata()
    for _, seg in ipairs(segments(path)) do
        if obj == nil then return nil end
        obj = step(obj, seg)
    end
    return obj
end

local tf_cache = {}
local function tf_for(group)
    if tf_cache[group] ~= nil then return tf_cache[group] or nil end
    local found = false
    pcall(function()
        local _, tm = tdata()
        local entries = tm:get_field("_tfFuncs"):get_field("_entries")
        for i = 0, entries:call("get_Count") - 1 do
            local e = entries:call("get_Item", i)
            local v = e and e:get_field("value")
            if v and v:get_type_definition():get_full_name():find("tf_" .. group, 1, true) then found = v return end
        end
    end)
    tf_cache[group] = found
    return found or nil
end

function TS.set(path, value)
    local segs = segments(path)
    if #segs == 0 then return false end
    local obj = tdata()
    for i = 1, #segs - 1 do
        if obj == nil then return false end
        obj = step(obj, segs[i])
    end
    local last = segs[#segs]
    if obj == nil or not last.field then return false end
    local ok = pcall(obj.set_field, obj, last.field, value)
    return ok
end

-- apply what was written: the group's training function, else a refresh
local function apply_groups(groups)
    local _, tm = tdata()
    local refresh = false
    for g in pairs(groups) do
        local f = tf_for(g)
        if f then pcall(f.call, f, "bApply") else refresh = true end
    end
    if refresh and tm then pcall(tm.call, tm, "set_IsReqRefresh", true) end
end

-- ---------------------------------------------------------------- per combo
local saved = {}      -- path -> the player's own value, while a combo's settings are on

function TS.apply_combo(list)
    TS.restore()
    if type(list) ~= "table" then return 0 end
    local groups, n = {}, 0
    for _, s in ipairs(list) do
        if type(s) == "table" and type(s.path) == "string" and s.value ~= nil then
            local cur = TS.get(s.path)
            if cur ~= nil and cur ~= s.value then
                saved[s.path] = cur
                if TS.set(s.path, s.value) then
                    n = n + 1
                    groups[s.path:match("^([^%.%[]+)")] = true
                end
            end
        end
    end
    if n > 0 then apply_groups(groups) end
    return n
end

function TS.restore()
    local groups, any = {}, false
    for p, v in pairs(saved) do
        if TS.set(p, v) then groups[p:match("^([^%.%[]+)")] = true; any = true end
    end
    saved = {}
    if any then apply_groups(groups) end
end

function TS.active()
    return next(saved) ~= nil
end

return TS
