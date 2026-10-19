-- ComboLab in-game overlay (REFramework draw + imgui).
local Overlay = {}

local function rgba(r, g, b, a) return ((a or 255) << 24) | (b << 16) | (g << 8) | r end

local C = {
    white   = rgba(240, 240, 240),
    dim     = rgba(150, 150, 160),
    sep     = rgba(110, 110, 120),
    yellow  = rgba(255, 214, 64),
    green   = rgba(80, 230, 120),
    red     = rgba(255, 64, 64),
    magenta = rgba(240, 90, 220),
    cyan    = rgba(0, 235, 245),
    cyan_d  = rgba(0, 150, 160, 150),
    bg      = rgba(10, 12, 18, 170),
    bg_hi   = rgba(40, 44, 60, 200),
    shadow  = rgba(0, 0, 0, 220),
    orange  = rgba(255, 150, 40),
    panel   = rgba(0, 0, 0, 165),
    sweet   = rgba(225, 255, 255, 235),
}
Overlay.C = C

-- Fonts are loaded once when the script loads (REFramework can't add fonts to
-- ImGui's atlas mid-frame), then the nearest preloaded size is used.
local FONT_SIZES = { 18, 24, 32, 40 }
local fonts = {}
Overlay.fonts_ok = false
for _, px in ipairs(FONT_SIZES) do
    local ok, f = pcall(imgui.load_font, nil, px)
    if ok and f ~= nil then fonts[px] = f; Overlay.fonts_ok = true end
end
local function font(px)
    local best, bd = nil, math.huge
    for size, f in pairs(fonts) do
        local d = math.abs(size - px)
        if d < bd then best, bd = f, d end
    end
    return best
end

local RES_COLOR = {
    ok = C.green, late = C.red, early = C.red, wrong = C.red, missed = C.red,
    eaten = C.red, whiff = C.red, skipped = C.red, spam = C.magenta, pending = C.white,
}
local RES_TEXT = {
    late = "LATE", early = "EARLY", wrong = "WRONG MOVE", missed = "MISSED INPUT",
    eaten = "INPUT EATEN", whiff = "WHIFF", skipped = "SKIPPED", spam = "SPAM",
}
Overlay.RES_TEXT = RES_TEXT

-- --------------------------------------------------------------------------
-- text helpers (inside the full-screen imgui window)
-- --------------------------------------------------------------------------
local function text_at(x, y, s, col, f)
    s = tostring(s):gsub("%%", "%%%%")   -- ImGui treats % as a format code
    if f then imgui.push_font(f) end
    imgui.set_cursor_pos(Vector2f.new(x + 2, y + 2))
    imgui.text_colored(s, C.shadow)
    imgui.set_cursor_pos(Vector2f.new(x, y))
    imgui.text_colored(s, col)
    if f then imgui.pop_font() end
end

local function panel(x, y, w, h)
    draw.filled_rect(x, y, w, h, C.panel)
end

local function measure(s, f)
    if f then imgui.push_font(f) end
    local v = imgui.calc_text_size(s)
    if f then imgui.pop_font() end
    return v.x, v.y
end

local function with_alpha(col, a)
    local al = math.max(0, math.min(255, math.floor(((col >> 24) & 255) * a)))
    return (col & 0x00FFFFFF) | (al << 24)
end

-- --------------------------------------------------------------------------
-- motion arrows: labels laid out as glyph + text items
-- --------------------------------------------------------------------------
local Motion = require("combolab.motion")
local glyph_cache = {}
local function glyph_of(p)
    local key = p.t .. ":" .. tostring(p.seq or p.d or "")
    local g = glyph_cache[key]
    if not g then g = Motion.glyph(p); glyph_cache[key] = g end
    return g
end

-- items: { t = "text", s, w } | { t = "glyph", g, w, gh, pad }
local function rich(label, f, arrows)
    label = tostring(label or "")
    if not arrows then
        local w = measure(label, f)
        return { { t = "text", s = label, w = w } }, w
    end
    local _, th = measure("Ag", f)
    local gh = th * 0.92
    local items, total = {}, 0
    for _, p in ipairs(Motion.parse(label)) do
        local it
        if p.t == "text" then
            it = { t = "text", s = p.s, w = measure(p.s, f) }
        else
            local g = glyph_of(p)
            it = { t = "glyph", g = g, gh = gh, pad = th * 0.07, w = gh * g.aspect + th * 0.14 }
        end
        items[#items + 1] = it
        total = total + it.w
    end
    return items, total
end
Overlay.rich = rich

local function alpha_of(col) return ((col >> 24) & 255) / 255 end

local function stroke(pts, w, col)
    local r = w / 2
    for i = 1, #pts - 3, 2 do
        local x1, y1, x2, y2 = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
        local dx, dy = x2 - x1, y2 - y1
        local l = math.sqrt(dx * dx + dy * dy)
        if l > 0.01 then
            local nx, ny = -dy / l * r, dx / l * r
            if draw.filled_quad then
                draw.filled_quad(x1 + nx, y1 + ny, x2 + nx, y2 + ny, x2 - nx, y2 - ny, x1 - nx, y1 - ny, col)
            else
                draw.line(x1, y1, x2, y2, col, w)
            end
        end
    end
    for i = 1, #pts, 2 do draw.filled_circle(pts[i], pts[i + 1], r, col, 12) end
end

-- draws one glyph with its top-left at (x, y), height h
local function draw_glyph(g, x, y, h, col)
    local sw = math.max(2, h * 0.16)
    local hl, hw = sw * 2.0, sw * 1.65               -- arrowhead length / half width
    local ol = math.max(1.5, sw * 0.35)              -- dark outline
    local dark = with_alpha(rgba(0, 0, 0, 230), alpha_of(col))
    local hx, hy = x + g.head[1] * h, y + g.head[2] * h
    local dx, dy = g.head[3], g.head[4]
    local px = {}
    for i, l in ipairs(g.lines) do
        local q = {}
        for j = 1, #l, 2 do q[j] = x + l[j] * h; q[j + 1] = y + l[j + 1] * h end
        if i == 1 then
            -- pull the stroke back so it ends inside the arrowhead
            local cut = hl * 0.6
            while #q > 2 and math.sqrt((q[#q - 1] - hx) ^ 2 + (q[#q] - hy) ^ 2) < cut do q[#q] = nil; q[#q] = nil end
            q[#q + 1] = hx - dx * cut; q[#q + 1] = hy - dy * cut
        end
        px[i] = q
    end
    local function head(grow, c)
        local bx, by = hx - dx * hl, hy - dy * hl
        local nx, ny = -dy, dx
        local tx, ty = hx + dx * grow * 1.6, hy + dy * grow * 1.6
        local w = hw + grow
        local ax, ay = bx - dx * grow + nx * w, by - dy * grow + ny * w
        local cx, cy = bx - dx * grow - nx * w, by - dy * grow - ny * w
        if draw.filled_quad then
            draw.filled_quad(tx, ty, ax, ay, bx + dx * hl * 0.25, by + dy * hl * 0.25, cx, cy, c)
        else
            draw.line(ax, ay, tx, ty, c, sw); draw.line(cx, cy, tx, ty, c, sw)
        end
    end
    for _, q in ipairs(px) do stroke(q, sw + ol * 2, dark) end
    head(ol, dark)
    for _, q in ipairs(px) do stroke(q, sw, col) end
    head(0, col)
end

-- glyph pass (draw layer) and text pass (imgui layer) for a laid-out label
local function rich_glyphs(items, x, y, th, col)
    for _, it in ipairs(items) do
        if it.t == "glyph" then draw_glyph(it.g, x + it.pad, y + (th - it.gh) / 2, it.gh, col) end
        x = x + it.w
    end
end
local function rich_text(items, x, y, col, f)
    for _, it in ipairs(items) do
        if it.t == "text" then text_at(x, y, it.s, col, f) end
        x = x + it.w
    end
end

local function fmt_range(a, b)
    if a == nil then return "-" end
    if b == nil or a == b then return tostring(math.floor(a)) end
    return string.format("%d..%d", math.floor(a), math.floor(b))
end

-- --------------------------------------------------------------------------
-- timeline bar
-- --------------------------------------------------------------------------
local function draw_segment(x, y, w, h, k, S, press, sc)
    local win = S.profile and S.profile:window(k) or nil
    local vals = {}
    local function add(v) if v then vals[#vals + 1] = v end end
    if win then add(win.E_soft); add(win.L_soft); add(win.E); add(win.L) end
    if press then add(press.p) end
    local lo, hi = 0, 20
    if #vals > 0 then
        lo, hi = math.huge, -math.huge
        for _, v in ipairs(vals) do lo = math.min(lo, v); hi = math.max(hi, v) end
        lo, hi = lo - 3, hi + 3
        if hi - lo < 12 then local m = (hi + lo) / 2; lo, hi = m - 6, m + 6 end
    end
    local span = hi - lo + 1
    local function fx(f) return x + (f - lo) / span * w end
    local cell = w / span

    draw.filled_rect(x, y, w, h, C.bg)
    if win and win.pred then
        -- predicted from frame data, nothing measured yet: hollow window
        draw.filled_rect(fx(win.E), y, (win.L - win.E + 1) * cell, h, rgba(0, 235, 245, 55))
        draw.outline_rect(fx(win.E), y + 1, (win.L - win.E + 1) * cell, h - 2, C.cyan)
    elseif win then
        draw.filled_rect(fx(win.E_soft), y, (win.L_soft - win.E_soft + 1) * cell, h, C.cyan_d)
        draw.filled_rect(fx(win.E), y, (win.L - win.E + 1) * cell, h, C.cyan)
        if win.sweet_lo then
            -- the part of the window that also keeps the NEXT step alive
            draw.filled_rect(fx(win.sweet_lo), y + h * 0.2, (win.sweet_hi - win.sweet_lo + 1) * cell, h * 0.6, C.sweet)
        end
        if S.mode == "develop" then
            -- sample ticks: successes on top edge, failures on bottom edge
            local samples = S.profile.steps[k].samples
            for i = math.max(1, #samples - 40), #samples do
                local s = samples[i]
                if s.p and s.p >= lo and s.p <= hi then
                    local col = s.res == "ok" and C.green or C.red
                    local yy = s.res == "ok" and (y - 4 * sc) or (y + h + 1 * sc)
                    draw.filled_rect(fx(s.p) + cell * 0.25, yy, math.max(2, cell * 0.5), 3 * sc, col)
                end
            end
            if win.o and win.o >= lo and win.o <= hi then
                draw.filled_rect(fx(win.o), y, math.max(1, 2 * sc), h, C.yellow)
            end
        end
    end
    -- frame grid ticks every 5 frames
    for f = math.ceil(lo / 5) * 5, hi, 5 do
        draw.filled_rect(fx(f) + cell * 0.5, y + h - 3 * sc, 1, 3 * sc, rgba(255, 255, 255, 70))
    end
    if press and press.p then
        local col = C.white
        if press.res and press.res ~= "ok" and press.res ~= "pending" then col = RES_COLOR[press.res] or C.red
        elseif press.off and press.off ~= 0 then col = C.yellow
        elseif press.res == "ok" then col = C.green end
        local px = fx(press.p) + cell * 0.5
        draw.filled_rect(px - 2.5 * sc, y - 3 * sc, 5 * sc, h + 6 * sc, rgba(0, 0, 0, 200))
        draw.filled_rect(px - 1.5 * sc, y - 2 * sc, 3 * sc, h + 4 * sc, col)
        if press.off and press.off ~= 0 then
            press.label_x = px
        end
    end
    -- optimal-press target: a small notch above and below the middle of the window
    if win and win.mid and S.cfg.rhythm ~= false then
        local mx = fx(win.mid) + cell * 0.5
        draw.filled_rect(mx - 1.5 * sc, y - 6 * sc, 3 * sc, 5 * sc, C.white)
        draw.filled_rect(mx - 1.5 * sc, y + h + 1 * sc, 3 * sc, 5 * sc, C.white)
    end
    return lo, hi, fx, cell
end

-- Glowing playhead at frame `f` of a segment. Brightest when it crosses the
-- optimal (mid-window) frame; pulses gently while travelling.
-- glowing line at screen x; `near` (0..1) brightens it, `big` scales it up
local function draw_playhead_x(x, y, h, sc, near, demo, big)
    local t = os.clock()
    local pulse = 0.65 + 0.35 * math.sin(t * math.pi * 4)
    local a = (demo and 0.55 or 1.0)
    local g = big or 1
    local glow_a = math.floor(255 * a * math.min(1, (0.25 + 0.35 * pulse + 0.4 * near) * (big and 1.25 or 1)))
    -- glow halo (widest, faintest first)
    local rings = big and 6 or 4
    for i = rings, 1, -1 do
        local ww = (2 + i * 3.5 * (1 + near)) * sc * g
        local al = math.floor(glow_a / (i + 0.5))
        draw.filled_rect(x - ww / 2, y - (3 + i) * sc * g, ww, h + (6 + 2 * i) * sc * g, rgba(120, 240, 255, al))
    end
    local core = near > 0.5 and rgba(255, 255, 255, math.floor(255 * a)) or rgba(170, 250, 255, math.floor(230 * a))
    local cw = 3 * sc * g
    draw.filled_rect(x - cw / 2, y - 4 * sc * g, cw, h + 8 * sc * g, core)
end

local function draw_playhead(f, lo, hi, fx, cell, y, h, sc, win, demo, big)
    if f < lo or f > hi + 1 then return end
    local x = fx(f) + cell * 0.5
    local near = 0
    if win and win.mid then
        local d = math.abs(f - win.mid)
        near = math.max(0, 1 - d / 1.5)          -- flash on the optimal frame
        if f >= win.E and f <= win.L + 1 then near = math.max(near, 0.35) end
    end
    draw_playhead_x(x, y, h, sc, near, demo, big)
end

-- --------------------------------------------------------------------------
-- rhythm guide
--   live: once step k-1's move has started, a playhead runs through segment k
--         in real game frames and lights up on the optimal press frame.
--   idle: a dimmer looping demo plays the whole combo's cadence, chaining each
--         step's optimal press + its usual press-to-startup delay.
-- --------------------------------------------------------------------------
local demo_t0 = nil
function Overlay.rhythm(S, geo, live, by, bh, sc)
    local P = S.profile
    if not P then return end
    if S.song and not (S.cfg.song_follow and live) then
        demo_t0 = nil
        local now = S.tracker:now()
        if not now then return end
        local fnow = now + math.max(0, math.min(1, (os.clock() - (S.tick_clock or os.clock())) * 60))
        local N = #S.combo.steps
        local T = S.song.T
        local BIG = 1.6
        local lead = geo.lead
        if lead and fnow < T[1] then
            -- count-in: travel across the lead-in and reach step 1 on the downbeat
            local u = (fnow - S.song.t0) / math.max(1, T[1] - S.song.t0)
            local beat_near = math.max(0, 1 - ((S.song.beat_phase or 0) * 4))
            draw_playhead_x(lead.x + u * (lead.mx - lead.x), by, bh, sc, beat_near * 0.6, false, BIG)
            return
        end
        if lead and fnow < T[1] + 8 then
            draw_playhead_x(lead.mx, by, bh, sc, math.max(0, 1 - (fnow - T[1]) / 8), false, BIG)
            return
        end
        for k = N, 2, -1 do
            local w = P:window(k)
            local anchor = T[k] - w.mid
            if fnow >= anchor + geo[k].lo then
                if fnow <= T[k] + (w.L - w.mid) + 8 then
                    draw_playhead(fnow - anchor, geo[k].lo, geo[k].hi, geo[k].fx, geo[k].cell, by, bh, sc, w, false, BIG)
                end
                break
            end
        end
        return
    end
    if live then
        demo_t0 = nil
        local k = live.c
        local g = geo[k]
        local now = S.tracker:now()
        if g and live.anchor and now and not live.failed and not live.success then
            draw_playhead(now - live.anchor, g.lo, g.hi, g.fx, g.cell, by, bh, sc, P:window(k), false)
        end
        return
    end
    if S.cfg.rhythm_demo == false or S.cfg.song_mode then return end
    -- build the demo timeline (frames from the combo's first move)
    local N = #S.combo.steps
    local anchors, A, have = {}, 0, 0
    for k = 2, N do
        local w = P:window(k)
        if w then
            have = have + 1
            anchors[k] = A
            A = A + w.mid + (w.dq or 1)
        end
    end
    if have < N - 1 then
        -- say why there's no preview instead of silently showing nothing
        return string.format("rhythm preview: %d/%d steps timed - finish them in Develop (F5)", have, N - 1)
    end
    local total = A + 45                    -- short rest before looping
    demo_t0 = demo_t0 or os.clock()
    local f = ((os.clock() - demo_t0) * 60) % total
    for k = 2, N do
        local nxt = (k < N) and anchors[k + 1] or (anchors[k] + P:window(k).L + 6)
        if f >= anchors[k] + geo[k].lo and f < nxt + geo[k].lo then
            draw_playhead(f - anchors[k], geo[k].lo, geo[k].hi, geo[k].fx, geo[k].cell, by, bh, sc, P:window(k), true)
            break
        end
    end
end


-- --------------------------------------------------------------------------
-- Song mode (Train): instead of waiting for the first hit, a count-in plays
-- and the whole combo is laid out on a fixed timeline at its ideal cadence
-- (each step's target frame + typical startup), notes visible from further out.
-- "Follow my hits" re-times the remaining notes from the moves that came out.
-- --------------------------------------------------------------------------
function Overlay.song_update(S, live, now)
    local cfg = S.cfg
    if not (S.mode == "train" and cfg.song_mode and S.combo and S.profile) or not now then
        S.song, S.song_hint = nil, nil
        return
    end
    local P, steps = S.profile, S.combo.steps
    local N = #steps
    for k = 2, N do
        if not P:window(k) then
            S.song = nil
            S.song_hint = string.format("song mode needs every step timed (%d/%d) - run the bot or Develop", k - 2, N - 1)
            return
        end
    end
    S.song_hint = nil
    local song = S.song
    -- finish: after the last note and once the attempt is over, re-arm when idle
    if song and not live and now > song.T[N] + 30 and (S.result_age or 99) > 1.0 then song = nil end
    if song and not live and now > song.T[N] + 240 then song = nil end
    if not song then
        if live or (S.result_age or 99) < 1.0 then S.song = nil return end
        local B = math.max(12, cfg.song_beat or 30)
        song = { t0 = now, B = B, T = {} }
        song.T[1] = now + 4 * B
        local prev_dq = 1
        for k = 2, N do
            local w = P:window(k)
            song.T[k] = song.T[k - 1] + prev_dq + w.mid
            prev_dq = w.dq or 1
        end
        song.fixed = {}
        for k = 1, N do song.fixed[k] = song.T[k] end
    end
    -- follow my hits: re-time the notes still ahead from the real anchor
    if cfg.song_follow and live and live.anchor and live.c and live.c >= 2 and live.c <= N and not live.failed then
        local w = P:window(live.c)
        song.T[live.c] = live.anchor + w.mid
        for j = live.c + 1, N do
            local wj, wp = P:window(j), P:window(j - 1)
            song.T[j] = song.T[j - 1] + (wp.dq or 1) + wj.mid
        end
    end
    -- count-in text: 3, 2, 1 on the beats before step 1
    local beat = math.floor((now - song.t0) / song.B)
    song.count = (beat >= 1 and beat <= 3) and tostring(4 - beat) or nil
    song.beat_phase = ((now - song.t0) % song.B) / song.B
    S.song = song
end

-- --------------------------------------------------------------------------
-- "Spearmint Twintails" note view (Train): each upcoming step is a note that
-- flies in along a curve and lands on the target ring exactly on that step's
-- target frame (middle of its sweet spot / window). A countdown hand sweeps the
-- ring and passes through the window, drawn as an arc at 12 o'clock.
-- Timeline: T[c] = anchor(c-1) + target[c]; later notes are predicted from each
-- step's typical press-to-startup delay, then corrected as the moves come out.
-- --------------------------------------------------------------------------
local PALETTES = {
    classic = { L = rgba(240, 70, 70), M = rgba(245, 245, 245), H = rgba(70, 130, 255) },   -- red / white / blue
    sf6     = { L = rgba(80, 205, 240), M = rgba(245, 215, 60), H = rgba(240, 75, 75) },     -- blue / yellow / red
}
local NOTE = { DR = rgba(110, 235, 140), SP = rgba(205, 140, 255), X = rgba(200, 200, 210) }
local cur_palette = PALETTES.classic
local NAMED = { DR = true, DI = true, PARRY = true, ["66"] = true, THROW = true }

local function note_kind(label)
    local l = tostring(label):upper():gsub("^J%.", "")
    if NAMED[l] or l:find("^SA") or l:find("^LVL") or l:find("^CA") then return nil, l end
    local b = l:gsub("[%d%[%]~]", "")
    local p, k = b:find("P") ~= nil, b:find("K") ~= nil
    return (p and not k) and "P" or ((k and not p) and "K" or nil), l
end

local function note_color(label)
    local _, l = note_kind(label)
    if l == "DR" or l == "DI" or l == "PARRY" or l == "66" then return NOTE.DR end
    if l:find("^SA") or l:find("^LVL") or l:find("^CA") then return NOTE.SP end
    local b = l:gsub("[%d%[%]~]", "")
    local strengths = {}
    for st in b:gmatch("([LMH])[PK]") do strengths[#strengths + 1] = st end
    if #strengths >= 2 or b:find("PP") or b:find("KK") then return NOTE.SP end   -- OD / multi-button
    return cur_palette[strengths[1] or ""] or NOTE.X
end

-- which way a note enters: punches from the left, kicks from the right,
-- anything else (Drive Rush, DI, supers, dashes) rises from below
local function note_side(label, flip)
    local kind = note_kind(label)
    local side = (kind == "P" and -1) or (kind == "K" and 1) or 0
    if flip then side = -side end
    return side
end

local judge_log = {}      -- [step] = { t = clock, text, col }
local judge_key = nil

local function ring_dots(cx, cy, r, a0, a1, col, dot, n)
    -- angles in radians, 0 = 12 o'clock, clockwise
    n = n or math.max(2, math.floor(math.abs(a1 - a0) * r / (dot * 1.6)))
    for i = 0, n do
        local a = a0 + (a1 - a0) * i / n
        draw.filled_circle(cx + math.sin(a) * r, cy - math.cos(a) * r, dot, col, 10)
    end
end

function Overlay.notes(S, W, H, sc, top)
    cur_palette = PALETTES[S.cfg.note_palette or "classic"] or PALETTES.classic
    local P, combo = S.profile, S.combo
    local steps = combo.steps
    local N = #steps
    local cfg = S.cfg
    local A = cfg.note_approach or 36               -- frames of flight
    local R = 34 * sc                               -- target ring radius
    local cx, cy = W / 2, top + R + 6 * sc
    local labels = {}
    local live = S.tracker:live_detail()
    local now = S.tracker:now() or 0
    local fnow = now + math.max(0, math.min(1, (os.clock() - (S.tick_clock or os.clock())) * 60))
    local clock = os.clock()

    -- judgements from the attempt in progress (or the last one)
    local shown = live or S.last
    local key = live and ("L" .. tostring(live.anchor or 0) .. tostring(S.attempt_seq or 0)) or ("R" .. tostring(S.attempt_seq or 0))
    if shown and shown.steps then
        for k, o in pairs(shown.steps) do
            local id = tostring(S.attempt_seq or 0) .. ":" .. k
            if k >= 2 and k <= N and o.res and o.res ~= "pending" and not judge_log[id] then
                local w = P:window(k)
                local text, col
                if o.res ~= "ok" then
                    text = (Overlay.RES_TEXT[o.res] or string.upper(o.res))
                    if o.off and o.off ~= 0 then text = text .. string.format(" %+d", o.off) end
                    col = C.red
                elseif w and o.p then
                    local in_sweet = w.sweet_lo and o.p >= w.sweet_lo and o.p <= w.sweet_hi
                    if in_sweet or (not w.sweet_lo and math.abs(o.p - w.mid) <= 1) then text, col = "SWEET", rgba(255, 225, 120)
                    elseif o.off and o.off ~= 0 then text, col = string.format(o.off < 0 and "EARLY %d" or "LATE +%d", o.off), C.orange
                    else text, col = "GOOD", C.cyan end
                else
                    text, col = "GOOD", C.cyan
                end
                judge_log[id] = { t = clock, text = text, col = col, k = k }
                judge_log._last = judge_log[id]
            end
        end
    end

    -- hit times
    local T = {}
    local first = 2
    local c = live and live.c or nil
    if S.song then
        A = cfg.song_approach or 80
        first = 1
        for j = 1, N do
            local done = live and live.steps and live.steps[j] and live.steps[j].res
            if not done or (j >= (c or 1)) then T[j] = S.song.T[j] end
        end
        if live and c then for j = 1, c - 1 do T[j] = nil end end
    elseif live and not live.failed and not live.success and c and c >= 2 and c <= N and live.anchor then
        local w = P:window(c)
        if w then
            T[c] = live.anchor + w.mid
            for j = c + 1, N do
                local wj, wp = P:window(j), P:window(j - 1)
                if not wj then break end
                T[j] = T[j - 1] + ((wp and wp.dq) or 1) + wj.mid
            end
        end
    end

    -- target ring
    local nxt = nil
    for j = first, N do if T[j] and T[j] > fnow - 6 then nxt = j break end end
    draw.filled_circle(cx, cy, R + 7 * sc, rgba(0, 0, 0, 150), 48)
    draw.outline_circle(cx, cy, R, rgba(255, 255, 255, 120), 48)
    if nxt then
        local w = nxt >= 2 and P:window(nxt) or nil
        -- the hand makes one lap per note: it leaves 12 o'clock when the previous
        -- note lands and is back at 12 o'clock exactly when this one does
        local prev
        if S.song then
            prev = (nxt > 1 and T[nxt - 1]) or (S.song.fixed and nxt > 1 and S.song.fixed[nxt - 1]) or S.song.t0
            if nxt > 1 and not T[nxt - 1] and live and live.anchor then prev = live.anchor end
        else
            prev = live and live.anchor or (T[nxt] - A)
        end
        local D = math.max(2, T[nxt] - prev)
        local per = (2 * math.pi) / D                   -- radians per frame for this lap
        local function arc(a, b)
            local lim = math.pi * 0.95
            return math.max(-lim, math.min(lim, a)), math.max(-lim, math.min(lim, b))
        end
        -- window arc and sweet arc, positioned relative to the target frame (12 o'clock)
        if w then
            local a0, a1 = arc((w.E - w.mid) * per, (w.L - w.mid) * per)
            ring_dots(cx, cy, R, a0, a1, with_alpha(C.cyan, 0.85), 3.2 * sc)
            if w.sweet_lo then
                local s0, s1 = arc((w.sweet_lo - w.mid) * per, (w.sweet_hi - w.mid) * per)
                ring_dots(cx, cy, R, s0, s1, C.white, 3.8 * sc)
            end
        end
        if S.song and S.song.count then
            local pulse = 1 - (S.song.beat_phase or 0)
            draw.outline_circle(cx, cy, R + (4 + 10 * pulse) * sc, with_alpha(C.yellow, 0.3 + 0.6 * pulse), 48)
        end
        local p = math.max(0, math.min(1.08, (fnow - prev) / D))
        local a = 2 * math.pi * p
        local hx, hy = cx + math.sin(a) * (R + 4 * sc), cy - math.cos(a) * (R + 4 * sc)
        draw.line(cx, cy, hx, hy, rgba(255, 255, 255, 235), 3 * sc)
        draw.filled_circle(hx, hy, 4.5 * sc, rgba(255, 255, 255, 255), 12)
        labels[#labels + 1] = { x = cx, y = cy, text = steps[nxt].label, col = note_color(steps[nxt].label), big = true, step = true }
    elseif not live and not S.song then
        -- idle: breathing ring on the first step
        local pulse = 0.5 + 0.5 * math.sin(clock * 4)
        draw.outline_circle(cx, cy, R + (3 + 4 * pulse) * sc, with_alpha(note_color(steps[1].label), 0.4 + 0.5 * pulse), 48)
        labels[#labels + 1] = { x = cx, y = cy, text = steps[1].label, col = note_color(steps[1].label), big = true, step = true }
        labels[#labels + 1] = { x = cx, y = cy + R + 18 * sc, text = "start when ready", col = C.dim }
    end

    -- notes in flight
    local dist = math.min(W * 0.38, 720 * sc)
    for j = N, first, -1 do
        local Tj = T[j]
        if Tj then
            local u = 1 - (Tj - fnow) / A
            if u > -0.02 and u < 1.12 then
                -- punches enter from the left, kicks from the right, the rest from below
                local side = note_side(steps[j].label, cfg.note_flip)
                local lift = ((j * 37) % 30) / 100            -- a little variety per step
                local sx, sy, px, py
                if side == 0 then
                    sx, sy = cx + (lift - 0.15) * dist * 0.6, cy + dist * 0.55
                    px, py = cx + (lift - 0.15) * dist * 0.3, cy + dist * 0.25
                else
                    sx, sy = cx + side * dist, cy + dist * (0.04 + lift * 0.3)
                    px, py = cx + side * dist * 0.45, cy + dist * (0.14 + lift * 0.4)
                end
                local function at(t)
                    t = math.max(0, math.min(1, t))
                    local a1, b1 = (1 - t) * (1 - t), 2 * (1 - t) * t
                    local c1 = t * t
                    return a1 * sx + b1 * px + c1 * cx, a1 * sy + b1 * py + c1 * cy
                end
                local col = note_color(steps[j].label)
                local cur = (j == nxt)
                local fade = (u > 1) and math.max(0, 1 - (u - 1) / 0.12) or 1
                local bright = cur and 1 or 0.45                 -- the note you're about to hit stands out
                for tr = 5, 1, -1 do
                    local tx, ty = at(u - tr * 0.035)
                    draw.filled_circle(tx, ty, (18 - 2 * tr) * sc, with_alpha(col, 0.10 * (6 - tr) * fade * bright), 16)
                end
                local x, y = at(u)
                if cur then
                    local pulse = 0.5 + 0.5 * math.sin(clock * 10)
                    draw.filled_circle(x, y, R + (6 + 3 * pulse) * sc, with_alpha(col, 0.22 * fade), 40)
                end
                draw.filled_circle(x, y, R, with_alpha(rgba(10, 12, 20), (cur and 0.92 or 0.75) * fade), 40)
                draw.outline_circle(x, y, R, with_alpha(col, fade * bright), 40)
                draw.outline_circle(x, y, R - 4 * sc, with_alpha(col, 0.6 * fade * bright), 40)
                if not cur or u < 0.92 then
                    labels[#labels + 1] = { x = x, y = y, text = steps[j].label, col = with_alpha(col, fade * (cur and 1 or 0.6)), note = true, step = true }
                end
            end
        end
    end

    if S.song and S.song.count then
        labels[#labels + 1] = { x = cx - R - 46 * sc, y = cy, text = S.song.count, col = C.yellow, judge = true }
    end

    -- judgement burst
    local jl = judge_log._last
    if jl then
        local age = clock - jl.t
        if age < 0.7 then
            local a = 1 - age / 0.7
            draw.outline_circle(cx, cy, R + (6 + 60 * age) * sc, with_alpha(jl.col, a), 48)
            labels[#labels + 1] = { x = cx, y = cy + R + (26 + 24 * age) * sc, text = jl.text, col = with_alpha(jl.col, a), judge = true }
        end
    end
    -- keep the log small
    local n = 0
    for k in pairs(judge_log) do n = n + 1 end
    if n > 200 then judge_log = {} end
    return labels, cy + R + 52 * sc
end

-- --------------------------------------------------------------------------
-- main draw (called from re.on_frame)
-- S = { mode, combo, profile, tracker, last, stats, cfg, msg }
-- --------------------------------------------------------------------------
function Overlay.draw(S)
    local cfg = S.cfg
    local disp = imgui.get_display_size()
    local W, H = disp.x, disp.y
    local sc = (H / 1080) * (cfg.scale or 1.0)

    local combo = S.combo
    local steps = combo and combo.steps or {}
    local N = #steps
    local live = S.tracker and S.tracker:live_detail() or nil
    local shown = live or S.last
    Overlay.song_update(S, live, S.tracker and S.tracker:now())

    -- ------------------------------------------------ bars (draw layer)
    local bw = math.min(W * 0.56, 1150 * sc)
    local bx = (W - bw) / 2
    local by = H * (cfg.y or 0.115)
    local bh = 26 * sc
    local seg_rects = {}
    local view = cfg.train_view or "bar"
    local notes_on = S.mode == "train" and (view == "notes" or view == "both") and N >= 2 and S.profile ~= nil
    local bar_on = not (notes_on and view == "notes")
    local note_labels, notes_bottom = nil, nil
    -- note view layout: [bar] / notation line / ring / result
    local notes_ny = nil
    if notes_on then
        notes_ny = bar_on and (by + bh + 34 * sc) or by
        note_labels, notes_bottom = Overlay.notes(S, W, H, sc, notes_ny + 56 * sc)
    end
    if N >= 2 and bar_on then
        local gap = 6 * sc
        local first_w = 18 * sc
        local lead_w = (S.song and S.mode == "train") and math.floor(bw * 0.14) or 0
        local sw = (bw - lead_w - (lead_w > 0 and gap or 0) - first_w - gap * (N - 1)) / (N - 1)
        local geo = {}
        local x0 = bx
        if lead_w > 0 then
            -- count-in lead: four beats ending at step 1
            draw.filled_rect(bx, by, lead_w, bh, C.bg)
            for b = 1, 3 do
                local tx = bx + lead_w * b / 4
                local lit = S.song.count and tonumber(S.song.count) and (4 - tonumber(S.song.count)) >= b
                draw.filled_rect(tx - 1.5 * sc, by + bh * 0.2, 3 * sc, bh * 0.6, lit and C.yellow or rgba(255, 255, 255, 90))
            end
            x0 = bx + lead_w + gap
            geo.lead = { x = bx, w = lead_w, mx = x0 + first_w / 2 }
        end
        -- step 1 marker
        local s1 = shown and shown.steps and shown.steps[1]
        local c1 = C.bg_hi
        if s1 then c1 = RES_COLOR[s1.res] or C.white end
        draw.filled_rect(x0, by, first_w, bh, c1)
        local x = x0 + first_w + gap
        for k = 2, N do
            local press = shown and shown.steps and shown.steps[k] or nil
            local lo, hi, fx, cell = draw_segment(x, by, sw, bh, k, S, press, sc)
            geo[k] = { lo = lo, hi = hi, fx = fx, cell = cell }
            if live and live.c == k then
                draw.outline_rect(x - 2, by - 2, sw + 4, bh + 4, C.yellow)
            end
            seg_rects[k] = { x = x, w = sw, press = press }
            x = x + sw + gap
        end
        S._rhythm_hint = nil
        if cfg.rhythm ~= false then
            S._rhythm_hint = Overlay.rhythm(S, geo, live, by, bh, sc)
        end
    end

    -- ------------------------------------------------ text model (computed first so
    -- the dark backing panels can be drawn underneath the text)
    local f_big, f_mid, f_sm = font(34 * sc), font(32 * sc), font(18 * sc)
    local pieces, total = {}, 0
    for k = 1, N do
        local st = steps[k]
        if k > 1 then
            local sp = st.sep or ">"
            if sp == "," then sp = ", " elseif sp == "~" then sp = " ~ " else sp = " " .. sp .. " " end
            pieces[#pieces + 1] = { sp, C.dim, sep = true }
        end
        local col = C.white
        local o = shown and shown.steps and shown.steps[k]
        if o then col = RES_COLOR[o.res] or C.white end
        if live and live.c == k and not live.failed then col = C.yellow end
        pieces[#pieces + 1] = { st.label, col }
    end
    local arrows = cfg.motion_arrows == true
    for _, p in ipairs(pieces) do
        p.items, p.w = rich(p[1], f_mid, arrows and not p.sep)
        total = total + p.w
    end
    local _, line_h = measure("Ag", f_mid)
    local ny = notes_ny or (by + bh + 34 * sc)
    local ry = notes_bottom or (ny + line_h + 18 * sc)

    local res_s, res_col, hint = nil, nil, nil
    local last = S.last
    if not combo then
        res_s, res_col = "ComboLab: no combo loaded (REFramework menu or ComboLab.html)", C.dim
    elseif not live and last and S.result_age < (cfg.result_seconds or 4) then
        if last.ok then
            res_s, res_col = "CLEAN", C.green
            if S.mode == "train" then
                local worst = 0
                for _, o in pairs(last.steps) do if o.off and math.abs(o.off) > math.abs(worst) then worst = o.off end end
                if worst ~= 0 then res_s = string.format("CLEAN  (outside known window by %+df)", worst); res_col = C.yellow end
            end
        else
            local k = last.fail_step or 1
            local o = last.steps[k] or {}
            res_s = string.format("DROPPED at %s: %s", (steps[k] and steps[k].label) or "?", RES_TEXT[o.res] or string.upper(o.res or "?"))
            if o.off and o.off ~= 0 then res_s = res_s .. string.format(" %+df", o.off) end
            res_col = RES_COLOR[o.res] or C.red
            hint = o.hint
        end
    end
    -- while the bot runs, describe the probe instead of the normal drop banner
    local bp = S.bot_status and S.bot_status.last_probe
    if bp and not live and (os.clock() - (bp.t or 0)) < 3 then
        hint = nil
        if bp.phase == "A" and bp.step then
            if bp.ok then
                res_s, res_col = string.format("step %d %s at +%df: works", bp.step, bp.label or "", bp.d or 0), C.green
            else
                res_s, res_col = string.format("step %d %s at +%df: %s", bp.step, bp.label or "", bp.d or 0,
                    Overlay.RES_TEXT[bp.res or ""] or "no hit"), C.orange
            end
            hint = "the bot only presses up to the step it's testing; later steps dropping is expected"
        elseif bp.ok then
            res_s, res_col = "full combo: clean", C.green
        else
            res_s, res_col = string.format("full combo: dropped at %s", bp.fail_label or "?"), C.orange
        end
    elseif S.bot_status then
        res_s = nil
    end
    local res_f = combo and f_big or f_sm
    local pad = 12 * sc
    if N > 0 then panel(W / 2 - total / 2 - pad, ny - pad * 0.6, total + pad * 2, line_h + pad * 1.2) end
    if arrows then
        local gx = W / 2 - total / 2
        for _, p in ipairs(pieces) do rich_glyphs(p.items, gx, ny, line_h, p[2]); gx = gx + p.w end
    end
    -- note labels: lay out now so their arrows go on the draw layer
    local f_note = font(24 * sc)
    if note_labels then
        for _, l in ipairs(note_labels) do
            l.f = (l.big or l.judge) and f_mid or (l.note and f_note or f_sm)
            l.items, l.w = rich(l.text, l.f, arrows and l.step)
            local _, th = measure("Ag", l.f)
            l.th = th
            if arrows and l.step then rich_glyphs(l.items, l.x - l.w / 2, l.y - th / 2, th, l.col) end
        end
    end
    local res_w, res_h, hint_w, hint_h = 0, 0, 0, 0
    if res_s then
        res_w, res_h = measure(res_s, res_f)
        local pw, ph = res_w, res_h
        if hint then
            hint_w, hint_h = measure(hint, f_sm)
            pw = math.max(pw, hint_w); ph = ph + hint_h + 6 * sc
        end
        panel(W / 2 - pw / 2 - pad, ry - pad * 0.6, pw + pad * 2, ph + pad * 1.2)
    end

    -- ------------------------------------------------ text (imgui layer)
    imgui.set_next_window_pos(Vector2f.new(0, 0), 1)
    imgui.set_next_window_size(Vector2f.new(W, H), 1)
    local flags = 1 | 2 | 4 | 8 | 16 | 128 | 256 | 512 | 4096 | 8192 | 786432
    imgui.push_style_var(4, 0.0) -- window border
    if imgui.begin_window("##combolab_overlay", true, flags) then
        if not Overlay.fonts_ok and imgui.set_window_font_scale then
            pcall(imgui.set_window_font_scale, 1.6 * sc)
        end

        -- mode tag
        local tag = ((S.mode == "train") and "TRAIN" or "DEVELOP") .. "  v" .. (S.version or "?")
        local b = S.bot_status
        if b then
            tag = string.format("BOT  %d/%d  %s  step %s %s  %s%s  #%d", b.queue_pos or 0, b.queue_len or 0,
                b.phase == "A" and "finding windows" or (b.phase == "B" and "sweet spots" or "checking"),
                tostring(b.step or "-"), tostring(b.step_label or ""), b.d and "+" or "", b.d and tostring(b.d) .. "f" or "",
                b.attempts or 0)
        end
        if S.mode == "train" and cfg.spam_block then tag = tag .. " | SPAM BLOCK" end
        text_at(bx, by - 26 * sc, tag, S.bot_status and C.magenta or (S.mode == "train" and C.orange or C.cyan), f_sm)
        if combo then
            local nm = combo.name or combo.id or ""
            local tw = measure(nm, f_sm)
            text_at(bx + bw - tw, by - 26 * sc, nm, C.dim, f_sm)
        end

        if S.song and S.song.count and not notes_on then
            local tw = measure(S.song.count, f_big)
            text_at(W / 2 - tw / 2, by - 64 * sc, S.song.count, C.yellow, f_big)
        end
        if S.song_hint and not live then
            local tw = measure(S.song_hint, f_sm)
            text_at(W / 2 - tw / 2, by - 48 * sc, S.song_hint, C.yellow, f_sm)
        end
        if S._rhythm_hint and not live then
            local tw = measure(S._rhythm_hint, f_sm)
            text_at(W / 2 - tw / 2, by - 26 * sc, S._rhythm_hint, C.yellow, f_sm)
        end

        -- frame-offset labels over the bar
        for k, r in pairs(seg_rects) do
            local p = r.press
            if p and p.off and p.off ~= 0 and p.label_x then
                local s = (p.off > 0 and "+" or "") .. tostring(p.off)
                local tw = measure(s, f_sm)
                text_at(p.label_x - tw / 2, by + bh + 4 * sc, s, (p.res == "ok") and C.yellow or C.red, f_sm)
            end
        end

        -- notation line, each step colored by its state
        local x = W / 2 - total / 2
        for _, p in ipairs(pieces) do
            rich_text(p.items, x, ny, p[2], f_mid)
            x = x + p.w
        end

        -- note labels
        if note_labels then
            for _, l in ipairs(note_labels) do
                rich_text(l.items, l.x - l.w / 2, l.y - l.th / 2, l.col, l.f)
            end
        end

        -- result line
        if res_s then
            text_at(W / 2 - res_w / 2, ry, res_s, res_col, res_f)
            if hint then text_at(W / 2 - hint_w / 2, ry + res_h + 6 * sc, hint, C.white, f_sm) end
        end

        -- stats
        if combo and S.stats then
            local st = S.stats
            local s
            if S.mode == "train" then
                local pct = st.n > 0 and math.floor(st.ok * 100 / st.n + 0.5) or 0
                s = string.format("%d/%d  %d%%   streak %d   best %d", st.ok, st.n, pct, st.streak, st.best)
            else
                local P = S.profile
                s = string.format("profile: %d attempts, %d clean", P and P.attempts or 0, P and P.successes or 0)
            end
            local sy = bar_on and (by + bh + 4 * sc) or (ny + line_h + 10 * sc)
            text_at(bx, sy, s, C.dim, f_sm)
        end

        if S.msg and S.msg_age < 3 then
            local tw = measure(S.msg, f_mid)
            text_at(W / 2 - tw / 2, H * 0.30, S.msg, C.yellow, f_mid)
        end

        if cfg.show_detail and combo then Overlay.detail(S, W, H, sc, f_sm) end
        imgui.end_window()
    end
    imgui.pop_style_var(1)
end

-- --------------------------------------------------------------------------
-- detail table (develop)
-- --------------------------------------------------------------------------
function Overlay.detail(S, W, H, sc, f)
    local steps = S.combo.steps
    local x0, y0 = W * 0.015, H * 0.30
    local cols = { 0, 34, 120, 160, 230, 420, 510, 580, 680, 750 }
    for i = 1, #cols do cols[i] = cols[i] * sc end
    local lh = 21 * sc
    local w_total = cols[#cols] + 80 * sc
    draw.filled_rect(x0 - 8 * sc, y0 - 8 * sc, w_total, lh * (#steps + 3) + 12 * sc, rgba(0, 0, 0, 150))
    local hdr = { "#", "step", "", "ok/n", "press window", "came out", "free at", "stun ends", "slack", "last" }
    for i, h in ipairs(hdr) do text_at(x0 + cols[i], y0, h, C.dim, f) end
    local last = S.tracker and S.tracker:live_detail() or S.last
    for k, st in ipairs(steps) do
        local y = y0 + lh * k
        local w = S.profile and S.profile:window(k) or nil
        local samples = S.profile and S.profile.steps[k] and S.profile.steps[k].samples or {}
        local n_ok = 0
        for _, s in ipairs(samples) do if s.res == "ok" then n_ok = n_ok + 1 end end
        local o = last and last.steps and last.steps[k]
        local col = o and (RES_COLOR[o.res] or C.white) or C.white
        text_at(x0 + cols[1], y, tostring(k), C.dim, f)
        text_at(x0 + cols[2], y, st.label, col, f)
        text_at(x0 + cols[3], y, k > 1 and (st.sep or "") or "", C.sep, f)
        text_at(x0 + cols[4], y, k > 1 and string.format("%d/%d", n_ok, #samples) or "-", C.white, f)
        if w then
            local s = fmt_range(w.E, w.L)
            if w.sweet_lo then
                s = s .. string.format("  sweet %s", fmt_range(w.sweet_lo, w.sweet_hi))
            elseif w.E_soft ~= w.E or w.L_soft ~= w.L then
                s = s .. "  (" .. fmt_range(w.E_soft, w.L_soft) .. ")"
            end
            if w.pred then s = s .. "  est. from frame data"
            elseif w.pred_E then s = s .. "  (data " .. fmt_range(w.pred_E, w.pred_L) .. ")" end
            text_at(x0 + cols[5], y, s, C.cyan, f)
            text_at(x0 + cols[6], y, fmt_range(w.q_min, w.q_max), C.white, f)
            text_at(x0 + cols[7], y, w.o and ("+" .. math.floor(w.o)) or (st.sep == ">" and "cancel" or "-"), C.yellow, f)
            text_at(x0 + cols[8], y, w.stun_end and ("+" .. math.floor(w.stun_end)) or "-", C.orange, f)
            text_at(x0 + cols[9], y, w.slack_min and (tostring(math.floor(w.slack_min)) .. "f") or "-", C.white, f)
        elseif k > 1 then
            text_at(x0 + cols[5], y, "no clean samples yet", C.dim, f)
        end
        if o and o.p then
            text_at(x0 + cols[10], y, "+" .. math.floor(o.p), col, f)
        end
    end
    text_at(x0, y0 + lh * (#steps + 1) + 4 * sc,
        "frames from the previous step's start | cyan: clean | white core: sweet spot (keeps the next step alive)", C.dim, f)
end

return Overlay
