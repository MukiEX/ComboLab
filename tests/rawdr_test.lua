-- raw Drive Rush trigger: parry (MP+MK) then 66; a plain dash isn't one.   lua tests/rawdr_test.lua
package.path = "reframework/autorun/?.lua;" .. package.path
local Tracker = require("combolab.tracker")
local fail = 0
local function check(c, m) if not c then fail = fail + 1; print("FAIL: " .. m) end end
local MPMK = 32 | 256
local function frames(seq)
    local out = {}
    for i, f in ipairs(seq) do out[i] = { dir = f[1], held = f[2] or 0, t = i } end
    return out
end
local trig = { type = "rawdr", mask = MPMK, mode = "all" }
-- parry held 6 frames, then 6 5 6 (the bot's input)
local f = frames({ {5}, {5, MPMK}, {5, MPMK}, {5, MPMK}, {5, MPMK}, {5, MPMK}, {5, MPMK}, {6}, {6}, {5}, {5}, {6}, {6} })
local hit
for i = 2, #f do if Tracker.trig_match(trig, f, i) then hit = hit or i end end
check(hit == 12, "fires on the second forward (frame " .. tostring(hit) .. ")")
-- plain dash: no parry
local g = frames({ {5}, {6}, {6}, {5}, {5}, {6}, {6} })
local any = false
for i = 2, #g do if Tracker.trig_match(trig, g, i) then any = true end end
check(not any, "a plain dash isn't a raw DR")
for i = 2, #g do if Tracker.trig_match({ type = "dash" }, g, i) then any = true end end
check(any, "but it is a dash")
print(fail == 0 and "rawdr ok" or (fail .. " failed"))
os.exit(fail == 0 and 0 or 1)
