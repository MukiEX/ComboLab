-- Frame simulator + tests for the ComboLab tracker/profile.
-- Run: lua tests/sim.lua   (from the project root)
package.path = "reframework/autorun/?.lua;tests/?.lua;" .. package.path
local Tracker = require("combolab.tracker")
local Profile = require("combolab.profile")

local Toy = require("toy")
local LP, MP, HP, LK, MK, HK = Toy.LP, Toy.MP, Toy.HP, Toy.LK, Toy.MK, Toy.HK
local STAND, CROUCH, DR_START, DR_RUN = Toy.STAND, Toy.CROUCH, Toy.DR_START, Toy.DR_RUN
local new_engine, engine_step = Toy.new_engine, Toy.engine_step

-- ---------------------------------------------------------------- bot player
-- plan: list of { btn, dir, delay } ; delay = frames after the previous step's
-- action started (step 1: absolute frame). extra = additional repeated presses
local CLOCK = 0
local function run(tracker, plan, frames)
    local e = new_engine()
    local events = {}
    local k = 1
    local anchor = nil
    local press_at = plan[1].delay
    local pressing = {}     -- t -> {btn, dir}
    local last_act_start = nil
    local results = {}
    local seen_inst_start = {}
    local cur_dir = 5
    local held_until = {}
    local prev_act, prev_af = nil, nil
    for f = 1, frames do
        -- schedule
        if k <= #plan and press_at and e.t + 1 >= press_at then
            local p = plan[k]
            held_until[#held_until + 1] = { btn = p.btn, from = e.t + 1, to = e.t + 2, dir = p.dir or 5 }
            for _, x in ipairs(p.extra or {}) do
                held_until[#held_until + 1] = { btn = p.btn, from = e.t + 1 + x, to = e.t + 2 + x, dir = p.dir or 5 }
            end
            k = k + 1
            press_at = nil
        end
        local held, dir = 0, 5
        for _, h in ipairs(held_until) do
            if e.t + 1 >= h.from and e.t + 1 <= h.to then held = held | h.btn; dir = h.dir end
            if e.t + 1 >= h.from - 2 and e.t + 1 <= h.to then dir = h.dir end
        end
        local s = engine_step(e, held, dir)
        -- detect action starts to set the next anchor
        if prev_act == nil or s.u.act ~= prev_act or s.u.af < prev_af then
            if s.u.act ~= STAND and s.u.act ~= CROUCH and s.u.act ~= DR_RUN then
                if k <= #plan and not press_at then press_at = s.t + plan[k].delay end
            end
        end
        prev_act, prev_af = s.u.act, s.u.af
        local ss = { t = s.t + CLOCK, u = s.u, o = s.o, cc = s.cc }
        local ev = tracker:push(ss)
        if ev then results[#results + 1] = ev.result end
    end
    CLOCK = CLOCK + frames
    return results
end

-- ---------------------------------------------------------------- combo def
local combo = {
    id = "test", version = 1, hash = "h1",
    steps = {
        { label = "2LP", sep = "start", kind = "hit", trigger = { type = "button", mask = LP, mode = "all" } },
        { label = "2LP", sep = ",", kind = "hit", trigger = { type = "button", mask = LP, mode = "all" } },
        { label = "DR", sep = ">", kind = "move", trigger = { type = "button", mask = MP | MK, mode = "all" } },
        { label = "5HP", sep = ">", kind = "hit", trigger = { type = "button", mask = HP, mode = "all" } },
    },
}

local pass, fail = 0, 0
local function check(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. msg) end
end

local function fresh()
    local prof = Profile.new(combo)
    local tr = Tracker.new({})
    tr:set_combo(combo, prof)
    -- idle so neutral ids get learned
    return tr, prof
end

local function plan_for(d2, d3, d4, extra)
    return {
        { btn = LP, dir = 2, delay = 30 },
        { btn = LP, dir = 2, delay = d2, extra = extra and extra[2] },
        { btn = MP | MK, dir = 5, delay = d3, extra = extra and extra[3] },
        { btn = HP, dir = 5, delay = d4, extra = extra and extra[4] },
    }
end

local function attempt(tr, prof, plan, mode, opts)
    local rs = run(tr, plan, 200)
    local r = rs[1]
    if r then
        prof:grade(r, opts)
        prof:learn(r, mode or "develop")
    end
    return r
end

-- 1) calibration run succeeds and learns ids
local tr, prof = fresh()
local r = attempt(tr, prof, plan_for(12, 6, 4))
check(r and r.ok, "calibration run should succeed: " .. tostring(r and r.result) ..
      " step " .. tostring(r and r.fail_step) .. " " .. tostring(r and r.steps[r.fail_step or 1] and r.steps[r.fail_step or 1].hint))
check(prof:learned_id(1) == 100, "step1 id learned = " .. tostring(prof:learned_id(1)))
check(prof:learned_id(2) == 100, "step2 id learned = " .. tostring(prof:learned_id(2)))
check(prof:learned_id(3) == DR_START, "step3 id learned = " .. tostring(prof:learned_id(3)))
check(prof:learned_id(4) == 120, "step4 id learned = " .. tostring(prof:learned_id(4)))
check(prof:is_tail(3, DR_RUN), "DR run learned as tail of step 3")
check(r.steps[4].q and r.steps[4].act == 120, "5HP bound after DR run")

-- 2) sweep link timing for step 2
local truth = {}
for d = 3, 24 do
    local r2 = attempt(tr, prof, plan_for(d, 6, 4))
    local okk = r2 and (r2.ok or (r2.fail_step and r2.fail_step > 2))
    truth[d] = okk and "ok" or (r2 and r2.steps[2] and r2.steps[2].res or "none")
end
local line = {}
for d = 3, 24 do line[#line + 1] = d .. ":" .. truth[d] end
print("step2 sweep: " .. table.concat(line, " "))
local w = prof:window(2)
print(string.format("window step2: E=%s L=%s Esoft=%s Lsoft=%s Lest=%s o=%s stun_end=%s n=%d",
    tostring(w.E), tostring(w.L), tostring(w.E_soft), tostring(w.L_soft), tostring(w.L_est),
    tostring(w.o), tostring(w.stun_end), w.n))
local tE, tL
for d = 3, 24 do if truth[d] == "ok" then tE = tE or d; tL = d end end
check(w.E == tE and w.L == tL, "window matches engine truth " .. tostring(tE) .. ".." .. tostring(tL))
for d = 3, 24 do
    if d < tE then check(truth[d] == "early" or truth[d] == "eaten", "d=" .. d .. " should be early, got " .. truth[d]) end
    if d > tL then check(truth[d] == "late", "d=" .. d .. " should be late, got " .. truth[d]) end
end

-- 3) late DR cancel
local r3 = attempt(tr, prof, plan_for(12, 30, 4))
check(r3 and not r3.ok and r3.fail_step == 3, "late DR fails at step 3: " .. tostring(r3 and r3.fail_step) .. " " .. tostring(r3 and r3.result))

-- 4) spam blocker in train mode
local r4 = attempt(tr, prof, plan_for(12, 6, 4, { [4] = { 4 } }), "train", { spam_block = true })
check(r4 and not r4.ok and r4.result == "spam" and r4.fail_step == 4, "spam on step 4 detected: " .. tostring(r4 and r4.result) .. " step " .. tostring(r4 and r4.fail_step))
local r5 = attempt(tr, prof, plan_for(12, 6, 4, { [4] = { 4 } }), "train", { spam_block = false })
check(r5 and r5.ok, "same input without spam blocker passes")

