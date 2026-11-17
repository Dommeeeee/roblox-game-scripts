-- Phantom Forces aim kit: body-first targeting with visible-part priority (no head),
-- ESP + FOV ring rendered as Roblox GUI so placement is DPI- and executor-independent,
-- and an optional trigger-time mouse assist.
-- Camera is never written directly; assist moves the real mouse only while firing.
-- PF v3231 runs its client framework inside Actor VMs, so remote/module hooks
-- from the main VM cannot reach the bullet pipeline.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Camera = workspace.CurrentCamera
local LP = Players.LocalPlayer

local S = (typeof(STATE) == "table" and STATE) or {
    onCleanup = function() end,
    connect = function(_, sig, fn) return sig:Connect(fn) end,
    alive = function() return true end,
}

if getgenv().pfAimCleanup then pcall(getgenv().pfAimCleanup) end

local Settings = {
    Enabled = true,
    Assist = false,
    AssistGain = 1.4,
    AssistMaxStep = 140,
    ESP = true,
    FOVCircle = true,
    FOVRadius = 200,
    MaxDistance = 700,
    MaxESP = 1500,
    TeamCheck = true,
    Lead = true,
    BulletSpeed = 900,
    LeadCap = 0.45,
}

local Status = {
    enabled = Settings.Enabled,
    assist = Settings.Assist,
    esp = Settings.ESP,
    fov = Settings.FOVCircle,
    enemies = 0,
    players = 0,
    lockedModel = nil,
    lockedPart = nil,
    lockedKind = nil,
    assistFrames = 0,
    view = "0,0",
    cTotal = 0,
    cVis = 0,
    cFov = 0,
    error = nil,
}
getgenv().PFAimStatus = Status

local connections = {}
local function connect(sig, fn)
    local ok, conn = pcall(S.connect, S, sig, fn)
    if not ok or not conn then conn = sig:Connect(fn) end
    table.insert(connections, conn)
    return conn
end

local playerGui = LP:FindFirstChildOfClass("PlayerGui")

local function screenSize()
    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize
    if vp and vp.X > 1 and vp.Y > 1 then return vp end
    local hud = playerGui and playerGui:FindFirstChild("HudScreenGui")
    if hud and hud.AbsoluteSize.X > 1 then return hud.AbsoluteSize end
    return Vector2.new(1920, 1080)
end

local chars = {}
local selfModel = nil
local lastRefresh = 0
local raycastParamsCache = nil

local function buildRaycastParams()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local filter = {}
    local cam = workspace.CurrentCamera
    if cam then table.insert(filter, cam) end
    local ignore = workspace:FindFirstChild("Ignore")
    if ignore then table.insert(filter, ignore) end
    if selfModel then table.insert(filter, selfModel) end
    if LP.Character then table.insert(filter, LP.Character) end
    params.FilterDescendantsInstances = filter
    raycastParamsCache = params
    return params
end

local function volumeOf(part)
    local s = part.Size
    return math.max(s.X * s.Y * s.Z, 0.001)
end

local function findTagModel(folder)
    local found = {}
    for _, d in ipairs(folder:GetDescendants()) do
        if d:IsA("TextLabel") and d.Name == "PlayerTag" then
            local headPart = d.Parent and d.Parent.Parent
            local model = headPart and headPart.Parent
            if model and headPart:IsA("BasePart") and not found[model] then
                found[model] = { model = model, head = headPart, tag = d }
            end
        end
    end
    return found
end

local function classify(ch)
    local model, head = ch.model, ch.head
    local folder = nil
    for _, c in ipairs(model:GetChildren()) do
        if c:IsA("Folder") then folder = c break end
    end

    local bodyParts = {}
    if folder then
        for _, c in ipairs(folder:GetChildren()) do
            if c:IsA("BasePart") and volumeOf(c) > 0.02 then
                table.insert(bodyParts, c)
            end
        end
    end
    if #bodyParts == 0 then
        for _, c in ipairs(model:GetChildren()) do
            if c:IsA("BasePart") and c ~= head then
                table.insert(bodyParts, c)
            end
        end
    end

    local headPos = head.Position
    local torso, limbs = {}, {}
    local cand = {}
    for _, p in ipairs(bodyParts) do
        local offset = p.Position - headPos
        local horiz = Vector2.new(offset.X, offset.Z).Magnitude
        if offset.Magnitude >= 0.75 then
            table.insert(cand, { part = p, vol = volumeOf(p), horiz = horiz })
        end
    end
    table.sort(cand, function(a, b) return a.vol > b.vol end)
    for i, c in ipairs(cand) do
        if i <= 2 and c.horiz < 1.4 then
            table.insert(torso, c)
        else
            table.insert(limbs, c)
        end
    end

    local parts = {}
    for _, c in ipairs(torso) do
        table.insert(parts, { part = c.part, kind = "torso", vol = c.vol })
    end
    for _, c in ipairs(limbs) do
        table.insert(parts, { part = c.part, kind = "limb", vol = c.vol })
    end
    ch.parts = parts
    ch.allParts = bodyParts
