-- ComboLab: the training dummy's settings (counter hit, stance, guard),
-- set from code the way the Training menu sets them: write the setting into
-- TrainingManager._tData, then have that setting's training function apply it.
-- Field names and values from Wael3rd's SF6_Tools (MIT):
--   CounterSetting.DummyData.NC_TYPE / PC_TYPE   (Counter: NC=1, Punish Counter: PC=1)
--   GuardSetting.DummyData.GuardType             (0 = no guard)
--   DummyStatus.DummyData.DummyActionType        (0 = stand, 1 = crouch)
-- and tf_CounterSetting / tf_GuardSetting:bApply() to apply without a reset.
local Dummy = {}

Dummy.COUNTER = { normal = 0, ch = 1, pc = 2 }
local tf_cache = {}

local function tdata()
    local tm = sdk.get_managed_singleton("app.training.TrainingManager")
    return tm and tm:get_field("_tData"), tm
end

-- the training function object (tf_CounterSetting, tf_GuardSetting, ...) that applies a setting
local function tf(name)
    if tf_cache[name] then return tf_cache[name] end
    pcall(function()
        local _, tm = tdata()
        local entries = tm and tm:get_field("_tfFuncs"):get_field("_entries")
        if not entries then return end
        for i = 0, entries:call("get_Count") - 1 do
            local e = entries:call("get_Item", i)
            local v = e and e:get_field("value")
            if v and v:get_type_definition():get_full_name():find(name, 1, true) then
                tf_cache[name] = v
                return
            end
        end
    end)
    return tf_cache[name]
end

local function apply(name)
    local f = tf(name)
    if f then return pcall(f.call, f, "bApply") end
    return false
end

-- ---------------------------------------------------------------- counter
function Dummy.get_counter()
    local v
    pcall(function()
        local dd = tdata():get_field("CounterSetting"):get_field("DummyData")
        if (dd.PC_TYPE or 0) ~= 0 then v = 2 elseif (dd.NC_TYPE or 0) ~= 0 then v = 1 else v = 0 end
    end)
    return v
end

function Dummy.set_counter(v)
    local ok = pcall(function()
        local dd = tdata():get_field("CounterSetting"):get_field("DummyData")
        dd.NC_TYPE = (v == 1) and 1 or 0
        dd.PC_TYPE = (v == 2) and 1 or 0
    end)
    return ok and apply("tf_CounterSetting")
end

-- ---------------------------------------------------------------- guard
function Dummy.get_guard()
    local v
    pcall(function() v = tdata():get_field("GuardSetting"):get_field("DummyData").GuardType end)
    return v
end

function Dummy.set_guard(v)
    local ok = pcall(function() tdata():get_field("GuardSetting"):get_field("DummyData").GuardType = v end)
    return ok and apply("tf_GuardSetting")
end

-- ---------------------------------------------------------------- stance
function Dummy.get_stance()
    local v
    pcall(function() v = tdata():get_field("DummyStatus"):get_field("DummyData").DummyActionType end)
    return v
end

function Dummy.set_stance(v)
    local ok = pcall(function() tdata():get_field("DummyStatus"):get_field("DummyData").DummyActionType = v end)
    if ok then apply("tf_DummyStatus") end
    return ok
end

-- ---------------------------------------------------------------- per combo
-- What a combo needs from the dummy. combo.dummy = { counter = "auto"|"normal"|"ch"|"pc",
-- stance = "auto"|"stand"|"crouch" } overrides; "auto" reads the name and steps:
--   * a combo that starts with Drive Impact needs Punish Counter (a DI only
--     crumples on a punish counter; the Training setting makes every hit one)
--   * "PC" / "punish" in the name: Punish Counter; "CH" / "counter": Counter
--   * "crouch" in the name: crouching dummy
function Dummy.wants(combo)
    local d = type(combo and combo.dummy) == "table" and combo.dummy or {}
    local name = " " .. tostring(combo and combo.name or ""):lower():gsub("[%(%)%[%]:,/]", " ") .. " "
    local counter = d.counter
    if counter == nil or counter == "auto" then
        local s1 = combo and combo.steps and combo.steps[1]
        if s1 and tostring(s1.label):upper() == "DI" then counter = "pc"
        elseif name:find("%spc%s") or name:find("punish counter") or name:find("punish%-counter") then counter = "pc"
        elseif name:find("%sch%s") or name:find("counter hit") or name:find("%scounter%s") then counter = "ch"
        else counter = "normal" end
    end
    local stance = d.stance
    if stance == nil or stance == "auto" then
        stance = (name:find("crouch") or name:find("%svs cr") or name:find("crouching")) and "crouch" or "stand"
    end
    return { counter = Dummy.COUNTER[counter] or 0, crouch = stance == "crouch", counter_name = counter, stance = stance }
end

-- Sets the dummy up for `combo`; remembers what the player had (once) so
-- restore() can put it back. Returns a short description.
local saved = nil
function Dummy.setup(combo, opts)
    opts = opts or {}
    local w = Dummy.wants(combo)
    if not saved then
        saved = { counter = Dummy.get_counter(), stance = Dummy.get_stance(), guard = Dummy.get_guard() }
    end
    if Dummy.get_counter() ~= w.counter then Dummy.set_counter(w.counter) end
    local st = w.crouch and 1 or 0
    if Dummy.get_stance() ~= st then Dummy.set_stance(st) end
    if opts.no_guard and Dummy.get_guard() ~= 0 then Dummy.set_guard(0) end
    return string.format("dummy: %s, %s%s", ({ [0] = "normal hit", "counter hit", "punish counter" })[w.counter], w.crouch and "crouching" or "standing", opts.no_guard and ", no guard" or "")
end

-- the bot turns guard off; put just that back when it stops
function Dummy.restore_guard()
    if saved and saved.guard and Dummy.get_guard() ~= saved.guard then Dummy.set_guard(saved.guard) end
end

function Dummy.restore()
    if not saved then return end
    local s = saved
    saved = nil
    if s.counter and Dummy.get_counter() ~= s.counter then Dummy.set_counter(s.counter) end
    if s.stance and Dummy.get_stance() ~= s.stance then Dummy.set_stance(s.stance) end
    if s.guard and Dummy.get_guard() ~= s.guard then Dummy.set_guard(s.guard) end
end

function Dummy.status()
    return { counter = Dummy.get_counter(), stance = Dummy.get_stance(), guard = Dummy.get_guard(), changed = saved ~= nil }
end

return Dummy
