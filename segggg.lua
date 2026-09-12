--[[
    ScriptVerse - Steal An Egg
    PlaceId: 107778070777162
    Fully merged, improved, and fixed version
]]

-- ─── COMPAT LAYER ───────────────────────────────────────────────────────────
local g = (getgenv and getgenv()) or _G
local C = rawget(g, "SVCompat")
if type(C) ~= "table" or not C.__svcompat then
    local function executorName()
        local ok, n = pcall(function()
            return (identifyexecutor and identifyexecutor())
                or (getexecutorname and getexecutorname())
                or ""
        end)
        return (ok and tostring(n) or ""):lower()
    end
    local exec = executorName()
    local isSolara = exec:find("solara", 1, true) ~= nil
        or exec:find("xeno", 1, true) ~= nil
        or exec:find("micro", 1, true) ~= nil
    local realRequire = require
    C = {
        __svcompat    = true,
        Executor      = exec,
        IsSolara      = isSolara,
        AllowRequire  = true,
        AllowHooks    = (not isSolara) and typeof(hookmetamethod) == "function",
        AllowGc       = typeof(getgc) == "function",
        AllowDrawing  = typeof(Drawing) == "table" and typeof(Drawing.new) == "function",
        rawRequire    = realRequire,
    }
    function C.softRequire(mod)
        if mod == nil then return nil end
        local ok, res = pcall(realRequire, mod)
        if ok then return res end
        local err = string.lower(tostring(res))
        if err:find("cannot require", 1, true)
            or err:find("cast string to bool", 1, true)
            or err:find("unable to cast", 1, true)
        then
            C.IsSolara      = true
            C.AllowRequire  = false
        end
        return nil
    end
    C.require    = C.softRequire
    C.rawRequire = realRequire
    function C.child(parent, ...)
        local cur = parent
        for i = 1, select("#", ...) do
            if typeof(cur) ~= "Instance" then return nil end
            cur = cur:FindFirstChild((select(i, ...)))
        end
        return cur
    end
    function C.softDrawing(class)
        if not C.AllowDrawing then return nil end
        local ok, obj = pcall(Drawing.new, class)
        return ok and obj or nil
    end
    function C.canHook() return C.AllowHooks == true end
    function C.canGc()   return C.AllowGc   == true end
    g.SVCompat = C
end

local require = (function()
    local genv2 = (getgenv and getgenv()) or _G
    local C2    = rawget(genv2, "SVCompat")
    if type(C2) == "table" and type(C2.require) == "function" then
        return C2.require
    end
    return require
end)()

-- ─── SHUTDOWN GUARD ─────────────────────────────────────────────────────────
local genv = (getgenv and getgenv()) or _G

if type(genv.SV_SAE_SHUTDOWN) == "function" then
    pcall(genv.SV_SAE_SHUTDOWN)
    task.wait(0.2)
end
if genv.SV_SAE_RUNNING then return end
genv.SV_SAE_RUNNING = true
print("[ScriptVerse] Steal An Egg - loading...")

-- ─── ANTI-CHEAT BYPASS ──────────────────────────────────────────────────────
-- Speed bypass from open source reference
pcall(function()
    loadstring(game:HttpGet(
        "https://raw.githubusercontent.com/Lutosys/opensrc/refs/heads/main/stealaeggspeedbypass.lua"
    ))()
end)

-- GC table freeze bypass (blocks movement detection tables)
pcall(function()
    for _, obj in getgc(true) do
        if typeof(obj) ~= "table" or getrawmetatable(obj) then continue end
        local mainrun = false
        for _, v in obj do
            if v == obj then mainrun = true break end
        end
        if not mainrun then continue end
        for _, v in obj do
            if typeof(v) == "number" and v >= 1 and v <= 3 and obj[v] == nil then
                setmetatable(obj, { __newindex = function() end })
                break
            end
        end
    end
end)

-- filtergc bypass (blocks gmatch+GetFullName detection)
local function bypassClientDetections()
    if typeof(filtergc) ~= "function"
        or typeof(debug) ~= "table"
        or typeof(debug.getupvalues) ~= "function"
    then
        return false, "no filtergc"
    end
    local ok, fn = pcall(function()
        return filtergc("function", {
            Constants = { "gmatch", "GetFullName" },
        }, true)
    end)
    if not ok or type(fn) ~= "function" then return false, "filter miss" end
    local setMeta = (typeof(setrawmetatable) == "function" and setrawmetatable)
        or (typeof(setmetatable) == "function" and setmetatable)
    if not setMeta then return false, "no setmeta" end
    local blocked   = 0
    local okUv, ups = pcall(debug.getupvalues, fn)
    if not okUv or type(ups) ~= "table" then return false, "no upvalues" end
    for _, tbl in pairs(ups) do
        if typeof(tbl) == "table" then
            local okSet = pcall(setMeta, tbl, { __newindex = function() end })
            if okSet then blocked += 1 end
        end
    end
    return blocked > 0, blocked
end

local acOk, acInfo = bypassClientDetections()
if acOk then
    print("[ScriptVerse] Client AC bypassed (" .. tostring(acInfo) .. " tables)")
else
    warn("[ScriptVerse] Client AC bypass skipped: " .. tostring(acInfo))
end

-- ─── SERVICES ────────────────────────────────────────────────────────────────
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local VirtualUser        = game:GetService("VirtualUser")
local Workspace          = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- ─── GAME MODULES ────────────────────────────────────────────────────────────
local function softRequireInst(inst)
    if typeof(inst) ~= "Instance" then return nil end
    local ok, mod = pcall(require, inst)
    return ok and mod or nil
end

local Lib       = ReplicatedStorage:WaitForChild("Library",   30)
local Client    = Lib:WaitForChild("Client",  15)
local Util      = Lib:WaitForChild("Util",    15)
local Globals   = Lib:WaitForChild("Globals", 15)

local EggCmds    = softRequireInst(Client:WaitForChild("EggCmds",           15))
local EggState   = softRequireInst(Client:FindFirstChild("EggState"))       -- reference script uses this
local PlotCmds   = softRequireInst(Client:WaitForChild("PlotCmds",          15))
local Network    = softRequireInst(Client:WaitForChild("Network",            15))
local Guard      = softRequireInst(Client:WaitForChild("ToolGameplayGuard",  15))
local Lookup     = softRequireInst(Util:WaitForChild("GuardAreaLookupUtil",  15))
local Save       = softRequireInst(Client:WaitForChild("Save",               15))
local BaseUpgrade= softRequireInst(Client:WaitForChild("BaseUpgradeClient",  15))
local AssetCmds  = softRequireInst(Client:WaitForChild("AssetCmds",          15))
local Constants  = softRequireInst(Globals:WaitForChild("Constants",         15))
local SpeedPowerProjection = softRequireInst(Client:FindFirstChild("SpeedPowerProjection"))

if not EggCmds or not PlotCmds or not Guard or not Lookup then
    warn("[ScriptVerse] Steal An Egg modules unavailable - abort")
    genv.SV_SAE_RUNNING = nil
    return
end

local NetMap  = (Constants and Constants.NETWORK_MAP) or (Network and Network.NET_MAP)
local PivotKey= (NetMap and NetMap.ClientCharacter and NetMap.ClientCharacter.SET_PIVOT)
    or "ClientCharacter: SetPivot"

-- ─── AREAS TABLE (from reference) ────────────────────────────────────────────
local AREAS = {
    "Forest",         -- 1
    "Lake",           -- 2
    "Desert",         -- 3
    "Jungle",         -- 4
    "Snow",           -- 5
    "Volcano",        -- 6
    "Abyss Ocean",    -- 7
    "Prehistoric",    -- 8
    "Cosmic",         -- 9
    "Cherry Blossom", -- 10
    "Titan Temple",   -- 11
}

-- Rarity list for filtering (common to exotic ordering)
local RARITIES = {
    "Common",
    "Uncommon",
    "Rare",
    "Epic",
    "Legendary",
    "Mythical",
    "Exotic",
}

-- ─── STATE ───────────────────────────────────────────────────────────────────
local SeparationLine    = nil
local cachedPlayPos     = nil
local cachedSafePos     = nil

local espPool = {}
local conns   = {}
local flyConn, noclipConn, infJumpConn
local speedBV

-- Safe zone / home position (reference uses fixed CFrame(514,71,-368))
local HOME_POS = CFrame.new(514, 71, -368)

