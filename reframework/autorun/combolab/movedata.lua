-- ComboLab: reads a move's frame data straight from SF6's character data, so
-- windows can be predicted before any practice. Access paths follow
-- alphaZomega's MMDK (MIT): gBattle.Resource.Data[pl].FAB.StyleDict[s].ActionList
-- (actions by id, each with ActionFrame and per-type key lists),
-- gBattle.Player.mpLoadHitDataAddress[pl] (hit data by AttackDataListIndex),
-- and gBattle.Command trigger groups (which actions a cancel window allows).
-- Everything is read defensively: any failure just means "no prediction".
local MoveData = {}

MoveData.last_error = nil
local cache = {}        -- ["pl:fighter:id"] = facts | false
local group_cache = {}  -- ["pl:fighter:group"] = { [action_id] = true }
local trig_cache = {}   -- ["pl:fighter"] = { [trigger index] = action_id }

local function td(name) local ok, t = pcall(sdk.find_type_definition, name); return ok and t or nil end
local function static(type_name, field)
    local t = td(type_name)
    local f = t and t:get_field(field)
    if not f then return nil end
    local ok, v = pcall(f.get_data, f)
    return ok and v or nil
end

local function F(obj, name)
    if obj == nil then return nil end
    local ok, v = pcall(obj.get_field, obj, name)
    if ok then return v end
    return nil
end

local function C(obj, name, ...)
    if obj == nil then return nil end
    local ok, v = pcall(obj.call, obj, name, ...)
    if ok then return v end
    return nil
end

local function num(v)
    if v == nil then return nil end
    if type(v) == "number" then return v end
    local ok, s = pcall(function() return v:call("ToString()") end)
    return ok and tonumber(s) or tonumber(tostring(v))
end

