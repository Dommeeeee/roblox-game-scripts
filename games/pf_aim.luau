-- Phantom Forces silent aim: body-first targeting, visible-part priority,
-- Drawing ESP + FOV circle, newbullets direction rewrite on the wire.
-- Camera is read-only. No weapon CFrame writes, no Highlight, no character edits.
-- PF characters are non-queryable mesh hitboxes under workspace.Players, so
-- visibility is world-occlusion only; head mesh is identified by proximity to
-- the NameTagGui anchor and never targeted.

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
    SilentAim = true,
    ESP = true,
    FOVCircle = true,
    FOVRadius = 160,
    MaxDistance = 700,
    MaxESP = 1500,
    TeamCheck = true,
    Lead = true,
    BulletSpeed = 900,
    LeadCap = 0.45,
}

local Status = {
    enabled = Settings.Enabled,
    silent = Settings.SilentAim,
    esp = Settings.ESP,
    fov = Settings.FOVCircle,
    hook = false,
    enemies = 0,
    players = 0,
    lockedModel = nil,
    lockedPart = nil,
    lockedKind = nil,
    shots = 0,
    rewrites = 0,
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

local drawings = {}
local function newDrawing(cls)
    if typeof(Drawing) ~= "table" and typeof(Drawing) ~= "userdata" then return nil end
    local ok, d = pcall(Drawing.new, cls)
    if not ok or not d then return nil end
    table.insert(drawings, d)
    return d
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
            table.insert(cand, { part = p, vol = volumeOf(p), horiz = horiz, dy = -offset.Y })
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
    ch.torsoParts = torso
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
        local enemy = true
        local c = tag.TextColor3
        enemy = c.R > c.G

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

    local cam = workspace.CurrentCamera
    local vp = cam and cam.ViewportSize or nil
    if not cam or not vp or vp.X <= 0 or vp.Y <= 0 then return nil end
    local center = Vector2.new(vp.X / 2, vp.Y / 2)
    local camPos = cam.CFrame.Position

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

    local best, bestScore = nil, nil
    for i = 1, math.min(#candidates, 4) do
        local ch = candidates[i].ch
        local hit = visiblePoint(ch)
        if hit then
            local sp = project(hit.point)
            if sp then
                local d = (sp - center).Magnitude
                if d <= Settings.FOVRadius then
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

local function applyTarget(itarget, packet)
    if not itarget then return 0 end
    local origin = nil
    if typeof(packet.firepos) == "Vector3" then origin = packet.firepos
    elseif typeof(packet.camerapos) == "Vector3" then origin = packet.camerapos
    else origin = Camera.CFrame.Position end

    local aim = itarget.point
    if Settings.Lead then
        local part = itarget.part
        local vel = part.AssemblyLinearVelocity or part.Velocity
        if vel and vel.Magnitude > 2 then
            local dist = (aim - origin).Magnitude
            local t = math.min(dist / math.max(Settings.BulletSpeed, 1), Settings.LeadCap)
            aim = aim + vel * t
        end
    end

    local dir = aim - origin
    if dir.Magnitude < 0.5 then return 0 end
    dir = dir.Unit

    local count = 0
    local bullets = packet.bullets
    if type(bullets) ~= "table" then return 0 end
    for i = 1, #bullets do
        local entry = bullets[i]
        if type(entry) == "table" then
            if type(entry[1]) == "Vector3" then
                entry[1] = dir
                count = count + 1
            elseif type(entry.lookVector) == "Vector3" then
                entry.lookVector = dir
                count = count + 1
            end
        end
    end
    return count
end

local function handleRemote(self, ...)
    if not (Settings.Enabled and Settings.SilentAim) then return end
    local char = LP.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return end

    local args = table.pack(...)
    local slot
    for i = 1, args.n do
        if args[i] == "newbullets" then slot = i break end
    end
    if not slot then return end

    local packet
    for i = slot + 1, math.min(slot + 3, args.n) do
        local v = args[i]
        if type(v) == "table" and type(v.bullets) == "table" then packet = v break end
    end
    if not packet then return end

    local target = resolveTarget(true)
    if not target then return end
    local n = applyTarget(target, packet)
    if n > 0 then
        Status.shots = Status.shots + 1
        Status.rewrites = Status.rewrites + n
    end
end

local oldNamecall, ourNamecall
local function installHook()
    local ok, mt = pcall(getrawmetatable, game)
    if not ok or not mt then return false end
    pcall(setreadonly, mt, false)
    oldNamecall = mt.__namecall
    if type(oldNamecall) ~= "function" then pcall(setreadonly, mt, true) return false end
    ourNamecall = newcclosure(function(self, ...)
        if getnamecallmethod() == "FireServer" then
            pcall(handleRemote, self, ...)
        end
        return oldNamecall(self, ...)
    end)
    mt.__namecall = ourNamecall
    pcall(setreadonly, mt, true)
    return true
end

local esp = {}
local fovCircle = newDrawing("Circle")
if fovCircle then
    fovCircle.Thickness = 1
    fovCircle.Transparency = 0.5
    fovCircle.Color = Color3.fromRGB(235, 235, 235)
    fovCircle.NumSides = 48
    fovCircle.Visible = Settings.FOVCircle
end
local hudLine = newDrawing("Text")
if hudLine then
    hudLine.Size = 15
    hudLine.Color = Color3.fromRGB(220, 220, 220)
    hudLine.Font = 2
    hudLine.Position = Vector2.new(18, 18)
    hudLine.Text = "pf aim"
    hudLine.Outline = true
    hudLine.OutlineColor = Color3.new(0, 0, 0)
end
local hudLock = newDrawing("Text")
if hudLock then
    hudLock.Size = 14
    hudLock.Color = Color3.fromRGB(255, 210, 60)
    hudLock.Font = 2
    hudLock.Position = Vector2.new(18, 38)
    hudLock.Text = ""
    hudLock.Outline = true
    hudLock.OutlineColor = Color3.new(0, 0, 0)
end

local function espEntry(model)
    local e = esp[model]
    if not e then
        e = {
            box = newDrawing("Square"),
            name = newDrawing("Text"),
            hp = newDrawing("Square"),
        }
        if e.box then
            e.box.Thickness = 1
            e.box.Filled = false
        end
        if e.name then
            e.name.Size = 13
            e.name.Font = 2
            e.name.Outline = true
            e.name.OutlineColor = Color3.new(0, 0, 0)
            e.name.Center = true
        end
        if e.hp then
            e.hp.Thickness = 0
            e.hp.Filled = true
        end
        esp[model] = e
    end
    return e
end

local function renderESP()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local seen = {}
    if Settings.ESP then
        for _, ch in ipairs(chars) do
            if ch.model.Parent and #ch.parts > 0 and not ch.dead then
                seen[ch.model] = true
                local e = espEntry(ch.model)
                local camPos = cam.CFrame.Position
                local minY, maxY = math.huge, -math.huge
                local sum = Vector3.zero
                local n = 0
                for _, entry in ipairs(ch.allParts or {}) do
                    local p = entry
                    if p and p.Parent then
                        minY = math.min(minY, p.Position.Y - p.Size.Y / 2)
                        maxY = math.max(maxY, p.Position.Y + p.Size.Y / 2)
                        sum = sum + p.Position
                        n = n + 1
                    end
                end
                if n == 0 then
                    for _, entry in ipairs(ch.parts) do
                        local p = entry.part
                        if p and p.Parent then
                            minY = math.min(minY, p.Position.Y - p.Size.Y / 2)
                            maxY = math.max(maxY, p.Position.Y + p.Size.Y / 2)
                            sum = sum + p.Position
                            n = n + 1
                        end
                    end
                end
                if n > 0 then
                    local centroid = sum / n
                    local topWorld = Vector3.new(centroid.X, maxY + 0.35, centroid.Z)
                    local bottomWorld = Vector3.new(centroid.X, minY, centroid.Z)
                    local pTop = project(topWorld)
                    local pBot = project(bottomWorld)
                    local dist = (centroid - camPos).Magnitude
                    local show = pTop and pBot and dist <= Settings.MaxESP
                    if show then
                        local h = math.abs(pBot.Y - pTop.Y)
                        if h < 8 then h = 8 end
                        local w = h * 0.5
                        local x = pTop.X - w / 2
                        local color = Color3.fromRGB(255, 70, 70)
                        if e.box then
                            e.box.Visible = true
                            e.box.Color = color
                            e.box.Position = Vector2.new(x, pTop.Y)
                            e.box.Size = Vector2.new(w, h)
                        end
                        if e.name then
                            e.name.Visible = true
                            e.name.Text = string.format("%s [%d]", ch.tagText or ch.model.Name, math.floor(dist))
                            e.name.Color = color
                            e.name.Position = Vector2.new(pTop.X, pTop.Y - 16)
                        end
                        if e.hp then
                            if ch.hum and ch.hum.MaxHealth > 0 then
                                local frac = math.clamp(ch.hum.Health / ch.hum.MaxHealth, 0, 1)
                                e.hp.Visible = true
                                e.hp.Color = Color3.fromRGB(math.floor(255 * (1 - frac)), math.floor(255 * frac), 60)
                                e.hp.Position = Vector2.new(x + 2, pTop.Y + h + 3)
                                e.hp.Size = Vector2.new((w - 4) * frac, 2)
                            else
                                e.hp.Visible = false
                            end
                        end
                    else
                        if e.box then e.box.Visible = false end
                        if e.name then e.name.Visible = false end
                        if e.hp then e.hp.Visible = false end
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
                for _, d in pairs(e) do
                    if d and d.Remove then pcall(d.Remove, d) end
                end
                esp[model] = nil
            end
        end
    end

    local vp = cam.ViewportSize
    if fovCircle then
        fovCircle.Visible = Settings.FOVCircle
        if Settings.FOVCircle then
            fovCircle.Center = Vector2.new(vp.X / 2, vp.Y / 2)
            fovCircle.Radius = Settings.FOVRadius
            fovCircle.Color = cachedTarget and Color3.fromRGB(90, 255, 120) or Color3.fromRGB(235, 235, 235)
        end
    end
    if hudLine then
        hudLine.Text = string.format("pf aim %s | silent %s | esp %s | fov %d | %d hits",
            Settings.Enabled and "on" or "off",
            Settings.SilentAim and "on" or "off",
            Settings.ESP and "on" or "off",
            Settings.FOVRadius,
            Status.rewrites)
    end
    if hudLock then
        if cachedTarget then
            hudLock.Text = string.format("lock: %s : %s", tostring(Status.lockedModel), tostring(Status.lockedPart))
        else
            hudLock.Text = ""
        end
    end
end

connect(RunService.RenderStepped, function()
    pcall(renderESP)
end)

connect(UIS.InputBegan, function(input, gp)
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
    elseif key == Enum.KeyCode.F4 then
        Settings.SilentAim = not Settings.SilentAim
        Status.silent = Settings.SilentAim
    end
end)

Status.hook = installHook()

task.spawn(function()
    while S.alive() do
        pcall(refreshCharacters)
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
    for _, d in ipairs(drawings) do
        pcall(function() d:Remove() end)
    end
    drawings = {}
    if ourNamecall then
        local ok, mt = pcall(getrawmetatable, game)
        if ok and mt and mt.__namecall == ourNamecall then
            pcall(setreadonly, mt, false)
            mt.__namecall = oldNamecall
            pcall(setreadonly, mt, true)
        end
    end
    getgenv().pfAimCleanup = nil
    getgenv().PFAimStatus = nil
end

getgenv().pfAimCleanup = cleanup
S.onCleanup(cleanup)