end

local function refreshCharacters()
    local now = os.clock()
    if now - lastRefresh < 0.25 then return end
    lastRefresh = now

    local folder = workspace:FindFirstChild("Players")
    chars = {}
    selfModel = nil
    if not folder then return end

    local found = findTagModel(folder)
    for model, entry in pairs(found) do
        local tag = entry.tag
        local tagText = tag.Text
        local isSelf = (LP.Character and model == LP.Character)
            or (tagText == LP.Name or tagText == LP.DisplayName)
        local c = tag.TextColor3
        local enemy = c.R > c.G

        if isSelf then
            selfModel = model
        elseif enemy or not Settings.TeamCheck then
            local ch = {
                model = model,
                head = entry.head,
                tagText = tagText,
                enemy = enemy,
                dead = false,
                parts = {},
            }
            local hum = model:FindFirstChildOfClass("Humanoid")
            ch.hum = hum
            if hum and hum.Health <= 0 then ch.dead = true end
            pcall(classify, ch)
            if #ch.parts > 0 then
                table.insert(chars, ch)
            end
        end
    end
    buildRaycastParams()
end

local function project(pos)
    local cam = workspace.CurrentCamera
    if not cam then return nil end
    local sp, on = cam:WorldToViewportPoint(pos)
    if not on or sp.Z <= 0 then return nil end
    return Vector2.new(sp.X, sp.Y)
end

local function screenCenter()
    local vp = screenSize()
    return Vector2.new(vp.X / 2, vp.Y / 2)
end

local function fovRadiusPx()
    local vp = screenSize()
    local base = vp.Y / 1080
    if base <= 0 then base = 1 end
    return Settings.FOVRadius * base
end

local function samplePoints(part)
    local cf = part.CFrame
    local size = part.Size
    local pts = { cf.Position }
    if size.X > 0.4 then
        table.insert(pts, cf.Position + cf.RightVector * (size.X * 0.3))
        table.insert(pts, cf.Position - cf.RightVector * (size.X * 0.3))
    end
    if size.Y > 0.4 then
        table.insert(pts, cf.Position + cf.UpVector * (size.Y * 0.3))
        table.insert(pts, cf.Position - cf.UpVector * (size.Y * 0.3))
    end
    return pts
end

local function pointVisible(camPos, pt, dist, params)
    local dir = pt - camPos
    if dir.Magnitude < 2 then return true end
    local result = workspace:Raycast(camPos, dir, params)
    if not result then return true end
    return (result.Position - camPos).Magnitude >= dist - 0.25
end

local function visiblePoint(ch)
    local cam = workspace.CurrentCamera
    if not cam then return nil end
    local params = raycastParamsCache or buildRaycastParams()
    local camPos = cam.CFrame.Position

    for _, entry in ipairs(ch.parts) do
        local part = entry.part
        if part and part.Parent then
            for _, pt in ipairs(samplePoints(part)) do
                local dist = (pt - camPos).Magnitude
                if dist <= Settings.MaxDistance and pointVisible(camPos, pt, dist, params) then
                    return {
                        point = pt,
                        part = part,
                        kind = entry.kind,
                        model = ch.model,
                    }
                end
            end
        end
    end
    return nil
end

