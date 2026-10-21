-- Toy fighting-game engine used by the tests.
local M = {}
local LP, MP, HP, LK, MK, HK = 16, 32, 64, 128, 256, 512

-- ---------------------------------------------------------------- toy engine
local MOVES = {
    ["2LP"] = { id = 100, btn = LP, dir = 2, startup = 4, active = 2, rec = 7, stun = 18, cancel = { 4, 12 } },
    ["5LK"] = { id = 110, btn = LK, dir = 5, startup = 5, active = 2, rec = 10, stun = 16, cancel = { 5, 14 } },
    ["5HP"] = { id = 120, btn = HP, dir = 5, startup = 6, active = 3, rec = 20, stun = 24, cancel = { 8, 18 } },
    ["2MK"] = { id = 130, btn = MK, dir = 2, startup = 7, active = 2, rec = 12, stun = 14, cancel = nil },
    -- a crumple: the opponent reels for a long time
    ["5MK"] = { id = 160, btn = MK, dir = 5, startup = 6, active = 2, rec = 14, stun = 150, cancel = nil },
    -- a power-up with no hitbox (like Juri's Feng Shui Engine activation)
    ["5HK"] = { id = 150, btn = HK, dir = 5, startup = 2, active = 0, rec = 1, stun = 0, cancel = nil, nohit = true },
}
local STAND, CROUCH, DR_START, DR_RUN = 1, 2, 50, 51
-- jumping: 4 frames of prejump, 36 in the air covering JUMP_DIST, 3 of landing.
-- j.HP comes out in the air; it only reaches the opponent on the way down
-- (air frame >= 20) and within 55 units, and hits harder the deeper it is.
local JUMP_PRE, JUMP_AIR, JUMP_LAND, JUMP_DIST = 60, 61, 62, 160
local AIRMOVE = { id = 140, btn = HP, startup = 7, active = 6 }
local BUFFER = 4

local function new_engine()
    return { t = 0, act = STAND, af = 0, inst_hit = false, opp_stun = 0, cc = 0, guard = 0,
             buf = {}, held = 0, dir = 5, mv = nil, dr_t = 0, x = 0, ox = 100, air = nil }
end

local function find_move(btn, dir)
    for name, m in pairs(MOVES) do
        if m.btn == btn and ((m.dir == 2) == (dir == 1 or dir == 2 or dir == 3)) then return name, m end
    end
end

local function start(e, id, mv)
    e.act, e.af, e.mv, e.inst_hit = id, 0, mv, false
end

-- one frame: input (held, dir) -> state sample
local function engine_step(e, held, dir)
    e.t = e.t + 1
    local rise = held & ~e.held
    e.held, e.dir = held, dir
    if rise ~= 0 then e.buf[#e.buf + 1] = { t = e.t, rise = rise, dir = dir } end
    while #e.buf > 0 and e.t - e.buf[1].t > BUFFER do table.remove(e.buf, 1) end

    -- opponent
    if e.guard > 0 then e.guard = e.guard - 1 end
    if e.opp_stun > 0 then
        e.opp_stun = e.opp_stun - 1
        if e.opp_stun == 0 then e.cc = 0 end
    end

    -- jumping (its own little state machine)
    if e.air or e.act == JUMP_PRE or e.act == JUMP_LAND then
        e.af = e.af + 1
        if e.act == JUMP_PRE then
            if e.af >= 4 then e.act, e.af, e.air = JUMP_AIR, 0, { f = 0, atk = nil, sign = (e.ox >= e.x) and 1 or -1 } end
        elseif e.act == JUMP_LAND then
            if e.af >= 3 then e.act, e.af = STAND, 0 end
        end
        if e.air then
            local a = e.air
            a.f = a.f + 1
            e.x = e.x + a.sign * JUMP_DIST / 36       -- direction fixed at takeoff
            -- air attack
            if not a.atk and rise & HP ~= 0 then a.atk = { af = 0, hit = false }; e.act, e.af = AIRMOVE.id, 0 end
            if a.atk then
                a.atk.af = a.atk.af + 1
                e.af = a.atk.af
                local k = a.atk.af
                if not a.atk.hit and k >= AIRMOVE.startup and k < AIRMOVE.startup + AIRMOVE.active
                    and a.f >= 20 and math.abs(e.ox - e.x) <= 55 then
                    a.atk.hit = true
                    e.opp_stun = 16 + (a.f - 20) * 2
                    e.cc = e.cc + 1
                    e.started_combo = true
                end
            end
            if a.f >= 36 then e.air = nil; e.act, e.af, e.mv = JUMP_LAND, 0, nil end
        end
        local margin = 0
        return {
            t = e.t,
            u = { act = e.act, af = e.af, margin = margin, held = held, dir = dir },
            o = { stun = e.opp_stun, hitstop = 0, guard = e.guard },
            cc = e.cc,
        }
    end

    -- advance current action
    e.af = e.af + 1
    local free, cancel_ok, dr_ok = false, false, false
    if e.mv then
        local m = e.mv
        local total = m.startup + m.active + m.rec
        if e.af >= total then free = true end
        if m.cancel and e.inst_hit and e.af >= m.cancel[1] and e.af <= m.cancel[2] then cancel_ok = true end
    elseif e.act == DR_START then
        if e.af >= 4 then start(e, DR_RUN, nil) end
    elseif e.act == DR_RUN then
        if e.af >= 1 then cancel_ok = true; e.run_cancel = true end
        if e.af >= 25 then free = true end
    else
        free = true
    end

    -- jump from neutral
    if free and not e.mv and e.act ~= DR_RUN and (dir == 7 or dir == 8 or dir == 9) then
        e.act, e.af, e.mv, e.buf = JUMP_PRE, 0, nil, {}
        return { t = e.t, u = { act = e.act, af = 0, margin = 0, held = held, dir = dir },
                 o = { stun = e.opp_stun, hitstop = 0, guard = e.guard }, cc = e.cc }
    end

    -- consume buffered input
    local took = false
    for i = #e.buf, 1, -1 do
        local b = e.buf[i]
        local chord = (e.held & (MP | MK)) == (MP | MK)
        if chord and (b.rise & (MP | MK)) ~= 0 and cancel_ok and e.mv then
            start(e, DR_START, nil); took = true; e.buf = {}; break
        end
        if free or (cancel_ok and e.act == DR_RUN) then
            local name, m = find_move(b.rise & ~(MP | MK) ~= 0 and (b.rise & (LP | HP | LK | MK | HP)) or b.rise, b.dir)
            if not m then name, m = find_move(b.rise, b.dir) end
            if m and not chord then start(e, m.id, m); took = true; e.buf = {}; break end
        end
    end
    if not took and free and (e.mv or e.act == DR_RUN) then
        e.mv = nil
        e.act = (dir <= 3) and CROUCH or STAND
        e.af = 0
    elseif not took and not e.mv and (e.act == STAND or e.act == CROUCH) then
        local want = (dir <= 3) and CROUCH or STAND
        if want ~= e.act then e.act, e.af = want, 0 end
    end

    -- hit check on first active frame
    if e.mv and not e.mv.nohit and not e.inst_hit and e.af == e.mv.startup then
        if e.cc == 0 and e.opp_stun == 0 and e.started_combo then
            e.guard = 10  -- opponent recovered: blocks
            e.started_combo = false
        else
            e.inst_hit = true
            e.opp_stun = e.mv.stun
            e.cc = e.cc + 1
            e.started_combo = true
        end
    end
    if e.cc == 0 and e.opp_stun == 0 and e.guard == 0 then e.started_combo = false end

    local margin = e.mv and (e.mv.startup + e.mv.active + e.mv.rec) or 0
    return {
        t = e.t,
        u = { act = e.act, af = e.af, margin = margin, held = held, dir = dir },
        o = { stun = e.opp_stun, hitstop = 0, guard = e.guard },
        cc = e.cc,
    }
end


M.new_engine, M.engine_step, M.MOVES = new_engine, engine_step, MOVES
M.LP, M.MP, M.HP, M.LK, M.MK, M.HK = LP, MP, HP, LK, MK, HK
M.STAND, M.CROUCH, M.DR_START, M.DR_RUN = STAND, CROUCH, DR_START, DR_RUN
M.JUMP_PRE, M.JUMP_AIR, M.JUMP_LAND, M.AIRMOVE, M.JUMP_DIST = JUMP_PRE, JUMP_AIR, JUMP_LAND, AIRMOVE, JUMP_DIST
return M
