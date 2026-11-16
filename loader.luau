-- GitHub game loader. Detects the running game, fetches its script from
-- raw.githubusercontent.com, and executes it. Single autoexec entry point.
-- Add a game by editing REGISTRY: place/universe -> path inside the repo.
-- Scripts are fetched over HTTPS, so no local files or readfile sandbox needed.

local S = (typeof(STATE) == "table" and STATE) or {
    onCleanup = function() end,
    connect = function(_, sig, fn) return sig:Connect(fn) end,
    alive = function() return true end,
}

local OWNER  = "Dommeeeee"
local REPO   = "roblox-game-scripts"
local BRANCH = "main"

-- Resolve the latest commit SHA so fetches pin to an exact, uncached raw path.
-- The /<branch>/ raw path is CDN-cached and can serve stale bytes after a push;
-- the /<sha>/ path is distinct and always fresh. Falls back to the branch name.
local function resolveRef()
    local api = ("https://api.github.com/repos/%s/%s/commits/%s"):format(OWNER, REPO, BRANCH)
    local ok, body = pcall(function() return game:HttpGet(api) end)
    if ok and typeof(body) == "string" then
        local ok2, data = pcall(function()
            return game:GetService("HttpService"):JSONDecode(body)
        end)
        if ok2 and typeof(data) == "table" and typeof(data.sha) == "string" then
            return data.sha
        end
    end
    return BRANCH
end

local REF  = resolveRef()
local BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, REF)

local REGISTRY = {
    { name = "Ugc Voxel War",    place = 78884249003161,  universe = 10773416193, script = "games/ugc_aim.luau" },
    { name = "Hypershot",        place = 17516596118,     universe = 5995470825, script = "games/hypershot_aim.luau" },
    { name = "Raycity RB",       place = 117419079466193, universe = 10772794231, script = "games/raycity_farm.luau" },
    { name = "OJBS",             place = 76870565041704,  universe = nil,           script = "games/ojbs-killaura.lua" },
    { name = "Vanta / Clover",   place = 76894257773137,  universe = nil,           script = "games/VantaCloverHub_v5.luau" },
    { name = "Murder Mystery 2", place = 142823291,       universe = nil,           script = "games/mm2_master_suite.luau" },
    { name = "Brookhaven",       place = 4924922222,      universe = nil,           script = "games/brookhaven_parlor_tricks.luau" },
}

local function resolve(placeId, universeId)
    for _, e in REGISTRY do
        if e.place and e.place == placeId then return e end
    end
    for _, e in REGISTRY do
        if e.universe and e.universe == universeId then return e end
    end
    return nil
end

-- Fetch text over HTTPS. game:HttpGet first, request() as fallback.
local function fetch(url)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if ok and typeof(body) == "string" and #body > 0 then
        return body
    end
    if typeof(request) == "function" then
        local ok2, res = pcall(request, { Url = url, Method = "GET" })
        if ok2 and typeof(res) == "table" and res.StatusCode == 200
            and typeof(res.Body) == "string" and #res.Body > 0 then
            return res.Body
        end
    end
    return nil, tostring(body)
end

local function run(e)
    local url = BASE .. e.script
    local src, err = fetch(url)
    if not src then
        warn(("[GameLoader] fetch failed for %s (%s): %s"):format(e.name, url, tostring(err)))
        return false
    end
    local fn, compileErr = loadstring(src, "@" .. e.name)
    if not fn then
        warn(("[GameLoader] compile failed for %s: %s"):format(e.name, tostring(compileErr)))
        return false
    end
    local ok, runErr = pcall(fn)
    if not ok then
        warn(("[GameLoader] runtime error in %s: %s"):format(e.name, tostring(runErr)))
        return false
    end
    return true
end

local placeId = game.PlaceId
local universeId = game.GameId
local entry = resolve(placeId, universeId)

getgenv().GameLoader = {
    registry = REGISTRY,
    resolve = resolve,
    fetch = fetch,
    base = BASE,
    ref = REF,
    current = entry and entry.name or nil,
    place = placeId,
    universe = universeId,
}

if not entry then
    print(("[GameLoader] no script registered for place %s (universe %s)"):format(tostring(placeId), tostring(universeId)))
    return
end

if getgenv().__gameLoaderRan == entry.name then
    print("[GameLoader] " .. entry.name .. " already running in this client")
    return
end
getgenv().__gameLoaderRan = entry.name

print(("[GameLoader] detected %s -> %s"):format(entry.name, BASE .. entry.script))
if run(entry) then
    print("[GameLoader] " .. entry.name .. " loaded from GitHub")
end

S.onCleanup(function()
    getgenv().__gameLoaderRan = nil
end)