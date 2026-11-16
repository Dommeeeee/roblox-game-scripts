-- Ugc / Voxel War: silent aim with infantry and vehicle lock, ESP, FOV, auto-run.
-- Camera is never touched. The shot payload is rewritten at the remote boundary,
-- and the AimShare look report is steered to the same direction so the server-side
-- look, shot direction and per-shot look argument stay mutually consistent.
--
-- Vehicles are read from ReplicatedStorage.Vehicles.Live: Id, Model, Team, Health,
-- Wrecked, Pose. The hull model is optional for targeting - pose is always there.

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

    if fireSet[self] and Settings.Enabled and Settings.SilentAim and target then
        local n = select("#", ...)
        if n == 5 then
            local origin, dir, t, look, cone = ...
            if typeof(origin) == "Vector3" and typeof(dir) == "Vector3" and typeof(look) == "Vector3" then
                local d = target.point - origin
                if d.Magnitude > 0.25 then
                    d = d.Unit
                    return oldNamecall(self, origin, d, t, d, cone)
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

local pool = {}
local fovCircle = Drawing.new("Circle")
fovCircle.Thickness = 1
fovCircle.Filled = false
fovCircle.Transparency = 0.75
fovCircle.Visible = false

local hud = Drawing.new("Text")
hud.Size = 14
hud.Center = false
hud.Outline = true
hud.Font = Drawing.Fonts.UI
hud.Color = Color3.fromRGB(225, 225, 225)
hud.Position = Vector2.new(14, 10)
hud.Visible = false

local lockLabel = Drawing.new("Text")
lockLabel.Size = 15
lockLabel.Center = true
lockLabel.Outline = true
lockLabel.Font = Drawing.Fonts.UI
lockLabel.Visible = false

local lockRing = Drawing.new("Circle")
lockRing.Thickness = 1.5
lockRing.Filled = false
lockRing.Transparency = 0.9
lockRing.Radius = 5
lockRing.Visible = false

local COLOR_INF = Color3.fromRGB(255, 70, 70)
local COLOR_VEH = Color3.fromRGB(255, 160, 40)
local COLOR_TARGET = Color3.fromRGB(0, 230, 255)

local function hide(entry)
    entry.box.Visible = false
    entry.label.Visible = false
end

local function slot(i)
    local e = pool[i]
    if e then return e end
    e = {
        box = Drawing.new("Square"),
        label = Drawing.new("Text"),
    }
    e.box.Thickness = 1
    e.box.Filled = false
    e.label.Size = 13
    e.label.Center = false
    e.label.Outline = true
    e.label.Font = Drawing.Fonts.UI
    pool[i] = e
    return e
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
                s.box.Color = color
                s.box.Position = Vector2.new(minX, minY)
                s.box.Size = Vector2.new(maxX - minX, maxY - minY)
                s.box.Visible = true
                s.label.Color = color
                s.label.Position = Vector2.new(minX, minY - 16)

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
    fovCircle.Position = center
    fovCircle.Radius = Settings.FOV
    fovCircle.Color = target and COLOR_TARGET or Color3.fromRGB(255, 255, 255)
    fovCircle.Visible = Settings.Enabled and Settings.FOVCircle
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
    hud.Text = ("AIM %s   MODE %s   RUN %s   ESP %s   FOV %d   INF %d   VEH %d")
        :format(Settings.Enabled and "ON" or "OFF",
            Settings.TargetMode:upper(),
            Settings.AutoRun and "ON" or "OFF",
            Settings.ESP and "ON" or "OFF",
            Settings.FOV,
            #entityCache - vehCount,
            vehCount)
    hud.Visible = true

    if Settings.Enabled and target then
        local sp, on = cam:WorldToViewportPoint(target.point)
        if on and sp.Z > 0 then
            lockRing.Position = Vector2.new(sp.X, sp.Y)
            lockRing.Color = COLOR_TARGET
            lockRing.Visible = true
            lockLabel.Position = Vector2.new(center.X, center.Y + Settings.FOV + 22)
            lockLabel.Text = targetLabel()
            lockLabel.Color = COLOR_TARGET
            lockLabel.Visible = true
            return
        end
    end
    lockRing.Visible = false
    if Settings.Enabled then
        lockLabel.Position = Vector2.new(center.X, center.Y + Settings.FOV + 22)
        lockLabel.Text = "no lock"
        lockLabel.Color = Color3.fromRGB(150, 150, 150)
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
    end
end)

S.onCleanup(function()
    releaseRun()
    pcall(setreadonly, mt, false)
    mt.__namecall = oldNamecall
    pcall(setreadonly, mt, true)
    for _, e in ipairs(pool) do
        e.box:Remove()
        e.label:Remove()
    end
    fovCircle:Remove()
    hud:Remove()
    lockLabel:Remove()
    lockRing:Remove()
end)

getgenv().UgcAim = { Settings = Settings, setAutoRun = setAutoRun, cycleMode = cycleMode }

getgenv().UgcAimStatus = function()
    local veh, inf = 0, 0
    for _, e in ipairs(entityCache) do
        if e.kind == "veh" then veh += 1 else inf += 1 end
    end
    return {
        installed = true,
        enabled = Settings.Enabled,
        esp = Settings.ESP,
        fov = Settings.FOV,
        maxDistance = Settings.MaxDistance,
        maxVehicleDistance = Settings.MaxVehicleDistance,
        mode = Settings.TargetMode,
        lead = Settings.Lead,
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
    }
end

print("[UgcAim] installed - silent aim, infantry+vehicle lock, ESP, FOV, autorun (F1-F5)")
