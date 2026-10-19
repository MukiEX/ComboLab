-- movedata.lua against a mock of SF6's object graph, shaped like the paths in
-- MMDK (gBattle.Resource / Player / Command). Checks the reading code paths;
-- the real layout still needs confirming in game (REFramework menu > Diagnostics).
--   lua tests/movedata_test.lua
package.path = "reframework/autorun/?.lua;" .. package.path
local fails = 0
local function check(c, m) if not c then fails = fails + 1; print("FAIL " .. m) end end

local function obj(fields, tname, calls, elements)
    local o = { _f = fields or {}, _c = calls or {}, _e = elements }
    function o:get_field(n) return self._f[n] end
    function o:call(n, ...) local f = self._c[n]; if not f then error("no method " .. n) end; return f(...) end
    function o:get_type_definition() return { get_name = function() return tname or "Object" end } end
    if elements then function o:get_elements() return self._e end end
    return o
end
local function list(items) return obj({}, "List", { get_Count = function() return #items end, get_Item = function(i) return items[i + 1] end }, items) end
local function dict(map)
    return obj({}, "Dictionary", { ContainsKey = function(k) return map[k] ~= nil end, get_Item = function(k) return map[k] end,
        get_Count = function() local n = 0; for _ in pairs(map) do n = n + 1 end; return n end })
end

-- Ryu 5LP (600) and 236LP (1000)
local function tkey(s, e, g) return obj({ _StartFrame = s, _EndFrame = e, TriggerGroup = g, ConditionFlag = 5131 }, "TriggerKey") end
local function akey(s, e, idx) return obj({ _StartFrame = s, _EndFrame = e, AttackDataListIndex = idx, CollisionType = 0 }, "AttackCollisionKey") end
local act600 = obj({ ActionFrame = obj({ MainFrame = 3, FollowFrame = 6, MarginFrame = 13 }), Frame = 39,
    Keys = list({ list({ tkey(1, 3, 58), tkey(3, 6, 58) }), list({ akey(3, 6, -1), akey(3, 6, 15) }) }) })
local act1000 = obj({ ActionFrame = obj({ MainFrame = 13, FollowFrame = 15, MarginFrame = 47 }), Frame = 60, Keys = list({}) })
local style = obj({ ActionList = dict({ [600] = act600, [1000] = act1000 }) })
local person = obj({ FAB = obj({ StyleDict = dict({ [0] = style }) }) })
local function entry(stun) return obj({ HitStun = stun, HitStopOwner = 9, HitStopTarget = 9, DmgType = 0 }) end
local params = {}
for i = 0, 19 do params[i + 1] = entry(0) end
params[1], params[2], params[9], params[13], params[17] = entry(14), entry(14), entry(16), entry(18), entry(9)
local hit15 = obj({ param = list(params) })
local statics = {
    Resource = obj({ Data = list({ person, person }) }),
    Player = obj({ mpLoadHitDataAddress = list({ dict({ [15] = hit15 }), dict({}) }) }),
    Command = obj({}, "gCommand", {
        get_mUserEngine = function() return list({ obj({}, "Eng", { ["GetTrigger()"] = function()
            return list({ obj({ action_id = 0 }), obj({ action_id = 1000 }), obj({ action_id = 1100 }) }) end }) }) end,
        GetTriggerGroup = function(pl, g)
            if g ~= 58 then return nil end
            local bits = obj({}, "BitArray", {}, { obj({ mValue = 1 }), obj({ mValue = 2 }) })
            bits.add_ref = function() end
            return obj({ Flag = obj({}, "Flag", { BitArray = function() return bits end }) })
        end,
    }),
}
sdk = { find_type_definition = function(n)
    if n ~= "gBattle" then return nil end
    return { get_field = function(_, f) return { get_data = function() return statics[f] end } end }
end }

local MD = require("combolab.movedata")
local A = MD.facts(0, 2, 600)
check(A and A.main == 3 and A.margin == 13 and A.frame == 39, "action frames")
check(A and #A.trig == 2 and A.trig[2].s == 3 and A.trig[2].e == 6 and A.trig[2].g == 58, "trigger keys")
check(A and #A.atk == 1 and A.atk[1].idx == 15, "strike keys (proximity box skipped)")
check(A and A.hit and A.hit.stun.st == 14 and A.hit.stun.pc == 18 and A.hit.stun.bl == 9 and A.hit.stop_o == 9, "hit data")
local set = MD.group(0, 2, 58)
check(set and set[1000] and set[1100] and not set[0], "trigger group -> actions")
local r = MD.cancel_ranges(0, 2, A, 1000)
check(r and #r == 2 and r[2].s == 3, "cancel ranges into 236LP")
check(#MD.cancel_ranges(0, 2, A, 4242) == 0, "no ranges for a move outside the group")
check(MD.facts(0, 2, 9999) == nil, "unknown action -> nil")
local B = MD.facts(0, 2, 1000)
check(B and B.main == 13 and B.hit == nil, "move without hits")
local Predict = require("combolab.predict")
check(Predict.advantage(A) == 4, "advantage from read data")
print(fails == 0 and "movedata ok" or (fails .. " failures"))
os.exit(fails == 0 and 0 or 1)
