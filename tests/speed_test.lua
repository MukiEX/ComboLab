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
        is_a = function(_, x) return x == "System.Enum" and tname == "app.SpeedType" end,
        is_value_type = function() return tname ~= "app.TrainingData" end } end } end
local tdata = { GameSpeed = 1.0, SpeedIndex = 0 }
local tdata_obj = {
    get_address = function() return 2 end,
    get_field = function(_, n) return tdata[n] end, set_field = function(_, n, v) tdata[n] = v end,
    get_type_definition = function() return { get_fields = function() return { mkfield("GameSpeed", "System.Single"), mkfield("SpeedIndex", "app.SpeedType"), mkfield("Other", "System.Int32") } end,
        get_parent_type = function() return nil end } end,
}
tdata.Other = 5
local tm = {
    get_address = function() return 1 end,
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
    ticks = ticks + global_speed
    Speed.update()
    if not Speed.test then break end
end
check(not Speed.test, "test finished")
check(Speed.base_fps and math.abs(Speed.base_fps - 60) < 2, "baseline ~60 fps")
local rg = Speed.results["global"]
check(rg and rg.ok and math.abs(rg.ratio - 2) < 0.1, "global speed gives 2x real frames")
local rt = Speed.results["training:TrainingManager._tData.GameSpeed"]
check(rt and not rt.ok, "animation-only speed rejected")
check(Speed.best() == "global", "best is the global speed")
check(global_speed == 1.0 and tdata.GameSpeed == 1.0, "everything restored after the test")
-- apply / restore
check(Speed.apply("global", 3) and global_speed == 3, "applied 3x")
Speed.restore()
check(global_speed == 1.0 and not Speed.active, "restored")
check(not Speed.apply("training:TrainingManager._tData.SpeedIndex", 2), "index setting refused")
print(fail == 0 and "speed ok" or (fail .. " failed"))
os.exit(fail == 0 and 0 or 1)
