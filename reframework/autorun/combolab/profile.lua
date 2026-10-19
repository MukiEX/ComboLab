-- ComboLab timing profile: samples per combo step, learned action ids,
-- derived timing windows, and grading of attempts against those windows.
-- Pure Lua (stored as JSON by the REFramework side).
--
-- All per-step timing numbers are in game frames relative to the ANCHOR of the
-- step: the frame the previous step's action started.
--   p  press of this step's trigger         q  this step's action started
--   o  you were free to act (links only)    k  this step connected
--   r  opponent hitstun left just before k  (k + r = when they would have recovered)

local Profile = {}
Profile.__index = Profile

local MAX_SAMPLES = 300
Profile.MAX_SAMPLES = MAX_SAMPLES
Profile.MACHINE = "local"     -- set from config: tags samples recorded on this PC

local function key(a) return tostring(a) end

local function median(t)
    if #t == 0 then return nil end
    table.sort(t)
    local m = (#t + 1) // 2
    if #t % 2 == 1 then return t[m] end
    return (t[m] + t[m + 1]) / 2
end

function Profile.new(combo)
    local self = setmetatable({}, Profile)
    self.combo_id = combo.id
    self.combo_hash = combo.hash
    self.fighter_id = combo.fighter_id
    self.attempts = 0
    self.successes = 0
    self.train_attempts = 0
    self.train_successes = 0
    self.neutral = {}
    self.steps = {}
    for k = 1, #combo.steps do
        self.steps[k] = { label = combo.steps[k].label, ids = {}, tail = {}, samples = {} }
    end
    self.combo = combo
    self._win = {}
    return self
end

-- Rebuild from decoded JSON; returns a fresh profile when it belongs to another
-- version of the combo.
function Profile.from_table(t, combo)
    if type(t) ~= "table" or t.combo_id ~= combo.id or t.combo_hash ~= combo.hash
        or type(t.steps) ~= "table" or #t.steps ~= #combo.steps then
        local fresh = Profile.new(combo)
        -- a reset written while the combo wasn't loaded ({ reset = true })
        if type(t) == "table" and t.reset then fresh.reset_at = tonumber(t.reset_at) or os.time(); return fresh, false end
        return fresh, (type(t) == "table")
    end
    local self = Profile.new(combo)
    self.attempts = tonumber(t.attempts) or 0
    self.successes = tonumber(t.successes) or 0
    self.train_attempts = tonumber(t.train_attempts) or 0
    self.train_successes = tonumber(t.train_successes) or 0
    self.seq = tonumber(t.seq) or 0
    self.reset_at = tonumber(t.reset_at)
    self.shared_rev = t.shared_rev
    if type(t.neutral) == "table" then
        for k, v in pairs(t.neutral) do if v then self.neutral[key(k)] = true end end
    end
    for k = 1, #combo.steps do
        local src = t.steps[k] or {}
        local dst = self.steps[k]
        if type(src.ids) == "table" then for a, n in pairs(src.ids) do dst.ids[key(a)] = tonumber(n) or 0 end end
        if type(src.tail) == "table" then for a, n in pairs(src.tail) do dst.tail[key(a)] = tonumber(n) or 0 end end
        if type(src.samples) == "table" then
            for _, s in ipairs(src.samples) do
                if type(s) == "table" then
                    for f, v in pairs(s) do
                        if type(v) == "number" then s[f] = math.tointeger(v) or v end
                    end
                    dst.samples[#dst.samples + 1] = s
                end
            end
        end
    end
    return self, false
end

function Profile:to_table()
    local out = {
        combo_id = self.combo_id, combo_hash = self.combo_hash, fighter_id = self.fighter_id,
        attempts = self.attempts, successes = self.successes,
        train_attempts = self.train_attempts, train_successes = self.train_successes,
        seq = self.seq or 0, reset_at = self.reset_at, shared_rev = self.shared_rev,
        neutral = self.neutral, steps = {}, windows = {},
    }
    for k, st in ipairs(self.steps) do
        out.steps[k] = { label = st.label, ids = st.ids, tail = st.tail, samples = st.samples }
        local w = self:window(k)
        out.windows[k] = w or { n = 0 }
    end
    return out
end

function Profile:learned_id(k)
    local st = self.steps[k]
    if not st then return nil end
    local best, bn = nil, 0
    for a, n in pairs(st.ids) do
        if n > bn then best, bn = tonumber(a), n end
    end
    return best
end

function Profile:knows_id(k, act)
    local st = self.steps[k]
    return st ~= nil and (st.ids[key(act)] or 0) > 0
end

function Profile:is_tail(k, act)
    local st = self.steps[k]
    return st ~= nil and st.tail[key(act)] ~= nil
end

-- --------------------------------------------------------------------------
-- windows
-- --------------------------------------------------------------------------
function Profile:window(k)
    if k < 2 then return nil end
    if self._win[k] ~= nil then return self._win[k] or nil end
    local st = self.steps[k]
    local step = self.combo.steps[k]
    local w = { n = 0, fails = 0 }
    local qs, os_, ends, ks, slack, dqs = {}, {}, {}, {}, {}, {}
    local ignore_spam = self.ignore_spam ~= false
    for _, s in ipairs(st.samples) do
        local p = s.p
        if s.res == "ok" then
            if p and (s.spam == 0 or not ignore_spam) then
                w.n = w.n + 1
                if not w.E or p < w.E then w.E = p end
                if not w.L or p > w.L then w.L = p end
                if s.r and s.r > 0 and step.sep == "," then
                    local est = p + s.r - 1
                    if not w.L_est or est > w.L_est then w.L_est = est end
                end
            end
            if s.q then qs[#qs + 1] = s.q end
            if s.q and p then dqs[#dqs + 1] = s.q - p end
            if s.o then os_[#os_ + 1] = s.o end
            if s.k then
                ks[#ks + 1] = s.k
                if s.r and s.r > 0 then ends[#ends + 1] = s.k + s.r; slack[#slack + 1] = s.r end
            end
        else
            w.fails = w.fails + 1
            if p and s.res == "early" then
                if not w.E_lo or p > w.E_lo then w.E_lo = p end
            elseif p and s.res == "late" then
                if not w.L_hi or p < w.L_hi then w.L_hi = p end
            end
        end
    end
    if w.n == 0 then
        self._win[k] = false
        return nil
    end
    -- early/late failures inside the observed range are noise from other causes
    if w.E_lo and w.E_lo >= w.E then w.E_lo = nil end
    if w.L_hi and w.L_hi <= w.L then w.L_hi = nil end
    w.E_soft = w.E_lo and (w.E_lo + 1) or w.E
    local ls = w.L
    if w.L_est and w.L_est > ls then ls = w.L_est end
    if w.L_hi and (w.L_hi - 1) < ls then ls = math.max(w.L, w.L_hi - 1) end
    w.L_soft = ls
    if #qs > 0 then table.sort(qs); w.q_min, w.q_max = qs[1], qs[#qs] end
    if #ks > 0 then table.sort(ks); w.k_min, w.k_max = ks[1], ks[#ks] end
    w.o = median(os_)
    w.stun_end = median(ends)
    if #slack > 0 then table.sort(slack); w.slack_min = slack[1] end
    w.width = w.L - w.E + 1
    w.mid = (w.E + w.L) / 2           -- "optimal" press: middle of the clean range
    self:sweet_spot(k, w, ignore_spam)
    w.dq = median(dqs) or 1           -- typical frames from press to the move starting
    self._win[k] = w
    return w
end

-- Downstream-aware sweet spot. Among clean presses of step k, which press
-- frames also let step k+1 succeed? The sweet band is the run of frames around
-- the best smoothed success rate; the target (w.mid) moves to its centre.
-- Needs enough linked samples, otherwise the plain window middle stays.
local SWEET_MIN = 8       -- linked samples before the sweet spot is trusted
local SWEET_TOL = 0.10    -- frames within 10 points of the best rate join the band

function Profile:sweet_spot(k, w, ignore_spam)
    local n, good, total = {}, {}, 0
    for _, s in ipairs(self.steps[k].samples) do
        if s.res == "ok" and s.p and s.nx ~= nil and ((s.spam or 0) == 0 or not ignore_spam) then
            n[s.p] = (n[s.p] or 0) + 1
            good[s.p] = (good[s.p] or 0) + s.nx
            total = total + 1
        end
    end
    w.sweet_n = total
    if total < SWEET_MIN then return end
    -- smoothed rate per frame (neighbours count half), with a weak prior so a
    -- single lucky sample can't dominate
    local rate, support = {}, {}
    local best, best_p = -1, nil
    for p = w.E, w.L do
        local nn = (n[p] or 0) + 0.5 * ((n[p - 1] or 0) + (n[p + 1] or 0))
        local gg = (good[p] or 0) + 0.5 * ((good[p - 1] or 0) + (good[p + 1] or 0))
        support[p] = nn
        if nn >= 1.5 then
            rate[p] = (gg + 0.5) / (nn + 1)
            if rate[p] > best then best, best_p = rate[p], p end
        end
    end
    if not best_p then return end
    local lo, hi = best_p, best_p
    while rate[lo - 1] and rate[lo - 1] >= best - SWEET_TOL do lo = lo - 1 end
    while rate[hi + 1] and rate[hi + 1] >= best - SWEET_TOL do hi = hi + 1 end
    -- overall next-step success inside the window, for comparison
    local all_n, all_g = 0, 0
    for p, c in pairs(n) do all_n = all_n + c; all_g = all_g + good[p] end
    w.sweet_lo, w.sweet_hi = lo, hi
    w.sweet_rate = best
    w.next_rate = all_n > 0 and all_g / all_n or nil
    w.mid = (lo + hi) / 2
end

-- --------------------------------------------------------------------------
-- grading: refine early/late and add frame offsets; apply spam blocker
-- --------------------------------------------------------------------------
function Profile:grade(res, opts)
    opts = opts or {}
    for k, o in pairs(res.steps) do
        local w = self:window(k)
        if w and o.p then
            local off = 0
            if o.p < w.E then off = o.p - w.E elseif o.p > w.L then off = o.p - w.L end
            o.off = off
            if off == 0 then o.zone = "firm"
            elseif o.p >= w.E_soft and o.p <= w.L_soft then o.zone = "soft"
            else o.zone = "out" end
            if o.res == "eaten" or o.res == "wrong" then
                if off < 0 then o.res = (o.res == "wrong") and "wrong" or "early"; o.dir = "early"
                elseif off > 0 then o.res = (o.res == "wrong") and "wrong" or "late"; o.dir = "late"
                else o.hint = (o.hint or "") .. " (timing was inside the window: check direction/motion)" end
            end
        elseif o.res == "eaten" and o.p and o.o and o.p < o.o then
            o.res = "early"
            o.hint = "pressed before you could act"
        end
    end
    if opts.spam_block then
        local last = res.ok and #res.steps or (res.fail_step or 0)
        for k = 1, last do
            local o = res.steps[k]
            if o and (o.spam or 0) > 0 and (res.ok or k < res.fail_step or o.res == "ok") then
                res.ok = false
                res.fail_step = k
                res.spam_fail = true
                o.res = "spam"
                o.hint = string.format("pressed %d extra time%s", o.spam, o.spam == 1 and "" or "s")
                for j = k + 1, #res.steps do res.steps[j] = nil end
                break
            end
        end
    end
    res.result = res.ok and "ok" or (res.steps[res.fail_step] and res.steps[res.fail_step].res or "fail")
    return res
end

-- --------------------------------------------------------------------------
-- learning
-- --------------------------------------------------------------------------
function Profile:learn(res, mode)
    self.seq = (self.seq or 0) + 1
    if mode == "train" then
        self.train_attempts = self.train_attempts + 1
        if res.ok then self.train_successes = self.train_successes + 1 end
    else
        self.attempts = self.attempts + 1
        if res.ok then self.successes = self.successes + 1 end
    end
    if res.neutral then
        for _, a in ipairs(res.neutral) do
            local isstep = false
            for k = 1, #self.steps do if self:learned_id(k) == a then isstep = true end end
            if not isstep then self.neutral[key(a)] = true end
        end
    end
    for k, o in pairs(res.steps) do
        local st = self.steps[k]
        if st then
            if o.res == "ok" then
                if o.act then st.ids[key(o.act)] = (st.ids[key(o.act)] or 0) + 1 end
                if o.tail then
                    local nxt = self:learned_id(k + 1)
                    for _, a in ipairs(o.tail) do
                        if a ~= nxt then st.tail[key(a)] = (st.tail[key(a)] or 0) + 1 end
                    end
                end
            end
            if k >= 2 and o.res ~= "pending" then
                -- downstream outcome: did the NEXT step survive this press timing?
                -- (missed / spammed next inputs are the player's own doing, not
                -- caused by this press, so they don't count either way)
                local nx = nil
                local o2 = res.steps[k + 1]
                if o.res == "ok" and o2 and o2.res ~= "pending" and o2.res ~= "missed" and o2.res ~= "spam" then
                    nx = (o2.res == "ok") and 1 or 0
                end
                st.samples[#st.samples + 1] = {
                    p = o.p, q = o.q, o = o.o, r = o.r, k = o.k, res = o.res,
                    spam = o.spam or 0, mode = mode, act = o.act,
                    a = self.seq, nx = nx, full = res.ok and 1 or 0,
                    t = os.time(), u = Profile.MACHINE .. "-" .. os.time() .. "-" .. self.seq,
                }
                while #st.samples > MAX_SAMPLES do table.remove(st.samples, 1) end
            end
        end
    end
    self._win = {}
end

-- train attempt without adding samples
function Profile:count(res)
    self.train_attempts = self.train_attempts + 1
    if res.ok then self.train_successes = self.train_successes + 1 end
end

function Profile:reset()
    local fresh = Profile.new(self.combo)
    for k, v in pairs(fresh) do self[k] = v end
    -- merging with other machines drops anything recorded before this moment
    self.reset_at = os.time()
end

-- --------------------------------------------------------------------------
-- merging profiles from other machines (same rules as combolab_merge.py)
-- --------------------------------------------------------------------------
local function numstr(v)
    if v == nil then return "-" end
    if type(v) == "number" then return tostring(math.tointeger(v) or v) end
    return tostring(v)
end

-- stable id for a sample; samples from before 1.7 get one from their content
function Profile.sample_uid(k, s)
    if s.u ~= nil then return tostring(s.u) end
    return "L" .. k .. ":" .. numstr(s.a) .. ":" .. numstr(s.p) .. ":" .. numstr(s.q) .. ":" .. tostring(s.res or "-")
end

local function as_list(v) return type(v) == "table" and v or {} end

-- Merges profile table `t` (decoded JSON from the hub) into this profile.
-- Samples are unioned by id; counters and learned ids take the larger value;
-- a newer reset on either side drops everything recorded before it.
-- Returns the number of samples added.
function Profile:merge(t)
    if type(t) ~= "table" or t.combo_id ~= self.combo_id or t.combo_hash ~= self.combo_hash then return 0 end
    local ra, rb = tonumber(self.reset_at) or 0, tonumber(t.reset_at) or 0
    local R = math.max(ra, rb)
    local a_full, b_full = ra == R, rb == R
    local tsteps = as_list(t.steps)
    if not a_full then
        -- the other side reset more recently: keep only our newer samples
        for _, f in ipairs({ "attempts", "successes", "train_attempts", "train_successes", "seq" }) do self[f] = 0 end
        self.neutral = {}
        for _, st in ipairs(self.steps) do st.ids, st.tail = {}, {} end
    end
    if b_full then
        for _, f in ipairs({ "attempts", "successes", "train_attempts", "train_successes", "seq" }) do
            self[f] = math.max(tonumber(self[f]) or 0, tonumber(t[f]) or 0)
        end
        for a in pairs(as_list(t.neutral)) do self.neutral[key(a)] = true end
    end
    if R > 0 then self.reset_at = R end
    local added = 0
    for k, st in ipairs(self.steps) do
        local src = tsteps[k] or {}
        if b_full then
            for a, n in pairs(as_list(src.ids)) do st.ids[key(a)] = math.max(st.ids[key(a)] or 0, tonumber(n) or 0) end
            for a, n in pairs(as_list(src.tail)) do st.tail[key(a)] = math.max(st.tail[key(a)] or 0, tonumber(n) or 0) end
        end
        local seen, out = {}, {}
        local function take(s, mine)
            if type(s) ~= "table" then return end
            if R > 0 and (tonumber(s.t) or 0) < R then return end
            local u = Profile.sample_uid(k, s)
            if seen[u] then return end
            seen[u] = true
            s.u = u
            for f, v in pairs(s) do if type(v) == "number" then s[f] = math.tointeger(v) or v end end
            out[#out + 1] = s
            if not mine then added = added + 1 end
        end
        for _, s in ipairs(st.samples) do take(s, true) end
        for _, s in ipairs(as_list(src.samples)) do take(s, false) end
        table.sort(out, function(x, y)
            local tx, ty = tonumber(x.t) or 0, tonumber(y.t) or 0
            if tx ~= ty then return tx < ty end
            local ax, ay = tonumber(x.a) or 0, tonumber(y.a) or 0
            if ax ~= ay then return ax < ay end
            return x.u < y.u
        end)
        while #out > MAX_SAMPLES do table.remove(out, 1) end
        st.samples = out
    end
    self._win = {}
    return added
end

return Profile
