-- Hypershot silent aim + ESP + FOV
-- Body-first targeting; visible-part-first when peeking; server-trace-valid aim payload.
-- Never writes camera yaw/pitch. Redirects ShotClient.Prepare aim dir only.

local S = (typeof(STATE) == "table" and STATE) or {
    onCleanup = function() end,
    connect = function(a, b, c)
        if c ~= nil then return b:Connect(c) end
        return a:Connect(b)
    end,
    alive = function() return true end,
}

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local LP = Players.LocalPlayer
local cam = workspace.CurrentCamera

local EntityFolder = RS:FindFirstChild("Entity")
if not EntityFolder or not EntityFolder:FindFirstChild("ShotClient") then
    return
end

local SC = require(RS.Entity.ShotClient)
local HB = require(RS.Entity.Hitboxes)
local GS = require(RS.Modules.GlobalStuff)
local EC = require(RS.Entity.EntityClient)

local defaults = {
    Enabled = true,
    AimEnabled = true,
    FOV = 10,
    FOVVisible = true,
    ESPEnabled = true,
    ESPBox = true,
    ESPName = true,
    ESPHealth = true,
    ESPDistance = true,
    MaxDistance = 500,
    TeamCheck = true,
    HeadFallback = true,
    ScanHz = 15,
    AimKey = nil,
}
local cfg = getgenv().HypershotAim
if typeof(cfg) ~= "table" then cfg = {} end
for k, v in defaults do if cfg[k] == nil then cfg[k] = v end end
getgenv().HypershotAim = cfg

local FONT = (typeof(Drawing.Fonts) == "table" and Drawing.Fonts.Plex) or 2
local ZONES = { "Torso", "Legs", "LeftArm", "RightArm", "Head" }
local COL_TARGET = Color3.fromRGB(0, 255, 255)
local COL_VIS = Color3.fromRGB(0, 255, 120)
local COL_PART = Color3.fromRGB(255, 220, 0)
local COL_BLOCK = Color3.fromRGB(255, 70, 70)

local currentTarget, currentPoint, currentZone = nil, nil, nil
local visCache = {}
local lastScan = 0
local pool = {}
local fovCircle

local function localModel()
    local m = EC:GetLocalModel()
    if m then return m end
    return LP.Character
end