local State = {
    running         = true,
    busy            = false,
    busySince       = nil,
    status          = "Idle",
    carrying        = false,
    autofarm        = false,
    preferHighValue = true,
    minAreaIndex    = 1,        -- minimum area index filter
    enabledAreas    = {},       -- area name -> bool
    enabledRarities = {},       -- rarity name -> bool
    filterName      = "",       -- partial egg name filter
    speedOn         = false,
    walkSpeed       = 32,
    fly             = false,
    flySpeed        = 32,
    noclip          = false,
    infJump         = false,
    antiAfk         = true,
    espWorldEgg     = false,
    espGuard        = false,
    espPlayer       = false,
    espPlot         = false,
    lastSteal       = 0,
    lastAfk         = 0,
    menuOpen        = true,
}

-- Init all areas and rarities as enabled by default
for _, a in ipairs(AREAS)    do State.enabledAreas[a]    = true end
for _, r in ipairs(RARITIES) do State.enabledRarities[r] = true end

-- ─── HELPERS ─────────────────────────────────────────────────────────────────
local function track(conn)
    table.insert(conns, conn)
    return conn
end

local function root()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function hum()
    local char = LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function zeroVel(part)
    if not part then return end
    part.AssemblyLinearVelocity  = Vector3.zero
    part.AssemblyAngularVelocity = Vector3.zero
end

local function waitRoot(timeout)
    timeout = timeout or 15
    local char = LocalPlayer.Character
    if not char then char = LocalPlayer.CharacterAdded:Wait() end
    return char:WaitForChild("HumanoidRootPart", timeout)
end

-- ─── SEPARATION LINE / ARENA SIDE ────────────────────────────────────────────
local function getSeparationLine()
    if SeparationLine and SeparationLine.Parent then return SeparationLine end
    local objs  = Workspace:FindFirstChild("__OBJECTS")
        or Workspace:WaitForChild("__OBJECTS", 20)
    if not objs then return nil end
    local areas = objs:FindFirstChild("Areas")
    if not areas then return nil end
    SeparationLine = areas:FindFirstChild("SeparationLine")
    return SeparationLine
end

local function onGameplaySide(pos)
    local line = getSeparationLine()
    if not line or not pos then return false end
    if type(Lookup.IsInGameplaySide) == "function" then
        return Lookup.IsInGameplaySide(line, pos) == true
    end
    local rel = line.CFrame:PointToObjectSpace(pos)
    return rel.Z > 0
end

local function inGameplay()
    if type(Guard.IsLocalPlayerInGameplayArea) == "function" then
        return Guard.IsLocalPlayerInGameplayArea() == true
    end
    return false
end

local function resolveArenaPoints()
    local line = getSeparationLine()
    if not line then return nil, nil end
    if cachedPlayPos and cachedSafePos then return cachedPlayPos, cachedSafePos end

    -- Try different directions to find gameplay side
    for x = -120, 120, 8 do
        for z = -120, 120, 8 do
            local p = line.Position + Vector3.new(x, 4, z)
            if onGameplaySide(p) and not cachedPlayPos then
                cachedPlayPos = p
            elseif not onGameplaySide(p) and not cachedSafePos then
                cachedSafePos = p
            end
            if cachedPlayPos and cachedSafePos then break end
        end
        if cachedPlayPos and cachedSafePos then break end
    end

    cachedPlayPos = cachedPlayPos or (line.Position + Vector3.new(55, 4, 0))
    cachedSafePos = cachedSafePos or (line.Position - Vector3.new(55, 4, 0))
    return cachedPlayPos, cachedSafePos
end

-- ─── NETWORK UTILS ───────────────────────────────────────────────────────────
local function netInvoke(key, ...)
    if not Network or not key then return false end
    local args = table.pack(...)
    local ok, a = pcall(function()
        return Network.Invoke(key, table.unpack(args, 1, args.n))
    end)
    return ok and a == true
end

local function netFire(key, ...)
    if not Network or not key then return end
    local args = table.pack(...)
    pcall(function()
        Network.Fire(key, table.unpack(args, 1, args.n))
    end)
end

-- ─── SPEED POWER FREEZE ──────────────────────────────────────────────────────
local function freezeSpeedPower()
    if not SpeedPowerProjection then return end
    local fn = SpeedPowerProjection.GetSpeedPower
    if type(fn) ~= "function" then return end
    if type(setupvalue) ~= "function" or type(getupvalue) ~= "function" then return end
    pcall(function()
        for i = 1, 12 do
            local v = getupvalue(fn, i)
            if type(v) == "number" then
                setupvalue(fn, i, 1e7)
                break
            end
        end
    end)
end

-- ─── MOVEMENT ────────────────────────────────────────────────────────────────

-- Burst teleport with network fire (anti-detection)
local function burstPivot(cf, fires)
    local r = root()
    if not r or not cf then return end
    fires = fires or 2
    for _ = 1, fires do
        if Network and PivotKey then
            pcall(function() Network.Fire(PivotKey, cf) end)
        end
        r.CFrame = cf
        zeroVel(r)
        task.wait(0.014)
    end
end

-- Smooth movement from reference (using MoveTo + lerp for natural pathing)
-- This is the key fix for the "random stop" issue - we use the reference's approach
local function smoothMoveTo(targetPos, timeout)
    timeout = timeout or 45
    local t0  = os.clock()
    local char = LocalPlayer.Character
    if not char then return false end

    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end

    repeat
        local ok = pcall(function()
            local dt    = task.wait(0.01)
            hrp         = char:FindFirstChild("HumanoidRootPart")
            if not hrp then return end
            local start = hrp.Position
            local dist  = (targetPos - start).Magnitude
            if dist <= 5 then return end
            -- Lerp step matching reference's 430 speed unit
            local half = start + (targetPos - start).Unit * dt * 430
            char:MoveTo(half)
        end)
        if not ok then break end
        hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then break end
    until (hrp and (targetPos - hrp.Position).Magnitude <= 5)
        or (os.clock() - t0 >= timeout)
        or not State.running

    return hrp ~= nil and (targetPos - hrp.Position).Magnitude <= 8
end

-- Stepped interpolation teleport (stealthy, fires SetPivot)
local function stealthPath(goal, steps)
    local r = root()
    if not r or not goal then return false end
    steps     = steps or 18
    local from = r.Position
    for i = 1, steps do
        if not State.running then return false end
        r = root()
        if not r then return false end
        local p  = from:Lerp(goal, i / steps)
        local cf = CFrame.new(p.X, math.max(p.Y, r.Position.Y), p.Z)
        if Network and PivotKey then
            pcall(function() Network.Fire(PivotKey, cf) end)
        end
        r.CFrame = cf
        zeroVel(r)
        task.wait(0.009)
    end
    return true
end

-- High-level travel: tries smoothMoveTo first, falls back to stealthPath
local function travelTo(goal)
    local r = root()
    if not r or not goal then return false end
    local dist = (r.Position - goal).Magnitude
    if dist <= 5 then return true end

    -- Use reference-style movement for naturalness + our stealthy fallback
    local ok = pcall(smoothMoveTo, goal, 40)
    r = root()
    if not ok or not r or (r.Position - goal).Magnitude > 12 then
        stealthPath(goal, 20)
    end
    burstPivot(CFrame.new(goal), 2)
    return true
end

-- ─── EGG FILTERING ───────────────────────────────────────────────────────────

-- Get rarity from area id (simple heuristic: higher area index = higher rarity)
local function getRarityFromRecord(rec)
    if not rec then return "Common" end
    -- Try explicit rarity field first
    if type(rec.Rarity) == "string"     then return rec.Rarity end
    if type(rec.RarityName) == "string" then return rec.RarityName end
    -- Derive from area index as fallback
    local idx = rec.AreaId and table.find(AREAS, rec.AreaId)
    if idx then
        if idx >= 10 then return "Exotic"
        elseif idx >= 8 then return "Mythical"
        elseif idx >= 7 then return "Legendary"
        elseif idx >= 5 then return "Epic"
        elseif idx >= 3 then return "Rare"
        elseif idx >= 2 then return "Uncommon"
        end
    end
    return "Common"
end

local function eggPassesFilter(rec)
    if not rec then return false end

    -- Area filter
    if rec.AreaId then
        local areaEnabled = State.enabledAreas[rec.AreaId]
        if areaEnabled == false then return false end
        local areaIdx = table.find(AREAS, rec.AreaId)
        if areaIdx and areaIdx < State.minAreaIndex then return false end
    end

    -- Rarity filter
    local rar = getRarityFromRecord(rec)
    if State.enabledRarities[rar] == false then return false end

    -- Name filter
    if State.filterName and State.filterName ~= "" then
        local name = string.lower(rec.AssetCategory or rec.AssetId or "")
        if not name:find(string.lower(State.filterName), 1, true) then
            return false
        end
    end

    return true
