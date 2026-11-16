-- MM2 Master Suite with GUI and Kill Aura
if getgenv().MM2_MASTER_CLEANUP then
    getgenv().MM2_MASTER_CLEANUP()
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local localPlayer = Players.LocalPlayer

-- Master Settings
local Settings = {
    ESP = true,
    SilentAim = true,
    AutoGrabGun = true,
    KillAura = true,
    AuraDistance = 14
}

-- Cleanup Registry
local Cleanups = {}

-- [[ 1. GUI MODULE ]]
local function getGuiParent()
    local success, parent = pcall(function()
        return (gethui and gethui()) or CoreGui
    end)
    if success and parent then return parent end
    return localPlayer:WaitForChild("PlayerGui")
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MM2_Master_GUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = getGuiParent()

local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 240, 0, 290)
mainFrame.Position = UDim2.new(0.02, 0, 0.35, 0)
mainFrame.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.Draggable = true
mainFrame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = mainFrame

local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(32, 32, 38)
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 10)
titleCorner.Parent = titleBar

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 1, 0)
title.Position = UDim2.new(0, 12, 0, 0)
title.BackgroundTransparency = 1
title.Text = "VANTA // MM2 SUITE"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 13
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar

local container = Instance.new("UIListLayout")
container.Parent = mainFrame
container.SortOrder = Enum.SortOrder.LayoutOrder
container.Padding = UDim.new(0, 6)

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 44)
pad.PaddingLeft = UDim.new(0, 10)
pad.PaddingRight = UDim.new(0, 10)
pad.PaddingBottom = UDim.new(0, 10)
pad.Parent = mainFrame

local function createToggle(name, default, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 36)
    btn.BackgroundColor3 = default and Color3.fromRGB(40, 95, 55) or Color3.fromRGB(38, 38, 44)
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamMedium
    btn.TextSize = 12
    btn.TextColor3 = Color3.fromRGB(240, 240, 240)
    btn.Text = (default and "[ON]  " or "[OFF] ") .. name
    btn.Parent = mainFrame

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 6)
    btnCorner.Parent = btn

    local state = default
    btn.MouseButton1Click:Connect(function()
        state = not state
        btn.BackgroundColor3 = state and Color3.fromRGB(40, 95, 55) or Color3.fromRGB(38, 38, 44)
        btn.Text = (state and "[ON]  " or "[OFF] ") .. name
        callback(state)
    end)
end

createToggle("Player & Gun ESP", Settings.ESP, function(v) Settings.ESP = v end)
createToggle("Silent Aim & Throw", Settings.SilentAim, function(v) Settings.SilentAim = v end)
createToggle("Auto Grab Dropped Gun", Settings.AutoGrabGun, function(v) Settings.AutoGrabGun = v end)
createToggle("Knife Kill Aura", Settings.KillAura, function(v) Settings.KillAura = v end)

-- Status label at bottom
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 24)
status.BackgroundTransparency = 1
status.Text = "Status: Armed & Operational"
status.TextColor3 = Color3.fromRGB(150, 150, 160)
status.TextSize = 10
status.Font = Enum.Font.Gotham
status.Parent = mainFrame

-- [[ 2. SHARED HELPERS ]]
local function checkTools(player, keyword)
    if not player then return false end
    local function check(cont)
        if not cont then return false end
        for _, item in ipairs(cont:GetChildren()) do
            if item:IsA("Tool") and item.Name:lower():find(keyword) then
                return true
            end
        end
        return false
    end
    return check(player.Character) or check(player:FindFirstChild("Backpack"))
end

local function getMurderer()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and p.Character then
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 and checkTools(p, "knife") then
                return p
            end
        end
    end
    return nil
end

local function getSheriff()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and p.Character then
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 and (checkTools(p, "gun") or checkTools(p, "revolver")) then
                return p
            end
        end
    end
    return nil
end

local function getNearestInnocent()
    local myChar = localPlayer.Character
    if not myChar then return nil end
    local myHrp = myChar:FindFirstChild("HumanoidRootPart")
    if not myHrp then return nil end

    local nearest = nil
    local minDist = math.huge

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and p.Character then
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            local hrp = p.Character:FindFirstChild("HumanoidRootPart")
            if hum and hum.Health > 0 and hrp and not checkTools(p, "knife") then
                local dist = (hrp.Position - myHrp.Position).Magnitude
                if dist < minDist then
                    minDist = dist
                    nearest = p
                end
            end
        end
    end
    return nearest
end

-- [[ 3. ESP SUBSYSTEM ]]
local highlights = {}
local colors = {
    Murderer = Color3.fromRGB(255, 35, 35),
    Sheriff = Color3.fromRGB(35, 120, 255),
    Innocent = Color3.fromRGB(60, 220, 80),
    GunDrop = Color3.fromRGB(255, 230, 20)
}

local function applyHighlight(target, color)
    if not target or not target.Parent then return end
    local hl = highlights[target]
    if not hl or not hl.Parent then
        hl = Instance.new("Highlight")
        hl.FillTransparency = 0.5
        hl.OutlineTransparency = 0.1
        hl.Adornee = target
        hl.Parent = target
        highlights[target] = hl
    end
    hl.FillColor = color
    hl.OutlineColor = color
end

local function clearHighlights()
    for target, hl in pairs(highlights) do
        if hl and hl.Parent then hl:Destroy() end
    end
    highlights = {}
end