-- 5) train grading offsets
local r6 = attempt(tr, prof, plan_for(tL + 2, 6, 4), "train", {})
check(r6 and r6.fail_step == 2 and r6.steps[2].off == 2, "late by 2 reported: off=" .. tostring(r6 and r6.steps[2] and r6.steps[2].off))
local r7 = attempt(tr, prof, plan_for(tE - 2, 6, 4), "train", {})
check(r7 and r7.fail_step == 2 and r7.steps[2].off == -2 and r7.steps[2].res == "early",
      "early by 2 reported: off=" .. tostring(r7 and r7.steps[2] and r7.steps[2].off) .. " res=" .. tostring(r7 and r7.steps[2] and r7.steps[2].res))

-- 5b) wrong move: 2MK instead of 2LP on step 2 (learned id mismatch)
local plan_w = plan_for(12, 6, 4); plan_w[2].btn = MK
tr.opts.strict_ids = true
local r8 = attempt(tr, prof, plan_w, "train", {})
tr.opts.strict_ids = false
check(r8 and r8.fail_step == 2 and r8.steps[2].res == "wrong", "wrong button fails step 2: " .. tostring(r8 and r8.steps[2] and r8.steps[2].res))
-- 5c) missed DR entirely
local plan_m = plan_for(12, 6, 4); plan_m[3].btn = 0
local r9 = attempt(tr, prof, plan_m, "train", {})
check(r9 and r9.fail_step == 3 and r9.steps[3].res == "missed", "no DR input -> missed: " .. tostring(r9 and r9.steps[3] and r9.steps[3].res))