local function excludeParams()
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Exclude
    local ok, list = pcall(SC.Exclude, SC)
    if ok and typeof(list) == "table" then
        p.FilterDescendantsInstances = list
    else
        local t = {}
        for _, n in { "IgnoreThese", "Entities", "EntityFocus", "StaticTargets" } do
            local f = workspace:FindFirstChild(n)
            if f then t[#t + 1] = f end
        end
        local lm = localModel()
        if lm then t[#t + 1] = lm end
        p.FilterDescendantsInstances = t
    end
    p.IgnoreWater = true
    return p
end

local function ignoreMap()
    local ok, m = pcall(SC.Ignore, SC)
    if ok and typeof(m) == "table" then return m end
    local lm = localModel()
    return lm and { [lm] = true } or {}
end

local function hittable(model)
    if not model or model == localModel() then return false end
    local ok, res = pcall(GS.CanHit, GS, LP, model, true, true)
    if ok then return res and true or false end
    return false
end

local function pointVisible(eye, pt, model, poses, params, ignore)
    local dir = pt - eye
    if dir.Magnitude < 0.05 then return false end
    local ok, res = pcall(HB.Raycast, eye, dir, params, poses, nil, ignore)
    if not ok or typeof(res) ~= "table" then return false end
    return res.Model == model
end

local function boxSamplePoints(box)
    local cf, s = box.CFrame, box.Size
    local hx, hy, hz = s.X * 0.5, s.Y * 0.5, s.Z * 0.5
    local k = 0.82
    local pts = { cf.Position }
    for sx = -1, 1, 2 do
        for sy = -1, 1, 2 do
            for sz = -1, 1, 2 do
                pts[#pts + 1] = (cf * CFrame.new(sx * hx * k, sy * hy * k, sz * hz * k)).Position
            end
        end
    end
    return pts
end

-- Torso center first (fully exposed -> body). If blocked, torso edges, then
-- legs/arms (peeking -> visible part). Head only as last resort.
local function selectPoint(eye, pose, poses, params, ignore)
    local ok, boxes = pcall(HB.GetBoxes, pose)
    if not ok or typeof(boxes) ~= "table" then return nil end
    local byZone = {}
    for _, b in boxes do byZone[b.Zone] = b end
    for _, zone in ZONES do
        if zone ~= "Head" or cfg.HeadFallback then
            local box = byZone[zone]
            if box then
                local center = box.CFrame.Position
                if pointVisible(eye, center, pose.Model, poses, params, ignore) then
                    return center, zone
                end
                local pts = boxSamplePoints(box)
                for i = 2, #pts do
                    if pointVisible(eye, pts[i], pose.Model, poses, params, ignore) then
                        return pts[i], zone
                    end
                end
            end
        end
    end
    return nil
end

local function candidates()
    local eye = SC.Origin()
    if not eye then return nil end
    local poses = SC:GetPoses()
    if typeof(poses) ~= "table" then return nil end
    local look = cam.CFrame.LookVector
    local camPos = cam.CFrame.Position
    local fovRad = math.rad(cfg.FOV)
    local list = {}
    for _, pose in ipairs(poses) do
        local model = pose.Model
        if hittable(model) then
            local ok, center = pcall(HB.ZoneCenter, pose, "Torso")
            if ok and typeof(center) == "Vector3" then
                local to = center - camPos
                local dist = to.Magnitude
                if dist > 0.1 and dist <= cfg.MaxDistance then
                    local ang = math.acos(math.clamp(look:Dot(to.Unit), -1, 1))
                    if ang <= fovRad then
                        list[#list + 1] = { pose = pose, ang = ang, dist = dist, center = center }
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.ang < b.ang end)
    return eye, poses, list
end

local function computeAim()
    if not cfg.AimEnabled then return nil end
    if cfg.AimKey and not UIS:IsKeyDown(cfg.AimKey) then return nil end
    local eye, poses, list = candidates()
    if not eye or #list == 0 then return nil end
    local params = excludeParams()
    local ignore = ignoreMap()
    local n = math.min(#list, 5)
    for i = 1, n do
        local c = list[i]
        local pt, zone = selectPoint(eye, c.pose, poses, params, ignore)
        if pt then
            local dir = pt - eye
            if dir.Magnitude >= 0.05 then
                return dir.Unit, c.pose, pt, zone
            end
        end
    end
    return nil
end

-- ---- silent aim hook (payload only) ----
local origPrepare = SC.Prepare
local oldPrepare
local function hookPrepare(self, weapon, aimDir, flags)
    if cfg.Enabled and aimDir then
        local ok, dir, pose, pt, zone = pcall(computeAim)
        if ok and dir then
            currentTarget, currentPoint, currentZone = pose, pt, zone
            return oldPrepare(self, weapon, dir, flags)
        end
    end
    return oldPrepare(self, weapon, aimDir, flags)
end
oldPrepare = hookfunction(origPrepare, hookPrepare)
S.onCleanup(function() pcall(hookfunction, origPrepare, oldPrepare) end)

-- ---- tracer/visual dir hook: the visible bullet flies to the locked point ----
-- AimDirection is the eye-relative dir the fire controller feeds to both the shot
-- payload and ShootVFX. Redirecting it makes the beam home without touching camera.
local origAimDirection = SC.AimDirection
local oldAimDirection
local function hookAimDirection(self, eye, range, params, poses, width)
    if cfg.Enabled and cfg.AimEnabled and currentTarget and currentPoint and typeof(eye) == "Vector3" then
        local dir = currentPoint - eye
        if dir.Magnitude >= 0.05 then
            return dir.Unit
        end
    end
    return oldAimDirection(self, eye, range, params, poses, width)
end
oldAimDirection = hookfunction(origAimDirection, hookAimDirection)
S.onCleanup(function() pcall(hookfunction, origAimDirection, oldAimDirection) end)

-- ---- drawing pool ----
local function newEntry()
    local e = {}
    e.box = Drawing.new("Square"); e.box.Filled = false; e.box.Thickness = 1; e.box.Visible = false
    e.name = Drawing.new("Text"); e.name.Font = FONT; e.name.Size = 13; e.name.Outline = true; e.name.Center = true; e.name.Visible = false
    e.hpBg = Drawing.new("Square"); e.hpBg.Filled = true; e.hpBg.Color = Color3.fromRGB(0, 0, 0); e.hpBg.Transparency = 0.6; e.hpBg.Visible = false
    e.hpFill = Drawing.new("Square"); e.hpFill.Filled = true; e.hpFill.Visible = false
    e.dist = Drawing.new("Text"); e.dist.Font = FONT; e.dist.Size = 12; e.dist.Outline = true; e.dist.Center = true; e.dist.Visible = false
    e.marker = Drawing.new("Circle"); e.marker.Filled = true; e.marker.Radius = 3; e.marker.NumSides = 12; e.marker.Color = COL_TARGET; e.marker.Visible = false
    return e
end

local function hideEntry(e)
    e.box.Visible = false; e.name.Visible = false; e.hpBg.Visible = false
    e.hpFill.Visible = false; e.dist.Visible = false; e.marker.Visible = false
end

local function removeEntry(e)
    for _, k in { "box", "name", "hpBg", "hpFill", "dist", "marker" } do
        pcall(function() e[k]:Remove() end)
    end
end

local function getEntry(i)
    if not pool[i] then pool[i] = newEntry() end
    return pool[i]
end

fovCircle = Drawing.new("Circle")
fovCircle.Filled = false; fovCircle.Thickness = 1; fovCircle.NumSides = 64
fovCircle.Color = Color3.fromRGB(255, 255, 255); fovCircle.Transparency = 0.55; fovCircle.Visible = false

S.onCleanup(function()
    for _, e in pool do removeEntry(e) end
    pool = {}
    pcall(function() fovCircle:Remove() end)
end)

local function fovRadius()
    local cf = cam.CFrame
    local dir = (cf * CFrame.Angles(math.rad(cfg.FOV), 0, 0)).LookVector
    local ok, vp = pcall(cam.WorldToViewportPoint, cam, cf.Position + dir * 100)
    if not ok then return 60 end
    local c = cam.ViewportSize * 0.5
    return (Vector2.new(vp.X, vp.Y) - c).Magnitude
end

local function healthFrac(model)
    local ok, h = pcall(GS.GetHealth, GS, model)
    if not ok or typeof(h) ~= "number" then return 1 end
    local max = model:GetAttribute("MaxHealth")
    if typeof(max) ~= "number" or max <= 0 then
        local hum = model:FindFirstChildOfClass("Humanoid")
        max = hum and hum.MaxHealth or 100
    end
    if max <= 0 then max = 100 end
    return math.clamp(h / max, 0, 1)
end

local function scan(eye, poses)
    visCache = {}
    local params = excludeParams()
    local ignore = ignoreMap()
    for _, pose in ipairs(poses) do
        local model = pose.Model
        if hittable(model) then
            local ok, center = pcall(HB.ZoneCenter, pose, "Torso")
            if ok and typeof(center) == "Vector3" then
                visCache[model] = pointVisible(eye, center, model, poses, params, ignore) and "vis" or "block"
            end
        end
    end
end

local function frame()
    cam = workspace.CurrentCamera
    if not cam then return end
    local center = cam.ViewportSize * 0.5

    if cfg.FOVVisible then
        fovCircle.Position = center
        fovCircle.Radius = fovRadius()
        fovCircle.Visible = true
    else
        fovCircle.Visible = false
    end

    if not cfg.ESPEnabled then
        for _, e in pool do hideEntry(e) end
        return
    end

    local eye, poses, list = candidates()
    if not poses then
        for _, e in pool do hideEntry(e) end
        return
    end

    local now = os.clock()
    if now - lastScan >= 1 / math.max(1, cfg.ScanHz) then
        lastScan = now
        if eye then scan(eye, poses) end
        if list and #list > 0 and eye then
            local params = excludeParams()
            local ignore = ignoreMap()
            local found = false
            for i = 1, math.min(#list, 5) do
                local c = list[i]
                local pt, zone = selectPoint(eye, c.pose, poses, params, ignore)
                if pt then
                    currentTarget, currentPoint, currentZone = c.pose, pt, zone
                    found = true
                    break
                end
            end
            if not found then
                currentTarget, currentPoint, currentZone = list[1].pose, nil, nil
            end
        else
            currentTarget, currentPoint, currentZone = nil, nil, nil
        end
    end

    local idx = 0
    for _, pose in ipairs(poses) do
        local model = pose.Model
        if hittable(model) then
            local ok, boxes = pcall(HB.GetBoxes, pose)
            if ok and typeof(boxes) == "table" then
                local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
                local anyOn = false
                for _, box in boxes do
                    local cf, s = box.CFrame, box.Size
                    local hx, hy, hz = s.X * 0.5, s.Y * 0.5, s.Z * 0.5
                    for sx = -1, 1, 2 do
                        for sy = -1, 1, 2 do
                            for sz = -1, 1, 2 do
                                local w = (cf * CFrame.new(sx * hx, sy * hy, sz * hz)).Position
                                local okp, vp, on = pcall(cam.WorldToViewportPoint, cam, w)
                                if okp and on then
                                    anyOn = true
                                    if vp.X < minX then minX = vp.X end
                                    if vp.Y < minY then minY = vp.Y end
                                    if vp.X > maxX then maxX = vp.X end
                                    if vp.Y > maxY then maxY = vp.Y end
                                end
                            end
                        end
                    end
                end
                if anyOn and maxX > minX and maxY > minY then
                    idx += 1
                    local e = getEntry(idx)
                    local isTarget = (currentTarget == pose)
                    local v = visCache[model]
                    local col = COL_BLOCK
                    if isTarget then col = COL_TARGET
                    elseif v == "vis" then col = COL_VIS
                    elseif v == "block" then col = COL_PART end

                    local w = maxX - minX
                    local h = maxY - minY
                    if cfg.ESPBox then
                        e.box.Position = Vector2.new(minX, minY)
                        e.box.Size = Vector2.new(w, h)
                        e.box.Color = col
                        e.box.Visible = true
                    else e.box.Visible = false end

                    if cfg.ESPName then
                        e.name.Text = model.Name
                        e.name.Position = Vector2.new(minX + w * 0.5, minY - 15)
                        e.name.Color = col
                        e.name.Visible = true
                    else e.name.Visible = false end

                    if cfg.ESPHealth then
                        local frac = healthFrac(model)
                        local bh = h
                        e.hpBg.Position = Vector2.new(minX - 5, minY)
                        e.hpBg.Size = Vector2.new(2, bh)
                        e.hpBg.Visible = true
                        e.hpFill.Position = Vector2.new(minX - 5, minY + bh * (1 - frac))
                        e.hpFill.Size = Vector2.new(2, bh * frac)
                        e.hpFill.Color = Color3.fromRGB(255 * (1 - frac), 255 * frac, 60)
                        e.hpFill.Visible = true
                    else e.hpBg.Visible = false; e.hpFill.Visible = false end

                    if cfg.ESPDistance then
                        local d = (pose.Pos - cam.CFrame.Position).Magnitude
                        e.dist.Text = string.format("%dm", math.floor(d + 0.5))
                        e.dist.Position = Vector2.new(minX + w * 0.5, maxY + 2)
                        e.dist.Color = col
                        e.dist.Visible = true
                    else e.dist.Visible = false end

                    if isTarget and currentPoint then
                        local okm, vpm, onm = pcall(cam.WorldToViewportPoint, cam, currentPoint)
                        if okm and onm then
                            e.marker.Position = Vector2.new(vpm.X, vpm.Y)
                            e.marker.Visible = true
                        else e.marker.Visible = false end
                    else e.marker.Visible = false end
                end
            end
        end
    end
    for i = idx + 1, #pool do hideEntry(pool[i]) end
end

task.spawn(function()
    while S.alive() do
        RunService.RenderStepped:Wait()
        local ok, err = pcall(frame)
        if not ok then warn("[HypershotAim] frame: " .. tostring(err)) end
    end
end)

S.connect(UIS.InputBegan, function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.F1 then
        cfg.AimEnabled = not cfg.AimEnabled
        print("[HypershotAim] aim " .. (cfg.AimEnabled and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.F2 then
        cfg.ESPEnabled = not cfg.ESPEnabled
        print("[HypershotAim] esp " .. (cfg.ESPEnabled and "ON" or "OFF"))
    elseif input.KeyCode == Enum.KeyCode.F3 then
        cfg.FOVVisible = not cfg.FOVVisible
        print("[HypershotAim] fov " .. (cfg.FOVVisible and "ON" or "OFF"))
    end
end)

getgenv().HypershotAimStatus = function()
    return {
        installed = true,
        aim = cfg.AimEnabled,
        esp = cfg.ESPEnabled,
        fov = cfg.FOV,
        target = currentTarget and currentTarget.Model and currentTarget.Model.Name or nil,
        zone = currentZone,
        point = currentPoint and tostring(currentPoint) or nil,
        poolSize = #pool,
    }
end

print("[HypershotAim] loaded - hook installed, FOV " .. tostring(cfg.FOV) .. "deg")
