-- Training settings by path: snapshot / diff / save with a combo / restore.   lua tests/tsettings_test.lua
package.path = "reframework/autorun/?.lua;" .. package.path
local fail = 0
local function check(c, m) if not c then fail = fail + 1; print("FAIL: " .. m) end end
local applied, refreshed = {}, 0
-- fake managed objects: tables with fields, a type name, field list
local function mo(tname, fields, order)
    local o = { __f = fields }
    o.get_field = function(self, n) return self.__f[n] end
    o.set_field = function(self, n, v) self.__f[n] = v end
    o.get_type_definition = function() return { get_full_name = function() return tname end,
        get_fields = function()
            local list = {}
            for _, n in ipairs(order) do
                list[#list + 1] = { get_name = function() return n end, is_static = function() return false end,
                    get_type = function() return { get_full_name = function() return type(fields[n]) == "number" and "System.Int32" or "x" end } end }
            end
            return list
        end } end
    return o
end
local juri = mo("app.training.CharaData", { FSE_Infinite = 0, Stock = 3 }, { "FSE_Infinite", "Stock" })
local ryu = mo("app.training.CharaData", { FSE_Infinite = 0, Stock = 0 }, { "FSE_Infinite", "Stock" })
local list = { juri, ryu }
local listobj = { get_type_definition = function() return { get_full_name = function() return "System.Collections.Generic.List`1<app.training.CharaData>" end } end,
                  call = function(_, m, i) if m == "get_Count" then return #list end; if m == "get_Item" then return list[i + 1] end end }
local chara = mo("app.training.TrainingData.TM_CharacterSetting", { FighterList = listobj }, { "FighterList" })
local tdata = mo("app.training.TrainingData", { CharacterSetting = chara, Life = 100 }, { "CharacterSetting", "Life" })
local tf = { get_type_definition = function() return { get_full_name = function() return "app.training.tf_CharacterSetting" end } end,
             call = function(_, m) if m == "bApply" then applied.char = (applied.char or 0) + 1 end end }
local entries = { call = function(_, m, i) if m == "get_Count" then return 1 end; return { get_field = function() return tf end } end }
local tm = { get_field = function(_, n) if n == "_tData" then return tdata end; if n == "_tfFuncs" then return { get_field = function() return entries end } end end,
             call = function(_, m) if m == "set_IsReqRefresh" then refreshed = refreshed + 1 end end }
sdk = { get_managed_singleton = function() return tm end }
local TS = require("combolab.tsettings")

local a = TS.snapshot()
check(a["CharacterSetting.FighterList[0].FSE_Infinite"] == 0 and a["Life"] == 100, "snapshot reaches list items")
juri.__f.FSE_Infinite = 1                      -- the player turns it on in the menu
local d = TS.diff(a, TS.snapshot())
check(#d == 1 and d[1].path == "CharacterSetting.FighterList[0].FSE_Infinite" and d[1].to == 1, "diff finds the one setting")
juri.__f.FSE_Infinite = 0                      -- and back off
local n = TS.apply_combo({ { path = d[1].path, value = 1 } })
check(n == 1 and juri.__f.FSE_Infinite == 1 and applied.char == 1, "combo setting written and applied with tf_CharacterSetting")
TS.apply_combo(nil)                            -- another combo without settings
check(juri.__f.FSE_Infinite == 0 and applied.char == 2, "player's value back")
check(TS.apply_combo({ { path = "Nope.X", value = 1 } }) == 0, "unknown path ignored")
print(fail == 0 and "tsettings ok" or (fail .. " failed"))
os.exit(fail == 0 and 0 or 1)
