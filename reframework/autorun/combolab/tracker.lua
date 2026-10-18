-- ComboLab tracker: pure-Lua combo attempt state machine.
--
-- Fed one normalized sample per GAME frame (see game.lua for the producer):
--   s.t   integer frame counter (monotonic)
--   s.u   user fighter   { act, af, margin, held, dir }
--           act    action id            af      current action frame (number)
--           margin IASA/margin frame    held    held button bits (pl_sw_new, buttons only)
--           dir    numpad 1-9 relative to facing
--   s.o   opponent       { stun, hitstop, guard }
--   s.cc  user's combo counter (team.mComboCount)
--
-- No REFramework APIs in here so it can be exercised by tests/sim.lua.

local Tracker = {}
Tracker.__index = Tracker

local RING = 40          -- idle frames kept so step-1 presses before the attempt are seen
local LOOKBACK1 = 20     -- how far before step 1's action a press may be attributed
local GRACE_DROP = 20    -- frames still recorded after a drop (late presses / late procs)
local GRACE_OK = 15      -- frames recorded after success (spam after last step)

local function is_up(d)  return d == 7 or d == 8 or d == 9 end
local function is_fwd(d) return d == 3 or d == 6 or d == 9 end

-- Does step trigger `trig` fire on frames[i]?
local function trig_match(trig, frames, i)
    local f, pf = frames[i], frames[i - 1]
    if not f then return false end
    local held = f.held or 0
    local pheld = pf and pf.held or 0
    local tt = trig.type or "button"
    if tt == "button" then
        local m = trig.mask or 0
        if m == 0 then return false end
        if trig.mode == "any" then
            return (held & ~pheld & m) ~= 0
        end
        return (held & m) == m and (pheld & m) ~= m
    elseif tt == "jump" then
        return is_up(f.dir) and not (pf and is_up(pf.dir))
    elseif tt == "dash" then
        if not (is_fwd(f.dir) and not (pf and is_fwd(pf.dir))) then return false end
        for j = i - 1, math.max(2, i - 14), -1 do
            if is_fwd(frames[j].dir) and not is_fwd(frames[j - 1].dir) then return true end
        end
        return false
    end
    return false
end
Tracker.trig_match = trig_match

local function same_trigger(a, b)
    if not a or not b then return false end
    return (a.type or "button") == (b.type or "button") and (a.mask or 0) == (b.mask or 0)
        and (a.mode or "all") == (b.mode or "all")
end

function Tracker.new(opts)
    local self = setmetatable({}, Tracker)
    self.opts = opts or {}
    self.neutral = {}          -- [act] = true, learned while idle
    self.combo = nil
    self.profile = nil
    self.prev = nil
    self.ring = {}
    self.inst = nil
    self.inst_seq = 0
    self.last_rise_t = -1000
    self.att = nil
    self.last_result = nil
    return self
end

function Tracker:set_combo(combo, profile)
    self.combo = combo
    self.profile = profile
    self.att = nil
    self.last_result = nil
    if profile and profile.neutral then
        for k in pairs(profile.neutral) do self.neutral[tonumber(k)] = true end
    end
end

function Tracker:learned_id(k)
    return self.profile and self.profile:learned_id(k) or nil
end

function Tracker:is_tail(k, act)
    return self.profile and self.profile:is_tail(k, act) or false
end

function Tracker:is_step_act(act)
    if not self.profile then return false end
    for k = 1, #self.combo.steps do
        if self.profile:learned_id(k) == act then return true end
    end
    return false
end

local function opt(self, k, d)
    local v = self.opts[k]
    if v == nil then return d end
    return v
end

