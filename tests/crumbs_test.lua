-- Breadcrumbs: a session that ended right after an action names it next time;
-- one that kept beating afterwards doesn't.
package.path = "reframework/autorun/?.lua;" .. package.path
local FILES = {}
json = { load_file = function(p) return FILES[p] end, dump_file = function(p, v) FILES[p] = v; return true end }
local P = "ComboLab\\crumbs.json"
local fails = 0
local function check(n, ok) if not ok then fails = fails + 1; print("FAIL " .. n) end end
local function fresh() package.loaded["combolab.crumbs"] = nil; return require("combolab.crumbs") end

FILES[P] = { beat = 1000, crumbs = { { t = 990, what = "teleport" }, { t = 1000, what = "load combo: Training settings for X" } } }
local C = fresh(); C.init()
check("names the suspect", C.previous and C.previous.what == "load combo: Training settings for X")
check("keeps the lead-up", C.previous and #C.previous.recent == 2)
check("starts a new log", #FILES[P].crumbs == 0)

FILES[P] = { beat = 1060, crumbs = { { t = 1000, what = "load combo" } } }
C = fresh(); C.init()
check("quiet ending is not blamed", C.previous == nil)

C.add("game speed x = 10")
check("adds", FILES[P].crumbs[1].what == "game speed x = 10")
for i = 1, 40 do C.add("a" .. i) end
check("capped", #FILES[P].crumbs == 24)
if fails == 0 then print("crumbs ok") else os.exit(1) end
