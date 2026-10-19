-- Window prediction from frame data. Numbers are Ryu's 5LP from MMDK's data
-- dump (startup 4, recovers on frame 13, 14 hitstun, 9 hitstop), +4 on hit.
--   lua tests/predict_test.lua
package.path = "reframework/autorun/?.lua;" .. package.path
local Predict = require("combolab.predict")
local fails = 0
local function check(c, m) if not c then fails = fails + 1; print("FAIL " .. m) end end

local LP = { main = 3, follow = 6, margin = 13, hit = { stun = { st = 14, cr = 14, ch = 16, pc = 18, bl = 9 }, stop_o = 9, stop_t = 9 } }
check(Predict.advantage(LP) == 4, "5LP +4 on hit")
check(Predict.advantage(LP, "bl") == -1, "5LP -1 on block")
check(Predict.advantage(LP, "pc") == 8, "5LP +8 on punish counter")

-- 5LP, 5LP: +4 into a 4f move is a 1-frame link
local w = Predict.window(",", LP, LP, nil, { dq = 0 })
check(w and w.E == 22 and w.L == 22, "5LP, 5LP is a 1f link at frame 22: " .. tostring(w and w.E) .. ".." .. tostring(w and w.L))
-- on punish counter it gets 4 frames wider
w = Predict.window(",", LP, LP, nil, { dq = 0, sit = "pc" })
check(w and w.L - w.E + 1 == 5, "PC widens the link to 5f")
-- into a 5f move it can't link
local slow = { main = 4, margin = 20 }
w = Predict.window(",", LP, slow, nil, { dq = 0 })
check(w and w.impossible, "+4 doesn't link into a 5f move")

-- cancel window [3,6): opens on the hit frame, lasts through hitstop
w = Predict.window(">", LP, slow, { { s = 3, e = 6 } }, { dq = 0 })
check(w and w.E == 3 and w.L == 14, "cancel 3..14 with hitstop: " .. tostring(w and w.E) .. ".." .. tostring(w and w.L))
-- a range before the hit doesn't count
w = Predict.window(">", LP, slow, { { s = 1, e = 3 } }, { dq = 0 })
check(w == nil, "pre-hit-only range gives no prediction")
-- no data, no prediction
check(Predict.window(">", LP, slow, {}, {}) == nil, "no cancel ranges")
check(Predict.window(",", { margin = 10 }, slow, nil, {}) == nil, "link needs hit data")

-- calibration shifts edges once there are 3+ measurements
local cal = { cancel = { dE = 3, dL = -3, n = 3 } }
w = Predict.window(">", LP, slow, { { s = 3, e = 6 } }, { dq = 0, cal = cal })
check(w.E == 4 and w.L == 13, "calibration applied")
cal.cancel.n = 2
w = Predict.window(">", LP, slow, { { s = 3, e = 6 } }, { dq = 0, cal = cal })
check(w.E == 3, "calibration ignored below 3 measurements")

print(fails == 0 and "predict ok" or (fails .. " failures"))
os.exit(fails == 0 and 0 or 1)
