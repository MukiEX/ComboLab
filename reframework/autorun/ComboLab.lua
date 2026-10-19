-- ComboLab: combo timing developer / trainer for Street Fighter 6 (REFramework).
-- Setup happens in reframework/data/ComboLab/ComboLab.html; this script runs the
-- in-game side: per-frame tracking, timing profiles, overlay. Training mode only.

local VERSION = "1.18.0"

-- safe mode: "use_hook": false in config.json samples once per rendered frame
-- instead of hooking the game's input update (read before game.lua installs it)
do
    local c = json.load_file("ComboLab\\config.json")
    _G.COMBOLAB_NO_HOOK = type(c) == "table" and c.use_hook == false
end

local Tracker = require("combolab.tracker")
local Profile = require("combolab.profile")
local Game = require("combolab.game")
local Overlay = require("combolab.overlay")
local Bot = require("combolab.bot")
local MoveData = require("combolab.movedata")
local Predict = require("combolab.predict")
local Speed = require("combolab.speed")

local DIR = "ComboLab\\"
local CFG_PATH = DIR .. "config.json"

-- ---------------------------------------------------------------- config
local DEFAULTS = {
    enabled = true,
    overlay = true,
    mode = "develop",          -- "develop" | "train"
    combo_id = nil,
    spam_block = false,
    learn_in_train = false,
    show_detail = true,
    train_view = "bar",       -- Train view: "bar" | "notes" (Spearmint Twintails) | "both" | "fix" (Strike Fixation)
    fix_pos = "center",       -- Strike Fixation lanes: "left" | "center" | "right"
    note_approach = 36,        -- note flight time in frames
    note_flip = false,
    note_palette = "classic",
    motion_arrows = true,
    song_mode = true,          -- Train: count-in, then the whole combo on a fixed timeline
    song_beat = 30,            -- count-in beat length in frames
    song_approach = 80,        -- note flight time in song mode (frames)
    song_follow = false,       -- re-time remaining notes from the hits that land  -- note colours: "classic" (red/white/blue) | "sf6" (blue/yellow/red)         -- true: kicks from the left, punches from the right
    rhythm = true,             -- Train: glowing playhead on the optimal timing
    rhythm_demo = true,        -- ...and a looping cadence preview between attempts
    ignore_spam_samples = true,
    scale = 1.0,
    y = 0.25,
    result_seconds = 4,
    user_side = 0,
    timeout = 90,
    use_hook = true,
    predict = true,            -- predict windows from the game's frame data
    auto_place = true,         -- corner combos: put both fighters in the corner between attempts
    place_spacing = 0,         -- extra distance between the fighters when placing
    research_speed = 1,        -- research bot: run the battle this many times faster (needs a passing speed test)
    speed_key = nil,           -- which speed setting to use (nil: the best one the test found)
    pred_cal = {},             -- measured-vs-predicted edge offsets, per combo step           -- false = safe mode (no game hook; restart the game after changing)
    last_cmd_seq = 0,
    keys = { mode = 0x74, next = 0x75, detail = 0x76, spam = 0x77, overlay = 0x78, bot = 0x79, view = 0x7A }, -- F5..F11
}

local cfg = {}
local function load_cfg()
    local c = json.load_file(CFG_PATH) or {}
    -- 1.13 turned motion arrows and song mode on by default; move older configs over once
    if next(c) ~= nil and (tonumber(c.defaults_rev) or 1) < 2 then
        c.motion_arrows, c.song_mode = true, true
    end
    c.defaults_rev = 2
    for k, v in pairs(DEFAULTS) do
        if c[k] == nil then c[k] = v end
    end
    if type(c.keys) ~= "table" then c.keys = DEFAULTS.keys end
    for k, v in pairs(DEFAULTS.keys) do if c.keys[k] == nil then c.keys[k] = v end end
    -- older defaults sat on top of SF6's training damage panel
    if c.y == 0.115 or c.y == 0.15 then c.y = 0.25 end
    cfg = c