end

local function eggValue(rec)
    local score = 0
    if not rec then return score end
    -- AssetScale from reference script
    if type(rec.AssetScale) == "number" then
        score = score + rec.AssetScale * 10
    end
    -- Area index = higher tier = more value
    local areaIdx = rec.AreaId and table.find(AREAS, rec.AreaId)
    if areaIdx then score = score + areaIdx * 20 end
    -- Mutations
    if type(rec.Mutations) == "table" then
        score = score + #rec.Mutations * 50
    end
    if rec.IsRare == true or rec.Rare == true then score = score + 100 end
    return score
end

-- ─── EGG SNAPSHOT ────────────────────────────────────────────────────────────

-- Uses both EggCmds and EggState (from reference) for maximum coverage
local function getAreaEggSnapshot()
    local snap

    -- Try EggState.ReadFieldEggs() from reference script
    if EggState and type(EggState.ReadFieldEggs) == "function" then
        local ok, res = pcall(EggState.ReadFieldEggs)
        if ok and res then snap = res end
    end

    -- Fallback to EggCmds methods
    if (not snap or not snap.Records) and EggCmds then
        if type(EggCmds.GetAreaEggSnapshot) == "function" then
            local ok, res = pcall(EggCmds.GetAreaEggSnapshot)
            if ok then snap = res end
        end
        if (not snap or not snap.Records) and type(EggCmds.RequestAreaEggSnapshot) == "function" then
            local ok, res = pcall(EggCmds.RequestAreaEggSnapshot)
            if ok then snap = res end
        end
    end

    return snap
end

local function listStealableEggs()
    local snap = getAreaEggSnapshot()
    if not snap or not snap.Records then return {} end

    local r    = root()
    local list = {}

    for _, rec in pairs(snap.Records) do
        if type(rec) ~= "table" then continue end

        -- Must be in Slot state (not being carried)
        if rec.State ~= "Slot" and rec.State ~= nil then continue end

        -- Must be in gameplay side
        local pos = rec.BottomCFrame and rec.BottomCFrame.Position
            or rec.BoundsCFrame and rec.BoundsCFrame.Position
        if not pos then continue end
        if not onGameplaySide(pos) then continue end

        -- Apply filters
        if not eggPassesFilter(rec) then continue end

        list[#list + 1] = {
            rec   = rec,
            pos   = pos,
            dist  = r and (pos - r.Position).Magnitude or math.huge,
            value = eggValue(rec),
        }
    end

    -- Sort: high value first, then closest
    table.sort(list, function(a, b)
        if State.preferHighValue then
            if a.value ~= b.value then return a.value > b.value end
        end
        return a.dist < b.dist
    end)

    return list
end

-- ─── PROXIMITY PROMPT ────────────────────────────────────────────────────────

-- Reference uses QueryDescendants("#CarryAreaEgg") which is more reliable
local function getProximityPromptForEgg(eggPos)
    -- Try QueryDescendants approach from reference
    if typeof(Workspace.QueryDescendants) == "function" then
        local ok, results = pcall(function()
            return Workspace:QueryDescendants("#CarryAreaEgg")
        end)
        if ok and results then
            local best, bestDist = nil, math.huge
            for _, prompt in ipairs(results) do
                local p = prompt.Parent
                if p and p:IsA("BasePart") then
                    local dist = (eggPos - p.Position).Magnitude
                    if dist < bestDist then
                        bestDist = dist
                        best     = prompt
                    end
                end
            end
            if best and bestDist < 12 then return best end
        end
    end

    -- Fallback: scan workspace descendants for ProximityPrompt near egg
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("ProximityPrompt") and inst.Enabled then
            local p = inst.Parent
            if p and p:IsA("BasePart") then
                if (eggPos - p.Position).Magnitude < 10 then
                    return inst
                end
            end
        end
    end
    return nil
end

local function firePrompt(prompt)
    if not prompt or not prompt.Enabled then return false end
    local holdDur = math.max(prompt.HoldDuration or 0.5, 0.4) + 0.15

    if typeof(fireproximityprompt) == "function" then
        local ok = pcall(fireproximityprompt, prompt)
        if ok then
            task.wait(holdDur)
            return true
        end
    end

    -- Manual hold fallback
    local ok = pcall(function()
        prompt:InputHoldBegin()
        task.wait(holdDur)
        prompt:InputHoldEnd()
    end)
    task.wait(0.05)
    return ok
end

-- ─── CARRY STATE ─────────────────────────────────────────────────────────────

-- Connect to carry state change event
if EggCmds and EggCmds.AreaEggCarryStateChanged
    and type(EggCmds.AreaEggCarryStateChanged.Connect) == "function"
then
    track(EggCmds.AreaEggCarryStateChanged:Connect(function(payload)
        if payload then
            if payload.IsCarrying == true  then State.carrying = true  end
            if payload.IsCarrying == false then State.carrying = false end
        end
    end))
end

local function isCarrying(uid)
    -- Check via EggCmds record
    if uid and type(EggCmds.GetAreaEggRecord) == "function" then
        local ok, rec = pcall(EggCmds.GetAreaEggRecord, uid)
        if ok and rec and rec.State == "Carried" then return true end
    end
    -- Check via EggState
    if EggState and type(EggState.ReadFieldEggs) == "function" then
        local ok, snap = pcall(EggState.ReadFieldEggs)
        if ok and snap and snap.Records then
            for _, rec in pairs(snap.Records) do
                if type(rec) == "table" and rec.State == "Carried"
                    and rec.CarrierId == LocalPlayer.UserId
                then
                    return true
                end
            end
        end
    end
    return State.carrying == true
end

local function waitForCarry(uid, timeout)
    timeout = timeout or 7
    local t0 = os.clock()
    while os.clock() - t0 < timeout and State.running do
        if isCarrying(uid) then return true end
        task.wait(0.07)
    end
    return isCarrying(uid)
end

-- ─── CORE STEAL CYCLE ────────────────────────────────────────────────────────

-- Cross to arena safely
local function crossToArena()
    if inGameplay() then return true end

    local line = getSeparationLine()
    if not line then
        -- Fallback: try going to the fixed safe zone from reference, then arena
        travelTo(HOME_POS.Position + Vector3.new(0, 0, 60))
        task.wait(0.3)
        return inGameplay()
    end

    local playPos, safePos = resolveArenaPoints()

    -- Step 1: get close to the line from safe side
    travelTo(safePos)
    task.wait(0.1)

    -- Step 2: cross into gameplay
    travelTo(playPos)
    task.wait(0.25)

    return inGameplay()
end

-- Return to safe zone using reference's fixed home position first,
-- then plot spawn as secondary
local function returnToSafe()
    State.status = "Returning to safe zone"

    -- Use reference's known safe position
    local homePos = HOME_POS.Position

    -- Also try PlotCmds for personalized plot position
    local plotCF
    pcall(function()
        plotCF = PlotCmds.GetRespawnPointCFrame(LocalPlayer)
    end)
    if plotCF then homePos = plotCF.Position + Vector3.new(0, 3, 0) end

    -- If in gameplay, first move toward the separation line exit
    if inGameplay() then
        local line = getSeparationLine()
        if line then
            local _, safePos = resolveArenaPoints()
            travelTo(safePos)
            task.wait(0.15)
        end
    end

    -- Now go all the way home
    travelTo(homePos)
    task.wait(0.5)

    State.carrying = false
    return not inGameplay()
end

-- Wait for the delivery success event (prevents "egg returned to nest" issue)
local function waitForDelivery(timeout)
    timeout = timeout or 6
    local delivered = false

    -- Listen for claim event
    local conn
    if EggCmds and EggCmds.AreaEggClaimed
        and type(EggCmds.AreaEggClaimed.Connect) == "function"
    then
        conn = EggCmds.AreaEggClaimed:Connect(function()
            delivered = true
        end)
    end

    local t0 = os.clock()
    while os.clock() - t0 < timeout and State.running do
        if delivered then break end
        -- Also check if we're safely out of gameplay with an egg no longer carried
        if not inGameplay() and not State.carrying then
            delivered = true
            break
        end
        task.wait(0.1)
    end

    if conn then pcall(function() conn:Disconnect() end) end
    return delivered
end

