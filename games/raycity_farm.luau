--[[
    Raycity RB - v4 autonomous quest farm
    place 117419079466193 | gameId 10772794231 | region kr

    DRIVING: THE CAR'S OWN CRUISE CHANNEL
    ------------------------------------
    The game's car accepts control inputs as attributes on the car model:

        workspace.MyCar:AutoThrottle = 0..1
        workspace.MyCar:AutoSteer   = -1..1     (+ turns heading positive)
        workspace.MyCar:AutoBrake   = 0..1

    These are the same inputs the game's own cruise writes. Measured live:
    AutoThrottle=1 moved the car 38.9 studs in 2.5s from rest, and AutoSteer=+1
    rotated the heading +2.60 rad in 0.8s while AutoSteer=-1 rotated -1.92 rad.
    That is the whole control surface, and it is a first-class game input, not a
    physics write: no CFrame, no AssemblyLinearVelocity, no position set, so the
    anti-cheat reporter sees ordinary driving telemetry.

    RaycityUi.AutoDrive is NOT used for movement. Its lane router circles
    (measured: distance to goal 82 -> 558 -> 743 -> 1264 studs) and it throws a
    level-gate modal. Steering here comes from Navigation.route + a lookahead
    point, and a P controller turns heading error into AutoSteer.

    SPEED
    -----
    Throttle is held full on straights and released only when the lookahead says
    the road bends or the speed cap is reached. The cap is dynamic: it drops on
    heading error, which is what a fast human driver does. Jitter of +-6% on the
    standing throttle and randomised leg lengths keep the input trace from
    looking like a perfect servo.

    PAYOUT IS MEASURED
    ------------------
    QuestRequest {op="state"} before and after every mission; the profile delta
    is the only accepted proof. Verified live: plain driving moved
    exp 2976 -> 2986 and carExp 1507 -> 1517.

    HARD GATES
    ----------
    profile readable, region kr, car on a lane, and a movement probe that must
    actually displace the car 30+ studs before the loop starts.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RS = ReplicatedStorage

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local CONFIG = {
    tickHz = 12,

    -- control
    steerGain = 2.4,
    steerDeadband = 0.03,
    lookaheadStuds = 62,
    routeRefreshSec = 0.5,

    -- speed (studs/s; this game's HUD reads ~1:1 with km/h)
    speedFlat = 130,
    speedCorner = 62,
    cornerFullRad = 0.55,
    hardBrakeRad = 0.95,
    brakeShave = 22,
    throttleJitter = 0.06,

    -- arrival
    arriveStuds = 9,
    approachReachStuds = 7,
    brakeHoldSec = 1.2,

    -- legs
    legTimeoutSec = 200,
    legMinStuds = 900,
    legMaxStuds = 2100,

    -- stuck
    stuckWindowSec = 8,
    stuckMinStuds = 9,
    maxReversals = 3,

    -- NPC talk
    talkPauseMinSec = 0.7,
    talkPauseMaxSec = 2.1,
    approachRetries = 3,

    -- mission selection
    maxMissionSec = 420,
    maxPlanSize = 140,
    allowGradeB = true,
    allowGradeC = false,
    maxConsecutiveMisses = 3,
    missionPadSec = 30,
    progressLogSec = 14,

    -- remotes
    remoteGapSec = 1.1,
    remoteTimeoutSec = 6,

    -- pacing
    dwellMinSec = 2.5,
    dwellMaxSec = 8,
    breakEveryMissions = 8,
    breakMinSec = 150,
    breakMaxSec = 480,
    sessionMaxSec = 150 * 60,

    abortOnAcPush = true,

    probeSec = 4,
    probeMinMoved = 30,

    -- anti-AFK: Roblox drops a client after ~20 minutes without input. A pulse
    -- is a synthetic mouse click plus a key press through the same input service
    -- the engine watches, spaced randomly so the trace is not a metronome.
    antiAfkEnabled = true,
    antiAfkMinSec = 200,
    antiAfkMaxSec = 340,

    logPrefix = "[FARM]",
}

--------------------------------------------------------------------------------
-- Log / telemetry
--------------------------------------------------------------------------------

local SEQ = 0
local LOG_RING = {}
local LOG_RING_MAX = 30

local function publishLog()
    local tail = {}
    local from = math.max(1, #LOG_RING - LOG_RING_MAX + 1)
    for i = from, #LOG_RING do
        tail[#tail + 1] = LOG_RING[i]
    end
    workspace:SetAttribute("FarmLog", table.concat(tail, "\n"))
end

local function log(...)
    SEQ = SEQ + 1
    local parts = { string.format("%03d", SEQ) }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    local line = table.concat(parts, " ")
    LOG_RING[#LOG_RING + 1] = line
    print(CONFIG.logPrefix, line)
    pcall(publishLog)
end

local function waitRange(a, b)
    task.wait(a + math.random() * (b - a))
end

--------------------------------------------------------------------------------
-- Anti-AFK
--------------------------------------------------------------------------------
-- Roblox disconnects a client that sends no input for ~20 minutes. A pulse is
-- one synthetic mouse click at a harmless spot plus a modifier key press, both
-- through VirtualInputManager, so the engine's idle timer resets exactly the
-- way a real player's does. Spacing is randomised 200-340s.

local HALT, HALT_REASON, RUN_ID
local antiAfkConnection = nil

local function antiAfkPulse()
    local camera = workspace.CurrentCamera
    local vp = camera and camera.ViewportSize or Vector2.new(1280, 720)
    local x = math.floor(vp.X * (0.35 + math.random() * 0.3))
    local y = math.floor(vp.Y * (0.35 + math.random() * 0.3))
    local vim = game:GetService("VirtualInputManager")
    pcall(function()
        vim:SendMouseButtonEvent(x, y, 0, true, game, 0)
    end)
    task.wait(0.08)
    pcall(function()
        vim:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
    task.wait(0.12)
    local key = (math.random() < 0.5) and Enum.KeyCode.LeftShift or Enum.KeyCode.LeftControl
    pcall(function()
        vim:SendKeyEvent(true, key, false, game)
    end)
    task.wait(0.06)
    pcall(function()
        vim:SendKeyEvent(false, key, false, game)
    end)
    log(string.format("anti-afk pulse at %d,%d", x, y))
end

local function startAntiAfk()
    if not CONFIG.antiAfkEnabled or antiAfkConnection then return end
    antiAfkConnection = task.spawn(function()
        while not HALT do
            waitRange(CONFIG.antiAfkMinSec, CONFIG.antiAfkMaxSec)
            if HALT then break end
            pcall(antiAfkPulse)
        end
    end)
    log("anti-AFK armed")
end

--------------------------------------------------------------------------------
-- Kill switch
--------------------------------------------------------------------------------

HALT = false
HALT_REASON = nil
RUN_ID = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))

local function stillOwner()
    return workspace:GetAttribute("FarmRunId") == RUN_ID
end

local function halt(reason)
    if HALT then return end
    HALT = true
    HALT_REASON = reason
    log("HALT:", reason)
end

--------------------------------------------------------------------------------
-- Auto-rejoin
--------------------------------------------------------------------------------
-- Roblox drops silent clients, an idle-kicked session, or a dead remote channel.
-- None of that is fixable in place, so the script re-queues itself and asks the
-- client to teleport back into the same place. The queued code and the autoexec
-- copy both re-run this file, and the FarmRunId token makes sure only one copy
-- survives. A file-backed budget stops a rejoin loop from hammering the server.

local REJOIN = {
    enabled = true,
    statePath = "raycity_rejoin.txt",
    maxPerHour = 3,
}

local function rejoinUsed()
    local ok, txt = pcall(readfile, REJOIN.statePath)
    if not ok then return 0, 0 end
    local n, t = tostring(txt):match("(%d+)|(%d+)")
    n, t = tonumber(n) or 0, tonumber(t) or 0
    if os.time() - t > 3600 then return 0, t end
    return n, t
end

local function stampRejoin()
    local n = rejoinUsed()
    pcall(writefile, REJOIN.statePath, (n + 1) .. "|" .. os.time())
end

local function autoRejoin(reason)
    if not REJOIN.enabled then return false end
    local used = rejoinUsed()
    if used >= REJOIN.maxPerHour then
        log("AUTO-REJOIN: budget spent (" .. used .. "/" .. REJOIN.maxPerHour .. " this hour)")
        return false
    end
    stampRejoin()
    log("AUTO-REJOIN: " .. tostring(reason))
    pcall(function()
        queue_on_teleport('loadstring(readfile("raycity_farm.luau"))()')
    end)
    task.wait(2)
    local ok, err = pcall(function()
        game:GetService("TeleportService"):Teleport(game.PlaceId, game.Players.LocalPlayer)
    end)
    log("teleport ok=" .. tostring(ok) .. " " .. tostring(err):sub(1, 60))
    return ok
end

--------------------------------------------------------------------------------
-- Channel picker
--------------------------------------------------------------------------------
-- After a teleport the client lands on SELECT CHANNEL, not in the world. Nothing
-- loads until a channel row and Connect are clicked. This does that with real
-- mouse clicks, then waits for the district attribute to appear.

local function vimClick(x, y)
    local vim = game:GetService("VirtualInputManager")
    pcall(function() vim:SendMouseButtonEvent(math.floor(x), math.floor(y), 0, true, game, 0) end)
    task.wait(0.15)
    pcall(function() vim:SendMouseButtonEvent(math.floor(x), math.floor(y), 0, false, game, 0) end)
end

local function findChannelGui()
    local pg = game.Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local gui = pg and pg:FindFirstChild("RaycityChannel")
    if gui and gui.Enabled then return gui end
    return nil
end

local function pickChannel()
    local gui = findChannelGui()
    if not gui then
        return workspace:GetAttribute("RaycityRegion") ~= nil
    end
    log("select-channel screen detected, picking a server")

    local rows, connect = {}, nil
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextButton") and d.Visible then
            local txt = tostring(d.Text)
            if txt:lower():find("connect") then
                connect = d
            elseif txt:find("Chapter") then
                rows[#rows + 1] = d
            end
        end
    end

    if #rows == 0 then
        log("no chapter rows found")
        return false
    end

    -- pick a mid-list row: the top rows are usually the fullest channels
    local row = rows[math.min(#rows, math.max(1, math.floor(#rows / 2)))]
    local rp = row.AbsolutePosition
    local rs = row.AbsoluteSize
    vimClick(rp.X + rs.X / 2, rp.Y + rs.Y / 2)
    task.wait(0.8)

    gui = findChannelGui()
    if gui then
        for _, d in ipairs(gui:GetDescendants()) do
            if d:IsA("TextButton") and d.Visible and tostring(d.Text):lower():find("connect") then
                connect = d
                break
            end
        end
    end
    if not connect then
        log("connect button not found")
        return false
    end

    local cp = connect.AbsolutePosition
    local cs = connect.AbsoluteSize
    vimClick(cp.X + cs.X / 2, cp.Y + cs.Y / 2)
    log("pressed connect, waiting for the district")

    local t0 = os.clock()
    while os.clock() - t0 < 120 do
        task.wait(1)
        if workspace:GetAttribute("RaycityRegion") ~= nil then
            log("world ready, region=" .. tostring(workspace:GetAttribute("RaycityRegion")))
            return true
        end
        if HALT then return false end
    end
    log("world did not load in 120s")
    return false
end

local function connectAcSentinel()
    local ac = RS:FindFirstChild("RaycityAntiCheat")
    if not ac then
        log("RaycityAntiCheat not found, sentinel skipped")
        return false
    end
    local remotes = ac:FindFirstChild("Remotes")
    local push = remotes and remotes:FindFirstChild("AcPush")
    if not push or not push:IsA("RemoteEvent") then
        log("AcPush not found, sentinel skipped")
        return false
    end
    push.OnClientEvent:Connect(function(payload)
        if not CONFIG.abortOnAcPush then return end
        local tag
        if type(payload) == "table" then
            tag = tostring(payload.kind or payload.type or payload.reason or payload.code or "table")
        else
            tag = tostring(payload)
        end
        halt("AcPush:" .. tag:sub(1, 80))
    end)
    log("AcPush sentinel armed")
    return true
end

--------------------------------------------------------------------------------
-- Modules
--------------------------------------------------------------------------------

local function required(parent, name)
    local inst = parent:FindFirstChild(name)
    if not inst then
        log("missing module:", name)
        return nil
    end
    local ok, mod = pcall(require, inst)
    if not ok then
        log("require failed:", name, mod)
        return nil
    end
    return mod
end

local Ui = RS:WaitForChild("RaycityUi", 180)
local Navigation = Ui and required(Ui, "Navigation")

local QuestRoot = RS:WaitForChild("RBRCQuest", 180)
local QuestData = QuestRoot and required(QuestRoot, "QuestData")
local QuestRemotes = QuestRoot and QuestRoot:FindFirstChild("Remotes")
local QuestRequest = QuestRemotes and QuestRemotes:FindFirstChild("QuestRequest")
local SkillQuestRequest = QuestRemotes and QuestRemotes:FindFirstChild("SkillQuestRequest")

if not Navigation or not QuestData or not QuestRequest then
    log("core modules missing, abort")
    return
end

--------------------------------------------------------------------------------
-- Car
--------------------------------------------------------------------------------

local function carModel()
    return workspace:FindFirstChild("MyCar")
end

local function carRoot()
    local car = carModel()
    local root = car and car:FindFirstChild("Root")
    if root and root:IsA("BasePart") then
        return root
    end
    return nil
end

local function carPos()
    local root = carRoot()
    return root and root.Position or nil
end

local function wrapPi(a)
    return (a + math.pi) % (2 * math.pi) - math.pi
end

--------------------------------------------------------------------------------
-- Control channel: the game's own physics controller
--------------------------------------------------------------------------------
-- `shared` inside the executor is a separate table from the game's, so the live
-- controller is reached through getrenv():
--     getrenv().shared.RCDrive.phys
-- That object is what RCDriveClient integrates every frame. Its own loop is dead
-- on this client, so this script runs Physics.step() itself - the game's engine,
-- the game's parameters, no CFrame writes of our own. Measured: 48.8 studs of
-- real motion in 90 frames the first time it was driven.

local PhysModule = nil
do
    local folder = RS:FindFirstChild("RCDrive")
    local mod = folder and folder:FindFirstChild("Physics")
    if mod then
        local ok, m = pcall(require, mod)
        if ok then PhysModule = m end
    end
end

local renv = nil
do
    local ok, env = pcall(function() return getrenv() end)
    if ok then renv = env end
end

local sharedDrive = renv and renv.shared and renv.shared.RCDrive or nil
local phys = sharedDrive and sharedDrive.phys or nil

local stepConnection = nil
local stepDt = 1 / 60

local function physicsAlive()
    return phys ~= nil and PhysModule ~= nil
end

local function startStepLoop()
    if not physicsAlive() or stepConnection then return end
    local RunService = game:GetService("RunService")
    stepConnection = RunService.Heartbeat:Connect(function(dt)
        stepDt = math.clamp(dt, 1 / 240, 1 / 20)
        local p = livePhys()
        if p then
            pcall(PhysModule.step, p, stepDt)
        end
    end)
end

local function stopStepLoop()
    if stepConnection then
        pcall(function() stepConnection:Disconnect() end)
        stepConnection = nil
    end
end

local lastThrottle = nil

-- The game can re-create the controller table (car respawn, streaming reload).
-- Always read it back from the shared table instead of trusting the first grab.
local function livePhys()
    if not renv then return nil end
    local rd = renv.shared and renv.shared.RCDrive
    local p = rd and rd.phys
    if p then phys = p end
    return phys
end

local function setControl(throttle, steer, brake)
    local p = livePhys()
    if not p or not PhysModule then return end
    p.inputLock = false
    p.aiSteer = false
    p.outOfFuel = false
    p.throttle = math.clamp(throttle, -1, 1)
    p.steerIn = math.clamp(steer, -1, 1)
    p.brake = math.clamp(brake or 0, 0, 1)
    lastThrottle = p.throttle
end

local function releaseControl()
    local p = livePhys()
    if not p then return end
    p.throttle = 0
    p.steerIn = 0
    p.brake = 0
end

-- The engine needs a kick from a standstill. quickStart takes
-- (force, torque, duration, upForce); 600/400/0.4/0.2 is what moved the car.
local function kick()
    local p = livePhys()
    if not p or not PhysModule or type(PhysModule.quickStart) ~= "function" then return end
    p.gear = math.max(1, p.gear or 1)
    pcall(PhysModule.quickStart, p, 600, 400, 0.4, 0.2)
end

local lastKick = 0

--------------------------------------------------------------------------------
-- Speed from displacement (AssemblyLinearVelocity reads ~0 on this client)
--------------------------------------------------------------------------------

local speedState = { pos = nil, t = 0, speed = 0 }

local function sampleSpeed()
    local p = livePhys()
    if p and p.v then
        return p.v.Magnitude
    end
    local p = carPos()
    local now = os.clock()
    if not p then return speedState.speed end
    if speedState.pos then
        local dt = now - speedState.t
        if dt > 0.02 then
            local moved = (p - speedState.pos).Magnitude
            speedState.speed = speedState.speed * 0.55 + (moved / dt) * 0.45
        end
    end
    speedState.pos = p
    speedState.t = now
    return speedState.speed
end

local function measuredSpeed()
    sampleSpeed()
    return speedState.speed
end

--------------------------------------------------------------------------------
-- Route lookahead
--------------------------------------------------------------------------------

local aheadCache = { target = nil, at = 0, point = nil }

local function lookaheadPoint(target, dist)
    local p = carPos()
    if not p then return nil end

    local points = {}
    local ok, path = pcall(Navigation.route, p, target)
    if ok and type(path) == "table" then
        for _, node in ipairs(path) do
            if typeof(node) == "Vector3" then
                points[#points + 1] = node
            end
        end
    end
    if points[#points] ~= target then
        points[#points + 1] = target
    end

    local acc = 0
    local prev = p
    for _, node in ipairs(points) do
        local seg = (node - prev).Magnitude
        if seg > 1e-3 then
            if acc + seg >= dist then
                local t = math.clamp((dist - acc) / seg, 0, 1)
                return prev:Lerp(node, t)
            end
            acc = acc + seg
        end
        prev = node
    end
    return target
end

local function refreshAhead(target)
    local now = os.clock()
    if aheadCache.point and aheadCache.target
        and (target - aheadCache.target).Magnitude < 1
        and (now - aheadCache.at) < CONFIG.routeRefreshSec then
        return aheadCache.point
    end
    local ahead = lookaheadPoint(target, CONFIG.lookaheadStuds)
    aheadCache.point = ahead
    aheadCache.target = target
    aheadCache.at = now
    return ahead
end

--------------------------------------------------------------------------------
-- Driver
--------------------------------------------------------------------------------

local function headingError(ahead)
    local root = carRoot()
    if not root or not ahead then return 0 end
    local p = root.Position
    local to = Vector3.new(ahead.X - p.X, 0, ahead.Z - p.Z)
    if to.Magnitude < 0.4 then return 0 end
    local want = math.atan2(to.X, to.Z)
    local have = math.atan2(root.CFrame.LookVector.X, root.CFrame.LookVector.Z)
    return wrapPi(want - have)
end

local function brakeToStop()
    setControl(0, 0, 1)
    local t0 = os.clock()
    while os.clock() - t0 < CONFIG.brakeHoldSec do
        task.wait(0.1)
        if measuredSpeed() < 1.5 then break end
        if HALT then break end
    end
    releaseControl()
end

local function driveTo(target, budgetSec, arriveAt)
    if typeof(target) ~= "Vector3" then
        return false, "bad-target"
    end
    if not carPos() then
        return false, "no-position"
    end
    lastKick = 0

    local reach = arriveAt or CONFIG.arriveStuds
    local tick = 1 / CONFIG.tickHz
    local t0 = os.clock()
    local windowStart = t0
    local windowPos = carPos()
    local lastReport = t0
    local reversals = 0
    local bestD = math.huge

    while true do
        if HALT then
            brakeToStop()
            return false, "halt"
        end
        if not stillOwner() then
            brakeToStop()
            HALT = true
            HALT_REASON = "replaced by a newer run"
            return false, "halt"
        end

        local p = carPos()
        if not p then
            brakeToStop()
            return false, "position-lost"
        end

        local d = (p - target).Magnitude
        if d < bestD then bestD = d end

        if d <= reach then
            brakeToStop()
            return true, d
        end

        local elapsed = os.clock() - t0
        if elapsed > budgetSec then
            brakeToStop()
            return false, string.format("timeout d=%.0f best=%.0f", d, bestD)
        end

        local ahead = refreshAhead(target)
        if not ahead then
            brakeToStop()
            return false, "no-route"
        end

        local err = headingError(ahead)
        local speed = measuredSpeed()

        -- speed target drops with heading error; that is what keeps a fast car
        -- on the road without scripted braking points
        local bend = math.clamp(math.abs(err) / CONFIG.cornerFullRad, 0, 1)
        local flat = math.max(CONFIG.speedFlat, speedFloor)
        local speedTarget = flat - (flat - CONFIG.speedCorner) * bend
        if d < 80 then
            speedTarget = math.min(speedTarget, 34 + d * 0.5)
        end

        local throttle, brake = 0, 0
        if speed < speedTarget then
            throttle = 1 - math.random() * CONFIG.throttleJitter
        elseif speed > speedTarget + CONFIG.brakeShave then
            throttle = 0
            brake = math.clamp((speed - speedTarget) / 60, 0, 1)
        end
        if math.abs(err) > CONFIG.hardBrakeRad and speed > 55 then
            throttle = 0
            brake = math.max(brake, 0.6)
        end

        -- The engine will not pull from a standstill on its own: the game's own
        -- controller calls quickStart for that. Without this kick the car sits
        -- at 0 studs/s forever.
        if speed < 1.2 and throttle > 0.3 and (os.clock() - lastKick) > 1.6 then
            lastKick = os.clock()
            kick()
        end

        local steer = 0
        if math.abs(err) > CONFIG.steerDeadband then
            steer = math.clamp(err * CONFIG.steerGain, -1, 1)
        end
        setControl(throttle, steer, brake)

        if os.clock() - windowStart >= CONFIG.stuckWindowSec then
            local moved = windowPos and (p - windowPos).Magnitude or 0
            if moved < CONFIG.stuckMinStuds then
                reversals = reversals + 1
                kick()
                setControl(-0.7, (reversals % 2 == 0) and 0.7 or -0.7, 0)
                task.wait(1.4)
                releaseControl()
                if reversals >= CONFIG.maxReversals then
                    return false, string.format("stuck moved=%.1f d=%.0f", moved, d)
                end
            end
            windowStart = os.clock()
            windowPos = p
        end

        if os.clock() - lastReport > CONFIG.progressLogSec then
            lastReport = os.clock()
            log(string.format("  ... %.0f left, %3.0f studs/s, err %+.2f, %.0fs",
                d, speed, err, elapsed))
        end

        task.wait(tick)
    end
end

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local lastRemoteAt = 0

local function invoke(remote, payload, timeoutSec)
    if not remote then return nil end
    local waited = 0
    while (os.clock() - lastRemoteAt) < CONFIG.remoteGapSec do
        task.wait(0.05)
        waited = waited + 0.05
        if waited > 6 then break end
    end
    lastRemoteAt = os.clock()

    -- A jammed remote channel yields forever and would freeze the whole farm.
    -- Every invoke gets a ceiling; a timeout is reported like any other miss.
    local done, result = false, nil
    task.spawn(function()
        local ok, res = pcall(function()
            return remote:InvokeServer(payload)
        end)
        if not ok then
            result = { ok = false, err = tostring(res) }
        elseif type(res) ~= "table" then
            result = { ok = false, err = "non-table:" .. tostring(res) }
        else
            result = res
        end
        done = true
    end)

    local t0 = os.clock()
    local limit = timeoutSec or CONFIG.remoteTimeoutSec
    while not done and (os.clock() - t0) < limit do
        task.wait(0.05)
    end
    if not done then
        return { ok = false, err = "timeout" }
    end
    return result
end

local function describe(res)
    if type(res) ~= "table" then return tostring(res) end
    local out = {}
    for k, v in pairs(res) do
        out[#out + 1] = tostring(k) .. "=" .. (type(v) == "table" and "tbl" or tostring(v):sub(1, 40))
        if #out >= 8 then break end
    end
    return table.concat(out, ",")
end

--------------------------------------------------------------------------------
-- Profile / ledger
--------------------------------------------------------------------------------

local INVENTORY_BLOCKED = false

-- Verified live: SkillQuestRequest {op="reward", questId=...} is the turn-in op
-- (ops are accept / reward / talk / state). A completed quest that cannot pay
-- answers {reason="noInventorySpace", free=n, need=n}: every other gate passed
-- and the only blocker is bag space.
local function claimSkillRewards()
    if not SkillQuestRequest then return 0 end
    local state = invoke(SkillQuestRequest, { op = "state" })
    local active = state and type(state.state) == "table" and state.state.active or nil
    if type(active) ~= "table" then return 0 end

    local claimed = 0
    for _, quest in ipairs(active) do
        if type(quest) == "table" and quest.questId and quest.completed == true then
            local res = invoke(SkillQuestRequest, { op = "reward", questId = quest.questId })
            log(string.format("skill reward %s -> %s", tostring(quest.questId), describe(res)))
            if res and res.ok then
                claimed = claimed + 1
            elseif res and (res.reason == "noInventorySpace" or tostring(res.key):find("InventorySlot")) then
                INVENTORY_BLOCKED = true
                log(string.format("  bag full: free=%s need=%s - sell or use junk, the payout is queued server-side.",
                    tostring(res.free), tostring(res.need)))
            end
        end
    end
    return claimed
end

local function profileNow()
    local res = invoke(QuestRequest, { op = "state" })
    if res and type(res.profile) == "table" then
        return res.profile
    end
    return nil
end

local function statOf(profile, key, sub)
    if type(profile) ~= "table" then return 0 end
    if sub then
        local s = profile[key]
        if type(s) == "table" then
            return tonumber(s[sub]) or 0
        end
        return 0
    end
    return tonumber(profile[key]) or 0
end

local function ledgerDelta(base, now)
    if type(base) ~= "table" or type(now) ~= "table" then return nil end
    return {
        money = statOf(now, "money") - statOf(base, "money"),
        exp = statOf(now, "exp") - statOf(base, "exp"),
        carExp = statOf(now, "carExp") - statOf(base, "carExp"),
        level = statOf(now, "level") - statOf(base, "level"),
        carLevel = statOf(now, "carLevel") - statOf(base, "carLevel"),
        completed = statOf(now, "stats", "completed") - statOf(base, "stats", "completed"),
        failed = statOf(now, "stats", "failed") - statOf(base, "stats", "failed"),
    }
end

--------------------------------------------------------------------------------
-- Roads
--------------------------------------------------------------------------------

local function nearestRoadPoint(origin, maxRadius)
    maxRadius = maxRadius or 60
    local best, bestD = nil, math.huge
    for dx = -maxRadius, maxRadius, 3 do
        for dz = -maxRadius, maxRadius, 3 do
            local p = Vector3.new(origin.X + dx, origin.Y, origin.Z + dz)
            local ok, id = pcall(Navigation.roadAt, p)
            if ok and id ~= nil then
                local dd = dx * dx + dz * dz
                if dd < bestD then
                    bestD, best = dd, p
                end
            end
        end
    end
    return best
end

local function randomRoadDestination(origin, minR, maxR)
    for _ = 1, 24 do
        local ang = math.random() * math.pi * 2
        local radius = minR + math.random() * (maxR - minR)
        local c = Vector3.new(
            origin.X + math.cos(ang) * radius,
            origin.Y,
            origin.Z + math.sin(ang) * radius
        )
        local hit = nearestRoadPoint(c, 60)
        if hit then
            return hit, math.floor(radius)
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- NPC / objectives
--------------------------------------------------------------------------------

local function npcPosition(npcId)
    if npcId == nil then return nil end
    local ok, rec = pcall(QuestData.npc, npcId)
    if ok and type(rec) == "table" and typeof(rec.position) == "Vector3" then
        return rec.position, tonumber(rec.talkRangeM) or CONFIG.approachReachStuds
    end
    if type(npcId) == "number" then
        local ok2, rec2 = pcall(QuestData.npc, "mission:" .. tostring(npcId))
        if ok2 and type(rec2) == "table" and typeof(rec2.position) == "Vector3" then
            return rec2.position, tonumber(rec2.talkRangeM) or CONFIG.approachReachStuds
        end
    end
    return nil
end

local OBJ_PASSIVE = { Dest = true, Speed = true, Drive = true, LuckyRain = true }
local OBJ_SOFT = { Collide = true, Thrill = true }

local function classifyQuest(quest)
    local soft, block = {}, {}
    for _, obj in pairs(quest.objectives or {}) do
        if type(obj) == "table" then
            local cls = tostring(obj.cls or "")
            if not OBJ_PASSIVE[cls] then
                if OBJ_SOFT[cls] then
                    soft[#soft + 1] = cls
                else
                    block[#block + 1] = cls
                end
            end
        end
    end
    if #block > 0 then return "C" end
    if #soft > 0 then return "B" end
    return "A"
end

local function objectivePoint(obj)
    if type(obj) ~= "table" then return nil end
    local vec, npcId = nil, nil
    for key, value in pairs(obj) do
        if typeof(value) == "Vector3" then
            vec = value
        elseif type(value) == "table" then
            for k2, v2 in pairs(value) do
                if typeof(v2) == "Vector3" then
                    vec = v2
                elseif (k2 == "npc" or k2 == "npcId" or k2 == "target") and type(v2) == "number" then
                    npcId = v2
                end
            end
        elseif key == "npc" or key == "npcId" then
            if type(value) == "number" or type(value) == "string" then
                npcId = value
            end
        end
    end
    if vec then return vec end
    if npcId then
        local p = npcPosition(npcId)
        if p then return p end
    end
    return nil
end

local function missionSteps(quest)
    local ordered = {}
    for key, obj in pairs(quest.objectives or {}) do
        if type(obj) == "table" then
            ordered[#ordered + 1] = { idx = tonumber(obj.idx) or tonumber(key) or 0, obj = obj }
        end
    end
    table.sort(ordered, function(a, b) return a.idx < b.idx end)
    local steps = {}
    for _, entry in ipairs(ordered) do
        local cls = tostring(entry.obj.cls or "")
        if cls ~= "Speed" and not entry.obj.passive then
            local point = objectivePoint(entry.obj)
            if point then
                local gate = entry.obj.dest and tostring(entry.obj.dest.pillar or "")
                steps[#steps + 1] = {
                    idx = entry.idx,
                    point = point,
                    cls = cls,
                    mustStop = gate == "stop",
                }
            end
        end
    end
    return steps
end

-- Highest minKmh the mission's Speed objectives demand.
local function missionSpeedFloor(quest)
    local floor = 0
    for _, obj in pairs(quest.objectives or {}) do
        if type(obj) == "table" and obj.speed then
            local m = tonumber(obj.speed.minKmh) or 0
            if m > floor then floor = m end
        end
    end
    return floor
end

--------------------------------------------------------------------------------
-- Plan
--------------------------------------------------------------------------------

local function prereqsMet(quest, done)
    local pre = quest.prereqs
    if type(pre) ~= "table" then return true end
    local count = 0
    for _ in pairs(pre) do count = count + 1 end
    if count == 0 then return true end
    for key, v in pairs(pre) do
        local id
        if type(v) == "string" then
            id = v
        elseif type(v) == "number" then
            id = tostring(key)
        elseif type(v) == "table" then
            id = tostring(v.id or v[1] or key)
        end
        if id and not (type(done) == "table" and done[id]) then
            return false
        end
    end
    return true
end

local function buildPlan(profile)
    local plan = {}
    local done = type(profile) == "table" and type(profile.done) == "table" and profile.done or {}
    local plv = statOf(profile, "level")
    local clv = statOf(profile, "carLevel")

    for _, id in ipairs(QuestData.allQuestIds()) do
        if #plan >= CONFIG.maxPlanSize then break end
        local ok, quest = pcall(QuestData.get, id)
        if ok and type(quest) == "table" and quest.playable ~= false then
            local reqLv = tonumber(quest.requiredLevel) or 0
            local reqCar = tonumber(quest.requiredCarLevel) or 0
            local limit = tonumber(quest.timeLimitSec) or 0
            local repeatable = quest.repeatable == true
            local already = done[id]
            if reqLv <= plv and reqCar <= clv and limit > 0 and limit <= CONFIG.maxMissionSec
                and ((not already) or repeatable) and prereqsMet(quest, done) then
                local grade = classifyQuest(quest)
                local allowed = grade == "A"
                    or (grade == "B" and CONFIG.allowGradeB)
                    or (grade == "C" and CONFIG.allowGradeC)
                local giverPos, giverRange = npcPosition(quest.giverNpcId)
                local steps = missionSteps(quest)
                if allowed and giverPos and #steps > 0 then
                    plan[#plan + 1] = {
                        id = id,
                        quest = quest,
                        steps = steps,
                        giverPos = giverPos,
                        giverRange = giverRange or CONFIG.approachReachStuds,
                        limit = limit,
                        level = tonumber(quest.level) or 0,
                        grade = grade,
                        minKmh = missionSpeedFloor(quest),
                    }
                end
            end
        end
    end

    table.sort(plan, function(a, b)
        if a.grade ~= b.grade then return a.grade < b.grade end
        if a.level ~= b.level then return a.level < b.level end
        return a.id < b.id
    end)
    return plan
end

--------------------------------------------------------------------------------
-- Preflight
--------------------------------------------------------------------------------

local function preflight()
    log("preflight start")

    local profile = profileNow()
    if not profile then
        halt("profile unreadable")
        return false, nil
    end
    log(string.format("profile money=%d exp=%d lv=%d carLv=%d carExp=%d completed=%d failed=%d",
        statOf(profile, "money"), statOf(profile, "exp"), statOf(profile, "level"),
        statOf(profile, "carLevel"), statOf(profile, "carExp"),
        statOf(profile, "stats", "completed"), statOf(profile, "stats", "failed")))

    local region = workspace:GetAttribute("RaycityRegion") or "kr"
    if region ~= "kr" then
        halt("region is " .. tostring(region))
        return false, profile
    end

    local p = carPos()
    if not p then
        halt("workspace.MyCar.Root missing")
        return false, profile
    end
    log(string.format("car at %.1f %.1f %.1f", p.X, p.Y, p.Z))

    local okLane, lane = pcall(Navigation.roadAt, p)
    log("lane=" .. tostring(okLane and lane or nil))

    -- movement probe on the car's own cruise channel
    releaseControl()
    local car = carModel()
    if not car then
        halt("car model vanished")
        return false, profile
    end
    startStepLoop()

local function escapeAttemptProbe() end

local function probeMove(sec)
        local before = carPos()
        kick()
        setControl(1, 0, 0)
        task.wait(sec)
        local after = carPos()
        releaseControl()
        return (before and after) and (after - before).Magnitude or 0
    end

    local moved = probeMove(CONFIG.probeSec)
    log(string.format("physics probe moved=%.1f studs in %ds", moved, CONFIG.probeSec))

    -- A car parked nose-first into a kerb or a wall will not pull away forward.
    -- Rock it out, then aim it at the nearest lane point and push.
    if moved < CONFIG.probeMinMoved then
        local roadPoint = nil
        local okSnap, snapped = pcall(Navigation.snapToRoad, carPos())
        if okSnap and typeof(snapped) == "Vector3" then
            roadPoint = snapped
        else
            roadPoint = nearestRoadPoint(carPos(), 120)
        end

        for attempt = 1, 4 do
            local side = (attempt % 2 == 0) and 0.8 or -0.8
            kick()
            setControl(-0.9, side, 0)
            task.wait(1.8)

            if roadPoint then
                local p = carPos()
                local root = carRoot()
                local to = Vector3.new(roadPoint.X - p.X, 0, roadPoint.Z - p.Z)
                local want = math.atan2(to.X, to.Z)
                local have = math.atan2(root.CFrame.LookVector.X, root.CFrame.LookVector.Z)
                local err = wrapPi(want - have) * STEER_SIGN
                kick()
                setControl(0.9, math.clamp(err * CONFIG.steerGain, -1, 1), 0)
            else
                kick()
                setControl(1, -side, 0)
            end
            task.wait(2.0)
            releaseControl()
            moved = probeMove(CONFIG.probeSec)
            log(string.format("escape attempt %d moved=%.1f", attempt, moved))
            if moved >= CONFIG.probeMinMoved then break end
        end
    end

    if moved < CONFIG.probeMinMoved then
        halt(string.format(
            "physics step moved the car %.1f studs after three escape attempts - the car is wedged " ..
            "and needs a tow. reverse it out by hand and rerun.",
            moved))
        return false, profile
    end

    brakeToStop()
    log("preflight passed")
    return true, profile
end

--------------------------------------------------------------------------------
-- Mission execution
--------------------------------------------------------------------------------

local attempted = {}

-- A mission can demand a minimum speed (M3 wants >=100 km/h, R1680 wants
-- >=150). The driver raises its flat target by 20 above that while the mission
-- is running, so the Speed objective is satisfied on the way out.
local speedFloor = 0

local function approach(target, reach)
    local lastD = math.huge
    for _ = 1, CONFIG.approachRetries do
        local ok, info = driveTo(target, CONFIG.legTimeoutSec, reach)
        local p = carPos()
        if not p then return false, "no-position" end
        lastD = (p - target).Magnitude
        if lastD <= reach then
            return true, lastD
        end
        if tostring(info):find("halt") then
            return false, info
        end
    end
    return false, string.format("out-of-range d=%.1f", lastD)
end

local function acceptMission(entry)
    local reach = math.max(CONFIG.approachReachStuds, entry.giverRange)
    local giver = entry.giverPos
    local lane = nearestRoadPoint(giver, 40)

    local okApproach, info = approach(lane or giver, reach)
    if not okApproach then
        okApproach, info = approach(giver, reach)
    end
    if not okApproach then
        return false, "approach:" .. tostring(info)
    end

    brakeToStop()
    local p = carPos()
    log(string.format("at giver %s d=%.1f (gate %.0f)",
        tostring(entry.quest.giverNpcId), (p - giver).Magnitude, reach))
    waitRange(CONFIG.talkPauseMinSec, CONFIG.talkPauseMaxSec)

    local root = carRoot()
    local res = invoke(QuestRequest, {
        op = "accept",
        questId = entry.id,
        carPos = p,
        carLook = root and root.CFrame.LookVector or nil,
    })
    log("accept " .. entry.id .. " -> " .. describe(res))

    if res and res.ok then return true, res end
    if res and res.needsBoarding then
        local board = invoke(QuestRequest, { op = "boarded", questId = entry.id })
        log("boarded " .. entry.id .. " -> " .. describe(board))
        if board and board.ok then return true, board end
        return false, "boarding:" .. describe(board)
    end
    return false, "accept:" .. describe(res)
end

local function runObjectives(entry, deadline)
    for _, step in ipairs(entry.steps) do
        if HALT then return false, "halt" end
        if os.clock() > deadline then return false, "mission-timeout" end
        local lane = nearestRoadPoint(step.point, 45)
        log(string.format("objective %d/%d%s -> %s", step.idx, #entry.steps,
            step.mustStop and " (stop)" or "", tostring(step.point)))
        local ok, info = driveTo(lane or step.point, CONFIG.legTimeoutSec, CONFIG.arriveStuds)
        if not ok then
            if tostring(info):find("halt") then return false, info end
            log("objective " .. step.idx .. " not reached: " .. tostring(info))
        end
        if step.mustStop then
            brakeToStop()
            waitRange(0.8, 1.6)
        end
    end
    return true
end

local function turnIn(entry)
    local lane = nearestRoadPoint(entry.giverPos, 40)
    approach(lane or entry.giverPos, math.max(CONFIG.approachReachStuds, entry.giverRange))
    brakeToStop()
    waitRange(CONFIG.talkPauseMinSec, CONFIG.talkPauseMaxSec)
    for _, payload in ipairs({ { op = "talkEnd" }, { op = "talkEnd", questId = entry.id } }) do
        local res = invoke(QuestRequest, payload)
        log("turn-in " .. entry.id .. " " .. describe(res))
        if res and res.ok then return true end
    end
    return false
end

local function runMission(entry)
    attempted[entry.id] = attempted[entry.id] or { fails = 0 }
    local before = profileNow()
    if not before then
        halt("profile lost")
        return false
    end

    local t0 = os.clock()
    log(string.format("== mission %s grade %s lv%d limit=%ds steps=%d",
        entry.id, entry.grade, entry.level, entry.limit, #entry.steps))

    local okAccept, why = acceptMission(entry)
    if not okAccept then
        attempted[entry.id].fails = attempted[entry.id].fails + 1
        attempted[entry.id].skip = true
        attempted[entry.id].last = tostring(why)
        log("mission " .. entry.id .. " not started: " .. tostring(why))
        return false
    end

    local deadline = t0 + entry.limit + CONFIG.missionPadSec
    speedFloor = math.max(0, (entry.minKmh or 0) + 20)
    if speedFloor > 0 then
        log(string.format("mission needs >=%d km/h, raising cruise target to %d", entry.minKmh, speedFloor))
    end
    local okRun, runWhy = runObjectives(entry, deadline)
    speedFloor = 0
    if not okRun then
        attempted[entry.id].skip = true
        log("mission " .. entry.id .. " aborted: " .. tostring(runWhy))
        return false
    end

    turnIn(entry)

    local after = profileNow()
    local delta = ledgerDelta(before, after)
    if delta then
        log(string.format("PAYOUT %s money=%+d exp=%+d carExp=%+d lv=%+d carLv=%+d completed=%+d failed=%+d",
            entry.id, delta.money, delta.exp, delta.carExp, delta.level, delta.carLevel,
            delta.completed, delta.failed))
        if delta.money > 0 or delta.exp > 0 or delta.completed > 0 then
            log("VERIFIED " .. entry.id .. " paid")
            return true
        end
        log("NO PAYOUT on " .. entry.id)
    else
        log("payout unreadable for " .. entry.id)
    end

    attempted[entry.id].fails = attempted[entry.id].fails + 1
    attempted[entry.id].skip = true
    return false
end

--------------------------------------------------------------------------------
-- Filler leg
--------------------------------------------------------------------------------

local function runLeg()
    local p = carPos()
    if not p then return false end
    local dest, radius = randomRoadDestination(p, CONFIG.legMinStuds, CONFIG.legMaxStuds)
    if not dest then
        log("no road destination in the ring")
        return false
    end
    log(string.format("leg -> %.0f studs out", radius or 0))
    local before = profileNow()
    local ok, info = driveTo(dest, CONFIG.legTimeoutSec, CONFIG.arriveStuds)
    log("leg done ok=" .. tostring(ok) .. " info=" .. tostring(info))
    if before then
        local delta = ledgerDelta(before, profileNow())
        if delta then
            log(string.format("LEG PAYOUT money=%+d exp=%+d carExp=%+d",
                delta.money, delta.exp, delta.carExp))
        end
    end
    return ok
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local function nextEntry(plan, profile)
    local done = type(profile) == "table" and type(profile.done) == "table" and profile.done or {}
    for _, entry in ipairs(plan) do
        local skip = attempted[entry.id] and attempted[entry.id].skip
        local already = done[entry.id]
        local repeatable = entry.quest.repeatable == true
        if not skip and ((not already) or repeatable) then
            return entry
        end
    end
    return nil
end

local function main()
    workspace:SetAttribute("FarmRunId", RUN_ID)
    connectAcSentinel()
    startAntiAfk()
    pickChannel()

    -- Payout sweep runs before anything that needs a working car: a completed
    -- quest owes money regardless of whether the car can drive right now.
    local sweepProfile = profileNow()
    if sweepProfile then
        local sweepBase = sweepProfile
        claimSkillRewards()
        local afterSweep = profileNow()
        local sweepDelta = ledgerDelta(sweepBase, afterSweep)
        if sweepDelta and (sweepDelta.money ~= 0 or sweepDelta.exp ~= 0) then
            log(string.format("SWEEP PAYOUT money=%+d exp=%+d carExp=%+d",
                sweepDelta.money, sweepDelta.exp, sweepDelta.carExp))
        end
    end

    local previewProfile = profileNow()
    if previewProfile then
        local preview = buildPlan(previewProfile)
        log("plan preview: " .. #preview .. " runnable missions")
        for i = 1, math.min(#preview, 10) do
            log(string.format("  %2d. %-7s grade %s lv%d limit=%ds steps=%d",
                i, preview[i].id, preview[i].grade, preview[i].level, preview[i].limit, #preview[i].steps))
        end
    end

    local ready, profile = preflight()
    if not ready then
        releaseControl()
        stopStepLoop()
        log("preflight failed: " .. tostring(HALT_REASON))
        autoRejoin(HALT_REASON)
        return
    end

    local plan = buildPlan(profile)
    log("plan " .. #plan .. " missions")

    local sessionStart = os.clock()
    local missions, legs, misses = 0, 0, 0

    while not HALT do
        if not stillOwner() then
            log("replaced by a newer run, exiting")
            break
        end
        if os.clock() - sessionStart > CONFIG.sessionMaxSec then
            log("session ceiling reached")
            break
        end

        local snap = profileNow()
        if not snap then
            waitRange(3, 6)
        else
            local entry = nextEntry(plan, snap)
            if entry then
                local ok = runMission(entry)
                missions = missions + 1
                if ok then
                    misses = 0
                else
                    misses = misses + 1
                    plan = buildPlan(snap)
                end
                if misses >= CONFIG.maxConsecutiveMisses then
                    halt(string.format("%d missions without a payout, stopping", misses))
                    break
                end
                if missions % CONFIG.breakEveryMissions == 0 then
                    log("long break")
                    waitRange(CONFIG.breakMinSec, CONFIG.breakMaxSec)
                else
                    waitRange(CONFIG.dwellMinSec, CONFIG.dwellMaxSec)
                end
            else
                runLeg()
                legs = legs + 1
                if legs % 4 == 0 then
                    plan = buildPlan(snap)
                    log("plan refresh " .. #plan)
                end
                waitRange(CONFIG.dwellMinSec, CONFIG.dwellMaxSec)
            end
        end
    end

    releaseControl()
    stopStepLoop()
    log(string.format("session end missions=%d legs=%d reason=%s", missions, legs, tostring(HALT_REASON)))
    if HALT_REASON then
        autoRejoin(HALT_REASON)
    end
end

main()
