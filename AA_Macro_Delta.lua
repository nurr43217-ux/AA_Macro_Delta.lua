--[[
    Anime Adventures - Macro Recorder & Player (UI Modern)
    Untuk executor Delta (mobile/PC)

    CATATAN:
    - Macro merekam remote game (place unit, upgrade, sell, dll) lalu memutarnya ulang.
    - Nama remote & folder unit ada di CONFIG. Sesuaikan jika game update.
    - Belum diuji langsung di game; gunakan dengan risiko sendiri (bisa melanggar ToS Roblox).
]]

local CONFIG = {
    -- Remote yang direkam/diputar ulang
    Watch = {
        spawn_unit = true,
        upgrade_unit_ingame = true,
        sell_unit_ingame = true,
        use_active_attack = true,
    },
    -- Remote untuk fitur Auto
    SkipWaveRemote = "vote_wave_skip",
    StartRemote = "vote_start",
    ReplayRemote = "vote_replay", -- sesuaikan dengan nama remote replay di game
    -- Folder unit di workspace (untuk mencocokkan unit saat upgrade/sell)
    UnitFolder = "_UNITS",
    Folder = "AA_Macros",
}

----------------------------------------------------------------
-- Services & state
----------------------------------------------------------------
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local TS = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local State = {
    recording = false,
    playing = false,
    loop = false,
    autoSkip = false,
    autoStart = false,
    autoReplay = false,
    webhook = "",
    notify = false,
    theme = "Ungu",
    macro = {},
    startTime = 0,
}

if isfolder and not isfolder(CONFIG.Folder) then pcall(makefolder, CONFIG.Folder) end

----------------------------------------------------------------
-- Serialisasi argumen
----------------------------------------------------------------
local function ser(v)
    local t = typeof(v)
    if t == "nil" then return { __t = "NIL" }
    elseif t == "CFrame" then return { __t = "CF", v = { v:GetComponents() } }
    elseif t == "Vector3" then return { __t = "V3", v = { v.X, v.Y, v.Z } }
    elseif t == "Instance" then
        local p
        if v:IsA("Model") then p = v:GetPivot().Position
        elseif v:IsA("BasePart") then p = v.Position end
        if p then return { __t = "INST", v = { p.X, p.Y, p.Z } } end
        return { __t = "NIL" }
    elseif t == "table" then
        local arr = {}
        for i, x in ipairs(v) do arr[i] = ser(x) end
        return { __t = "ARR", v = arr }
    end
    return v
end

local function findUnit(pos)
    local folder = workspace:FindFirstChild(CONFIG.UnitFolder)
    if not folder then return nil end
    local best, bd = nil, 4
    for _, u in ipairs(folder:GetChildren()) do
        local ok, p = pcall(function() return u:GetPivot().Position end)
        if ok then
            local d = (p - Vector3.new(pos[1], pos[2], pos[3])).Magnitude
            if d < bd then best, bd = u, d end
        end
    end
    return best
end

local function deser(v)
    if type(v) ~= "table" then return v end
    if v.__t == "NIL" then return nil
    elseif v.__t == "CF" then return CFrame.new(table.unpack(v.v))
    elseif v.__t == "V3" then return Vector3.new(table.unpack(v.v))
    elseif v.__t == "INST" then return findUnit(v.v)
    elseif v.__t == "ARR" then
        local o = {}
        for i, x in ipairs(v.v) do o[i] = deser(x) end
        return o
    end
    return v
end

----------------------------------------------------------------
-- Remote helpers
----------------------------------------------------------------
local cache = {}
local function getRemote(name)
    if cache[name] and cache[name].Parent then return cache[name] end
    for _, d in ipairs(RS:GetDescendants()) do
        if d.Name == name and (d:IsA("RemoteEvent") or d:IsA("RemoteFunction")) then
            cache[name] = d
            return d
        end
    end
end

local function callRemote(name, method, args)
    local r = getRemote(name)
    if not r then return false end
    local out = {}
    for i = 1, args.n do out[i] = deser(args[i]) end
    task.spawn(function()
        if r:IsA("RemoteFunction") then
            pcall(r.InvokeServer, r, table.unpack(out, 1, args.n))
        else
            pcall(r.FireServer, r, table.unpack(out, 1, args.n))
        end
    end)
    return true
end

----------------------------------------------------------------
-- Hook perekam
----------------------------------------------------------------
local logFn = function() end

local old
old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
    local method = getnamecallmethod()
    if State.recording and (method == "FireServer" or method == "InvokeServer")
        and CONFIG.Watch[self.Name] and not checkcaller() then
        local args = table.pack(...)
        local s = { n = args.n }
        for i = 1, args.n do s[i] = ser(args[i]) end
        table.insert(State.macro, {
            t = os.clock() - State.startTime,
            remote = self.Name,
            method = method,
            args = s,
        })
        logFn("Rekam: " .. self.Name .. " (#" .. #State.macro .. ")")
    end
    return old(self, ...)
end))