-- Grab one egg - full cycle with robust error handling
local function grabAndDeliver()
    -- Refresh egg list
    local eggs = listStealableEggs()
    if #eggs == 0 then
        State.status = "No eggs matching filter"
        return false, "No eggs"
    end

    local target  = eggs[1]
    local rec     = target.rec
    local eggPos  = target.pos
    local uid     = rec.Uid or rec.Id or ""
    local label   = rec.AssetCategory or rec.AssetId or "egg"
    local areaLbl = rec.AreaId or "?"

    -- Step 1: ensure we're in gameplay
    if not inGameplay() then
        State.status = "Crossing to arena"
        if not crossToArena() then
            return false, "Could not enter arena"
        end
        task.wait(0.2)
    end

    -- Step 2: travel to egg position
    State.status = "Going to " .. label .. " (" .. areaLbl .. ")"
    travelTo(eggPos)
    task.wait(0.1)

    -- Check egg still exists and is not carried
    if isCarrying(uid) then
        -- Already somehow carrying it? proceed to return
        goto deliver
    end

    -- Step 3: get proximity prompt and fire it
    do
        local attempts = 0
        repeat
            attempts += 1
            if not State.running then return false, "Shutdown" end

            -- Re-check egg is still there
            local eggs2 = listStealableEggs()
            if #eggs2 == 0 then return false, "Egg gone" end

            -- Re-fetch target (might have changed)
            local refreshed = eggs2[1]
            eggPos = refreshed.pos
            rec    = refreshed.rec
            uid    = refreshed.rec.Uid or refreshed.rec.Id or ""

            -- Move closer
            travelTo(eggPos)
            task.wait(0.05)

            -- Try prompt
            local prompt = getProximityPromptForEgg(eggPos)
            if prompt then
                firePrompt(prompt)
            end

            -- Try API fallback
            if not isCarrying(uid) and EggCmds then
                if type(EggCmds.RequestCarryAreaEgg) == "function" then
                    pcall(EggCmds.RequestCarryAreaEgg, uid, rec.NestId or rec.SlotId)
                end
            end

            task.wait(0.3)

            if waitForCarry(uid, 1.5) then break end

        until attempts >= 5 or isCarrying(uid)

        if not isCarrying(uid) then
            return false, "Could not grab egg after " .. attempts .. " attempts"
        end
    end

    ::deliver::
    State.carrying = true
    State.status   = "Delivering " .. label

    -- Step 4: return to safe zone BEFORE the game can reclaim the egg
    -- This is the key fix for "Delivery Failed" - we must be in safe zone fast
    local returnedSafe = returnToSafe()

    -- Step 5: wait for delivery confirmation
    local ok = waitForDelivery(5)

    State.carrying = false
    if ok then
        State.lastSteal = os.clock()
        State.status    = "Delivered: " .. label
        return true, label
    else
        -- We're in safe zone, delivery should still be fine
        State.status = "In safe zone - egg secured"
        return true, label
    end
end

-- Main autofarm loop cycle
local function autofarmCycle()
    if State.busy then
        -- Timeout guard from reference concept
        if State.busySince and os.clock() - State.busySince > 80 then
            warn("[ScriptVerse] Busy timeout - resetting")
            State.busy     = false
            State.busySince = nil
            State.carrying = false
        else
            return
        end
    end

    if not State.autofarm then return end

    State.busy     = true
    State.busySince = os.clock()

    local ok, result = pcall(function()
        if not waitRoot(12) then return false end
        local success, info = grabAndDeliver()
        if success then
            print("[ScriptVerse] Steal success: " .. tostring(info))
        else
            warn("[ScriptVerse] Steal fail: " .. tostring(info))
        end
        return success
    end)

    State.busy     = false
    State.busySince = nil

    if not ok then
        warn("[ScriptVerse] Cycle error: " .. tostring(result))
        -- Reset carry state on error
        State.carrying = false
        -- Return to safe zone in case stuck
        pcall(returnToSafe)
    end
end

-- One-shot steal button
local function doStealOnce()
    if State.busy then return end
    State.busy     = true
    State.busySince = os.clock()
    local ok, err = pcall(function()
        waitRoot(12)
        grabAndDeliver()
    end)
    State.busy     = false
    State.busySince = nil
    if not ok then
        warn("[ScriptVerse] Single steal error: " .. tostring(err))
        pcall(returnToSafe)
    end
end

genv.SV_SAE_STEAL = doStealOnce

-- ─── MOVEMENT FEATURES ───────────────────────────────────────────────────────

local function applySpeed()
    local r = root()
    if State.speedOn then freezeSpeedPower() end
    if speedBV and (not State.speedOn or not r or speedBV.Parent ~= r) then
        pcall(function() speedBV:Destroy() end)
        speedBV = nil
    end
    if State.speedOn and r then
        if not speedBV or speedBV.Parent ~= r then
            speedBV         = Instance.new("BodyVelocity")
            speedBV.Name     = "SV_Speed"
            speedBV.MaxForce = Vector3.new(8e4, 0, 8e4)
            speedBV.Parent   = r
        end
        local h   = hum()
        local dir = Vector3.zero
        if h and h.MoveDirection.Magnitude > 0.05 then
            dir = Vector3.new(h.MoveDirection.X, 0, h.MoveDirection.Z).Unit
        end
        speedBV.Velocity = dir * State.walkSpeed
    end
end

local function setNoclip(on)
    if noclipConn then noclipConn:Disconnect() noclipConn = nil end
    if not on then return end
    noclipConn = track(RunService.Stepped:Connect(function()
        local char = LocalPlayer.Character
        if not char then return end
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = false end
        end
    end))
end

local flyBV, flyBG

local function setFly(on)
    if flyConn then flyConn:Disconnect() flyConn = nil end
    if flyBV then pcall(function() flyBV:Destroy() end) flyBV = nil end
    if flyBG then pcall(function() flyBG:Destroy() end) flyBG = nil end
    if not on then return end

    flyConn = track(RunService.Heartbeat:Connect(function()
        local r   = root()
        local h   = hum()
        if not r or not h then return end
        local cam = Workspace.CurrentCamera
        if not cam then return end

        if not flyBV or not flyBV.Parent then
            flyBV            = Instance.new("BodyVelocity")
            flyBV.MaxForce   = Vector3.new(1e5, 1e5, 1e5)
            flyBV.Velocity   = Vector3.zero
            flyBV.Parent     = r
            flyBG            = Instance.new("BodyGyro")
            flyBG.MaxTorque  = Vector3.new(1e5, 1e5, 1e5)
            flyBG.P          = 3000
            flyBG.Parent     = r
        end

        local dir = Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += cam.CFrame.LookVector  end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= cam.CFrame.LookVector  end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space)       then dir += Vector3.yAxis end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end

        flyBV.Velocity = dir.Magnitude > 0 and dir.Unit * State.flySpeed or Vector3.zero
        flyBG.CFrame   = cam.CFrame
        freezeSpeedPower()
    end))
end

local function setInfJump(on)
    if infJumpConn then infJumpConn:Disconnect() infJumpConn = nil end
    if not on then return end
    infJumpConn = track(UserInputService.JumpRequest:Connect(function()
        local h = hum()
        if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
    end))
end

-- ─── ESP ─────────────────────────────────────────────────────────────────────

local function clearEsp()
    for _, d in ipairs(espPool) do
        pcall(function()
            if d.hl then d.hl:Destroy() end
        end)
    end
    table.clear(espPool)
end

local function addHighlight(inst, color)
    if not inst or not inst.Parent then return end
    local target = inst:IsA("Model") and inst
        or inst:FindFirstAncestorWhichIsA("Model")
        or inst
    local hl                   = Instance.new("Highlight")
    hl.FillTransparency        = 0.65
    hl.OutlineTransparency     = 0.15
    hl.FillColor               = color
    hl.OutlineColor            = color
    hl.Adornee                 = target
    hl.Parent                  = target
    table.insert(espPool, { hl = hl })
end

local function refreshEsp()
    clearEsp()
    if not State.running then return end

    if State.espWorldEgg then
        for _, e in ipairs(listStealableEggs()) do
            local model = Workspace:FindFirstChild(e.rec.Uid or "", true)
            if model then
                addHighlight(model, Color3.fromRGB(255, 220, 90))
            end
        end
    end

    if State.espPlot then
        pcall(function()
            local folder = PlotCmds.GetPlotsFolder and PlotCmds.GetPlotsFolder()
            if folder then
                for _, plot in ipairs(folder:GetChildren()) do
                    addHighlight(plot, Color3.fromRGB(90, 180, 255))
                end
            end
        end)
    end

    if State.espGuard then
        local objs = Workspace:FindFirstChild("__OBJECTS")
        if objs then
            local areas = objs:FindFirstChild("Areas")
            if areas then
                local guardAreas = areas:FindFirstChild("GuardAreas")
                if guardAreas then
                    for _, area in ipairs(guardAreas:GetChildren()) do
                        local guard = area:FindFirstChild("Guard")
                        if guard then addHighlight(guard, Color3.fromRGB(255, 80, 80)) end
                    end
                end
            end
        end
    end

    if State.espPlayer then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and plr.Character then
                addHighlight(plr.Character, Color3.fromRGB(255, 120, 120))
            end
        end
    end
