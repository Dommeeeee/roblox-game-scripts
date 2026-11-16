-- parlor tricks - brookhaven rp
-- prompts, quickchat bubbles, rp name/bio, follow kid, family invites

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local LP = Players.LocalPlayer

local Remotes = RS:WaitForChild("Remotes")
local RE = RS:WaitForChild("RE")

local R = {
    trig = RE:WaitForChild("1Playe1rTrigge1rEven1t"),
    rp = RE:WaitForChild("1RPNam1eTex1t"),
    kid = RE:WaitForChild("1Bab1yFollo1w"),
    qc = Remotes:WaitForChild("QuickChat:Request"),
    fam = Remotes:WaitForChild("InvitePlayerToFamily"),
}

local PROMPTS = {
    P = "Request: Piggyback!",
    C = "Request: Carry!",
    S = "Request: Shoulders!",
}
local ORDER = { "P", "C", "S" }

local BUBBLES = {
    "Thank you", "Sorry",
    "\xF0\x9F\x98\x81", "\xF0\x9F\x98\x82", "\xF0\x9F\x98\xAD", "\xE2\x9D\xA4\xEF\xB8\x8F",
    "\xF0\x9F\x91\x8D", "\xF0\x9F\x91\x8E", "\xF0\x9F\x98\xA1", "\xF0\x9F\x92\x80",
    "\xF0\x9F\xA4\xA8", "\xF0\x9F\x98\xB4", "\xF0\x9F\x98\x8E", "\xF0\x9F\xA4\x93",
    "\xF0\x9F\xA5\xB1", "\xF0\x9F\xA4\xA1", "\xF0\x9F\xA5\x80", "\xF0\x9F\x92\xA9",
    "\xF0\x9F\x91\x8F", "\xF0\x9F\x91\x8C",
}

local KIDS = {
    "BabyBoy", "BabyGirl", "Minions2026_Henry", "Minions2026_James",
}

local lastPrompt = {}
local bubIdx, kidIdx = 0, 0
local autoBubble, autoPrompt = false, false

local function fire(remote, ...)
    return select(1, pcall(remote.FireServer, remote, ...))
end

local function nearest()
    local me = LP.Character and LP.Character:GetPivot().Position
    local out = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local d = me and (p.Character:GetPivot().Position - me).Magnitude or 0
            table.insert(out, { p = p, d = d })
        end
    end
    table.sort(out, function(a, b)
        return a.d < b.d
    end)
    return out
end

local function promptTo(plr, kind)
    if not plr or not plr.Character then
        return false
    end
    local now = os.clock()
    if lastPrompt[plr.UserId] and now - lastPrompt[plr.UserId] < 10 then
        return false
    end
    lastPrompt[plr.UserId] = now
    return fire(R.trig, "Client2Client", PROMPTS[kind], plr)
end

local function bubble(text)
    if not text then
        bubIdx = bubIdx % #BUBBLES + 1
        text = BUBBLES[bubIdx]
    end
    local ok, res = pcall(function()
        return R.qc:InvokeServer(text)
    end)
    return ok and res == true
end

local function setName(t)
    fire(R.rp, "RolePlayName", t)
end

local function setBio(t)
    fire(R.rp, "RolePlayBio", t)
end

local function spawnKid()
    kidIdx = kidIdx % #KIDS + 1
    fire(R.kid, "SpawnChild", KIDS[kidIdx])
end

local function killKid()
    fire(R.kid, "DeleteFollowCharacter")
end

local function inviteFamily(plr)
    if plr then
        fire(R.fam, plr.UserId, "FamilyInviteMenu")
    end
end

_G.Parlor = {
    bubble = bubble,
    prompt = promptTo,
    rename = setName,
    bio = setBio,
    kid = spawnKid,
    kidOff = killKid,
    fam = inviteFamily,
    nearest = nearest,
    gui = nil,
}

local old = LP:FindFirstChild("PlayerGui") and LP.PlayerGui:FindFirstChild("ParlorTricks")
if old then
    old:Destroy()
end

local gui = Instance.new("ScreenGui")
gui.Name = "ParlorTricks"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 200
gui.Parent = LP:WaitForChild("PlayerGui")
_G.Parlor.gui = gui

