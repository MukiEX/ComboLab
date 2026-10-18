-- Renders the note view over time (mock imgui/draw) for a GIF preview.
package.path = "reframework/autorun/?.lua;" .. package.path
local OUT = arg[1] or "/tmp/claude-0/notes"
local NF = tonumber(arg[2] or "48")
local calls, cur, font_stack = {}, { x = 0, y = 0 }, {}
local CLK = 0
os.clock = function() return CLK end
Vector2f = { new = function(x, y) return { x = x, y = y } end }
local function fsize() return font_stack[#font_stack] or 13 end
draw = {
    filled_rect = function(x, y, w, h, c) calls[#calls + 1] = { "rect", x, y, w, h, c } end,
    outline_rect = function(x, y, w, h, c) calls[#calls + 1] = { "orect", x, y, w, h, c } end,
    filled_circle = function(x, y, r, c) calls[#calls + 1] = { "circle", x, y, r, c } end,
    outline_circle = function(x, y, r, c) calls[#calls + 1] = { "ocircle", x, y, r, c } end,
    line = function(x1, y1, x2, y2, c, t) calls[#calls + 1] = { "line", x1, y1, x2, y2, c, t or 1 } end,
}
imgui = setmetatable({
    get_display_size = function() return { x = 1920, y = 1080 } end,
    load_font = function(_, px) return { px = px } end,
    push_font = function(f) font_stack[#font_stack + 1] = f.px end,
    pop_font = function() font_stack[#font_stack] = nil end,
    set_cursor_pos = function(v) cur = v end,
    calc_text_size = function(s) return { x = #s * fsize() * 0.55, y = fsize() } end,
    text_colored = function(s, c) calls[#calls + 1] = { "text", cur.x, cur.y, s, c, fsize() } end,
    begin_window = function() return true end,
}, { __index = function() return function() end end })
local Profile = require("combolab.profile")
local Overlay = require("combolab.overlay")
local labels = { "2LK", "2LP", "2LP", "DR", "5LP", "5HK", "5LP", "5LK", "236MK" }
local seps = { "start", ",", ",", ">", ">", ",", ",", ",", ">" }
local combo = { id = "x", hash = "h", name = "Mai: Lights DRC (example)", steps = {} }
for i, l in ipairs(labels) do combo.steps[i] = { label = l, sep = seps[i], kind = (l == "DR") and "move" or "hit", trigger = { mask = 16 } } end
local P = Profile.new(combo)
local wins = { nil, { 6, 10 }, { 6, 10 }, { 3, 9 }, { 8, 12 }, { 9, 14 }, { 12, 16 }, { 6, 9 }, { 4, 10 } }
for k = 2, #labels do
    for _ = 1, 10 do
        local p = math.random(wins[k][1], wins[k][2])
        P.steps[k].samples[#P.steps[k].samples + 1] = { p = p, q = p + 1, res = "ok", spam = 0, nx = (p <= wins[k][1] + 2) and 1 or 0 }
    end
end
local ANCHOR = 100
local tick = 96
local live = { c = 2, anchor = ANCHOR, steps = { [1] = { res = "ok" } } }
local tracker = { live_detail = function() return live end, now = function() return tick end }
local S = { mode = "train", combo = combo, profile = P, tracker = tracker, last = nil, result_age = 99,
    stats = { n = 7, ok = 5, streak = 3, best = 4 }, msg_age = 99, version = "1.4.0", attempt_seq = 1,
    cfg = { scale = 1.0, y = 0.25, result_seconds = 4, train_view = "notes", note_approach = 36, note_palette = os.getenv("PAL") or "classic" } }
-- simulate: the player hits each step on its target frame
local function target(k) return P:window(k).mid end
local hit = {}
for f = 0, NF - 1 do
    tick = 96 + f * 2
    CLK = f * 2 / 60
    S.tick_clock = CLK
    -- advance live state when the current step's target passes
    while live.c <= #labels and tick >= live.anchor + target(live.c) do
        local k = live.c
        live.steps[k] = { res = "ok", p = math.floor(target(k) + 0.5), off = 0 }
        live.anchor = live.anchor + math.floor(target(k) + 0.5) + 1
        live.c = k + 1
        live._changed = true
    end
    calls = {}
    Overlay.draw(S)
    local fo = io.open(string.format("%s/c%03d.json", OUT, f), "w")
    local parts = {}
    for _, c in ipairs(calls) do
        local q = {}
        for i, v in ipairs(c) do q[i] = type(v) == "string" and string.format("%q", v) or tostring(v) end
        parts[#parts + 1] = "[" .. table.concat(q, ",") .. "]"
    end
    fo:write("[" .. table.concat(parts, ",\n") .. "]"); fo:close()
end
print("frames written")