-- 6) profile JSON round trip
local t = prof:to_table()
local p2 = Profile.from_table(t, combo)
check(p2:learned_id(4) == 120 and p2:window(2).E == tE, "profile round-trip")


-- 7) downstream-aware sweet spot: late DR presses still cancel but make 5HP drop
do
    local tr2, prof2 = fresh()
    attempt(tr2, prof2, plan_for(12, 6, 4))           -- calibration
    for rep = 1, 3 do
        for d3 = 2, 14 do attempt(tr2, prof2, plan_for(12, d3, 4)) end
    end
    local w3 = prof2:window(3)
    print(string.format("DR window %s..%s  sweet %s..%s (rate %.2f, n=%d)  next ok overall %.2f  target %.1f",
        tostring(w3.E), tostring(w3.L), tostring(w3.sweet_lo), tostring(w3.sweet_hi),
        w3.sweet_rate or -1, w3.sweet_n or 0, w3.next_rate or -1, w3.mid))
    check(w3.sweet_lo and w3.sweet_hi < w3.L, "sweet band ends before the late part of the DR window")
    check(w3.mid < (w3.E + w3.L) / 2, "target moved earlier than the window middle")
    local w4 = prof2:window(4)
    check(w4 and w4.sweet_lo == nil, "last step has no downstream sweet spot")
    -- round trip keeps linked fields
    local p3 = Profile.from_table(prof2:to_table(), combo)
    check(p3:window(3).sweet_hi == w3.sweet_hi, "sweet spot survives save/load")
end

-- 8) a power-up step (no hitbox): as a "hit" step it can only fail; timed as a
--    movement step the combo goes through
do
    local function pcombo(kind)
        return { id = "pw" .. kind, version = 1, hash = "p" .. kind, steps = {
            { label = "2LP", sep = "start", kind = "hit", trigger = { type = "button", mask = LP, mode = "all" } },
            { label = "5HK", sep = ",", kind = kind, trigger = { type = "button", mask = HK, mode = "all" } },
            { label = "2LP", sep = ",", kind = "hit", trigger = { type = "button", mask = LP, mode = "all" } },
        } }
    end
    local plan = { { btn = LP, dir = 2, delay = 30 }, { btn = HK, dir = 5, delay = 13 }, { btn = LP, dir = 2, delay = 3 } }
    for _, kind in ipairs({ "hit", "move" }) do
        local c = pcombo(kind)
        local p = Profile.new(c)
        local tr = Tracker.new({})
        tr:set_combo(c, p)
        local r = run(tr, plan, 200)[1]
        p:learn(r or { steps = {} }, "develop")
        if kind == "hit" then
            check(r and not r.ok,
                "power-up as a hit step drops the combo: " .. tostring(r and r.fail_step) .. " " .. tostring(r and r.steps[2] and r.steps[2].res))
        else
            check(r and r.ok, "power-up as a movement step: combo goes through (" .. tostring(r and r.fail_step) .. " " .. tostring(r and r.steps[r.fail_step or 1] and r.steps[r.fail_step or 1].hint) .. ")")
        end
    end
end

-- 9) a long crumple: the next step 100 frames later is still part of the combo
do
    local c = { id = "crumple", version = 1, hash = "cr", steps = {
        { label = "5MK", sep = "start", kind = "hit", trigger = { type = "button", mask = MK, mode = "all" } },
        { label = "5HK", sep = ",", kind = "move", trigger = { type = "button", mask = HK, mode = "all" } },
        { label = "2LP", sep = ",", kind = "hit", trigger = { type = "button", mask = LP, mode = "all" } },
    } }
    local p = Profile.new(c)
    local tr = Tracker.new({ timeout = 90 })
    tr:set_combo(c, p)
    local r = run(tr, { { btn = MK, dir = 5, delay = 30 }, { btn = HK, dir = 5, delay = 100 }, { btn = LP, dir = 2, delay = 3 } }, 300)[1]
    check(r and r.ok, "crumple: a slow follow-up isn't a timeout (" .. tostring(r and r.fail_step) .. " " .. tostring(r and r.steps[r.fail_step or 1] and r.steps[r.fail_step or 1].res) .. ")")
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
