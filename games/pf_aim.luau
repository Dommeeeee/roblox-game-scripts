-- Phantom Forces silent aim: body-first targeting, visible-part priority,
-- Drawing ESP + FOV circle, newbullets direction rewrite, and hit claims.
-- Camera read-only. No weapon CFrame writes, no Highlight, no character edits.
-- PF sends bypass __namecall (captured C FireServer), so both paths are hooked.
-- Claims reuse the game's own next send so the LCG key sequence never desyncs.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
    ClaimHits = true,
}

local Status = {
    enabled = Settings.Enabled,
    silent = Settings.SilentAim,
    esp = Settings.ESP,
    fov = Settings.FOVCircle,
    hook = false,
    fireHook = false,
    enemies = 0,
    players = 0,
    lockedModel = nil,
    lockedPart = nil,
    lockedKind = nil,
    shots = 0,
    sends = 0,
    rewrites = 0,
    claims = 0,
    claimsSent = 0,
    mapFail = 0,
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

local tagPlayerCache = {}
local function playerFromTag(tag)
    if tagPlayerCache[tag] then return tagPlayerCache[tag] end
    local text = tag.Text
    local found = nil
    local low = string.lower(text)
    for _, p in ipairs(Players:GetPlayers()) do
        if string.lower(p.Name) == low or string.lower(p.DisplayName) == low then
            found = p
            break
        end
    end
    if not found then
        for _, d in ipairs(tag:GetDescendants()) do
            local url = nil
            if d:IsA("ImageLabel") or d:IsA("ImageButton") then
                url = d.Image
            end
            if url then
                local id = string.match(url, "id=(%d+)")
                if id then
                    local p = Players:GetPlayerByUserId(tonumber(id))
                    if p then
                        found = p
                        break
                    end
                end
            end
        end
    end
    if found then
        tagPlayerCache[tag] = found
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
                tag = tag,
                enemy = enemy,
                dead = false,
                parts = {},
            }
            local hum = model:FindFirstChildOfClass("Humanoid")
            ch.hum = hum
            if hum and hum.Health <= 0 then ch.dead = true end
            ch.player = playerFromTag(tag)
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
                        player = ch.player,
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

local function aimDirection(itarget, origin)
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
    if dir.Magnitude < 0.5 then return nil end
    return dir.Unit, aim
end

local function partLabel(kind)
    if kind == "torso" then return "Torso" end
    return "Left Arm"
end

local remote = ReplicatedStorage:FindFirstChild("RemoteEvent")
local pending = {}

local function rewritePacket(args, idx, name, target)
    local uniqueId = args[idx + 1]
    local packet, packetIndex
    for i = idx + 1, math.min(idx + 3, args.n) do
        local v = args[i]
        if type(v) == "table" and type(v.bullets) == "table" then
            packet, packetIndex = v, i
            break
        end
    end
    if not packet then return false end

    local origin = nil
    if typeof(packet.firepos) == "Vector3" then origin = packet.firepos
    elseif typeof(packet.camerapos) == "Vector3" then origin = packet.camerapos
    else origin = Camera.CFrame.Position end

    local dir, aim = aimDirection(target, origin)
    if not dir then return false end

    local fireTime = nil
    if typeof(args[packetIndex + 1]) == "number" then fireTime = args[packetIndex + 1] end

    local tickets = {}
    local count = 0
    for i = 1, #packet.bullets do
        local entry = packet.bullets[i]
        if type(entry) == "table" then
            if type(entry[1]) == "Vector3" then
                entry[1] = dir
                count = count + 1
            elseif type(entry.lookVector) == "Vector3" then
                entry.lookVector = dir
                count = count + 1
            end
            if entry[2] ~= nil then table.insert(tickets, entry[2]) end
        end
    end

    if count > 0 and Settings.ClaimHits and target.player and uniqueId ~= nil then
        for _, ticket in ipairs(tickets) do
            table.insert(pending, {
                uniqueId = uniqueId,
                ticket = ticket,
                player = target.player,
                point = aim,
                label = partLabel(target.kind),
                firedAt = os.clock(),
                fireTime = fireTime,
            })
        end
        Status.claims = #pending
    end
    return count > 0