-- [[ 4. WEAPONSERVICE HOOK ]]
local WeaponService = require(ReplicatedStorage:WaitForChild("ClientServices"):WaitForChild("WeaponService"))
local oldGetMouseTargetCFrame = WeaponService.GetMouseTargetCFrame
local oldGetTargetPosition = WeaponService.GetTargetPosition

local function getBestTarget()
    if not Settings.SilentAim then return nil end
    if checkTools(localPlayer, "knife") then
        local sher = getSheriff()
        if sher and sher.Character then return sher end
        return getNearestInnocent()
    end
    if checkTools(localPlayer, "gun") or checkTools(localPlayer, "revolver") then
        return getMurderer()
    end
    return nil
end

WeaponService.GetMouseTargetCFrame = function(...)
    local target = getBestTarget()
    if target and target.Character then
        local part = target.Character:FindFirstChild("HumanoidRootPart") or target.Character:FindFirstChild("Head")
        if part then return CFrame.new(part.Position) end
    end
    return oldGetMouseTargetCFrame(...)
end

WeaponService.GetTargetPosition = function(...)
    local target = getBestTarget()
    if target and target.Character then
        local part = target.Character:FindFirstChild("HumanoidRootPart") or target.Character:FindFirstChild("Head")
        if part then return CFrame.new(part.Position) end
    end
    return oldGetTargetPosition(...)
end

-- [[ 5. AUTO-GRAB GUN SUBSYSTEM ]]
local function grabGun(gun)
    if not Settings.AutoGrabGun then return end
    if checkTools(localPlayer, "knife") or checkTools(localPlayer, "gun") then return end

    local char = localPlayer.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then return end

    local targetPart = gun:IsA("BasePart") and gun or gun:FindFirstChildWhichIsA("BasePart")
    if targetPart then
        local oldCFrame = hrp.CFrame
        if typeof(firetouchinterest) == "function" then
            firetouchinterest(hrp, targetPart, 0)
            task.wait(0.05)
            firetouchinterest(hrp, targetPart, 1)
        else
            hrp.CFrame = targetPart.CFrame
            task.wait(0.05)
            hrp.CFrame = oldCFrame
        end
    end
end

-- [[ 6. KILL AURA SUBSYSTEM ]]
local lastSlashTime = 0
local function runKillAura()
    if not Settings.KillAura then return end
    local char = localPlayer.Character
    if not char then return end
    local knife = char:FindFirstChild("Knife")
    if not knife then return end -- Only aura if holding knife
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then return end

    local events = knife:FindFirstChild("Events")
    local handle = knife:FindFirstChild("Handle")
    if not events or not handle then return end

    -- Check players in range
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and p.Character then
            local pHum = p.Character:FindFirstChildOfClass("Humanoid")
            local pHrp = p.Character:FindFirstChild("HumanoidRootPart")
            if pHum and pHum.Health > 0 and pHrp then
                local dist = (pHrp.Position - hrp.Position).Magnitude
                if dist <= Settings.AuraDistance then
                    -- Attack
                    if os.clock() - lastSlashTime > 0.85 then
                        lastSlashTime = os.clock()
                        events.KnifeStabbed:FireServer()
                    end
                    -- Touch interest on enemy root/head
                    events.HandleTouched:FireServer(pHrp)
                    if typeof(firetouchinterest) == "function" then
                        firetouchinterest(handle, pHrp, 0)
                        task.wait(0.02)
                        firetouchinterest(handle, pHrp, 1)
                    end
                    break
                end
            end
        end
    end
end

-- [[ 7. MAIN ENGINE LOOP ]]
local isRunning = true
task.spawn(function()
    while isRunning do
        -- ESP Loop
        if Settings.ESP then
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= localPlayer and p.Character then
                    local hum = p.Character:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health > 0 then
                        local role = "Innocent"
                        if checkTools(p, "knife") then role = "Murderer"
                        elseif checkTools(p, "gun") or checkTools(p, "revolver") then role = "Sheriff" end
                        applyHighlight(p.Character, colors[role])
                    end
                end
            end
            local gunDrop = Workspace:FindFirstChild("GunDrop")
            if not gunDrop then
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj.Name == "GunDrop" then gunDrop = obj break end
                end
            end
            if gunDrop and gunDrop.Parent then
                applyHighlight(gunDrop, colors.GunDrop)
            end
        else
            clearHighlights()
        end

        -- Auto-Grab Gun Loop
        if Settings.AutoGrabGun and not checkTools(localPlayer, "gun") and not checkTools(localPlayer, "knife") then
            local gun = Workspace:FindFirstChild("GunDrop")
            if not gun then
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj.Name == "GunDrop" then gun = obj break end
                end
            end
            if gun and gun.Parent then
                grabGun(gun)
            end
        end

        -- Kill Aura Loop
        runKillAura()

        task.wait(0.2)
    end
end)

-- [[ 8. MASTER CLEANUP ]]
getgenv().MM2_MASTER_CLEANUP = function()
    isRunning = false
    clearHighlights()
    if screenGui and screenGui.Parent then
        screenGui:Destroy()
    end
    WeaponService.GetMouseTargetCFrame = oldGetMouseTargetCFrame
    WeaponService.GetTargetPosition = oldGetTargetPosition
    print("[MM2_MASTER] All systems and UI unloaded cleanly.")
end

print("[MM2_MASTER] Loaded successfully with Interactive GUI & Kill Aura.")
