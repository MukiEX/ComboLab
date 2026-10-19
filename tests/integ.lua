-- Integration test: runs ComboLab.lua + game/overlay against a mocked
-- REFramework API whose "game" is the toy engine. Run from project root:
--   lua tests/integ.lua
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
    local want = pat:match("\\\\([%w%-_]+)\\%.json%$$")
    for k in pairs(FILES) do
        local kd, kn = k:match("^ComboLab\\(%a+)\\([%w%-_]+)%.json$")
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
local function player(addr)
    local p = { addr = addr, mpActParam = { ActionPart = { _Engine = engine_obj() } },
                pl_input_new = 0, pl_sw_new = 0, rl_dir = true,
                damage_time = 0, hit_stop = 0, guard_time = 0 }
    function p:get_field(n) return self[n] end
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

dofile("reframework/autorun/ComboLab.lua")
assert(on_frame and on_ui, "callbacks registered")

-- ------------------------------------------------------------ driver
local clock = 0
os.clock = function() return clock end

local function frame(held, dir)
    local s = Toy.engine_step(E, held, dir)
    -- reflect engine into the mocked game objects
    local raw = 0
    if dir == 1 or dir == 2 or dir == 3 then raw = raw | 2 end
    if dir == 7 or dir == 8 or dir == 9 then raw = raw | 1 end
    if dir == 3 or dir == 6 or dir == 9 then raw = raw | 8 end
    if dir == 1 or dir == 4 or dir == 7 then raw = raw | 4 end
    P0.pl_input_new = raw
    P0.pl_sw_new = held | raw
    P1.damage_time = E.opp_stun
    P1.guard_time = E.guard
    team0.mComboCount = E.cc
    for _, h in ipairs(hooks) do
        h.pre({ [2] = 1000 }); h.post(0)
        h.pre({ [2] = 2000 }); h.post(0)
    end
    clock = clock + 1 / 60
    on_frame()
end

local function play(plan, n)
    -- plan: { {t=frame, held=bits, dir=d, len=2}, ... } relative to now
    local t0 = 0
    for f = 1, n do
        local held, dir = 0, 5
        for _, p in ipairs(plan) do
            if f >= p.t and f < p.t + (p.len or 2) then held = held | p.held; dir = p.dir or dir end
        end
        frame(held, dir)
    end
end

-- idle a bit so the bridge loads the combo and neutral ids are learned
for _ = 1, 240 do frame(0, 5) end
local st = FILES["ComboLab\\status.json"]
assert(st and st.combo_id == "guile-test", "combo loaded via command: " .. tostring(st and st.combo_id))
assert(st.tick_source == "hook", "ticks from hook: " .. tostring(st.tick_source))

-- clean attempts: 2LP at 10, 2LP link 12f after first start, DR 6f after, 5HP 4f after DR start
local function clean(d2)
    play({ { t = 10, held = LP, dir = 2 }, { t = 10 + d2, held = LP, dir = 2 },
           { t = 10 + d2 + 6, held = MP | MK, dir = 5 }, { t = 10 + d2 + 6 + 4, held = HP, dir = 5 } }, 150)
end
for _, d in ipairs({ 12, 10, 14, 11, 16 }) do clean(d) end
local prof = FILES["ComboLab\\profiles\\guile-test.json"]
assert(prof, "profile written")
print(string.format("profile: attempts %d clean %d", prof.attempts, prof.successes))
local w2 = prof.windows[2]
print(string.format("step2 window %s..%s n=%s", tostring(w2.E), tostring(w2.L), tostring(w2.n)))
assert(prof.successes == 4, "4 clean (d2=10 makes the DR press land before 2LP hits: early)")
assert(w2.E == 10 and w2.L == 16, "window 10..16")

