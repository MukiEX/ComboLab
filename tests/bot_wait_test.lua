-- The bot only starts an attempt once the dummy is back in a resting action:
-- a Drive Impact crumple (one long action) must play out first.
package.path = "reframework/autorun/?.lua;" .. package.path
local Bot = require("combolab.bot")
local teleports, traces = 0, {}
local env = {
    teleport = function() teleports = teleports + 1; return true end,
    edge = 730, log = function() end,
    trace = function(m) traces[#traces + 1] = m end,
}
local b = Bot.new(env)
b.running = true
b.o_idle, b.o_same = {}, 0
b.cur = { spacing = 0, position = "mid", plans = {} }
local fails = 0
local function check(name, ok) if not ok then fails = fails + 1; print("FAIL " .. name) end end

local t = 0
local function feed(oact, n)
    for _ = 1, n do
        t = t + 1
        b:observe({ t = t, u = { act = 1, phys = 0 }, o = { act = oact, stun = 0, guard = 0, hitstop = 0 } })
        b:update()
        if b.state ~= "prep" then return true end
    end
    return false
end

-- first attempt: the dummy is standing (action 1); that becomes a resting action
b:prep()
check("starts from standing", feed(1, 40))
check("learned standing", b.o_idle[1] == true)

-- after a DI: the dummy crumples (action 900) for 150 frames, then stands
b:prep()
check("waits through the crumple", not feed(900, 150))
check("said why", #traces > 0 and traces[#traces]:find("get back up") ~= nil)
check("starts once it's up", feed(1, 40))
check("crumple not learned", b.o_idle[900] == nil)

-- a new resting pose (stance changed to crouch, action 2): accepted after 3 s
b:prep()
check("waits a while for an unknown pose", not feed(2, 150))
check("then accepts it", feed(2, 60))
check("learned crouching", b.o_idle[2] == true)

-- something that never ends still times out
b:prep()
check("times out", feed(901, 200) or feed(902, 230))

if fails == 0 then print("bot wait ok") else os.exit(1) end
