-- Ugc / Voxel War: silent aim, visible-part targeting, FOV circle, ESP, auto-run.
-- Camera is never touched. The shot payload is rewritten at the remote boundary,
-- and the AimShare look report is steered to the same direction so the server-side
-- look, shot direction and per-shot look argument stay mutually consistent.

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
    TeamCheck = true,
    Smooth = 24,
    AutoRun = false,
    AutoSprint = true,
}

local Voxel = ReplicatedStorage:WaitForChild("Voxel", 20)
local Remotes = Voxel and Voxel:WaitForChild("Remotes", 20)
local AimShare = Remotes and Remotes:WaitForChild("AimShare", 10)
if not AimShare then
    warn("[UgcAim] Voxel.Remotes.AimShare not found")
    return
end

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
local enemyCache = {}
local nextScan = 0
local scanMs = 0

local function collect()
    local list = {}
    local myTeam = LocalPlayer.Team
    local myTeamName = myTeam and myTeam.Name

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and not (Settings.TeamCheck and myTeam and p.Team == myTeam) then
            local ch = p.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if ch and hum and hum.Health > 0 and ch:GetAttribute("Protected") ~= true then
                table.insert(list, ch)
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
                    table.insert(list, b)
                end
            end
        end
    end

    enemyCache = list
end

local function excludeFor(model, cam)
    local ex = {}
    if LocalPlayer.Character then ex[#ex + 1] = LocalPlayer.Character end
    ex[#ex + 1] = cam
    ex[#ex + 1] = model
    return ex
end

local function pointVisible(model, part, camPos, ex)
    rayParams.FilterDescendantsInstances = ex
    local hit = workspace:Raycast(camPos, part.Position - camPos, rayParams)
    return (not hit) or hit.Instance:IsDescendantOf(model)
end

-- First part in priority order that the camera can actually see. Chest when the
-- torso is clear; otherwise whatever limb is showing.
local function visiblePoint(model, camPos, ex)
    for _, entry in ipairs(PART_ORDER) do
        local part = model:FindFirstChild(entry.name, true)
        if part and part:IsA("BasePart") and pointVisible(model, part, camPos, ex) then
            return part
        end
    end
    return nil
end

local function screenAngle(cam, pos, center)
    local sp, on = cam:WorldToViewportPoint(pos)
    if not on or sp.Z <= 0 then return nil end
    return (Vector2.new(sp.X, sp.Y) - center).Magnitude
end

local function candidateScore(m, cam, center, camPos)
    local part = m:FindFirstChild("UpperTorso") or m:FindFirstChild("Torso")
        or m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
    if not part then return nil end
    local d = screenAngle(cam, part.Position, center)
    if not d or d > Settings.FOV then return nil end
    if (part.Position - camPos).Magnitude > Settings.MaxDistance then return nil end
    return d
end

local function bestVisible(cam, center, camPos, limit)
    local cands = {}
    for _, m in ipairs(enemyCache) do
        local sc = candidateScore(m, cam, center, camPos)
        if sc then table.insert(cands, { model = m, score = sc }) end
    end
    table.sort(cands, function(a, b) return a.score < b.score end)
    for i = 1, math.min(#cands, limit) do
        local m = cands[i].model
        local part = visiblePoint(m, camPos, excludeFor(m, cam))
        if part then
            return m, part, cands[i].score
        end
    end
    return nil
end

local function updateTarget(cam, now)
    if not Settings.Enabled then
        target = nil
        return
    end

    local center = cam.ViewportSize * 0.5
    local camPos = cam.CFrame.Position

    if target and not (target.model.Parent and target.part.Parent) then
        target = nil
    end

    -- Retain the current lock while it stays visible, even after a small drift out
    -- of the acquisition ring. Stops the reticle hopping between two bodies.
    if target then
        local d = screenAngle(cam, target.part.Position, center)
        if d and d <= Settings.FOV * 1.4
            and pointVisible(target.model, target.part, camPos, excludeFor(target.model, cam)) then
            target.point = target.part.Position
            target.score = d
            return
        end
    end

    local m, part, score = bestVisible(cam, center, camPos, 8)
    if m then
        target = { model = m, part = part, point = part.Position, score = score }
    else
        target = nil
    end
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

local function drawESP(cam)
    local idx = 0
    if Settings.ESP then
        for _, m in ipairs(enemyCache) do
            if m.Parent then
                local ok, cf, size = pcall(function()
                    return m:GetBoundingBox()
                end)
                if ok and cf then
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
                    if any and maxX > minX and maxY > minY then
                        idx += 1
                        local e = slot(idx)
                        local isTarget = target and target.model == m
                        local color = isTarget and Color3.fromRGB(0, 230, 255) or Color3.fromRGB(255, 70, 70)
                        e.box.Color = color
                        e.box.Position = Vector2.new(minX, minY)
                        e.box.Size = Vector2.new(maxX - minX, maxY - minY)
                        e.box.Visible = true
                        e.label.Color = color
                        e.label.Position = Vector2.new(minX, minY - 16)
                        local root = m:FindFirstChild("HumanoidRootPart")
                        local d = root and math.floor((root.Position - cam.CFrame.Position).Magnitude) or 0
                        e.label.Text = m.Name .. "  " .. d .. "m"
                        e.label.Visible = true
                    end
                end
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
    fovCircle.Color = target and Color3.fromRGB(0, 230, 255) or Color3.fromRGB(255, 255, 255)
    fovCircle.Visible = Settings.Enabled and Settings.FOVCircle
end

local function drawHud(cam)
    local center = cam.ViewportSize * 0.5
    hud.Text = ("AIM %s   RUN %s   ESP %s   FOV %d   TGT %d")
        :format(Settings.Enabled and "ON" or "OFF",
            Settings.AutoRun and "ON" or "OFF",
            Settings.ESP and "ON" or "OFF",
            Settings.FOV,
            #enemyCache)
    hud.Visible = true

    if Settings.Enabled and target then
        local sp, on = cam:WorldToViewportPoint(target.point)
        if on and sp.Z > 0 then
            lockRing.Position = Vector2.new(sp.X, sp.Y)
            lockRing.Color = Color3.fromRGB(0, 230, 255)
            lockRing.Visible = true
            lockLabel.Position = Vector2.new(center.X, center.Y + Settings.FOV + 22)
            lockLabel.Text = "LOCK  " .. target.model.Name .. "  [" .. target.part.Name .. "]"
            lockLabel.Color = Color3.fromRGB(0, 230, 255)
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

    if target then
        target.point = target.part.Position
    end

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

getgenv().UgcAim = { Settings = Settings, setAutoRun = setAutoRun }

getgenv().UgcAimStatus = function()
    return {
        installed = true,
        enabled = Settings.Enabled,
        esp = Settings.ESP,
        fov = Settings.FOV,
        maxDistance = Settings.MaxDistance,
        autoRun = Settings.AutoRun,
        autoSprint = Settings.AutoSprint,
        sprintHeld = Movement and Movement.sprintHeld() or nil,
        runHeld = runHeld,
        target = target and target.model.Name or nil,
        part = target and target.part.Name or nil,
        enemies = #enemyCache,
        poolSize = #pool,
        scanMs = scanMs,
        reportDir = reportDir and tostring(reportDir) or nil,
    }
end

print("[UgcAim] installed - silent aim, visible-part targeting, ESP, FOV, autorun (F1/F2/F3/F4)")
