-- ==============================================================================
-- VANTA CLOVERFALL // AUTO-FARM V5 (ANTI-KICK GROUND ENGINE)
-- PlaceId: 76894257773137 | PlaceVersion: 1254
-- Designed for dj
-- ==============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- 0. Cleanup Previous Instances
if _G.VANTA_FARM_CLEANUP then
    pcall(_G.VANTA_FARM_CLEANUP)
    _G.VANTA_FARM_CLEANUP = nil
end

local existingGui = PlayerGui:FindFirstChild("VantaCloverHub")
if existingGui then existingGui:Destroy() end

local ProgressionConfig = require(ReplicatedStorage.Modules.ProgressionConfig)
local CombatConfig = require(ReplicatedStorage.Modules.CombatConfig)

-- 1. Helper: Target Mob Band by Level
local function getTargetBand(lvl)
    local success, band = pcall(ProgressionConfig.bandFor, lvl)
    if success and band then
        return band
    end
    if ProgressionConfig.bands then
        for _, b in ipairs(ProgressionConfig.bands) do
            if lvl >= b.from and lvl <= b.to then
                return b
            end
        end
        return ProgressionConfig.bands[#ProgressionConfig.bands]
    end
    return { id = "CloverOutlaws", title = "Clover Outlaws", from = 25, to = 50 }
end

-- 2. Helper: Find Spawn Point for Mob
local function getSpawnPosition(mobId)
    local es = workspace:FindFirstChild("EnemySpawns")
    if not es then return nil end
    local spawnPart = es:FindFirstChild(mobId .. "Spawn")
    if spawnPart and spawnPart:IsA("BasePart") then
        return spawnPart.Position
    end
    for _, child in ipairs(es:GetChildren()) do
        if child.Name:find(mobId) and child:IsA("BasePart") then
            return child.Position
        end
    end
    return nil
end

-- 3. Helper: Find Best Alive Target Mob in workspace or workspace.Enemies
local function findNearestTargetMob(mobId)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end

    local best, bestDist = nil, 999999

    local function scanFolder(folder)
        if not folder then return end
        for _, model in ipairs(folder:GetChildren()) do
            if model:IsA("Model") and (model.Name == mobId or model.Name:find(mobId)) then
                local hum = model:FindFirstChildOfClass("Humanoid")
                local mHrp = model:FindFirstChild("HumanoidRootPart")
                if hum and hum.Health > 0 and mHrp then
                    local dist = (mHrp.Position - hrp.Position).Magnitude
                    if dist < bestDist then
                        bestDist = dist
                        best = model
                    end
                end
            end
        end
    end

    scanFolder(workspace:FindFirstChild("Enemies"))
    scanFolder(workspace)
    return best, bestDist
end

-- 4. GUI Construction (Glassmorphism & Drift Styling)
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "VantaCloverHub"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = PlayerGui

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 310, 0, 270)
MainFrame.Position = UDim2.new(0.04, 0, 0.32, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(15, 16, 22)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 14)
MainCorner.Parent = MainFrame

local MainStroke = Instance.new("UIStroke")
MainStroke.Thickness = 1.6
MainStroke.Color = Color3.fromRGB(0, 220, 255)
MainStroke.Transparency = 0.35
MainStroke.Parent = MainFrame

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Name = "TitleLabel"
TitleLabel.Size = UDim2.new(1, -20, 0, 36)
TitleLabel.Position = UDim2.new(0, 14, 0, 6)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.Text = "VANTA // AUTO-FARM V5"
TitleLabel.TextColor3 = Color3.fromRGB(240, 245, 255)
TitleLabel.TextSize = 15
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = MainFrame

local SubTitle = Instance.new("TextLabel")
SubTitle.Name = "SubTitle"
SubTitle.Size = UDim2.new(1, -20, 0, 16)
SubTitle.Position = UDim2.new(0, 14, 0, 36)
SubTitle.BackgroundTransparency = 1
SubTitle.Font = Enum.Font.Gotham
SubTitle.Text = "Ground Anti-Kick // Safe Behind Stance"
SubTitle.TextColor3 = Color3.fromRGB(130, 140, 170)
SubTitle.TextSize = 11
SubTitle.TextXAlignment = Enum.TextXAlignment.Left
SubTitle.Parent = MainFrame

local InfoCard = Instance.new("Frame")
InfoCard.Name = "InfoCard"
InfoCard.Size = UDim2.new(1, -28, 0, 115)
InfoCard.Position = UDim2.new(0, 14, 0, 62)
InfoCard.BackgroundColor3 = Color3.fromRGB(22, 24, 34)
InfoCard.BorderSizePixel = 0
InfoCard.Parent = MainFrame