----------------------------------------------------------------
-- Player
----------------------------------------------------------------
local function saveSettings()
    if not writefile then return end
    pcall(writefile, CONFIG.Folder .. "/settings.json", HttpService:JSONEncode({
        webhook = State.webhook, notify = State.notify, theme = State.theme,
    }))
end

do
    local path = CONFIG.Folder .. "/settings.json"
    if isfile and isfile(path) then
        local ok, d = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
        if ok and type(d) == "table" then
            State.webhook = d.webhook or ""
            State.notify = d.notify or false
            State.theme = d.theme or "Ungu"
        end
    end
end

local function sendWebhook(msg, force)
    if not (State.notify or force) or State.webhook == "" then return end
    local req = (syn and syn.request) or http_request or request
    if not req then return logFn("Executor tidak mendukung http request") end
    task.spawn(function()
        local ok = pcall(req, {
            Url = State.webhook,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({
                username = "AA Macro",
                content = ("**%s** • %s"):format(Players.LocalPlayer.Name, msg),
            }),
        })
        if not ok then logFn("Gagal kirim webhook") end
    end)
end

local function play()
    if State.playing or #State.macro == 0 then return end
    State.playing = true
    task.spawn(function()
        repeat
            local t0 = os.clock()
            for i, e in ipairs(State.macro) do
                if not State.playing then break end
                while os.clock() - t0 < e.t do
                    if not State.playing then break end
                    task.wait(0.05)
                end
                if not State.playing then break end
                callRemote(e.remote, e.method, e.args)
                logFn(("Play %d/%d: %s"):format(i, #State.macro, e.remote))
            end
            if State.playing then
                sendWebhook(("Macro selesai satu putaran (%d aksi)"):format(#State.macro))
            end
            if State.playing and State.loop then task.wait(3) end
        until not (State.playing and State.loop)
        State.playing = false
        logFn("Playback selesai")
    end)
end

local function saveMacro(name)
    if not writefile then return logFn("writefile tidak tersedia") end
    writefile(CONFIG.Folder .. "/" .. name .. ".json", HttpService:JSONEncode(State.macro))
    logFn("Tersimpan: " .. name)
end

local function loadMacro(name)
    local path = CONFIG.Folder .. "/" .. name .. ".json"
    if not (isfile and isfile(path)) then return logFn("File tidak ditemukan") end
    State.macro = HttpService:JSONDecode(readfile(path))
    logFn(("Dimuat: %s (%d aksi)"):format(name, #State.macro))
end

----------------------------------------------------------------
-- UI
----------------------------------------------------------------
local C = {
    bg = Color3.fromRGB(18, 18, 24),
    side = Color3.fromRGB(24, 24, 32),
    card = Color3.fromRGB(32, 32, 43),
    accent = Color3.fromRGB(124, 92, 255),
    text = Color3.fromRGB(235, 235, 245),
    sub = Color3.fromRGB(150, 150, 170),
    on = Color3.fromRGB(70, 200, 130),
    off = Color3.fromRGB(70, 70, 88),
    red = Color3.fromRGB(235, 80, 90),
}

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end
local function round(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 10) }, o) end
local function stroke(o, c, t) new("UIStroke", { Color = c or C.accent, Thickness = t or 1, Transparency = 0.6 }, o) end

local parentGui = (gethui and gethui()) or game:GetService("CoreGui")
if parentGui:FindFirstChild("AAMacroUI") then parentGui.AAMacroUI:Destroy() end

local gui = new("ScreenGui", { Name = "AAMacroUI", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, parentGui)

local main = new("Frame", {
    Size = UDim2.fromOffset(440, 280), Position = UDim2.new(0.5, -220, 0.5, -140),
    BackgroundColor3 = C.bg, BorderSizePixel = 0,
}, gui)
round(main, 14); stroke(main)

-- Top bar
local top = new("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = C.side, BorderSizePixel = 0 }, main)
round(top, 14)
new("Frame", { Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 1, -12), BackgroundColor3 = C.side, BorderSizePixel = 0 }, top)
new("TextLabel", {
    Text = "⚔  Anime Adventures • Macro", Font = Enum.Font.GothamBold, TextSize = 14,
    TextColor3 = C.text, BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 0),
    Size = UDim2.new(1, -90, 1, 0), TextXAlignment = Enum.TextXAlignment.Left,
}, top)

local function topBtn(txt, x, col)
    local b = new("TextButton", {
        Text = txt, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.text,
        BackgroundColor3 = col, Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, x, 0, 6),
        AutoButtonColor = true,
    }, top)
    round(b, 12)
    return b
end
local closeBtn = topBtn("×", -32, C.red)
local minBtn = topBtn("–", -62, C.off)

-- Drag
do
    local dragging, startPos, startInput
    top.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, startPos, startInput = true, main.Position, i.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startInput
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

-- Sidebar + pages
local side = new("Frame", { Size = UDim2.new(0, 110, 1, -36), Position = UDim2.fromOffset(0, 36), BackgroundColor3 = C.side, BorderSizePixel = 0 }, main)
new("UIListLayout", { Padding = UDim.new(0, 6) }, side)
new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, side)

local content = new("Frame", { Size = UDim2.new(1, -110, 1, -36), Position = UDim2.fromOffset(110, 36), BackgroundTransparency = 1 }, main)
local pages, tabs = {}, {}

local function newPage(name)
    local p = new("ScrollingFrame", {
        Size = UDim2.new(1, -16, 1, -16), Position = UDim2.fromOffset(8, 8), BackgroundTransparency = 1,
        BorderSizePixel = 0, ScrollBarThickness = 3, Visible = false, CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, content)
    new("UIListLayout", { Padding = UDim.new(0, 8) }, p)
    pages[name] = p

    local t = new("TextButton", {
        Text = name, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = C.sub,
        BackgroundColor3 = C.card, Size = UDim2.new(1, 0, 0, 32), AutoButtonColor = false,
    }, side)
    round(t, 8)
    tabs[name] = t
    t.MouseButton1Click:Connect(function()
        for n, pg in pairs(pages) do
            pg.Visible = (n == name)
            TS:Create(tabs[n], TweenInfo.new(0.2), {
                BackgroundColor3 = (n == name) and C.accent or C.card,
                TextColor3 = (n == name) and C.text or C.sub,
            }):Play()
        end
    end)
    return p
end

local function button(parent, text, cb, col)
    local b = new("TextButton", {
        Text = text, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = C.text,
        BackgroundColor3 = col or C.card, Size = UDim2.new(1, 0, 0, 34), AutoButtonColor = true,
    }, parent)
    round(b, 8); stroke(b, col or C.accent)
    b.MouseButton1Click:Connect(cb)
    return b
end

local function toggle(parent, text, default, cb)
    local f = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = C.card }, parent)
    round(f, 8)
    new("TextLabel", {
        Text = text, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = C.text,
        BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -70, 1, 0),
        TextXAlignment = Enum.TextXAlignment.Left,
    }, f)
    local pill = new("TextButton", {
        Text = "", Size = UDim2.fromOffset(40, 20), Position = UDim2.new(1, -52, 0.5, -10),
        BackgroundColor3 = default and C.on or C.off, AutoButtonColor = false,
    }, f)
    round(pill, 10)
    local knob = new("Frame", {
        Size = UDim2.fromOffset(16, 16), BackgroundColor3 = Color3.new(1, 1, 1),
        Position = default and UDim2.fromOffset(22, 2) or UDim2.fromOffset(2, 2),
    }, pill)
    round(knob, 8)
    local val = default
    pill.MouseButton1Click:Connect(function()
        val = not val
        TS:Create(pill, TweenInfo.new(0.15), { BackgroundColor3 = val and C.on or C.off }):Play()
        TS:Create(knob, TweenInfo.new(0.15), { Position = val and UDim2.fromOffset(22, 2) or UDim2.fromOffset(2, 2) }):Play()
        cb(val)
    end)
