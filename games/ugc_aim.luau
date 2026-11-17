-- Ugc / Voxel War: silent aim, ESP, FOV, auto-run, and weapon power.
-- Camera is never touched. The shot payload is rewritten at the remote boundary,
-- and the AimShare look report is steered to the same direction so the server-side
-- look, shot direction and per-shot look argument stay mutually consistent.
--
-- Power layer works on the same boundary:
--   rapid fire  - duplicate the 5-arg gun payload inside the caller's own rate budget
--   no spread   - cone pinned to 0.02 and direction taken from the pre-recoil look
--   auto reload - the tool's own ReloadX remote, called when the replicated mag is low
--   rocket aim  - FireRocket hit point redirected onto the locked target
--   trigger     - VirtualInputManager click while a lock is held
--
-- Vehicles are read from ReplicatedStorage.Vehicles.Live: Id, Model, Team, Health,
-- Wrecked, Pose. The hull model is optional for targeting - pose is always there.
-- Overlay is a ScreenGui, not Drawing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer

local S = (typeof(STATE) == "table" and STATE) or {
    onCleanup = function() end,
    connect = function(a, b, c)
        if c ~= nil then return b:Connect(c) end
        return a:Connect(b)
    end,
    alive = function() return true end,
}

local Settings = {
    Enabled = true,
    SilentAim = true,
    ShareLook = true,
    ESP = true,
    FOVCircle = true,
    FOV = 140,
    MaxDistance = 1000,
    MaxVehicleDistance = 2500,
    TeamCheck = true,
    Smooth = 24,
    AutoRun = false,
    AutoSprint = true,
    TargetMode = "both",  -- both | vehicles | infantry
    Lead = true,
    BulletSpeed = 1700,
    LeadCap = 0.6,
    VehicleWeapons = true,
    TurretPitchMin = -0.35,
    TurretPitchMax = 0.45,

    FirePower = true,
    Rapid = true,
    RapidMul = 2,          -- 1 | 2 | 3 payload sends per game shot
    RapidCap = 12,         -- extra sends per second, total across weapons
    NoSpread = true,
    SpreadCone = 0.02,
    AutoReload = true,
    ReloadAt = 0.35,       -- reload when mag fraction is at or below this
    RocketAim = true,
    Trigger = false,
    TriggerKey = Enum.KeyCode.F7,
    HeadAim = false,
}

local Power = {
    extras = 0,
    sent = 0,
    reloads = 0,
    toolMap = 0,
    lastError = nil,
}

local Voxel = ReplicatedStorage:WaitForChild("Voxel", 20)
local Remotes = Voxel and Voxel:WaitForChild("Remotes", 20)
local AimShare = Remotes and Remotes:WaitForChild("AimShare", 10)
if not AimShare then
    warn("[UgcAim] Voxel.Remotes.AimShare not found")
    return
end

local Vehicles = ReplicatedStorage:WaitForChild("Vehicles", 20)
local VehicleLive = Vehicles and Vehicles:WaitForChild("Live", 20)
local VRemotes = Vehicles and Vehicles:WaitForChild("Remotes", 20)
local HeliFireR = VRemotes and VRemotes:WaitForChild("HeliFire", 10)
local HeliDoorFireR = VRemotes and VRemotes:WaitForChild("HeliDoorFire", 10)
local TankFireR = VRemotes and VRemotes:WaitForChild("TankFire", 10)
local FireRocketR = Remotes and Remotes:WaitForChild("FireRocket", 10)

local Movement = nil
pcall(function()
    Movement = require(Voxel:WaitForChild("Movement", 5))
end)

local fireSet = {}
for _, r in ipairs(Remotes:GetChildren()) do
    if r:IsA("RemoteEvent") and r.Name:sub(1, 4) == "Fire" then
        fireSet[r] = true
    end
end
-- Emplacement and flamethrower keep their own cadence; duplicating them is noise.
local FIRE_EXTRA_BLOCK = { FireAA = true, FireFlame = true }

local Bots = workspace:FindFirstChild("BotRigs")

-- Head is deliberately absent: body first, exposed limb when that is all there is.
local PART_ORDER = {
    { name = "UpperTorso" },
    { name = "Torso" },
    { name = "LowerTorso" },
    { name = "LeftUpperArm" },
    { name = "RightUpperArm" },
    { name = "Left Arm" },
    { name = "Right Arm" },
    { name = "LeftLowerArm" },
    { name = "RightLowerArm" },
    { name = "LeftUpperLeg" },
    { name = "RightUpperLeg" },
    { name = "Left Leg" },
    { name = "Right Leg" },
    { name = "LeftLowerLeg" },
    { name = "RightLowerLeg" },
    { name = "LeftFoot" },
    { name = "RightFoot" },
    { name = "LeftHand" },
    { name = "RightHand" },
}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local target = nil
local reportDir = nil
local entityCache = {}
local nextScan = 0
local scanMs = 0
local vehVel = {}
local myVeh = nil

