-- Dummy settings: what each combo wants, set + apply, restore.   lua tests/dummy_test.lua
package.path = "reframework/autorun/?.lua;" .. package.path
local fail = 0
local function check(c, m) if not c then fail = fail + 1; print("FAIL: " .. m) end end
local counter = { NC_TYPE = 0, PC_TYPE = 0 }
local guard = { GuardType = 3 }
local status = { DummyActionType = 0 }
local applied = {}
local function obj(t, fields) return setmetatable({ get_field = function(_, n) return fields[n] end }, { __index = t, __newindex = t }) end
local tdata = obj({}, { CounterSetting = obj({}, { DummyData = counter }), GuardSetting = obj({}, { DummyData = guard }),
                        DummyStatus = obj({}, { DummyData = status }) })
local function tfobj(name) return { get_type_definition = function() return { get_full_name = function() return "app.training." .. name end } end,
                                    call = function(_, m) if m == "bApply" then applied[name] = (applied[name] or 0) + 1 end end } end
local list = { tfobj("tf_CounterSetting"), tfobj("tf_GuardSetting"), tfobj("tf_DummyStatus") }
local entries = { call = function(_, m, i) if m == "get_Count" then return #list end; return { get_field = function() return list[i + 1] end } end }
local tm = { get_field = function(_, n) if n == "_tData" then return tdata end; if n == "_tfFuncs" then return { get_field = function() return entries end } end end }
sdk = { get_managed_singleton = function() return tm end }
local Dummy = require("combolab.dummy")

local function combo(name, first) return { name = name, steps = { { label = first or "2LP" } } } end
check(Dummy.wants(combo("Drive Impact: DI corner", "DI")).counter_name == "pc", "DI starter -> punish counter")
check(Dummy.wants(combo("Punish counter: PC 5HK")).counter_name == "pc", "PC in name")
check(Dummy.wants(combo("BnB: CH 2MP link")).counter_name == "ch", "CH in name")
check(Dummy.wants(combo("Lights: 2LP confirm")).counter_name == "normal", "plain combo -> normal")
check(Dummy.wants(combo("Lights vs crouching")).stance == "crouch", "crouching in name")
check(Dummy.wants({ name = "x", steps = { { label = "DI" } }, dummy = { counter = "normal", stance = "crouch" } }).counter_name == "normal", "combo override wins")

local msg = Dummy.setup(combo("DI corner", "DI"), { no_guard = true })
check(counter.PC_TYPE == 1 and counter.NC_TYPE == 0 and applied.tf_CounterSetting == 1, "punish counter set and applied")
check(guard.GuardType == 0 and applied.tf_GuardSetting == 1, "no guard for the bot")
check(msg:find("punish counter"), "describes it: " .. tostring(msg))
Dummy.setup(combo("BnB: CH 2MP link"), {})
check(counter.NC_TYPE == 1 and counter.PC_TYPE == 0, "counter hit set")
Dummy.setup(combo("vs crouching"), {})
check(status.DummyActionType == 1 and counter.NC_TYPE == 0, "crouching, normal hit")
Dummy.restore_guard()
check(guard.GuardType == 3, "guard back after the bot")
Dummy.restore()
check(counter.NC_TYPE == 0 and counter.PC_TYPE == 0 and status.DummyActionType == 0 and guard.GuardType == 3, "everything back as the player had it")
print(fail == 0 and "dummy ok" or (fail .. " failed"))
os.exit(fail == 0 and 0 or 1)