local lastResolve = 0
local cachedTarget = nil
local function resolveTarget(force)
    local now = os.clock()
    if not force and cachedTarget and (now - lastResolve) < 0.05
        and cachedTarget.model and cachedTarget.model.Parent then
        return cachedTarget
    end
    lastResolve = now
    cachedTarget = nil

    local center = screenCenter()
    local camPos = Camera.CFrame.Position
    local fovPx = fovRadiusPx()

    local candidates = {}
    for _, ch in ipairs(chars) do
        if ch.enemy and not ch.dead and ch.model.Parent and #ch.parts > 0 then
            local sum, n = Vector3.zero, 0
            for _, entry in ipairs(ch.parts) do
                if entry.part and entry.part.Parent then
                    sum = sum + entry.part.Position
                    n = n + 1
                end
            end
            if n > 0 then
                local pos = sum / n
                local dist = (pos - camPos).Magnitude
                if dist <= Settings.MaxDistance then
                    local sp = project(pos)
                    if sp then
                        table.insert(candidates, { ch = ch, d = (sp - center).Magnitude })
                    end
                end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.d < b.d end)

    Status.cTotal = #candidates
    Status.cVis = 0
    Status.cFov = 0

    local best, bestScore = nil, nil
    local scanned = 0
    for i = 1, #candidates do
        if scanned >= 12 then break end
        scanned = scanned + 1
        local ch = candidates[i].ch
        local hit = visiblePoint(ch)
        if hit then
            Status.cVis = Status.cVis + 1
            local sp = project(hit.point)
            if sp then
                local d = (sp - center).Magnitude
                if d <= fovPx then
                    Status.cFov = Status.cFov + 1
                    local penalty = hit.kind == "torso" and 0 or 20
                    local score = d + penalty
                    if not bestScore or score < bestScore then
                        best, bestScore = hit, score
                    end
                end
            end
        end
    end

    if best then
        cachedTarget = best
        Status.lockedModel = best.model.Name
        Status.lockedPart = best.part.Name
        Status.lockedKind = best.kind
    else
        Status.lockedModel = nil
        Status.lockedPart = nil
        Status.lockedKind = nil
    end
    return best
end

local function assistPoint(itarget)
    local aim = itarget.point
    if Settings.Lead then
        local part = itarget.part
        local vel = part.AssemblyLinearVelocity or part.Velocity
        if vel and vel.Magnitude > 2 then
            local cpos = Camera.CFrame.Position
            local dist = (aim - cpos).Magnitude
            local t = math.min(dist / math.max(Settings.BulletSpeed, 1), Settings.LeadCap)
            aim = aim + vel * t
        end
    end
    return aim
end

local gui = nil
local ring = nil
local ringStroke = nil
local hudLine = nil
local hudLock = nil
local esp = {}

local function ensureGui()
    if gui and gui.Parent then return end
    if not playerGui then return end
    gui = Instance.new("ScreenGui")
    gui.Name = "pfAimOverlay"
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 100
    gui.ResetOnSpawn = false
    gui.Parent = playerGui

    ring = Instance.new("Frame")
    ring.Name = "fovRing"
    ring.AnchorPoint = Vector2.new(0.5, 0.5)
    ring.Position = UDim2.fromScale(0.5, 0.5)
    ring.BackgroundTransparency = 1
    ring.BorderSizePixel = 0
    ring.Size = UDim2.fromOffset(320, 320)
    ring.Parent = gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.5, 0)
    corner.Parent = ring
    ringStroke = Instance.new("UIStroke")
    ringStroke.Thickness = 1
    ringStroke.Transparency = 0.5
    ringStroke.Color = Color3.fromRGB(235, 235, 235)
    ringStroke.Parent = ring

    hudLine = Instance.new("TextLabel")
    hudLine.BackgroundTransparency = 1
    hudLine.Position = UDim2.fromOffset(18, 14)
    hudLine.Size = UDim2.fromOffset(760, 18)
    hudLine.Font = Enum.Font.SourceSansSemibold
    hudLine.TextSize = 15
    hudLine.TextXAlignment = Enum.TextXAlignment.Left
    hudLine.TextColor3 = Color3.fromRGB(220, 220, 220)
    hudLine.TextStrokeTransparency = 0.3
    hudLine.Text = "pf aim"
    hudLine.Parent = gui

    hudLock = Instance.new("TextLabel")
    hudLock.BackgroundTransparency = 1
    hudLock.Position = UDim2.fromOffset(18, 34)
    hudLock.Size = UDim2.fromOffset(760, 18)
    hudLock.Font = Enum.Font.SourceSansSemibold
    hudLock.TextSize = 14
    hudLock.TextXAlignment = Enum.TextXAlignment.Left
    hudLock.TextColor3 = Color3.fromRGB(255, 210, 60)
    hudLock.TextStrokeTransparency = 0.3
    hudLock.Text = ""
    hudLock.Parent = gui