local function excludeFor(model, cam)
    local ex = {}
    if LocalPlayer.Character then ex[#ex + 1] = LocalPlayer.Character end
    ex[#ex + 1] = cam
    if model then ex[#ex + 1] = model end
    return ex
end

local function pointVisible(model, part, camPos, ex)
    rayParams.FilterDescendantsInstances = ex
    local hit = workspace:Raycast(camPos, part.Position - camPos, rayParams)
    return (not hit) or hit.Instance:IsDescendantOf(model)
end

local function posVisible(model, pos, camPos, ex)
    rayParams.FilterDescendantsInstances = ex
    local hit = workspace:Raycast(camPos, pos - camPos, rayParams)
    if not hit then return true end
    return model ~= nil and hit.Instance:IsDescendantOf(model)
end

local function visiblePoint(model, camPos, ex)
    if Settings.HeadAim then
        local head = model:FindFirstChild("Head")
        if head and head:IsA("BasePart") and pointVisible(model, head, camPos, ex) then
            return head
        end
    end
    for _, entry in ipairs(PART_ORDER) do
        local part = model:FindFirstChild(entry.name, true)
        if part and part:IsA("BasePart") and pointVisible(model, part, camPos, ex) then
            return part
        end
    end
    return nil
end

local function chestOf(model)
    return model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
        or model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
end

local function vehicleModel(id)
    local name = "V" .. tostring(id)
    local hulls = workspace:FindFirstChild("VehicleHulls")
    local m = hulls and hulls:FindFirstChild(name)
    if m then return m end
    local helis = workspace:FindFirstChild("Helicopters")
    m = helis and helis:FindFirstChild(name)
    if m then return m end
    return workspace:FindFirstChild(name)
end

local function collect()
    local list = {}
    local myTeam = LocalPlayer.Team
    local myTeamName = myTeam and myTeam.Name
    local mode = Settings.TargetMode

    myVeh = nil
    if VehicleLive then
        local uid = LocalPlayer.UserId
        for _, cfg in ipairs(VehicleLive:GetChildren()) do
            local mine = cfg:GetAttribute("S1") == uid
            if not mine then
                for i = 2, 5 do
                    if cfg:GetAttribute("S" .. i) == uid then
                        mine = true
                        break
                    end
                end
            end
            if mine then
                local pose = cfg:GetAttribute("Pose")
                if typeof(pose) == "CFrame" then
                    myVeh = { id = cfg:GetAttribute("Id"), cf = pose, cfg = cfg }
                end
                break
            end
        end
    end

    if mode ~= "vehicles" then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and not (Settings.TeamCheck and myTeam and p.Team == myTeam) then
                local ch = p.Character
                local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                if ch and hum and hum.Health > 0 and ch:GetAttribute("Protected") ~= true then
                    table.insert(list, { kind = "inf", model = ch, name = ch.Name })
                end
            end
        end

        if Bots then
            for _, b in ipairs(Bots:GetChildren()) do
                if b:IsA("Model")
                    and b:GetAttribute("Alive") ~= false
                    and b:GetAttribute("Protected") ~= true
                    and not (Settings.TeamCheck and myTeamName and b:GetAttribute("Team") == myTeamName) then
                    local hum = b:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health > 0 then
                        table.insert(list, { kind = "inf", model = b, name = b.Name })
                    end
                end
            end
        end
    end

    if mode ~= "infantry" and VehicleLive then
        local now = os.clock()
        for _, cfg in ipairs(VehicleLive:GetChildren()) do
            local team = cfg:GetAttribute("Team")
            local health = cfg:GetAttribute("Health")
            local wrecked = cfg:GetAttribute("Wrecked")
            local pose = cfg:GetAttribute("Pose")
            local id = cfg:GetAttribute("Id")
            if typeof(pose) == "CFrame" and typeof(id) == "number"
                and wrecked ~= true and typeof(health) == "number" and health > 0
                and not (Settings.TeamCheck and myTeamName and team == myTeamName) then
                local pos = pose.Position
                local rec = vehVel[id]
                if rec then
                    local dt = now - rec.t
                    if dt > 0.01 then
                        local instant = (pos - rec.p) / dt
                        rec.v = rec.v:Lerp(instant, 0.35)
                        rec.p = pos
                        rec.t = now
                    end
                else
                    rec = { p = pos, t = now, v = Vector3.zero }
                    vehVel[id] = rec
                end
                local model = vehicleModel(id)
                table.insert(list, {
                    kind = "veh",
                    id = id,
                    model = model,
                    point = pos,
                    vel = rec.v,
                    health = health,
                    label = tostring(cfg:GetAttribute("Model") or "Vehicle"),
                })
            end
        end
    end

    entityCache = list
end

local function screenAngle(cam, pos, center)
    local sp, on = cam:WorldToViewportPoint(pos)
    if not on or sp.Z <= 0 then return nil end
    return (Vector2.new(sp.X, sp.Y) - center).Magnitude
end

local function entityPos(e)
    if e.kind == "inf" then
        local part = chestOf(e.model)
        return part and part.Position or nil
    end
    return e.point
end

local function candidateScore(e, cam, center, camPos)
    local pos = entityPos(e)
    if not pos then return nil end
    local d = screenAngle(cam, pos, center)
    if not d or d > Settings.FOV then return nil end
    local limit = e.kind == "veh" and Settings.MaxVehicleDistance or Settings.MaxDistance
    if (pos - camPos).Magnitude > limit then return nil end
    return d
end

local function entityKey(e)
    if e.kind == "veh" then return "V" .. tostring(e.id) end
    return tostring(e.model)
end

local function entityVisible(e, camPos, cam)
    if e.kind == "inf" then
        return visiblePoint(e.model, camPos, excludeFor(e.model, cam)) ~= nil
    end
    return posVisible(e.model, e.point, camPos, excludeFor(e.model, cam))
end

-- Turret convention: yaw from atan2(-x, -z) in hull space, pitch asin of the
-- vertical component. Matches the tank's own PointToObjectSpace pipeline.
local function aimAngles(cf, worldPoint)
    local localDir = cf:VectorToObjectSpace(worldPoint - cf.Position)
    local flat = math.sqrt(localDir.X * localDir.X + localDir.Z * localDir.Z)
    local yaw = math.atan2(-localDir.X, -localDir.Z)
    local pitch = math.atan2(localDir.Y, math.max(flat, 1e-4))
    return yaw, math.clamp(pitch, Settings.TurretPitchMin, Settings.TurretPitchMax)
end

local function bestVisible(cam, center, camPos, limit)
    local cands = {}
    for _, e in ipairs(entityCache) do
        local sc = candidateScore(e, cam, center, camPos)
        if sc then table.insert(cands, { e = e, score = sc }) end
    end
    table.sort(cands, function(a, b) return a.score < b.score end)
    for i = 1, math.min(#cands, limit) do
        local e = cands[i].e
        if entityVisible(e, camPos, cam) then
            return e, cands[i].score
        end
    end
    return nil
end

local function lockFrom(e, score)
    local t = {
        key = entityKey(e),
        kind = e.kind,
        model = e.model,
        id = e.id,
        name = e.name or (e.label and (e.label .. " #" .. tostring(e.id))) or "vehicle",
        label = e.label,
        health = e.health,
        base = e.point,
        vel = e.vel,
        score = score,
        point = e.point,
    }
    if e.kind == "inf" then
        t.part = visiblePoint(e.model, workspace.CurrentCamera.CFrame.Position, excludeFor(e.model, workspace.CurrentCamera))
            or chestOf(e.model)
        t.name = e.model.Name
        t.point = t.part and t.part.Position or Vector3.zero
        t.base = t.point
    end
    return t
end

local function updateTarget(cam, now)
    if not Settings.Enabled then
        target = nil
        return
    end

    local center = cam.ViewportSize * 0.5
    local camPos = cam.CFrame.Position

    if target then
        local live = nil
        for _, e in ipairs(entityCache) do
            if entityKey(e) == target.key then
                live = e
                break
            end
        end
        if live then
            local pos = entityPos(live)
            local d = pos and screenAngle(cam, pos, center)
            if d and d <= Settings.FOV * 1.4 and entityVisible(live, camPos, cam) then
                target = lockFrom(live, d)
                return
            end
        end
        target = nil
    end

    local e, score = bestVisible(cam, center, camPos, 8)
    if e then
        target = lockFrom(e, score)
    end
end

local function updateAimPoint(dt)
    local cam = workspace.CurrentCamera
    if not cam or not target or not Settings.Enabled then
        return
    end

    local base, vel
    if target.kind == "inf" then
        if not target.part or not target.part.Parent then return end
        base = target.part.Position
        vel = target.part.AssemblyLinearVelocity
    else
        local cfg = VehicleLive and VehicleLive:FindFirstChild(target.key)
        if cfg then
            local pose = cfg:GetAttribute("Pose")
            if typeof(pose) == "CFrame" then
                target.base = pose.Position
            end
            target.health = cfg:GetAttribute("Health")
        end
        base = target.base
        vel = target.vel or Vector3.zero
    end

    if not base then return end

    if Settings.Lead and vel and vel.Magnitude > 1 then
        local dist = (base - cam.CFrame.Position).Magnitude
        if dist > 80 then
            local tof = math.min(dist / Settings.BulletSpeed, Settings.LeadCap)
            target.point = base + vel * tof
            return
        end
    end
    target.point = base
end

local function updateReport(dt)
    local cam = workspace.CurrentCamera
    if not cam or not target or not Settings.Enabled then
        reportDir = nil
        return
    end
    local want = target.point - cam.CFrame.Position
    if want.Magnitude < 0.5 then
        reportDir = nil
        return
    end
    want = want.Unit
    if not reportDir then
        reportDir = want
    else
        reportDir = reportDir:Lerp(want, 1 - math.exp(-Settings.Smooth * dt))
        if reportDir.Magnitude > 0 then
            reportDir = reportDir.Unit
        end
    end
end

-- ---------------------------------------------------------------------------
-- Power layer
-- ---------------------------------------------------------------------------

local extraTokens = 0
local extraRefill = 0

local function takeExtra(now)
    if now >= extraRefill then
        extraRefill = now + 1
        extraTokens = Settings.RapidCap
    end
    if extraTokens <= 0 then return false end
    extraTokens -= 1
    return true
end

local toolReload = {}
local reloadAt = {}

local function learnTool(fireRemote)
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if not tool or toolReload[tool] then return end
    local suffix = fireRemote.Name:sub(5)
    local rel = Remotes:FindFirstChild("Reload" .. suffix)
    if rel and rel:IsA("RemoteEvent") then
        toolReload[tool] = rel
        Power.toolMap += 1
    end
end

local triggerDown = false

local function releaseTrigger()
    if not triggerDown then return end
    triggerDown = false
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if tool then
        pcall(function() tool:Deactivate() end)
    end
end

local function autoReload(now)
    if not Settings.FirePower or not Settings.AutoReload then return end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return end
    local rel = toolReload[tool]
    if not rel then return end
    local ammo = tool:GetAttribute("Ammo")
    local mag = tool:GetAttribute("MagSize")
    if typeof(ammo) ~= "number" or typeof(mag) ~= "number" or mag <= 0 then return end
    if now - (reloadAt[tool] or 0) < 2.6 then return end
    -- At zero the game's own reload runs; a second request resets the server timer.
    if ammo >= 1 and ammo <= math.max(1, math.floor(mag * Settings.ReloadAt)) then
        reloadAt[tool] = now
        local ok = pcall(function() rel:FireServer() end)
        if ok then Power.reloads += 1 end
    end
end

local function triggerStep(now)
    if not (Settings.FirePower and Settings.Trigger and Settings.Enabled) or myVeh then
        releaseTrigger()
        return
    end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local tool = char and char:FindFirstChildOfClass("Tool")
    if not target or not tool or not hum or hum.Health <= 0 then
        releaseTrigger()
        return
    end
    if not triggerDown then
        triggerDown = true
        local ok = pcall(function() tool:Activate() end)
        if ok then Power.sent += 1 else triggerDown = false end
    end
end

-- Remote boundary. Fires only through the game's own calls (checkcaller false);
-- 5-arg vector payloads are the gun shot contract, everything else passes through.
local mt = getrawmetatable(game)
local oldNamecall = rawget(mt, "__namecall")
pcall(setreadonly, mt, false)
mt.__namecall = newcclosure(function(self, ...)
    local method = getnamecallmethod()
    if method ~= "FireServer" or checkcaller() then
        return oldNamecall(self, ...)
    end

    if self == AimShare then
        local pitch, flags, yaw = ...
        if Settings.Enabled and Settings.ShareLook and reportDir then
            return oldNamecall(self,
                math.asin(math.clamp(reportDir.Y, -1, 1)),
                flags,
                math.atan2(-reportDir.X, -reportDir.Z))
        end
        return oldNamecall(self, pitch, flags, yaw)
    end

    -- Rocket: hit point and direction redirected onto the lock.
    if self == FireRocketR and Settings.FirePower and Settings.RocketAim and target then
        local hitPos, dir, worldPos = ...
        if typeof(hitPos) == "Vector3" and typeof(dir) == "Vector3" and typeof(worldPos) == "Vector3" then
            local d = target.point - worldPos
            if d.Magnitude > 0.5 then
                return oldNamecall(self, target.point, d.Unit, worldPos)
            end
        end
    end

    if fireSet[self] and Settings.Enabled then
        local n = select("#", ...)
        if n == 5 then
            local origin, dir, t, look, cone = ...
            if typeof(origin) == "Vector3" and typeof(dir) == "Vector3" and typeof(look) == "Vector3" then
                if Settings.SilentAim and target then
                    local d = target.point - origin
                    if d.Magnitude > 0.25 then
                        dir = d.Unit
                    end
                elseif Settings.FirePower and Settings.NoSpread then
                    -- Pre-recoil look: recoil is applied to the camera after this vector is set.
                    dir = look
                end

                if Settings.FirePower and Settings.NoSpread then
                    cone = Settings.SpreadCone
                end

                local ok, err = pcall(oldNamecall, self, origin, dir, t, look, cone)
                if not ok then Power.lastError = tostring(err) end

                if Settings.FirePower and Settings.Rapid then
                    learnTool(self)
                    if not FIRE_EXTRA_BLOCK[self.Name] then
                        local now = os.clock()
                        for _ = 2, math.clamp(Settings.RapidMul, 1, 3) do
                            if takeExtra(now) then
                                local ok2, err2 = pcall(oldNamecall, self, origin, dir, t, look, cone)
                                if ok2 then
                                    Power.extras += 1
                                else
                                    Power.lastError = tostring(err2)
                                end
                            end
                        end
                    end
                end
                return
            end
        end
    end

    -- Vehicle weapon lock: only while seated, only on our own hull id.
    if Settings.Enabled and Settings.VehicleWeapons and target and myVeh
        and (self == HeliFireR or self == HeliDoorFireR or self == TankFireR) then
        local n = select("#", ...)
        local args = table.pack(...)
        local id = args[1]

        if id == myVeh.id then
            if self == HeliFireR then
                local kind = args[2]
                local pos = args[3]
                if (kind == "gun" or kind == "rocket") and typeof(pos) == "Vector3" then
                    args[3] = target.point
                    return oldNamecall(self, table.unpack(args, 1, n))
                end
            elseif self == TankFireR then
                local yaw, pitch = args[2], args[3]
                if typeof(yaw) == "number" and typeof(pitch) == "number" then
                    local ny, np = aimAngles(myVeh.cf, target.point)
                    args[2] = ny
                    args[3] = np
                    return oldNamecall(self, table.unpack(args, 1, n))
                end
            elseif self == HeliDoorFireR then
                local dir = target.point - myVeh.cf.Position
                if dir.Magnitude > 0.5 then
                    dir = dir.Unit
                    local changed = false
                    for i = 2, n do
                        local v = args[i]
                        if typeof(v) == "Vector3" then
                            local m = v.Magnitude
                            if m > 0.9 and m < 1.1 then
                                args[i] = dir
                                changed = true
                            end
                        end
                    end
                    if changed then
                        return oldNamecall(self, table.unpack(args, 1, n))
                    end
                end
            end
        end
    end

    return oldNamecall(self, ...)
end)
pcall(setreadonly, mt, true)

-- Auto-run: native W through VirtualInputManager plus the movement module's own
-- sprint toggle, so speed, stance, pose flags and audio all come out legitimate.
local runHeld = false

local function pressRun()
    if runHeld or not Settings.AutoRun then return end
    if UserInputService:GetFocusedTextBox() then return end
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.W, false, game)
    end)
    runHeld = true
    if Settings.AutoSprint and Movement then
        pcall(function()
            if not Movement.sprintHeld() then Movement.toggleSprint() end
        end)
    end
end

local function releaseRun()
    if not runHeld then return end
    runHeld = false
    pcall(function()
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
    end)
end

local function manageRun()
    if not Settings.AutoRun then
        releaseRun()
        return
    end
    if UserInputService:GetFocusedTextBox() then
        releaseRun()
        return
    end
    if not runHeld then
        pressRun()
    elseif Settings.AutoSprint and Movement then
        if not Movement.sprintHeld() then
            pcall(function() Movement.toggleSprint() end)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Overlay: ScreenGui only
-- ---------------------------------------------------------------------------

local playerGui = LocalPlayer:WaitForChild("PlayerGui", 20)
local overlay = Instance.new("ScreenGui")
overlay.Name = "ugcAimOverlay"
overlay.ResetOnSpawn = false
overlay.IgnoreGuiInset = true
overlay.DisplayOrder = 100
overlay.Parent = playerGui

local COLOR_INF = Color3.fromRGB(255, 70, 70)
local COLOR_VEH = Color3.fromRGB(255, 160, 40)
local COLOR_TARGET = Color3.fromRGB(0, 230, 255)
local COLOR_FOV = Color3.fromRGB(255, 255, 255)

local fovFrame = Instance.new("Frame")
fovFrame.Name = "fov"
fovFrame.AnchorPoint = Vector2.new(0.5, 0.5)
fovFrame.Position = UDim2.fromScale(0.5, 0.5)
fovFrame.BackgroundTransparency = 1
fovFrame.Visible = false
fovFrame.Parent = overlay
local fovCorner = Instance.new("UICorner")
fovCorner.CornerRadius = UDim.new(0.5, 0)
fovCorner.Parent = fovFrame
local fovStroke = Instance.new("UIStroke")
fovStroke.Thickness = 1.5
fovStroke.Transparency = 0.25
fovStroke.Color = COLOR_FOV
fovStroke.Parent = fovFrame

local lockRing = Instance.new("Frame")
lockRing.Name = "lockRing"
lockRing.AnchorPoint = Vector2.new(0.5, 0.5)
lockRing.Size = UDim2.fromOffset(22, 22)
lockRing.BackgroundTransparency = 1
lockRing.Visible = false
lockRing.Parent = overlay
local lockRingCorner = Instance.new("UICorner")
lockRingCorner.CornerRadius = UDim.new(0.5, 0)
lockRingCorner.Parent = lockRing
local lockRingStroke = Instance.new("UIStroke")
lockRingStroke.Thickness = 1.5
lockRingStroke.Color = COLOR_TARGET
lockRingStroke.Parent = lockRing

local hud = Instance.new("TextLabel")
hud.Name = "hud"
hud.AnchorPoint = Vector2.new(0, 0)
hud.Position = UDim2.new(0, 12, 0.60, 0)
hud.Size = UDim2.fromOffset(700, 58)
hud.BackgroundTransparency = 0.55
hud.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
hud.Font = Enum.Font.Code
hud.TextSize = 14
hud.TextXAlignment = Enum.TextXAlignment.Left
hud.TextYAlignment = Enum.TextYAlignment.Top
hud.TextColor3 = Color3.fromRGB(225, 225, 225)
hud.TextStrokeTransparency = 0.4
hud.Text = ""
hud.Parent = overlay

local lockLabel = Instance.new("TextLabel")
lockLabel.Name = "lockLabel"
lockLabel.AnchorPoint = Vector2.new(0.5, 0.5)
lockLabel.Size = UDim2.fromOffset(460, 18)
lockLabel.BackgroundTransparency = 1
lockLabel.Font = Enum.Font.Code
lockLabel.TextSize = 15
lockLabel.TextColor3 = COLOR_TARGET
lockLabel.TextStrokeTransparency = 0.4
lockLabel.Text = ""
lockLabel.Visible = false
lockLabel.Parent = overlay

local pool = {}

local function slot(i)
    local e = pool[i]
    if e then return e end
    local frame = Instance.new("Frame")
    frame.AnchorPoint = Vector2.new(0, 0)
    frame.BackgroundTransparency = 1
    frame.Visible = false
    frame.Parent = overlay
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Parent = frame
    local label = Instance.new("TextLabel")
    label.AnchorPoint = Vector2.new(0, 1)
    label.Position = UDim2.fromOffset(0, -2)
    label.Size = UDim2.fromOffset(220, 14)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Code
    label.TextSize = 13
    label.TextStrokeTransparency = 0.3
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = ""
    label.Parent = frame
    e = { frame = frame, stroke = stroke, label = label }
    pool[i] = e
    return e
end

local function hide(entry)
    entry.frame.Visible = false
end

local function projectedBox(cam, m)
    if not m then return nil end
    local ok, cf, size = pcall(function()
        return m:GetBoundingBox()
    end)
    if not ok or not cf then return nil end
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    local any = false
    for sx = -0.5, 0.5, 1 do
        for sy = -0.5, 0.5, 1 do
            for sz = -0.5, 0.5, 1 do
                local wp = cf * Vector3.new(sx * size.X, sy * size.Y, sz * size.Z)
                local sp, on = cam:WorldToViewportPoint(wp)
                if on and sp.Z > 0 then
                    any = true
                    minX = math.min(minX, sp.X)
                    minY = math.min(minY, sp.Y)
                    maxX = math.max(maxX, sp.X)
                    maxY = math.max(maxY, sp.Y)
                end
            end
        end
    end
    if not any or maxX <= minX or maxY <= minY then return nil end
    return minX, minY, maxX, maxY
end

local function drawESP(cam)
    local idx = 0
    if Settings.ESP then
        for _, e in ipairs(entityCache) do
            local minX, minY, maxX, maxY
            if e.kind == "inf" then
                if e.model.Parent then
                    minX, minY, maxX, maxY = projectedBox(cam, e.model)
                end
            else
                local pos = e.point
                local sp, on = cam:WorldToViewportPoint(pos)
                if on and sp.Z > 0 then
                    local d = (pos - cam.CFrame.Position).Magnitude
                    local half = math.clamp(9000 / math.max(d, 1), 6, 60)
                    minX, minY = sp.X - half, sp.Y - half
                    maxX, maxY = sp.X + half, sp.Y + half
                end
            end

            if minX then
                idx += 1
                local s = slot(idx)
                local isTarget = target and target.key == entityKey(e)
                local color = isTarget and COLOR_TARGET
                    or (e.kind == "veh" and COLOR_VEH or COLOR_INF)
                s.stroke.Color = color
                s.frame.Position = UDim2.fromOffset(minX, minY)
                s.frame.Size = UDim2.fromOffset(maxX - minX, maxY - minY)
                s.frame.Visible = true
                s.label.TextColor3 = color

                local pos = e.kind == "inf" and entityPos(e) or e.point
                local dist = pos and math.floor((pos - cam.CFrame.Position).Magnitude) or 0
                if e.kind == "veh" then
                    s.label.Text = string.format("%s #%d  %d%%  %dm",
                        e.label or "Vehicle", e.id, math.floor((e.health or 0) * 100), dist)
                else
                    s.label.Text = e.model.Name .. "  " .. dist .. "m"
                end
                s.label.Visible = true
            end
        end
    end
    for i = idx + 1, #pool do
        hide(pool[i])
    end
end

local function drawFov(cam)
    local center = cam.ViewportSize * 0.5
    fovFrame.Position = UDim2.fromOffset(center.X, center.Y)
    fovFrame.Size = UDim2.fromOffset(Settings.FOV * 2, Settings.FOV * 2)
    fovStroke.Color = (Settings.Enabled and target) and COLOR_TARGET or COLOR_FOV
    fovFrame.Visible = Settings.Enabled and Settings.FOVCircle
end

local function powerLine()
    local rate = #entityCache
    local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
    local ammo = tool and tool:GetAttribute("Ammo")
    local mag = tool and tool:GetAttribute("MagSize")
    local ammoText = (typeof(ammo) == "number" and typeof(mag) == "number")
        and string.format(" %d/%d", ammo, mag) or ""
    return string.format("FIRE %s  rapid x%d (%d)  spread %s  reload %s (%d)%s",
        Settings.FirePower and "ON" or "OFF",
        Settings.Rapid and math.clamp(Settings.RapidMul, 1, 3) or 1,
        Power.extras,
        Settings.NoSpread and "OFF" or "ON",
        Settings.AutoReload and "ON" or "OFF",
        Power.reloads,
        ammoText)
end

local function targetLabel()
    if not target then return nil end
    if target.kind == "veh" then
        return string.format("LOCK  %s #%d  [%d%%]", target.label or "Vehicle", target.id,
            math.floor(math.clamp(target.health or 0, 0, 1) * 100))
    end
    return "LOCK  " .. target.model.Name .. "  [" .. (target.part and target.part.Name or "body") .. "]"
end

local function drawHud(cam)
    local center = cam.ViewportSize * 0.5
    local vehCount = 0
    for _, e in ipairs(entityCache) do
        if e.kind == "veh" then vehCount += 1 end
    end
    hud.Text = ("AIM %s  MODE %s  RUN %s  ESP %s  FOV %d  HEAD %s  INF %d  VEH %d%s\n%s%s")
        :format(Settings.Enabled and "ON" or "OFF",
            Settings.TargetMode:upper(),
            Settings.AutoRun and "ON" or "OFF",
            Settings.ESP and "ON" or "OFF",
            Settings.FOV,
            Settings.HeadAim and "ON" or "OFF",
            #entityCache - vehCount,
            vehCount,
            myVeh and ("  GUN V" .. tostring(myVeh.id)) or "",
            powerLine(),
            Settings.Trigger and "  TRIG ON" or "")
    hud.Visible = true

    if Settings.Enabled and target then
        local sp, on = cam:WorldToViewportPoint(target.point)
        if on and sp.Z > 0 then
            lockRing.Position = UDim2.fromOffset(sp.X, sp.Y)
            lockRingStroke.Color = COLOR_TARGET
            lockRing.Visible = true
            lockLabel.Position = UDim2.fromOffset(center.X, center.Y + Settings.FOV + 22)
            lockLabel.Text = targetLabel()
            lockLabel.TextColor3 = COLOR_TARGET
            lockLabel.Visible = true
            return
        end
    end
    lockRing.Visible = false
    if Settings.Enabled then
        lockLabel.Position = UDim2.fromOffset(center.X, center.Y + Settings.FOV + 22)
        lockLabel.Text = "no lock"
        lockLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
        lockLabel.Visible = true
    else
        lockLabel.Visible = false
    end
end

local function step(dt)
    local cam = workspace.CurrentCamera
    if not cam then return end

    local now = os.clock()
    if now >= nextScan then
        local t0 = os.clock()
        collect()
        updateTarget(cam, now)
        scanMs = (os.clock() - t0) * 1000
        nextScan = now + (target and 0.05 or 0.02)
    end

    updateAimPoint(dt)
    updateReport(dt)
    manageRun()
    autoReload(now)
    triggerStep(now)
    drawESP(cam)
    drawFov(cam)
    drawHud(cam)
end

task.spawn(function()
    while S.alive() do
        local dt = RunService.RenderStepped:Wait()
        local ok, err = pcall(step, dt)
        if not ok then warn("[UgcAim] frame: " .. tostring(err)) end
    end
end)

local function setAutoRun(on)
    Settings.AutoRun = on
    if on then
        pressRun()
    else
        releaseRun()
    end
end

local function cycleMode()
    if Settings.TargetMode == "both" then
        Settings.TargetMode = "vehicles"
    elseif Settings.TargetMode == "vehicles" then
        Settings.TargetMode = "infantry"
    else
        Settings.TargetMode = "both"
    end
    target = nil
    print("[UgcAim] target mode " .. Settings.TargetMode)
end

local function cycleRapid()
    local m = Settings.RapidMul
    if m >= 3 then
        Settings.RapidMul = 1
    else
        Settings.RapidMul = m + 1
    end
    print("[UgcAim] rapid x" .. Settings.RapidMul)
end

S.connect(UserInputService.InputBegan, function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F1 then
        Settings.Enabled = not Settings.Enabled
        print("[UgcAim] aim " .. (Settings.Enabled and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.F2 then
        Settings.ESP = not Settings.ESP
        print("[UgcAim] esp " .. (Settings.ESP and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.F3 then
        Settings.FOVCircle = not Settings.FOVCircle
        print("[UgcAim] fov " .. (Settings.FOVCircle and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.F4 then
        setAutoRun(not Settings.AutoRun)
        print("[UgcAim] autorun " .. (Settings.AutoRun and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.F5 then
        cycleMode()
    elseif input.KeyCode == Enum.KeyCode.F6 then
        Settings.VehicleWeapons = not Settings.VehicleWeapons
        print("[UgcAim] vehicle weapons " .. (Settings.VehicleWeapons and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.F7 then
        Settings.Trigger = not Settings.Trigger
        print("[UgcAim] trigger " .. (Settings.Trigger and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.F8 then
        cycleRapid()
    elseif input.KeyCode == Enum.KeyCode.F9 then
        Settings.NoSpread = not Settings.NoSpread
        print("[UgcAim] no spread " .. (Settings.NoSpread and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.F10 then
        Settings.AutoReload = not Settings.AutoReload
        print("[UgcAim] auto reload " .. (Settings.AutoReload and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.F11 then
        Settings.RocketAim = not Settings.RocketAim
        print("[UgcAim] rocket aim " .. (Settings.RocketAim and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.H then
        Settings.HeadAim = not Settings.HeadAim
        print("[UgcAim] head aim " .. (Settings.HeadAim and "ON" or "OFF"))
    end
end)

S.onCleanup(function()
    releaseRun()
    releaseTrigger()
    pcall(setreadonly, mt, false)
    mt.__namecall = oldNamecall
    pcall(setreadonly, mt, true)
    if overlay then overlay:Destroy() end
    table.clear(pool)
    table.clear(toolReload)
    table.clear(reloadAt)
end)

getgenv().UgcAim = {
    Settings = Settings,
    setAutoRun = setAutoRun,
    cycleMode = cycleMode,
    cycleRapid = cycleRapid,
}

getgenv().UgcAimStatus = function()
    local veh, inf = 0, 0
    for _, e in ipairs(entityCache) do
        if e.kind == "veh" then veh += 1 else inf += 1 end
    end
    local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
    return {
        installed = true,
        enabled = Settings.Enabled,
        esp = Settings.ESP,
        fov = Settings.FOV,
        maxDistance = Settings.MaxDistance,
        maxVehicleDistance = Settings.MaxVehicleDistance,
        mode = Settings.TargetMode,
        lead = Settings.Lead,
        vehicleWeapons = Settings.VehicleWeapons,
        inVehicle = myVeh and myVeh.id or nil,
        autoRun = Settings.AutoRun,
        autoSprint = Settings.AutoSprint,
        sprintHeld = Movement and Movement.sprintHeld() or nil,
        runHeld = runHeld,
        target = target and (target.kind == "veh"
            and string.format("%s#%d", target.label or "Vehicle", target.id)
            or target.name) or nil,
        targetKind = target and target.kind or nil,
        targetHealth = target and target.health or nil,
        part = target and target.part and target.part.Name or nil,
        infantry = inf,
        vehicles = veh,
        poolSize = #pool,
        scanMs = scanMs,
        reportDir = reportDir and tostring(reportDir) or nil,
        firePower = Settings.FirePower,
        rapid = Settings.Rapid,
        rapidMul = Settings.RapidMul,
        extras = Power.extras,
        noSpread = Settings.NoSpread,
        cone = Settings.SpreadCone,
        autoReload = Settings.AutoReload,
        reloads = Power.reloads,
        trigger = Settings.Trigger,
        rocketAim = Settings.RocketAim,
        headAim = Settings.HeadAim,
        tool = tool and tool.Name or nil,
        ammo = tool and tool:GetAttribute("Ammo") or nil,
        mag = tool and tool:GetAttribute("MagSize") or nil,
        toolMap = Power.toolMap,
        lastError = Power.lastError,
        hud = hud and hud.Text or nil,
    }
end

print("[UgcAim] installed - aim, ESP, FOV, autorun, rapid fire, no spread, auto reload, rocket aim (F1-F11)")
