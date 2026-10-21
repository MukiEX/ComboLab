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
-- ImGui's atlas mid-frame): ComboLab's own font (reframework/fonts/
-- ComboLab-Bold.ttf, DejaVu Sans Bold) at a range of sizes, else ImGui's
-- default. Each piece of text then asks for an exact pixel size: the nearest
-- loaded font is pushed and the window's font scale makes up the rest, sized
-- from the height the font really has. (Loading with no font file gave the
-- default font at one size whatever size was asked for, so text never grew.)
local FONT_FILE = "ComboLab-Bold.ttf"
local FONT_SIZES = { 18, 24, 32, 44, 60, 80, 108 }
local fonts = {}           -- px -> font
Overlay.fonts_ok, Overlay.font_file = false, false
for _, px in ipairs(FONT_SIZES) do
    local ok, f = pcall(imgui.load_font, FONT_FILE, px)
    if ok and f ~= nil then fonts[px] = f; Overlay.fonts_ok = true; Overlay.font_file = true end
end
if not Overlay.fonts_ok then
    local ok, f = pcall(imgui.load_font, nil, 24)
    if ok and f ~= nil then fonts[24] = f; Overlay.fonts_ok = true end
end
local can_scale = imgui.set_window_font_scale ~= nil
Overlay.text_scale = 1.0
local fdesc = {}           -- rounded px -> { f = font or nil, px = wanted size }
local function font(px)
    px = math.floor(px * (Overlay.text_scale or 1) + 0.5)
    local d = fdesc[px]
    if d then return d end
    local best, bd = nil, math.huge
    for size, f in pairs(fonts) do
        local dd = math.abs(size - px)
        if size >= px then dd = dd * 0.5 end     -- scaling down stays crisp: prefer the bigger one
        if dd < bd then best, bd = f, dd end
    end
    d = { f = best, px = px }
    fdesc[px] = d
    return d
end

-- the height a font really draws at (window scale 1)
local base_h = {}
local function height_of(d)
    local key = d.f or "default"
    local h = base_h[key]
    if h then return h end
    if d.f then imgui.push_font(d.f) end
    local v = imgui.calc_text_size("Ag")
    if d.f then imgui.pop_font() end
    h = (v and v.y and v.y > 0) and v.y or 16
    base_h[key] = h
    return h
end
local function scale_of(d)
    if not d or not can_scale then return 1 end
    return d.px / height_of(d)
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
    local k = scale_of(f)
    if f and f.f then imgui.push_font(f.f) end
    if k ~= 1 then pcall(imgui.set_window_font_scale, k) end
    local sh = math.max(2, (f and f.px or 16) * 0.08)
    imgui.set_cursor_pos(Vector2f.new(x + sh, y + sh))
    imgui.text_colored(s, C.shadow)
    imgui.set_cursor_pos(Vector2f.new(x, y))
    imgui.text_colored(s, col)
    if k ~= 1 then pcall(imgui.set_window_font_scale, 1.0) end
    if f and f.f then imgui.pop_font() end
end

local function panel(x, y, w, h)
    draw.filled_rect(x, y, w, h, C.panel)
end

local function measure(s, f)
    if f and f.f then imgui.push_font(f.f) end
    local v = imgui.calc_text_size(s)
    if f and f.f then imgui.pop_font() end
    local k = scale_of(f)
    return v.x * k, v.y * k
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
    local gh = th * 1.05
    local items, total = {}, 0
    for _, p in ipairs(Motion.parse(label)) do
        local it
        if p.t == "text" then
            it = { t = "text", s = p.s, w = measure(p.s, f) }
        else
            local g = glyph_of(p)
            it = { t = "glyph", g = g, gh = gh, pad = th * 0.06, w = gh * g.aspect + th * 0.12 }
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
-- draws one motion glyph with its top-left at (x, y), height h, in `col`
-- with a dark outline
local function draw_glyph(g, x, y, h, col)
    local sw = math.max(2, h * 0.15)
    local inset = sw * 0.5                           -- keep the stroke inside the box
    local hh = h - 2 * inset
    x, y = x + inset, y + inset
    local hl, hw = sw * 2.1, sw * 1.7                -- arrowhead length / half width
    local ol = math.max(1.5, sw * 0.35)              -- dark outline
    local dark = with_alpha(rgba(0, 0, 0, 230), alpha_of(col))
    local hx, hy = x + g.head[1] * hh, y + g.head[2] * hh
    local dx, dy = g.head[3], g.head[4]
    local px = {}
    for i, l in ipairs(g.lines) do
        local q = {}
        for j = 1, #l, 2 do q[j] = x + l[j] * hh; q[j + 1] = y + l[j + 1] * hh end
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
            draw.filled_quad(tx, ty, ax, ay, bx + dx * hl * 0.2, by + dy * hl * 0.2, cx, cy, c)
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
-- --------------------------------------------------------------------------
-- display clock: game frames as a smooth, fractional time for drawing.
-- The game ticks on its own thread and its ticks don't line up with rendered
-- frames, so "last tick + time since it" wobbles by most of a frame whenever
-- the two drift past each other (a periodic hitch). This runs a clock at a
-- steady 60/s from os.clock and only eases it toward the tick estimate; it
-- snaps when the gap is big (pause, reset, new attempt counter).
-- --------------------------------------------------------------------------
local dclk = { t = nil, os = nil, frame = nil, value = nil }
Overlay.frame_id = 0
function Overlay.ftime(S, now)
    if dclk.frame == Overlay.frame_id and dclk.value then return dclk.value end
    local c = os.clock()
    local est = now + math.max(0, math.min(1.5, (c - (S.tick_clock or c)) * 60))
    local t
    if not dclk.t or not dclk.os or c - dclk.os > 0.25 or math.abs(est - dclk.t) > 3 then
        t = est
    else
        t = dclk.t + (c - dclk.os) * 60
        t = t + (est - t) * 0.12
        if t < dclk.t then t = dclk.t end          -- never run backwards
    end
    dclk.t, dclk.os, dclk.frame, dclk.value = t, c, Overlay.frame_id, t
    return t
end