end

local function buildClaim(idx, args)
    local now = os.clock()
    for i, claim in ipairs(pending) do
        local age = now - claim.firedAt
        if age > 2.5 then
            table.remove(pending, i)
            Status.claims = #pending
            return nil
        end
    end
    local claim = pending[1]
    if not claim then return nil end
    if now - claim.firedAt < 0.08 then return nil end
    table.remove(pending, 1)
    Status.claims = #pending

    local t = claim.fireTime
    if typeof(t) ~= "number" then t = 0 end
    args[idx + 1] = claim.uniqueId
    args[idx + 2] = claim.player
    args[idx + 3] = claim.point
    args[idx + 4] = claim.label
    args[idx + 5] = claim.ticket
    args[idx + 6] = t + 0.05
    args.n = idx + 6
    Status.claimsSent = Status.claimsSent + 1
    return true
end

local function patchSend(self, args)
    if remote and self ~= remote then return false end
    Status.sends = Status.sends + 1
    local idx, name
    for i = 1, math.min(args.n, 3) do
        if type(args[i]) == "string" then
            idx, name = i, args[i]
            break
        end
    end
    if not idx then return false end

    if name == "newbullets" then
        if not (Settings.Enabled and Settings.SilentAim) then return false end
        local target = resolveTarget(true)
        if not target then return false end
        if not target.player then Status.mapFail = Status.mapFail + 1 end
        local ok = rewritePacket(args, idx, name, target)
        if ok then
            Status.shots = Status.shots + 1
            Status.rewrites = Status.rewrites + 1
        end
        return ok
    end

    if name == "ping" and Settings.ClaimHits and #pending > 0 then
        return buildClaim(idx, args) or false
    end
    return false
end

local oldNamecall, ourNamecall
local originalFire, fireWrapper, fireHooked = nil, nil, false

local function installHooks()
    local ok, mt = pcall(getrawmetatable, game)
    if ok and mt and type(mt.__namecall) == "function" then
        pcall(setreadonly, mt, false)
        oldNamecall = mt.__namecall
        ourNamecall = newcclosure(function(self, ...)
            if getnamecallmethod() == "FireServer" then
                local args = table.pack(...)
                local ok2, changed = pcall(patchSend, self, args)
                if ok2 and changed then
                    return oldNamecall(self, table.unpack(args, 1, args.n))
                end
            end
            return oldNamecall(self, ...)
        end)
        mt.__namecall = ourNamecall
        pcall(setreadonly, mt, true)
        Status.hook = true
    end

    if remote and type(remote.FireServer) == "function" then
        originalFire = remote.FireServer
        local fireBackup = nil
        fireWrapper = newcclosure(function(self, ...)
            local args = table.pack(...)
            local ok2, changed = pcall(patchSend, self, args)
            if ok2 and changed then
                return fireBackup(self, table.unpack(args, 1, args.n))
            end
            return fireBackup(self, ...)
        end)
        local ok3, backup = pcall(hookfunction, originalFire, fireWrapper)
        if ok3 and type(backup) == "function" then
            fireBackup = backup
            fireHooked = true
        else
            fireHooked = false
        end
        Status.fireHook = fireHooked
    end
end

installHooks()

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
                for _, p in ipairs(ch.allParts or {}) do
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
                    local pTop = project(Vector3.new(centroid.X, maxY + 0.35, centroid.Z))
                    local pBot = project(Vector3.new(centroid.X, minY, centroid.Z))
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
        hudLine.Text = string.format("pf aim %s | silent %s | esp %s | fov %d | rw %d | cl %d",
            Settings.Enabled and "on" or "off",
            Settings.SilentAim and "on" or "off",
            Settings.ESP and "on" or "off",
            Settings.FOVRadius,
            Status.rewrites,
            Status.claimsSent)
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
    Pending = function() return pending end,
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
    if fireHooked and originalFire then
        pcall(function() restorefunction(originalFire) end)
    end
    getgenv().pfAimCleanup = nil
    getgenv().PFAimStatus = nil
end

getgenv().pfAimCleanup = cleanup
S.onCleanup(cleanup)