end

local function espEntry(model)
    local e = esp[model]
    if e and e.box and e.box.Parent then return e end
    ensureGui()
    if not gui then return nil end
    e = {
        box = Instance.new("Frame"),
        name = Instance.new("TextLabel"),
        hp = Instance.new("Frame"),
    }
    e.box.Name = "espBox"
    e.box.BackgroundTransparency = 1
    e.box.BorderSizePixel = 0
    e.box.Parent = gui
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Color = Color3.fromRGB(255, 70, 70)
    stroke.Parent = e.box
    e.boxStroke = stroke

    e.name.Name = "espName"
    e.name.BackgroundTransparency = 1
    e.name.AnchorPoint = Vector2.new(0.5, 1)
    e.name.Font = Enum.Font.SourceSansSemibold
    e.name.TextSize = 13
    e.name.TextColor3 = Color3.fromRGB(255, 70, 70)
    e.name.TextStrokeTransparency = 0.2
    e.name.Parent = gui

    e.hp.Name = "espHp"
    e.hp.BackgroundColor3 = Color3.fromRGB(60, 255, 60)
    e.hp.BorderSizePixel = 0
    e.hp.Parent = gui

    esp[model] = e
    return e
end

local function destroyEsp(model)
    local e = esp[model]
    if not e then return end
    for _, d in pairs(e) do
        if typeof(d) == "Instance" then
            pcall(function() d:Destroy() end)
        end
    end
    esp[model] = nil
end

local function renderOverlay()
    ensureGui()
    if not gui then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    local center = screenCenter()
    local fovPx = fovRadiusPx()
    Status.view = tostring(screenSize())

    if ring then
        ring.Visible = Settings.FOVCircle
        if Settings.FOVCircle then
            ring.Position = UDim2.fromScale(0.5, 0.5)
            ring.Size = UDim2.fromOffset(fovPx * 2, fovPx * 2)
            ringStroke.Color = cachedTarget and Color3.fromRGB(90, 255, 120) or Color3.fromRGB(235, 235, 235)
        end
    end

    local seen = {}
    if Settings.ESP then
        for _, ch in ipairs(chars) do
            if ch.model.Parent and #ch.parts > 0 and not ch.dead then
                seen[ch.model] = true
                local e = espEntry(ch.model)
                if e then
                    local camPos = cam.CFrame.Position
                    local minY, maxY = math.huge, -math.huge
                    local sum = Vector3.zero
                    local n = 0
                    for _, p in ipairs(ch.allParts or {}) do
                        if p and p.Parent then
                            minY = math.min(minY, p.Position.Y - p.Size.Y / 2)
                            maxY = math.max(maxY, p.Position.Y + p.Size.Y / 2)
                            sum = sum + p.Position
                            n = n + 1
                        end
                    end
                    if n > 0 then
                        local centroid = sum / n
                        local pTop = project(Vector3.new(centroid.X, maxY + 0.35, centroid.Z))
                        local pBot = project(Vector3.new(centroid.X, minY, centroid.Z))
                        local dist = (centroid - camPos).Magnitude
                        local show = pTop and pBot and dist <= Settings.MaxESP
                        if show then
                            local h = math.abs(pBot.Y - pTop.Y)
                            if h < 8 then h = 8 end
                            local w = h * 0.5
                            local x = pTop.X - w / 2
                            e.box.Visible = true
                            e.box.Position = UDim2.fromOffset(x, pTop.Y)
                            e.box.Size = UDim2.fromOffset(w, h)

                            e.name.Visible = true
                            e.name.Text = string.format("%s [%d]", ch.tagText or ch.model.Name, math.floor(dist))
                            e.name.Position = UDim2.fromOffset(pTop.X, pTop.Y - 2)

                            if ch.hum and ch.hum.MaxHealth > 0 then
                                local frac = math.clamp(ch.hum.Health / ch.hum.MaxHealth, 0, 1)
                                e.hp.Visible = true
                                e.hp.BackgroundColor3 = Color3.fromRGB(math.floor(255 * (1 - frac)), math.floor(255 * frac), 60)
                                e.hp.Position = UDim2.fromOffset(x + 2, pTop.Y + h + 3)
                                e.hp.Size = UDim2.fromOffset((w - 4) * frac, 2)
                            else
                                e.hp.Visible = false
                            end
                        else
                            e.box.Visible = false
                            e.name.Visible = false
                            e.hp.Visible = false
                        end
                    end
                end
            end
        end
    end
    for model, e in pairs(esp) do
        if not seen[model] then
            if e.box then e.box.Visible = false end
            if e.name then e.name.Visible = false end
            if e.hp then e.hp.Visible = false end
            if not model.Parent then
                destroyEsp(model)
            end
        end
    end

    if hudLine then
        hudLine.Text = string.format("pf aim %s | esp %s | assist %s (F5) | fov %dpx (F7/F8) | view %s",
            Settings.Enabled and "on" or "off",
            Settings.ESP and "on" or "off",
            Settings.Assist and "on" or "off",
            math.floor(fovPx),
            Status.view)
    end
    if hudLock then
        local counts = string.format("tgt %d | vis %d | fov %d", Status.cTotal, Status.cVis, Status.cFov)
        if cachedTarget then
            hudLock.Text = string.format("lock: %s : %s | %s", tostring(Status.lockedModel), tostring(Status.lockedKind), counts)
        else
            hudLock.Text = "no lock | " .. counts
        end
    end