-- train mode via hotkey F5, then a late link
keys_down[0x74] = true; frame(0, 5); keys_down[0x74] = false; frame(0, 5)
for _ = 1, 30 do frame(0, 5) end
clean(19)
local sess = FILES["ComboLab\\sessions\\guile-test.json"]
local last = sess.attempts[#sess.attempts]
print("train result:", last.mode, last.result, "fail step", last.fail_step, "off", last.steps[2].off)
assert(last.mode == "train" and last.ok == false and last.fail_step == 2 and last.steps[2].off == 3, "late +3 in train")

-- ------------------------------------------------------------ hub sync pickup
local before = #FILES["ComboLab\\profiles\\guile-test.json"].steps[2].samples
local s0 = FILES["ComboLab\\profiles\\guile-test.json"].steps[2].samples[1]
assert(s0.u and s0.t, "new samples carry an id and a time")
local shared = deep(FILES["ComboLab\\profiles\\guile-test.json"])
shared.steps[2].samples = {}
for i = 1, 3 do
    shared.steps[2].samples[i] = { p = 12, q = 13, res = "ok", spam = 0, mode = "develop", a = i, t = os.time(), u = "zzzz-" .. i }
end
FILES["ComboLab\\shared\\guile-test.json"] = shared
FILES["ComboLab\\combos\\guile-two.json"] = deep(FILES["ComboLab\\combos\\guile-test.json"])
FILES["ComboLab\\combos\\guile-two.json"].id = "guile-two"
local shared2 = deep(shared); shared2.combo_id = "guile-two"
FILES["ComboLab\\shared\\guile-two.json"] = shared2
FILES["ComboLab\\shared\\_status.json"] = { combos_rev = 1, shared = { ["guile-test"] = 5, ["guile-two"] = 6 } }
for _ = 1, 400 do frame(0, 5) end      -- first check notes combos_rev
FILES["ComboLab\\shared\\_status.json"].combos_rev = 2   -- agent pulled a combo: rescan
for _ = 1, 400 do frame(0, 5) end
local after = FILES["ComboLab\\profiles\\guile-test.json"]
assert(#after.steps[2].samples == before + 3 and after.shared_rev == 5, "shared samples merged into the loaded combo")
local two = FILES["ComboLab\\profiles\\guile-two.json"]
assert(two and #two.steps[2].samples == 3 and two.shared_rev == 6, "shared profile merged for a combo that isn't loaded")
for _ = 1, 400 do frame(0, 5) end
assert(#FILES["ComboLab\\profiles\\guile-test.json"].steps[2].samples == before + 3, "no double merge")
print("hub pickup OK")

-- overlay drew something
assert(draws > 0, "overlay drew")
local saw = false
for _, t in ipairs(texts) do if t:find("DROPPED at 2LP") then saw = true end end
assert(saw, "result banner shown")
on_ui()
print("integration OK; draw calls:", draws)

-- ------------------------------------------------------------ optional demo data dump
local out = os.getenv("DUMP")
if out then
    math.randomseed(7)
    -- more develop attempts with human-ish jitter, then train attempts
    keys_down[0x74] = true; frame(0, 5); keys_down[0x74] = false; frame(0, 5) -- back to develop
    for _ = 1, 40 do
        local d2 = 7 + math.random(0, 12)
        local d3 = 4 + math.random(0, 6)
        local d4 = 2 + math.random(0, 4)
        play({ { t = 10, held = LP, dir = 2 }, { t = 10 + d2, held = LP, dir = 2 },
               { t = 10 + d2 + d3, held = MP | MK, dir = 5 }, { t = 10 + d2 + d3 + d4, held = HP, dir = 5 } }, 150)
    end
    keys_down[0x74] = true; frame(0, 5); keys_down[0x74] = false; frame(0, 5) -- train
    for _ = 1, 30 do
        local d2 = 9 + math.random(-2, 9)
        local d3 = 5 + math.random(-1, 3)
        local extra = math.random() < 0.15 and { t = 10 + d2 + d3 + 8, held = HP, dir = 5 } or nil
        local plan = { { t = 10, held = LP, dir = 2 }, { t = 10 + d2, held = LP, dir = 2 },
               { t = 10 + d2 + d3, held = MP | MK, dir = 5 }, { t = 10 + d2 + d3 + 4, held = HP, dir = 5 } }
        if extra then plan[#plan + 1] = extra end
        play(plan, 150)
    end
    local function enc(v, ind)
        local t = type(v)
        if t == "table" then
            local n = #v
            local isarr = n > 0
            for k in pairs(v) do if type(k) ~= "number" or k < 1 or k > n or math.type(k) ~= "integer" then isarr = false end end
            local parts = {}
            if isarr then
                for i = 1, n do parts[#parts + 1] = enc(v[i]) end
                return "[" .. table.concat(parts, ",") .. "]"
            end
            for k, x in pairs(v) do parts[#parts + 1] = string.format("%q", tostring(k)) .. ":" .. enc(x) end
            if #parts == 0 then return "{}" end
            return "{" .. table.concat(parts, ",") .. "}"
        elseif t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
        elseif t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then return "null" end
            return math.type(v) == "integer" and tostring(v) or string.format("%.4f", v)
        elseif t == "boolean" then return tostring(v)
        else return "null" end
    end
    local all = {}
    for k, v in pairs(FILES) do all[k:gsub("\\", "/"):gsub("^ComboLab/", "")] = v end
    local f = io.open(out, "w"); f:write(enc(all)); f:close()
    print("dumped demo data to " .. out)
end
