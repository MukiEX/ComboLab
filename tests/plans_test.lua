-- Every bundled combo must turn into bot inputs or a clear skip reason.
package.path = "reframework/autorun/?.lua;" .. package.path
local Bot = require("combolab.bot")
local dir = arg[1] or "reframework/data/ComboLab/combos"
local ok, skipped, reasons = 0, 0, {}
local function decode(txt)  -- tiny JSON reader good enough for combo files
    local f = load("return " .. txt:gsub('"([%w_]+)"%s*:', '[%q]='):gsub("%[", "{"):gsub("%]", "}"))
    return f and f()
end
for path in io.popen('ls "' .. dir .. '"/*.json'):lines() do
    local txt = io.open(path):read("a")
    local labels, kinds = {}, {}
    for st in txt:gmatch('"label":%s*"(.-)"') do labels[#labels + 1] = st end
    for kd in txt:gmatch('"kind":%s*"(.-)"') do kinds[#kinds + 1] = kd end
    local fid = tonumber(txt:match('"fighter_id":%s*(%d+)'))
    local control = txt:match('"control":%s*"(.-)"')
    local why
    for k, l in ipairs(labels) do
        local p, w = Bot.step_plan({ label = l, kind = kinds[k] }, k, k > 1 and { label = labels[k - 1], kind = kinds[k - 1] } or nil, fid, control)
        if not p then why = w break end
    end
    if why then skipped = skipped + 1; reasons[why] = (reasons[why] or 0) + 1 else ok = ok + 1 end
end
print(ok .. " combos playable, " .. skipped .. " skipped")
for w, n in pairs(reasons) do print(string.format("  %3d  %s", n, w)) end
-- spot checks on generated inputs
local p = Bot.step_plan({ label = "236MK", kind = "hit" }, 2, { label = "5MP", kind = "hit" }, 32, "classic")
assert(#p == 3 and p[1].dir == 2 and p[2].dir == 3 and p[3].dir == 6 and p[3].btn == 256 and p.lead == 2)
p = Bot.step_plan({ label = "SA1", kind = "hit" }, 3, { label = "214HK", kind = "hit" }, 16, "classic")
assert(p.lead == 5 and p[#p].btn == 128, "Juri SA1 is 236236K")
p = Bot.step_plan({ label = "236[PP]", kind = "hit" }, 2, nil, 28, "classic")
assert(p[#p].to == 24 and p[#p].btn == 48, "held PP")
p = Bot.step_plan({ label = "[2]8HK", kind = "hit" }, 3, nil, 18, "classic")
assert(p.charge == 2 and p[#p].btn == 512)
p = Bot.step_plan({ label = "DR", kind = "move" }, 1, nil, 18, "classic")
assert(#p == 4, "raw DR = parry then 66")
print("plan spot checks OK")
