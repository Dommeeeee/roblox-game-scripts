local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
local MC = PlayerScripts:WaitForChild("MC")
local Shared = ReplicatedStorage:WaitForChild("MC")

local Controller = require(MC.Controller)
local World = require(MC.World)
local Hands = require(MC.Hands)
local Physics = require(Shared.Physics)
local Remotes = Shared:WaitForChild("Remotes")
local Action = Remotes:WaitForChild("Action")

local Hooks = STATE or {}
local function connect(signal, fn)
    if Hooks.connect then return Hooks.connect(signal, fn) end
    return signal:Connect(fn)
end
local function onCleanup(fn)
    if Hooks.onCleanup then Hooks.onCleanup(fn) end
end
local function alive()
    if Hooks.alive then return Hooks.alive() end
    return true
end

local Settings = {
    Enabled = false,
    Range = 3.4,
    Blink = false,
    BlinkRange = 130,
    Fov = 180,
    Toggle = Enum.KeyCode.RightShift,
    BlinkToggle = Enum.KeyCode.RightAlt,
    PressMsMin = 70,
    PressMsMax = 170,
}

local BLOCK_NAMES = { "Solid" }
if getgenv().OJBS_Aura and getgenv().OJBS_Aura.Settings then
    getgenv().OJBS_Aura.Settings.Enabled = false
end
local stats = { attacks = 0, blinks = 0, rejects = 0, busy = false, seen = 0, phase = "idle" }
getgenv().OJBS_Aura = { Settings = Settings, Stats = stats }

local function pressMs()
    return math.random(Settings.PressMsMin, Settings.PressMsMax)
end

local function losClear(eye, dir, dist)
    local hit = World.blockRay(eye, dir, dist + 0.2, BLOCK_NAMES)
    return hit == nil or hit.dist >= dist - 0.05
end

local function myMode()
    return LocalPlayer:GetAttribute("Mode")
end

