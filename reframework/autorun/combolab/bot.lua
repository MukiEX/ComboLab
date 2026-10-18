-- ComboLab training bot: plays a combo by itself in Training mode, sweeping each
-- step's press timing frame by frame, so the normal tracker/profile machinery
-- records exact windows and sweet spots. Pure Lua: the game side is reached only
-- through the `env` table given to Bot.new (see ComboLab.lua and tests/bot_test.lua).
--
-- Timing model (same as the tracker): step k is pressed d frames after step k-1's
-- action STARTED. The bot watches action starts on the same frame (observe) and
-- schedules the next step's inputs relative to it.

local Bot = {}
Bot.__index = Bot

local CB = { LP = 16, MP = 32, HP = 64, LK = 128, MK = 256, HK = 512 }
local MPMK, HPHK, LPLK = 32 | 256, 64 | 512, 16 | 128

-- Super motions. Most of the cast uses these; per-fighter overrides below.
-- Writing the motion out in the notation (e.g. 236236K) always wins.
local SA_DEFAULT = { SA1 = "236236P", SA2 = "214214P", SA3 = "236236K", CA = "236236K", LVL1 = "236236P", LVL2 = "214214P", LVL3 = "236236K" }
local SA_BY_FIGHTER = {
    [16] = { SA1 = "236236K", SA2 = "214214P", SA3 = "214214K" },   -- Juri
}

local CHARGE_FRAMES = 46

local function button_mask(tok)
    local mask, i = 0, 1
    while i <= #tok do
        local two, three = tok:sub(i, i + 1), tok:sub(i, i + 2)
        if CB[two] then mask = mask | CB[two]; i = i + 2
        elseif three == "PPP" then mask = mask | 112; i = i + 3
        elseif three == "KKK" then mask = mask | 896; i = i + 3
        elseif two == "PP" then mask = mask | 48; i = i + 2
        elseif two == "KK" then mask = mask | 384; i = i + 2
        elseif tok:sub(i, i) == "P" then mask = mask | 16; i = i + 1
        elseif tok:sub(i, i) == "K" then mask = mask | 128; i = i + 1
        else return nil end
    end
    return mask
end
Bot.button_mask = button_mask