local InfoCorner = Instance.new("UICorner")
InfoCorner.CornerRadius = UDim.new(0, 10)
InfoCorner.Parent = InfoCard

local function createRow(name, yPos, labelText, defaultVal)
    local rowLabel = Instance.new("TextLabel")
    rowLabel.Size = UDim2.new(0.45, 0, 0, 22)
    rowLabel.Position = UDim2.new(0, 10, 0, yPos)
    rowLabel.BackgroundTransparency = 1
    rowLabel.Font = Enum.Font.GothamMedium
    rowLabel.Text = labelText
    rowLabel.TextColor3 = Color3.fromRGB(150, 160, 190)
    rowLabel.TextSize = 11
    rowLabel.TextXAlignment = Enum.TextXAlignment.Left
    rowLabel.Parent = InfoCard

    local valLabel = Instance.new("TextLabel")
    valLabel.Name = name
    valLabel.Size = UDim2.new(0.5, 0, 0, 22)
    valLabel.Position = UDim2.new(0.48, 0, 0, yPos)
    valLabel.BackgroundTransparency = 1
    valLabel.Font = Enum.Font.GothamBold
    valLabel.Text = defaultVal
    valLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    valLabel.TextSize = 11
    valLabel.TextXAlignment = Enum.TextXAlignment.Right
    valLabel.Parent = InfoCard
    return valLabel
end

local LevelVal = createRow("LevelVal", 8, "CURRENT LEVEL:", "Lv. --")
local TargetVal = createRow("TargetVal", 32, "TARGET MOB:", "--")
local HealthVal = createRow("HealthVal", 56, "MOB HEALTH:", "-- / --")
local StatusVal = createRow("StatusVal", 80, "STATUS:", "STANDBY")
StatusVal.TextColor3 = Color3.fromRGB(255, 170, 0)

local ToggleBtn = Instance.new("TextButton")
ToggleBtn.Name = "ToggleBtn"
ToggleBtn.Size = UDim2.new(1, -28, 0, 44)
ToggleBtn.Position = UDim2.new(0, 14, 0, 195)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(0, 180, 110)
ToggleBtn.BorderSizePixel = 0
ToggleBtn.Font = Enum.Font.GothamBold
ToggleBtn.Text = "START AUTO-FARM"
ToggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ToggleBtn.TextSize = 13
ToggleBtn.Parent = MainFrame

local BtnCorner = Instance.new("UICorner")
BtnCorner.CornerRadius = UDim.new(0, 10)
BtnCorner.Parent = ToggleBtn

-- 5. Core Farm State Machine
local isRunning = false
local currentTarget = nil
local lastAttack = 0
local isTraveling = false

local function cleanup()
    isRunning = false
    isTraveling = false
    currentTarget = nil
    pcall(function()
        CombatConfig.platformFire("FistAttack", Enum.UserInputState.End)
    end)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum.WalkSpeed = 16 end
end

_G.VANTA_FARM_CLEANUP = function()
    cleanup()
    if ScreenGui and ScreenGui.Parent then ScreenGui:Destroy() end
end

local function toggleFarm()
    isRunning = not isRunning
    if isRunning then
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(220, 50, 60)
        ToggleBtn.Text = "STOP AUTO-FARM"
        StatusVal.Text = "ACTIVE"
        StatusVal.TextColor3 = Color3.fromRGB(0, 255, 150)
    else
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(0, 180, 110)
        ToggleBtn.Text = "START AUTO-FARM"
        StatusVal.Text = "STANDBY"
        StatusVal.TextColor3 = Color3.fromRGB(255, 170, 0)
        HealthVal.Text = "-- / --"
        cleanup()
    end
end

ToggleBtn.MouseButton1Click:Connect(toggleFarm)