end
local function save_cfg() json.dump_file(CFG_PATH, cfg, 2) end
load_cfg()
-- a short random id for this PC; tags the samples it records so profiles from
-- several machines can be merged without counting an attempt twice
if type(cfg.machine_id) ~= "string" or cfg.machine_id == "" then
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    local abc, id = "abcdefghijklmnopqrstuvwxyz0123456789", ""
    for _ = 1, 8 do local i = math.random(1, #abc); id = id .. abc:sub(i, i) end
    cfg.machine_id = id
    save_cfg()
end
Profile.MACHINE = cfg.machine_id

-- ---------------------------------------------------------------- state
local S = {
    mode = cfg.mode, cfg = cfg, combo = nil, profile = nil, version = VERSION,
    tracker = Tracker.new({ timeout = cfg.timeout }),
    last = nil, result_age = 999, stats = { n = 0, ok = 0, streak = 0, best = 0 },
    msg = nil, msg_age = 999,
}
local combos = {}           -- list of { id, name, fighter, path }
local combo_names = {}
local status_dirty = true
local in_training = false
local fighter_id, modern = nil, false
local clock_result, clock_msg = 0, 0
local last_error = nil

-- writes to re2_framework_log.txt (REFramework's log) when available
local function L(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    msg = "[ComboLab] " .. (ok and msg or tostring(fmt))
    if log and log.info then pcall(log.info, msg) end
end

local function flash(m)
    S.msg = m
    clock_msg = os.clock()
    L("%s", m)
end

-- json.load_file logs an error for files that don't exist yet; check first
local function exists(dir, name)
    -- fs.glob takes a regex; ids are [a-z0-9-] so only the dot needs escaping
    local pat = "ComboLab\\\\" .. dir .. "\\\\" .. (name:gsub("%.", "\\.")) .. "$"
    local ok, files = pcall(fs.glob, pat)
    if not ok or type(files) ~= "table" then return true end
    return #files > 0
end

local function int(v) return math.tointeger(tonumber(v) or 0) or 0 end

-- ---------------------------------------------------------------- combos
local function normalize_combo(c)
    if type(c) ~= "table" or type(c.steps) ~= "table" or #c.steps == 0 then return nil end
    c.id = tostring(c.id or "")
    if c.id == "" then return nil end
    c.hash = tostring(c.hash or c.version or "0")
    for k, st in ipairs(c.steps) do
        st.label = tostring(st.label or ("step " .. k))
        st.kind = (st.kind == "move") and "move" or "hit"
        st.sep = st.sep or (k == 1 and "start" or ">")
        local tr = type(st.trigger) == "table" and st.trigger or {}
        tr.type = tr.type or "button"
        tr.mask = int(tr.mask)
        tr.mode = tr.mode or "all"
        st.trigger = tr
    end
    c.fighter_id = c.fighter_id and int(c.fighter_id) or nil
    return c
end

local function scan_combos()
    combos, combo_names = {}, {}
    local ok, files = pcall(fs.glob, [[ComboLab\\combos\\.*\.json]])
    if not ok or type(files) ~= "table" then return end
    for _, path in ipairs(files) do
        local c = normalize_combo(json.load_file(path))
        if c then
            combos[#combos + 1] = { id = c.id, name = c.name or c.id, fighter = c.fighter or "", fighter_id = c.fighter_id, path = path }
        end
    end
    table.sort(combos, function(a, b)
        if a.fighter ~= b.fighter then return a.fighter < b.fighter end
        return a.name < b.name
    end)
    for i, c in ipairs(combos) do
        combo_names[i] = (c.fighter ~= "" and (c.fighter .. ": ") or "") .. c.name
    end
end

local place = { idle = 0, done = false }    -- fighter placement state (see placement_tick)
local facts_wanted = false                   -- read frame data for the loaded combo (see refresh_facts)

local function profile_path(id) return DIR .. "profiles\\" .. id .. ".json" end
local function session_path(id) return DIR .. "sessions\\" .. id .. ".json" end

local function save_profile()
    if S.profile and S.combo then
        S.profile.ignore_spam = cfg.ignore_spam_samples
        json.dump_file(profile_path(S.combo.id), S.profile:to_table())
    end
end

local session = nil
local function load_session(id)
    local t = exists("sessions", id .. ".json") and json.load_file(session_path(id)) or nil
    if type(t) ~= "table" or type(t.attempts) ~= "table" then t = { combo_id = id, attempts = {} } end
    session = t
    -- train stats for today's run start fresh; history stays in the file
    S.stats = { n = 0, ok = 0, streak = 0, best = 0 }
end

local function load_combo(id)
    for _, e in ipairs(combos) do
        if e.id == id then
            local c = normalize_combo(json.load_file(e.path))
            if not c then flash("ComboLab: could not read " .. e.path) return false end
            local raw = exists("profiles", c.id .. ".json") and json.load_file(profile_path(c.id)) or nil
            local prof, reset = Profile.from_table(raw, c)
            prof.ignore_spam = cfg.ignore_spam_samples
            S.combo, S.profile = c, prof
            S.tracker:set_combo(c, prof)
            S.last = nil
            load_session(c.id)
            facts_wanted = true
            place.done, place.idle = false, 0
            cfg.combo_id = c.id
            save_cfg()
            if reset then flash("Combo changed since its profile was recorded: profile reset")
            else flash("Loaded " .. (c.name or c.id)) end
            status_dirty = true
            return true
        end
    end
    flash("ComboLab: combo '" .. tostring(id) .. "' not found")
    return false
end

local function set_mode(m)
    if m ~= "develop" and m ~= "train" then return end
    S.mode = m
    cfg.mode = m
    S.tracker.opts.strict_ids = (m == "train")
    S.tracker.att = nil
    S.last = nil
    if m == "train" then S.stats = { n = 0, ok = 0, streak = 0, best = 0 } end
    save_cfg()
    status_dirty = true
    flash((m == "train") and "TRAIN mode" or "DEVELOP mode")
end

-- ---------------------------------------------------------------- attempts
local function compact(res)
    local steps = {}
    for k = 1, #(S.combo and S.combo.steps or {}) do
        local o = res.steps[k]
        if o then
            steps[k] = { res = o.res, p = o.p, off = o.off, q = o.q, spam = o.spam, hint = o.hint }
        else
            steps[k] = { res = "pending" }
        end
    end
    return { time = os.time(), mode = S.mode, ok = res.ok, fail_step = res.fail_step,
             result = res.result, steps = steps }
end

-- ---------------------------------------------------------------- predictions
-- Calibration: steps whose edges were pinned down by misses on both sides tell
-- us how far the frame-data prediction is off; the average shift is applied
-- to every prediction of that kind (cancel / link).
local function rebuild_cal()
    local cal = {}
    for _, e in pairs(cfg.pred_cal or {}) do
        if type(e) == "table" and e.kind then
            local c = cal[e.kind] or { dE = 0, dL = 0, n = 0 }
            c.dE, c.dL, c.n = c.dE + (e.dE or 0), c.dL + (e.dL or 0), c.n + 1
            cal[e.kind] = c
        end
    end
    Profile.CAL = cal
end
rebuild_cal()
Profile.PREDICT = cfg.predict ~= false

local function summarize(f)
    if not f then return nil end
    return { id = f.id, main = f.main, follow = f.follow, margin = f.margin, frame = f.frame, hit = f.hit }
end

local facts_done = {}     -- "combo:k" -> true once read from the game this session

local function refresh_facts()
    local P = S.profile
    if not cfg.predict or not P or not S.combo or not in_training or not fighter_id then return end
    local changed = false
    for k = 2, #S.combo.steps do
        local ida, idb = P:candidate_id(k - 1), P:candidate_id(k)
        local st = P.steps[k]
        local f = st.facts
        local key = S.combo.id .. ":" .. k
        if ida and (not facts_done[key] or not f or f.ida ~= ida or f.idb ~= idb) then
            local A = MoveData.facts(Game.user or 0, fighter_id, ida)
            if A then
                local B = idb and MoveData.facts(Game.user or 0, fighter_id, idb) or nil
                local cancel = nil
                if S.combo.steps[k].sep ~= "," and idb then cancel = MoveData.cancel_ranges(Game.user or 0, fighter_id, A, idb) end
                P:set_facts(k, { a = summarize(A), b = summarize(B), cancel = cancel, ida = ida, idb = idb, fighter = fighter_id })
                changed = true
                if idb then facts_done[key] = true end
            end
        end
    end
    if changed then save_profile(); status_dirty = true end
end

local function calibrate()
    local P = S.profile
    if not P or not S.combo then return end
    local changed = false
    for k = 2, #S.combo.steps do
        local w = P:window(k)
        if w and not w.pred and w.n >= 4 and w.E_lo == w.E - 1 and w.L_hi == w.L + 1 then
            local raw = P:prediction(k, true)
            if raw and not raw.impossible then
                local id = S.combo.id .. ":" .. tostring(S.combo.hash) .. ":" .. k
                local e = { kind = raw.kind, dE = w.E - raw.E, dL = w.L - raw.L }
                local old = cfg.pred_cal[id]
                if not old or old.dE ~= e.dE or old.dL ~= e.dL then cfg.pred_cal[id] = e; changed = true end
            end
        end
    end
    if changed then rebuild_cal(); P._win = {}; save_cfg() end
end

local function on_attempt(res)
    local P = S.profile
    if not P then return end
    -- the bot's jump-in probes (measuring the jump, finding the spacing) press
    -- things the combo doesn't: nothing from them is learned or recorded
    local cur = S.bot and S.bot.running and S.bot.cur
    if cur and (cur.phase == "M" or cur.phase == "J") then return end
    local botting = S.bot and S.bot.running
    P:grade(res, { spam_block = (not botting) and (S.mode == "train") and cfg.spam_block })
    if botting then
        P:learn(res, "bot")
    elseif S.mode == "develop" then
        P:learn(res, "develop")
    elseif cfg.learn_in_train then
        P:learn(res, "train")
    else
        P:count(res)
    end
    S.last = res
    S.attempt_seq = (S.attempt_seq or 0) + 1
    clock_result = os.clock()
    if S.mode == "train" then
        local st = S.stats
        st.n = st.n + 1
        if res.ok then
            st.ok = st.ok + 1
            st.streak = st.streak + 1
            if st.streak > st.best then st.best = st.streak end
        else
            st.streak = 0
        end
    end
    pcall(refresh_facts)
    pcall(calibrate)
    save_profile()
    if session then
        local list = session.attempts
        list[#list + 1] = compact(res)
        while #list > 500 do table.remove(list, 1) end
        json.dump_file(session_path(S.combo.id), session)
    end
    status_dirty = true
    if botting then S.bot:on_result(res) end
end

Game.on_sample = function(s)
    local ev = S.tracker:push(s)
    if ev and ev.type == "attempt" then on_attempt(ev.result) end
end

-- ---------------------------------------------------------------- training bot
S.bot = Bot.new({
    load = function(id)
        scan_combos()
        if S.mode ~= "develop" then set_mode("develop") end
        if load_combo(id) then return S.combo, S.profile end
        return nil
    end,
    reset_profile = function()
        if S.profile then
            S.profile:reset()
            S.tracker:set_combo(S.combo, S.profile)
            S.last = nil
            save_profile()
        end
    end,
    tracker = S.tracker,
    teleport = function(ux, dx) return Game.teleport(ux, dx) end,
    tp_status = function() return Game.pending_tp ~= nil, Game.tp_result end,
    edge = Game.STAGE_EDGE,
    fighter_id = function() return fighter_id end,
    report = function(id, r) json.dump_file(DIR .. "bot\\" .. id .. ".json", r) end,
    log = function(m) flash(m) end,
    trace = function(m) L("bot: %s", m) end,
})
Game.injector = function(t) return S.bot:frame_mask(t) end
Game.observer = function(smp) S.bot:observe(smp) end

local function speed_up_for_bot(opts)
    local mult = tonumber(opts and opts.speed) or tonumber(cfg.research_speed) or 1
    if mult <= 1.001 then return end
    local key = cfg.speed_key or Speed.best()
    if not key then flash("Research speed: run the speed test first (bot runs at normal speed)") return end
    local ok, why = Speed.apply(key, mult)
    if ok then flash(string.format("Research speed %.1fx", mult))
    else flash("Research speed: " .. tostring(why)) end
end

local function bot_start(ids, opts)
    if not in_training then flash("Bot: go into Training mode first") return end
    if not Game.hook_ok then flash("Bot needs the game hook (turn safe mode off and restart)") return end
    if type(ids) ~= "table" or #ids == 0 then flash("Bot: nothing to profile") return end
    if Speed.test then flash("Bot: wait for the speed test to finish") return end
    S.bot:start(ids, opts or {})
    if S.bot.running then speed_up_for_bot(opts) end
    status_dirty = true
end

local function bot_ids_for_fighter()
    local ids = {}
    for _, c in ipairs(combos) do
        if fighter_id and c.fighter_id == fighter_id then ids[#ids + 1] = c.id end
    end
    return ids
end

-- ---------------------------------------------------------------- bridge
local last_poll, last_status = 0, 0

local function apply_options(o)
    if type(o) ~= "table" then return end
    for _, k in ipairs({ "spam_block", "learn_in_train", "show_detail", "ignore_spam_samples", "overlay", "enabled", "rhythm", "rhythm_demo", "motion_arrows", "predict", "auto_place" }) do
        if o[k] ~= nil then cfg[k] = o[k] == true end
    end
    Profile.PREDICT = cfg.predict ~= false
    if S.profile then S.profile._win = {} end
    if o.train_view == "bar" or o.train_view == "notes" or o.train_view == "both" or o.train_view == "fix" then cfg.train_view = o.train_view end
    if o.fix_pos == "left" or o.fix_pos == "center" or o.fix_pos == "right" then cfg.fix_pos = o.fix_pos end
    if o.note_flip ~= nil then cfg.note_flip = o.note_flip == true end
    if o.song_mode ~= nil then cfg.song_mode = o.song_mode == true; S.song = nil end
    if o.song_follow ~= nil then cfg.song_follow = o.song_follow == true end
    if tonumber(o.song_approach) then cfg.song_approach = math.max(30, math.min(180, math.floor(tonumber(o.song_approach)))) end
    if tonumber(o.song_beat) then cfg.song_beat = math.max(12, math.min(90, math.floor(tonumber(o.song_beat)))) end
    if o.note_palette == "classic" or o.note_palette == "sf6" then cfg.note_palette = o.note_palette end
    if tonumber(o.note_approach) then cfg.note_approach = math.max(12, math.min(90, math.floor(tonumber(o.note_approach)))) end
    if tonumber(o.place_spacing) then cfg.place_spacing = math.max(0, math.min(200, tonumber(o.place_spacing))) end
    for _, k in ipairs({ "scale", "y", "result_seconds", "timeout" }) do
        if tonumber(o[k]) then cfg[k] = tonumber(o[k]) end
    end
    if cfg.y == 0.115 or cfg.y == 0.15 then cfg.y = 0.25 end -- old page defaults
    if o.user_side ~= nil then cfg.user_side = int(o.user_side) == 1 and 1 or 0 end
    S.tracker.opts.timeout = cfg.timeout
    if S.profile then S.profile.ignore_spam = cfg.ignore_spam_samples; S.profile._win = {} end
    save_cfg()
end

local function handle_command(c)
    local cmd = c.cmd
    L("command: %s%s", tostring(cmd), c.combo_id and (" " .. tostring(c.combo_id)) or (c.ids and (" (" .. #c.ids .. " combos)") or ""))
    if cmd == "load" then
        scan_combos()
        if c.mode then set_mode(c.mode) end
        if c.options then apply_options(c.options) end
        if c.combo_id then load_combo(c.combo_id) end
    elseif cmd == "mode" then
        set_mode(c.mode)
    elseif cmd == "options" then
        apply_options(c.options)
    elseif cmd == "reset_profile" then
        if S.profile and (not c.combo_id or c.combo_id == S.combo.id) then
            S.profile:reset()
            S.tracker:set_combo(S.combo, S.profile)
            S.last = nil
            save_profile()
            flash("Profile reset")
        elseif c.combo_id then
            json.dump_file(profile_path(c.combo_id), { reset = true, reset_at = os.time(), combo_id = c.combo_id })
        end
    elseif cmd == "reset_stats" then
        S.stats = { n = 0, ok = 0, streak = 0, best = 0 }
        -- keep_history: only today's numbers start over (the page's "Reset today")
        if S.combo and not c.keep_history then session = { combo_id = S.combo.id, attempts = {} }; json.dump_file(session_path(S.combo.id), session) end
    elseif cmd == "bot_start" then
        scan_combos()
        local ids = c.ids
        if c.all_for_fighter then ids = bot_ids_for_fighter() end
        bot_start(ids, c.options)
    elseif cmd == "bot_stop" then
        S.bot:stop("stopped from the web page")
    elseif cmd == "speed_test" then
        if not in_training or not Game.hook_ok or not S.combo or not cfg.enabled then flash("Speed test: go into Training mode with a combo loaded first")
        elseif S.bot.running then flash("Speed test: stop the bot first")
        else
            Speed.start_test(function() return Game.hook_ticks end, tonumber(c.mult) or 2)
            flash("Testing research speed: hands off for ~15 s")
        end
    elseif cmd == "speed_scan" then
        if not Speed.watch_core() then
            -- first scan: catch the battle core on the next frame, then scan
            S.scan_pending = os.clock()
            flash("Speed scan: looking for the battle core...")
            return
        end
        local ok, done, info = pcall(Speed.scan, DIR .. "speed_scan.json")
        if ok and done then flash(string.format("Speed scan: %d values listed in reframework/data/ComboLab/speed_scan.json", info or 0))
        else flash("Speed scan failed: " .. tostring(ok and info or done)) end
    elseif cmd == "speed_probe" then
        if not in_training or S.bot.running or Speed.test then flash("Speed probe: Training mode, bot stopped")
        else
            local ok, why = Speed.start_probe(DIR .. "speed_probe.json")
            flash(ok and "Speed probe: hands off for ~3 s (the game may stutter)" or ("Speed probe: " .. tostring(why)))
        end
    elseif cmd == "speed_settings" then
        if tonumber(c.research_speed) then cfg.research_speed = math.max(1, math.min(8, tonumber(c.research_speed))) end
        if c.speed_key ~= nil then cfg.speed_key = (c.speed_key ~= "" and c.speed_key ~= false) and tostring(c.speed_key) or nil end
        save_cfg()
    elseif cmd == "place" then
        place_fighters(c.position == "mid" and "mid" or "corner")
    elseif cmd == "rescan" then
        scan_combos()
        if S.combo then load_combo(S.combo.id) end
    end
    status_dirty = true
end

local function poll_commands()
    local c = json.load_file(DIR .. "command.json")
    if type(c) ~= "table" or c.seq == nil then return end
    local seq = tonumber(c.seq) or 0
    if seq == cfg.last_cmd_seq then return end
    cfg.last_cmd_seq = seq
    save_cfg()
    local ok, err = pcall(handle_command, c)
    if not ok then last_error = tostring(err) end
end

local function write_status()
    local st = {
        version = VERSION,
        time = os.time(),
        mode = S.mode,
        combo_id = S.combo and S.combo.id or nil,
        in_training = in_training,
        tick_source = Game.source,
        hook_ok = Game.hook_ok,
        fighter_id = fighter_id, opp_fighter_id = Profile.OPP,
        modern = modern,
        attempts = S.profile and S.profile.attempts or 0,
        successes = S.profile and S.profile.successes or 0,
        stats = S.stats,
        last = S.last and compact(S.last) or nil,
        options = {
            spam_block = cfg.spam_block, learn_in_train = cfg.learn_in_train, show_detail = cfg.show_detail,
            ignore_spam_samples = cfg.ignore_spam_samples, scale = cfg.scale, y = cfg.y,
            user_side = cfg.user_side, overlay = cfg.overlay, enabled = cfg.enabled,
            rhythm = cfg.rhythm, rhythm_demo = cfg.rhythm_demo,
            train_view = cfg.train_view, note_approach = cfg.note_approach, note_flip = cfg.note_flip, note_palette = cfg.note_palette, fix_pos = cfg.fix_pos,
            motion_arrows = cfg.motion_arrows, predict = cfg.predict, auto_place = cfg.auto_place, place_spacing = cfg.place_spacing,
            song_mode = cfg.song_mode, song_follow = cfg.song_follow, song_approach = cfg.song_approach, song_beat = cfg.song_beat,
        },
        bot = S.bot:status(),
        speed = (function() local t = Speed.status(); t.research_speed = cfg.research_speed; t.speed_key = cfg.speed_key; return t end)(),
        error = last_error or Game.last_error,
    }
    json.dump_file(DIR .. "status.json", st, 2)
end

-- ---------------------------------------------------------------- hotkeys
local key_prev = {}
local function pressed(vk)
    local ok, down = pcall(reframework.is_key_down, reframework, vk)
    down = ok and down or false
    local was = key_prev[vk]
    key_prev[vk] = down
    return down and not was
end

local function cycle_combo(dir)
    if #combos == 0 then return end
    local idx = 0
    for i, c in ipairs(combos) do if S.combo and c.id == S.combo.id then idx = i end end
    idx = ((idx - 1 + dir) % #combos) + 1
    load_combo(combos[idx].id)
end

local function do_hotkeys()
    local k = cfg.keys
    if pressed(k.mode) then set_mode(S.mode == "develop" and "train" or "develop") end
    if pressed(k.next) then cycle_combo(1) end
    if pressed(k.detail) then cfg.show_detail = not cfg.show_detail; save_cfg() end
    if pressed(k.spam) then
        cfg.spam_block = not cfg.spam_block; save_cfg()
        flash(cfg.spam_block and "Spam blocker ON" or "Spam blocker OFF")
    end
    if pressed(k.overlay) then cfg.overlay = not cfg.overlay; save_cfg() end
    if k.view and pressed(k.view) then
        local order = { bar = "notes", notes = "both", both = "fix", fix = "bar" }
        cfg.train_view = order[cfg.train_view or "bar"] or "bar"; save_cfg()
        flash("Train view: " .. ({ bar = "bar", notes = "Spearmint Twintails", both = "bar + notes", fix = "Strike Fixation" })[cfg.train_view])
    end
    if k.bot and pressed(k.bot) then
        if S.bot.running then S.bot:stop("stopped with F10")
        elseif S.combo then bot_start({ S.combo.id }, {}) end
    end
end

-- ---------------------------------------------------------------- frame
-- ---------------------------------------------------------------- hub sync
-- The sync agent (combolab_sync.py, run by combolab_server.py) writes merged
-- profiles from the hub to shared/<id>.json and lists them with a revision in
-- shared/_status.json. The mod stays the only writer of profiles/: it merges
-- those samples in here, a few combos per check.
local sync = { last = 0, combos_rev = nil, pending = {}, done = {} }
local function shared_path(id) return DIR .. "shared\\" .. id .. ".json" end

-- returns true when done, false to retry soon, nil when the combo isn't known
-- here yet (the agent may still be bringing it over)
local function merge_shared(id, rev)
    local loaded = S.combo and S.combo.id == id
    local entry
    if not loaded then
        for _, e in ipairs(combos) do if e.id == id then entry = e end end
        if not entry then return nil end
    end
    if loaded then
        -- don't change the windows under a running attempt or the bot (and
        -- don't read the file yet: it can be big, and this runs every 5 s)
        if S.bot.running or S.tracker.att then return false end
        if S.profile.shared_rev == rev then return true end
    end
    local sh = json.load_file(shared_path(id))
    if type(sh) ~= "table" then return not exists("shared", id .. ".json") end
    if loaded then
        local n = S.profile:merge(sh)
        S.profile.shared_rev = rev
        save_profile()
        if n > 0 then flash(string.format("Hub: merged %d samples from other machines", n)); status_dirty = true end
        return true
    end
    local c = normalize_combo(json.load_file(entry.path))
    if not c or c.hash ~= sh.combo_hash then return true end
    local raw = exists("profiles", id .. ".json") and json.load_file(profile_path(id)) or nil
    local prof = Profile.from_table(raw, c)
    if prof.shared_rev == rev then return true end
    local n = prof:merge(sh)
    prof.shared_rev = rev
    prof.ignore_spam = cfg.ignore_spam_samples
    json.dump_file(profile_path(id), prof:to_table())
    if n > 0 then L("hub: merged %d samples into %s", n, id) end
    return true
end

local function sync_tick()
    -- read straight away: a missing file just gives nil (fs.glob walks the whole data folder)
    local st = json.load_file(DIR .. "shared\\_status.json")
    if type(st) ~= "table" then return end
    if st.combos_rev ~= nil and st.combos_rev ~= sync.combos_rev then
        if sync.combos_rev ~= nil then scan_combos(); status_dirty = true end
        sync.combos_rev = st.combos_rev
    end
    if type(st.shared) == "table" then
        for id, rev in pairs(st.shared) do
            if sync.done[id] ~= rev then sync.pending[id] = rev end
        end
    end
    local budget = 3
    for id, rev in pairs(sync.pending) do
        if budget <= 0 then break end
        budget = budget - 1
        local ok, res = pcall(merge_shared, id, rev)
        if ok and res then sync.pending[id] = nil; sync.done[id] = rev
        elseif ok and res == nil then sync.pending[id] = nil      -- looked at again next check
        elseif not ok then last_error = "hub merge: " .. tostring(res); sync.pending[id] = nil; sync.done[id] = rev end
    end
end

-- ---------------------------------------------------------------- placement
-- Corner combos (name says "corner"): put both fighters in the corner when the
-- combo loads and again between attempts, once you've been idle for a moment.
-- The corner is the one you're facing, so it works from either side.
local function wants_corner(c)
    return c and ((tostring(c.name or "") .. " " .. tostring(c.id or "")):lower():find("corner")) ~= nil
end

local function place_fighters(pos)
    local edge = Game.STAGE_EDGE
    local dist = 30 + (tonumber(cfg.place_spacing) or 0)
    local ux, dx
    if pos == "corner" then dx = edge - 1; ux = dx - dist else ux, dx = -dist / 2, dist / 2 end
    local d = Game.diag
    if d and d.u and d.o and d.u.x and d.o.x and d.u.x > d.o.x then ux, dx = -ux, -dx end
    return Game.teleport(ux, dx), ux, dx
end

local function placement_tick()
    if not cfg.auto_place or S.bot.running or not in_training or not wants_corner(S.combo) then return end
    if S.tracker.att then place.idle, place.done = 0, false return end
    local d = Game.diag
    if not d or not d.u or not d.o then return end
    if (d.u.held or 0) == 0 and (d.u.dir or 5) == 5 and (d.o.stun or 0) == 0 and (d.o.hitstop or 0) == 0 then
        place.idle = place.idle + 1
    else
        place.idle = 0
    end
    if place.idle >= 45 and not place.done then
        place.done = true
        local edge = Game.STAGE_EDGE
        local dist = 30 + (tonumber(cfg.place_spacing) or 0)
        local in_corner = math.abs(math.abs(d.o.x or 0) - (edge - 1)) < 8 and math.abs(math.abs((d.u.x or 0) - (d.o.x or 0)) - dist) < 8
        if not in_corner then place_fighters("corner") end
    end
end

Speed.log = function(m) L("speed: %s", m) end
if type(cfg.speed_results) == "table" then Speed.results = cfg.speed_results; Speed.base_fps = cfg.speed_base end
local training_check = 0
scan_combos()
if cfg.combo_id then load_combo(cfg.combo_id) end
S.tracker.opts.strict_ids = (S.mode == "train")
S.msg = nil

re.on_frame(function()
    local now = os.clock()
    training_check = training_check - 1
    if training_check <= 0 then
        training_check = 60
        in_training = Game.in_training()
        if in_training then
            Game.user = cfg.user_side or 0
            local info = Game.side_info(Game.user)
            if info.fighter_id and info.fighter_id ~= fighter_id then
                fighter_id = info.fighter_id
                MoveData.clear()
                facts_done = {}
                facts_wanted = true
                S.tracker:reset_learning()
                status_dirty = true
            end
            modern = info.modern or false
            -- the dummy's character goes on every sample (combos can depend on it)
            local opp = Game.side_info(1 - Game.user).fighter_id
            if opp ~= Profile.OPP then Profile.OPP = opp; status_dirty = true end
        end
    end
    if S.bot.running and not in_training then S.bot:stop("left Training mode") end
    if Speed.probe then
        if not in_training then Speed.probe = nil; Speed.restore() else Speed.update_probe() end
        status_dirty = true
        if not Speed.probe and Speed.last_probe then flash(string.format("Speed probe: %d fields follow the game speed (speed_probe.json)", Speed.last_probe.hits)) end
    end
    if S.scan_pending and (Speed.core or os.clock() - S.scan_pending > 2) then
        S.scan_pending = nil
        handle_command({ cmd = "speed_scan" })
    end
    -- research speed: test runs, and never stays on without the bot
    Speed.sample(Game.hook_ticks)
    if Speed.test then
        if not in_training or Game.paused() then Speed.test = nil; Speed.restore(); Speed.error = "test stopped (left Training or paused)" end
        Speed.update()
        status_dirty = true
        if not Speed.test then
            -- remember what worked, across restarts
            cfg.speed_results, cfg.speed_base = Speed.results, Speed.base_fps
            save_cfg()
            local b = Speed.best()
            flash(b and string.format("Speed test: %.1fx works (%s)", Speed.results[b].ratio, b) or ("Speed test: " .. (Speed.error or "no setting gave extra frames")))
        end
    elseif Speed.active and not S.bot.running and not Speed.probe then
        Speed.restore()
    end
    if S.bot.running and Game.source ~= "hook" and Game.tick > 0 and Game.source ~= "none" then
        S.bot:stop("the game hook isn't running")
    end
    Game.enabled = (cfg.enabled or S.bot.running) and in_training and S.combo ~= nil
    Game.render_tick()
    Game.drain()
    if S.bot.running then
        local ok, err = pcall(S.bot.update, S.bot)
        if not ok then last_error = "bot: " .. tostring(err); S.bot:stop("error: " .. tostring(err)) end
        status_dirty = true
    end
    S.bot_status = S.bot.running and S.bot:status() or nil

    do_hotkeys()

    if now - last_poll > 0.5 then
        last_poll = now
        local ok, err = pcall(poll_commands)
        if not ok then last_error = tostring(err) end
    end
    Game.teleport_tick()
    pcall(placement_tick)
    if facts_wanted and in_training and fighter_id and S.profile then
        facts_wanted = false
        local ok, err = pcall(refresh_facts)
        if not ok then last_error = "frame data: " .. tostring(err) end
    end
    if now - sync.last > 5 then
        sync.last = now
        local ok, err = pcall(sync_tick)
        if not ok then last_error = "hub sync: " .. tostring(err) end
    end
    if (status_dirty and now - last_status > 0.5) or now - last_status > 3 then
        last_status = now
        status_dirty = false
        pcall(write_status)
    end

    S.tick_clock = Game.tick_clock
    S.result_age = now - clock_result
    S.msg_age = now - clock_msg
    if cfg.enabled and cfg.overlay and in_training and not Game.paused() then
        local ok, err = pcall(Overlay.draw, S)
        if not ok then last_error = "overlay: " .. tostring(err) end
    end
end)

-- ---------------------------------------------------------------- menu
local MODES = { "Develop", "Train" }

re.on_draw_ui(function()
    if not imgui.tree_node("ComboLab " .. VERSION) then return end
    local changed, v
    changed, v = imgui.checkbox("Enabled", cfg.enabled); if changed then cfg.enabled = v; save_cfg() end
    imgui.same_line()
    changed, v = imgui.checkbox("Overlay (F9)", cfg.overlay); if changed then cfg.overlay = v; save_cfg() end

    changed, v = imgui.combo("Mode (F5)", S.mode == "train" and 2 or 1, MODES)
    if changed then set_mode(v == 2 and "train" or "develop") end

    local idx = 0
    for i, c in ipairs(combos) do if S.combo and c.id == S.combo.id then idx = i end end
    changed, v = imgui.combo("Combo (F6)", idx, combo_names)
    if changed and combos[v] then load_combo(combos[v].id) end
    if imgui.button("Rescan combos") then scan_combos() end
    imgui.same_line()
    if imgui.button("Reset profile") and S.profile then
        S.profile:reset(); S.tracker:set_combo(S.combo, S.profile); S.last = nil; save_profile()
    end
    imgui.same_line()
    if imgui.button("Reset train stats") then handle_command({ cmd = "reset_stats" }) end

    changed, v = imgui.checkbox("Spam blocker (Train, F8)", cfg.spam_block); if changed then cfg.spam_block = v; save_cfg() end
    local VIEWS = { "Bar", "Spearmint Twintails (notes)", "Bar + notes", "Strike Fixation (lanes)" }
    local VKEY = { "bar", "notes", "both", "fix" }
    local vi = 1
    for i, kk in ipairs(VKEY) do if cfg.train_view == kk then vi = i end end
    changed, v = imgui.combo("Train view (F11)", vi, VIEWS)
    if changed then cfg.train_view = VKEY[v]; save_cfg() end
    local PKEY = { "left", "center", "right" }
    local pi = 2
    for i, kk in ipairs(PKEY) do if cfg.fix_pos == kk then pi = i end end
    changed, v = imgui.combo("Strike Fixation lanes", pi, { "Left", "Centre", "Right" })
    if changed then cfg.fix_pos = PKEY[v]; save_cfg() end
    changed, v = imgui.slider_int and imgui.slider_int("Note flight (frames)", cfg.note_approach or 36, 18, 72)
    if changed then cfg.note_approach = v; save_cfg() end
    changed, v = imgui.combo("Note colours", cfg.note_palette == "sf6" and 2 or 1, { "Classic (red / white / blue)", "SF6 (blue / yellow / red)" })
    if changed then cfg.note_palette = (v == 2) and "sf6" or "classic"; save_cfg() end
    changed, v = imgui.checkbox("Motion arrows instead of numbers (623 -> Z arrow)", cfg.motion_arrows == true)
    if changed then cfg.motion_arrows = v; save_cfg() end
    changed, v = imgui.checkbox("Song mode (count-in, fixed timeline)", cfg.song_mode == true)
    if changed then cfg.song_mode = v; S.song = nil; save_cfg() end
    imgui.same_line()
    changed, v = imgui.checkbox("Follow my hits", cfg.song_follow == true)
    if changed then cfg.song_follow = v; save_cfg() end
    if imgui.slider_int then
        changed, v = imgui.slider_int("Song note flight (frames)", cfg.song_approach or 80, 40, 150)
        if changed then cfg.song_approach = v; save_cfg() end
        changed, v = imgui.slider_int("Count-in beat (frames)", cfg.song_beat or 30, 15, 60)
        if changed then cfg.song_beat = v; save_cfg() end
    end
    changed, v = imgui.checkbox("Notes: kicks from the left, punches from the right", cfg.note_flip == true)
    if changed then cfg.note_flip = v; save_cfg() end
    changed, v = imgui.checkbox("Safe mode: no game hook (restart game to apply)", cfg.use_hook == false)
    if changed then cfg.use_hook = not v; save_cfg() end
    changed, v = imgui.checkbox("Corner combos: put both fighters in the corner between attempts", cfg.auto_place ~= false)
    if changed then cfg.auto_place = v; place.done = false; save_cfg() end
    if imgui.button("Place fighters in the corner now") then place_fighters("corner") end
    imgui.same_line()
    if imgui.button("Midscreen now") then place_fighters("mid") end
    if Game.tp_result and Game.tp_result ~= "ok" then imgui.text("last placement: " .. Game.tp_result) end
    if imgui.slider_int then
        changed, v = imgui.slider_int("Placement spacing", math.floor(tonumber(cfg.place_spacing) or 0), 0, 200)
        if changed then cfg.place_spacing = v; save_cfg() end
    end
    changed, v = imgui.checkbox("Predict windows from game frame data", cfg.predict ~= false)
    if changed then cfg.predict = v; Profile.PREDICT = v; save_cfg(); if S.profile then S.profile._win = {} end end
    changed, v = imgui.checkbox("Rhythm guide (Train)", cfg.rhythm ~= false); if changed then cfg.rhythm = v; save_cfg() end
    imgui.same_line()
    changed, v = imgui.checkbox("Cadence preview between attempts", cfg.rhythm_demo ~= false); if changed then cfg.rhythm_demo = v; save_cfg() end
    changed, v = imgui.checkbox("Keep learning in Train", cfg.learn_in_train); if changed then cfg.learn_in_train = v; save_cfg() end
    changed, v = imgui.checkbox("Detail table (F7)", cfg.show_detail); if changed then cfg.show_detail = v; save_cfg() end
    changed, v = imgui.checkbox("Ignore spammed samples in windows", cfg.ignore_spam_samples)
    if changed then apply_options({ ignore_spam_samples = v }) end
    changed, v = imgui.checkbox("I'm on the 2P side", cfg.user_side == 1)
    if changed then cfg.user_side = v and 1 or 0; Game.user = cfg.user_side; S.tracker:reset_learning(); save_cfg() end
    changed, v = imgui.slider_float("Overlay scale", cfg.scale, 0.5, 2.0); if changed then cfg.scale = v; save_cfg() end
    changed, v = imgui.slider_float("Overlay height", cfg.y, 0.02, 0.9); if changed then cfg.y = v; save_cfg() end

    if imgui.tree_node("Research bot") then
        if S.bot.running then
            local b = S.bot:status()
            imgui.text(string.format("combo %d/%d: %s", b.queue_pos, b.queue_len, tostring(b.combo_name)))
            imgui.text(string.format("phase %s  step %s (%s)  offset %s  attempts %d",
                tostring(b.phase), tostring(b.step), tostring(b.step_label), tostring(b.d), b.attempts))
            if imgui.button("Stop bot (F10)") then S.bot:stop("stopped from the menu") end
        else
            if imgui.button("Profile this combo (F10)") and S.combo then bot_start({ S.combo.id }, {}) end
            imgui.same_line()
            if imgui.button("Profile all combos for this character") then bot_start(bot_ids_for_fighter(), {}) end
            if S.bot.stop_reason then imgui.text("last run: " .. tostring(S.bot.stop_reason)) end
        end
        imgui.text("Set dummy to no guard, gauges to infinite/refill. Hands off the controller while it runs.")
        imgui.tree_pop()
    end
    if imgui.tree_node("Research speed") then
        imgui.text("Runs the battle faster while the research bot works (frames are counted, so windows stay exact).")
        if Speed.test then imgui.text("Testing... hands off")
        elseif imgui.button("Test speed settings (about 15 s, Training mode)") then
            handle_command({ cmd = "speed_test", mult = 2 })
        end
        local st = Speed.status()
        if st.base_fps then imgui.text(string.format("normal: %.1f frames/s", st.base_fps)) end
        for key, r in pairs(Speed.results or {}) do
            imgui.text(string.format("  %s: %s", key, type(r) == "table" and (r.note or "") or "?"))
        end
        if st.error then imgui.text_colored(st.error, 0xFF5555FF) end
        if imgui.button("Scan the game for speed settings (freezes a few seconds)") then handle_command({ cmd = "speed_scan" }) end
        if imgui.button("Probe what Game Speed changes (100% / 150% / 100%)") then handle_command({ cmd = "speed_probe" }) end
        local ch, v = imgui.slider_float("Research speed (x)", cfg.research_speed or 1, 1, 1.5)
        if ch then cfg.research_speed = math.floor(v * 10 + 0.5) / 10; save_cfg() end
        if st.fps then imgui.text(string.format("battle now: %.1f frames/s%s", st.fps, Speed.active and string.format("  (%.2gx on)", Speed.active.mult) or "")) end
        imgui.tree_pop()
    end
    if imgui.tree_node("Diagnostics") then
        imgui.text(string.format("in training: %s   tick source: %s   hook: %s   tick: %d",
            tostring(in_training), Game.source, tostring(Game.hook_ok), Game.tick))
        imgui.text(string.format("fighter id: %s   modern: %s   overlay fonts: %s", tostring(fighter_id), tostring(modern), tostring(Overlay.fonts_ok)))
        local d = Game.diag
        if d and d.u then
            imgui.text(string.format("you: act %s  frame %.1f  margin %.1f  held 0x%X  dir %d  combo %d",
                tostring(d.u.act), d.u.af or 0, d.u.margin or 0, d.u.held or 0, d.u.dir or 5, d.cc or 0))
            imgui.text(string.format("opponent: hitstun %d  hitstop %d  blockstun %d",
                d.o.stun or 0, d.o.hitstop or 0, d.o.guard or 0))
        end
        local n = 0
        for _ in pairs(S.tracker.neutral) do n = n + 1 end
        imgui.text("neutral actions learned: " .. n)
        if S.combo and S.profile then
            for k, st in ipairs(S.combo.steps) do
                imgui.text(string.format("  %d %-8s id %s  mask 0x%X %s", k, st.label,
                    tostring(S.profile:learned_id(k)), st.trigger.mask or 0, st.kind))
                local f = S.profile.steps[k].facts
                if f and f.a then
                    local A = f.a
                    local adv = Predict.advantage(A, S.profile.sit)
                    local w = S.profile:window(k)
                    local cr = {}
                    for _, r in ipairs(f.cancel or {}) do cr[#cr + 1] = r.s .. "-" .. (r.e - 1) end
                    imgui.text(string.format("      prev move %s: startup %s  recovers %s  hitstun %s  hitstop %s  adv %s%s",
                        tostring(A.id), A.main and (A.main + 1) or "-", tostring(A.margin),
                        A.hit and A.hit.stun and tostring(A.hit.stun[S.profile.sit] or A.hit.stun.st) or "-",
                        A.hit and tostring(A.hit.stop_o) or "-", adv and string.format("%+d", adv) or "-",
                        #cr > 0 and ("  cancel " .. table.concat(cr, ",")) or ""))
                    if w then
                        imgui.text(string.format("      predicted %s..%s (%s)   measured %s",
                            tostring(w.pred_E), tostring(w.pred_L), tostring(w.pred_kind),
                            w.pred and "none yet" or string.format("%d..%d", w.E, w.L)))
                    end
                end
            end
            if imgui.button("Re-read frame data") then MoveData.clear(); facts_done = {}; pcall(refresh_facts) end
            if MoveData.last_error then imgui.text("frame data: " .. tostring(MoveData.last_error)) end
        end
        if last_error or Game.last_error then imgui.text_colored("error: " .. tostring(last_error or Game.last_error), 0xFF4040FF) end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)
