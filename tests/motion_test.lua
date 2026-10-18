-- Motion-arrow parsing and geometry.
package.path = "reframework/autorun/?.lua;" .. package.path
local M = require("combolab.motion")
local function sig(label)
    local t = {}
    for _, p in ipairs(M.parse(label)) do t[#t + 1] = p.t:sub(1, 1) .. ":" .. (p.s or p.seq or "") end
    return table.concat(t, " ")
end
local cases = {
    ["623HP"] = "m:623 t:HP", ["j.214P"] = "t:j. m:214 t:P", ["[2]8HK"] = "t:[ m:2 t:] m:8 t:HK",
    ["236236K"] = "m:236 m:236 t:K", ["66"] = "m:6 m:6", ["DR"] = "t:DR", ["SA2"] = "t:SA2",
    ["5MP"] = "t:MP", ["cr.MK"] = "m:2 t:MK", ["360P"] = "c: t:P", ["236K~K"] = "m:236 t:K t:~ t:K",
    ["Parry"] = "t:Parry", ["22P"] = "m:2 m:2 t:P", ["9"] = "m:9", ["236[PP]"] = "m:236 t:[PP]",
}
local fails = 0
for l, want in pairs(cases) do
    local got = sig(l)
    if got ~= want then print("FAIL", l, got, "want", want); fails = fails + 1 end
end
-- geometry stays inside its box and the DP arrow ends pointing forward
for _, p in ipairs({ { t = "motion", seq = "623" }, { t = "motion", seq = "41236" }, { t = "circle" }, { t = "motion", seq = "2" } }) do
    local g = M.glyph(p)
    for _, l in ipairs(g.lines) do
        for i = 1, #l, 2 do
            if l[i] < -1e-6 or l[i] > g.aspect + 1e-6 or l[i + 1] < -1e-6 or l[i + 1] > 1 + 1e-6 then
                print("FAIL out of box", p.seq or p.t); fails = fails + 1; break
            end
        end
    end
end
local dp = M.glyph({ t = "motion", seq = "623" })
if not (dp.head[3] > 0.95) then print("FAIL 623 head should point forward", dp.head[3], dp.head[4]); fails = fails + 1 end
print(fails == 0 and "motion ok" or (fails .. " failures"))
os.exit(fails == 0 and 0 or 1)
