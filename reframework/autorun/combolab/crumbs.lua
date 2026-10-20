-- ComboLab: breadcrumbs for crashes. Before each action that touches the
-- game's own state (dummy and Training settings, game speed, teleports) a short
-- note goes to ComboLab\crumbs.json, and a heartbeat goes there every couple
-- of seconds. If the game dies, the next start sees that the last note came
-- right before the heartbeat stopped, and says what it was.
local Crumbs = {}
local PATH = "ComboLab\\crumbs.json"
local MAX = 24

local state = { started = os.time(), beat = os.time(), crumbs = {} }
Crumbs.previous = nil     -- { what, t, ago } when the last session ended right after an action

local function save()
    if type(json) == "table" and json.dump_file then pcall(json.dump_file, PATH, state) end
end

function Crumbs.init()
    local ok, old = false, nil
    if type(json) == "table" and json.load_file then ok, old = pcall(json.load_file, PATH) end
    if ok and type(old) == "table" and type(old.crumbs) == "table" then
        local last = old.crumbs[#old.crumbs]
        -- the heartbeat stopped within 3 s of the last action: that's the suspect
        if type(last) == "table" and tonumber(last.t) and tonumber(old.beat) and tonumber(last.t) >= tonumber(old.beat) - 3 then
            Crumbs.previous = { what = tostring(last.what), t = tonumber(last.t), recent = {} }
            for i = math.max(1, #old.crumbs - 5), #old.crumbs do
                local c = old.crumbs[i]
                if type(c) == "table" then Crumbs.previous.recent[#Crumbs.previous.recent + 1] = tostring(c.what) end
            end
        end
    end
    state = { started = os.time(), beat = os.time(), crumbs = {} }
    save()
end

-- note an action that's about to touch the game
function Crumbs.add(what)
    state.crumbs[#state.crumbs + 1] = { t = os.time(), what = tostring(what) }
    while #state.crumbs > MAX do table.remove(state.crumbs, 1) end
    state.beat = os.time()
    save()
end

-- once a frame; writes every 2 s
local last_beat = 0
function Crumbs.beat()
    local c = os.clock()
    if c - last_beat < 2 then return end
    last_beat = c
    state.beat = os.time()
    save()
end

function Crumbs.recent(n)
    local out = {}
    for i = math.max(1, #state.crumbs - (n or 8) + 1), #state.crumbs do out[#out + 1] = state.crumbs[i].what end
    return out
end

return Crumbs
