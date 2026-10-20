-- Apple Addict Attack: what each label puts on the highway, and a draw run
-- (song and free play) that must produce only finite coordinates.
package.path = "reframework/autorun/?.lua;" .. package.path
local CLK = 0
os.clock = function() return CLK end
Vector2f = { new = function(x, y) return { x = x, y = y } end }
local bad, ncalls = 0, 0
local function chk(...)
    ncalls = ncalls + 1
    for _, v in ipairs({ ... }) do
        if type(v) == "number" and (v ~= v or v == math.huge or v == -math.huge) then bad = bad + 1 end
    end
end
draw = setmetatable({}, { __index = function() return chk end })
imgui = setmetatable({
    get_display_size = function() return { x = 1920, y = 1080 } end,
    load_font = function(_, px) return { px = px } end,
    calc_text_size = function(s) return { x = #s * 7, y = 13 } end,
    begin_window = function() return true end,
}, { __index = function() return function() end end })

local Profile = require("combolab.profile")
local Overlay = require("combolab.overlay")
local fails = 0
local function eq(name, got, want)
    if got ~= want then fails = fails + 1; print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want)) end
end
local function list(t) return table.concat(t, ",") end
local function bars(t) local o = {} for _, b in ipairs(t) do o[#o + 1] = b[1] .. "-" .. b[2] end return table.concat(o, ",") end

local n = Overlay.aaa_need("5LP"); eq("5LP taps", list(n.taps), "LP"); eq("5LP arrows", list(n.arrows), "")
n = Overlay.aaa_need("2MK"); eq("2MK taps", list(n.taps), "MK"); eq("2MK arrows", list(n.arrows), "2")
n = Overlay.aaa_need("236HK"); eq("236HK arrows", list(n.arrows), "2,3,6"); eq("236HK taps", list(n.taps), "HK")
n = Overlay.aaa_need("623HP"); eq("623HP arrows", list(n.arrows), "6,2,3")
n = Overlay.aaa_need("236236K"); eq("SA arrows", list(n.arrows), "2,3,6,2,3,6"); eq("SA bar", bars(n.bars), "LK-HK")
n = Overlay.aaa_need("236[PP]"); eq("hold", n.hold, true); eq("OD bar", bars(n.bars), "LP-MP")
n = Overlay.aaa_need("214KK"); eq("OD kick bar", bars(n.bars), "LK-MK"); eq("214 arrows", list(n.arrows), "2,1,4")
n = Overlay.aaa_need("[4]6HP"); eq("charge", n.charge, "4"); eq("charge arrows", list(n.arrows), "6"); eq("charge tap", list(n.taps), "HP")
n = Overlay.aaa_need("DR"); eq("DR wall", n.walls.left, true); eq("DR right", n.walls.right, nil); eq("DR no taps", list(n.taps), "")
n = Overlay.aaa_need("DR", { trigger = { type = "rawdr" } }); eq("raw DR arrows", list(n.arrows), "6,6")
n = Overlay.aaa_need("DI"); eq("DI wall", n.walls.right, true)
n = Overlay.aaa_need("PARRY"); eq("parry wall", n.walls.left, true)
n = Overlay.aaa_need("SA2"); eq("SA2 walls", tostring(n.walls.left) .. tostring(n.walls.right), "truetrue")
n = Overlay.aaa_need("THROW"); eq("throw", list(n.taps), "LP,LK")
n = Overlay.aaa_need("66"); eq("dash", list(n.arrows), "6,6")
n = Overlay.aaa_need("j.HP"); eq("jump-in", list(n.taps), "HP")
eq("judge SWEET", Overlay.aaa_kind("SWEET"), "SWEET")
eq("judge EARLY", Overlay.aaa_kind("EARLY -2"), "EARLY")
eq("judge LATE", Overlay.aaa_kind("LATE +3"), "LATE")
eq("judge drop", Overlay.aaa_kind("WRONG MOVE"), "DROP")
eq("judge late drop", Overlay.aaa_kind("LATE"), "DROP")

-- draw runs
local labels = { "2MP", "236[PP]", "[4]6HP", "DI", "623HP", "SA2", "THROW", "5MK", "DR", "214KK" }
for _, song in ipairs({ false, true }) do
    local combo = { id = "x", hash = "h", name = "AAA test", steps = {} }
    for i, l in ipairs(labels) do combo.steps[i] = { label = l, sep = i == 1 and "start" or ">", kind = "hit", trigger = { mask = 16 } } end
    local P = Profile.new(combo)
    for k = 2, #labels do
        for _ = 1, 8 do
            local p = math.random(5, 11)
            P.steps[k].samples[#P.steps[k].samples + 1] = { p = p, q = p + 1, res = "ok", spam = 0, nx = 0 }
        end
    end
    local tick = 100
    local live = (not song) and { c = 2, anchor = 100, steps = { [1] = { res = "ok" } } } or nil
    local S = { mode = "train", combo = combo, profile = P, result_age = 99, msg_age = 99, attempt_seq = 1,
        stats = { n = 3, ok = 2, streak = 2, best = 2 },
        tracker = { live_detail = function() return live end, now = function() return tick end },
        cfg = { scale = 1, y = 0.115, train_view = "aaa", song_mode = song, song_approach = 80, song_beat = 30, note_approach = 36, motion_arrows = true } }
    for f = 0, 150 do
        tick = 100 + f; CLK = f / 60; S.tick_clock = CLK
        S.stick_dir = ({ 5, 2, 3, 6, 4, 7 })[(f % 6) + 1]
        if song and not live and S.song and tick >= S.song.T[1] then live = { c = 2, anchor = S.song.T[1] + 1, steps = { [1] = { res = "ok" } } } end
        while live and live.c <= #labels and tick >= live.anchor + P:window(live.c).mid do
            local k = live.c
            live.steps[k] = { res = (k == 7) and "late" or "ok", p = math.floor(P:window(k).mid), off = (k == 7) and 3 or 0 }
            live.anchor = live.anchor + math.floor(P:window(k).mid) + 1
            live.c = k + 1
        end
        local ok, err = pcall(Overlay.draw, S)
        if not ok then fails = fails + 1; print("FAIL draw (song=" .. tostring(song) .. ") frame " .. f .. ": " .. tostring(err)) break end
    end
end
eq("non-finite draw coordinates", bad, 0)
if ncalls < 1000 then fails = fails + 1; print("FAIL too few draw calls: " .. ncalls) end
if fails == 0 then print("aaa_test: all passed (" .. ncalls .. " draw calls)") else print("aaa_test: " .. fails .. " failed"); os.exit(1) end