local root = Instance.new("Frame")
root.Size = UDim2.fromOffset(470, 390)
root.Position = UDim2.new(1, -490, 0, 80)
root.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
root.BorderSizePixel = 0
root.Active = true
root.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = root

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(56, 56, 66)
stroke.Thickness = 1
stroke.Parent = root

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 30)
header.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
header.BorderSizePixel = 0
header.Parent = root

local hcorner = Instance.new("UICorner")
hcorner.CornerRadius = UDim.new(0, 8)
hcorner.Parent = header

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.TextXAlignment = Enum.TextXAlignment.Left
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextColor3 = Color3.fromRGB(235, 235, 240)
title.Text = "parlor tricks  -  right shift"
title.Parent = header

local hideBtn = Instance.new("TextButton")
hideBtn.Size = UDim2.fromOffset(24, 20)
hideBtn.Position = UDim2.new(1, -32, 0, 5)
hideBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
hideBtn.BorderSizePixel = 0
hideBtn.Font = Enum.Font.GothamBold
hideBtn.TextSize = 12
hideBtn.TextColor3 = Color3.fromRGB(220, 220, 225)
hideBtn.Text = "x"
hideBtn.Parent = header

local hbcorner = Instance.new("UICorner")
hbcorner.CornerRadius = UDim.new(0, 4)
hbcorner.Parent = hideBtn

hideBtn.MouseButton1Click:Connect(function()
    root.Visible = false
end)

local function btn(parent, text, size, pos, cb)
    local b = Instance.new("TextButton")
    b.AutoButtonColor = true
    b.Size = size
    b.Position = pos
    b.BackgroundColor3 = Color3.fromRGB(38, 38, 46)
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 12
    b.TextColor3 = Color3.fromRGB(230, 230, 235)
    b.Text = text
    b.Parent = parent
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 4)
    c.Parent = b
    b.MouseButton1Click:Connect(cb)
    return b
end

local ctrl = Instance.new("Frame")
ctrl.Size = UDim2.new(1, -20, 0, 128)
ctrl.Position = UDim2.fromOffset(10, 36)
ctrl.BackgroundTransparency = 1
ctrl.Parent = root

local bubbleBtn = btn(ctrl, "bubble now", UDim2.fromOffset(96, 26), UDim2.fromOffset(0, 0), function()
    bubble()
end)
bubbleBtn.BackgroundColor3 = Color3.fromRGB(44, 60, 84)

local autoB = btn(ctrl, "auto bubble: off", UDim2.fromOffset(120, 26), UDim2.fromOffset(102, 0), function()
    autoBubble = not autoBubble
end)

local autoP = btn(ctrl, "auto prompts: off", UDim2.fromOffset(126, 26), UDim2.fromOffset(228, 0), function()
    autoPrompt = not autoPrompt
end)

local nameBox = Instance.new("TextBox")
nameBox.Size = UDim2.fromOffset(150, 24)
nameBox.Position = UDim2.fromOffset(0, 34)
nameBox.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
nameBox.BorderSizePixel = 0
nameBox.Font = Enum.Font.Gotham
nameBox.TextSize = 12
nameBox.TextColor3 = Color3.fromRGB(230, 230, 235)
nameBox.PlaceholderText = "rp name"
nameBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
nameBox.Text = ""
nameBox.ClearTextOnFocus = false
nameBox.Parent = ctrl

local ncorner = Instance.new("UICorner")
ncorner.CornerRadius = UDim.new(0, 4)
ncorner.Parent = nameBox

btn(ctrl, "name", UDim2.fromOffset(52, 24), UDim2.fromOffset(156, 34), function()
    if nameBox.Text ~= "" then
        setName(nameBox.Text)
    end
end)

local bioBox = Instance.new("TextBox")
bioBox.Size = UDim2.fromOffset(150, 24)
bioBox.Position = UDim2.fromOffset(0, 64)
bioBox.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
bioBox.BorderSizePixel = 0
bioBox.Font = Enum.Font.Gotham
bioBox.TextSize = 12
bioBox.TextColor3 = Color3.fromRGB(230, 230, 235)
bioBox.PlaceholderText = "rp bio"
bioBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
bioBox.Text = ""
bioBox.ClearTextOnFocus = false
bioBox.Parent = ctrl

local bcorner = Instance.new("UICorner")
bcorner.CornerRadius = UDim.new(0, 4)
bcorner.Parent = bioBox