local demo_t0 = nil
function Overlay.rhythm(S, geo, live, by, bh, sc)
    local P = S.profile
    if not P then return end
    if S.song and not (S.cfg.song_follow and live) then
        demo_t0 = nil
        local now = S.tracker:now()
        if not now then return end
        local fnow = Overlay.ftime(S, now)
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
        if S.dummy_down then S.song = nil; S.song_hint = "waiting for the dummy to get up" return end
        local B = math.max(12, cfg.song_beat or 30)
        song = { t0 = now, B = B, T = {} }
        S.song_seq = (S.song_seq or 0) + 1        -- a new count-in (ComboLab.lua may re-place the fighters)
        song.T[1] = now + 4 * B
        local prev_dq = 1
        for k = 2, N do
            local w = P:window(k)
            song.T[k] = song.T[k - 1] + prev_dq + w.mid
            prev_dq = w.dq or 1
        end
        song.fixed = {}
        for k = 1, N do song.fixed[k] = song.T[k] end
        song.got = {}
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
    -- restart when the first note goes by untouched, or two notes in a row do
    if live and live.steps then
        for j, o in pairs(live.steps) do if o.res == "ok" then song.got[j] = true end end
    end
    local streak, why = 0, nil
    for j = 1, N do
        local slack = 6
        if j >= 2 then
            local w = P:window(j)
            slack = slack + math.max(0, (w.L or w.mid) - w.mid)
        end
        if now <= song.T[j] + slack then break end
        if song.got[j] then
            streak = 0
        else
            streak = streak + 1
            if j == 1 then why = "missed the first hit" break end
            if streak >= 2 then why = "missed two notes in a row" break end
        end
    end
    if why then
        S.song_flash = { t = os.clock(), text = why .. ": restarting" }
        if live and S.tracker then S.tracker.att = nil; S.tracker._live = nil end
        S.song = nil
        return
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

-- Shared by the note views: logs a judgement for each finished step of the
-- attempt in progress (or the last one), and returns the target frame of every
-- upcoming step (T), the first step that gets a note, and the flight time.
function Overlay.timeline(S, live, fnow)
    local P, cfg = S.profile, S.cfg
    local N = #S.combo.steps
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
    local A = cfg.note_approach or 36
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

    return T, first, A
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
    local fnow = Overlay.ftime(S, now)
    local clock = os.clock()

    local T, first, A2 = Overlay.timeline(S, live, fnow)
    A = A2 or A
    local c = live and live.c or nil

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
-- "Strike Fixation" view (Train): a DDR-style chart. Lanes are
--   [ motion ] [ light ] [ medium ] [ heavy ]
-- and every step is a row of notes rising to the receptors at the top, landing
-- on its target frame. Punch / kick shows on the note (P, K, PK); a button of
-- any strength spans all three lanes. A faint band around each row is the
-- step's press window.
-- --------------------------------------------------------------------------
local LANES = { "L", "M", "H" }