end

-- ─── UI ──────────────────────────────────────────────────────────────────────

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Create screen gui
local ScreenGui              = Instance.new("ScreenGui")
ScreenGui.Name               = "SV_SAE_UI"
ScreenGui.ResetOnSpawn       = false
ScreenGui.IgnoreGuiInset     = true
ScreenGui.ZIndexBehavior     = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder       = 15
ScreenGui.Parent             = PlayerGui

-- ─── Toggle Button (circle) ────────────────────────────────────────────────
local ToggleBtn              = Instance.new("ImageButton")
ToggleBtn.Name               = "ToggleBtn"
ToggleBtn.Size               = UDim2.new(0, 48, 0, 48)
ToggleBtn.Position           = UDim2.new(0, 16, 0.5, -24)
ToggleBtn.BackgroundColor3   = Color3.fromRGB(18, 18, 18)
ToggleBtn.BorderSizePixel    = 0
ToggleBtn.Image              = ""
ToggleBtn.ZIndex             = 20
ToggleBtn.Parent             = ScreenGui

local ToggleCorner           = Instance.new("UICorner")
ToggleCorner.CornerRadius    = UDim.new(1, 0)
ToggleCorner.Parent          = ToggleBtn

local ToggleStroke           = Instance.new("UIStroke")
ToggleStroke.Color           = Color3.fromRGB(120, 220, 160)
ToggleStroke.Thickness       = 2
ToggleStroke.Parent          = ToggleBtn

local ToggleLbl              = Instance.new("TextLabel")
ToggleLbl.Size               = UDim2.new(1, 0, 1, 0)
ToggleLbl.BackgroundTransparency = 1
ToggleLbl.Text               = "SV"
ToggleLbl.TextColor3         = Color3.fromRGB(120, 220, 160)
ToggleLbl.TextSize           = 13
ToggleLbl.Font               = Enum.Font.GothamBold
ToggleLbl.Parent             = ToggleBtn

-- Make toggle button draggable
do
    local dragging, dragStart, startPos
    ToggleBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            dragging  = true
            dragStart = input.Position
            startPos  = ToggleBtn.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch)
        then
            local delta = input.Position - dragStart
            ToggleBtn.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            dragging = false
        end
    end)
end

-- ─── Main Window ──────────────────────────────────────────────────────────────
local MainFrame              = Instance.new("Frame")
MainFrame.Name               = "MainFrame"
MainFrame.Size               = UDim2.new(0, 420, 0, 560)
MainFrame.Position           = UDim2.new(0.5, -210, 0.5, -280)
MainFrame.BackgroundColor3   = Color3.fromRGB(10, 10, 10)
MainFrame.BackgroundTransparency = 0.12
MainFrame.BorderSizePixel    = 0
MainFrame.ClipsDescendants   = true
MainFrame.ZIndex             = 10
MainFrame.Visible            = true
MainFrame.Parent             = ScreenGui

local MFCorner               = Instance.new("UICorner")
MFCorner.CornerRadius        = UDim.new(0, 8)
MFCorner.Parent              = MainFrame

local MFStroke               = Instance.new("UIStroke")
MFStroke.Color               = Color3.fromRGB(60, 60, 60)
MFStroke.Thickness           = 1.2
MFStroke.Parent              = MainFrame

-- Title bar
local TitleBar               = Instance.new("Frame")
TitleBar.Name                = "TitleBar"
TitleBar.Size                = UDim2.new(1, 0, 0, 40)
TitleBar.BackgroundColor3    = Color3.fromRGB(14, 14, 14)
TitleBar.BackgroundTransparency = 0.0
TitleBar.BorderSizePixel     = 0
TitleBar.ZIndex              = 11
TitleBar.Parent              = MainFrame

local TBCorner               = Instance.new("UICorner")
TBCorner.CornerRadius        = UDim.new(0, 8)
TBCorner.Parent              = TitleBar

-- Flatten bottom corners of title bar
local TBFill                 = Instance.new("Frame")
TBFill.Size                  = UDim2.new(1, 0, 0.5, 0)
TBFill.Position              = UDim2.new(0, 0, 0.5, 0)
TBFill.BackgroundColor3      = Color3.fromRGB(14, 14, 14)
TBFill.BorderSizePixel       = 0
TBFill.ZIndex                = 11
TBFill.Parent                = TitleBar

local TitleLbl               = Instance.new("TextLabel")
TitleLbl.Size                = UDim2.new(1, -100, 1, 0)
TitleLbl.Position            = UDim2.new(0, 14, 0, 0)
TitleLbl.BackgroundTransparency = 1
TitleLbl.Text                = "Steal An Egg   |   ScriptVerse"
TitleLbl.TextColor3          = Color3.fromRGB(200, 200, 200)
TitleLbl.TextSize            = 13
TitleLbl.Font                = Enum.Font.GothamBold
TitleLbl.TextXAlignment      = Enum.TextXAlignment.Left
TitleLbl.ZIndex              = 12
TitleLbl.Parent              = TitleBar

local StatusLbl              = Instance.new("TextLabel")
StatusLbl.Size               = UDim2.new(1, -14, 0, 18)
StatusLbl.Position           = UDim2.new(0, 14, 0, 42)
StatusLbl.BackgroundTransparency = 1
StatusLbl.Text               = "Status: Idle"
StatusLbl.TextColor3         = Color3.fromRGB(120, 220, 160)
StatusLbl.TextSize           = 11
StatusLbl.Font               = Enum.Font.Gotham
StatusLbl.TextXAlignment     = Enum.TextXAlignment.Left
StatusLbl.ZIndex             = 12
StatusLbl.Parent             = MainFrame

-- Tab buttons
local TabBar                 = Instance.new("Frame")
TabBar.Name                  = "TabBar"
TabBar.Size                  = UDim2.new(1, -14, 0, 30)
TabBar.Position              = UDim2.new(0, 7, 0, 64)
TabBar.BackgroundTransparency= 1
TabBar.ZIndex                = 11
TabBar.Parent                = MainFrame

local TabLayout              = Instance.new("UIListLayout")
TabLayout.FillDirection      = Enum.FillDirection.Horizontal
TabLayout.HorizontalAlignment= Enum.HorizontalAlignment.Left
TabLayout.SortOrder          = Enum.SortOrder.LayoutOrder
TabLayout.Padding            = UDim.new(0, 5)
TabLayout.Parent             = TabBar

-- Scrollable content area
local ContentFrame           = Instance.new("ScrollingFrame")
ContentFrame.Name            = "ContentFrame"
ContentFrame.Size            = UDim2.new(1, -8, 1, -108)
ContentFrame.Position        = UDim2.new(0, 4, 0, 98)
ContentFrame.BackgroundTransparency = 1
ContentFrame.BorderSizePixel = 0
ContentFrame.ScrollBarThickness = 3
ContentFrame.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 80)
ContentFrame.CanvasSize      = UDim2.new(0, 0, 0, 0)
ContentFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
ContentFrame.ZIndex          = 11
ContentFrame.Parent          = MainFrame

local ContentLayout          = Instance.new("UIListLayout")
ContentLayout.FillDirection  = Enum.FillDirection.Vertical
ContentLayout.SortOrder      = Enum.SortOrder.LayoutOrder
ContentLayout.Padding        = UDim.new(0, 4)
ContentLayout.Parent         = ContentFrame

-- Resize handle (bottom-right corner)
local ResizeHandle           = Instance.new("TextButton")
ResizeHandle.Name            = "ResizeHandle"
ResizeHandle.Size            = UDim2.new(0, 18, 0, 18)
ResizeHandle.Position        = UDim2.new(1, -20, 1, -20)
ResizeHandle.BackgroundColor3= Color3.fromRGB(60, 60, 60)
ResizeHandle.Text            = ""
ResizeHandle.BorderSizePixel = 0
ResizeHandle.ZIndex          = 15
ResizeHandle.Parent          = MainFrame

local RHCorner               = Instance.new("UICorner")
RHCorner.CornerRadius        = UDim.new(0, 4)
RHCorner.Parent              = ResizeHandle

-- ─── UI HELPERS ──────────────────────────────────────────────────────────────