-- --------------------------------------------------------------------------
-- frame push
-- --------------------------------------------------------------------------
function Tracker:push(s)
    if not self.combo or not self.combo.steps or #self.combo.steps == 0 then
        self.prev = s
        return nil
    end
    local prev = self.prev
    local u = s.u
    local held = u.held or 0
    local rise = held & ~(prev and prev.u.held or 0)
    if rise ~= 0 then self.last_rise_t = s.t end

    -- action instance tracking (a restart of the same id counts as new)
    local new_inst = false
    if not prev or u.act ~= prev.u.act or (u.af or 0) < (prev.u.af or 0) then
        self.inst_seq = self.inst_seq + 1
        if self.inst then self.inst.stop = s.t - 1 end
        self.inst = { id = self.inst_seq, act = u.act, start = s.t }
        new_inst = true
    end
    local inst = self.inst
    inst.neutral = self.neutral[u.act] == true

    local frame = {
        t = s.t, held = held, dir = u.dir or 5, act = u.act, af = u.af or 0,
        margin = u.margin or 0, inst = inst.id, neutral = inst.neutral,
        cc = s.cc or 0, stun = s.o.stun or 0, guard = s.o.guard or 0,
        ohs = s.o.hitstop or 0,
    }

    local event = nil
    if not self.att then
        -- learn neutral actions: started with nothing pressed recently
        if new_inst and held == 0 and (s.t - self.last_rise_t) > LOOKBACK1
            and not self:is_step_act(u.act) then
            self.neutral[u.act] = true
            inst.neutral = true
            frame.neutral = true
        end
        self.ring[#self.ring + 1] = frame
        if #self.ring > RING then table.remove(self.ring, 1) end
        if new_inst then self:try_start(s, frame) end
    else
        local att = self.att
        att.frames[#att.frames + 1] = frame
        att.inst_by_id[inst.id] = inst
        event = self:step_attempt(s, frame, new_inst)
    end
    self.prev = s
    return event
end

function Tracker:try_start(s, frame)
    local steps = self.combo.steps
    local st1 = steps[1]
    local inst = self.inst
    local learned = self:learned_id(1)
    local ok = false
    local trig1 = st1.trigger or {}
    local movement_trig = trig1.type == "jump" or trig1.type == "dash"
    if learned then
        ok = (inst.act == learned)
    elseif not inst.neutral or movement_trig then
        -- a step-1 press within the lookback
        local n = #self.ring
        for i = n, math.max(2, n - LOOKBACK1), -1 do
            if trig_match(trig1, self.ring, i) then ok = true break end
        end
    end
    if not ok then return end

    local att = {
        t0 = s.t,
        frames = {},
        inst_by_id = {},
        st = {},          -- per step live record
        c = 1,            -- next unresolved step
        last_progress = s.t,
        first_connect = nil,
        last_nn = inst,   -- last non-neutral instance
        blocked = false,
    }
    for i = 1, #self.ring do att.frames[i] = self.ring[i] end
    self.ring = {}
    att.inst_by_id[inst.id] = inst
    att.st[1] = { proc = inst.start, inst = inst }
    if (st1.kind or "hit") == "move" then
        att.st[1].resolved = s.t
        att.c = 2
    end
    self.att = att
    self.live_changed = true
    if att.c > #self.combo.steps then
        att.success_t = s.t
        att.finish_at = s.t + GRACE_OK
    end
end

-- was step trigger `trig` pressed with lo < t <= hi (within the attempt)?
function Tracker:pressed_since(trig, lo, hi)
    local frames = self.att.frames
    for i = #frames, 2, -1 do
        local t = frames[i].t
        if t <= lo then break end
        if t <= hi and trig_match(trig, frames, i) then return true end
    end
    return false
end

-- --------------------------------------------------------------------------
-- attempt in progress
-- --------------------------------------------------------------------------
function Tracker:step_attempt(s, frame, new_inst)
    local att = self.att
    local steps = self.combo.steps
    local N = #steps
    local prev = self.prev
    local inst = self.inst
    local prev_cc = prev and prev.cc or 0
    local cc = s.cc or 0

    if not inst.neutral then att.last_nn = inst end

    if att.finish_at then
        if s.t >= att.finish_at then return self:finish() end
        return nil
    end

    local c = att.c

    -- new action instance while step c is pending
    if new_inst and c <= N and c >= 2 then
        local A = att.st[c - 1].proc
        local st = steps[c]
        local learned = self:learned_id(c)
        local prev_inst = att.st[c - 1].inst
        if inst ~= prev_inst and s.t > A then
            local trig = st.trigger or {}
            local mv_trig = trig.type == "jump" or trig.type == "dash"
            local is_tail = self:is_tail(c - 1, inst.act)
            if not inst.neutral or (mv_trig and (st.kind == "move")) then
                if (st.kind or "hit") == "move" then
                    local bind = false
                    if learned then
                        bind = (inst.act == learned)
                    else
                        -- unlearned: needs a step-c press since the anchor
                        for i = #att.frames, 2, -1 do
                            local f = att.frames[i]
                            if f.t <= A then break end
                            if trig_match(trig, att.frames, i) then bind = true break end
                        end
                    end
                    if bind then
                        att.st[c] = { proc = inst.start, inst = inst, resolved = s.t }
                        att.c = c + 1
                        att.last_progress = s.t
                        self.live_changed = true
                        if att.c > N then
                            att.success_t = s.t
                            att.finish_at = s.t + GRACE_OK
                        end
                        return nil
                    end
                end
            end
        end
    end

    -- a hit landed
    if cc > prev_cc then
        local I = inst.neutral and att.last_nn or inst
        att.last_progress = s.t
        att.hits = (att.hits or 0) + 1
        if not att.first_connect then att.first_connect = s.t end
        if c == 1 then
            local st1 = att.st[1]
            if I ~= st1.inst then st1.inst = I; st1.proc = I.start end
            st1.connect = s.t
            st1.r = prev and prev.o.stun or 0
            st1.resolved = s.t
            att.c = 2
            self.live_changed = true
        elseif c <= N then
            local pst = att.st[c - 1]
            if I == pst.inst then
                pst.extra_hits = (pst.extra_hits or 0) + 1
            elseif (steps[c].kind or "hit") == "hit" then
                local learned = self:learned_id(c)
                local known = learned and (I.act == learned or (self.profile and self.profile:knows_id(c, I.act)))
                if not known and not (learned and opt(self, "strict_ids", false))
                    and not self:pressed_since(steps[c].trigger or {}, pst.proc, I.start) then
                    -- a later hit of the previous move (sub-action), not this step
                    pst.extra_hits = (pst.extra_hits or 0) + 1
                    return nil
                end
                local is_later = false
                if not known then
                    for j = c + 1, N do
                        if self:learned_id(j) == I.act then is_later = true end
                    end
                end
                if learned and not known and (is_later or opt(self, "strict_ids", false)) then
                    -- the wrong move connected
                    att.fail = { step = c, kind = "wrong", inst = I }
                    att.drop_t = s.t
                    att.finish_at = s.t + GRACE_DROP
                    self.live_changed = true
                    return nil
                end
                att.st[c] = { proc = I.start, inst = I, connect = s.t,
                              r = prev and prev.o.stun or 0, resolved = s.t }
                att.c = c + 1
                self.live_changed = true
            else
                -- a hit from a new action while a movement step was expected
                att.fail = { step = c, kind = "skipped", inst = I }
                att.drop_t = s.t
                att.finish_at = s.t + GRACE_DROP
                self.live_changed = true
                return nil
            end
        end
        if att.c > N then
            att.success_t = s.t
            att.finish_at = s.t + GRACE_OK
            return nil
        end
        return nil
    end

    c = att.c
    -- drop / failure detection
    local timeout = opt(self, "timeout", 90)
    if not att.first_connect then
        local t1 = opt(self, "first_hit_timeout", 60)
        if s.t - att.t0 > t1 then
            att.drop_t = s.t
            att.fail = { step = c, kind = "timeout" }
        end
    else
        if cc < prev_cc then
            att.drop_t = s.t
            att.fail = { step = c, kind = "drop" }
        elseif (s.o.guard or 0) > 0 and (prev and prev.o.guard or 0) == 0 then
            att.drop_t = s.t
            att.blocked = true
            att.fail = { step = c, kind = "blocked" }
        elseif s.t - att.last_progress > timeout then
            att.drop_t = s.t
            att.fail = { step = c, kind = "timeout" }
        end
    end
    if att.fail then
        att.finish_at = s.t + GRACE_DROP
        self.live_changed = true
    end
    return nil
end

-- --------------------------------------------------------------------------
-- analysis
-- --------------------------------------------------------------------------
local function index_of_t(frames, t)
    -- frames are contiguous-ish; binary search on t
    local lo, hi = 1, #frames
    while lo <= hi do
        local mid = (lo + hi) // 2
        local ft = frames[mid].t
        if ft == t then return mid end
        if ft < t then lo = mid + 1 else hi = mid - 1 end
    end
    return lo
end

-- presses of trigger `trig` with lo < t <= hi
local function presses_in(trig, frames, lo, hi)
    local out = {}
    for i = 2, #frames do
        local t = frames[i].t
        if t > hi then break end
        if t > lo and trig_match(trig, frames, i) then out[#out + 1] = t end
    end
    return out
end

-- first frame after A where the user is free from the instance `pinst`
local function link_open(frames, A, pinst)
    if not pinst then return nil end
    local i0 = index_of_t(frames, A)
    for i = i0, #frames do
        local f = frames[i]
        if f.t > A then
            if f.inst == pinst.id then
                if f.margin and f.margin > 0 and f.af >= f.margin then return f.t end
            elseif f.neutral then
                return f.t
            else
                return nil -- something else started before we were free: a cancel
            end
        end
    end
    return nil
end

function Tracker:finish()
    local att = self.att
    local steps = self.combo.steps
    local N = #steps
    local frames = att.frames
    local t_end = frames[#frames].t
    local ok = att.fail == nil and att.success_t ~= nil
    local fail_step = att.fail and att.fail.step or nil
    local last = ok and N or (fail_step or 1)

    local res = {
        ok = ok, fail_step = fail_step, fail_kind = att.fail and att.fail.kind or nil,
        t0 = att.t0, t_end = t_end, steps = {}, hits = att.hits or 0,
        combo_id = self.combo.id, combo_ver = self.combo.version,
    }

    for k = 1, math.min(last, N) do
        local st = steps[k]
        local rec = att.st[k] or {}
        local trig = st.trigger or {}
        local o = { label = st.label, res = "pending" }
        res.steps[k] = o
        local A = (k >= 2 and att.st[k - 1]) and att.st[k - 1].proc or nil
        local resolved = rec.resolved ~= nil
        local lo, hi
        if k == 1 then
            lo = (rec.proc or att.t0) - LOOKBACK1 - 1
            hi = rec.proc or att.t0
        else
            lo = A
            hi = rec.proc or t_end
        end
        local pr = presses_in(trig, frames, lo, hi)
        o.presses = #pr
        o.press_t = pr[#pr]
        if k >= 2 and A then
            o.p = pr[#pr] and (pr[#pr] - A) or nil
            o.p_first = pr[1] and (pr[1] - A) or nil
            if rec.proc then o.q = rec.proc - A end
            if rec.connect then o.k = rec.connect - A end
            if rec.r and rec.r > 0 then o.r = rec.r end
            local pst = att.st[k - 1]
            if (steps[k - 1].kind or "hit") == "hit" then
                local lo_t = link_open(frames, A, pst.inst)
                if lo_t then o.o = lo_t - A end
            end
        else
            if rec.proc and pr[#pr] then o.latency = rec.proc - pr[#pr] end
        end
        if rec.inst then o.act = rec.inst.act end

        -- spam: repeated trigger after the step came out, before the next step's action
        local spam_after = 0
        if rec.proc then
            local nxt = steps[k + 1]
            if not nxt or not same_trigger(trig, nxt.trigger) then
                local up = (att.st[k + 1] and att.st[k + 1].proc) or t_end
                spam_after = #presses_in(trig, frames, rec.proc, up)
            end
        end
        o.spam_after = spam_after
        o.spam = math.max(0, #pr - 1) + spam_after

        -- tail instances between this step's proc and the next one
        if resolved and att.st[k + 1] and att.st[k + 1].proc then
            local tails, seen = {}, {}
            local a, b = rec.proc, att.st[k + 1].proc
            for i = index_of_t(frames, a), #frames do
                local f = frames[i]
                if f.t >= b then break end
                if f.t > a and f.inst ~= rec.inst.id and not f.neutral and not seen[f.inst] then
                    seen[f.inst] = true
                    tails[#tails + 1] = f.act
                end
            end
            o.tail = tails
        end

        if resolved and k ~= fail_step then
            o.res = "ok"
        end
    end

    if not ok and fail_step and fail_step <= N then
        self:classify(res, att, fail_step, t_end)
    end
    if ok then res.result = "ok" else res.result = res.steps[fail_step] and res.steps[fail_step].res or "fail" end
    res.neutral = {}
    for a in pairs(self.neutral) do res.neutral[#res.neutral + 1] = a end

    self.att = nil
    self.last_result = res
    self.live_changed = true
    return { type = "attempt", result = res }
end

-- Decide why step k failed. Uses state; the profile refines early/late afterwards.
function Tracker:classify(res, att, k, t_end)
    local o = res.steps[k]
    local steps = self.combo.steps
    local frames = att.frames
    local drop_t = att.drop_t or t_end
    local A = (k >= 2) and att.st[k - 1].proc or att.t0
    local trig = steps[k].trigger or {}
    local learned = self:learned_id(k)

    local pr = presses_in(trig, frames, A, t_end)

    -- did the expected action come out at all? Scan action instances that
    -- started after the anchor (and after the first press when unlearned).
    local proc_inst, wrong = nil, nil
    if att.st[k] and att.st[k].inst then
        proc_inst = att.st[k].inst
    else
        local prev_id = (k >= 2 and att.st[k - 1].inst) and att.st[k - 1].inst.id or -1
        local seen = {}
        for i = index_of_t(frames, A), #frames do
            local f = frames[i]
            if f.t > A and not seen[f.inst] and f.inst ~= prev_id then
                seen[f.inst] = true
                local inst = att.inst_by_id[f.inst] or { act = f.act, start = f.t }
                local skip = f.neutral or (k >= 2 and self:is_tail(k - 1, f.act))
                if not skip then
                    if learned then
                        if f.act == learned then proc_inst = inst break end
                        wrong = wrong or inst
                    elseif pr[1] and inst.start >= pr[1] then
                        proc_inst = inst
                        break
                    end
                end
            end
        end
    end
    if proc_inst then
        o.act = proc_inst.act
        o.q = proc_inst.start - A
    end
    o.presses = #pr
    -- effective press: last one before the action came out, else the last one at all
    local eff = nil
    if proc_inst then
        for _, t in ipairs(pr) do if t <= proc_inst.start then eff = t end end
    end
    eff = eff or pr[#pr]
    if k >= 2 and eff then o.p = eff - A end
    o.p_first = (k >= 2 and pr[1]) and (pr[1] - A) or nil
    o.spam = math.max(0, #pr - 1)
    o.drop = drop_t - A

    -- the move that hit instead: is it one of the LATER steps? then this step's
    -- input was simply eaten and the player carried on with the combo
    local hit_inst = att.fail and (att.fail.kind == "wrong" or att.fail.kind == "skipped") and
        (att.fail.inst or att.last_nn) or nil
    local later = false
    if hit_inst then
        for j = k + 1, #steps do
            if self:learned_id(j) == hit_inst.act then later = true end
        end
    end
    if hit_inst and later and #pr > 0 then
        o.res = "eaten"
        o.act = nil
        o.q = nil
        o.hint = "this input didn't come out; your next move hit instead"
    elseif att.fail and att.fail.kind == "wrong" then
        o.res = "wrong"
        o.act = att.fail.inst.act
        o.q = att.fail.inst.start - A
        local eff2 = nil
        for _, t in ipairs(pr) do if t <= att.fail.inst.start then eff2 = t end end
        if k >= 2 and eff2 then o.p = eff2 - A end
        o.hint = "a different move came out and hit"
    elseif att.fail and att.fail.kind == "skipped" then
        o.res = "skipped"
        o.hint = "a different move hit before this step came out"
    elseif att.blocked then
        o.res = "late"
        o.hint = "opponent blocked: they recovered before this hit"
    elseif proc_inst then
        if proc_inst.start >= drop_t then
            o.res = "late"
            o.hint = "came out after the combo ended"
        elseif k == 1 then
            o.res = "whiff"
            o.hint = "first hit never connected"
        else
            o.res = "late"
            o.hint = "came out but did not connect (late or out of range)"
        end
    elseif wrong then
        o.res = "wrong"
        o.act = wrong.act
        o.q = wrong.start - A
        o.hint = "a different action came out"
    elseif #pr == 0 then
        o.res = "missed"
        o.hint = "no input for this step was seen"
    else
        if pr[1] >= drop_t then
            o.res = "late"
            o.hint = "pressed after the opponent recovered"
        else
            o.res = "eaten"
            o.hint = "input pressed but nothing came out"
        end
    end
end

-- Live view for the overlay: resolved steps of the attempt in progress.
function Tracker:live_detail()
    local att = self.att
    if not att then self._live = nil return nil end
    if self._live and not self.live_changed then return self._live end
    self.live_changed = false
    local steps = self.combo.steps
    local out = { c = att.c, failed = att.fail and att.fail.step or nil,
                  success = att.success_t ~= nil, steps = {} }
    for k = 1, math.min(att.c - 1, #steps) do
        local rec = att.st[k]
        if rec and rec.proc then
            local o = { res = "ok" }
            if k >= 2 and att.st[k - 1] then
                local A = att.st[k - 1].proc
                local pr = presses_in(steps[k].trigger or {}, att.frames, A, rec.proc)
                if pr[#pr] then o.p = pr[#pr] - A end
                local w = self.profile and self.profile:window(k)
                if w and o.p then
                    o.off = (o.p < w.E and (o.p - w.E)) or (o.p > w.L and (o.p - w.L)) or 0
                end
            end
            out.steps[k] = o
        end
    end
    if out.failed then out.steps[out.failed] = { res = "pending" } end
    if att.c >= 2 and att.st[att.c - 1] then out.anchor = att.st[att.c - 1].proc end
    self._live = out
    return out
end

-- current game frame (for the overlay's rhythm guide)
function Tracker:now()
    return self.prev and self.prev.t or nil
end

function Tracker:reset_learning()
    self.neutral = {}
    self.att = nil
    self.prev = nil
    self.inst = nil
    self.ring = {}
    self._live = nil
end

return Tracker