end

local firing = false
connect(UIS.InputBegan, function(input, gp)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then firing = true end
    if gp then return end
    local key = input.KeyCode
    if key == Enum.KeyCode.F1 then
        Settings.Enabled = not Settings.Enabled
        Status.enabled = Settings.Enabled
    elseif key == Enum.KeyCode.F2 then
        Settings.ESP = not Settings.ESP
        Status.esp = Settings.ESP
    elseif key == Enum.KeyCode.F3 then
        Settings.FOVCircle = not Settings.FOVCircle
        Status.fov = Settings.FOVCircle
    elseif key == Enum.KeyCode.F5 then
        Settings.Assist = not Settings.Assist
        Status.assist = Settings.Assist
    elseif key == Enum.KeyCode.F7 then
        Settings.FOVRadius = math.clamp(Settings.FOVRadius + 20, 40, 600)
    elseif key == Enum.KeyCode.F8 then
        Settings.FOVRadius = math.clamp(Settings.FOVRadius - 20, 40, 600)
    end
end)
connect(UIS.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then firing = false end
end)

local function assistStep()
    if not (Settings.Enabled and Settings.Assist and firing) then return end
    local target = resolveTarget(false)
    if not target then return end
    local sp = project(assistPoint(target))
    if not sp then return end
    local center = screenCenter()
    local dx = sp.X - center.X
    local dy = sp.Y - center.Y
    if math.abs(dx) + math.abs(dy) < 1.5 then return end
    local gain = Settings.AssistGain
    local stepX = math.clamp(dx * gain, -Settings.AssistMaxStep, Settings.AssistMaxStep)
    local stepY = math.clamp(dy * gain, -Settings.AssistMaxStep, Settings.AssistMaxStep)
    pcall(mousemoverel, stepX, stepY)
    Status.assistFrames = Status.assistFrames + 1
end

connect(RunService.RenderStepped, function()
    pcall(renderOverlay)
    pcall(assistStep)
end)

local function stillAlive()
    if type(S.alive) ~= "function" then return true end
    local ok, v = pcall(S.alive)
    if not ok then return true end
    return v ~= false
end

task.spawn(function()
    while stillAlive() do
        local ok, err = pcall(refreshCharacters)
        if not ok then Status.error = tostring(err) end
        pcall(function()
            Status.players = #chars
            Status.enemies = #chars
        end)
        pcall(resolveTarget, false)
        task.wait(0.2)
    end
end)

getgenv().PFAim = {
    Settings = Settings,
    Status = Status,
    Resolve = resolveTarget,
    Characters = function() return chars end,
}

local function cleanup()
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}
    for model in pairs(esp) do
        destroyEsp(model)
    end
    esp = {}
    if gui then
        pcall(function() gui:Destroy() end)
        gui = nil
    end
    getgenv().pfAimCleanup = nil
    getgenv().PFAimStatus = nil
end

getgenv().pfAimCleanup = cleanup
S.onCleanup(cleanup)
