-- Bot test: the real mod (ComboLab.lua + bot) drives the toy engine purely via
-- injected input and must discover the engine's true timing windows.
--   lua tests/bot_test.lua
package.path = "reframework/autorun/?.lua;tests/?.lua;" .. package.path
local Toy = require("toy")
local LP, MP, HP, MK = Toy.LP, Toy.MP, Toy.HP, Toy.MK

-- ------------------------------------------------------------ json mock (in-memory files)
FILES = {}
local FILES = FILES
local function deep(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deep(x) end
    return o
end
json = {
    load_file = function(p) return deep(FILES[p]) end,
    dump_file = function(p, v) FILES[p] = deep(v); return true end,
}
LOGLINES = {}
log = { info = function(m) LOGLINES[#LOGLINES + 1] = m end }
fs = { glob = function(pat)
    local out = {}
    local dir = pat:match("^ComboLab\\\\(%a+)\\\\")
    local want = pat:match("\\\\([%w%-]+)\\%.json%$$")
    for k in pairs(FILES) do
        local kd, kn = k:match("^ComboLab\\(%a+)\\([%w%-]+)%.json$")
        if kd == dir and (not want or want == kn) then out[#out + 1] = k end
    end
    return out
end }

-- ------------------------------------------------------------ game objects
local E = Toy.new_engine()
local function engine_obj()
    return {
        get_ActionID = function() return E.act end,
        get_ActionFrame = function() return E.af end,
        get_MarginFrame = function() return E.mv and (E.mv.startup + E.mv.active + E.mv.rec) or 0 end,
    }
end
local dummy_engine = { get_ActionID = function() return 1 end, get_ActionFrame = function() return 0 end, get_MarginFrame = function() return 0 end }
local teleports = 0
local function player(addr)
    local p = { addr = addr, mpActParam = { ActionPart = { _Engine = (addr == 2000) and dummy_engine or engine_obj() } },
                pos = { x = { v = 0 } },
                pl_input_new = 0, pl_sw_new = 0, rl_dir = true,
                damage_time = 0, hit_stop = 0, guard_time = 0 }
    function p:get_field(n) return self[n] end
    function p:set_field(n, v) self[n] = v end
    function p:POS_SETx(v) self.pos.x.v = math.floor(v * 65536); teleports = teleports + 1 end
    function p:get_address() return self.addr end
    return p
end
local P0, P1 = player(1000), player(2000)
local sPlayer = { mcPlayer = { [0] = P0, [1] = P1 } }
local team0 = { mComboCount = 0, mComboDamage = 0 }
local sTeam = { mcTeam = { [0] = team0, [1] = { mComboCount = 0 } } }

local hooks = {}
sdk = {
    find_type_definition = function(name)
        if name == "gBattle" then
            return { get_field = function(_, f)
                return { get_data = function() return f == "Player" and sPlayer or sTeam end }
            end }
        elseif name == "via.sfix" then
            return { get_method = function() return { call = function(_, _, v) return v end } end }
        elseif name == "nBattle.cPlayer" then
            return { get_method = function(_, m) return m end }
        end
    end,
    hook = function(m, pre, post) hooks[#hooks + 1] = { pre = pre, post = post } end,
    to_int64 = function(x) return x end,
    get_managed_singleton = function(name)
        if name == "app.training.TrainingManager" then
            local tdata = { get_field = function(_, f)
                if f == "SelectMenu" then return { PlayerDatas = { [0] = { FighterID = 18, InputType = 0 } } } end
            end }
            return { get_field = function(_, f) if f == "_tData" then return tdata end end }
        elseif name == "app.PauseManager" then
            return { get_field = function() return 64 end }
        end
    end,
}

-- ------------------------------------------------------------ re / imgui / draw mocks
local on_frame, on_ui = nil, nil
re = { on_frame = function(f) on_frame = f end, on_draw_ui = function(f) on_ui = f end }
local draws = 0
local texts = {}
draw = setmetatable({}, { __index = function() return function() draws = draws + 1 end end })
Vector2f = { new = function(x, y) return { x = x, y = y } end }
imgui = setmetatable({
    get_display_size = function() return { x = 1920, y = 1080 } end,
    calc_text_size = function(s) return { x = #s * 9, y = 18 } end,
    begin_window = function() return true end,
    tree_node = function() return true end,
    combo = function(_, v) return false, v end,
    checkbox = function(_, v) return false, v end,
    slider_float = function(_, v) return false, v end,
    button = function() return false end,
    load_font = function() return {} end,
    text_colored = function(s) texts[#texts + 1] = s end,
}, { __index = function() return function() end end })
local keys_down = {}
reframework = { is_key_down = function(_, vk) return keys_down[vk] == true end }

-- ------------------------------------------------------------ combo file (as the web app writes it)
FILES["ComboLab\\combos\\guile-test.json"] = {
    id = "guile-test", name = "Test BnB", fighter = "Guile", fighter_id = 18, hash = "abc",
    notation = "2LP, 2LP > DR > 5HP",
    steps = {
        { label = "2LP", sep = "start", kind = "hit", trigger = { type = "button", mask = 16, mode = "all" } },
        { label = "2LP", sep = ",", kind = "hit", trigger = { type = "button", mask = 16, mode = "all" } },
        { label = "DR", sep = ">", kind = "move", trigger = { type = "button", mask = 288, mode = "all" } },
        { label = "5HP", sep = ">", kind = "hit", trigger = { type = "button", mask = 64, mode = "all" } },
    },
}
FILES["ComboLab\\command.json"] = { seq = 1, cmd = "load", combo_id = "guile-test", mode = "develop" }
FILES["ComboLab\\config.json"] = { result_seconds = 0 }

dofile("reframework/autorun/ComboLab.lua")

-- BOT_PRED="2:E:L,3:E:L,..." stands in for windows predicted from game data
if os.getenv("BOT_PRED") then
    local pred = {}
    for k, e, l in os.getenv("BOT_PRED"):gmatch("(%d+):(%-?%d+):(%-?%d+)") do
        pred[tonumber(k)] = { kind = "test", E = tonumber(e), L = tonumber(l) }
    end
    require("combolab.profile").prediction = function(_, k) return pred[k] end
end

local clock = 0
os.clock = function() return clock end
local DIRS = { [0] = 5, [1] = 8, [2] = 2, [4] = 4, [8] = 6, [5] = 7, [6] = 1, [9] = 9, [10] = 3 }

MULTI = tonumber(os.getenv("BOT_MULTI") or "1")
local function frame()
    P0.pl_input_new, P0.pl_sw_new = 0, 0           -- nobody touches the real pad
    P1.damage_time, P1.guard_time = E.opp_stun, E.guard
    team0.mComboCount = E.cc
    for _, h in ipairs(hooks) do
        h.pre({ [2] = 1000 }); h.post(0)
        h.pre({ [2] = 2000 }); h.post(0)
    end
    local raw = P0.pl_input_new & 15
    Toy.engine_step(E, P0.pl_sw_new & ~15, DIRS[raw] or 5)
    clock = clock + 1 / 60
    -- BOT_MULTI=n: n battle frames per rendered frame (research speed)
    FRAMES = (FRAMES or 0) + 1
    if FRAMES % MULTI == 0 then on_frame() end
end

for _ = 1, 120 do frame() end
if os.getenv("DBG") then print("status:", FILES["ComboLab\\status.json"] and FILES["ComboLab\\status.json"].error, LOGLINES[#LOGLINES]) end
FILES["ComboLab\\command.json"] = { seq = 2, cmd = "bot_start", ids = { "guile-test" }, options = { reps = 2 } }
local n = 0
repeat
    for _ = 1, 600 do frame() end
    n = n + 600
    local st = FILES["ComboLab\\status.json"]
    local b = st and st.bot
    if n % 6000 == 0 and b then print(string.format("  t=%d phase %s step %s d %s attempts %d state %s", n, tostring(b.phase), tostring(b.step), tostring(b.d), b.attempts or 0, tostring(b.state))) end
until (FILES["ComboLab\\bot\\guile-test.json"] and not (FILES["ComboLab\\status.json"].bot or {}).running) or n > 400000

local r = FILES["ComboLab\\bot\\guile-test.json"]
assert(r, "bot report written")
print("bot result:", r.ok, r.reason, "attempts", r.attempts, "clean", r.clean, "/", r.clean_of, "teleports", teleports)
for k = 2, 4 do local w = r.windows[k]; if w then print(string.format("  step %d window %d..%d target %d", k, w.E, w.L, w.target)) end end
local prof = FILES["ComboLab\\profiles\\guile-test.json"]
for k = 2, 4 do
    local w = prof.windows[k]
    print(string.format("  profile step %d: %s..%s sweet %s..%s (n=%s)", k, tostring(w.E), tostring(w.L), tostring(w.sweet_lo), tostring(w.sweet_hi), tostring(w.sweet_n)))
end
local fail = 0
local function check(c, m) if not c then fail = fail + 1; print("FAIL: " .. m) end end
check(r.ok, "bot finished the combo")
-- engine truth for this harness's frame ordering: 2LP link 9 frames wide, DR
-- cancel 9 wide, 5HP latest at 6 (the earliest 5HP frame is below what a
-- scheduled press can reach). The bot's windows must equal what the tracker
-- measured for the profile, and match those widths exactly.
for k = 2, 4 do
    check(r.windows[k] and prof.windows[k].E == r.windows[k].E and prof.windows[k].L == r.windows[k].L,
        "step " .. k .. " bot window equals the profile's measured window")
end
check(r.windows[2].L - r.windows[2].E + 1 == 9, "2LP link window is 9 frames")
check(r.windows[3].L - r.windows[3].E + 1 == 9, "DR cancel window is 9 frames")
check(r.windows[4].L == 6, "5HP late edge = 6")
check(prof.windows[3].sweet_hi and prof.windows[3].sweet_hi < prof.windows[3].L, "late DR presses flagged by the sweet spot")
check(r.clean == r.clean_of, "validation runs all clean")
-- a second run on the same combo starts from the windows it already has
FILES["ComboLab\\bot\\guile-test.json"] = nil
FILES["ComboLab\\command.json"] = { seq = 3, cmd = "bot_start", ids = { "guile-test" }, options = { reps = 2, reset = false } }
n = 0
repeat
    for _ = 1, 600 do frame() end
    n = n + 600
until (FILES["ComboLab\\bot\\guile-test.json"] and not (FILES["ComboLab\\status.json"].bot or {}).running) or n > 400000
local r2 = FILES["ComboLab\\bot\\guile-test.json"]
print("second run attempts", r2 and r2.attempts, "vs first", r.attempts)
check(r2 and r2.ok, "second run finished")
for k = 2, 4 do
    check(r2 and r2.windows[k] and r2.windows[k].E == r.windows[k].E and r2.windows[k].L == r.windows[k].L, "step " .. k .. " same window on the second run")
end
check(r2 and r2.attempts < r.attempts, "second run is quicker")
-- an experimental combo that can't work: "all combos" runs give up after 30 dry attempts
FILES["ComboLab\\combos\\guile-exp.json"] = {
    id = "guile-exp", name = "Impossible", fighter = "Guile", fighter_id = 18, hash = "exp1", experimental = true,
    notation = "5HP, 5HP",
    steps = {
        { label = "5HP", sep = "start", kind = "hit", trigger = { type = "button", mask = 64, mode = "all" } },
        { label = "5HP", sep = ",", kind = "hit", trigger = { type = "button", mask = 64, mode = "all" } },
    },
}
FILES["ComboLab\\command.json"] = { seq = 4, cmd = "bot_start", ids = { "guile-exp" }, options = { reps = 1, experimental_limit = 30 } }
n = 0
repeat
    for _ = 1, 600 do frame() end
    n = n + 600
until (FILES["ComboLab\\bot\\guile-exp.json"] and not (FILES["ComboLab\\status.json"].bot or {}).running) or n > 400000
local r3 = FILES["ComboLab\\bot\\guile-exp.json"]
print("experimental:", r3 and r3.ok, r3 and r3.reason, "attempts", r3 and r3.attempts)
check(r3 and not r3.ok and tostring(r3.reason):find("experimental") and r3.attempts == 30, "experimental combo given up after 30 dry attempts")
print(fail == 0 and "bot test OK" or (fail .. " failed"))
local fo = os.getenv("BOT_OUT")
if fo then
    local f = io.open(fo, "w")
    f:write(string.format("%d", r.attempts))
    for k = 2, 4 do f:write(string.format(" %d:%d:%d", k, r.windows[k].E, r.windows[k].L)) end
    f:close()
end
os.exit(fail == 0 and 0 or 1)