-- what a step asks for, lane by lane
function Overlay.fix_lanes(label)
    label = tostring(label or "")
    label = label:match("[^~]+$") or label        -- "236K~K": the follow-up is what you press next
    local up = label:upper()
    local r = { parts = nil, mtext = nil, L = nil, M = nil, H = nil, any = nil }
    if up == "DR" then r.mtext, r.M = "DR", "PK" return r end
    if up == "DI" then r.mtext, r.H = "DI", "PK" return r end
    if up == "PARRY" then r.mtext, r.M = "PARRY", "PK" return r end
    if up == "THROW" then r.mtext, r.L = "THROW", "PK" return r end
    if up:find("^SA") or up:find("^CA") or up:find("^LVL") then r.mtext = up return r end
    local parts = Motion.parse(label)
    -- the button text is the last text part; everything before it goes in the motion lane
    local btn, bi = nil, nil
    for i = #parts, 1, -1 do
        if parts[i].t == "text" and parts[i].s ~= "]" and parts[i].s ~= "~" then btn, bi = parts[i].s, i break end
    end
    if btn and btn:upper():find("^J%.") then btn, bi = nil, nil end
    local m = {}
    for i, p in ipairs(parts) do if i ~= bi then m[#m + 1] = p end end
    if #m > 0 then r.parts = m end
    local s = (btn or ""):upper():gsub("[%[%]%+%s]", "")
    local function add(lane, v) r[lane] = (r[lane] and r[lane] ~= v and not r[lane]:find(v)) and (r[lane] .. v) or (r[lane] or v) end
    while #s > 0 do
        local two = s:sub(1, 2)
        if two:match("^[LMH][PK]$") then add(two:sub(1, 1), two:sub(2)); s = s:sub(3)
        elseif s:sub(1, 3) == "PPP" or s:sub(1, 3) == "KKK" then for _, l in ipairs(LANES) do add(l, s:sub(1, 1)) end; s = s:sub(4)
        elseif two == "PP" or two == "KK" then r.any = (r.any or "") .. two; s = s:sub(3)
        elseif s:sub(1, 2) == "SP" then r.mtext = (r.mtext or "") .. "SP"; s = s:sub(3)
        elseif s:sub(1, 4) == "AUTO" then r.any = (r.any or "") .. "AUTO"; s = s:sub(5)
        elseif s:sub(1, 1) == "P" or s:sub(1, 1) == "K" then r.any = (r.any or "") .. s:sub(1, 1); s = s:sub(2)
        elseif s:sub(1, 1):match("[LMH]") then add(s:sub(1, 1), "•"); s = s:sub(2)          -- Modern L / M / H
        else break end
    end
    return r
end

local function lane_color(l) return cur_palette[l] or NOTE.X end

function Overlay.fixation(S, W, H, sc, top)
    cur_palette = PALETTES[S.cfg.note_palette or "classic"] or PALETTES.classic
    local P, combo, cfg = S.profile, S.combo, S.cfg
    local steps = combo.steps
    local N = #steps
    local labels = {}
    local live = S.tracker:live_detail()
    local now = S.tracker:now() or 0
    local fnow = Overlay.ftime(S, now)
    local clock = os.clock()
    local T, first, A = Overlay.timeline(S, live, fnow)

    -- geometry
    local u = 64 * sc
    local gap = 6 * sc
    local mw = u * 1.9                                  -- motion lane is wider (236236 needs room)
    local pw = mw + 3 * u + 4 * gap
    local px = (cfg.fix_pos == "left" and W * 0.05) or (cfg.fix_pos == "right" and (W * 0.95 - pw)) or (W - pw) / 2
    local ph = math.min(H * 0.55, 560 * sc)
    local ry = top + u * 0.55                           -- receptor centre line
    local speed = (ph - u * 0.6) / math.max(10, A)      -- pixels per frame
    local lane_x = { motion = px + gap }
    lane_x.L = lane_x.motion + mw + gap
    lane_x.M = lane_x.L + u + gap
    lane_x.H = lane_x.M + u + gap
    local function y_of(t) return ry + (t - fnow) * speed end

    -- lanes
    draw.filled_rect(px, top, pw, ph, rgba(6, 8, 14, 195))
    draw.filled_rect(lane_x.motion, top, mw, ph, rgba(255, 255, 255, 10))
    for _, l in ipairs(LANES) do draw.filled_rect(lane_x[l], top, u, ph, with_alpha(lane_color(l), 0.06)) end

    -- beat lines (song mode) for a DDR feel
    if S.song then
        local B = S.song.B
        local k0 = math.ceil((fnow - S.song.t0) / B)
        for k = k0, k0 + math.ceil(A / B) + 1 do
            local y = y_of(S.song.t0 + k * B)
            if y > top and y < top + ph then draw.filled_rect(px, y, pw, math.max(1, 1.5 * sc), rgba(255, 255, 255, 28)) end
        end
    end

    -- which step is next, and which lanes just got judged (receptor flash)
    local nxt
    for j = first, N do if T[j] and T[j] > fnow - 6 then nxt = j break end end
    local jl = judge_log._last
    local flash = (jl and clock - jl.t < 0.25) and (1 - (clock - jl.t) / 0.25) or 0
    local flash_lanes = (flash > 0 and jl.k and steps[jl.k]) and Overlay.fix_lanes(steps[jl.k].label) or nil

    -- receptors
    local rr = u * 0.36
    local function receptor(l, cx)
        local col = lane_color(l)
        local lit = flash_lanes and (flash_lanes[l] or flash_lanes.any)
        if lit then draw.filled_circle(cx, ry, rr + 8 * sc * flash, with_alpha(jl.col, 0.5 * flash), 32) end
        draw.outline_circle(cx, ry, rr, with_alpha(col, 0.9), 32)
        draw.outline_circle(cx, ry, rr - 3 * sc, with_alpha(col, 0.45), 32)
        labels[#labels + 1] = { x = cx, y = ry, text = l, col = with_alpha(col, 0.55), size = 18 }
    end
    for _, l in ipairs(LANES) do receptor(l, lane_x[l] + u / 2) end
    do
        local cx = lane_x.motion + mw / 2
        local lit = flash_lanes and (flash_lanes.parts or flash_lanes.mtext)
        if lit then draw.filled_rect(lane_x.motion, ry - rr - 6 * sc * flash, mw, 2 * rr + 12 * sc * flash, with_alpha(jl.col, 0.35 * flash)) end
        draw.outline_rect(lane_x.motion + 4 * sc, ry - rr, mw - 8 * sc, 2 * rr, rgba(255, 255, 255, 120))
        labels[#labels + 1] = { x = cx, y = ry, text = "MOTION", col = rgba(255, 255, 255, 70), size = 18 }
    end

    -- notes, latest first so the next one draws on top
    local gh = u * 0.62
    for j = N, first, -1 do
        local Tj = T[j]
        if Tj then
            local y = y_of(Tj)
            local passed = y < ry
            local fade = passed and math.max(0, 1 - (ry - y) / (u * 0.8)) or 1
            if y < top + ph + u * 0.5 and fade > 0 then
                local cur = (j == nxt)
                local bright = (cur and 1 or 0.6) * fade
                local need = Overlay.fix_lanes(steps[j].label)
                -- press window band
                local w = j >= 2 and P:window(j) or nil
                if w and not passed and y - ry > u * 0.5 then
                    -- thin bracket at the panel edges rather than a full-width band
                    local y0, y1 = y_of(Tj - (w.mid - w.E)), y_of(Tj + (w.L - w.mid))
                    local a = cur and 200 or 90
                    draw.filled_rect(px, y0, 4 * sc, math.max(2, y1 - y0), rgba(0, 235, 245, a))
                    draw.filled_rect(px + pw - 4 * sc, y0, 4 * sc, math.max(2, y1 - y0), rgba(0, 235, 245, a))
                    draw.filled_rect(px + 4 * sc, y0, pw - 8 * sc, math.max(2, y1 - y0), rgba(0, 235, 245, cur and 22 or 10))
                end
                -- button lanes
                local gr = u * 0.36
                for _, l in ipairs(LANES) do
                    if need[l] then
                        local cx = lane_x[l] + u / 2
                        local col = lane_color(l)
                        if cur then draw.filled_circle(cx, y, gr + 5 * sc, with_alpha(col, 0.25 * fade), 28) end
                        draw.filled_circle(cx, y, gr, with_alpha(rgba(12, 14, 22), 0.9 * fade), 28)
                        draw.filled_circle(cx, y, gr - 4 * sc, with_alpha(col, 0.85 * bright), 28)
                        draw.outline_circle(cx, y, gr, with_alpha(rgba(255, 255, 255), 0.7 * bright), 28)
                        labels[#labels + 1] = { x = cx, y = y, text = need[l], col = with_alpha(rgba(10, 10, 14), fade), size = 24, dark = true }
                    end
                end
                if need.any then
                    -- any strength: one bar across all three lanes
                    local x0, x1 = lane_x.L + u * 0.18, lane_x.H + u * 0.82
                    local col = NOTE.SP
                    draw.filled_rect(x0, y - gr * 0.7, x1 - x0, gr * 1.4, with_alpha(col, 0.8 * bright))
                    draw.filled_circle(x0, y, gr * 0.7, with_alpha(col, 0.8 * bright), 20)
                    draw.filled_circle(x1, y, gr * 0.7, with_alpha(col, 0.8 * bright), 20)
                    labels[#labels + 1] = { x = (x0 + x1) / 2, y = y, text = need.any, col = with_alpha(rgba(10, 10, 14), fade), size = 24, dark = true }
                end
                -- motion lane
                local mx = lane_x.motion
                local mcol = with_alpha(rgba(255, 255, 255), bright)
                if need.parts or need.mtext then
                    draw.filled_rect(mx + 6 * sc, y - gr, mw - 12 * sc, 2 * gr, with_alpha(rgba(20, 24, 36), 0.9 * fade))
                    draw.outline_rect(mx + 6 * sc, y - gr, mw - 12 * sc, 2 * gr, with_alpha(cur and C.yellow or rgba(255, 255, 255), 0.6 * bright))
                end
                if need.parts then
                    -- lay out glyphs (draw layer) and text bits like "j." or "[ ]" (imgui layer)
                    local f = font(24 * sc)
                    local items, total = {}, 0
                    for _, p in ipairs(need.parts) do
                        local it
                        if p.t == "text" then it = { t = "text", s = p.s, w = measure(p.s, f) }
                        else local g = glyph_of(p); it = { t = "glyph", g = g, w = gh * g.aspect + gh * 0.16 } end
                        items[#items + 1] = it; total = total + it.w
                    end
                    local scale = math.min(1, (mw - 20 * sc) / math.max(1, total))
                    local x = mx + mw / 2 - total * scale / 2
                    for _, it in ipairs(items) do
                        if it.t == "glyph" then
                            local h = gh * scale
                            draw_glyph(it.g, x + h * 0.08, y - h / 2, h, mcol)
                        else
                            labels[#labels + 1] = { x = x + it.w * scale / 2, y = y, text = it.s, col = mcol, size = 24 }
                        end
                        x = x + it.w * scale
                    end
                elseif need.mtext then
                    labels[#labels + 1] = { x = mx + mw / 2, y = y, text = need.mtext, col = with_alpha(NOTE.DR, bright), size = 24 }
                end
            end
        end
    end

    -- judgement and combo counter, DDR style
    if jl and clock - jl.t < 0.8 then
        local a = 1 - (clock - jl.t) / 0.8
        labels[#labels + 1] = { x = px + pw / 2, y = ry + u * 1.15, text = jl.text, col = with_alpha(jl.col, a), size = 32 }
    end
    if live and live.c and live.c > 2 and not live.failed then
        labels[#labels + 1] = { x = px + pw / 2, y = ry + u * 2.0, text = tostring(live.c - 1) .. " combo", col = rgba(120, 200, 255, 220), size = 32 }
    end
    if S.song and S.song.count then
        local pulse = 1 - (S.song.beat_phase or 0)
        labels[#labels + 1] = { x = px + pw / 2, y = top + ph * 0.55, text = S.song.count, col = with_alpha(C.yellow, 0.5 + 0.5 * pulse), size = 40 }
    elseif not live and not S.song then
        labels[#labels + 1] = { x = px + pw / 2, y = top + ph * 0.55, text = "start when ready", col = C.dim, size = 18 }
    end
    return labels, top + ph + 12 * sc
end

-- --------------------------------------------------------------------------
-- "Apple Addict Attack" view (Train): an Ongeki-style highway seen in
-- perspective. Plane, left to right (plane units):
--   [wall 24][LP][MP][HP] | [LK][MK][HK][wall 24]     lanes 56 wide, 384 in all
-- Left wall = Drive Rush / Parry, right wall = Drive Impact, both = supers.
-- A purple lever rail runs up the highway (back = left, neutral = middle,
-- forward = right) carrying big green arrows for stick motions; an arrow that
-- crosses a button note is drawn as an outline so both stay readable. The red
-- apple on the judgement line follows the stick.
-- --------------------------------------------------------------------------
local AAA = {
    L = rgba(59, 155, 246), M = rgba(250, 204, 21), H = rgba(239, 68, 68),
    wall = rgba(255, 159, 28), wall_bg = rgba(42, 24, 6, 230),
    floor = rgba(8, 11, 20, 215), sep = rgba(34, 43, 64), divider = rgba(148, 163, 184),
    rail = rgba(217, 70, 239), charge = rgba(126, 34, 206),
    arrow = rgba(34, 197, 94), arrow_dark = rgba(5, 46, 22), arrow_hi = rgba(187, 247, 208), arrow_ol = rgba(74, 222, 128),
    win = rgba(14, 58, 74, 200), win_edge = rgba(34, 211, 238), sweet = rgba(21, 94, 117, 235),
    apple = rgba(225, 29, 72), leaf = rgba(34, 197, 94), title = rgba(250, 204, 21),
    SWEET = rgba(253, 230, 138), GOOD = rgba(94, 234, 212), EARLY = rgba(147, 197, 253), LATE = rgba(251, 146, 60), DROP = rgba(248, 113, 113),
    enemy = rgba(249, 115, 22), panel = rgba(22, 30, 48, 220),
}
local AAA_PLANE = 384
local AAA_LANE_U = { LP = 52, MP = 108, HP = 164, LK = 220, MK = 276, HK = 332 }
local AAA_LEVER = { back = 52, neutral = 192, forward = 332 }

-- what kind of judgement a judge_log text is
local function aaa_kind(text)
    text = tostring(text or "")
    if text == "SWEET" then return "SWEET" end
    if text == "GOOD" then return "GOOD" end
    if text:find("^EARLY") then return "EARLY" end
    if text:find("^LATE %+") then return "LATE" end
    return "DROP"
end
Overlay.aaa_kind = aaa_kind

local function lever_of(d)
    d = tonumber(d) or 5
    if d == 1 or d == 4 or d == 7 then return AAA_LEVER.back end
    if d == 3 or d == 6 or d == 9 then return AAA_LEVER.forward end
    return AAA_LEVER.neutral
end

-- What a step asks for on the highway:
--   taps = { "LP", ... }  bars = { { "LP", "MP" } }  walls = { left, right }
--   arrows = { "2", "3", "6" }  charge = "4" | nil  hold = bool
local aaa_cache = {}
function Overlay.aaa_need(label, step)
    label = tostring(label or "")
    local key = label .. "|" .. tostring(step and step.trigger and step.trigger.type or "")
    if aaa_cache[key] then return aaa_cache[key] end
    local jump = label:match("^[Jj]%.") ~= nil
    local r = Overlay.fix_lanes(jump and label:sub(3) or label)       -- "j.HP": the button is what's pressed
    local up = label:upper()
    local need = { taps = {}, bars = {}, walls = {}, arrows = {}, hold = false, jump = jump }
    local function tap(n) for _, t in ipairs(need.taps) do if t == n then return end end need.taps[#need.taps + 1] = n end
    if up == "DR" or up == "PARRY" then need.walls.left = true end
    if up == "DI" then need.walls.right = true end
    if up == "THROW" then tap("LP"); tap("LK") end
    if r.mtext and (r.mtext:find("^SA") or r.mtext:find("^CA") or r.mtext:find("^LVL") or r.mtext:find("SP")) then
        need.walls.left, need.walls.right = true, true
    end
    if step and step.trigger and step.trigger.type == "rawdr" then
        need.walls.left = true
        need.arrows = { "6", "6" }
    end
    local named = (up == "DR" or up == "PARRY" or up == "DI" or up == "THROW")
    for _, l in ipairs(LANES) do
        local v = (not named) and r[l]
        if v then
            if v:find("P") then tap(l .. "P") end
            if v:find("K") then tap(l .. "K") end
            if v == "•" then tap(l .. "P") end          -- Modern L / M / H
        end
    end
    local any = r.any or ""
    if any:find("PP") then need.bars[#need.bars + 1] = { "LP", "MP" }; any = any:gsub("PP", "", 1) end
    if any:find("KK") then need.bars[#need.bars + 1] = { "LK", "MK" }; any = any:gsub("KK", "", 1) end
    if any:find("AUTO") then need.bars[#need.bars + 1] = { "LP", "HK" }; any = any:gsub("AUTO", "", 1) end
    if any:find("P") then need.bars[#need.bars + 1] = { "LP", "HP" } end
    if any:find("K") then need.bars[#need.bars + 1] = { "LK", "HK" } end
    need.hold = label:find("%[[LMH]?[PK][PK]?%]") ~= nil
    -- motion: arrows, and a charge "[4]6"
    if r.parts then
        local i = 1
        local parts = r.parts
        while i <= #parts do
            local p = parts[i]
            if p.t == "text" and p.s == "[" and parts[i + 1] and parts[i + 1].t == "motion" then
                need.charge = parts[i + 1].seq:sub(1, 1)
                i = i + 3
            elseif p.t == "motion" then
                for d in tostring(p.seq):gmatch("%d") do if d ~= "5" then need.arrows[#need.arrows + 1] = d end end
                i = i + 1
            elseif p.t == "circle" then
                for _, d in ipairs({ "6", "3", "2", "1", "4" }) do need.arrows[#need.arrows + 1] = d end
                i = i + 1
            else
                i = i + 1
            end
        end
    end
    aaa_cache[key] = need
    return need
end

-- big chunky arrow (40x40 box, pointing right), rotated to numpad direction d
local AR_OUT = { 3, 13, 19, 13, 19, 3, 38, 20, 19, 37, 19, 27, 3, 27, 3, 13 }
local AR_HI = { 7, 17, 23, 17, 23, 11, 32, 20 }
local AR_ANG = { ["6"] = 0, ["3"] = 1, ["2"] = 2, ["1"] = 3, ["4"] = 4, ["7"] = 5, ["8"] = 6, ["9"] = 7 }
local function aaa_arrow(d, cx, cy, size, outline, alpha)
    local a = (AR_ANG[tostring(d)] or 0) * math.pi / 4
    local ca, sa = math.cos(a), math.sin(a)
    local z = size / 40
    local function tr(src)
        local out = {}
        for i = 1, #src, 2 do
            local x, y = src[i] - 20, src[i + 1] - 20
            out[i] = cx + (x * ca - y * sa) * z
            out[i + 1] = cy + (x * sa + y * ca) * z
        end
        return out
    end
    local o = tr(AR_OUT)
    if outline then
        stroke(o, 8 * z, with_alpha(AAA.arrow_dark, alpha))
        stroke(o, 4 * z, with_alpha(AAA.arrow_ol, alpha))
        return
    end
    stroke(o, 3.5 * z, with_alpha(AAA.arrow_dark, alpha))
    local col = with_alpha(AAA.arrow, alpha)
    -- shaft (3,13)-(19,27) and head (19,3)(38,20)(19,37)
    draw.filled_quad(o[1], o[2], o[3], o[4], o[11], o[12], o[13], o[14], col)
    draw.filled_quad(o[5], o[6], o[7], o[8], o[9], o[10], (o[5] + o[9]) / 2, (o[6] + o[10]) / 2, col)
    stroke(tr(AR_HI), 2.5 * z, with_alpha(AAA.arrow_hi, alpha * 0.9))
end
Overlay.aaa_arrow = aaa_arrow

local function aaa_apple(x, y, r)
    draw.filled_circle(x, y + r * 0.15, r * 1.25, rgba(0, 0, 0, 120), 24)
    draw.filled_circle(x - r * 0.38, y, r * 0.78, AAA.apple, 24)
    draw.filled_circle(x + r * 0.38, y, r * 0.78, AAA.apple, 24)
    draw.filled_circle(x, y + r * 0.22, r * 0.85, AAA.apple, 24)
    draw.filled_circle(x - r * 0.42, y - r * 0.22, r * 0.2, rgba(255, 190, 205, 220), 12)
    draw.line(x, y - r * 0.55, x + r * 0.12, y - r * 1.05, rgba(110, 60, 20), math.max(2, r * 0.16))
    draw.filled_quad(x + r * 0.1, y - r * 0.8, x + r * 0.55, y - r * 1.15, x + r * 0.95, y - r * 1.0, x + r * 0.5, y - r * 0.7, AAA.leaf)
end

local function aaa_hex(cx, cy, r, col)
    local p = {}
    for i = 0, 5 do
        local a = i * math.pi / 3
        p[#p + 1] = cx + math.cos(a) * r; p[#p + 1] = cy + math.sin(a) * r
    end
    draw.filled_quad(p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], col)
    draw.filled_quad(p[7], p[8], p[9], p[10], p[11], p[12], p[1], p[2], col)
end

-- session tallies (reset when the combo changes)
local aaa_tally = { key = nil, SWEET = 0, GOOD = 0, DROP = 0, seen = {} }

function Overlay.apple(S, W, H, sc, top)
    local P, combo, cfg = S.profile, S.combo, S.cfg
    local steps = combo.steps
    local N = #steps
    local labels = {}
    local live = S.tracker:live_detail()
    local now = S.tracker:now() or 0
    local fnow = Overlay.ftime(S, now)
    local clock = os.clock()
    local T, first, A = Overlay.timeline(S, live, fnow)
    A = math.max(10, A)

    -- tallies from the judgement log
    local ck = tostring(combo.id or combo.name or "")
    if aaa_tally.key ~= ck then aaa_tally = { key = ck, SWEET = 0, GOOD = 0, DROP = 0, seen = {} } end
    for id, e in pairs(judge_log) do
        if id ~= "_last" and type(e) == "table" and not aaa_tally.seen[e] then
            aaa_tally.seen[e] = true
            local k = aaa_kind(e.text)
            if k == "SWEET" then aaa_tally.SWEET = aaa_tally.SWEET + 1
            elseif k == "DROP" then aaa_tally.DROP = aaa_tally.DROP + 1
            else aaa_tally.GOOD = aaa_tally.GOOD + 1 end
        end
    end

    -- geometry: plane units -> screen
    local k = 1.2 * sc                                   -- pixels per plane unit at the line
    local NW = AAA_PLANE * k
    local Hp = math.min(H * 0.62, 600 * sc)
    local F = 1.1                                        -- depth: the far end is 1/(1+F) as wide
    local s1 = 1 / (1 + F)
    local pos = cfg.fix_pos
    local cx = (pos == "left" and (W * 0.05 + NW / 2)) or (pos == "right" and (W * 0.95 - NW / 2)) or W / 2
    local yb = top + Hp
    local function proj(u, t)
        local s = 1 / (1 + math.max(-0.3, t) * F)
        return cx + (u - AAA_PLANE / 2) * k * s, yb - Hp * (1 - s) / (1 - s1), s
    end
    local function tt(frame) return (frame - fnow) / A end
    local function quad(u0, u1, t0, t1, col)
        local ax, ay = proj(u0, t0)
        local bx, by = proj(u1, t0)
        local cx2, cy2 = proj(u1, t1)
        local dx, dy = proj(u0, t1)
        draw.filled_quad(ax, ay, bx, by, cx2, cy2, dx, dy, col)
    end
    local TMIN = -0.08

    -- floor, walls, lanes
    quad(0, AAA_PLANE, TMIN, 1, AAA.floor)
    quad(0, 24, TMIN, 1, AAA.wall_bg)
    quad(AAA_PLANE - 24, AAA_PLANE, TMIN, 1, AAA.wall_bg)
    quad(-2, 0, TMIN, 1, AAA.wall)
    quad(AAA_PLANE, AAA_PLANE + 2, TMIN, 1, AAA.wall)
    for i = 0, 5 do
        local u0 = 24 + i * 56
        local n = ({ "L", "M", "H" })[(i % 3) + 1]
        quad(u0 + 26.5, u0 + 29.5, TMIN, 1, with_alpha(AAA[n], 0.22))
        if i < 5 and i ~= 2 then quad(u0 + 55.5, u0 + 56.5, TMIN, 1, AAA.sep) end
    end
    quad(190, 194, TMIN, 1, with_alpha(AAA.divider, 0.8))

    -- beat lines (song mode)
    if S.song and S.song.B then
        local B = S.song.B
        local k0 = math.ceil((fnow - S.song.t0) / B)
        for b = k0, k0 + math.ceil(A / B) + 1 do
            local t = tt(S.song.t0 + b * B)
            if t > 0 and t < 1 then quad(0, AAA_PLANE, t, t + 0.004, rgba(60, 72, 104, 200)) end
        end
    end

    -- next step
    local nxt
    for j = first, N do if T[j] and T[j] > fnow - 6 then nxt = j break end end

    -- collect what's on screen
    local DT = 0.03                                     -- note thickness (fraction of the highway)
    local GAP = 0.085 * A                               -- frames between arrows of one motion (at most)
    local items = {}
    for j = first, N do
        local Tj = T[j]
        if Tj then
            local t = tt(Tj)
            local need = Overlay.aaa_need(steps[j].label, steps[j])
            local n = #need.arrows
            -- squeeze the motion into the time since the previous step
            local room = (j > 1 and T[j - 1]) and (Tj - T[j - 1]) or A
            local gap = (n > 1) and math.min(GAP, math.max(1, room * 0.75 / (n - 1 + (need.charge and 1 or 0)))) or GAP
            local clen = need.charge and math.min(A * 0.3, math.max(gap, room * 0.6 - (n - 1) * gap)) or 0
            local lead = (n > 0 and (n - 1) * gap or 0) + clen
            if t - lead / A < 1.05 and t > TMIN - 0.15 then
                items[#items + 1] = { j = j, T = Tj, t = t, need = need, gap = gap, clen = clen }
            end
        end
    end

    -- press windows behind the notes
    for _, it in ipairs(items) do
        local w = it.j >= 2 and P:window(it.j) or nil
        if w and w.E and w.L and w.mid and it.t > 0.02 then
            local need = it.need
            local u0, u1 = 24, AAA_PLANE - 24
            local lo, hi = math.huge, -math.huge
            for _, l in ipairs(need.taps) do lo = math.min(lo, AAA_LANE_U[l] - 28); hi = math.max(hi, AAA_LANE_U[l] + 28) end
            for _, b in ipairs(need.bars) do lo = math.min(lo, AAA_LANE_U[b[1]] - 28); hi = math.max(hi, AAA_LANE_U[b[2]] + 28) end
            if lo < hi then u0, u1 = lo + 2, hi - 2 end
            local t0, t1 = tt(it.T - (w.mid - w.E)), math.min(1, tt(it.T + (w.L - w.mid) + 1))
            local cur = it.j == nxt
            if t0 < 1 then
            quad(u0 - 1.5, u1 + 1.5, t0, t1, with_alpha(AAA.win_edge, cur and 0.9 or 0.45))
            quad(u0, u1, t0 + 0.003, t1 - 0.003, with_alpha(AAA.win, cur and 1 or 0.6))
            if w.sweet_lo then
                local s0, s1 = tt(it.T + w.sweet_lo - w.mid), math.min(1, tt(it.T + w.sweet_hi - w.mid + 1))
                if s0 < s1 then quad(u0, u1, s0, s1, with_alpha(AAA.sweet, cur and 1 or 0.6)) end
            end
            end
        end
    end

    -- lever rail: neutral, bending out for motions and charges
    local pts = { { f = fnow + TMIN * A, u = AAA_LEVER.neutral } }
    local charges = {}
    local function add_pt(f, u)
        -- a later step's motion cuts off what's left of the one before it
        while #pts > 1 and pts[#pts].f >= f do pts[#pts] = nil end
        pts[#pts + 1] = { f = f, u = u }
    end
    for _, it in ipairs(items) do
        local need = it.need
        local n = #need.arrows
        local gap = it.gap
        if n > 0 or need.charge then
            local t_first = it.T - (n > 0 and (n - 1) * gap or 0)
            if need.charge then
                local c0, c1 = t_first - it.clen, t_first - gap * 0.6
                add_pt(c0 - 1.5, AAA_LEVER.neutral)
                add_pt(c0, lever_of(need.charge))
                add_pt(c1, lever_of(need.charge))
                charges[#charges + 1] = { c0, c1, lever_of(need.charge) }
            else
                add_pt(t_first - gap * 0.6, AAA_LEVER.neutral)
            end
            for i, d in ipairs(need.arrows) do
                add_pt(it.T - (n - i) * gap, lever_of(d))
            end
            add_pt(it.T + gap * 0.4, n > 0 and lever_of(need.arrows[n]) or AAA_LEVER.neutral)
            add_pt(it.T + gap * 0.9, AAA_LEVER.neutral)
        end
    end
    if pts[#pts].f < fnow + A then pts[#pts + 1] = { f = fnow + A * 1.05, u = pts[#pts].u } end
    local poly = {}
    for i, p in ipairs(pts) do
        local t = tt(p.f)
        local u = p.u
        if t > 1 then
            -- clip the segment at the far end of the highway
            local q = pts[i - 1]
            if q then
                local tq = tt(q.f)
                local r = (1 - tq) / math.max(1e-6, t - tq)
                u = q.u + (p.u - q.u) * r
            end
            t = 1
        end
        local x, y = proj(u, math.max(TMIN, t))
        poly[#poly + 1] = x; poly[#poly + 1] = y
        if t >= 1 then break end
    end
    stroke(poly, 6 * k, with_alpha(AAA.rail, 0.9))
    for _, c in ipairs(charges) do
        local t0, t1 = math.max(TMIN, tt(c[1])), math.min(1, tt(c[2]))
        if t1 > t0 then quad(c[3] - 9, c[3] + 9, t0, t1, with_alpha(AAA.charge, 0.95)) end
    end

    -- notes, far to near
    local busy = {}       -- button notes by time, for the arrow outline rule
    table.sort(items, function(a, b) return a.T > b.T end)
    for _, it in ipairs(items) do
        local need, t = it.need, it.t
        if t > TMIN and t < 1.02 then
            local cur = it.j == nxt
            local fade = t < 0 and math.max(0, 1 + t / -TMIN) or 1
            local bright = (cur and 1 or 0.8) * fade
            local function note(u0, u1, col)
                if need.hold then quad(u0 + 8, u1 - 8, t, math.min(1, t + 0.18), with_alpha(col, 0.35 * bright)) end
                quad(u0 - 2, u1 + 2, t - DT / 2 - 0.004, t + DT / 2 + 0.004, with_alpha(rgba(5, 8, 14), 0.9 * fade))
                quad(u0, u1, t - DT / 2, t + DT / 2, with_alpha(col, bright))
                quad(u0 + 3, u1 - 3, t + DT / 2 - 0.007, t + DT / 2 - 0.003, with_alpha(rgba(255, 255, 255), 0.55 * bright))
                busy[#busy + 1] = { T = it.T, u0 = u0, u1 = u1 }
            end
            for _, l in ipairs(need.taps) do
                local u = AAA_LANE_U[l]
                note(u - 25, u + 25, AAA[l:sub(1, 1)])
            end
            for _, b in ipairs(need.bars) do
                local u0, u1 = AAA_LANE_U[b[1]] - 25, AAA_LANE_U[b[2]] + 25
                local c0, c1 = AAA[b[1]:sub(1, 1)], AAA[b[2]:sub(1, 1)]
                note(u0, (u0 + u1) / 2, c0)
                note((u0 + u1) / 2, u1, c1)
            end
            if need.walls.left then
                quad(2, 22, t - DT, t + DT, with_alpha(AAA.wall, bright))
                quad(-6, 0, t - DT * 1.5, t + DT * 1.5, with_alpha(AAA.wall, 0.6 * bright))
            end
            if need.walls.right then
                quad(AAA_PLANE - 22, AAA_PLANE - 2, t - DT, t + DT, with_alpha(AAA.wall, bright))
                quad(AAA_PLANE, AAA_PLANE + 6, t - DT * 1.5, t + DT * 1.5, with_alpha(AAA.wall, 0.6 * bright))
            end
            -- the next step's label, beside the highway
            if cur and t > 0.02 then
                local x, y = proj(AAA_PLANE + 14, t)
                labels[#labels + 1] = { x = x + 70 * sc, y = y, text = steps[it.j].label, col = rgba(241, 245, 249, 230), size = 24, step = true }
            end
        end
    end

    -- arrows on the rail, far to near, on top of the notes
    local arrows = {}
    for _, it in ipairs(items) do
        local n = #it.need.arrows
        for i, d in ipairs(it.need.arrows) do
            arrows[#arrows + 1] = { f = it.T - (n - i) * it.gap, d = d, cur = it.j == nxt, squeeze = math.max(0.55, math.min(1, it.gap / GAP)) }
        end
    end
    table.sort(arrows, function(a, b) return a.f > b.f end)
    for _, a in ipairs(arrows) do
        local t = tt(a.f)
        if t > TMIN and t < 1.02 then
            local u = lever_of(a.d)
            local x, y, s = proj(u, t)
            local size = 46 * k * s * a.squeeze
            local outline = false
            for _, b in ipairs(busy) do
                if math.abs(b.T - a.f) <= 1.5 and u + 23 > b.u0 and u - 23 < b.u1 then outline = true break end
            end
            local fade = t < 0 and math.max(0, 1 + t / -TMIN) or 1
            aaa_arrow(a.d, x, y - size * 0.15, size, outline, fade * (a.cur and 1 or 0.85))
        end
    end

    -- judgement line and receptors
    do
        local jl = judge_log._last
        local flash = (jl and clock - jl.t < 0.25) and (1 - (clock - jl.t) / 0.25) or 0
        quad(0, AAA_PLANE, -0.012, 0.012, rgba(255, 255, 255, 60 + math.floor(140 * flash)))
        quad(0, AAA_PLANE, -0.004, 0.004, rgba(255, 255, 255, 230))
        for l, u in pairs(AAA_LANE_U) do quad(u - 25, u + 25, -0.006, 0.006, with_alpha(AAA[l:sub(1, 1)], 0.8)) end
    end

    -- the apple follows the stick
    do
        local d = S.stick_dir or 5
        local u = lever_of(d)
        local x, y = proj(u, 0)
        if d == 7 or d == 8 or d == 9 then y = y - 10 * sc elseif d == 1 or d == 2 or d == 3 then y = y + 6 * sc end
        aaa_apple(x, y, 15 * sc)
    end

    -- judgement text
    local jl = judge_log._last
    if jl and clock - jl.t < 0.8 then
        local a = 1 - (clock - jl.t) / 0.8
        local _, y = proj(AAA_PLANE / 2, 0.22)
        labels[#labels + 1] = { x = cx, y = y - 20 * sc * (1 - a), text = jl.text, col = with_alpha(AAA[aaa_kind(jl.text)] or C.white, a), size = 40 }
    end
    if live and live.c and live.c > 2 and not live.failed then
        local _, y = proj(AAA_PLANE / 2, 0.36)
        labels[#labels + 1] = { x = cx, y = y, text = tostring(live.c - 1) .. " combo", col = rgba(120, 200, 255, 200), size = 24 }
    end
    if S.song and S.song.count then
        local pulse = 1 - (S.song.beat_phase or 0)
        local _, y = proj(AAA_PLANE / 2, 0.5)
        labels[#labels + 1] = { x = cx, y = y, text = S.song.count, col = with_alpha(C.yellow, 0.5 + 0.5 * pulse), size = 40 }
    elseif not live and not S.song then
        local _, y = proj(AAA_PLANE / 2, 0.5)
        labels[#labels + 1] = { x = cx, y = y, text = "start when ready", col = C.dim, size = 18 }
    end

    -- HUD: tallies and streak on one side, the dummy as the "enemy" on the other
    local hl, hr = 28 * sc, W - 28 * sc
    local hy = top - 40 * sc
    local left_free = pos ~= "left"
    local right_free = pos ~= "right"
    local hx = left_free and hl or (W - 28 * sc - 300 * sc)
    local ex = right_free and hr or (hl + 300 * sc)
    local ey = (left_free == right_free) and hy or (hy + 200 * sc)
    if not left_free then hx, ex = W - 28 * sc - 300 * sc, W - 28 * sc end
    labels[#labels + 1] = { x = hx + 150 * sc, y = hy, text = "APPLE ADDICT ATTACK", col = AAA.title, size = 32 }
    local bw, gw = 92 * sc, 8 * sc
    for i, kname in ipairs({ "SWEET", "GOOD", "DROP" }) do
        local bx = hx + (i - 1) * (bw + gw)
        draw.filled_rect(bx, hy + 26 * sc, bw, 58 * sc, AAA.panel)
        draw.outline_rect(bx, hy + 26 * sc, bw, 58 * sc, rgba(42, 53, 80))
        labels[#labels + 1] = { x = bx + bw / 2, y = hy + 46 * sc, text = tostring(aaa_tally[kname]), col = (kname == "DROP" and aaa_tally.DROP == 0) and C.white or AAA[kname], size = 32 }
        labels[#labels + 1] = { x = bx + bw / 2, y = hy + 72 * sc, text = kname, col = rgba(167, 179, 201), size = 18 }
    end
    local st = S.stats or {}
    local streak = st.streak or 0
    for i = 1, 5 do
        local dx, dy = hx + 9 * sc + (i - 1) * 20 * sc, hy + 104 * sc
        if i <= streak then draw.filled_circle(dx, dy, 7 * sc, AAA.title, 16)
        else draw.outline_circle(dx, dy, 7 * sc, rgba(71, 85, 105), 16) end
    end
    labels[#labels + 1] = { x = hx + 112 * sc + 90 * sc, y = hy + 104 * sc, text = streak == 1 and "1 clean run" or (tostring(streak) .. " clean runs in a row"), col = rgba(203, 213, 225), size = 18 }
    -- the enemy: hits and damage of the combo in progress (or the last one)
    do
        local hits, dmg = S.combo_hits or 0, S.combo_dmg or 0
        local r = 40 * sc
        local hcx, hcy = ex - r, ey + r + 10 * sc
        aaa_hex(hcx, hcy, r, AAA.enemy)
        aaa_hex(hcx, hcy, r - 5 * sc, rgba(26, 18, 6, 240))
        labels[#labels + 1] = { x = hcx, y = hcy - 4 * sc, text = tostring(hits), col = rgba(253, 186, 116), size = 32 }
        labels[#labels + 1] = { x = hcx, y = hcy + 20 * sc, text = "hits", col = rgba(253, 186, 116), size = 18 }
        labels[#labels + 1] = { x = hcx - r - 80 * sc, y = hcy - 14 * sc, text = "DUMMY", col = rgba(241, 245, 249), size = 18 }
        labels[#labels + 1] = { x = hcx - r - 80 * sc, y = hcy + 10 * sc, text = tostring(dmg) .. " damage", col = rgba(203, 213, 225), size = 18 }
    end

    return labels, yb + 20 * sc
end

-- --------------------------------------------------------------------------
-- main draw (called from re.on_frame)
-- S = { mode, combo, profile, tracker, last, stats, cfg, msg }
-- --------------------------------------------------------------------------
function Overlay.draw(S)
    Overlay.frame_id = Overlay.frame_id + 1
    local cfg = S.cfg
    Overlay.text_scale = math.max(0.75, math.min(2.5, tonumber(cfg.text_scale) or 1.4))
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
    local fix_on = S.mode == "train" and view == "fix" and N >= 2 and S.profile ~= nil
    local aaa_on = S.mode == "train" and view == "aaa" and N >= 2 and S.profile ~= nil
    local bar_on = not ((notes_on and view == "notes") or fix_on or aaa_on)
    local note_labels, notes_bottom = nil, nil
    -- room for the text lines above a note view, at the current text size
    local _, lh_mid = measure("Ag", font(32 * sc))
    local _, lh_big = measure("Ag", font(34 * sc))
    -- note view layout: [bar] / notation line / ring / result
    local notes_ny = nil
    if notes_on then
        notes_ny = bar_on and (by + bh + 34 * sc) or by
        note_labels, notes_bottom = Overlay.notes(S, W, H, sc, notes_ny + math.max(56 * sc, lh_mid + 22 * sc))
    elseif fix_on then
        -- notation line, then the result line, then the lanes
        notes_ny = by
        note_labels = Overlay.fixation(S, W, H, sc, by + math.max(110 * sc, lh_mid + lh_big + 46 * sc))
    elseif aaa_on then
        notes_ny = by
        note_labels = Overlay.apple(S, W, H, sc, by + math.max(110 * sc, lh_mid + lh_big + 46 * sc))
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
    -- a long combo in big text: shrink the notation line to fit the screen
    if total > W * 0.94 then
        local f2 = font(32 * sc * (W * 0.94 / total))
        if f2 ~= f_mid then
            f_mid, total = f2, 0
            for _, p in ipairs(pieces) do
                p.items, p.w = rich(p[1], f_mid, arrows and not p.sep)
                total = total + p.w
            end
        end
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
            l.f = l.size and font(l.size * sc) or ((l.big or l.judge) and f_mid or (l.note and f_note or f_sm))
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
        pcall(imgui.set_window_font_scale, 1.0)

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
        -- above the notation panel, clear of it however big the text is
        local _, sm_h = measure("Ag", f_sm)
        local tag_y = math.min(by - 26 * sc, (notes_ny or by) - pad * 0.6 - sm_h - 4 * sc)
        text_at(bx, tag_y, tag, S.bot_status and C.magenta or (S.mode == "train" and C.orange or C.cyan), f_sm)
        if combo then
            local nm = combo.name or combo.id or ""
            local tw = measure(nm, f_sm)
            text_at(bx + bw - tw, tag_y, nm, C.dim, f_sm)
        end

        if S.song and S.song.count and not notes_on and not fix_on and not aaa_on then
            local tw = measure(S.song.count, f_big)
            text_at(W / 2 - tw / 2, by - 64 * sc, S.song.count, C.yellow, f_big)
        end
        if S.song_flash and os.clock() - S.song_flash.t < 1.5 then
            local tw = measure(S.song_flash.text, f_mid)
            text_at(W / 2 - tw / 2, by - 64 * sc, S.song_flash.text, C.orange, f_mid)
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