-- 6. Ground Travel Helper (Anti-Rollback Lerp at 65 studs/s)
local function travelToGroundPosition(targetPos, maxDistanceStop)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local dist = (targetPos - hrp.Position).Magnitude
    if dist <= maxDistanceStop then return end

    isTraveling = true
    StatusVal.Text = "TRAVELING (" .. math.floor(dist) .. "s)"
    StatusVal.TextColor3 = Color3.fromRGB(0, 200, 255)

    local path = PathfindingService:CreatePath({
        AgentRadius = 2.5,
        AgentHeight = 5,
        AgentCanJump = true,
        WaypointSpacing = 8
    })

    pcall(function()
        path:ComputeAsync(hrp.Position, targetPos)
    end)

    local waypoints = (path.Status == Enum.PathStatus.Success) and path:GetWaypoints() or nil
    local speed = 65

    if waypoints and #waypoints > 1 then
        for i = 2, #waypoints do
            if not isRunning then break end
            local wp = waypoints[i]
            local wpPos = wp.Position + Vector3.new(0, 2.5, 0)
            local curPos = hrp.Position
            local legDist = (wpPos - curPos).Magnitude

            if (targetPos - hrp.Position).Magnitude <= maxDistanceStop then break end

            if legDist > 0.5 then
                local legTime = legDist / speed
                local steps = math.max(1, math.floor(legTime / 0.03))
                local dir = (wpPos - curPos).Unit
                for s = 1, steps do
                    if not isRunning then break end
                    local alpha = s / steps
                    local p = curPos:Lerp(wpPos, alpha)
                    hrp.CFrame = CFrame.new(p, p + dir)
                    hrp.AssemblyLinearVelocity = dir * speed
                    task.wait(0.03)
                end
            end
        end
    else
        local curPos = hrp.Position
        local legDist = (targetPos - curPos).Magnitude
        local steps = math.max(1, math.floor((legDist / speed) / 0.03))
        local dir = (targetPos - curPos).Unit
        for s = 1, steps do
            if not isRunning then break end
            if (targetPos - hrp.Position).Magnitude <= maxDistanceStop then break end
            local alpha = s / steps
            local p = curPos:Lerp(targetPos, alpha)
            hrp.CFrame = CFrame.new(p, p + dir)
            hrp.AssemblyLinearVelocity = dir * speed
            task.wait(0.03)
        end
    end

    if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
    isTraveling = false
end

-- 7. Main Farm Loop
task.spawn(function()
    while true do
        task.wait(0.04)

        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local hum = char and char:FindFirstChildOfClass("Humanoid")

        if not hrp or not hum or hum.Health <= 0 then
            task.wait(1)
            continue
        end

        local lvl = LocalPlayer:GetAttribute("Level") or 1
        LevelVal.Text = "Lv. " .. tostring(lvl)

        local band = getTargetBand(lvl)
        local targetMobId = band.id
        TargetVal.Text = band.title or targetMobId

        if not isRunning then
            continue
        end

        if not char:FindFirstChild("Fists") then
            local fists = LocalPlayer.Backpack:FindFirstChild("Fists")
            if fists then
                hum:EquipTool(fists)
                task.wait(0.1)
            end
        end

        if not currentTarget or not currentTarget.Parent or not currentTarget:FindFirstChild("HumanoidRootPart") or (currentTarget:FindFirstChildOfClass("Humanoid") and currentTarget:FindFirstChildOfClass("Humanoid").Health <= 0) then
            local mob, dist = findNearestTargetMob(targetMobId)
            if mob then
                currentTarget = mob
            else
                local spawnPos = getSpawnPosition(targetMobId)
                if spawnPos then
                    travelToGroundPosition(spawnPos, 25)
                else
                    StatusVal.Text = "SEARCHING SPAWN..."
                    StatusVal.TextColor3 = Color3.fromRGB(255, 200, 0)
                end
                task.wait(0.5)
                continue
            end
        end

        local tHrp = currentTarget:FindFirstChild("HumanoidRootPart")
        local tHum = currentTarget:FindFirstChildOfClass("Humanoid")

        if not tHrp or not tHum or tHum.Health <= 0 then
            currentTarget = nil
            continue
        end

        tHrp.CanQuery = true
        tHrp.CanTouch = true

        HealthVal.Text = math.floor(tHum.Health) .. " / " .. math.floor(tHum.MaxHealth)
        local dist = (hrp.Position - tHrp.Position).Magnitude

        if dist > 14 and not isTraveling then
            travelToGroundPosition(tHrp.Position, 8)
            continue
        end

        if isTraveling then
            continue
        end

        -- Stand 2.8 studs behind the mob at ground level
        StatusVal.Text = "FARMING: " .. targetMobId
        StatusVal.TextColor3 = Color3.fromRGB(0, 255, 180)

        local groundY = tHrp.Position.Y
        local behindPos = tHrp.Position - tHrp.CFrame.LookVector * 2.8
        behindPos = Vector3.new(behindPos.X, groundY, behindPos.Z)

        hrp.CFrame = CFrame.new(behindPos, tHrp.Position)
        hrp.AssemblyLinearVelocity = Vector3.zero

        local now = os.clock()
        if now - lastAttack >= 0.34 then
            lastAttack = now
            pcall(function()
                CombatConfig.platformFire("FistAttack", Enum.UserInputState.Begin)
                task.wait(0.04)
                CombatConfig.platformFire("FistAttack", Enum.UserInputState.End)
            end)
        end
    end
end)