-- Inputs for one step, relative to its press frame 0:
-- { {from, to, dir, btn}, ..., lead = frames needed before 0, charge = digit|nil }
function Bot.step_plan(st, k, prev_st, fighter_id, control)
    if control == "modern" then return nil, "Modern controls aren't supported by the bot yet" end
    local label = tostring(st.label or ""):upper():gsub("%s", "")
    local air = false
    if label:sub(1, 2) == "J." then air = true; label = label:sub(3) end
    if air and k == 1 then return nil, "starts with a jump-in (" .. st.label .. ")" end
    local sa = (SA_BY_FIGHTER[fighter_id] or {})[label] or SA_DEFAULT[label]
    if sa then label = sa end

    local plan = {}
    local function add(from, to, dir, btn) plan[#plan + 1] = { from = from, to = to, dir = dir, btn = btn or 0 } end

    if label == "DR" then
        if k == 1 or (prev_st and prev_st.kind == "move") then
            -- raw Drive Rush: Drive Parry, then 66
            add(0, 5, 5, MPMK); add(6, 7, 6, 0); add(8, 9, 5, 0); add(10, 12, 6, 0)
        else
            add(0, 1, 5, MPMK)                     -- Drive Rush cancel
        end
    elseif label == "PARRY" then add(0, 14, 5, MPMK)
    elseif label == "66" then add(-4, -3, 6, 0); add(-2, -1, 5, 0); add(0, 2, 6, 0)
    elseif label == "DI" then add(0, 1, 5, HPHK)
    elseif label == "THROW" then add(0, 1, 5, LPLK)
    elseif label == "7" or label == "8" or label == "9" then add(0, 2, tonumber(label), 0)
    else
        local charge = nil
        local c = label:match("^%[(%d)%]")
        if c then charge = tonumber(c); label = label:sub(4) end
        local dirs, rest = label:match("^(%d*)(.*)$")
        local held = false
        local hb = rest:match("^%[(%u+)%]$")
        if hb then rest = hb; held = true end
        local mask = button_mask(rest)
        if not mask or mask == 0 then return nil, "can't turn '" .. tostring(st.label) .. "' into inputs" end
        if #dirs <= 1 then
            local d = tonumber(dirs) or 5
            if air then d = 5 end
            add(-1, -1, d, 0)
            add(0, 1, d, mask)
        else
            local n = #dirs
            for i = 1, n - 1 do
                local f = -(n - i)
                add(f, f, tonumber(dirs:sub(i, i)), 0)
            end
            add(0, 1, tonumber(dirs:sub(n, n)), mask)
        end
        if held then add(2, 24, 5, mask) end
        plan.charge = charge
    end
    local lead = 0
    for _, e in ipairs(plan) do if -e.from > lead then lead = -e.from end end
    plan.lead = lead
    return plan
end

-- ---------------------------------------------------------------------------
-- construction / queue
-- ---------------------------------------------------------------------------
-- env: {
--   load(id) -> combo, profile          (loads it into the tracker too)
--   reset_profile()                     tracker  -> live tracker
--   teleport(user_x, dummy_x) -> bool   edge     -> stage edge (centre x limit)
--   fighter_id() -> current trainee fighter id
--   report(id, table)                   log(msg)
-- }
function Bot.new(env)
    local self = setmetatable({}, Bot)
    self.env = env
    self.running = false
    self.state = "idle"
    self.results = {}
    return self
end

function Bot:start(ids, opts)
    self.opts = opts or {}
    self.reps = math.max(1, math.min(3, tonumber(self.opts.reps) or 2))
    self.dmax = tonumber(self.opts.dmax) or 50
    self.sweet = self.opts.sweet ~= false
    self.queue = ids
    self.qi = 0
    self.results = {}
    self.running = true
    self.started_clock = os.clock()
    self.total_attempts = 0
    self.msg = nil
    self:next_combo()
end

function Bot:stop(reason)
    if not self.running then return end
    self.running = false
    self.state = "idle"
    self.events = {}
    self.stop_reason = reason or "stopped"
    if self.cur then self:finish_combo(reason or "stopped") end
    self.env.log("Bot stopped: " .. tostring(self.stop_reason))
end

function Bot:next_combo()
    self.cur = nil
    while true do
        self.qi = self.qi + 1
        local id = self.queue[self.qi]
        if not id then
            self.running = false
            self.state = "idle"
            self.stop_reason = "done"
            self.env.log("Bot finished: " .. #self.results .. " combo(s)")
            return
        end
        local combo, profile = self.env.load(id)
        local skip = nil
        if not combo then skip = "couldn't load it"
        elseif combo.bot and combo.bot.skip then skip = "marked skip"
        elseif combo.fighter_id and self.env.fighter_id() and combo.fighter_id ~= self.env.fighter_id() then
            skip = "needs " .. tostring(combo.fighter or combo.fighter_id) .. " selected in Training"
        end
        local plans = {}
        if not skip then
            for k, st in ipairs(combo.steps) do
                local p, why = Bot.step_plan(st, k, combo.steps[k - 1], combo.fighter_id, combo.control)
                if not p then skip = why break end
                plans[k] = p
            end
        end
        if skip then
            self.results[#self.results + 1] = { id = id, name = combo and combo.name or id, ok = false, reason = "skipped: " .. skip }
        else
            if self.opts.reset ~= false then self.env.reset_profile() end
            local name = (combo.name or ""):lower()
            local bot = combo.bot or {}
            self.cur = {
                id = id, combo = combo, profile = profile, plans = plans, N = #combo.steps,
                position = bot.position or self.opts.position_override or (name:find("corner") and "corner" or "mid"),
                spacing = tonumber(bot.spacing) or tonumber(self.opts.spacing) or 0,
                mid = {}, win = {}, attempts = 0, t0 = os.clock(),
            }
            self:begin_phase("A", 2)
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- phases
--   A: for k = 2..N, sweep step k (earlier steps at their middle) to find its window
--   B: full combos varying one step across its window (feeds the sweet spot)
--   C: full combos at the target timings (validation)
-- ---------------------------------------------------------------------------
function Bot:begin_phase(phase, k)
    local c = self.cur
    c.phase, c.k = phase, k
    if phase == "A" then
        if c.N < 2 then return self:begin_phase("C") end
        c.sweep = { d = c.plans[k].lead + 1, res = {}, first_ok = nil, last_ok = nil, pass = 1, list = nil }
        c.d = c.sweep.d
    elseif phase == "B" then
        if not self.sweet or k > c.N - 1 then return self:begin_phase("C") end
        local w = c.win[k]
        c.blist = {}
        for _ = 1, self.reps do for d = w.E, w.L do c.blist[#c.blist + 1] = d end end
        c.bi = 1
        c.d = c.blist[1]
    elseif phase == "C" then
        c.cn, c.cok = 0, 0
        c.d = nil
    end
    self:prep()
end

function Bot:offset(k)
    local c = self.cur
    if c.phase ~= "C" and k == c.k and c.d then return c.d end
    return c.mid[k]
end

function Bot:last_step()
    local c = self.cur
    if c.phase == "A" then return c.k end
    return c.N
end

local function contiguous(res, lo, hi)
    -- largest run of frames whose success rate is >= 0.5
    local best_E, best_L, E = nil, nil, nil
    for d = lo, hi + 1 do
        local r = res[d]
        local good = r and r.n > 0 and r.ok / r.n >= 0.5
        if good then E = E or d
        elseif E then
            if not best_E or (d - 1 - E) > (best_L - best_E) then best_E, best_L = E, d - 1 end
            E = nil
        end
    end
    return best_E, best_L
end

function Bot:on_result(res)
    if not self.running or not self.cur then return end
    if self.state ~= "run" and self.state ~= "await" then return end
    local c = self.cur
    c.attempts = c.attempts + 1
    self.total_attempts = self.total_attempts + 1
    self.attempt_time = os.clock()
    local steps = res and res.steps or {}
    local function ok_at(j) return steps[j] and steps[j].res == "ok" end

    if c.phase == "A" then
        local k = c.k
        local prev_ok = true
        for j = 1, k - 1 do if not ok_at(j) then prev_ok = false; c.bad_step = j end end
        if not prev_ok then
            c.instab = (c.instab or 0) + 1
            if c.instab >= 3 then
                local j = c.bad_step
                local why = (j == 1) and "the first hit doesn't connect from this spacing (check position/distance and dummy settings)"
                    or string.format("step %d (%s) stopped connecting at its own timing", j, c.combo.steps[j].label)
                return self:fail_combo(why)
            end
            return self:prep()           -- retry the same offset
        end
        c.instab = 0
        local sw = c.sweep
        local r = sw.res[c.d] or { n = 0, ok = 0 }
        r.n = r.n + 1
        if ok_at(k) then r.ok = r.ok + 1 end
        sw.res[c.d] = r
        if sw.pass == 1 then
            if ok_at(k) then sw.first_ok = sw.first_ok or c.d; sw.last_ok = c.d end
            local done = (sw.last_ok and c.d - sw.last_ok >= 4) or c.d >= self.dmax
            if not done then
                c.d = c.d + 1
                return self:prep()
            end
            if not sw.first_ok then
                return self:fail_combo(string.format("no timing between %d and %d frames made step %d (%s) work",
                    c.plans[k].lead + 1, self.dmax, k, c.combo.steps[k].label))
            end
            -- confirmation passes around the edges
            local E, L = contiguous(sw.res, c.plans[k].lead + 1, self.dmax)
            sw.list = {}
            for _ = 2, self.reps do
                for _, d in ipairs({ E - 1, E, L, L + 1 }) do
                    if d >= c.plans[k].lead + 1 then sw.list[#sw.list + 1] = d end
                end
            end
            sw.pass, sw.li = 2, 0
        end
        sw.li = (sw.li or 0) + 1
        if sw.list[sw.li] then
            c.d = sw.list[sw.li]
            return self:prep()
        end
        local E, L = contiguous(sw.res, c.plans[k].lead + 1, self.dmax)
        if not E then
            return self:fail_combo(string.format("step %d (%s) only worked by luck; no reliable timing", k, c.combo.steps[k].label))
        end
        c.win[k] = { E = E, L = L }
        c.mid[k] = (E + L) // 2
        if k < c.N then return self:begin_phase("A", k + 1) end
        -- refine targets with the profile's sweet spot later; go to B
        return self:begin_phase("B", 2)
    elseif c.phase == "B" then
        c.bi = c.bi + 1
        if c.blist[c.bi] then
            c.d = c.blist[c.bi]
            return self:prep()
        end
        -- adopt the profile's sweet-spot target for this step if it formed
        local w = c.profile and c.profile.window and c.profile:window(c.k)
        if w and w.sweet_lo then c.mid[c.k] = math.floor(w.mid + 0.5) end
        return self:begin_phase("B", c.k + 1)
    else -- C
        c.cn = c.cn + 1
        if res and res.ok then c.cok = c.cok + 1 end
        if c.cn < math.max(3, self.reps + 1) then return self:prep() end
        return self:finish_combo(nil)
    end
end

function Bot:fail_combo(why)
    local c = self.cur
    self.env.log("Bot: " .. (c.combo.name or c.id) .. ": " .. why)
    self:finish_combo(why)
    self:next_combo()
end

function Bot:finish_combo(why)
    local c = self.cur
    if not c then return end
    local windows = {}
    for k = 2, c.N do
        if c.win[k] then windows[k] = { E = c.win[k].E, L = c.win[k].L, target = c.mid[k] } end
    end
    local r = {
        id = c.id, name = c.combo.name, ok = why == nil, reason = why,
        attempts = c.attempts, seconds = math.floor(os.clock() - c.t0),
        windows = windows, clean = c.cok, clean_of = c.cn, position = c.position,
    }
    self.results[#self.results + 1] = r
    self.env.report(c.id, r)
    self.cur = nil
    if why == nil and self.running then self:next_combo() end
end

-- ---------------------------------------------------------------------------
-- attempt state machine
-- ---------------------------------------------------------------------------
function Bot:prep()
    self.state = "prep"
    self.prep_t = self.now or 0
    self.quiet = 0
    self.events = {}
end

-- called from the input hook, once per game frame, BEFORE the frame's sample
function Bot:frame_mask(t)
    if not self.running or (self.state ~= "run" and self.state ~= "await") then return nil end
    local dir, dprio, btn = nil, -99, 0
    local charge = nil
    for _, e in ipairs(self.events) do
        if t >= e.from and t <= e.to then
            btn = btn | e.btn
            if e.charge then charge = e.dir
            elseif e.prio > dprio then dir, dprio = e.dir, e.prio end
        end
    end
    if not dir then dir = charge end
    if not dir and btn == 0 then return nil end
    return dir or 5, btn
end

function Bot:schedule(k, press)
    local c = self.cur
    local plan = c.plans[k]
    for _, e in ipairs(plan) do
        self.events[#self.events + 1] = { from = press + e.from, to = press + e.to, dir = e.dir, btn = e.btn, prio = k }
    end
    if plan.charge then
        local from = math.max((self.press[k - 1] or press - CHARGE_FRAMES) + 2, press - CHARGE_FRAMES)
        self.events[#self.events + 1] = { from = from, to = press - plan.lead - 1, dir = plan.charge, btn = 0, prio = -1, charge = true }
    end
    self.press[k] = press
end

local function is_new_instance(s, prev)
    return not prev or s.u.act ~= prev.u.act or (s.u.af or 0) < (prev.u.af or 0)
end

-- called from the input hook with each sample (same frame)
function Bot:observe(s)
    self.now = s.t
    local prev = self.prev
    self.prev = s
    if not self.running then return end
    if (s.u.phys or 0) ~= 0 then return self:stop("controller input: hands off while the bot runs") end
    -- quiet detector for resets
    if prev and (s.o.act ~= prev.o.act or s.u.act ~= prev.u.act or s.o.stun > 0 or s.o.guard > 0 or (s.o.hitstop or 0) > 0) then
        self.quiet = 0
    else
        self.quiet = (self.quiet or 0) + 1
    end
    if self.state ~= "run" then return end
    local c = self.cur
    local j = self.wait_anchor
    -- the move pressed on frame P starts in the sample after P; anything that
    -- starts on P itself came from a direction held early (crouch, walk)
    if j and is_new_instance(s, prev) and s.t > (self.press[j] or math.huge) then
        local env = self.env
        local expected = c.profile and c.profile:learned_id(j)
        local match
        if expected then match = (s.u.act == expected)
        else
            match = not (env.tracker.neutral[s.u.act]) and
                not (j >= 2 and c.profile and c.profile:is_tail(j - 1, s.u.act))
        end
        if match then
            self.anchor[j] = s.t
            local nk = j + 1
            if nk <= self:last_step() then
                self:schedule(nk, s.t + self:offset(nk))
                self.wait_anchor = (nk < self:last_step()) and nk or nil
            else
                self.wait_anchor = nil
            end
            if not self.wait_anchor then self.state = "await"; self.await_t = s.t end
        end
    end
    if self.wait_anchor and s.t - (self.press[self.wait_anchor] or s.t) > 90 then
        self.wait_anchor = nil
        self.state = "await"
        self.await_t = s.t
    end
end

-- called from re.on_frame
function Bot:update()
    if not self.running or not self.cur then return end
    local now = self.now or 0
    if self.state == "prep" then
        local waited = now - (self.prep_t or now)
        if (self.quiet or 0) >= 20 and waited >= 20 or waited > 420 then
            self:do_teleport()
            self.state = "settle"
            self.settle_t = now
        end
    elseif self.state == "settle" then
        if now - self.settle_t == 2 then self:do_teleport() end
        if now - self.settle_t >= 24 then
            self.state = "run"
            self.events, self.press, self.anchor = {}, {}, {}
            local c = self.cur
            local p1 = now + c.plans[1].lead + 3
            self:schedule(1, p1)
            self.wait_anchor = (self:last_step() >= 2) and 1 or nil
            if not self.wait_anchor then self.state = "await"; self.await_t = now end
            self.run_t = now
        end
    elseif self.state == "await" or self.state == "run" then
        if now - (self.run_t or now) > 600 then
            -- the tracker never reported (e.g. step 1 whiffed before it counted)
            self:on_result({ ok = false, steps = {} })
        end
    end
end

function Bot:do_teleport()
    local c = self.cur
    local edge = self.env.edge or 730
    local dist = 30 + (c.spacing or 0)
    local ux, dx
    if c.position == "corner" then
        dx = edge - 1
        ux = dx - dist
    else
        ux, dx = -dist / 2, dist / 2
    end
    self.env.teleport(ux, dx)
end

function Bot:status()
    local c = self.cur
    local st = {
        running = self.running, state = self.state, stop_reason = self.stop_reason,
        queue_pos = self.qi or 0, queue_len = self.queue and #self.queue or 0,
        attempts = self.total_attempts or 0, results = self.results,
        elapsed = self.started_clock and math.floor(os.clock() - self.started_clock) or 0,
    }
    if c then
        st.combo_id, st.combo_name, st.phase, st.step, st.d = c.id, c.combo.name, c.phase, c.k, c.d
        st.step_label = c.k and c.combo.steps[c.k] and c.combo.steps[c.k].label
        st.combo_attempts = c.attempts
        st.N = c.N
        st.position = c.position
    end
    return st
end

return Bot
