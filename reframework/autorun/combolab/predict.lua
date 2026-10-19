-- ComboLab: predicts a step's press window from game frame data (movedata.lua).
-- Pure Lua. Frames are counted like the profile: d = frames after the previous
-- step's action started, hitstop included.
--
--   A = facts of the previous step's move, B = facts of this step's move
--   A.main   first active frame (0-based; startup = main + 1)
--   A.margin first frame A can act again
--   A.hit    { stun = { st, cr, ch, pc, bl }, stop_o, stop_t } of A's first hit
--   cancel   frame ranges { s, e } (end exclusive) of A that allow B
--
-- Cancel / chain: B is accepted while A is inside a cancel range; frames after
-- A's hit are pushed back by the hitstop.
-- Link: B can come out once A recovers (margin + hitstop); its first active
-- frame has to land before the opponent's hitstun runs out.
-- Calibration (cal) shifts the edges by what measured windows showed.
local Predict = {}

Predict.DQ = 1    -- frames from press to the move starting, until measured

local function hitstop(A)
    if not A or not A.hit or not A.main or A.main < 0 then return 0, 0 end
    return A.hit.stop_o or 0, A.hit.stop_t or A.hit.stop_o or 0
end

-- game frame (from A's start) at which A first shows frame f
local function g(A, f)
    local H = hitstop(A)
    if not A.main or A.main < 0 or f <= A.main then return f end
    return f + H
end

-- sit: "st" (default), "cr", "ch", "pc"
function Predict.window(sep, A, B, cancel, opts)
    opts = opts or {}
    if not A then return nil end
    local dq = opts.dq or Predict.DQ
    local sit = opts.sit or "st"
    local E, L, kind
    local H = hitstop(A)
    local hit_at = (A.main and A.main >= 0) and A.main or nil
    if sep == ">" or sep == "~" then
        if not cancel or #cancel == 0 then return nil end
        for _, r in ipairs(cancel) do
            -- in a combo A has hit, so only the part of a range from the hit on counts
            if not hit_at or r.e > hit_at then
                local s = hit_at and math.max(r.s, hit_at) or r.s
                local last = r.e - 1
                local e_game = g(A, s)
                local l_game = g(A, last) + ((hit_at and last == hit_at) and H or 0)
                if not E or e_game < E then E = e_game end
                if not L or l_game > L then L = l_game end
            end
        end
        if not E then return nil end
        E, L = E - dq, L - dq
        kind = "cancel"
    elseif sep == "," then
        if not A.margin or A.margin <= 0 then return nil end
        E = g(A, A.margin) - dq
        if hit_at and A.hit and A.hit.stun and B and B.main and B.main >= 0 then
            local stun = A.hit.stun[sit] or A.hit.stun.st
            if not stun then return nil end
            local _, Ht = hitstop(A)
            local recover = hit_at + Ht + stun          -- first frame the opponent is free
            L = recover - 1 - B.main - dq
        else
            return nil
        end
        kind = "link"
    else
        return nil
    end
    local cal = opts.cal and opts.cal[kind]
    if cal and (cal.n or 0) >= 3 then
        E = E + math.floor((cal.dE or 0) / cal.n + 0.5)
        L = L + math.floor((cal.dL or 0) / cal.n + 0.5)
    end
    if L < E then return { kind = kind, E = E, L = L, impossible = true } end
    return { kind = kind, E = E, L = L }
end

-- on-hit advantage of A (first active frame hit), for display
function Predict.advantage(A, sit)
    if not A or not A.hit or not A.hit.stun or not A.margin or not A.main or A.main < 0 then return nil end
    local stun = A.hit.stun[sit or "st"] or A.hit.stun.st
    if not stun then return nil end
    local H, Ht = hitstop(A)
    return (A.main + Ht + stun) - (A.margin + H)
end

return Predict