local function collect(range)
    local state = Controller.state
    if not state then return {} end
    local feet = state.pos
    local mode = myMode()
    local out = {}

    for _, model in World.models() do
        if model ~= LocalPlayer.Character
            and model:GetAttribute("Alive") ~= false
            and model:GetAttribute("Gamemode") ~= "spectator"
            and model:GetAttribute("Mode") == mode then
            local targetFeet = World.feet(model)
            if targetFeet then
                local dist = (targetFeet - feet).Magnitude
                if dist <= range then
                    out[#out + 1] = { model = model, feet = targetFeet, dist = dist }
                end
            end
        end
    end

    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

local function lookAtWorld(point, eye)
    local dir = point - eye
    if dir.Magnitude < 1e-5 then return nil end
    dir = dir.Unit
    local yaw = math.atan2(-dir.X, -dir.Z)
    local pitch = math.asin(math.clamp(dir.Y, -1, 1))
    return CFrame.fromEulerAnglesYXZ(pitch, yaw, 0).LookVector, dir
end

local function chestPoint(entry)
    return entry.feet + Vector3.new(0, World.height(entry.model) * 0.62, 0)
end

local function snapshot(look, predicted, pos)
    local state = Controller.state
    return {
        fall = state.fallDistance,
        ground = state.onGround,
        sprint = state.sprinting,
        water = state.inWater,
        gliding = state.gliding,
        vel = state.vel,
        look = look,
        swap = false,
        pos = pos or state.pos,
        predicted = predicted,
    }
end

local function weaponDef()
    local def = Hands.heldDef()
    if not def or not def.damage then return nil end
    if def.kind == "spear" or def.kind == "fist" then return nil end
    return def
end

local function strike(entry, mindex)
    local state = Controller.state
    local eye = state.pos + Vector3.new(0, Physics.eyeHeight(state), 0)
    local look, dir = lookAtWorld(chestPoint(entry), eye)
    if not look then return false end
    local predicted = losClear(eye, dir, entry.dist)
    local payload = {
        a = "attack",
        target = entry.model:GetAttribute("EntityId"),
        st = snapshot(look, predicted, mindex),
        pressMs = pressMs(),
        k = Controller.tickCount,
    }
    local ok = pcall(function()
        Action:FireServer(payload)
    end)
    if ok then
        stats.attacks = stats.attacks + 1
        stats.lastDist = entry.dist
        Hands.attackReset = Controller.tickCount
        return true
    end
    stats.rejects = stats.rejects + 1
    return false
end

local function pickLocal(entries)
    local baseLook = Controller.look()
    local halfFov = math.rad(Settings.Fov) * 0.5
    local state = Controller.state
    local eye = state.pos + Vector3.new(0, Physics.eyeHeight(state), 0)
    for _, entry in entries do
        local dir = chestPoint(entry) - eye
        if dir.Magnitude > 1e-5 then
            local angle = math.acos(math.clamp(baseLook:Dot(dir.Unit), -1, 1))
            if angle <= halfFov then
                return entry
            end
        end
    end
end

local lastHit = {}

local function pickBlink(entries)
    local now = os.clock()
    for _, entry in entries do
        local id = entry.model:GetAttribute("EntityId")
        local last = lastHit[id]
        if not last or now - last >= 1.05 then
            return entry
        end
    end
end

local function stepLocal()
    local entries = collect(Settings.Range)
    if #entries == 0 then return end
    local chosen = pickLocal(entries)
    if not chosen then return end
    strike(chosen)
end

local function stepBlink()
    local entries = collect(Settings.BlinkRange)
    stats.seen = #entries
    if #entries == 0 then stats.phase = "noent" return end
    local chosen = pickBlink(entries)
    if not chosen then stats.phase = "cool" return end
    stats.phase = "go"

    stats.busy = true
    task.spawn(function()
        local home = Controller.state.pos
        local id = chosen.model:GetAttribute("EntityId")
        local ok, err = pcall(function()
            local away = (home - chosen.feet)
            away = Vector3.new(away.X, 0, away.Z)
            if away.Magnitude < 1e-3 then away = Vector3.new(1, 0, 0) end
            away = away.Unit
            local land = chosen.feet + away * 1.2 + Vector3.new(0, 0.05, 0)

            for _ = 1, 2 do
                Controller.state.pos = land
                RunService.Heartbeat:Wait()
            end

            local entry = { model = chosen.model, feet = World.feet(chosen.model) or chosen.feet, dist = 1.2 }
            strike(entry, land)
            stats.blinks = stats.blinks + 1
            lastHit[id] = os.clock()

            for _ = 1, 2 do
                Controller.state.pos = home
                RunService.Heartbeat:Wait()
            end
        end)
        Controller.state.pos = home
        if not ok then
            stats.rejects = stats.rejects + 1
            stats.innerErr = tostring(err)
        end
        stats.busy = false
    end)
end

local function step()
    stats.phase = "enter"
    if not Settings.Enabled then stats.phase = "off" return end
    if LocalPlayer:GetAttribute("Gamemode") == "spectator" then stats.phase = "spec" return end
    if stats.busy then stats.phase = "busy" return end

    local state = Controller.state
    if not state or Hands.using then stats.phase = "hand" return end
    if not weaponDef() then stats.phase = "weapon" return end
    if Hands.strength(0) < 1 then stats.phase = "charge" return end

    if Settings.Blink then
        stats.phase = "blink"
        stepBlink()
    else
        stats.phase = "local"
        stepLocal()
    end
end

local gui = Instance.new("ScreenGui")
gui.Name = "OJBS_Aura"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.AnchorPoint = Vector2.new(0, 0)
label.Position = UDim2.new(0, 12, 0, 120)
label.Size = UDim2.fromOffset(220, 20)
label.BackgroundTransparency = 1
label.Font = Enum.Font.Code
label.TextSize = 14
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextColor3 = Color3.fromRGB(255, 85, 85)
label.Text = "AURA off"
label.Parent = gui

onCleanup(function()
    gui:Destroy()
    if getgenv().OJBS_Aura then
        getgenv().OJBS_Aura = nil
    end
end)

connect(UserInputService.InputBegan, function(input, processed)
    if processed then return end
    if input.KeyCode == Settings.Toggle then
        Settings.Enabled = not Settings.Enabled
        stats.attacks = 0
        stats.blinks = 0
        label.TextColor3 = Settings.Enabled and Color3.fromRGB(85, 255, 85) or Color3.fromRGB(255, 85, 85)
        print(("[OJBS] Killaura %s"):format(Settings.Enabled and "ON" or "OFF"))
    elseif input.KeyCode == Settings.BlinkToggle then
        Settings.Blink = not Settings.Blink
        print(("[OJBS] Blink %s"):format(Settings.Blink and "ON" or "OFF"))
    end
end)

connect(RunService.Heartbeat, function()
    if not alive() then return end
    local ok, err = pcall(step)
    if not ok then
        stats.lastError = tostring(err)
    end
    local mode = Settings.Blink and "BLINK" or "LOCAL"
    label.Text = Settings.Enabled
        and ("AURA %s  %d%s  d:%s"):format(
            mode,
            stats.attacks,
            Settings.Blink and ("/" .. stats.blinks) or "",
            stats.lastDist and ("%.1f"):format(stats.lastDist) or "-"
        )
        or "AURA off"
end)

print("[OJBS] Killaura loaded - RightShift aura, RightAlt blink mode")