end

local function input(parent, placeholder)
    local box = new("TextBox", {
        PlaceholderText = placeholder, Text = "", Font = Enum.Font.Gotham, TextSize = 13,
        TextColor3 = C.text, PlaceholderColor3 = C.sub, BackgroundColor3 = C.card,
        Size = UDim2.new(1, 0, 0, 34), ClearTextOnFocus = false,
    }, parent)
    round(box, 8); stroke(box)
    return box
end

-- Status
local statusLbl

-- Page: Macro
local pMacro = newPage("Macro")
statusLbl = new("TextLabel", {
    Text = "Status: Idle", Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C.sub,
    BackgroundColor3 = C.card, Size = UDim2.new(1, 0, 0, 30), TextWrapped = true,
}, pMacro)
round(statusLbl, 8)
logFn = function(msg) if statusLbl then statusLbl.Text = "Status: " .. msg end end

local recBtn
recBtn = button(pMacro, "● Mulai Rekam", function()
    State.recording = not State.recording
    if State.recording then
        State.macro, State.startTime = {}, os.clock()
        recBtn.Text = "■ Stop Rekam"; recBtn.BackgroundColor3 = C.red
        logFn("Merekam... lakukan aksi di game")
    else
        recBtn.Text = "● Mulai Rekam"; recBtn.BackgroundColor3 = C.card
        logFn(("Rekaman selesai (%d aksi)"):format(#State.macro))
    end
end)
button(pMacro, "▶ Play Macro", play, C.accent)
button(pMacro, "⏹ Stop Playback", function() State.playing = false; logFn("Dihentikan") end)
toggle(pMacro, "Loop Macro", false, function(v) State.loop = v end)

-- Page: Auto
local pAuto = newPage("Auto")
toggle(pAuto, "Auto Skip Wave", false, function(v) State.autoSkip = v end)
toggle(pAuto, "Auto Start / Vote", false, function(v) State.autoStart = v end)
toggle(pAuto, "Auto Replay", false, function(v) State.autoReplay = v end)

task.spawn(function()
    while gui.Parent do
        if State.autoStart then
            local r = getRemote(CONFIG.StartRemote)
            if r then pcall(function() if r:IsA("RemoteFunction") then r:InvokeServer() else r:FireServer() end end) end
        end
        if State.autoReplay then
            local r = getRemote(CONFIG.ReplayRemote)
            if r then pcall(function() if r:IsA("RemoteFunction") then r:InvokeServer() else r:FireServer() end end) end
        end
        if State.autoSkip then
            local r = getRemote(CONFIG.SkipWaveRemote)
            if r then pcall(function() if r:IsA("RemoteFunction") then r:InvokeServer() else r:FireServer() end end) end
        end
        task.wait(2)
    end
end)

-- Page: File
local pFile = newPage("File")
local nameBox = input(pFile, "Nama macro (contoh: map1)")
button(pFile, "💾 Simpan Macro", function()
    if nameBox.Text ~= "" then saveMacro(nameBox.Text) else logFn("Isi nama dulu") end
end, C.accent)
button(pFile, "📂 Muat Macro", function()
    if nameBox.Text ~= "" then loadMacro(nameBox.Text) else logFn("Isi nama dulu") end
end)

-- Page: Settings (Webhook + Tema)
local pSet = newPage("Settings")

local hookBox = input(pSet, "Discord Webhook URL")
hookBox.Text = State.webhook
hookBox.FocusLost:Connect(function()
    State.webhook = hookBox.Text
    saveSettings()
    logFn("Webhook disimpan")
end)

toggle(pSet, "Notifikasi Discord", State.notify, function(v)
    State.notify = v
    saveSettings()
end)

button(pSet, "📨 Tes Webhook", function()
    if State.webhook == "" then return logFn("Isi webhook dulu") end
    sendWebhook("Tes notifikasi berhasil ✅", true)
    logFn("Tes dikirim")
end)

local THEMES = {
    Ungu = Color3.fromRGB(124, 92, 255),
    Biru = Color3.fromRGB(64, 156, 255),
    Hijau = Color3.fromRGB(46, 190, 120),
    Pink = Color3.fromRGB(255, 105, 180),
}

local function applyTheme(name)
    local newCol = THEMES[name]
    if not newCol then return end
    local old = C.accent
    C.accent = newCol
    State.theme = name
    for _, o in ipairs(gui:GetDescendants()) do
        if o:IsA("UIStroke") and o.Color == old then
            o.Color = newCol
        elseif o:IsA("GuiObject") and not o:GetAttribute("NoTheme") and o.BackgroundColor3 == old then
            o.BackgroundColor3 = newCol
        end
    end
end

new("TextLabel", {
    Text = "Tema warna", Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C.sub,
    BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), TextXAlignment = Enum.TextXAlignment.Left,
}, pSet)

local row = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1 }, pSet)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, row)
for name, col in pairs(THEMES) do
    local b = new("TextButton", {
        Text = name, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = Color3.new(1, 1, 1),
        BackgroundColor3 = col, Size = UDim2.new(0.25, -5, 1, 0), AutoButtonColor = true,
    }, row)
    round(b, 8)
    b:SetAttribute("NoTheme", true)
    b.MouseButton1Click:Connect(function()
        applyTheme(name)
        saveSettings()
    end)
end

-- Tab awal
tabs["Macro"].BackgroundColor3 = C.accent
tabs["Macro"].TextColor3 = C.text
pages["Macro"].Visible = true

-- Terapkan tema tersimpan
applyTheme(State.theme)

-- Minimize & close
local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    side.Visible, content.Visible = not minimized, not minimized
    TS:Create(main, TweenInfo.new(0.2), { Size = minimized and UDim2.fromOffset(440, 36) or UDim2.fromOffset(440, 280) }):Play()
end)
closeBtn.MouseButton1Click:Connect(function()
    State.recording, State.playing, State.autoSkip, State.autoStart = false, false, false, false
    gui:Destroy()
end)
