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
local STRIDE = 3          -- coarse scan step (frames)

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
    local sa = (SA_BY_FIGHTER[fighter_id] or {})[label] or SA_DEFAULT[label]
    if sa then label = sa end

    local plan = {}
    local function add(from, to, dir, btn) plan[#plan + 1] = { from = from, to = to, dir = dir, btn = btn or 0 } end

    if label == "DR" then
        local tt = st.trigger and st.trigger.type
        if tt == "rawdr" then
            -- raw Drive Rush timed on the second forward: Parry, 6, 5, 6
            add(-10, -5, 5, MPMK); add(-4, -3, 6, 0); add(-2, -1, 5, 0); add(0, 2, 6, 0)
        elseif k == 1 or (prev_st and prev_st.kind == "move") then
            -- older combo files (DR timed on the parry press): Drive Parry, then 66
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
    -- a jump-in starter: the bot jumps forward first (see phases M and J)
    if air and k == 1 then plan.jump = true end
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
    env.trace = env.trace or function() end
    self.env = env
    self.running = false
    self.state = "idle"
    self.results = {}
    return self
end

function Bot:start(ids, opts)
    self.opts = opts or {}
    self.reps = math.max(1, math.min(3, tonumber(self.opts.reps) or 2))
    self.dmax = tonumber(self.opts.dmax) or 90
    self.sweet = self.opts.sweet ~= false
    self.queue = ids
    self.qi = 0
    self.results = {}
    self.running = true
    self.started_clock = os.clock()
    self.total_attempts = 0
    self.msg = nil
    -- the dummy's resting actions (standing / crouching idle), learned as the
    -- bot goes: an attempt only starts once the dummy is in one of them, so a
    -- long stumble or knockdown (a Drive Impact crumple) plays out first
    self.o_idle = {}
    self.o_same = 0
    self.env.trace(string.format("start: %d combo(s), reps %d, sweet %s", #ids, self.reps, tostring(self.sweet)))
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
    self.env.trace("stopped: " .. tostring(self.stop_reason))
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
            self.env.trace(string.format("skip %s: %s", tostring(id), skip))
            self.results[#self.results + 1] = { id = id, name = combo and combo.name or id, ok = false, reason = "skipped: " .. skip }
        else
            if self.opts.reset == true then self.env.reset_profile() end
            local name = (combo.name or ""):lower()
            local bot = combo.bot or {}
            self.cur = {
                id = id, combo = combo, profile = profile, plans = plans, N = #combo.steps,
                position = bot.position or self.opts.position_override or (name:find("corner") and "corner" or "mid"),
                spacing = tonumber(bot.spacing) or tonumber(self.opts.spacing) or 0,
                mid = {}, win = {}, attempts = 0, t0 = os.clock(),
            }
            self.env.trace(string.format("combo %s (%d steps, %s, spacing %s)", id, #combo.steps, self.cur.position, tostring(self.cur.spacing)))
            if plans[1].jump then
                -- a jump-in found on an earlier run (saved in the combo by the page) skips the search
                local bj = bot.jump
                if type(bj) == "table" and tonumber(bj.jd) and tonumber(bj.spacing) and not self.opts.reset then
                    self.cur.jd, self.cur.spacing = tonumber(bj.jd), tonumber(bj.spacing)
                    self.cur.jump, self.cur.jump_saved = { jd = self.cur.jd, spacing = self.cur.spacing }, true
                    self.env.trace(string.format("jump-in from an earlier run: spacing %d, press %d", self.cur.spacing, self.cur.jd))
                    if #combo.steps >= 2 then self:begin_phase("A", 2) else self:begin_phase("C") end
                else
                    self:begin_phase("M")
                end
            else
                self:begin_phase("A", 2)
            end
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
        c.sweep = { d = c.plans[k].lead + 1, res = {}, mode = "scan" }
        c.d = c.sweep.d
        self:seed(k)
    elseif phase == "B" then
        if not self.sweet or k > c.N - 1 then return self:begin_phase("C") end
        local w = c.win[k]
        c.blist = {}
        local step = math.max(1, math.ceil((w.L - w.E + 1) / 8))       -- at most ~8 frames per step
        for _ = 1, self.reps do
            for d = w.E, w.L, step do c.blist[#c.blist + 1] = d end
            if (w.L - w.E) % step ~= 0 then c.blist[#c.blist + 1] = w.L end
        end
        c.bi = 1
        c.d = c.blist[1]
    elseif phase == "C" then
        c.cn, c.cok = 0, 0
        c.d = nil
    elseif phase == "M" then
        -- measure the forward jump: how long until it lands, how far it goes
        -- (from far apart, so the dummy can't get in the way)
        c.jd = 12
        c.spacing_user = c.spacing_user or c.spacing
        c.spacing = 300
    elseif phase == "J" then
        -- find where to stand and when to press so the jump-in hits as deep
        -- as possible: try spacings around the jump's length; at each, scan
        -- the press from just before landing backwards until it hits
        local A, T = c.jm.A, c.jm.T
        local sp = {}
        for _, off in ipairs({ -35, -15, -55, -75, 5, -95 }) do
            local s2 = math.floor(T + off - 30)
            if s2 >= 0 then sp[#sp + 1] = s2 end
        end
        if #sp == 0 then sp[1] = 0 end
        local jl = {}
        for jd = A - 1, math.max(6, A - 30), -2 do jl[#jl + 1] = jd end
        c.js = { sp = sp, si = 1, jl = jl, ji = 1, tried = {} }
        c.spacing = sp[1]
        c.jd = jl[1]
    end
    self:prep()
end

-- Start from the window predicted from the game's frame data, if there is one:
-- probe just outside and just inside both edges. If all four agree the window
-- is found; otherwise fall back to the normal scan.
function Bot:seed(k)
    local c = self.cur
    local sw = c.sweep
    if sw.seeded or not c.profile or not c.profile.prediction then return false end
    -- a window measured on an earlier run beats the frame-data prediction
    local src, pred = "frame data", nil
    local okw, w = pcall(c.profile.window, c.profile, k)
    if okw and w and not w.pred and (w.n or 0) >= 3 and w.E and w.L then
        pred, src = { E = w.E, L = w.L }, "previous profile"
    else
        local ok
        ok, pred = pcall(c.profile.prediction, c.profile, k)
        if not ok then pred = nil end
    end
    if not pred or pred.impossible then return false end
    local dmin = c.plans[k].lead + 1
    if pred.L < dmin or pred.E > self.dmax then return false end
    local E, L = math.max(dmin, pred.E), math.min(self.dmax, pred.L)
    sw.seeded = true
    sw.mode = "seed"
    sw.pE, sw.pL = E, L
    sw.list, sw.li = {}, 1
    for _, d in ipairs({ E - 1, E, L, L + 1 }) do
        if d >= dmin and d <= self.dmax then sw.list[#sw.list + 1] = d end
    end
    c.d = sw.list[1]
    sw.src = src
    self.env.trace(string.format("step %d: checking window %d..%d from %s", k, pred.E, pred.L, src))
    return true
end

function Bot:offset(k)
    local c = self.cur
    if c.phase ~= "C" and k == c.k and c.d then return c.d end
    return c.mid[k]
end

function Bot:last_step()
    local c = self.cur
    if c.phase == "M" or c.phase == "J" then return 1 end
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
    if c.phase == "M" or c.phase == "J" then return end       -- judged by the bot itself (probe_done)
    c.attempts = c.attempts + 1
    self.total_attempts = self.total_attempts + 1
    self.attempt_time = os.clock()
    local steps = res and res.steps or {}
    local function ok_at(j) return steps[j] and steps[j].res == "ok" end
    do
        local k = c.k
        local tested = (c.phase == "A") and k or nil
        local sres = tested and steps[tested] and steps[tested].res or nil
        self.last_probe = {
            phase = c.phase, step = tested, label = tested and c.combo.steps[tested].label or nil, d = c.d,
            ok = tested and ok_at(tested) or (res and res.ok) or false,
            res = sres or (res and res.result), fail_step = res and res.fail_step,
            fail_label = res and res.fail_step and c.combo.steps[res.fail_step] and c.combo.steps[res.fail_step].label,
            t = os.clock(),
        }
    end
    do
        local parts = {}
        for j = 1, c.N do parts[#parts + 1] = steps[j] and (steps[j].res .. (steps[j].p and ("@" .. steps[j].p) or "")) or "-" end
        self.env.trace(string.format("#%d phase %s step %s d=%s anchors=%d -> %s [%s]", c.attempts, c.phase, tostring(c.k),
            tostring(c.d), self.anchor and #self.anchor or 0, res and (res.ok and "clean" or ("fail@" .. tostring(res.fail_step))) or "no result",
            table.concat(parts, " ")))
    end

    -- experimental combos (not confirmed to work) get a limited number of
    -- tries: give up after `experimental_limit` attempts in a row with nothing working
    if self.opts.experimental_limit and c.combo.experimental == true then
        local success = res and res.ok or false
        if c.phase == "A" then
            success = true
            for j = 1, c.k do if not ok_at(j) then success = false end end
        end
        c.dry = success and 0 or (c.dry or 0) + 1
        local lim = math.max(1, tonumber(self.opts.experimental_limit) or 30)
        if c.dry >= lim then
            return self:fail_combo(string.format("experimental combo: no successful attempt in %d tries, gave up", lim))
        end
    end
    if c.phase == "A" then
        local k = c.k
        local prev_ok = true
        for j = 1, k - 1 do if not ok_at(j) then prev_ok = false; c.bad_step = j end end
        if not prev_ok then
            c.instab = (c.instab or 0) + 1
            if c.instab >= 3 and c.jump_saved and c.bad_step == 1 then
                -- the saved jump-in no longer lands: measure it again
                c.jump_saved, c.instab = nil, 0
                self.env.trace("saved jump-in doesn't hit any more; measuring again")
                return self:begin_phase("M")
            end
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
        local good = ok_at(k)
        if good then r.ok = r.ok + 1 end
        sw.res[c.d] = r
        local dmin = c.plans[k].lead + 1
        local label = c.combo.steps[k].label
        -- predicted window: check its edges first
        if sw.mode == "seed" then
            sw.li = sw.li + 1
            if sw.list[sw.li] then c.d = sw.list[sw.li]; return self:prep() end
            local function works(d) local x = sw.res[d]; return x and x.n > 0 and x.ok / x.n >= 0.5 end
            local function fails(d) local x = sw.res[d]; return (d < dmin or d > self.dmax) or (x and x.n > 0 and x.ok / x.n < 0.5) end
            if works(sw.pE) and works(sw.pL) and fails(sw.pE - 1) and fails(sw.pL + 1) then
                sw.E, sw.L = sw.pE, sw.pL
                sw.mode = "confirm"
                self.env.trace(string.format("step %d: %s window confirmed", k, sw.src or "predicted"))
            else
                self.env.trace(string.format("step %d: prediction was off; searching", k))
                sw.mode = "scan"
                sw.last_fail = nil
                c.d = dmin
                return self:prep()
            end
        end
        -- the move came out for the first time: a prediction may be possible now
        if sw.mode == "scan" and not good and not sw.seeded and self:seed(k) then return self:prep() end
        -- coarse-to-fine search: scan in strides, then bisect each edge
        if sw.mode == "scan" then
            if good then
                sw.first_ok, sw.last_ok = c.d, c.d
                if sw.last_fail then sw.mode, sw.lo, sw.hi = "lo", sw.last_fail, c.d
                else sw.E = c.d; sw.mode = "hi_scan" end
            else
                sw.last_fail = c.d
                c.d = c.d + STRIDE
                if c.d > self.dmax then
                    return self:fail_combo(string.format("no timing between %d and %d frames made step %d (%s) work",
                        dmin, self.dmax, k, label))
                end
                return self:prep()
            end
        elseif sw.mode == "lo" then
            if good then sw.hi = c.d else sw.lo = c.d end
        elseif sw.mode == "hi_scan" then
            if good then sw.last_ok = c.d else sw.mode, sw.lo, sw.hi = "hi", sw.last_ok, c.d end
        elseif sw.mode == "hi" then
            if good then sw.lo = c.d else sw.hi = c.d end
        end
        -- choose the next probe
        if sw.mode == "lo" then
            if sw.hi - sw.lo > 1 then c.d = (sw.lo + sw.hi) // 2; return self:prep() end
            sw.E = sw.hi
            sw.mode = "hi_scan"
        end
        if sw.mode == "hi_scan" then
            local nd = sw.last_ok + STRIDE
            if nd <= self.dmax then c.d = nd; return self:prep() end
            sw.L = self.dmax
            sw.mode = "confirm"
        end
        if sw.mode == "hi" then
            if sw.hi - sw.lo > 1 then c.d = (sw.lo + sw.hi) // 2; return self:prep() end
            sw.L = sw.lo
            sw.mode = "confirm"
        end
        if sw.mode == "confirm" then
            if not sw.list then
                sw.list, sw.li = {}, 0
                for _ = 2, self.reps do
                    for _, d in ipairs({ sw.E - 1, sw.E, sw.L, sw.L + 1 }) do
                        if d >= dmin and d <= self.dmax then sw.list[#sw.list + 1] = d end
                    end
                end
            end
            sw.li = sw.li + 1
            if sw.list[sw.li] then c.d = sw.list[sw.li]; return self:prep() end
        end
        -- settle the edges with the confirmation results
        local function rate(d) local x = sw.res[d]; return x and x.n > 0 and (x.ok / x.n) or nil end
        local E, L = sw.E, sw.L
        if rate(E - 1) and rate(E - 1) >= 0.5 then E = E - 1 end
        if rate(E) and rate(E) < 0.5 and E < L then E = E + 1 end
        if rate(L + 1) and rate(L + 1) >= 0.5 then L = L + 1 end
        if rate(L) and rate(L) < 0.5 and L > E then L = L - 1 end
        if not E or not L or L < E then
            return self:fail_combo(string.format("step %d (%s) only worked by luck; no reliable timing", k, label))
        end
        c.win[k] = { E = E, L = L }
        c.mid[k] = (E + L) // 2
        self.env.trace(string.format("step %d (%s) window %d..%d", k, label, E, L))
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

-- end of a jump measurement (M) or a jump-in probe (J)
function Bot:probe_done()
    local c, P = self.cur, self.probe
    self.probe = nil
    c.attempts = c.attempts + 1
    self.total_attempts = self.total_attempts + 1
    self.attempt_time = os.clock()
    if c.phase == "M" then
        -- takeoff: first frame x moves; landing: x stops for 2 frames after that
        local xs, t0, x0, t1, x1 = P.xs, nil, nil, nil, nil
        for i = 2, #xs do
            local dx = math.abs(xs[i].x - xs[i - 1].x)
            if not t0 and dx > 0.5 then t0, x0 = xs[i - 1].t, xs[i - 1].x end
            if t0 and not t1 and i < #xs and dx < 0.01 and math.abs(xs[i + 1].x - xs[i].x) < 0.01 then t1, x1 = xs[i].t, xs[i].x end
        end
        if not t0 or not t1 then
            return self:fail_combo("couldn't see a forward jump (is the dummy in the way, or is 9 not a jump?)")
        end
        c.jm = { A = t1 - P.jump_t, T = math.abs(x1 - x0) }
        self.env.trace(string.format("jump: lands %d frames after the input, travels %.0f", c.jm.A, c.jm.T))
        return self:begin_phase("J")
    end
    -- J: did the air attack (started before landing) hit?
    local js = c.js
    local air_hit = P.hit_t ~= nil and P.atk_t ~= nil and P.atk_t < P.jump_t + c.jm.A
    js.tried[c.spacing .. ":" .. c.jd] = air_hit
    self.last_probe = { phase = "J", d = c.jd, ok = air_hit, res = air_hit and "air hit" or "no air hit", t = os.clock() }
    self.env.trace(string.format("jump-in probe spacing %d press %d after the jump: %s", c.spacing, c.jd, air_hit and "hit" or "no"))
    if js.refine then
        if not air_hit then c.jd = js.found end
        return self:jump_found()
    end
    if air_hit then
        js.found = c.jd
        if js.tried[c.spacing .. ":" .. (c.jd + 1)] == nil and c.jd + 1 < c.jm.A then
            js.refine = true
            c.jd = c.jd + 1            -- one frame later (deeper) was skipped by the coarse scan
            return self:prep()
        end
        return self:jump_found()
    end
    js.ji = js.ji + 1
    if not js.jl[js.ji] then
        js.si, js.ji = js.si + 1, 1
        if not js.sp[js.si] then
            return self:fail_combo("the jump-in never hit (tried " .. #js.sp .. " distances); set the spacing by hand or check the dummy")
        end
        c.spacing = js.sp[js.si]
    end
    c.jd = js.jl[js.ji]
    return self:prep()
end

function Bot:jump_found()
    local c = self.cur
    c.jump = { jd = c.jd, spacing = c.spacing }
    self.env.trace(string.format("jump-in: spacing %d, press %d frames after the jump", c.spacing, c.jd))
    if c.N >= 2 then return self:begin_phase("A", 2) end
    return self:begin_phase("C")
end

function Bot:fail_combo(why)
    local c = self.cur
    local nm = " " .. tostring(c.combo.name or "") .. " "
    if nm:find("[%s:%(]CH[%s,)]") or nm:find("[%s:%(]PC[%s,)]") or nm:lower():find("counter") then
        why = why .. " (this combo needs a counter hit: set the dummy's Counter setting)"
    end
    self.env.trace("combo failed: " .. why)
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
        windows = windows, clean = c.cok, clean_of = c.cn, position = c.position, jump = c.jump,
    }
    self.results[#self.results + 1] = r
    self.env.trace(string.format("combo done %s ok=%s clean %s/%s attempts %d", c.id, tostring(r.ok), tostring(c.cok), tostring(c.cn), c.attempts))
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
    if k == 1 and plan.jump then
        self.events[#self.events + 1] = { from = press - c.jd, to = press - c.jd + 1, dir = 9, btn = 0, prio = 0 }
        if c.phase == "M" then self.press[k] = press; return end     -- just the jump
    end
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
    -- how long the dummy has been in the same action
    if prev and s.o.act ~= nil and s.o.act == prev.o.act then self.o_same = (self.o_same or 0) + 1 else self.o_same = 0 end
    -- quiet detector for resets
    if prev and (s.o.act ~= prev.o.act or s.u.act ~= prev.u.act or s.o.stun > 0 or s.o.guard > 0 or (s.o.hitstop or 0) > 0) then
        self.quiet = 0
    else
        self.quiet = (self.quiet or 0) + 1
    end
    local P = self.probe
    if P and (self.state == "run" or self.state == "await") and s.t >= P.jump_t then
        P.xs[#P.xs + 1] = { t = s.t, x = s.u.x or 0 }
        if (s.o.stun or 0) > 0 and (not prev or (prev.o.stun or 0) == 0) and not P.hit_t then P.hit_t = s.t end
        if s.t > P.press and not P.atk_t and is_new_instance(s, prev) then P.atk_t, P.atk_act = s.t, s.u.act end
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
        self.env.trace(string.format("step %d's move never started (expected action %s, last action %s)", self.wait_anchor,
            tostring(c.profile and c.profile:learned_id(self.wait_anchor)), tostring(s.u.act)))
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
        -- wait for the dummy to be back on its feet: a crumple or a knockdown
        -- can hold one action long enough to look "quiet"
        local o = self.prev and self.prev.o
        local idle = self.o_idle or {}
        local up = true
        if o and next(idle) then
            up = idle[o.act] == true or (self.o_same or 0) >= 180     -- 3 s unchanged: a new resting pose (stance changed)
        end
        if (self.quiet or 0) >= 20 and waited >= 20 and not up and not self.told_wait then
            self.told_wait = true
            self.env.trace(string.format("waiting for the dummy to get back up (action %s)", tostring(o and o.act)))
        end
        if ((self.quiet or 0) >= 20 and waited >= 20 and up) or waited > 420 then
            self.told_wait = nil
            -- learn the resting action (not after a timeout: the dummy may still be down)
            if o and o.act ~= nil and up and (o.stun or 0) == 0 and (o.guard or 0) == 0 then
                self.o_idle = self.o_idle or {}
                self.o_idle[o.act] = true
            end
            self:do_teleport()
            self.state = "settle"
            self.settle_t = now
            self.retp = false
        end
    elseif self.state == "settle" then
        -- (>= and a flag: at research speed several frames can pass per update)
        if not self.retp and now - self.settle_t >= 2 then self.retp = true; self:do_teleport() end
        -- don't start until the fighters really are in place
        local pending, result = nil, nil
        if self.env.tp_status then pending, result = self.env.tp_status() end
        if now - self.settle_t >= 24 and (pending or (result and result ~= "ok")) then
            self.tp_tries = (self.tp_tries or 0) + 1
            if self.tp_tries > 3 then
                self.tp_tries = 0
                return self:fail_combo("couldn't move the fighters into position (" .. tostring(result or "teleport pending") .. ")")
            end
            self:do_teleport()
            self.settle_t = now - 4
            return
        end
        if now - self.settle_t >= 24 then
            self.tp_tries = 0
            self.state = "run"
            self.events, self.press, self.anchor = {}, {}, {}
            local c = self.cur
            local lead1 = c.plans[1].jump and (c.jd + 1) or c.plans[1].lead
            local p1 = now + lead1 + 3
            self:schedule(1, p1)
            self.wait_anchor = (self:last_step() >= 2) and 1 or nil
            if not self.wait_anchor then self.state = "await"; self.await_t = now end
            self.run_t = now
            self.probe = nil
            if c.phase == "M" or c.phase == "J" then
                self.probe = { press = p1, jump_t = p1 - c.jd, xs = {}, stun0 = nil }
            end
        end
    elseif self.probe and (self.state == "await" or self.state == "run") then
        if now >= self.probe.jump_t + (self.cur.phase == "M" and 90 or ((self.cur.jm and self.cur.jm.A or 50) + 40)) then
            return self:probe_done()
        end
    elseif self.state == "await" or self.state == "run" then
        if now - (self.run_t or now) > 600 then
            -- the tracker never reported (e.g. step 1 whiffed before it counted)
            self.env.trace(string.format("no tracker result after 600 frames (state %s, waiting for step %s anchor)", self.state, tostring(self.wait_anchor)))
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
    local ok = self.env.teleport(ux, dx)
    if not ok and not self.warned_tp then
        self.warned_tp = true
        self.env.trace("teleport failed (POS_SETx not available?) - attempts will start from wherever the fighters are")
    end
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
        st.last_probe = self.last_probe
        st.N = c.N
        st.position = c.position
    end
    return st
end

return Bot