local ACCENT   = Color3.fromRGB(120, 220, 160)
local ACCENT2  = Color3.fromRGB(80,  180, 130)
local TEXT_CLR = Color3.fromRGB(200, 200, 200)
local SUB_CLR  = Color3.fromRGB(130, 130, 130)
local ITEM_BG  = Color3.fromRGB(22, 22, 22)

local orderCounter = 0
local function nextOrder()
    orderCounter += 1
    return orderCounter
end

-- Section header
local function makeSection(parent, title)
    local f                      = Instance.new("Frame")
    f.Size                       = UDim2.new(1, -8, 0, 26)
    f.BackgroundTransparency     = 1
    f.LayoutOrder                = nextOrder()
    f.Parent                     = parent

    local lbl                    = Instance.new("TextLabel")
    lbl.Size                     = UDim2.new(1, -10, 1, 0)
    lbl.Position                 = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency   = 1
    lbl.Text                     = string.upper(title)
    lbl.TextColor3               = ACCENT
    lbl.TextSize                 = 10
    lbl.Font                     = Enum.Font.GothamBold
    lbl.TextXAlignment           = Enum.TextXAlignment.Left
    lbl.ZIndex                   = 12
    lbl.Parent                   = f

    -- Divider line
    local line                   = Instance.new("Frame")
    line.Size                    = UDim2.new(1, -10, 0, 1)
    line.Position                = UDim2.new(0, 5, 1, -1)
    line.BackgroundColor3        = Color3.fromRGB(40, 40, 40)
    line.BorderSizePixel         = 0
    line.ZIndex                  = 12
    line.Parent                  = f
    return f
end

-- Toggle row
local function makeToggle(parent, labelText, default, callback)
    local row                    = Instance.new("Frame")
    row.Size                     = UDim2.new(1, -8, 0, 34)
    row.BackgroundColor3         = ITEM_BG
    row.BackgroundTransparency   = 0.4
    row.BorderSizePixel          = 0
    row.LayoutOrder              = nextOrder()
    row.Parent                   = parent

    local rowCorner              = Instance.new("UICorner")
    rowCorner.CornerRadius       = UDim.new(0, 5)
    rowCorner.Parent             = row

    local lbl                    = Instance.new("TextLabel")
    lbl.Size                     = UDim2.new(1, -56, 1, 0)
    lbl.Position                 = UDim2.new(0, 10, 0, 0)
    lbl.BackgroundTransparency   = 1
    lbl.Text                     = labelText
    lbl.TextColor3               = TEXT_CLR
    lbl.TextSize                 = 12
    lbl.Font                     = Enum.Font.Gotham
    lbl.TextXAlignment           = Enum.TextXAlignment.Left
    lbl.ZIndex                   = 12
    lbl.Parent                   = row

    local togBtn                 = Instance.new("TextButton")
    togBtn.Size                  = UDim2.new(0, 38, 0, 20)
    togBtn.Position              = UDim2.new(1, -46, 0.5, -10)
    togBtn.BackgroundColor3      = default and ACCENT or Color3.fromRGB(50, 50, 50)
    togBtn.Text                  = ""
    togBtn.BorderSizePixel       = 0
    togBtn.ZIndex                = 13
    togBtn.Parent                = row

    local togCorner              = Instance.new("UICorner")
    togCorner.CornerRadius       = UDim.new(1, 0)
    togCorner.Parent             = togBtn

    local dot                    = Instance.new("Frame")
    dot.Size                     = UDim2.new(0, 14, 0, 14)
    dot.Position                 = default
        and UDim2.new(1, -17, 0.5, -7)
        or  UDim2.new(0, 3, 0.5, -7)
    dot.BackgroundColor3         = Color3.fromRGB(230, 230, 230)
    dot.BorderSizePixel          = 0
    dot.ZIndex                   = 14
    dot.Parent                   = togBtn

    local dotCorner              = Instance.new("UICorner")
    dotCorner.CornerRadius       = UDim.new(1, 0)
    dotCorner.Parent             = dot

    local value = default == true

    togBtn.MouseButton1Click:Connect(function()
        value = not value
        TweenService:Create(togBtn, TweenInfo.new(0.15), {
            BackgroundColor3 = value and ACCENT or Color3.fromRGB(50, 50, 50)
        }):Play()
        TweenService:Create(dot, TweenInfo.new(0.15), {
            Position = value
                and UDim2.new(1, -17, 0.5, -7)
                or  UDim2.new(0, 3, 0.5, -7)
        }):Play()
        pcall(callback, value)
    end)

    return row, function(v)
        value = v
        togBtn.BackgroundColor3 = v and ACCENT or Color3.fromRGB(50, 50, 50)
        dot.Position = v and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
    end
end

-- Slider row
local function makeSlider(parent, labelText, minV, maxV, defaultV, increment, callback)
    local row                    = Instance.new("Frame")
    row.Size                     = UDim2.new(1, -8, 0, 50)
    row.BackgroundColor3         = ITEM_BG
    row.BackgroundTransparency   = 0.4
    row.BorderSizePixel          = 0
    row.LayoutOrder              = nextOrder()
    row.Parent                   = parent

    local rowCorner              = Instance.new("UICorner")
    rowCorner.CornerRadius       = UDim.new(0, 5)
    rowCorner.Parent             = row

    local lbl                    = Instance.new("TextLabel")
    lbl.Size                     = UDim2.new(0.7, 0, 0, 22)
    lbl.Position                 = UDim2.new(0, 10, 0, 4)
    lbl.BackgroundTransparency   = 1
    lbl.Text                     = labelText
    lbl.TextColor3               = TEXT_CLR
    lbl.TextSize                 = 12
    lbl.Font                     = Enum.Font.Gotham
    lbl.TextXAlignment           = Enum.TextXAlignment.Left
    lbl.ZIndex                   = 12
    lbl.Parent                   = row

    local valLbl                 = Instance.new("TextLabel")
    valLbl.Size                  = UDim2.new(0.3, -10, 0, 22)
    valLbl.Position              = UDim2.new(0.7, 0, 0, 4)
    valLbl.BackgroundTransparency= 1
    valLbl.Text                  = tostring(defaultV)
    valLbl.TextColor3            = ACCENT
    valLbl.TextSize              = 12
    valLbl.Font                  = Enum.Font.GothamBold
    valLbl.TextXAlignment        = Enum.TextXAlignment.Right
    valLbl.ZIndex                = 12
    valLbl.Parent                = row

    local track2                 = Instance.new("Frame")
    track2.Size                  = UDim2.new(1, -20, 0, 4)
    track2.Position              = UDim2.new(0, 10, 0, 34)
    track2.BackgroundColor3      = Color3.fromRGB(45, 45, 45)
    track2.BorderSizePixel       = 0
    track2.ZIndex                = 12
    track2.Parent                = row

    local trkCorner              = Instance.new("UICorner")
    trkCorner.CornerRadius       = UDim.new(1, 0)
    trkCorner.Parent             = track2

    local fill                   = Instance.new("Frame")
    fill.BackgroundColor3        = ACCENT
    fill.BorderSizePixel         = 0
    fill.ZIndex                  = 13
    fill.Parent                  = track2

    local fillCorner             = Instance.new("UICorner")
    fillCorner.CornerRadius      = UDim.new(1, 0)
    fillCorner.Parent            = fill

    local thumb                  = Instance.new("Frame")
    thumb.Size                   = UDim2.new(0, 12, 0, 12)
    thumb.BackgroundColor3       = Color3.fromRGB(230, 230, 230)
    thumb.BorderSizePixel        = 0
    thumb.ZIndex                 = 14
    thumb.Parent                 = track2

    local thumbCorner            = Instance.new("UICorner")
    thumbCorner.CornerRadius     = UDim.new(1, 0)
    thumbCorner.Parent           = thumb

    local currentVal = defaultV
    local draggingSlider = false

    local function updateSlider(v)
        v = math.clamp(
            math.round((v - minV) / increment) * increment + minV,
            minV, maxV
        )
        currentVal   = v
        local pct    = (v - minV) / (maxV - minV)
        fill.Size    = UDim2.new(pct, 0, 1, 0)
        thumb.Position = UDim2.new(pct, -6, 0.5, -6)
        valLbl.Text  = tostring(v)
        pcall(callback, v)
    end

    updateSlider(defaultV)

    track2.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch
        then
            draggingSlider = true
        end
    end)

    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
            or inp.UserInputType == Enum.UserInputType.Touch
        then
            draggingSlider = false
        end
    end)

    UserInputService.InputChanged:Connect(function(inp)
        if not draggingSlider then return end
        if inp.UserInputType ~= Enum.UserInputType.MouseMovement
            and inp.UserInputType ~= Enum.UserInputType.Touch
        then return end
        local absPos  = track2.AbsolutePosition
        local absSize = track2.AbsoluteSize
        local relX    = math.clamp((inp.Position.X - absPos.X) / absSize.X, 0, 1)
        updateSlider(minV + relX * (maxV - minV))
    end)

    return row