-- managed list/array -> Lua list (1-based)
local function arr(list)
    if list == nil then return {} end
    local ok, el = pcall(function() return list:get_elements() end)
    if ok and type(el) == "table" then return el end
    local out = {}
    local items, size = F(list, "_items"), num(F(list, "_size"))
    if items ~= nil then
        local ok2, el2 = pcall(function() return items:get_elements() end)
        if ok2 and type(el2) == "table" then
            for i = 1, (size or #el2) do out[i] = el2[i] end
            return out
        end
    end
    local n = num(C(list, "get_Count")) or 0
    for i = 0, n - 1 do out[#out + 1] = C(list, "get_Item", i) end
    return out
end

-- dictionary lookup that doesn't throw on a missing key
local function dget(dict, key)
    if dict == nil then return nil end
    if C(dict, "ContainsKey", key) ~= true then return nil end
    return C(dict, "get_Item", key)
end

local function type_name(obj)
    local ok, n = pcall(function() return obj:get_type_definition():get_name() end)
    return ok and n or nil
end

-- ------------------------------------------------------------------ lookups
local function find_action(pl, id)
    local res = static("gBattle", "Resource")
    local data = res and F(res, "Data")
    if not data then return nil end
    local persons = arr(data)
    local function in_person(person)
        local fab = F(person, "FAB")
        local styles = fab and F(fab, "StyleDict")
        if not styles then return nil end
        local n = num(C(styles, "get_Count")) or 1
        for s = 0, math.max(0, n - 1) do
            local style = dget(styles, s)
            local list = style and F(style, "ActionList")
            local a = list and dget(list, id)
            if a then return a end
        end
    end
    return in_person(persons[pl + 1]) or in_person(persons[7])   -- [6] holds the shared moves
end

local function hit_table(pl)
    local p = static("gBattle", "Player")
    local all = p and F(p, "mpLoadHitDataAddress")
    if not all then return nil end
    return arr(all)[pl + 1]
end

-- one situation from a HIT_DT_TBL: param[0..19]
-- 0 stand, 1 crouch, 2 air, 8 counter hit, 12 punish counter, 16 block
local function hit_entry(tbl, i)
    local params = tbl and arr(F(tbl, "param"))
    local e = params and params[i + 1]
    if not e then return nil end
    return { stun = num(F(e, "HitStun")), stop_o = num(F(e, "HitStopOwner")), stop_t = num(F(e, "HitStopTarget")),
             dmg_type = num(F(e, "DmgType")) }
end

-- Frame facts for one action. Cached; returns nil when unreadable.
function MoveData.facts(pl, fighter, id)
    if id == nil then return nil end
    local key = pl .. ":" .. tostring(fighter) .. ":" .. tostring(id)
    if cache[key] ~= nil then return cache[key] or nil end
    local ok, f = pcall(function()
        local a = find_action(pl, id)
        if not a then return nil end
        local af = F(a, "ActionFrame")
        local facts = {
            id = id, main = num(F(af, "MainFrame")), follow = num(F(af, "FollowFrame")),
            margin = num(F(af, "MarginFrame")), frame = num(F(a, "Frame")),
            trig = {}, atk = {},
        }
        for _, list in ipairs(arr(F(a, "Keys"))) do
            local items = arr(list)
            local tn = items[1] and type_name(items[1])
            if tn == "TriggerKey" then
                for _, k in ipairs(items) do
                    local s = num(F(k, "_StartFrame")) or num(C(k, "get_StartFrame"))
                    local e = num(F(k, "_EndFrame")) or num(C(k, "get_EndFrame"))
                    local g = num(F(k, "TriggerGroup"))
                    if s and e and g then facts.trig[#facts.trig + 1] = { s = s, e = e, g = g, c = num(F(k, "ConditionFlag")) } end
                end
            elseif tn == "AttackCollisionKey" then
                for _, k in ipairs(items) do
                    local idx = num(F(k, "AttackDataListIndex"))
                    if idx and idx >= 0 then
                        facts.atk[#facts.atk + 1] = { s = num(F(k, "_StartFrame")), e = num(F(k, "_EndFrame")), idx = idx }
                    end
                end
            end
        end
        table.sort(facts.atk, function(x, y) return (x.s or 0) < (y.s or 0) end)
        if #facts.atk > 0 then MoveData.seen_atk = true end
        -- hit data of the first strike
        local first = facts.atk[1]
        if first then
            local tbl = dget(hit_table(pl), first.idx)
            if tbl then
                local st, cr, ch, pc, bl = hit_entry(tbl, 0), hit_entry(tbl, 1), hit_entry(tbl, 8), hit_entry(tbl, 12), hit_entry(tbl, 16)
                if st then
                    facts.hit = {
                        stun = { st = st.stun, cr = cr and cr.stun, ch = ch and ch.stun, pc = pc and pc.stun, bl = bl and bl.stun },
                        stop_o = st.stop_o, stop_t = st.stop_t, dmg_type = st.dmg_type,
                    }
                end
            end
        end
        return facts
    end)
    if not ok then MoveData.last_error = tostring(f); f = nil end
    cache[key] = f or false
    return f
end

-- trigger index -> action id for this player's command engine
local function triggers(pl, fighter)
    local key = pl .. ":" .. tostring(fighter)
    if trig_cache[key] then return trig_cache[key] end
    local cmd = static("gBattle", "Command")
    local engines = cmd and C(cmd, "get_mUserEngine")
    local eng = engines and arr(engines)[pl + 1]
    local list = eng and C(eng, "GetTrigger()")
    if not list then return nil end
    local out = {}
    for i, t in ipairs(arr(list)) do
        local aid = num(F(t, "action_id"))
        if aid then out[i - 1] = aid end
    end
    trig_cache[key] = out
    return out
end

-- set of action ids a trigger group allows
function MoveData.group(pl, fighter, g)
    local key = pl .. ":" .. tostring(fighter) .. ":" .. tostring(g)
    if group_cache[key] then return group_cache[key] end
    local ok, set = pcall(function()
        local cmd = static("gBattle", "Command")
        local tg = C(cmd, "GetTriggerGroup", pl, g)
        local flag = tg and F(tg, "Flag")
        local bits
        for _ = 1, 5 do                       -- BitArray() sometimes comes back incomplete; MMDK retries
            bits = flag and C(flag, "BitArray")
            if bits and pcall(function() return bits:get_elements() end) then break end
        end
        if not bits then return nil end
        pcall(function() bits:add_ref() end)
        local trig = triggers(pl, fighter) or {}
        local s = {}
        for _, t in ipairs(bits:get_elements()) do
            local idx = num(F(t, "mValue")) or num(t)
            local aid = idx and trig[idx]
            if aid then s[aid] = true end
        end
        return s
    end)
    if not ok then MoveData.last_error = tostring(set) end
    if ok and set then group_cache[key] = set end
    return ok and set or nil
end

-- frame ranges [s, e) of action A in which action B can be cancelled into
function MoveData.cancel_ranges(pl, fighter, A, b_id)
    if not A or not A.trig or b_id == nil then return nil end
    local out = {}
    for _, t in ipairs(A.trig) do
        local set = MoveData.group(pl, fighter, t.g)
        if set and set[b_id] then out[#out + 1] = { s = t.s, e = t.e } end
    end
    return out
end

function MoveData.clear()
    MoveData.seen_atk = nil
    cache, group_cache, trig_cache = {}, {}, {}
end

return MoveData
