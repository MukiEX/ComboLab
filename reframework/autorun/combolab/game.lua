-- ComboLab game adapter: reads SF6 battle state through REFramework and turns it
-- into one normalized sample per game frame for the tracker.
--
-- Field names follow the community SF6 scripts (WistfulHopes' info display,
-- Wael3rd's SF6_Tools): gBattle.Player.mcPlayer[i], gBattle.Team.mcTeam[i],
-- cPlayer.mpActParam.ActionPart._Engine, pl_input_new / pl_sw_new, rl_dir.

local Game = {}

local td_gBattle = sdk.find_type_definition("gBattle")
local f_player = td_gBattle and td_gBattle:get_field("Player")
local f_team = td_gBattle and td_gBattle:get_field("Team")

Game.user = 0               -- player index the trainee controls (0 = P1 side)
Game.tick = 0               -- game-frame counter
Game.source = "none"        -- "hook" | "render"
Game.on_sample = nil        -- callback(sample)
Game.last_error = nil
Game.diag = {}

local last_hook_clock = 0
local addr_cache = { [0] = nil, [1] = nil }
local addr_refresh = 0

local function sfix(v)
    if v == nil then return 0 end
    local t = type(v)
    if t == "number" then return v end
    local ok, s = pcall(v.call, v, "ToString()")
    if ok then return tonumber(s) or 0 end
    return 0
end

local function players()
    if not f_player then return nil end
    local sP = f_player:get_data(nil)
    if not sP then return nil end
    return sP.mcPlayer
end

local function teams()
    if not f_team then return nil end
    local sT = f_team:get_data(nil)
    if not sT then return nil end
    return sT.mcTeam
end

-- Training-mode check (cheap, refreshed once a second by the caller)
function Game.in_training()
    local ok, res = pcall(function()
        local tm = sdk.get_managed_singleton("app.training.TrainingManager")
        return tm ~= nil and tm:get_field("_tData") ~= nil
    end)
    return ok and res or false
end

function Game.paused()
    local ok, res = pcall(function()
        local pm = sdk.get_managed_singleton("app.PauseManager")
        if not pm then return false end
        local pb = pm:get_field("_CurrentPauseTypeBit")
        return pb ~= nil and pb ~= 64 and pb ~= 2112
    end)
    return ok and res or false
end

-- FighterID / control type of a side from the training select menu
function Game.side_info(idx)
    local info = {}
    pcall(function()
        local tm = sdk.get_managed_singleton("app.training.TrainingManager")
        local td = tm and tm:get_field("_tData")
        local sm = td and td:get_field("SelectMenu")
        local pd = sm and sm.PlayerDatas and sm.PlayerDatas[idx]
        if pd then
            info.fighter_id = tonumber(pd.FighterID)
            info.modern = tonumber(pd.InputType) == 1
        end
    end)
    return info
end

local function numpad(raw, facing_right)
    local u = (raw & 1) ~= 0
    local d = (raw & 2) ~= 0
    local l = (raw & 4) ~= 0
    local r = (raw & 8) ~= 0
    if not facing_right then l, r = r, l end -- l = back, r = forward
    if u and l then return 7 elseif u and r then return 9 elseif d and l then return 1
    elseif d and r then return 3 elseif u then return 8 elseif d then return 2
    elseif l then return 4 elseif r then return 6 end
    return 5
end

local function read_sample()
    local cp = players()
    if not cp then return nil end
    local ui, oi = Game.user, 1 - Game.user
    local up, op = cp[ui], cp[oi]
    if not up or not op then return nil end

    local eng = up.mpActParam.ActionPart._Engine
    local act = eng:get_ActionID()
    local af = sfix(eng:get_ActionFrame())
    local margin = sfix(eng:get_MarginFrame())

    local raw_dir = (up:get_field("pl_input_new") or 0) & 15
    local sw = up:get_field("pl_sw_new") or 0
    local facing_right = up:get_field("rl_dir") == true

    local cc, dmg = 0, 0
    local ct = teams()
    if ct and ct[ui] then
        cc = ct[ui].mComboCount or 0
        dmg = ct[ui].mComboDamage or 0
    end

    local oact = 0
    pcall(function() oact = op.mpActParam.ActionPart._Engine:get_ActionID() end)
    local ux, ox = 0, 0
    pcall(function() ux = up.pos.x.v / 65536.0; ox = op.pos.x.v / 65536.0 end)
    local s = {
        u = {
            act = act, af = af, margin = margin,
            held = sw & ~15, dir = numpad(raw_dir, facing_right),
            hitstop = up.hit_stop or 0, x = ux, facing_right = facing_right,
            phys = Game.phys_held or 0,   -- buttons from the real controller this frame
        },
        o = {
            stun = op.damage_time or 0,
            hitstop = op.hit_stop or 0,
            guard = op.guard_time or 0,
            act = oact, x = ox,
        },
        cc = cc,
        dmg = dmg,
    }
    return s
end

local function emit(source)
    local ok, s = pcall(read_sample)
    if not ok then
        Game.last_error = tostring(s)
        return
    end
    if not s then return end
    Game.tick = Game.tick + 1
    Game.tick_clock = os.clock()
    s.t = Game.tick
    Game.source = source
    Game.diag = s
    -- light synchronous observer (the bot needs action starts on the same frame)
    if Game.observer then
        local ok2, err = pcall(Game.observer, s)
        if not ok2 then Game.last_error = "observer: " .. tostring(err) end
    end
    -- Only queue here: the hook runs on the game's own update path, so all the
    -- real work (tracking, file writes) happens later in re.on_frame.
    local q = Game.queue
    q[#q + 1] = s
    if #q > 600 then table.remove(q, 1) end
end

Game.queue = {}

-- Process queued samples (call from re.on_frame).
function Game.drain()
    local q = Game.queue
    if #q == 0 then return end
    Game.queue = {}
    if not Game.on_sample then return end
    for i = 1, #q do
        local ok, err = pcall(Game.on_sample, q[i])
        if not ok then Game.last_error = tostring(err) end
    end
end

-- --------------------------------------------------------------------------
-- input injection (training bot)
-- Game.injector(tick) returns (numpad_dir_relative, button_mask) for the frame
-- about to be processed, or nil. Same technique as Wael3rd's SF6_Tools: OR the
-- bits into pl_input_new / pl_sw_new after the game's input update.
-- Absolute direction bits: 1 up, 2 down, 4 left, 8 right.
-- --------------------------------------------------------------------------
local NUMPAD_REL = { [5] = 0, [8] = 1, [2] = 2, [4] = 4, [6] = 8, [7] = 5, [1] = 6, [9] = 9, [3] = 10 }
Game.injector = nil
Game.phys_held = 0

local function inject(p)
    if not p then return end
    local in_raw = p:get_field("pl_input_new") or 0
    local sw_raw = p:get_field("pl_sw_new") or 0
    Game.phys_held = (sw_raw | in_raw) & ~15
    if not Game.injector then return end
    local dir, btn = Game.injector(Game.tick + 1)
    if not dir and not btn then return end
    local d = NUMPAD_REL[dir or 5] or 0
    if p:get_field("rl_dir") ~= true then          -- facing left: forward is left
        local r, l = (d & 8) ~= 0, (d & 4) ~= 0
        d = d & ~12
        if r then d = d | 4 end
        if l then d = d | 8 end
    end
    local m = d | (btn or 0)
    if m == 0 then return end
    p:set_field("pl_input_new", in_raw | m)
    p:set_field("pl_sw_new", sw_raw | m)
end

-- Move both fighters: positions are centre x in stage units (about +-730).
local sfix_from = nil
local function apply_tp(user_x, dummy_x)
    local cp = players()
    if not cp then return false end
    if not sfix_from then
        local t = sdk.find_type_definition("via.sfix")
        sfix_from = t and t:get_method("From(System.Double)")
    end
    if not sfix_from then return false end
    local up, op = cp[Game.user], cp[1 - Game.user]
    if not up or not op or not up.POS_SETx then return false end
    up:POS_SETx(sfix_from:call(nil, user_x))
    op:POS_SETx(sfix_from:call(nil, dummy_x))
    return true
end

-- Moves both fighters. The game can put a position back on the next frame
-- (Wael3rd's SF6_Teleport re-applies for the same reason), so teleport_tick()
-- keeps re-applying for up to 15 frames until both are where they should be.
Game.pending_tp = nil
Game.tp_result = nil
function Game.teleport(user_x, dummy_x)
    local ok = apply_tp(user_x, dummy_x)
    if ok then Game.pending_tp = { ux = user_x, dx = dummy_x, n = 0 } end
    return ok
end

function Game.teleport_tick()
    local p = Game.pending_tp
    if not p then return end
    local cp = players()
    local up, op = cp and cp[Game.user], cp and cp[1 - Game.user]
    local ux, ox
    pcall(function() ux = up.pos.x.v / 65536.0; ox = op.pos.x.v / 65536.0 end)
    if ux and ox and math.abs(ux - p.ux) < 0.5 and math.abs(ox - p.dx) < 0.5 then
        Game.pending_tp, Game.tp_result = nil, "ok"
        return
    end
    p.n = p.n + 1
    if p.n > 15 then
        -- the game may keep a fighter a little off the wall (collision box): close enough counts
        if ux and ox and math.abs(ux - p.ux) < 40 and math.abs(ox - p.dx) < 40 then
            Game.pending_tp, Game.tp_result = nil, "ok"
        else
            Game.pending_tp, Game.tp_result = nil, string.format("didn't stick: you at %.0f, dummy at %.0f, wanted %.0f / %.0f", ux or 0, ox or 0, p.ux, p.dx)
        end
        return
    end
    apply_tp(p.ux, p.dx)
end
Game.STAGE_EDGE = 47841280 / 65536.0

-- per-game-frame tick: post-hook of cPlayer.pl_input_sub for the user's player
local td_cPlayer = sdk.find_type_definition("nBattle.cPlayer")
local m_input = td_cPlayer and td_cPlayer:get_method("pl_input_sub")
Game.hook_ok = m_input ~= nil and not _G.COMBOLAB_NO_HOOK
local hook_this = {}
if Game.hook_ok then
    sdk.hook(m_input,
        function(args)
            if #hook_this > 16 then hook_this = {} end
            hook_this[#hook_this + 1] = Game.enabled and sdk.to_int64(args[2]) or 0
        end,
        function(retval)
            local addr = table.remove(hook_this)
            if not Game.enabled then return retval end
            pcall(function()
                addr_refresh = addr_refresh - 1
                if addr_refresh <= 0 or not addr_cache[Game.user] then
                    addr_refresh = 120
                    local cp = players()
                    for i = 0, 1 do
                        addr_cache[i] = cp and cp[i] and cp[i]:get_address() or nil
                    end
                end
                if addr and addr == addr_cache[Game.user] then
                    last_hook_clock = os.clock()
                    inject(players()[Game.user])
                    emit("hook")
                end
            end)
            return retval
        end)
end

-- Fallback when the hook isn't firing: sample once per rendered frame.
function Game.render_tick()
    if not Game.enabled then return end
    if Game.hook_ok and os.clock() - last_hook_clock < 0.5 then return end
    if Game.paused() then return end
    emit("render")
end

Game.enabled = false

return Game