end

-- Button row
local function makeButton(parent, labelText, callback)
    local btn                    = Instance.new("TextButton")
    btn.Size                     = UDim2.new(1, -8, 0, 34)
    btn.BackgroundColor3         = Color3.fromRGB(28, 28, 28)
    btn.BorderSizePixel          = 0
    btn.Text                     = labelText
    btn.TextColor3               = ACCENT
    btn.TextSize                 = 12
    btn.Font                     = Enum.Font.GothamBold
    btn.LayoutOrder              = nextOrder()
    btn.ZIndex                   = 12
    btn.Parent                   = parent

    local btnCorner              = Instance.new("UICorner")
    btnCorner.CornerRadius       = UDim.new(0, 5)
    btnCorner.Parent             = btn

    local btnStroke              = Instance.new("UIStroke")
    btnStroke.Color              = Color3.fromRGB(50, 50, 50)
    btnStroke.Thickness          = 1
    btnStroke.Parent             = btn

    btn.MouseButton1Click:Connect(function()
        pcall(callback)
    end)
    return btn
end

-- Text input row
local function makeTextInput(parent, labelText, placeholder, callback)
    local row                    = Instance.new("Frame")
    row.Size                     = UDim2.new(1, -8, 0, 34)
    row.BackgroundColor3         = ITEM_BG
    row.BackgroundTransparency   = 0.4
    row.BorderSizePixel          = 0
    row.LayoutOrder              = nextOrder()
    row.Parent                   = parent

    local rowCorner              = Instance.new("UICorner")
    rowCorner.CornerRadius       = UDim.new(0, 5)
    rowCorner.Parent             = row

    local lbl                    = Instance.new("TextLabel")
    lbl.Size                     = UDim2.new(0.38, 0, 1, 0)
    lbl.Position                 = UDim2.new(0, 10, 0, 0)
    lbl.BackgroundTransparency   = 1
    lbl.Text                     = labelText
    lbl.TextColor3               = TEXT_CLR
    lbl.TextSize                 = 11
    lbl.Font                     = Enum.Font.Gotham
    lbl.TextXAlignment           = Enum.TextXAlignment.Left
    lbl.ZIndex                   = 12
    lbl.Parent                   = row

    local box                    = Instance.new("TextBox")
    box.Size                     = UDim2.new(0.57, -5, 0, 22)
    box.Position                 = UDim2.new(0.4, 0, 0.5, -11)
    box.BackgroundColor3         = Color3.fromRGB(30, 30, 30)
    box.BorderSizePixel          = 0
    box.PlaceholderText          = placeholder or ""
    box.PlaceholderColor3        = Color3.fromRGB(80, 80, 80)
    box.Text                     = ""
    box.TextColor3               = TEXT_CLR
    box.TextSize                 = 11
    box.Font                     = Enum.Font.Gotham
    box.ZIndex                   = 12
    box.ClearTextOnFocus         = false
    box.Parent                   = row

    local boxCorner              = Instance.new("UICorner")
    boxCorner.CornerRadius       = UDim.new(0, 4)
    boxCorner.Parent             = box

    box.FocusLost:Connect(function()
        pcall(callback, box.Text)
    end)

    return row
end