btn(ctrl, "bio", UDim2.fromOffset(52, 24), UDim2.fromOffset(156, 64), function()
    if bioBox.Text ~= "" then
        setBio(bioBox.Text)
    end
end)

btn(ctrl, "kid +", UDim2.fromOffset(64, 24), UDim2.fromOffset(0, 96), spawnKid)
btn(ctrl, "kid -", UDim2.fromOffset(64, 24), UDim2.fromOffset(70, 96), killKid)
btn(ctrl, "invite all", UDim2.fromOffset(86, 24), UDim2.fromOffset(140, 96), function()
    for _, e in ipairs(nearest()) do
        inviteFamily(e.p)
    end
end)

local listLabel = Instance.new("TextLabel")
listLabel.Size = UDim2.new(1, -20, 0, 18)
listLabel.Position = UDim2.fromOffset(10, 168)
listLabel.BackgroundTransparency = 1
listLabel.TextXAlignment = Enum.TextXAlignment.Left
listLabel.Font = Enum.Font.GothamBold
listLabel.TextSize = 11
listLabel.TextColor3 = Color3.fromRGB(150, 150, 160)
listLabel.Text = "nearby  -  p / c / s / f"
listLabel.Parent = root

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -20, 0, 196)
scroll.Position = UDim2.fromOffset(10, 186)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 3
scroll.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 90)
scroll.CanvasSize = UDim2.fromOffset(0, 0)
scroll.Parent = root

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 2)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = scroll

local function buildRow(p, dist)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, -6, 0, 26)
    f.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
    f.BorderSizePixel = 0
    f.Parent = scroll

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 4)
    c.Parent = f

    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, -186, 1, 0)
    l.Position = UDim2.fromOffset(8, 0)
    l.BackgroundTransparency = 1
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Font = Enum.Font.Gotham
    l.TextSize = 12
    l.TextColor3 = Color3.fromRGB(220, 220, 226)
    l.TextTruncate = Enum.TextTruncate.AtEnd
    l.Text = string.format("%s  %d", p.DisplayName ~= "" and p.DisplayName or p.Name, math.floor(dist))
    l.Parent = f

    btn(f, "p", UDim2.fromOffset(40, 20), UDim2.fromOffset(252, 3), function() promptTo(p, "P") end)
    btn(f, "c", UDim2.fromOffset(40, 20), UDim2.fromOffset(296, 3), function() promptTo(p, "C") end)
    btn(f, "s", UDim2.fromOffset(40, 20), UDim2.fromOffset(340, 3), function() promptTo(p, "S") end)
    btn(f, "f", UDim2.fromOffset(40, 20), UDim2.fromOffset(384, 3), function() inviteFamily(p) end)
end

task.spawn(function()
    while true do
        local list = nearest()
        for _, ch in ipairs(scroll:GetChildren()) do
            if ch:IsA("Frame") then
                ch:Destroy()
            end
        end
        local n = math.min(#list, 12)
        for i = 1, n do
            buildRow(list[i].p, list[i].d)
        end
        scroll.CanvasSize = UDim2.fromOffset(0, n * 28)
        task.wait(3)
    end
end)

task.spawn(function()
    while true do
        task.wait(2.6)
        if autoBubble then
            bubble()
        end
        autoB.Text = autoBubble and "auto bubble: on" or "auto bubble: off"
        autoB.BackgroundColor3 = autoBubble and Color3.fromRGB(48, 84, 56) or Color3.fromRGB(38, 38, 46)
    end
end)

task.spawn(function()
    while true do
        task.wait(2)
        if autoPrompt then
            local list = nearest()
            if #list > 0 then
                local pick = list[math.random(#list)]
                promptTo(pick.p, ORDER[math.random(#ORDER)])
            end
        end
        autoP.Text = autoPrompt and "auto prompts: on" or "auto prompts: off"
        autoP.BackgroundColor3 = autoPrompt and Color3.fromRGB(48, 84, 56) or Color3.fromRGB(38, 38, 46)
    end
end)

local dragging, dragStart, startPos = false, nil, nil
header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = root.Position
    end
end)

UIS.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local d = input.Position - dragStart
        root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)

UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)

UIS.InputBegan:Connect(function(input, busy)
    if not busy and input.KeyCode == Enum.KeyCode.RightShift then
        root.Visible = not root.Visible
    end
end)

print("[parlor] loaded " .. tostring(#Players:GetPlayers()) .. " players")
