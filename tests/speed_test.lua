-- Speed module: finds speed settings, measures them, picks the one that
-- really runs more battle frames, and restores everything.   lua tests/speed_test.lua
package.path = "reframework/autorun/?.lua;" .. package.path
local CLK = 0
os.clock = function() return CLK end

-- fake game: GlobalSpeed really speeds the battle up; the training float only
-- speeds animations (no extra frames); an enum index can't go past the menu
local global_speed = 1.0
local function mkfield(name, tname, static) return {
    get_name = function() return name end, is_static = function() return static or false end,
    get_type = function() return { get_full_name = function() return tname end,
        is_a = function(_, x) return x == "System.Enum" and (tname == "app.SpeedType" or tname == "app.training.GameSpeed") end,
        is_value_type = function() return tname ~= "app.TrainingData" end } end } end
local tdata = { GameSpeed = 1.0, SpeedIndex = 0, OS_Game_Speed = 5, Is_Speed_Setting = false }
local applied_speed = 5        -- what the battle runs at after ForceGameSpeedSettingApply
local tdata_obj = {
    get_address = function() return 2 end,
    get_field = function(_, n) return tdata[n] end, set_field = function(_, n, v) tdata[n] = v end,
    get_type_definition = function() return { get_fields = function() return { mkfield("GameSpeed", "System.Single"), mkfield("SpeedIndex", "app.SpeedType"), mkfield("Other", "System.Int32"), mkfield("OS_Game_Speed", "app.training.GameSpeed") } end,
        get_parent_type = function() return nil end } end,
}
tdata.Other = 5
local tm = {
    get_address = function() return 1 end,
    call = function(_, m) if m == "ForceGameSpeedSettingApply" then applied_speed = tdata.OS_Game_Speed end end,
    get_field = function(_, n) if n == "_tData" then return tdata_obj end end,
    get_type_definition = function() return { get_fields = function() return { mkfield("_tData", "app.TrainingData") } end,
        get_parent_type = function() return nil end } end,
}
sdk = {
    get_native_singleton = function(n) return n == "via.Application" and {} or nil end,
    find_type_definition = function(n) return {} end,
    call_native_func = function(_, _, m, v)
        if m == "get_GlobalSpeed" then return global_speed end
        if m:find("^set_GlobalSpeed") then global_speed = v end
    end,
    get_managed_singleton = function(n) return n == "app.training.TrainingManager" and tm or nil end,
}
local Speed = require("combolab.speed")
local fail = 0
local function check(c, m) if not c then fail = fail + 1; print("FAIL: " .. m) end end

local c = Speed.discover()
local keys = {}
for _, x in ipairs(c) do keys[x.key] = x end
check(keys["global"] and keys["global"].kind == "mult", "global speed found")
check(keys["training:TrainingManager._tData.GameSpeed"] and keys["training:TrainingManager._tData.GameSpeed"].kind == "mult", "training float found")
check(keys["training:TrainingManager._tData.SpeedIndex"] and keys["training:TrainingManager._tData.SpeedIndex"].kind == "index", "enum seen as an index")
check(not keys["training:TrainingManager._tData.Other"], "unrelated field ignored")

-- run the test: 60 battle frames/s times GlobalSpeed, rendered at 60 Hz
local ticks = 0
Speed.start_test(function() return math.floor(ticks) end, 2)
for _ = 1, 60 * 30 do
    CLK = CLK + 1 / 60
    ticks = ticks + (0.5 + 0.1 * applied_speed)
    Speed.update()
    if not Speed.test then break end
