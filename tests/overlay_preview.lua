-- Renders the overlay against mocked imgui/draw and records every call to JSON
-- (tests/render_overlay.py turns that into a PNG on top of a game screenshot).
package.path = "reframework/autorun/?.lua;tests/?.lua;" .. package.path
local calls = {}
local cur = { x = 0, y = 0 }
local font_stack, fonts = {}, {}
Vector2f = { new = function(x, y) return { x = x, y = y } end }
local function fsize() return font_stack[#font_stack] or 13 end
draw = {
    filled_rect = function(x, y, w, h, c) calls[#calls + 1] = { "rect", x, y, w, h, c } end,
    outline_rect = function(x, y, w, h, c) calls[#calls + 1] = { "orect", x, y, w, h, c } end,
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
-- tiny json decode via python-generated lua? keep it simple: steps by hand
local labels = { "2LP","2LP","5LK","DR","5LP","5HP","DR","5HK","5MP","4HP","[2]8HK" }
local seps = { "start", ">", ",", ">", ">", ",", ">", ">", ",", "~", ">" }
local combo = { id = "x", hash = "h", name = "Guile: DR BnB (example)", steps = {} }
for i, l in ipairs(labels) do combo.steps[i] = { label = l, sep = seps[i], kind = (l == "DR") and "move" or "hit", trigger = { mask = 16 } } end
local P = Profile.new(combo)
math.randomseed(3)
local wins = { nil, { 3, 9 }, { 10, 14 }, { 5, 11 }, { 2, 8 }, { 12, 15 }, { 4, 10 }, { 2, 7 }, { 13, 16 }, { 6, 11 }, { 9, 18 } }
for k = 2, #labels do
    local w = wins[k]
    for _ = 1, 14 do
        local p = math.random(w[1], w[2])
        P.steps[k].samples[#P.steps[k].samples + 1] = { p = p, res = "ok", spam = 0, q = p + 1, k = p + 5, r = 3, o = w[1] + 1 }
    end
    P.steps[k].samples[#P.steps[k].samples + 1] = { p = w[2] + 2, res = "late", spam = 0 }
    P.steps[k].samples[#P.steps[k].samples + 1] = { p = w[1] - 2, res = "early", spam = 0 }
end
P.attempts, P.successes = 37, 22
local mode = arg[1] or "train"
local CLK = tonumber(arg[3] or "0"); os.clock = function() return CLK end
local last = { ok = false, fail_step = 8, steps = {} }
for k = 1, 7 do last.steps[k] = { res = "ok", p = k > 1 and (wins[k][1] + 2) or nil, off = 0 } end
last.steps[3].off = 0
last.steps[8] = { res = "late", p = wins[8][2] + 3, off = 3, hint = "came out but did not connect (late or out of range)" }
local S = { mode = mode, combo = combo, profile = P, tracker = { live_detail = function() return nil end },
    last = last, result_age = tonumber(arg[4] or "1"), stats = { n = 20, ok = 13, streak = 2, best = 6 },
    cfg = { scale = 1.0, y = 0.25, result_seconds = 4, spam_block = true, show_detail = (mode == "develop") }, msg_age = 99 }
Overlay.draw(S)
local out = {}
for _, c in ipairs(calls) do
    local parts = {}
    for i, v in ipairs(c) do parts[i] = type(v) == "string" and string.format("%q", v) or tostring(v) end
    out[#out + 1] = "[" .. table.concat(parts, ",") .. "]"
end
local fo = io.open(arg[2] or "/tmp/claude-0/overlay_calls.json", "w"); fo:write("[" .. table.concat(out, ",\n") .. "]"); fo:close()
print(#calls .. " calls")