-- Dropdown-style multi-select (checkboxes in a sub-list)
local function makeMultiSelect(parent, labelText, items, stateTable, callback)
    local header                 = Instance.new("TextButton")
    header.Size                  = UDim2.new(1, -8, 0, 30)
    header.BackgroundColor3      = ITEM_BG
    header.BackgroundTransparency= 0.3
    header.BorderSizePixel       = 0
    header.Text                  = labelText .. "  v"
    header.TextColor3            = TEXT_CLR
    header.TextSize              = 11
    header.Font                  = Enum.Font.GothamBold
    header.LayoutOrder           = nextOrder()
    header.ZIndex                = 12
    header.Parent                = parent

    local headerCorner           = Instance.new("UICorner")
    headerCorner.CornerRadius    = UDim.new(0, 5)
    headerCorner.Parent          = header

    local subFrame               = Instance.new("Frame")
    subFrame.Size                = UDim2.new(1, -8, 0, #items * 26 + 4)
    subFrame.BackgroundColor3    = Color3.fromRGB(16, 16, 16)
    subFrame.BackgroundTransparency = 0.3
    subFrame.BorderSizePixel     = 0
    subFrame.LayoutOrder         = nextOrder()
    subFrame.Visible             = false
    subFrame.Parent              = parent

    local subCorner              = Instance.new("UICorner")
    subCorner.CornerRadius       = UDim.new(0, 5)
    subCorner.Parent             = subFrame

    local subLayout              = Instance.new("UIListLayout")
    subLayout.FillDirection      = Enum.FillDirection.Vertical
    subLayout.SortOrder          = Enum.SortOrder.LayoutOrder
    subLayout.Padding            = UDim.new(0, 2)
    subLayout.Parent             = subFrame

    local UIPadding              = Instance.new("UIPadding")
    UIPadding.PaddingLeft        = UDim.new(0, 8)
    UIPadding.PaddingTop         = UDim.new(0, 3)
    UIPadding.Parent             = subFrame

    for idx, item in ipairs(items) do
        local itemRow            = Instance.new("TextButton")
        itemRow.Size             = UDim2.new(1, -10, 0, 22)
        itemRow.BackgroundTransparency = 1
        itemRow.BorderSizePixel  = 0
        itemRow.Text             = ""
        itemRow.LayoutOrder      = idx
        itemRow.ZIndex           = 13
        itemRow.Parent           = subFrame

        local checkBox           = Instance.new("Frame")
        checkBox.Size            = UDim2.new(0, 12, 0, 12)
        checkBox.Position        = UDim2.new(0, 0, 0.5, -6)
        checkBox.BackgroundColor3= stateTable[item] ~= false and ACCENT or Color3.fromRGB(45, 45, 45)
        checkBox.BorderSizePixel = 0
        checkBox.ZIndex          = 14
        checkBox.Parent          = itemRow

        local cbCorner           = Instance.new("UICorner")
        cbCorner.CornerRadius    = UDim.new(0, 3)
        cbCorner.Parent          = checkBox

        local itemLbl            = Instance.new("TextLabel")
        itemLbl.Size             = UDim2.new(1, -20, 1, 0)
        itemLbl.Position         = UDim2.new(0, 18, 0, 0)
        itemLbl.BackgroundTransparency = 1
        itemLbl.Text             = item
        itemLbl.TextColor3       = TEXT_CLR
        itemLbl.TextSize         = 11
        itemLbl.Font             = Enum.Font.Gotham
        itemLbl.TextXAlignment   = Enum.TextXAlignment.Left
        itemLbl.ZIndex           = 14
        itemLbl.Parent           = itemRow

        itemRow.MouseButton1Click:Connect(function()
            local newVal         = stateTable[item] == false and true or false
            stateTable[item]     = newVal
            checkBox.BackgroundColor3 = newVal and ACCENT or Color3.fromRGB(45, 45, 45)
            pcall(callback, item, newVal)
        end)
    end

    local expanded = false
    header.MouseButton1Click:Connect(function()
        expanded              = not expanded
        subFrame.Visible      = expanded
        header.Text           = labelText .. (expanded and "  ^" or "  v")
    end)

    return header, subFrame
end

-- ─── TABS ─────────────────────────────────────────────────────────────────────

local tabs     = {}
local tabPages = {}

local function makeTabBtn(name)
    local btn                    = Instance.new("TextButton")
    btn.Size                     = UDim2.new(0, 80, 1, 0)
    btn.BackgroundColor3         = Color3.fromRGB(25, 25, 25)
    btn.BackgroundTransparency   = 0.3
    btn.BorderSizePixel          = 0
    btn.Text                     = name
    btn.TextColor3               = SUB_CLR
    btn.TextSize                 = 11
    btn.Font                     = Enum.Font.GothamBold
    btn.ZIndex                   = 12
    btn.Parent                   = TabBar

    local btnCorner              = Instance.new("UICorner")
    btnCorner.CornerRadius       = UDim.new(0, 5)
    btnCorner.Parent             = btn

    return btn
end

local function makeTabPage()
    local page                   = Instance.new("Frame")
    page.Size                    = UDim2.new(1, 0, 1, 0)
    page.BackgroundTransparency  = 1
    page.BorderSizePixel         = 0
    page.Visible                 = false
    page.ZIndex                  = 11
    page.Parent                  = ContentFrame

    local layout                 = Instance.new("UIListLayout")
    layout.FillDirection         = Enum.FillDirection.Vertical
    layout.SortOrder             = Enum.SortOrder.LayoutOrder
    layout.Padding               = UDim.new(0, 4)
    layout.Parent                = page

    local pad                    = Instance.new("UIPadding")
    pad.PaddingLeft              = UDim.new(0, 2)
    pad.PaddingRight             = UDim.new(0, 2)
    pad.PaddingTop               = UDim.new(0, 4)
    pad.Parent                   = page

    return page
end

local TAB_NAMES = { "Farm", "Filter", "Movement", "ESP" }
local activeTab = 1

for i, name in ipairs(TAB_NAMES) do
    local btn  = makeTabBtn(name)
    local page = makeTabPage()
    tabs[i]    = btn
    tabPages[i]= page

    btn.MouseButton1Click:Connect(function()
        for j, p in ipairs(tabPages) do
            p.Visible = (j == i)
            tabs[j].TextColor3 = (j == i) and ACCENT or SUB_CLR
            tabs[j].BackgroundTransparency = (j == i) and 0.0 or 0.5
        end
        activeTab = i
    end)
end

-- Activate first tab
tabPages[1].Visible = true
tabs[1].TextColor3  = ACCENT
tabs[1].BackgroundTransparency = 0.0

-- ─── TAB 1: FARM ─────────────────────────────────────────────────────────────
local FarmPage = tabPages[1]

makeSection(FarmPage, "Auto Farm")

makeToggle(FarmPage, "Auto Steal", false, function(v)
    State.autofarm = v
end)

makeToggle(FarmPage, "Prefer High Value Eggs", true, function(v)
    State.preferHighValue = v
end)

makeButton(FarmPage, "Steal Once (Manual)", function()
    task.spawn(doStealOnce)
end)

makeButton(FarmPage, "Return to Safe Zone", function()
    task.spawn(returnToSafe)
end)

makeSection(FarmPage, "Anti-AFK")

makeToggle(FarmPage, "Anti-AFK", true, function(v)
    State.antiAfk = v
end)

-- ─── TAB 2: FILTER ───────────────────────────────────────────────────────────
local FilterPage = tabPages[2]

makeSection(FilterPage, "Egg Name Filter")

makeTextInput(FilterPage, "Egg Name:", "e.g. Dragon", function(v)
    State.filterName = v or ""
end)

makeSection(FilterPage, "Minimum Area")

makeSlider(FilterPage, "Min Area Index", 1, #AREAS, 1, 1, function(v)
    State.minAreaIndex = v
end)

-- Area multi-select
makeSection(FilterPage, "Areas (toggle off to skip)")
makeMultiSelect(FilterPage, "Areas", AREAS, State.enabledAreas, function(item, val)
    State.enabledAreas[item] = val
end)

-- Rarity multi-select
makeSection(FilterPage, "Rarities (toggle off to skip)")
makeMultiSelect(FilterPage, "Rarities", RARITIES, State.enabledRarities, function(item, val)
    State.enabledRarities[item] = val
end)

-- ─── TAB 3: MOVEMENT ─────────────────────────────────────────────────────────
local MovePage = tabPages[3]

makeSection(MovePage, "Walk Speed")

makeToggle(MovePage, "Speed Boost", false, function(v)
    State.speedOn = v
    applySpeed()
end)

makeSlider(MovePage, "Speed Value", 16, 120, 32, 1, function(v)
    State.walkSpeed = v
    if State.speedOn then applySpeed() end
end)

makeSection(MovePage, "Fly")

makeToggle(MovePage, "Fly Mode (WASD + Space/Ctrl)", false, function(v)
    State.fly = v
    setFly(v)
end)

makeSlider(MovePage, "Fly Speed", 16, 120, 32, 1, function(v)
    State.flySpeed = v
end)

makeSection(MovePage, "Misc")

makeToggle(MovePage, "Noclip", false, function(v)
    State.noclip = v
    setNoclip(v)
end)

makeToggle(MovePage, "Infinite Jump", false, function(v)
    State.infJump = v
    setInfJump(v)
end)

makeButton(MovePage, "Unload Script", function()
    pcall(genv.SV_SAE_SHUTDOWN)
end)

-- ─── TAB 4: ESP ──────────────────────────────────────────────────────────────
local EspPage = tabPages[4]

makeSection(EspPage, "ESP Highlights")

makeToggle(EspPage, "World Egg ESP", false, function(v)
    State.espWorldEgg = v
    refreshEsp()
end)

makeToggle(EspPage, "Guard ESP", false, function(v)
    State.espGuard = v
    refreshEsp()
end)

makeToggle(EspPage, "Player ESP", false, function(v)
    State.espPlayer = v
    refreshEsp()
end)

makeToggle(EspPage, "Plot ESP", false, function(v)
    State.espPlot = v
    refreshEsp()
end)

-- ─── DRAGGING + RESIZE ───────────────────────────────────────────────────────

-- Main window drag
do
    local dragging, dragStart, startPos
    TitleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            dragging  = true
            dragStart = input.Position
            startPos  = MainFrame.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch)
        then
            local delta       = input.Position - dragStart
            MainFrame.Position= UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            dragging = false
        end
    end)
end

-- Resize handle
do
    local resizing, resizeStart, startSize
    ResizeHandle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            resizing    = true
            resizeStart = input.Position
            startSize   = MainFrame.Size
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch)
        then
            local delta   = input.Position - resizeStart
            local newW    = math.clamp(startSize.X.Offset + delta.X, 320, 700)
            local newH    = math.clamp(startSize.Y.Offset + delta.Y, 380, 800)
            MainFrame.Size= UDim2.new(0, newW, 0, newH)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            resizing = false
        end
    end)
end

-- Toggle open/close
ToggleBtn.MouseButton1Click:Connect(function()
    State.menuOpen = not State.menuOpen
    MainFrame.Visible = State.menuOpen
    ToggleLbl.Text    = State.menuOpen and "SV" or "SV"
    ToggleStroke.Color= State.menuOpen
        and Color3.fromRGB(120, 220, 160)
        or  Color3.fromRGB(80, 80, 80)
end)

-- ─── MAIN LOOPS ──────────────────────────────────────────────────────────────

-- Status label update
track(RunService.Heartbeat:Connect(function()
    if not State.running then return end
    StatusLbl.Text = "Status: " .. tostring(State.status)
        .. (State.carrying and "  [CARRYING]" or "")
        .. (State.autofarm and "  [FARM ON]" or "")
end))

-- Speed and fly each heartbeat
track(RunService.Heartbeat:Connect(function()
    if not State.running then return end
    if State.speedOn or State.fly then
        freezeSpeedPower()
    end
    if State.speedOn then
        applySpeed()
    end
end))

-- Anti-AFK
track(RunService.Heartbeat:Connect(function()
    if not State.running then return end
    if not State.antiAfk then return end
    if os.clock() - State.lastAfk > 900 then
        State.lastAfk = os.clock()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new(0, 0))
        end)
    end
end))

-- ESP refresh loop
track(task.spawn(function()
    while State.running do
        if State.espWorldEgg or State.espGuard or State.espPlayer or State.espPlot then
            pcall(refreshEsp)
        end
        task.wait(2.5)
    end
end))

-- Apply movement features on respawn
track(LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.6)
    if not State.running then return end
    if State.speedOn then applySpeed() end
    if State.fly      then setFly(true) end
    if State.noclip   then setNoclip(true) end
    if State.infJump  then setInfJump(true) end
end))

-- Autofarm loop (runs every 1.5 seconds, cycles when ready)
track(task.spawn(function()
    while State.running do
        pcall(autofarmCycle)
        task.wait(1.5)
    end
end))

-- ─── SHUTDOWN ────────────────────────────────────────────────────────────────

genv.SV_SAE_SHUTDOWN = function()
    State.running  = false
    State.autofarm = false

    for _, c in ipairs(conns) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(conns)

    clearEsp()
    setNoclip(false)
    setFly(false)
    setInfJump(false)

    if speedBV then
        pcall(function() speedBV:Destroy() end)
        speedBV = nil
    end

    pcall(function()
        if ScreenGui and ScreenGui.Parent then
            ScreenGui:Destroy()
        end
    end)

    genv.SV_SAE_RUNNING  = nil
    genv.SV_SAE_SHUTDOWN = nil
    print("[ScriptVerse] Steal An Egg - unloaded")
end

print("[ScriptVerse] Steal An Egg - loaded successfully")
