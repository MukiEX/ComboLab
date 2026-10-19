-- ComboLab: turns step labels like "623HP", "j.214P", "[2]8HK", "236236K"
-- into motion-arrow glyphs plus button text. Pure Lua: geometry only, the
-- overlay does the drawing (and the web page mirrors this logic in JS).
local Motion = {}

-- numpad direction -> angle (radians, screen space: y grows downward, so
-- increasing angle runs clockwise on screen). 5 is the centre.
local ANG = { [6] = 0, [3] = 1, [2] = 2, [1] = 3, [4] = 4, [7] = 5, [8] = 6, [9] = 7 }   -- x 45 degrees

local function pos(d)
    if d == 5 then return 0, 0 end
    local a = ANG[d] * math.pi / 4
    return math.cos(a), math.sin(a)
end

-- ring distance between two directions, signed (-4..4); nil if either is 5
local function ring_step(a, b)
    if a == 5 or b == 5 then return nil end
    local s = (ANG[b] - ANG[a]) % 8
    if s > 4 then s = s - 8 end
    return s
end

-- --------------------------------------------------------------- parsing
-- Returns a list of parts: { t = "text", s = "HP" } | { t = "motion", seq = "623" }
-- | { t = "circle" } (360). A charge "[2]" becomes text "[", motion "2", text "]".
function Motion.parse(label)
    label = tostring(label or "")
    local parts = {}
    local function text(s) if s and s ~= "" then parts[#parts + 1] = { t = "text", s = s } end end
    local up = label:upper()

    -- dashes and plain jumps
    if up == "66" or up == "44" then
        local d = up:sub(1, 1)
        parts[1] = { t = "motion", seq = d }; parts[2] = { t = "motion", seq = d }
        return parts
    end

    -- follow-ups written inside one step ("236K~K")
    if label:find("~", 1, true) then
        local first = true
        for piece in label:gmatch("[^~]+") do
            if not first then text("~") end
            for _, p in ipairs(Motion.parse(piece)) do parts[#parts + 1] = p end
            first = false
        end
        return parts
    end

    local body = label
    if body:match("^[Jj]%.") then text(body:sub(1, 2)); body = body:sub(3) end
    if body:match("^[Cc][Rr]%.") then body = "2" .. body:sub(4)
    elseif body:match("^[Ss][Tt]%.") then body = "5" .. body:sub(4) end

    local charge, rest = body:match("^%[(%d)%](.*)$")
    if charge then body = rest end
    local digits, btn = body:match("^(%d*)(.*)$")
    if not digits or (not charge and digits == "") then return { { t = "text", s = label } } end

    if charge then
        if charge == "5" then return { { t = "text", s = label } } end
        -- held direction, shown in brackets like the notation: [v]^HK
        text("[")
        parts[#parts + 1] = { t = "motion", seq = charge }
        text("]")
    end
    if digits == "360" or digits == "720" then
        parts[#parts + 1] = { t = "circle" }
        if digits == "720" then parts[#parts + 1] = { t = "circle" } end
    elseif digits ~= "" then
        if digits:find("0") then return { { t = "text", s = label } } end
        digits = digits:gsub("^5+", "")      -- neutral prefix ("5MP") carries no motion
        if digits ~= "" then
            local n = #digits
            local h = n // 2
            if n >= 2 and n % 2 == 0 and digits:sub(1, h) == digits:sub(h + 1) and not digits:find("5") then
                parts[#parts + 1] = { t = "motion", seq = digits:sub(1, h) }
                parts[#parts + 1] = { t = "motion", seq = digits:sub(1, h) }
            else
                parts[#parts + 1] = { t = "motion", seq = digits }
            end
        end
    end
    text(btn)
    if #parts == 0 then return { { t = "text", s = label } } end
    return parts
end

-- True when the label has anything to draw as an arrow.
function Motion.has_glyph(label)
    for _, p in ipairs(Motion.parse(label)) do if p.t ~= "text" then return true end end
    return false
end

-- --------------------------------------------------------------- geometry
-- Returns { lines = { {x,y, x,y, ...}, ... }, head = {x, y, dx, dy} | nil, aspect }
-- with coordinates normalised into a box of height 1 and width `aspect`
-- (0..aspect, 0..1). The first line carries the arrowhead at its end.
local function arc(out, a0, a1, r)
    local n = math.max(2, math.ceil(math.abs(a1 - a0) / (math.pi / 24)))
    for i = 1, n do
        local a = a0 + (a1 - a0) * i / n
        out[#out + 1] = math.cos(a) * r
        out[#out + 1] = math.sin(a) * r
    end
end

-- Rounds the corner at V between A and B with a quadratic curve, cutting at
-- most r into each side.
local function round_corner(out, ax, ay, vx, vy, bx, by, r)
    local la = math.sqrt((ax - vx) ^ 2 + (ay - vy) ^ 2)
    local lb = math.sqrt((bx - vx) ^ 2 + (by - vy) ^ 2)
    local ta, tb = math.min(r, la * 0.5) / la, math.min(r, lb * 0.5) / lb
    local p0x, p0y = vx + (ax - vx) * ta, vy + (ay - vy) * ta
    local p2x, p2y = vx + (bx - vx) * tb, vy + (by - vy) * tb
    for i = 0, 8 do
        local t = i / 8
        local u = 1 - t
        out[#out + 1] = u * u * p0x + 2 * u * t * vx + t * t * p2x
        out[#out + 1] = u * u * p0y + 2 * u * t * vy + t * t * p2y
    end
end

local function raw_path(p)
    local lines, main = {}, {}
    if p.t == "circle" then
        -- clockwise from 6 almost all the way round
        main[1], main[2] = 1, 0
        arc(main, 0, math.pi * 2 * 0.86, 1)
        lines[1] = main
        return lines
    end
    local seq = {}
    for c in p.seq:gmatch("%d") do if c ~= "5" then seq[#seq + 1] = tonumber(c) end end
    if #seq == 1 then
        local x, y = pos(seq[1])
        lines[1] = { -x * 0.9, -y * 0.9, x * 0.9, y * 0.9 }
        return lines, 0.6 + 0.5 * math.abs(x)      -- upright arrows narrow, flat ones wide
    end
    -- dragon punch (623 / 421): a plain "Z", head pointing forward along the bottom bar
    if #seq == 3 and (seq[1] == 6 or seq[1] == 4) and seq[2] == 2 and (seq[3] == seq[1] - 3) then
        local f = seq[1] == 6 and 1 or -1
        lines[1] = { 0, 0, f, 0, 0, 1, f * 1.1, 1 }
        return lines
    end
    -- everything else: each input is a heading. Straight runs for up / down /
    -- back / forward, short ones for diagonals, and gentle turns rounded off,
    -- so 236 reads "down, curve, forward ->" and 41236 is a "C" ending forward.
    local pts = { 0, 0 }
    local x, y = 0, 0
    for _, d in ipairs(seq) do
        local hx, hy = pos(d)
        local L = (d % 2 == 0) and 1 or 0.45
        x, y = x + hx * L, y + hy * L
        pts[#pts + 1] = x; pts[#pts + 1] = y
    end
    main[1], main[2] = pts[1], pts[2]
    local n = #pts // 2
    for i = 2, n - 1 do
        local ax, ay = pts[2 * i - 3], pts[2 * i - 2]
        local vx, vy = pts[2 * i - 1], pts[2 * i]
        local bx, by = pts[2 * i + 1], pts[2 * i + 2]
        local d1x, d1y, d2x, d2y = vx - ax, vy - ay, bx - vx, by - vy
        local cosang = (d1x * d2x + d1y * d2y) / math.sqrt((d1x * d1x + d1y * d1y) * (d2x * d2x + d2y * d2y))
        if cosang > 0.6 then
            round_corner(main, ax, ay, vx, vy, bx, by, 0.45)       -- 45-degree turn: smooth
        else
            main[#main + 1] = vx; main[#main + 1] = vy            -- sharp turn stays sharp
        end
    end
    main[#main + 1] = pts[2 * n - 1]; main[#main + 1] = pts[2 * n]
    lines[1] = main
    return lines
end

function Motion.glyph(p)
    local lines, fixed_aspect = raw_path(p)
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, l in ipairs(lines) do
        for i = 1, #l, 2 do
            minx = math.min(minx, l[i]); maxx = math.max(maxx, l[i])
            miny = math.min(miny, l[i + 1]); maxy = math.max(maxy, l[i + 1])
        end
    end
    local bw, bh = maxx - minx, maxy - miny
    -- straight arrows get a sensible box instead of a zero-width one
    local span = math.max(bw, bh, 0.01)
    local aspect = fixed_aspect or math.max(0.55, math.min(1.9, math.max(bw, 0.5 * span) / math.max(bh, 0.5 * span)))
    local s = math.min(aspect / math.max(bw, 0.01), 1 / math.max(bh, 0.01))
    local ox = (aspect - bw * s) / 2 - minx * s
    local oy = (1 - bh * s) / 2 - miny * s
    local out = {}
    for i, l in ipairs(lines) do
        local q = {}
        for j = 1, #l, 2 do q[j] = l[j] * s + ox; q[j + 1] = l[j + 1] * s + oy end
        out[i] = q
    end
    local m = out[1]
    local n = #m
    local dx, dy = m[n - 1] - m[n - 3], m[n] - m[n - 2]
    local dl = math.sqrt(dx * dx + dy * dy)
    if dl > 0 then dx, dy = dx / dl, dy / dl end
    return { lines = out, head = { m[n - 1], m[n], dx, dy }, aspect = aspect }
end

return Motion
