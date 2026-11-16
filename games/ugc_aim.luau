-- Ugc / Voxel War: silent aim, visible-part targeting, FOV circle, ESP.
-- Camera is never touched. The shot payload is rewritten at the remote boundary,
-- and the AimShare look report is steered to the same direction so the server-side
-- look, shot direction and per-shot look argument stay mutually consistent.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

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
    MaxDistance = 450,
    TeamCheck = true,
    Smooth = 24,
}

local Voxel = ReplicatedStorage:WaitForChild("Voxel", 20)
local Remotes = Voxel and Voxel:WaitForChild("Remotes", 20)
local AimShare = Remotes and Remotes:WaitForChild("AimShare", 10)
if not AimShare then
    warn("[UgcAim] Voxel.Remotes.AimShare not found")
    return
end

local fireSet = {}
for _, r in ipairs(Remotes:GetChildren()) do
    if r:IsA("RemoteEvent") and r.Name:sub(1, 4) == "Fire" then
        fireSet[r] = true
    end
end

local Bots = workspace:FindFirstChild("BotRigs")

-- Head is deliberately absent: body first, exposed limb when that is all there is.
local PART_ORDER = {
    { name = "UpperTorso", w = 1 },
    { name = "Torso", w = 1 },
    { name = "LowerTorso", w = 2 },
    { name = "LeftUpperArm", w = 3 },
    { name = "RightUpperArm", w = 3 },
    { name = "Left Arm", w = 3 },
    { name = "Right Arm", w = 3 },
    { name = "LeftLowerArm", w = 4 },
    { name = "RightLowerArm", w = 4 },
    { name = "LeftUpperLeg", w = 5 },
    { name = "RightUpperLeg", w = 5 },
    { name = "Left Leg", w = 5 },
    { name = "Right Leg", w = 5 },
    { name = "LeftLowerLeg", w = 6 },
    { name = "RightLowerLeg", w = 6 },
    { name = "LeftFoot", w = 7 },
    { name = "RightFoot", w = 7 },
    { name = "LeftHand", w = 8 },
    { name = "RightHand", w = 8 },
}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local target = nil
local reportDir = nil
local enemyCache = {}
local scanT = 0

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

-- First part in priority order that the camera can actually see. Chest when the
-- torso is clear; otherwise whatever limb is showing.
local function visiblePoint(model, camPos, exclude)
    rayParams.FilterDescendantsInstances = exclude
    for _, entry in ipairs(PART_ORDER) do
        local part = model:FindFirstChild(entry.name, true)
        if part and part:IsA("BasePart") then
            local hit = workspace:Raycast(camPos, part.Position - camPos, rayParams)
            if not hit or hit.Instance:IsDescendantOf(model) then
                return part
            end
        end
    end
    return nil
end

local function pickTarget(cam)
    if not Settings.Enabled then
        target = nil
        return
    end

    local center = cam.ViewportSize * 0.5
    local camPos = cam.CFrame.Position
    local cands = {}

    for _, m in ipairs(enemyCache) do
        local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
        if root then
            local sp, on = cam:WorldToViewportPoint(root.Position)
            if on and sp.Z > 0 then
                local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                if d <= Settings.FOV then
                    local dist = (root.Position - camPos).Magnitude
                    if dist <= Settings.MaxDistance then
                        table.insert(cands, { model = m, score = d })
                    end
                end
            end
        end
    end

    table.sort(cands, function(a, b) return a.score < b.score end)

    target = nil
    for i = 1, math.min(#cands, 6) do
        local m = cands[i].model
        local ex = {}
        if LocalPlayer.Character then ex[#ex + 1] = LocalPlayer.Character end
        ex[#ex + 1] = cam
        ex[#ex + 1] = m
        local part = visiblePoint(m, camPos, ex)
        if part then
            target = { model = m, part = part, point = part.Position, dist = cands[i].score }
            return
        end
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

local pool = {}
local fovCircle = Drawing.new("Circle")
fovCircle.Thickness = 1
fovCircle.Filled = false
fovCircle.Transparency = 0.75
fovCircle.Visible = false

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

local function step(dt)
    local cam = workspace.CurrentCamera
    if not cam then return end

    scanT += dt
    if scanT >= 0.05 then
        scanT = 0
        collect()
        pickTarget(cam)
    elseif target and target.model.Parent == nil then
        target = nil
    end

    updateReport(dt)
    drawESP(cam)
    drawFov(cam)
end

task.spawn(function()
    while S.alive() do
        local dt = RunService.RenderStepped:Wait()
        local ok, err = pcall(step, dt)
        if not ok then warn("[UgcAim] frame: " .. tostring(err)) end
    end
end)

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
    end
end)

S.onCleanup(function()
    pcall(setreadonly, mt, false)
    mt.__namecall = oldNamecall
    pcall(setreadonly, mt, true)
    for _, e in ipairs(pool) do
        e.box:Remove()
        e.label:Remove()
    end
    fovCircle:Remove()
end)

getgenv().UgcAim = { Settings = Settings }

getgenv().UgcAimStatus = function()
    return {
        installed = true,
        enabled = Settings.Enabled,
        esp = Settings.ESP,
        fov = Settings.FOV,
        target = target and target.model.Name or nil,
        part = target and target.part.Name or nil,
        enemies = #enemyCache,
        poolSize = #pool,
        reportDir = reportDir and tostring(reportDir) or nil,
    }
end

print("[UgcAim] installed - silent aim, visible-part targeting, ESP, FOV (F1/F2/F3)")