end
check(not Speed.test, "test finished")
check(Speed.base_fps and math.abs(Speed.base_fps - 60) < 2, "baseline ~60 fps")
local rg = Speed.results["global"]
check(rg and not rg.ok, "global speed gives no extra frames (as in SF6)")
local TS = "training:TrainingManager._tData.OS_Game_Speed"
local rs = Speed.results[TS]
check(rs and rs.ok and math.abs(rs.ratio - 1.5) < 0.05, "Training Game Speed gives 1.5x")
local rt = Speed.results["training:TrainingManager._tData.GameSpeed"]
check(rt and not rt.ok, "animation-only speed rejected")
check(Speed.best() == TS, "best is Training Game Speed")
check(global_speed == 1.0 and tdata.GameSpeed == 1.0 and tdata.OS_Game_Speed == 5 and applied_speed == 5, "everything restored after the test")
-- apply / restore
check(Speed.apply(TS, 1.3) and tdata.OS_Game_Speed == 8 and applied_speed == 8 and tdata.Is_Speed_Setting, "1.3x = SPEED_130, applied")
Speed.restore()
check(tdata.OS_Game_Speed == 5 and applied_speed == 5 and not tdata.Is_Speed_Setting and not Speed.active, "restored to 100%")
check(Speed.apply(TS, 4) and tdata.OS_Game_Speed == 10, "capped at SPEED_150")
Speed.restore()
check(not Speed.apply("training:TrainingManager._tData.SpeedIndex", 2), "index setting refused")
-- scan: walks the training manager and gBattle's statics
json = { dump_file = function(p, v) DUMP = v; return true end }
local game = { _SlowRate = 1.0, Name = "x" }
local game_obj = { get_address = function() return 9 end, get_field = function(_, n) return game[n] end,
    get_type_definition = function() return { get_full_name = function() return "nBattle.sGame" end,
        get_fields = function() return { mkfield("_SlowRate", "System.Single"), mkfield("Name", "System.String") } end,
        get_methods = function() return { { get_name = function() return "SetSlowRate" end } } end } end }
sdk.find_type_definition = function(n)
    if n == "gBattle" then return { get_fields = function() return { { get_name = function() return "Game" end, is_static = function() return true end,
        get_data = function() return { get_data = function() return game_obj end } end } } end } end
    if n == "app.training.GameSpeed" then return { get_fields = function() return { { get_name = function() return "Speed100" end, is_static = function() return true end, get_data = function() return 0 end } } end } end
    return {}
end
local ok, n = Speed.scan("x.json")
local joined = table.concat(DUMP.values, "\n")
check(ok and joined:find("gBattle.Game._SlowRate = 1.0", 1, true), "scan finds the battle's slow rate")
check(joined:find("TrainingManager._tData.GameSpeed", 1, true), "scan includes training values")
check(DUMP.methods["nBattle.sGame"] and DUMP.methods["nBattle.sGame"][1] == "SetSlowRate", "scan lists speed-ish methods")
check(DUMP.enums["app.training.GameSpeed"][1] == "Speed100 = 0", "scan lists enum names")
-- probe: a battle field that follows the applied speed shows up; a running counter doesn't
local chron = { _Rate = 1.0, _Counter = 0 }
local chron_obj = { get_address = function() return 77 end, get_field = function(_, n) return chron[n] end,
    get_type_definition = function() return { get_fields = function() return { mkfield("_Rate", "System.Single"), mkfield("_Counter", "System.Int32") } end } end }
sdk.find_type_definition = function(n)
    if n == "gBattle" then return { get_field = function(_, root) if root == "Chronos" then return { get_data = function() return chron_obj end } end end } end
    return {}
end
local okp = Speed.start_probe("p.json")
check(okp, "probe starts")
for _ = 1, 60 * 5 do
    CLK = CLK + 1 / 60
    chron._Rate = (0.5 + 0.1 * applied_speed) ; chron._Counter = chron._Counter + 1
    Speed.update_probe()
    if not Speed.probe then break end
end
check(not Speed.probe and Speed.last_probe and Speed.last_probe.hits >= 1, "probe finished")
local found_rate = false
for _, h in ipairs(DUMP.changed_with_speed or {}) do if h:find("gBattle.Chronos._Rate", 1, true) then found_rate = true end; check(not h:find("_Counter"), "counter filtered out") end
check(found_rate, "probe finds the rate field")
check(applied_speed == 5, "speed back to 100% after the probe")
print(fail == 0 and "speed ok" or (fail .. " failed"))
os.exit(fail == 0 and 0 or 1)
