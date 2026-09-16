-- BlyxoHub Steal An Egg - ANTICHEAT-SAFE VERSION WITH SERVER RECONCILIATION FIXES
--
-- - Reduced speed to 300 studs/sec (from 350) for better server reconciliation
-- - Lower server correction threshold (5 studs) for faster response
-- - Conservative tween movement (300 studs/sec, max 400)
-- - Server reconciliation acceptance (never fight server corrections)

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

-- ============================================================================
-- ONE INSTANCE AT A TIME
-- ============================================================================
--
-- Nothing stopped this script being executed twice, and people re-run scripts
-- constantly - a second paste, a key-system loader firing again, an auto-exec
-- on respawn. Every one of those built a SECOND everything: another window,
-- another steal loop fighting the first for the character, and another copy of
-- all eleven `while true` background loops. Doubled remote traffic, doubled UI
-- work, two movers arguing over the same HumanoidRootPart. A good share of
-- "it gets laggy" and "it goes glitchy after a while" is this.
--
-- A counter in the shared environment retires the old copy without needing any
-- cooperation from it: each background loop remembers the generation it was
-- born in and returns as soon as that is no longer current, so the previous
-- instance unwinds itself within a second.
--
-- Written this way for a reason. The obvious version - three top-level locals
-- for the env, the generation and an alive() helper - does not compile:
--
--     Out of local registers when trying to allocate teardown: exceeded 200
--
-- This chunk is already close to Luau's 200-local ceiling, so the counter
-- lives in the shared table and each loop keeps its own copy in its own scope.
-- Zero new top-level locals.
--
-- FIRST RUN AFTER THIS UPDATE: a copy already running predates the check and
-- cannot see it, so one duplication can still happen when loading this over an
-- older build. Every run after that is clean.
do
    local env = (type(getgenv) == "function" and getgenv()) or _G

    -- AND DISCONNECT WHAT THE PREVIOUS COPY LEFT BEHIND.
    --
    -- The generation counter retires the old copy's LOOPS, but not its
    -- CONNECTIONS. Every Heartbeat/RenderStepped/Stepped handler it had open -
    -- the speed hold, the spoof, noclip, anti-hit, the ESP pass, the claim and
    -- drop watches - stayed connected for the rest of the session. So after a
    -- re-execute the old copy was still running every frame next to the new
    -- one, and every closure it held (all of its tables and caches) could
    -- never be collected: the memory climbed with each re-run, and the old
    -- handlers kept writing to the character - the lag and the "movement goes
    -- weird after re-executing".
    --
    -- Each copy now publishes the two places its connections live - the BX
    -- table and BlyxoTop for top-level ones - and the next copy disconnects
    -- every RBXScriptConnection it finds in them before it starts.
    for _, holder in ipairs({ env.__BLYXO_BX, env.__BLYXO_TOP }) do
        if type(holder) == "table" then
            for _, v in pairs(holder) do
                if typeof(v) == "RBXScriptConnection" then
                    pcall(function() v:Disconnect() end)
                end
            end
        end
    end
    env.__BLYXO_TOP = {}
    env.__BLYXO_GEN = (tonumber(env.__BLYXO_GEN) or 0) + 1
end
-- Top-level connections go in here (a global, not a local: register ceiling).
BlyxoTop = ((type(getgenv) == "function" and getgenv()) or _G).__BLYXO_TOP
-- Load-stage clock (global, register ceiling) - see "=== load:" near the end.
BlyxoLoadT = { start = os.clock() }

-- A QUIET CONSOLE. Every trace line used to be mirrored to the executor
-- console (up to 8 a second), plus a heartbeat line and a few status prints -
-- and on phone executors the console itself is a real frame cost. Printing is
-- for debugging only now: `print` inside this script does nothing unless
-- getgenv().BlyxoDebug is true. The trace FILE (BlyxoHub_trace.txt) still
-- gets every line, which is what bug reports are read from. warn() is left
-- alone: it only fires when the menu library itself fails to load, and that
-- has to be seen. (Globals, not locals: the main chunk is at the register
-- ceiling.)
BlyxoRealPrint = BlyxoRealPrint or print
print = function(...)
    local env = (type(getgenv) == "function" and getgenv()) or _G
    if env.BlyxoDebug then BlyxoRealPrint(...) end
end

-- ============================================================================
-- LOADING SCREEN (and the Discord step inside it)
-- ============================================================================
--
-- Up before anything slow happens - the UI library download, waiting for the
-- game's modules, building ~14,000 lines of menu - so the first thing you see
-- is BlyxoHub loading, not a menu assembling itself in front of you.
--
-- ONE CARD. The Discord ask used to be its own popup: the splash stepped
-- aside, a dark overlay and a second card came up, then the splash came back.
-- Now, at about 55%, the same card grows taller and a Discord section slides
-- open between the header and the progress bar; once you join, it closes and
-- loading carries on to 100%. Same Mono surface as the rest of the hub - a
-- white button, not Discord purple.
--
-- A GLOBAL, NOT A LOCAL. The main chunk sits near Luau's 200-register ceiling
-- (see the note above), so the splash lives in one global table and its own
-- function scope, and costs the chunk zero locals. Calls further down:
--
--     BlyxoSplash.step("Building menu", 0.65)   -- status line + bar target
--     BlyxoSplash.discord()                     -- blocks until joined
--     BlyxoSplash.fail("why")                   -- show the reason, then go
--     BlyxoSplash.done()                        -- fill, fade, destroy
--
-- It can never trap anyone. The Discord step continues by itself after 25s,
-- same as the old gate, and the whole card removes itself if nothing has
-- happened for 30s (an error halfway through the build). The screen dim takes
-- no input; only the card's own button does.
-- DisplayOrder 999997 is above Rayfield (99999).
BlyxoSplash = { step = function() end, discord = function() end,
                fail = function() end, done = function() end,
                -- No splash (it failed to build): run the callback straight away.
                whenClosed = function(fn) pcall(fn) end }
;(function()
    local ok = pcall(function()
        local TS = game:GetService("TweenService")
        local HS = game:GetService("HttpService")
        local LOGO = "rbxassetid://95108798243406"
        local INVITE_CODE = "9KSXyabAYV"
        local INVITE_URL = "https://discord.gg/" .. INVITE_CODE
        local shownAt, lastBeat, finished, inDiscord = os.clock(), os.clock(), false, false

        -- Touch screens get a 44px Join button (the usual minimum for a
        -- finger) instead of 38, and the open card grows by the difference.
        local JOIN_H = (game:GetService("UserInputService").TouchEnabled
            and not game:GetService("UserInputService").KeyboardEnabled) and 44 or 38
        local W, H, OPEN_H = 300, 132, 224 + JOIN_H   -- card size; OPEN_H with Discord open

        local WHITE  = Color3.fromRGB(240, 240, 246)
        local GREY   = Color3.fromRGB(138, 138, 146)
        local EDGE   = Color3.fromRGB(48, 48, 56)
        local ONLINE = Color3.fromRGB(87, 242, 135)

        local function mk(class, props, parent)
            local o = Instance.new(class)
            for k, v in pairs(props) do o[k] = v end
            o.Parent = parent
            return o
        end
        local function tw(o, t, props, style)
            pcall(function()
                TS:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quint,
                    Enum.EasingDirection.Out), props):Play()
            end)
        end

        -- Asked for as soon as the card exists, so the numbers are usually
        -- already there by the time the Discord section opens.
        local counts = nil
        task.spawn(function()
            pcall(function()
                local raw = game:HttpGet("https://discord.com/api/v9/invites/"
                    .. INVITE_CODE .. "?with_counts=true")
                local t = HS:JSONDecode(raw)
                if tonumber(t.approximate_member_count) then
                    counts = { members = tonumber(t.approximate_member_count),
                               online = tonumber(t.approximate_presence_count) or 0 }
                end
            end)
        end)
        local function commas(n)
            local s = tostring(math.floor(n))
            repeat
                local k
                s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
            until k == 0
            return s
        end

        local parent = (gethui and gethui()) or game:GetService("CoreGui")
        local old = parent:FindFirstChild("BlyxoSplash")
        if old then old:Destroy() end

        local gui = mk("ScreenGui", {
            Name = "BlyxoSplash", DisplayOrder = 999997, IgnoreGuiInset = true,
            ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        }, parent)

        -- Covers the screen so the menu builds unseen behind it. Not Active:
        -- it hides the menu, it does not block the game.
        local shade = mk("Frame", {
            Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(6, 6, 8),
            BackgroundTransparency = 1, BorderSizePixel = 0,
        }, gui)

        local card = mk("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(W, H), BackgroundColor3 = Color3.new(1, 1, 1),
            BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true,
        }, shade)
        mk("UICorner", { CornerRadius = UDim.new(0, 14) }, card)
        mk("UIGradient", {
            Color = ColorSequence.new(Color3.fromRGB(26, 26, 30), Color3.fromRGB(14, 14, 17)),
            Rotation = 90,
        }, card)
        local cardStroke = mk("UIStroke", {
            Color = Color3.new(1, 1, 1), Thickness = 1, Transparency = 1,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }, card)
        mk("UIGradient", {
            Color = ColorSequence.new(Color3.fromRGB(206, 206, 212), Color3.fromRGB(41, 41, 48)),
            Rotation = 90,
        }, cardStroke)
        -- SIZED FOR THE SCREEN IT IS ON.
        --
        -- This was capped at 1x - 300px wide whatever the screen, which on a
        -- 1536x943 desktop is a small card in a big empty space. Now:
        --   * PC grows with the screen height (~1.5x at 943 tall, ~1.75x at
        --     1080), because that is what reads as "the same size" across
        --     monitors,
        --   * touch screens fit what they have, up to 1.25x,
        --   * and nothing ever exceeds the room available: the fit is taken
        --     against the OPEN card (Discord step showing), so the Join button
        --     can never end up off-screen.
        -- Re-fitted if the viewport changes while it is up (phone rotation,
        -- window resize).
        local touchUI = game:GetService("UserInputService").TouchEnabled
            and not game:GetService("UserInputService").KeyboardEnabled
        local function fitScale()
            local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
            if not vp or vp.X < 10 or vp.Y < 10 then return 1 end
            local want = touchUI and 1.25 or math.clamp(vp.Y / 620, 1.2, 1.8)
            local room = math.min((vp.X - 32) / W, (vp.Y - 32) / OPEN_H)
            return math.max(0.6, math.min(want, room))
        end
        local baseScale = 1
        pcall(function() baseScale = fitScale() end)
        local scale = mk("UIScale", { Scale = baseScale * 0.92 }, card)
        pcall(function()
            local vpConn
            vpConn = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
                if not gui.Parent then vpConn:Disconnect() return end
                baseScale = fitScale()
                if not finished then scale.Scale = baseScale end
            end)
        end)

        local logo = mk("ImageLabel", {
            Position = UDim2.fromOffset(22, 22), Size = UDim2.fromOffset(38, 38),
            BackgroundTransparency = 1, Image = LOGO, ImageTransparency = 1,
            ScaleType = Enum.ScaleType.Fit,
        }, card)
        local title = mk("TextLabel", {
            Position = UDim2.fromOffset(72, 22), Size = UDim2.new(1, -94, 0, 20),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 17,
            TextColor3 = WHITE, TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left, Text = "BlyxoHub",
        }, card)
        local sub = mk("TextLabel", {
            Position = UDim2.fromOffset(72, 43), Size = UDim2.new(1, -94, 0, 15),
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12,
            TextColor3 = GREY, TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left, Text = "Steal An Egg  ·  V3.1",
        }, card)

        -- The progress row hangs off the BOTTOM edge, so when the card grows
        -- it rides down with it and the Discord section opens above it.
        local status = mk("TextLabel", {
            Position = UDim2.new(0, 22, 1, -52), Size = UDim2.new(1, -84, 0, 14),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 12,
            TextColor3 = Color3.fromRGB(200, 200, 206), TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left, Text = "Starting",
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, card)
        local pct = mk("TextLabel", {
            Position = UDim2.new(1, -62, 1, -52), Size = UDim2.fromOffset(40, 14),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 12,
            TextColor3 = GREY, TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Right, Text = "0%",
        }, card)
        local track = mk("Frame", {
            Position = UDim2.new(0, 22, 1, -30), Size = UDim2.new(1, -44, 0, 4),
            BackgroundColor3 = Color3.fromRGB(41, 41, 48), BackgroundTransparency = 1,
            BorderSizePixel = 0, ClipsDescendants = true,
        }, card)
        mk("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
        local fill = mk("Frame", {
            Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1),
            BackgroundTransparency = 1, BorderSizePixel = 0,
        }, track)
        mk("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)
        mk("UIGradient", {
            Color = ColorSequence.new(WHITE, Color3.fromRGB(150, 150, 158)),
        }, fill)

        ---------- Discord section ----------

        local disc = mk("Frame", {
            Position = UDim2.fromOffset(22, 72), Size = UDim2.new(1, -44, 0, 92 + JOIN_H),
            BackgroundTransparency = 1, Visible = false,
        }, card)
        local rule = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = EDGE,
            BackgroundTransparency = 1, BorderSizePixel = 0,
        }, disc)
        local dTitle = mk("TextLabel", {
            Position = UDim2.fromOffset(0, 14), Size = UDim2.new(1, 0, 0, 18),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 14,
            TextColor3 = WHITE, TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left, Text = "Join the community",
        }, disc)
        local dSub = mk("TextLabel", {
            Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 15),
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12,
            TextColor3 = GREY, TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left, Text = "Updates, configs and support",
        }, disc)
        local dot = mk("Frame", {
            Position = UDim2.fromOffset(0, 60), Size = UDim2.fromOffset(6, 6),
            BackgroundColor3 = ONLINE, BackgroundTransparency = 1, BorderSizePixel = 0,
        }, disc)
        mk("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
        local dCount = mk("TextLabel", {
            Position = UDim2.fromOffset(12, 56), Size = UDim2.new(1, -12, 0, 14),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 12,
            TextColor3 = GREY, TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left, Text = "",
        }, disc)
        -- Modal frees the mouse while the card is up, so a first-person or
        -- shift-lock camera cannot keep the cursor from reaching the button.
        local join = mk("TextButton", {
            Position = UDim2.fromOffset(0, 82), Size = UDim2.new(0.62, -4, 0, JOIN_H),
            BackgroundColor3 = WHITE, BackgroundTransparency = 1, BorderSizePixel = 0,
            AutoButtonColor = false, Font = Enum.Font.GothamBold, TextSize = 14,
            TextColor3 = Color3.fromRGB(14, 14, 17), TextTransparency = 1,
            Text = "Join Discord", Modal = true, ZIndex = 2,
        }, disc)
        mk("UICorner", { CornerRadius = UDim.new(0, 9) }, join)
        local joinScale = mk("UIScale", { Scale = 1 }, join)
        -- CONTINUE: skip it instantly. Outlined, so Join stays the obvious one.
        local cont = mk("TextButton", {
            Position = UDim2.new(0.62, 4, 0, 82), Size = UDim2.new(0.38, -4, 0, JOIN_H),
            BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
            AutoButtonColor = false, Font = Enum.Font.GothamMedium, TextSize = 13,
            TextColor3 = WHITE, TextTransparency = 1, Text = "Continue", ZIndex = 2,
        }, disc)
        mk("UICorner", { CornerRadius = UDim.new(0, 9) }, cont)
        local contStroke = mk("UIStroke", {
            Color = EDGE, Thickness = 1, Transparency = 1,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }, cont)

        -- Resting transparency of every piece, so fading is one loop.
        local parts = {
            { shade, "BackgroundTransparency", 0.3 }, { card, "BackgroundTransparency", 0.02 },
            { cardStroke, "Transparency", 0.45 }, { logo, "ImageTransparency", 0 },
            { title, "TextTransparency", 0 }, { sub, "TextTransparency", 0 },
            { status, "TextTransparency", 0 }, { pct, "TextTransparency", 0 },
            { track, "BackgroundTransparency", 0 }, { fill, "BackgroundTransparency", 0 },
        }
        local discParts = {
            { rule, "BackgroundTransparency", 0 }, { dTitle, "TextTransparency", 0 },
            { dSub, "TextTransparency", 0 }, { dot, "BackgroundTransparency", 0 },
            { dCount, "TextTransparency", 0 }, { join, "BackgroundTransparency", 0 },
            { join, "TextTransparency", 0 }, { cont, "BackgroundTransparency", 0.94 },
            { cont, "TextTransparency", 0 }, { contStroke, "Transparency", 0 },
        }
        local function fadeSet(list, on, t)
            for _, p in ipairs(list) do tw(p[1], t, { [p[2]] = on and p[3] or 1 }) end
        end
        local function setShown(on, t)
            fadeSet(parts, on, t)
            if disc.Visible then fadeSet(discParts, on, t) end
            tw(scale, t, { Scale = on and baseScale or baseScale * 0.92 },
                on and Enum.EasingStyle.Back or Enum.EasingStyle.Quint)
        end

        -- The shown percentage counts toward the bar's target instead of
        -- jumping, so big steps still read as progress.
        local target, shownPct = 0, 0
        task.spawn(function()
            while gui.Parent do
                local dt = task.wait()
                shownPct += (target - shownPct) * math.min(1, dt * 8)
                pct.Text = ("%d%%"):format(math.floor(shownPct * 100 + 0.5))
            end
        end)

        local function step(text, p)
            if finished then return end
            lastBeat = os.clock()
            if text then status.Text = tostring(text) end
            if p then
                target = math.clamp(math.max(target, p), 0, 1)
                tw(fill, 0.45, { Size = UDim2.fromScale(target, 1) })
            end
        end

        -- Things waiting for the card to be gone (the menu stays hidden until
        -- then - see "THE MENU WAITS FOR THE CARD" after CreateWindow).
        local onClosed, closedDone = {}, false
        local function runClosed()
            if closedDone then return end
            closedDone = true
            for _, fn in ipairs(onClosed) do pcall(fn) end
        end

        local function close(delay)
            if finished then return end
            finished = true
            task.delay(delay or 0, function()
                setShown(false, 0.3)
                -- Start revealing the menu as the card fades, not after it.
                task.delay(0.15, runClosed)
                task.delay(0.35, function() pcall(function() gui:Destroy() end) end)
            end)
        end

        ---------- the Discord step ----------

        local function copyInvite()
            for _, fn in pairs({ setclipboard, toclipboard, set_clipboard }) do
                if type(fn) == "function" and pcall(fn, INVITE_URL) then return true end
            end
            return false
        end

        -- The desktop Discord app listens for invites on one of ten local
        -- ports. All ten are tried at once, in the background; whether any
        -- answers never decides anything here.
        local function tryDiscordApp()
            local req = (syn and syn.request) or request or http_request or httprequest
            if type(req) ~= "function" then return end
            local body = HS:JSONEncode({
                cmd = "INVITE_BROWSER", args = { code = INVITE_CODE },
                nonce = HS:GenerateGUID(false),
            })
            for port = 6463, 6472 do
                task.spawn(pcall, req, {
                    Url = ("http://127.0.0.1:%d/rpc?v=1"):format(port), Method = "POST",
                    Headers = { ["Content-Type"] = "application/json", ["Origin"] = "https://discord.com" },
                    Body = body,
                })
            end
        end

        -- EVERY LOAD, AND IT NEVER HOLDS THE LOAD UP.
        --
        -- This used to block: loading stopped until Join was tapped, or 25s
        -- - most of the "the hub takes a minute to load" reports, which is why
        -- it went to once a day. Now it opens and returns at once. The menu
        -- keeps building underneath (the bar keeps moving), Join and Continue
        -- both close it, and if loading finishes first the card stays up with
        -- "Ready" for a few more seconds and then closes by itself. Nobody
        -- waits on it.
        local discordOpen, accepted, closeWhenDone = false, false, false
        local function accept(opened)
            if accepted then return end
            accepted = true
            if opened then
                local copied = copyInvite()
                pcall(function() game:GetService("GuiService"):OpenBrowserWindow(INVITE_URL) end)
                tryDiscordApp()
                print("[BLYXO] Discord: " .. INVITE_URL)
                join.Text = copied and "✓  Invite copied" or "✓  Opening Discord"
                task.wait(0.7)
            end
            -- Close: section out first, then the card folds back.
            fadeSet(discParts, false, 0.2)
            task.wait(0.15)
            tw(card, 0.4, { Size = UDim2.fromOffset(W, H) })
            task.wait(0.4)
            disc.Visible = false
            discordOpen, inDiscord = false, false
            lastBeat = os.clock()
            -- Loading already finished while it was open: now the card can go.
            if closeWhenDone then close(0.2) end
        end

        local function discord()
            if finished then return end
            discordOpen, inDiscord = true, true

            if counts then
                dCount.Text = ("%s online  ·  %s members"):format(commas(counts.online), commas(counts.members))
            else
                -- No numbers (request blocked or slow): the invite itself is
                -- still worth a line, so the row is never an empty gap.
                dCount.Text = "discord.gg/" .. INVITE_CODE
                discParts[4][3] = 1          -- no "online" dot without a count
                dCount.Position = UDim2.fromOffset(0, 56)
            end

            -- Open: the card grows, the progress row rides down, the section
            -- fades in a beat later so it does not appear before there is room.
            -- The status line keeps showing the real loading step.
            disc.Visible = true
            tw(card, 0.5, { Size = UDim2.fromOffset(W, OPEN_H) })
            task.delay(0.15, function() fadeSet(discParts, true, 0.35) end)

            join.MouseEnter:Connect(function() tw(join, 0.15, { BackgroundColor3 = Color3.new(1, 1, 1) }) end)
            join.MouseLeave:Connect(function() tw(join, 0.2, { BackgroundColor3 = WHITE }) end)
            join.MouseButton1Down:Connect(function() tw(joinScale, 0.1, { Scale = 0.97 }) end)
            join.MouseButton1Up:Connect(function() tw(joinScale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back) end)
            -- Activated is the one event raised for mouse AND touch AND
            -- gamepad; the others are there for executors that eat it.
            join.Activated:Connect(function() task.spawn(accept, true) end)
            join.MouseButton1Click:Connect(function() task.spawn(accept, true) end)
            pcall(function() join.TouchTap:Connect(function() task.spawn(accept, true) end) end)
            cont.Activated:Connect(function() task.spawn(accept, false) end)
            cont.MouseButton1Click:Connect(function() task.spawn(accept, false) end)
            pcall(function() cont.TouchTap:Connect(function() task.spawn(accept, false) end) end)
            -- No waiting loop here any more: the load carries straight on.
        end

        setShown(true, 0.4)

        BlyxoSplash.step = step
        BlyxoSplash.discord = discord
        BlyxoSplash.whenClosed = function(fn)
            if closedDone then pcall(fn) else onClosed[#onClosed + 1] = fn end
        end
        BlyxoSplash.fail = function(why)
            if finished then return end
            status.Text = tostring(why)
            status.TextColor3 = Color3.fromRGB(240, 110, 110)
            close(4)
        end
        BlyxoSplash.done = function()
            if finished then return end
            step("Ready", 1)
            -- Discord section still open: stay up a little longer so it can
            -- be read, then close by itself. Join or Continue closes it
            -- sooner. Everything behind the card is already loaded.
            if discordOpen and not accepted then
                closeWhenDone = true
                task.delay(8, function()
                    if not accepted then accept(false) end
                end)
                return
            end
            -- Never a flash: at least a second on screen, and long enough for
            -- the bar to visibly reach the end.
            close(math.max(0.45, 1.0 - (os.clock() - shownAt)))
        end

        -- Safety net: 30s with no progress (and not waiting on the Discord
        -- step) means the build stopped somewhere. Take the card down.
        task.spawn(function()
            while not finished do
                task.wait(1)
                if not inDiscord and os.clock() - lastBeat > 30 then close(0) end
            end
        end)
    end)
    -- If building it failed, the no-op table above is still in place and
    -- every call below is harmless.
    if not ok then warn("[BLYXO] loading screen unavailable") end
end)()
BlyxoSplash.step("Loading interface", 0.08)

local Rayfield
do
    local URLS = {
        "https://sirius.menu/gen2",
        "https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/main/source.lua",
    }
    local lastErr
    for attempt = 1, 4 do
        for _, url in ipairs(URLS) do
            local ok, res = pcall(function() return game:HttpGet(url) end)
            if ok and type(res) == "string" and #res > 1000 then
                local okLoad, lib = pcall(function() return loadstring(res)() end)
                if okLoad and type(lib) == "table" then
                    Rayfield = lib
                    break
                end
                lastErr = "loadstring failed: " .. tostring(lib)
            else
                lastErr = tostring(res)
            end
        end
        if Rayfield then break end
        warn(("[BLYXO] UI host attempt %d/4 failed: %s"):format(attempt, tostring(lastErr)))
        task.wait(attempt * 1.5)
    end

    if not Rayfield then
        warn("[BLYXO] Could not load the UI library. The menu host is down, not your executor.")
        warn("[BLYXO] Last error: " .. tostring(lastErr))
        BlyxoSplash.fail("Menu host is down - try again in a minute")
        return
    end
end
BlyxoLoadT.lib = os.clock()
BlyxoSplash.step("Waiting for the game", 0.3)

-- Delta and other slower injectors can run this before the game tree is
-- populated. Wait for each dependency instead of asserting instantly.
local function waitFor(parent, name, timeout)
    if not parent then return nil end
    local ok, res = pcall(function() return parent:WaitForChild(name, timeout or 15) end)
    return ok and res or nil
end

local function deepFind(root, name, timeout)
    if not root then return nil end
    local deadline = os.clock() + (timeout or 15)
    repeat
        local found = root:FindFirstChild(name, true)
        if found then return found end
        task.wait(0.2)
    until os.clock() > deadline
    return nil
end

-- WHY THE RAW PASTE WORKS AND A LOADER DOES NOT.
--
-- safeRequire(RS.Client.EggState) cannot protect itself. Lua evaluates the
-- ARGUMENT before the call, so `RS.Client.EggState` is indexed outside the
-- pcall - and indexing a child that has not replicated yet does not return
-- nil, it throws:
--     "Client is not a valid member of ReplicatedStorage"
-- Proven in the live client: pcall around safeRequire still failed, because
-- the error happens at the call site.
--
-- Pasting by hand happens after the game has finished loading, so every folder
-- is there and the line is harmless. A key-system loader auto-executes on
-- join, and whichever of ReplicatedStorage's folders has not arrived yet kills
-- the whole script on that line - or, if it survives, leaves AssetsDir and
-- friends nil, which is how egg names, values and the whole target list end up
-- wrong.
--
-- needModule walks the path with WaitForChild, so it waits for replication
-- instead of assuming it. Same result on a loaded client, no crash on a cold
-- one.
local function needModule(root, ...)
    local node = root
    for _, name in ipairs({ ... }) do
        if not node then return nil end
        local ok, child = pcall(function()
            return node:WaitForChild(name, 20)
        end)
        node = ok and child or nil
    end
    if not node then return nil end
    local ok, mod = pcall(require, node)
    return ok and mod or nil
end

local function safeRequire(path)
    local ok, mod = pcall(require, path)
    return ok and mod or nil
end

local packages = waitFor(RS, "Packages")
local net = waitFor(packages, "Networking")
if not net then
    BlyxoSplash.fail("Networking not found - are you in Steal An Egg?")
    Rayfield:Notify({ title = "BlyxoHub", content = "Networking not found - are you in Steal An Egg?",
        icon = "rbxassetid://95108798243406", duration = 6 })
    return
end
BlyxoSplash.step("Hooking networking", 0.38)

local AskFieldEggCarry = deepFind(net, "RF/EggWorld/AskFieldEggCarry")
local FieldEggCarryRE = deepFind(net, "RE/EggWorld/FieldEggCarry")
local OwnerDroppedRE = deepFind(net, "RE/EggWorld/OwnerDropped")

BlyxoSplash.step("Loading egg data", 0.45)
local EggState = needModule(RS, "Client", "EggState")
local AreaEggSlotIdentity = needModule(RS, "Shared", "Util", "AreaEggSlotIdentity")
local AssetsDirMod = needModule(RS, "Data", "Assets")
local AssetsDir = AssetsDirMod and AssetsDirMod.Directory
local Mutations = needModule(RS, "Shared", "Modules", "Mutations")
-- The game's own earnings maths. Preferred over our copy of the formula.
local AssetEarnings = needModule(RS, "Shared", "Util", "AssetEarnings")
-- Resolves WHICH PLOT IS OURS. See BX.homePos.
local PlotState = needModule(RS, "Client", "PlotState")


local objects = waitFor(Workspace, "__OBJECTS")
local areas = waitFor(objects, "Areas")
local GuardAreas = waitFor(areas, "GuardAreas")

if not (EggState and GuardAreas) then
    BlyxoSplash.fail("Game not fully loaded - rejoin and try again")
    Rayfield:Notify({ title = "BlyxoHub", content = "Game not fully loaded - rejoin and try again",
        icon = "rbxassetid://95108798243406", duration = 6 })
    return
end
BlyxoSplash.step("Mapping guard areas", 0.55)

---------- UI ----------

-- DISCORD, INSIDE THE LOADING CARD.
--
-- Must run BEFORE CreateWindow, as the old gate did: once Rayfield has built
-- its window it has already rendered, and hiding it afterwards is too late.
-- The ask itself is BlyxoSplash.discord() at the top of the file: the card
-- grows, shows the server with its live member count and a Join button, and
-- folds back once you join (or by itself after 25s).
BlyxoLoadT.game = os.clock()
BlyxoSplash.discord()
BlyxoLoadT.discord = os.clock()

BlyxoSplash.step("Building menu", 0.65)

-- ONE MENU, EVER. Re-executing built a second Rayfield window and nothing
-- unloaded the first: ~2,000 instances plus every connection the library
-- holds for them, still alive behind the new menu, once per re-run. The
-- previous copy publishes its window below; unload it before building ours.
pcall(function()
    local env = (type(getgenv) == "function" and getgenv()) or _G
    if env.__BLYXO_WINDOW and not env.__BLYXO_WINDOW.unloaded then
        env.__BLYXO_WINDOW:Unload()
    end
end)

local Window = Rayfield:CreateWindow({
    name = "BlyxoHub",
    subtitle = "Steal An Egg",
    icon = 95108798243406,
    showName = "BlyxoHub",
    sidebarLayout = true,
    profile = "Premium",
    theme = {
        AccentColor = Color3.fromRGB(255, 255, 255),
        AccentStroke = Color3.fromRGB(40, 40, 40),
        AccentGlow = 0.1,
        TextColor = Color3.fromRGB(220, 220, 220),
        BackgroundColor = Color3.fromRGB(12, 12, 12),
        ElementColor = Color3.fromRGB(20, 20, 20),
    },
    configuration = {
        autoSave = false,
        autoLoad = false,
        fileName = "BlyxoHub_StealAnEgg",
    },
})
;((type(getgenv) == "function" and getgenv()) or _G).__BLYXO_WINDOW = Window

-- THE MENU WAITS FOR THE CARD.
--
-- The Discord step no longer holds the load up, so the menu finished building
-- and showed behind the loading card while Join / Continue were still on it.
-- Rayfield's own ScreenGui is switched off here and back on the moment the
-- card goes (BlyxoSplash.whenClosed) - Enabled rather than ToggleHide, so no
-- "Tap to show" pill appears in between. With no loading card at all, the
-- callback runs at once and nothing is hidden.
pcall(function()
    local root = (gethui and gethui()) or game:GetService("CoreGui")
    local sg
    for _ = 1, 20 do
        local ci = root:FindFirstChild("CollapsedIcon", true)
        if ci and ci.Parent and ci.Parent.Name == "BlyxoHub" then
            sg = ci:FindFirstAncestorOfClass("ScreenGui")
        end
        if sg then break end
        task.wait(0.05)
    end
    if sg then
        sg.Enabled = false
        BlyxoSplash.whenClosed(function() sg.Enabled = true end)
    end
end)

local TRACE = true
local TRACE_FILE = "BlyxoHub_trace.txt"
local traceBuf = {}
local traceFlushAt = 0
local TRACE_FLUSH_GAP = 1.0   -- seconds between writes of the log file

-- Most console lines per second. Eight is plenty to follow a run by eye; a
-- relocate storm produces far more and is what filled the executor's log to
-- its cap before the client went down.
--
-- It lives on traceBuf, NOT on K. `local K = {}` is declared about 170 lines
-- below this, and trace() is called before that - so `K.anything` here would
-- index a nil and kill the script at load for everyone. That mistake has been
-- made twice in this file already.
traceBuf.budget = 8

-- LITE MODE: MEASURED, NOT A TOGGLE THE USER HAS TO FIND.
--
-- Phones and weak laptops run this at 10-20fps, and the things that cost most
-- there are the ones that run per frame or per log line. Rather than ask
-- people to guess, sample the real frame time for a few seconds after load and
-- turn the expensive extras down if the client cannot afford them.
--
-- Nothing that affects whether a steal WORKS is touched - only how much the
-- script draws and prints.
-- A PLAIN LOCAL, NOT A FIELD ON BX.
--
-- BX is not declared until line ~495 and trace() lives up here, so writing
-- BX.lite at this point indexed a nil and killed the script on load:
--     [string ""]:225: attempt to index nil with 'lite'
-- A local declared here is visible to everything below it, which is all
-- this flag ever needed.
local liteMode = false
local LITE_FPS = 25          -- below this we are on a weak client
local LITE_SAMPLE = 4        -- seconds of frame times to average first
local traceStart = os.clock()
local canWriteFile = (typeof(writefile) == "function")
local function trace(msg)
    if not TRACE then return end
    local text = tostring(msg)

    -- SAY IT ONCE.
    --
    -- Every trace line is mirrored to the executor's console, and several of
    -- them repeat on a timer - the idle loop alone produced four prints a
    -- second, forever. Over a session that is tens of thousands of lines
    -- sitting in the log window, which is real memory and real main-thread
    -- work, and it is what filled Madium's buffer to its 5000-line cap before
    -- the client went down.
    --
    -- Identical consecutive lines are now dropped outright. Anything that
    -- actually changes still comes through immediately, so nothing diagnostic
    -- is lost - only the repetition. Stored on traceBuf rather than a new
    -- local because this chunk is near Luau's 200-local ceiling.
    if text == traceBuf.lastMsg then
        traceBuf.repeats = (traceBuf.repeats or 0) + 1
        return
    end
    if (traceBuf.repeats or 0) > 0 then
        local n = traceBuf.repeats
        traceBuf.repeats = 0
        traceBuf.lastMsg = nil
        trace(("(the line above repeated %d more times)"):format(n))
    end
    traceBuf.lastMsg = text
    traceBuf.repeats = 0

    local line = string.format("[%7.2fs] %s", os.clock() - traceStart, text)
    -- The console mirror is not free on a weak client - every print crosses
    -- into the executor's log window. On lite clients only the important
    -- lines go to the console; the FILE still gets everything, so nothing is
    -- lost for diagnosis.
    -- A BUDGET, NOT JUST A DEDUPE.
    --
    -- The identical-line dedupe above cannot help here, and this is why the
    -- spam came back: the loudest line in the script is
    --
    --     relocate: #91 - backing off 3s
    --     relocate: #92 - backing off 3s
    --
    -- and the counter makes every one of them a DIFFERENT string. Ninety of
    -- those in a minute all print. Same for anything carrying a distance, a
    -- time or a count - which is most of the useful lines.
    --
    -- So the console mirror gets a hard budget per second. Over it, printing
    -- stops and the file keeps everything, so nothing is lost for diagnosis -
    -- only the log window is spared. One line says it happened, and normal
    -- printing resumes as soon as the second is quiet again.
    --
    -- Session markers and errors always print; those are the ones worth an
    -- interruption.
    local important = line:find("===", 1, true) or line:find("ERR", 1, true)
    -- Console mirror only when debugging (getgenv().BlyxoDebug) - see "A
    -- QUIET CONSOLE" at the top. The file below is written either way.
    local debugOn = (type(getgenv) == "function" and getgenv().BlyxoDebug) or _G.BlyxoDebug
    if debugOn and (not liteMode or important) then
        local sec = math.floor(os.clock())
        if traceBuf.printSec ~= sec then
            traceBuf.printSec = sec
            if (traceBuf.printMuted or 0) > 0 then
                print(("[BLYXO] (%d lines held back last second - the file has them all)")
                    :format(traceBuf.printMuted))
            end
            traceBuf.printMuted = 0
            traceBuf.printCount = 0
        end
        traceBuf.printCount = (traceBuf.printCount or 0) + 1
        if important or traceBuf.printCount <= (traceBuf.budget or 8) then
            print("[BLYXO] " .. line)
        else
            traceBuf.printMuted = (traceBuf.printMuted or 0) + 1
        end
    end
    if not canWriteFile then return end
    traceBuf[#traceBuf + 1] = line
    if #traceBuf > 400 then table.remove(traceBuf, 1) end

    -- THIS WAS THE LAG.
    --
    -- It concatenated the whole 400-line buffer and writefile'd it on EVERY
    -- trace call. A busy second produces dozens of lines, so that was dozens
    -- of full-log disk writes per second, each rebuilding a string of several
    -- kilobytes, on the same thread as the steal loop. It is the single most
    -- expensive thing the script did, and it did it constantly.
    --
    -- The stated reason was not losing the last lines before a kick. A timed
    -- flush keeps almost all of that - at worst the final second is missing -
    -- and the console mirror above is still printed immediately. Session
    -- markers flush at once, so the head of a run is never lost.
    local now = os.clock()
    if line:find("===", 1, true) or (now - traceFlushAt) >= TRACE_FLUSH_GAP then
        traceFlushAt = now
        pcall(writefile, TRACE_FILE, table.concat(traceBuf, "\n"))
    end
end
trace("=== BlyxoHub Steal An Egg loaded ===")

-- SAY IT OUT LOUD IF A CORE MODULE IS MISSING.
--
-- The FlowAuth loader runs this script inside a coroutine (its runtime is
-- Luraph-obfuscated and uses coroutine.* throughout), and an error raised in a
-- coroutine nobody resumes is SILENT. So a half-initialised script - egg names
-- blank, values zero, target list wrong - looks like "the loader version is
-- just worse" instead of like a failure.
--
-- These six modules are what everything reads from. If any is missing after
-- needModule has already waited 20s per hop, the client is not going to
-- produce it, and the user should be told rather than left guessing.
do
    local missing = {}
    if not EggState then missing[#missing + 1] = "EggState" end
    if not AssetsDirMod then missing[#missing + 1] = "Data.Assets" end
    if not AreaEggSlotIdentity then missing[#missing + 1] = "AreaEggSlotIdentity" end
    if not Mutations then missing[#missing + 1] = "Mutations" end
    if not AssetEarnings then missing[#missing + 1] = "AssetEarnings" end
    if not PlotState then missing[#missing + 1] = "PlotState" end

    if #missing > 0 then
        local msg = "Game modules missing: " .. table.concat(missing, ", ")
            .. " - the game had not finished loading. Wait for the map, then run again."
        trace("=== STARTUP INCOMPLETE: " .. msg .. " ===")
        pcall(function()
            Rayfield:Notify({ title = "BlyxoHub", content = msg,
                icon = "rbxassetid://95108798243406", duration = 10 })
        end)
    else
        trace("=== startup: all game modules resolved ===")
    end
end

-- WHY TWO PEOPLE RUNNING THE SAME SCRIPT GET DIFFERENT SPEEDS.
--
-- The fast travel comes from raising WalkSpeed and keeping the client
-- anticheat's own record clean, and finding that record needs getgc(true) to
-- return TABLES. Executors differ here: measured on this machine getgc(true)
-- returns 39,371 tables and the spoof arms; an executor without getgc, or one
-- whose getgc only yields functions, can never arm it and falls back to
-- K.ARC_SPEED_NOSPOOF.
--
-- That fallback is also why the far areas fail for those users: Titan Temple's
-- guard chases at 918 studs/s and Cherry Blossom's at 888, so a 500 studs/s
-- carry is caught every time. It is not the anticheat "being harsher" on their
-- account - they are simply slower.
--
-- Printed once at load so a report says which mode it was in.
task.spawn(function()
    local why
    -- NO HEAP SWEEP JUST TO PRINT A NUMBER. This walked getgc(true) - every
    -- object in the VM, ~39k tables here and far slower on a phone executor -
    -- at load, only to count them for this one line. On Delta that is a
    -- visible freeze before the menu is even usable. Presence is enough.
    if type(getgc) ~= "function" then
        why = "no getgc - travel limited to what the anticheat allows"
    else
        why = "getgc available"
    end
    trace("=== SPEED MODE: " .. why .. " ===")
end)
trace("=== BUILD: v45 - tween OUT (server clamps far teleports), teleport HOME ===")

-- Notify builds Instances, so it fails on any thread that has been narrowed by
-- a game-module call - which the steal loop is, constantly. A fresh task.spawn
-- thread is clean (measured), so notifications keep working mid-farm instead of
-- never once worked. Measured in the live client:
local toast
do
    local queue = {}
    local reported = false

    function toast(msg)
        queue[#queue + 1] = tostring(msg)
    end

    -- SMALL, RATE-LIMITED NOTES - for anything that can repeat on its own.
    --
    -- The rift code was toasting from inside loops: "waiting for <pet>" every
    -- 8 seconds for as long as the pet was not on the map, "all pets ready"
    -- again every time the owned count flickered, and the pity counter on
    -- every step near the threshold. Each one a full notification card.
    --
    -- BlyxoNote(key, msg, cooldown) shows at most one note per key per
    -- `cooldown` seconds (default 60), whatever the text says, and draws it as
    -- Rayfield's compact Toast pill at the bottom of the screen instead of a
    -- card. A global rather than a local: this chunk is at the register
    -- ceiling (see the top of the file).
    -- ONE MESSAGE PER STEAL.
    --
    -- A single delivered egg used to announce itself four times: the claim
    -- watch ("Egg delivered: <name>"), the trip home ("Egg delivered" or
    -- "...pick your next one"), the loop releasing the selection ("Egg done -
    -- pick your next one") and then "Pick an egg to steal". All four now
    -- report here; the first opens a 1.2s window, the rest add what they know
    -- (the egg's name, whether you need to pick), and one message goes out:
    --     "Stole Mantaris - pick your next one"
    -- Anything that reports within 6s after that is the same steal, and says
    -- nothing.
    local steal = { pending = false, name = nil, pick = false, lastAt = -100 }
    function BlyxoStealDone(name, pick)
        if name and tostring(name) ~= "egg" then steal.name = tostring(name) end
        if pick then steal.pick = true end
        if steal.pending or os.clock() - steal.lastAt < 6 then return end
        steal.pending = true
        task.delay(1.2, function()
            local msg = "Stole " .. (steal.name or "an egg")
            if steal.pick then msg = msg .. " - pick your next one" end
            queue[#queue + 1] = msg
            steal.lastAt = os.clock()
            steal.pending, steal.name, steal.pick = false, nil, false
        end)
    end
    -- "Pick an egg" right after a steal is part of that steal's message.
    function BlyxoPickPrompt(msg)
        if steal.pending then steal.pick = true return end
        if os.clock() - steal.lastAt < 8 then return end
        queue[#queue + 1] = tostring(msg)
    end

    local lastNote = {}
    function BlyxoNote(key, msg, cooldown)
        local now = os.clock()
        key = tostring(key)
        if lastNote[key] and now - lastNote[key] < (cooldown or 60) then return end
        lastNote[key] = now
        -- One pending note per key: a burst collapses to its latest text.
        for i = #queue, 1, -1 do
            if type(queue[i]) == "table" and queue[i].key == key then table.remove(queue, i) end
        end
        queue[#queue + 1] = { key = key, text = tostring(msg) }
    end

    -- ONE NOTIFICATION, ONE PLACE.
    --
    -- Every message goes out as the small pill at the bottom centre
    -- (Window:Toast). The bottom-right card (Window:Notify) is only the
    -- fallback for the older library URL, which has no Toast.
    --
    -- And one per event: things that happen together used to stack - toggle
    -- rift auto and get "Rift auto ON", "Auto Steal ON" and more at once. The
    -- worker now lets a burst finish arriving (0.35s), shows only its LAST
    -- message - the most specific one - and never repeats the same text
    -- within 4s.
    task.spawn(function()
        local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
        local lastText, lastAt = nil, -100
        while true do
            if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
            if #queue > 0 then
                task.wait(0.35)
                local item = queue[#queue]
                table.clear(queue)
                local text = type(item) == "table" and tostring(item.text) or tostring(item)
                if not (text == lastText and os.clock() - lastAt < 4) then
                    lastText, lastAt = text, os.clock()
                    local ok, err = pcall(function()
                        if type(Window.Toast) == "function" then
                            Window:Toast({ title = text, duration = 2.5, position = "Bottom",
                                icon = 95108798243406 })
                        else
                            Window:Notify({ title = "BlyxoHub", content = text,
                                icon = "rbxassetid://95108798243406", duration = 3 })
                        end
                    end)
                    if not ok then
                        if not reported then
                            reported = true
                            trace("toast: notification failed even from the worker -> " .. tostring(err))
                        end
                        print("[BLYXO] " .. text)
                    end
                end
            end
            task.wait(0.1)
        end
    end)
end

BlyxoTop.hideKey = UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        pcall(function() Window:ToggleHide() end)
    end
end)

---------- CONFIG ----------

-- 250 is the ONLY speed we have observed a full clean farming session at.
-- 500 (what the reference build uses) coincided with a kick, but that run also
--   280-290 studs/s -> zero relocates, steals succeed
--   800-850 studs/s -> 4 relocates inside 0.09s, steal returned carried=false
-- WalkSpeed * 1.7 + tolerance, which at the measured WalkSpeed of ~160-171 is
-- roughly 270-290 studs/s. 800 is about three times that. It is the user's
-- call, but the relocate bursts in the trace are the cost of it.
-- 800. Measured working: "return: CARRYING - tween at 800 studs/s
local TWEEN_SPEED = 800
-- Tuning constants live on one table: the main chunk is at Luau's 200-local
-- ceiling and each of these being its own local is what overflowed it.
local K = {}

-- Below this, a WalkSpeed reading is not ours - it is Roblox's default 16
-- (BASE_WALK_SPEED) showing through during a respawn or a rig swap before the
-- server's WalkSpeedGovernor has pushed our real value back.
-- Guarding on "> 0" did not catch it, because 16 is greater than zero. The
-- cost, measured:
-- Every area judged unbeatable against a WalkSpeed of 16, the egg list emptied,
K.WALKSPEED_SANE_MIN = 40
local noclipGated = true
-- Measured live against this game's server reconciliation:
--   single jump <=110 studs -> accepted;  >=130 -> reverted in ~0.1s
--   hops paced on Heartbeat  -> 700 studs in 0.08s (~8900 studs/sec)
--   LONGER gaps are worse: at 0.1s the server has time to correct between
-- Ground-snapping every hop is required; without it you snag and crawl.
local MOVE_MODE = "Tween" -- outbound leg; the return leg uses BX.returnToSafe
K.HOP_DISTANCE = 100 -- used by hopMoveTo (TP-home fallback)
K.HOP_GAP = 0 -- 0 = pace hops on Heartbeat, which is what survives
-- MEASURED walkable region: the map is a strip. Collidable floor spans
-- x 400..5100 at z -370, flat at y 67.58, continuous with no gaps.
-- After the server relocates us, wait this long before writing CFrame again.
-- Fighting a relocate is what escalates one correction into a burst.
K.RELOCATE_COOLDOWN = 3

-- Relocate-burst safety. Three corrections inside ten seconds is the server
-- shouting; give speed back before it escalates to a kick.
K.RELOCATE_WINDOW = 10
K.RELOCATE_BURST_LIMIT = 3
K.RELOCATE_SPEED_DROP = 150
K.RELOCATE_SPEED_FLOOR = 250



K.SNAP_MAX = 12

K.NO_PROGRESS_LIMIT = 2


-- Long legs are split into segments no bigger than this.
--
-- This was 300, which is why movement stuttered: every segment ends its tween,
-- has a real one (K.NO_PROGRESS_LIMIT) that fires in 2s regardless of leg length.
K.MAX_SEGMENT = 1500

-- How many stalled segments a single route tolerates before giving up.
K.MAX_STALL_RETRIES = 3

-- How long an egg we could not reach, or could not carry, is skipped for.
-- Long enough that the loop moves on to a different egg instead of grinding
-- the same unreachable one; short enough that a one-off relocate does not
K.UNREACHABLE_COOLDOWN = 45

K.ZIGZAG_WIDTH = 45
K.ZIGZAG_SEGMENT = 220

K.CORRIDOR_Z = -370
-- WALL SAFETY. The walkable band is only about z -455..-285 and the walls sit
-- right on those numbers, so "inside the band" is NOT the same as "safe" -
-- the middle corridor (-370) whenever it has a choice.
K.WALL_SAFE_Z_MIN = -425
K.WALL_SAFE_Z_MAX = -305

-- THE GUARD'S CEILING IS base * 4, NOT base.
--
-- GuardChasePolicy.ResolveWalkSpeed:
-- base. And ResolveCatchDuration compares that against our WalkSpeed stat -
-- That is why a 2.31s carry from Abyss Ocean still lost the egg: 130 * 4 =
K.OUTRUN_MARGIN = 4.0
-- Safe side is Ground x 379..551; the GameplayZ gate is x 552..554. 545 puts
-- us 7 studs inside the safe zone - the shortest crossing that can claim.
K.SAFE_EDGE_X = 545

-- THE SAFE SIDE, as a box. Measured off the live client, not guessed -
-- Workspace.__OBJECTS.Areas, world-space spans:
-- when this was measured (545.3, 70.6, -399.5).
-- z=-500 is on the safe floor but behind 2048 studs of wall, and a crossing
K.SAFE_ZONE_X_MAX = 551
K.SAFE_ZONE_Z_MIN = -434
K.SAFE_ZONE_Z_MAX = -297
K.SAFE_FALLBACK_Z = -364      -- the SeparationLine's own Z, mid-doorway
K.SAFE_STAND_Y = 70.58        -- Ground top 67.58 + GROUND_OFFSET

-- Budget for the one-shot return. The reference clip banks the egg within a
-- few frames of landing, so these are a net under one dropped packet, not a
-- retry strategy. The old code spent 12.5s here re-asserting positions and
K.SAFE_TP_WINDOW = 1.2        -- seconds of light re-assert after the jump
K.SAFE_TP_REASSERT = 0.1      -- gap between those re-asserts
K.SAFE_TP_CLAIM_TAIL = 0.6    -- listen-only tail, for a late FieldClaimed
K.SAFE_TP_PLOT_WINDOW = 2.5   -- only reached when BX.safeTpPlotFallback is on

-- ===================================================================
-- MEASURED ON A QUIET SERVER. Read this before touching teleport again.
-- server is SILENT at rest: 0 relocates in 5s of standing still, and a CFrame
-- write inside the safe zone sticks perfectly with 0 relocates.
--     50 studs  -> HELD      0 relocates
--    100 studs  -> HELD      0 relocates
--    200 studs  -> HELD      0 relocates
--    400 studs  -> reverted after 0.42s, 1 relocate

-- THE OUTBOUND STEAL RACE. See the long note in carryEgg for the measurements.
-- CarryFieldEgg blocks ~160ms (it is a RemoteFunction) and the server relocates
-- a bare PivotTo after ~170ms, so one serial invoker samples the server slower
-- its own thread, sample every ~50ms instead. Measured time to acceptance:
--   serial + hold 0.875s/5 calls | 3x50ms 0.262s & 0.345s/5-6 | 4x40ms 0.360s/8
K.CARRY_RACE_THREADS = 3
K.CARRY_RACE_STAGGER = 0.05

-- ONE LEGAL JUMP. The ladder above says a single hop of <=200 studs lands and
-- is HELD with zero relocates, while 400 is reverted in 0.42s. 180 keeps a
-- margin under the measured ceiling. This is the move the server always takes,
K.LEGAL_JUMP = 180
K.LEGAL_JUMP_SETTLE = 0.12

-- How far outside the corridor box still counts as "on the map". The box is
-- a routing aid, not a map boundary, and treating it as one made the void
-- watch teleport us back off perfectly solid ground.
-- Consecutive failed ground probes before we believe a fall. At 0.2s per
-- sample that is 0.6s of no floor at all.
K.VOID_MISSES_NEEDED = 3
-- ...and we must actually be BELOW the last ground we stood on by this
-- much. A miss while standing on a nest is not a fall.
K.VOID_DROP_PROOF = 25
K.VOID_BOUNDS_SLACK = 400
K.CORRIDOR_X_MIN = 430
K.CORRIDOR_X_MAX = 5070
K.CORRIDOR_Z_MIN = -455
K.CORRIDOR_Z_MAX = -285

local autoCalibrate = false
-- Ceiling was 290 on the assumption that ~300 studs/s was a kill threshold.
-- That was wrong: the reference build runs 500 without being kicked, and the
-- real trigger was our direct egg-remote calls. Raised accordingly.
local calibMin, calibMax = 200, 800    -- 1200 relocates on long trips; see TWEEN_SPEED
local calibUpStep, calibDownStep = 25, 50
local calibNeeded = 3
local calibSuccesses = 0
local calibStats = { ok = 0, fail = 0 }
local calibLabel = nil
-- Was 0.5s. The game's own client calls AskFieldEggCarry ONCE and then
-- listens to EggState.CarryChanged. Invoking a RemoteFunction twice per
local PROTECT_INTERVAL = 6
local CARRY_LOCK_TIMEOUT = 3
local GUARD_Y_OFFSET = -7
local SAFE_ZONE = CFrame.new(157, 55, -52)
local GROUND_OFFSET = 3
-- Fallback only. This hardcoded point is NOT your base.
--
-- MEASURED: ReplicatedStorage.Client.PlotState reports
-- 512,68,-362 sits next to PLOT 1, 165 studs from ours. Plots are assigned per
-- return leg was carrying every stolen egg to a stranger's base, which is why
-- getting home never actually accomplished anything.
local SAFE_POS_FALLBACK = Vector3.new(512, 68, -362)
local SAFE_POS = SAFE_POS_FALLBACK

---------- STATE ----------

local stealing = false
local isProtecting = false
local isMoving = false
local carryLocked = false
local guardManipEnabled = false
local heldEggUid = nil
local heldEggSlotKey = nil
-- Gap between steal cycles. Was 1s of dead time on every egg; the loop already
-- waits on real events (the carry, the ragdoll, the re-grab), so this only ever
-- added latency. The UI input still clamps it if you want it slower.
local stealDelay = 0.15
local selectedEggUid = nil
local cachedEggs = {}
local eggDropdown = nil

local stolenUids = {}

local stopProtect  -- forward declaration: BX.armMonsterGuard is defined above it
-- Luau allows only 200 locals per scope and this chunk was already near the
-- ceiling, so all anticheat state and helpers live on one table instead of
-- burning a register each.
local BX = {
    -- uid -> tick() when we last failed to reach or carry it. Read in
    -- stealLoop's target pick; see K.UNREACHABLE_COOLDOWN.
    unreachable = {},
    -- Set true to restore the old behaviour of noclipping while carrying an
    -- egg. See the note in cfMoveTo: phasing the SafeZoneBarriers with an egg
    -- nest", which lands 0.07s into the leg that crosses into the plot.
    noclipWhileCarrying = false,
    -- Anti-trap. See the PLAYER TRAPS block below isRagdolled().
    avoidTraps = true,
    trapRadius = 14,
    trapHits = 0,
    -- Set by cfMoveTo, read through waitForMove(). nil until the first route.
    routeOk = false,
    routeFail = nil,
    carryConn = nil,
    rigConn = nil,
    monConn = nil,
    stalled = false,
    activeTween = nil,
    activeTweenConn = nil,
    savedWalkSpeed = nil,
    allowRemoteCarry = false,  -- opt-in fallback only
    -- INSTANT STEAL. EggWorld.AskFieldEggCarry is a RemoteFunction, so
    -- EggState.CarryFieldEgg returns the server's own verdict SYNCHRONOUSLY.
    -- every "prompt fired but state is Slot - retrying" and up to 450ms of a
    -- 630ms window. Measured live against a Forest egg:
    -- Instant, authoritative, and it tells us WHY when it refuses. The server
    -- validates two things and neither is a timer: you must be in the
    -- gameplay area ("Enter the gameplay area first") and within ~10-14 studs
    instantCarry = true,
    -- TELEPORT MODE - OPT IN, UNVERIFIED. Set true to replace BOTH travel legs
    -- with a single CFrame set. You asked for this; here is what the file's
    --     at carry time, which is why the last 70 studs are walked with real
    --   * return:   "one PivotTo, ~4000 studs -> arrived, egg State=Dropped".
    -- BOTH of those were measured with ReadFieldEgg().State - the field that
    -- MEASURED OFF. Not a preference - a single large CFrame write does not
    --   set hrp.CFrame 4256 studs to a Titan Temple egg
    --     t+0.25 pos=549,-358   (never moved)
    teleportMode = false,
    tpSettle = 0.35,
    -- BAIL AT 3s. Was 8, on the belief that far areas legitimately needed
    -- 5.28s. They do not - see the race note in carryEgg: a steal that is
    -- going to land lands inside ~0.4s at any distance, so the extra five
    -- Anything still refusing at 3s is refusing for a reason more time will
    tpStealTimeout = 3,
    -- NO DISTANCE GATE. Teleport is attempted for EVERY egg.
    --
    -- With 900 here, any egg further than 900 studs from the plot - which is
    -- most of the map - skipped the teleport entirely, tweened to 70 studs
    -- short of the nest, and stopped there, because the final approach was
    -- refuses, carryEgg bails in 3s and the loop takes another egg.
    -- Historical note kept because the reasoning was wrong and should not be
    -- timings it produced (0.26s acceptance, distance irrelevant) measure
    tpOutMaxDist = math.huge,
    -- The tile the trip departed from, on the safe side of the separation
    -- line. Set by BX.captureSafeAnchor and used by BX.safeReturnCF as the
    -- destination for a carried egg. nil until we have stood somewhere legal.
    tpAnchorCF = nil,
    tpAnchorAt = 0,
    -- Second leg of the return (re-assert at the plot) after the safe-zone
    -- line failed to claim. OFF: the reference clip never goes to the base,
    safeTpPlotFallback = false,
    -- RIDING IS OFF, and the game files say why.
    --
    -- Decompiled GuardChasePolicy.ResolveCatchDuration:
    --     if playerSpeed >= ResolveWalkSpeed(guardBase, ref, dist) then
    --         return nil          -- never caught
    -- and ResolveWalkSpeed returns the guard's BASE speed while the distance
    -- matters is base speed vs ours. From Data.Guards:
    -- Our WalkSpeed is 204.7, so nine of the eleven can never catch us. Only
    rideGuardEnabled = false,
    -- Target areas whose guard out-runs us anyway. Off: those eggs cannot be
    -- delivered at our WalkSpeed, and chasing them is why every "best egg"
    -- What I read out of GuardChasePolicy still stands as code - the guard's
    -- not a hard ceiling, because someone at our speed does it. Something in
    -- WAS true, which bypassed the guard-speed check entirely. With the speed
    -- spoof gone that check is the only thing standing between the user and
    -- an area whose guard is twice as fast as the carry.
    ignoreGuardSpeed = false,
    -- DECOY IS OFF. DISPROVED, and it was actively harmful.
    --
    -- dropping an egg creates one. Measured on the Snow guard, sampling its
    -- GuardState attribute every 0.5s after a deliberate
    --   +0.5s after the drop    ReturningHome  ws=147  x=1454
    --   +1.5s                   ReturningHome  ws=0    x=1492 (home)
    --   +2.0s onward            Sleeping
    -- It never enters RetrievingEgg. A player-requested drop just sends the
    decoyEnabled = false,
    -- Pick up and drop an egg in the FIRST area before each real steal. Done
    -- on observation of several working scripts; see the FIRST-AREA PRIME
    -- going to the first egg" the reference never does, and it has never been
    -- you were getting. The prime already visits the Forest guard (WalkSpeed
    -- 16, HitDistance 2.5, right next to the safe zone), so if a hit is worth
    takeHitOnSteal = false,

    primeEnabled = true,

    -- ARC TRAVEL. Climb while speeding up, cruise flat at top speed, dive
    -- while slowing, then a slow final approach inside 50 studs; and on the
    -- one travels at floor level, which is why it needed the three-leg
    -- corridor routing, and it is the thing the notes below measured as
    arcEnabled = true,
    -- FLIGHT IS OFF. It is what was killing you, and I measured the kill.
    --
    --   0.31s x=910    fine
    --   0.45s x=545    SNAPPED BACK
    --   1.21s x=1360   second attempt
    --   1.36s x=545    snapped back
    --   2.40s x=1550   third attempt
    --   2.55s x=545    snapped back
    flyEnabled = false,
    flyOutbound = false,
    -- HOVER WALK: raised WalkSpeed + raised HipHeight, then ordinary walking.
    -- Established by frame-stepping a filmed working run - see the block above
    hoverEnabled = true,
    -- Stand and take a guard hit before carrying home, so the chase the steal
    -- rouses is resolved rather than left open. Only safe because
    -- OFF. Measured, not argued. v98 turned this ON on the theory that the
    --    9.74  DROP: carry ended, reason=not reported     <- 0.81s after steal
    --   10.00  SERVER RigSync -> BeginRagdoll             <- hit lands 0.26s LATER
    --   10.01  hit: taken after 1.08s - egg still held=false
    -- itself lands, and BX.blockEggDrop cannot stop that because the server
    -- initiates it - the client is never asked. So waiting for a hit with the
    wantGuardHit = false,
    -- OFF. It reorders the egg list so only nearby areas come up, which makes
    -- the picker useless for choosing what you actually want. The distance
    -- theory did not pan out either - short trips were refused too.
    -- OFF: THIS IS A DISPLAY ORDER, AND IT WAS HIDING TITAN TEMPLE.
    --
    -- Turning it on sorted out-of-budget eggs to the bottom of cachedEggs -
    -- and the Target Egg dropdown only renders the first UI.MAX_EGGS (25) of
    -- 53. Titan Temple sits 4191 studs out, past K.CARRY_MAX_DIST, so all five
    -- of its eggs fell off the end of the list and became unselectable. Same
    -- for anything else far out.
    --
    -- The list the USER picks from should be sorted by what is worth stealing.
    -- Bankability belongs in the AUTO-pick instead, which is where the far-egg
    -- problem actually lived - see UI.bestBankable below.
    preferCloseEggs = false,
    -- Move by stepped CFrame with the client anticheat's own record rewritten
    -- to match, for both the outbound leg and the carry. See the block above
    -- v89 note, kept because it is why this was ever turned off: spoofCarry is
    -- hrp.CFrame at a fixed point every Heartbeat for K.PIN_HOLD (6s), which is
    -- voids the transport, and three times the ~2s the guard needs to reach us.
    spoofCarry = true,
    spoofOutbound = true,
    -- HOVER ON THE CARRY: OFF.
    --
    -- Hover walk moves by WalkSpeed, and the game hard-caps WalkSpeed at 300
    -- (ResolveFinalWalkSpeed(1e18) still returns 300; its only multiplier
    -- argument is constrained to (0,1], so multipliers reduce, never boost).
    -- voids the delivery. So the carry cannot get its speed from WalkSpeed.
    -- It gets it from the tween instead - CFrame translation, WalkSpeed left
    -- legal - which is also what the reference must be doing, since it covers
    hoverCarry = false,
    -- Carry by real walking (Humanoid:MoveTo) rather than by CFrame tween.
    -- The tween is what produced vel=0 while the position moved; see the
    -- measured manual baseline quoted at the carry dispatch.
    walkCarry = true,
    -- Velocity-driven carry (K.VEL_CARRY_SPEED). OFF: tested at 380 with a
    -- legal WalkSpeed and PlatformStand off, and the delivery was still
    -- refused. The walk carry below is the only mode measured to deliver
    -- been left true, so every carry under K.FAST_CARRY_MAX_DIST (450 studs)
    -- took the velocity branch at >=500 studs/s - the exact mode described here
    velCarry = false,
    eggCacheAt = 0,
    trapConn = nil,
    lastEggUid = nil,
    lastEggSlot = nil,
    lastEggPos = nil,
    trapBlocks = 0,
    sessionId = nil,
    sessionStart = 0,
    -- Always false now: the Follow Best Egg toggle was removed. Your
    -- selected egg is never silently swapped for a different one; the
    -- loop only auto-picks when you have not chosen anything.
    followBest = false,
    swapped = false,
    swapEnabled = true,    -- proven path: see BX.swapHumanoid
    probing = false,       -- guards the authority probe in diagnoseStall
    valueCache = {},       -- uid -> income/s, rebuilt each evaluateEggs pass
    valueCacheNext = {},
    lastReassert = 0,
    reassertCount = 0,
    REASSERT_GAP = 2.5,
    SWAP_ATTR = "BlyxoStealHum",
}
-- Published so the NEXT copy can disconnect every BX.*Conn this one opens -
-- see "AND DISCONNECT WHAT THE PREVIOUS COPY LEFT BEHIND" at the top.
((type(getgenv) == "function" and getgenv()) or _G).__BLYXO_BX = BX
local activeGuardClone = nil
local activeGuardArea = nil
local originalGuardData = nil

local moveConnection = nil
local moveGeneration = 0
local cfMoveTo
local protectThread = nil
local stealThread = nil

local originalAtmosphereDensities = {}
local fpsUnlocked = false
local antiKickEnabled = false
local originalKick = nil
local autoFeedEnabled = false
local autoFeedThread = nil
local guardEnforceConn = nil
local acEnforceConn = nil
local antiDeathConns = {}
local noclipConn = nil
local originalHumanoidState = nil
local fieldEggCarryHooked = false
local ownerDroppedHooked = false
local originalEffectEnabled = {}

---------- UTILITIES ----------

local function getChar() return LocalPlayer.Character end
local function getHRP()
    local c = getChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHumanoid()
    local c = getChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

-- Network ownership check to ensure we can move parts
local function hasNetworkOwnership(part)
    if typeof(isnetworkowner) == "function" then
        local ok, owned = pcall(function() return isnetworkowner(part) end)
        return ok and owned
    end
    return true -- Assume ownership if function not available
end

-- Server reconciliation detection and handling
local lastServerPosition = Vector3.zero
local correctionCount = 0
local lastCorrectionTime = 0

local function detectServerCorrection(currentPos)
    local now = tick()
    local dist = (currentPos - lastServerPosition).Magnitude

    -- If we moved significantly in a very short time, it's likely a server correction
    if dist > 10 and (now - lastCorrectionTime) < 0.1 then
        correctionCount = correctionCount + 1
        lastCorrectionTime = now
        return true
    end

    lastServerPosition = currentPos
    return false
end

local function getCorrectionCount()
    return correctionCount
end

local function resetCorrectionCount()
    correctionCount = 0
end

---------- EGG EVALUATION ----------

-- Adaptive precision: two decimals under 10 of a unit, one above, so you get
-- 6.78M and 15.8M rather than 6.8M and 15.8M. Trailing zeros are trimmed.
local function formatNumber(n)
    n = tonumber(n) or 0
    local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
    for _, u in ipairs(units) do
        if n >= u[1] then
            local v = n / u[1]
            local txt = (v < 10) and string.format("%.2f", v) or string.format("%.1f", v)
            txt = txt:gsub("%.?0+$", "")
            return txt .. u[2]
        end
    end
    return tostring(math.round(n))
end

-- Income per second.
--
-- The last three terms are the ones a hand-copy can never get right: gamepass
local function calcEggValue(rec)
    local hit = BX.valueCache[rec.Uid]
    if hit then
        BX.valueCacheNext[rec.Uid] = hit
        return hit
    end

    local item = {
        Category = rec.AssetCategory,
        Scale = tonumber(rec.AssetScale) or 1,
        Mutations = rec.Mutations or {},
    }

    local function remember(v)
        v = tonumber(v) or 0
        BX.valueCache[rec.Uid] = v
        BX.valueCacheNext[rec.Uid] = v
        return v
    end

    if AssetEarnings then
        local ok, rate = pcall(AssetEarnings.LiveRatePerSecond, item, nil, nil, LocalPlayer)
        if ok and type(rate) == "number" then return remember(rate) end
        -- LiveRatePerSecond needs a player; MutationOnlyRatePerSecond does not.
        ok, rate = pcall(AssetEarnings.MutationOnlyRatePerSecond, item)
        if ok and type(rate) == "number" then return remember(rate) end
    end

    local dir = AssetsDir[rec.AssetCategory]
    if not dir then return 0 end  -- not cached: the directory may not be loaded yet
    local baseRate = tonumber(dir.EarningRate) or 0
    local scale = item.Scale
    local scaleFactor = scale <= 5 and scale ^ 1.85 or (scale / 5) ^ 1.2 * 19.637875755794113
    local mutMult = 1
    pcall(function()
        mutMult = Mutations.EarningsFor(item.Mutations)
    end)
    return remember(math.max(1, math.round(baseRate * scaleFactor * (tonumber(mutMult) or 1))))
end

local function getEggDisplayName(rec)
    local dir = AssetsDir[rec.AssetCategory]
    return dir and dir.DisplayName or rec.AssetCategory
end

-- WHAT THE EGG WEIGHS, the number on the egg in game.
--
-- Data.Assets.Directory[cat].Egg.WeightKg is the BASE weight for that pet, and
-- every egg on the field is rolled with an AssetScale that stretches it. The
-- two together are what the game shows you:
--
--     Dodo   base 7.0kg  scale 1.043 ->  7.3kg
--     Dodo   base 7.0kg  scale 2.920 -> 20.4kg
--
-- Same pet, same income, nearly three times the egg. That is why weight is
-- worth targeting on its own, and - see UI.eggLabel - it is also what finally
-- tells those two Dodos apart in the list.
local function getEggKg(rec)
    local kg
    pcall(function()
        local d = AssetsDir and AssetsDir[rec.AssetCategory]
        local base = d and d.Egg and tonumber(d.Egg.WeightKg)
        if base then kg = base * (tonumber(rec.AssetScale) or 1) end
    end)
    return kg or 0
end

local function getEggRarity(rec)
    local dir = AssetsDir[rec.AssetCategory]
    if dir and dir.Rarity then
        return dir.Rarity.DisplayName or dir.Rarity._id or "?"
    end
    return "?"
end

-- WHICH EGGS THE FARM TAB WANTS.
--
-- Two sets, both empty by default, and empty means "no opinion" - so out of
-- the box this changes nothing at all. Picking "Abyss Ocean" and "Prehistoric"
-- narrows the candidate list to those areas; picking Legendary and Divine
-- narrows it to those rarities. Both together mean BOTH must match.
--
-- It belongs here, in the "which eggs exist" pass, and NOT in the steal loop.
-- The loop's job is how to take an egg and get home with it, and that logic is
-- not being touched. All this does is decide what goes on the list the loop
-- reads from - the same layer stolenUids and the guard-escape check already
-- work at.
BX.farmAreas = {}
BX.farmRarities = {}
BX.farmSkipped = 0

function BX.farmAny(set)
    for _ in pairs(set or {}) do return true end
    return false
end

function BX.farmWanted(rec)
    -- THE FILTER BELONGS TO THE FARM TAB'S RUN, NOT TO THE SCRIPT.
    --
    -- It used to be global, and that is the bug: pick Abyss Ocean on Farm,
    -- turn Farm's Auto Steal off, start Main's instead, and Main quietly kept
    -- stealing from Abyss Ocean. Nothing on Main said a filter existed, so
    -- there was no way to work out why it was ignoring the rest of the map.
    --
    -- Now the filter is only live for a run that Farm started. Main is Main.
    if not BX.farmActive then return true end

    if BX.farmAny(BX.farmAreas) and not BX.farmAreas[tostring(rec.AreaId)] then
        return false
    end
    if BX.farmAny(BX.farmRarities) and not BX.farmRarities[getEggRarity(rec)] then
        return false
    end
    return true
end

-- EGG DATA - 100% LOCAL, ZERO REMOTE CALLS.
--
--   ReplicatedStorage.Client.EggState decompiled in full. ReadFieldEggs() is
--   Measured: 54 records returned, 53 in "Slot" state, zero network traffic.
-- there was never a reason to keep a remote path around to be accidentally
-- WHAT IS IN A FIELD EGG RECORD (measured, not guessed):
-- Was 20s. ReadFieldEggs() is a local table read measured at 0.0001s, so
-- there was never a performance reason for a long cache - and it made dropped
K.EGG_CACHE_TTL = 3

-- Roblox's capability sandbox narrows a thread when it calls into game script
-- code, and the narrowing persists after the call returns. Once narrowed, the
-- confine the narrowing. MEASURED IN THE LIVE CLIENT: it does not. resume()
-- with it and the very next dropdown:Refresh() throws. That is exactly why the
-- What DOES work, measured the same way: task.spawn. The scheduler runs the
-- closure as a genuinely separate thread, we never resume it ourselves, and we
-- Cost: this YIELDS, so it must not be called from anywhere that needs a
function BX.offthread(fn, timeout)
    local done, result = false, nil
    task.spawn(function()
        local ok, r = pcall(fn)
        if ok then result = r end
        done = true
    end)
    -- COUNT REAL SECONDS, NOT TICKS.
    --
    -- This added 0.03 per iteration and compared that to the timeout, as if
    -- task.wait(0.03) always took 0.03. It does not - it takes at least one
    -- frame. On a phone at 15fps a frame is 0.067s, so a "5 second" timeout
    -- actually ran 166 iterations at 0.067s each: eleven seconds of the main
    -- thread doing nothing but waiting, and the whole hub feels hung for the
    -- duration.
    --
    -- The slower the client, the longer it hangs - which is the wrong way
    -- round, and it is why this bites phones hardest. os.clock is the honest
    -- measure.
    local startedAt = os.clock()
    timeout = timeout or 5
    while not done and (os.clock() - startedAt) < timeout do
        task.wait(0.03)
    end
    if not done then
        trace(("offthread: TIMED OUT after %.1fs"):format(os.clock() - startedAt))
    end
    return result
end

function BX.snapshot(force)
    local now = os.clock()
    if not force and BX.rawSnap and (now - (BX.rawSnapAt or 0)) < K.EGG_CACHE_TTL then
        return BX.rawSnap
    end

    -- ReadFieldEggs() returns { Records = { <record>, ... }, ServerTime = n }.
    -- An older parser iterated the TOP level looking for .Uid, but the top
    -- level only holds "Records" and "ServerTime", so it always found nothing.
    local records = {}
    -- Plain call. evaluateEggs() is invoked through BX.offthread by the UI, so
    -- this already runs on a throwaway thread; wrapping it again would only
    -- add another yield.
    local data
    pcall(function()
        data = EggState and EggState.ReadFieldEggs and EggState.ReadFieldEggs()
    end)
    if type(data) == "table" and type(data.Records) == "table" then
        for _, rec in ipairs(data.Records) do
            if type(rec) == "table" and rec.Uid then
                records[#records + 1] = rec
            end
        end
    end

    if #records > 0 then
        BX.rawSnap = { Records = records }
        BX.rawSnapAt = now
        return BX.rawSnap
    end

    -- EggState's own background sync may not have landed yet on a fresh join.
    -- Fall back to replicated scene data rather than asking the server.
    local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
    if slots then
        for _, d in ipairs(slots:GetDescendants()) do
            local uid = d:GetAttribute("Uid") or d:GetAttribute("EggUid")
            if uid then
                local pos
                if d:IsA("BasePart") then pos = d.CFrame
                elseif d:IsA("Model") then pos = d:GetPivot() end
                if pos then
                    records[#records + 1] = {
                        Uid = uid,
                        BoundsCFrame = pos,
                        State = "Slot",
                        AreaId = d:GetAttribute("AreaId"),
                        NestId = d:GetAttribute("NestId"),
                        AssetCategory = d:GetAttribute("AssetCategory"),
                    }
                end
            end
        end
        if #records > 0 then
            trace(("eggs: %d records (AreaEggSlotsClient fallback)"):format(#records))
            BX.rawSnap = { Records = records }
            BX.rawSnapAt = now
            return BX.rawSnap
        end
    end

    trace("eggs: no local data yet - EggState sync has not landed")
    return BX.rawSnap
end

-- Will the guard let us leave with this egg?
--
-- WalkSpeed answers, before we ever walk out there, whether the trip is
--     ExitDistance / WalkSpeed <= GetWakingDuration()   -- 0.63s, gone before it wakes
-- otherwise it is a straight footrace against BaseGuardWalkSpeed.
-- Measured on this account (Speed 451M -> WalkSpeed 204, and the server drops
-- eggs, which is exactly why an income-only pick lost every single trip. As
-- OFF, DELIBERATELY, AND THE REASONING MATTERS.
--
-- Chase speed alone does NOT decide the outcome. Cherry Blossom's guard tops
-- out at 888 against our 430, yet a 3512-stud carry from there banked cleanly
-- in this script's own log. The guard still has to wake (0.63s), path to us,
-- and beat us to the safe zone - so a faster guard makes an area UNRELIABLE,
-- not impossible.
--
-- Switching this on blocks any area whose chase beats the carry, which is six
-- of eleven - it would cut the field from 54 targetable eggs to 24 and throw
-- away areas that provably work. That is a worse trade than the occasional
-- lost egg.
--
-- BX.canOutrunGuard is now correct (carry vs base*4) and is still used to
-- decide when a decoy is worth sending, which is the real counter to a fast
-- guard: it sends the guard after a different egg entirely.
BX.skipUnwinnable = false
local escapeVerdictCache, escapeVerdictAt = {}, 0

local function areaEscapeVerdict(areaId, eggPos)
    if not (areaId and eggPos) then return "Unknown" end
    local now = os.clock()
    if (now - escapeVerdictAt) > 20 then
        escapeVerdictCache, escapeVerdictAt = {}, now
    end
    local hum = getHumanoid()
    -- A base-16 read is a bad read, not a slow character. Unknown = take the egg.
    if not (hum and hum.WalkSpeed and hum.WalkSpeed > K.WALKSPEED_SANE_MIN) then return "Unknown" end
    local ws = hum.WalkSpeed
    -- Judge on the CARRYING speed, not the empty-handed one. The penalty is
    -- MEASURED, not guessed: the Prehistoric run logged
    --   SERVER RigSync -> SetWalkSpeed 182.92189340033827   (from 204.14167)
    ws = ws * 0.8961
    local key = ("%s|%d|%d"):format(areaId, math.floor(eggPos.X), math.floor(ws))
    local hit = escapeVerdictCache[key]
    if hit then return hit end

    local verdict = "Unknown"
    pcall(function()
        local GEP = require(RS.Shared.Modules.GuardAreas.GuardEscapePrediction)
        local GCP = require(RS.Shared.Modules.GuardAreas.GuardChasePolicy)
        local Guards = require(RS.Data.Guards)
        local AreasData = require(RS.Data.Areas)
        local area = Workspace.__OBJECTS.Areas.GuardAreas[areaId]
        local bounds, guard = area.Bounds, area.Guard
        local g = Guards.Directory[AreasData.Directory[areaId].GuardId]
        -- Home is west of every area, so that is the edge we leave by.
        local dir = Vector3.new(-1, 0, 0)
        local pp = Vector3.new(eggPos.X, bounds.Position.Y, eggPos.Z)
        local ed = GEP.ResolveExitDistance(bounds.CFrame, bounds.Size, pp, dir)
        verdict = GEP.Resolve({
            BaseGuardWalkSpeed = g.WalkSpeed,
            ExitDirection      = dir,
            ExitDistance       = ed,
            FlatRadius         = g.FlatRadius,
            GuardStartPosition = guard:GetPivot().Position,
            HitDistance        = GCP.ResolveHitDistance(g.HitDistance),
            PlayerStartPosition = pp,
            PlayerWalkSpeed    = ws,
        }).Outcome
    end)
    escapeVerdictCache[key] = verdict
    return verdict
end

-- ONLY "EscapedSafely" keeps the egg. "EscapedAtRisk" is a loss, not a pass -
-- that mistake is what cost the Prehistoric Triceratops: the solver called it
-- EscapedAtRisk, this filter waved it through because it was not "Caught", and
local function canEscapeArea(areaId, eggPos)
    if not BX.skipUnwinnable then return true end
    -- Hard gate first: if the guard is simply faster than we are, no amount of
    -- routing or carry speed wins. Measured - Cherry Blossom (222) and Titan
    if not BX.decoyEnabled and not BX.ignoreGuardSpeed and not BX.canOutrunGuard(areaId) then
        return false
    end
    -- Two independent ways to keep an egg, and either is enough.
    --
    --    that matters, because it is decided before the chase starts and so
    local hum = getHumanoid()
    if hum and hum.WalkSpeed and hum.WalkSpeed > K.WALKSPEED_SANE_MIN then
        if BX.guardExitIsSafe and BX.guardExitIsSafe(areaId, eggPos, hum.WalkSpeed * 0.8961) then
            return true
        end
    end
    local v = areaEscapeVerdict(areaId, eggPos)
    return v == "EscapedSafely" or v == "Unknown"
end

local function evaluateEggs(force)
    local now = os.clock()
    if not force and BX.eggCache and (now - BX.eggCacheAt) < K.EGG_CACHE_TTL then
        return BX.eggCache
    end

    -- THE FIELD ARRIVES IN TWO HALVES, AND ACTING ON THE FIRST ONE IS WRONG.
    --
    -- Your five Forest nests hold FirstAreaEgg_<yourUserId>_... records. They
    -- are generated for you and resolve the instant your profile loads. The
    -- other fifty are shared field state that has to replicate from the
    -- server, and ReadFieldEggs happily returns whatever has arrived so far.
    --
    -- Caught in your own log:
    --
    --     [851.36s] eggs: 5 stealable, best Bear 262/s
    --               ... 25 loop passes, still 5 ...
    --     [863.56s] eggs: 55 stealable, best Snowy Owl 104544933/s
    --
    -- Twelve seconds where the only readable eggs were your own five Forest
    -- ones. A Titan steal in that window cannot work - Titan is not in the
    -- list yet - and Auto Steal started there picks a 240/s Bear as "best"
    -- instead of a 104M/s Snowy Owl, off a map that is 9% loaded.
    --
    -- So: once we have seen the full field, a snapshot that collapses back to
    -- a handful is replication catching up, not the map emptying. Keep the
    -- last good list and look again shortly.
    local data = BX.snapshot(force)
    do
        local n = (data and data.Records) and #data.Records or 0
        if n > 10 then BX.sawFullField = true end
        if BX.sawFullField and n > 0 and n <= 8 and BX.eggCache and #BX.eggCache > 0 then
            if not BX.saidPartial then
                BX.saidPartial = true
                trace(("eggs: only %d records replicated - the field is still loading,"
                    .. " keeping the last %d"):format(n, #BX.eggCache))
            end
            return BX.eggCache
        end
        BX.saidPartial = false
    end
    if not (data and data.Records) then
        BX.eggCache = BX.eggCache or {}
        BX.eggCacheAt = now
        return BX.eggCache
    end

    -- Prune stolenUids by walking IT, not the record list. The old code only
    -- expired an entry if that uid still appeared in the current snapshot, so
    -- an egg we stole that then despawned was never visited again and its
    local nowTick = tick()
    for uid, at in pairs(stolenUids) do
        if (nowTick - at) > 120 then stolenUids[uid] = nil end
    end

    -- Rebuilt from the uids actually seen this pass, so it is self-bounding.
    BX.valueCacheNext = {}

    local eggs = {}
    local skippedByGuard = {}
    local skippedByFarm = 0
    local skippedMine = 0
    for _, rec in ipairs(data.Records) do
        -- AreaEggs.States: Slot | Dropped | Carried | Claimed | GuardCarried
        --
        -- Slot/Dropped are ours to take. GuardCarried means a guard picked the
        local grabbable = (rec.State == "Slot" or rec.State == "Dropped")
        local visible = grabbable or rec.State == "GuardCarried"

        -- An egg we "stole" that is back on the field is available again, so
        -- stop hiding it. This used to test ONLY for Dropped, which is the bug
        --     States      = Slot | Carried | Dropped | GuardCarried | Claimed
        -- becomes Slot again. Neither of those is "Dropped", so stolenUids was
        -- never cleared and the egg stayed hidden for the full 120s while
        -- Slot, Dropped and GuardCarried all mean "on the field, not ours".
        if stolenUids[rec.Uid]
            and (rec.State == "Slot" or rec.State == "Dropped"
                 or rec.State == "GuardCarried") then
            stolenUids[rec.Uid] = nil
        end

        local escapable = true
        if type(rec) == "table" and typeof(rec.BoundsCFrame) == "CFrame" then
            escapable = canEscapeArea(rec.AreaId, rec.BoundsCFrame.Position)
            if not escapable then
                skippedByGuard[rec.AreaId or "?"] = (skippedByGuard[rec.AreaId or "?"] or 0) + 1
            end
        end

        -- YOUR OWN FOREST EGGS ARE NOT STEALABLE, AND THEY WERE ON THE LIST.
        --
        -- Read straight off this account, every Forest nest:
        --
        --     Forest | Chicken | Common | Slot | FIRST | MINE
        --     Forest | Dog     | Common | Slot | FIRST | MINE   (x3)
        --     Forest | Raccoon | Rare   | Slot | FIRST | MINE
        --
        -- All five hold FirstAreaEgg_<yourUserId>_... records - your own eggs,
        -- in your own nests. The server will never hand one of those to you, so
        -- the prompt fires, the state stays Slot, the loop gives up, retreats,
        -- and comes straight back for the same egg. Out, refused, home, out
        -- again. That is the back-and-forth.
        --
        -- Nothing filtered them out, and they only get REACHED when the
        -- candidate list is small - which is exactly what a rarity filter does.
        -- Chicken and Dog are Common and Raccoon is Rare, so Common, Uncommon
        -- or Epic on the Farm tab can leave a list that is mostly, or entirely,
        -- eggs that belong to you. A Secret filter never comes near them, which
        -- is why that one worked.
        --
        -- The game's own helper decides this rather than a string match of
        -- mine: FirstAreaOwnerUserId returns the owner id for a first-area uid
        -- and nil for every ordinary field egg (verified both ways on a live
        -- client). Other players' Forest eggs are untouched - they are still
        -- yours to take, and they are most of what a new account steals.
        local mine = false
        pcall(function()
            mine = AreaEggSlotIdentity.FirstAreaOwnerUserId(rec.Uid) == LocalPlayer.UserId
        end)
        if mine then skippedMine = skippedMine + 1 end

        local wanted = BX.farmWanted(rec)
        if visible and escapable and not mine and not wanted then
            skippedByFarm = skippedByFarm + 1
        end

        if type(rec) == "table" and rec.Uid and rec.BoundsCFrame
            and typeof(rec.BoundsCFrame) == "CFrame"
            and visible and escapable and wanted and not mine
            and not stolenUids[rec.Uid] then
            table.insert(eggs, {
                uid = rec.Uid,
                state = rec.State,
                dropped = (rec.State == "Dropped"),
                grabbable = grabbable,
                guardHeld = (rec.State == "GuardCarried"),
                pet = rec.AssetCategory,
                name = getEggDisplayName(rec),
                area = rec.AreaId,
                rarity = getEggRarity(rec),
                value = calcEggValue(rec),
                kg = getEggKg(rec),
                scale = tonumber(rec.AssetScale) or 1,
                parasite = rec.HasParasite == true,
                mutations = rec.Mutations,
                nestId = rec.NestId,
                -- STAND AT THE NEST, NOT AT THE MIDDLE OF THE EGG.
                --
                -- This was BoundsCFrame.Position - the centre of the egg's
                -- bounding box - and every distance gate in the grab path
                -- measures in 3D against it. Fine for a small egg. On a big
                -- one the centre is metres in the air, and we are standing on
                -- the ground underneath it:
                --
                --     Rhino     bounds 12.3 x 15.5 x 11.9, scale 4.09
                --               centre sits 7.7 studs above the nest
                --
                -- The prompt reaches 8 studs and the remote path wants 9. On
                -- that egg the height alone eats nearly all of it before any
                -- horizontal error, which is why the log reads
                --
                --     carry: remote skipped, 9.3 studs from the egg record
                --
                -- and why it is always the big ones. The models are
                -- non-collidable - checked, 0 collidable parts - so there was
                -- never a reason to aim high; BottomCFrame is the egg's base
                -- on the nest, which is exactly where we want to be standing.
                position = (rec.BottomCFrame and rec.BottomCFrame.Position)
                    or rec.BoundsCFrame.Position,
                boundsPos = rec.BoundsCFrame.Position,
                record = rec,
            })
        end
    end

    -- SORT BY WHAT WE CAN ACTUALLY BANK, NOT BY WHAT IS WORTH MOST.
    --
    -- Measured across every run this session: a 426-stud carry delivered in
    -- 1.32s; 2269, 2290 and 2324-stud carries were refused at 205, 500 and 900
    -- studs/s alike. The highest-value egg on the map is usually the one we
    -- Measured against the SAFE ZONE, which is where the egg is banked - see
    -- BX.safeZonePos. This read plotDeliverPos, so the budget it enforced was
    -- TARGET THE HEAVIEST INSTEAD OF THE RICHEST, if that is what you asked
    -- for. Sorting here rather than in the UI means the dropdown, the
    -- auto-pick and the steal loop all agree without any of them being
    -- special-cased.
    -- FALL THROUGH, DO NOT RETURN. The first version of this returned the
    -- sorted list straight out of here, which skipped the two lines below the
    -- other branches:
    --
    --     BX.valueCache = BX.valueCacheNext
    --     BX.valueCacheNext = {}
    --
    -- valueCacheNext is rebuilt from scratch at the top of every pass, so
    -- never swapping it in left valueCache frozen at whatever it held when the
    -- mode was switched - stale prices on every egg, for as long as Weight was
    -- selected. It also skipped the one-line scan trace, so the log went quiet
    -- exactly when someone would be trying to work out why.
    local sorted = false
    if BX.targetBy == "Weight" then
        table.sort(eggs, function(a, b)
            if (a.kg or 0) ~= (b.kg or 0) then return (a.kg or 0) > (b.kg or 0) end
            return (a.value or 0) > (b.value or 0)
        end)
        sorted = true
    end

    local homeP = nil
    pcall(function() homeP = BX.safeZonePos() end)
    if sorted then
        -- already ordered by weight
    elseif BX.preferCloseEggs and typeof(homeP) == "Vector3" then
        for _, e in ipairs(eggs) do
            local d = e.position and Vector3.new(
                e.position.X - homeP.X, 0, e.position.Z - homeP.Z).Magnitude or math.huge
            e.carryDist = d
            e.inBudget = (d <= K.CARRY_MAX_DIST)
        end
        table.sort(eggs, function(a, b)
            if a.inBudget ~= b.inBudget then return a.inBudget end
            return a.value > b.value
        end)
    else
        table.sort(eggs, function(a, b) return a.value > b.value end)
    end

    -- Swap in the fresh cache. Anything not seen this pass is dropped.
    BX.valueCache = BX.valueCacheNext
    BX.valueCacheNext = {}
    -- ONE line per scan, and only when it says something new. This ran on
    -- every refresh AND every loop pass, four lines a time, unchanged for
    -- minutes at a stretch.
    do
        local parts = {}
        for area, n in pairs(skippedByGuard) do
            parts[#parts + 1] = ("%s x%d"):format(area, n)
        end
        table.sort(parts)
        local line = ("eggs: %d stealable, best %s %s/s"):format(
            #eggs,
            eggs[1] and eggs[1].name or "-",
            eggs[1] and tostring(eggs[1].value) or "0")
        if #parts > 0 then
            line = line .. " | sealed: " .. table.concat(parts, ", ")
        end
        if skippedMine > 0 then
            line = line .. (" | %d of yours"):format(skippedMine)
        end
        if line ~= BX.lastEggScanLine then
            BX.lastEggScanLine = line
            trace(line)
        end
    end
    BX.eggCache = eggs
    BX.eggCacheAt = os.clock()
    return eggs
end

---------- ANTICHEAT BYPASS (DISABLED FOR SAFETY) ----------
-- All hooking functions disabled to avoid executor detection
-- These functions use detectable executor APIs: hookfunction, newcclosure, debug.getinfo, debug.getconstants, getgc

local function hook_constants(sourcePath, targetConstants, hookFn)
    -- DISABLED: Uses detectable executor functions (getgc, debug.getinfo, debug.getconstants, hookfunction, newcclosure)
    -- These are easily detected by anticheat as they don't exist in normal Roblox clients
    return
end

local function destroyAntiCollision()
    -- DISABLED: Deleting game scripts is trivially checkable by anticheat
    -- Continuous script destruction is a major detection vector
    return
end

local function disconnectAllACConnections()
    -- DISABLED: Uses detectable getconnections and debug.getinfo
    -- Disconnecting game event handlers is easily detected by server-side anticheat
    return
end

local function blockRigSync()
    -- DISABLED: Disconnecting game remotes and hooking remote functions is easily detected
    -- Server-side anticheat can detect when clients stop responding to expected remote events
    return
end

local function hookContentCatalog()
    -- DISABLED: All hooking functions disabled to avoid detection
    return
end

local function hookForestStrike()
    -- DISABLED: All hooking functions disabled to avoid detection
    return
end

local function hookAskRigWipe()
    -- DISABLED: All hooking functions disabled to avoid detection
    return
end

local function destroyObbyAntiTP()
    -- DISABLED: Deleting game scripts is detectable
    return
end

local function disconnectDangerousSignals()
    -- DISABLED: Uses detectable getconnections and debug.getinfo
    -- Disconnecting game event handlers is easily detected
    return
end

local function blockGuardRemotes()
    -- DISABLED: Disconnecting game remotes is easily detected by server-side anticheat
    return
end

local function hookFieldEggCarry()
    -- DISABLED: Uses detectable getconnections
    -- Disconnecting and hooking game remotes is easily detected
    return
end

local function hookOwnerDropped()
    -- DISABLED: Uses detectable getconnections
    -- Disconnecting and hooking game remotes is easily detected
    return
end

local legacyAcBypass = false

local function bypassAnticheat()
    if not legacyAcBypass then return end
    destroyAntiCollision()
    disconnectAllACConnections()
    blockRigSync()
    hookContentCatalog()
    hookForestStrike()
    hookAskRigWipe()
    destroyObbyAntiTP()
    disconnectDangerousSignals()
    blockGuardRemotes()
    hookFieldEggCarry()
    hookOwnerDropped()
end

---------- ANTI-DEATH (LennonHub Proto 61) ----------

local antiDeathEnabled = false

local function setupAntiDeath()
    if not antiDeathEnabled then return end
    for _, c in pairs(antiDeathConns) do
        pcall(function() c:Disconnect() end)
    end
    antiDeathConns = {}

    local char = getChar()
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    if not originalHumanoidState or originalHumanoidState.humanoid ~= hum then
        local animate = char:FindFirstChild("Animate")
        originalHumanoidState = {
            humanoid = hum,
            breakJointsOnDeath = hum.BreakJointsOnDeath,
            deadEnabled = hum:GetStateEnabled(Enum.HumanoidStateType.Dead),
            animate = animate,
            animateDisabled = animate and animate.Disabled or nil,
        }
    end

    hum.BreakJointsOnDeath = false
    hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)

    table.insert(antiDeathConns, hum.HealthChanged:Connect(function(hp)
        if hp <= 0 then hum.Health = hum.MaxHealth end
    end))

    table.insert(antiDeathConns, hum.StateChanged:Connect(function(_, new)
        if new == Enum.HumanoidStateType.Dead then
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            hum.Health = hum.MaxHealth
        end
    end))

    pcall(function()
        local animator = hum:FindFirstChildOfClass("Animator")
        if animator then
            local clone = animator:Clone()
            animator:Destroy()
            clone.Parent = hum
        end
    end)

    pcall(function()
        workspace.CurrentCamera.CameraSubject = hum
    end)

    pcall(function()
        local animate = char:FindFirstChild("Animate")
        if animate then animate.Disabled = true end
    end)
end

local function restoreAntiDeath()
    for _, c in ipairs(antiDeathConns) do
        pcall(function() c:Disconnect() end)
    end
    antiDeathConns = {}

    local state = originalHumanoidState
    local hum = state and state.humanoid
    if hum and hum.Parent then
        pcall(function() hum.BreakJointsOnDeath = state.breakJointsOnDeath end)
        pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, state.deadEnabled) end)
    end
    if state and state.animate and state.animate.Parent and state.animateDisabled ~= nil then
        pcall(function() state.animate.Disabled = state.animateDisabled end)
    end
    originalHumanoidState = nil
end

---------- ANTI-RAGDOLL (LennonHub Proto 16) ----------

local function antiRagdoll()
    local char = getChar()
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
    hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)

    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("Motor6D") then d.Enabled = true end
    end
end

local function recoverFromRagdoll()
    local hum = getHumanoid()
    if not hum then return end
    hum:ChangeState(Enum.HumanoidStateType.GettingUp)
    local char = getChar()
    if char then
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("Motor6D") then d.Enabled = true end
        end
    end
end

-- THE GAME RAGDOLLS WITH THE *PHYSICS* STATE, NOT Ragdoll.
--
-- This tested for Ragdoll and FallingDown, which this game NEVER enters, so it
-- on it was dead: waitForRagdollEnd returned instantly, unstick never noticed
-- it was pinned, and Anti Hit never saw a hit to react to.
-- PlatformStand is included because Ragdoll.NpcRagdoll sets that too, and a
local function isRagdolled()
    local hum = getHumanoid()
    if not hum then return false end
    if hum.PlatformStand then return true end
    local s = hum:GetState()
    return s == Enum.HumanoidStateType.Physics
        or s == Enum.HumanoidStateType.Ragdoll
        or s == Enum.HumanoidStateType.FallingDown
end

---------- PLAYER TRAPS ----------
--
-- MEASURED in a live server, not inferred:
--   Data.Gears.Directory.Trap
-- catches me". A trap is not a stall and must not be treated as one.

local function isTrapped()
    local char = getChar()
    if not char then return false end
    return char:GetAttribute("IsTrapped") == true
end
BX.isTrapped = isTrapped

-- Live trap positions, OTHER PEOPLE'S only. Your own traps do not fire on you,
-- so routing around them would be avoiding nothing.
function BX.trapPositions()
    local out = {}
    local ok = pcall(function()
        local me = LocalPlayer.Name
        for _, t in ipairs(game:GetService("CollectionService"):GetTagged("PlacedTrap")) do
            if t:IsA("BasePart") and t:GetAttribute("Owner") ~= me then
                out[#out + 1] = t.Position
            end
        end
    end)
    if not ok then return {} end
    return out
end

-- Seven seconds is the documented freeze. Wait it out rather than fighting it:
-- there is no unstick for this, the server is holding us on purpose.
function BX.waitForTrapEnd(timeout)
    if not isTrapped() then return true end
    BX.trapHits = (BX.trapHits or 0) + 1
    local started = os.clock()
    trace("trap: CAUGHT - freezing until it releases")
    local deadline = os.clock() + (timeout or 9)
    while os.clock() < deadline do
        task.wait(0.1)
        if not isTrapped() then
            trace(("trap: released after %.1fs"):format(os.clock() - started))
            return true
        end
    end
    trace("trap: still held after timeout")
    return false
end

-- Push any waypoint that lands on top of a trap out to the side. Only the
-- waypoints move - the destination is never shifted, because arriving is the
-- point. Returns how many were nudged, for the trace.
function BX.dodgeTraps(segs)
    if not BX.avoidTraps or #segs < 2 then return 0 end
    local traps = BX.trapPositions()
    if #traps == 0 then return 0 end

    local radius = BX.trapRadius or 14
    local moved = 0

    -- ITERATIVE, and pushing away from the CLOSEST trap only.
    --
    -- trap B, and nothing re-checks. Measured against the three real traps at
    for i = 1, #segs - 1 do   -- #segs is the destination; arriving is the point
        local nudged = false
        for _ = 1, 4 do
            local closest, closestDist
            for _, tp in ipairs(traps) do
                local d = Vector3.new(segs[i].X - tp.X, 0, segs[i].Z - tp.Z).Magnitude
                if d < radius and (not closestDist or d < closestDist) then
                    closest, closestDist = tp, d
                end
            end
            if not closest then break end
            local flat = Vector3.new(segs[i].X - closest.X, 0, segs[i].Z - closest.Z)
            -- Sitting exactly on the trap gives no direction to push along.
            local dir = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(1, 0, 0)
            local off = closest + dir * (radius + 4)
            segs[i] = Vector3.new(
                math.clamp(off.X, K.CORRIDOR_X_MIN, K.CORRIDOR_X_MAX),
                segs[i].Y,
                math.clamp(off.Z, K.CORRIDOR_Z_MIN, K.CORRIDOR_Z_MAX)
            )
            nudged = true
        end
        if nudged then moved = moved + 1 end
    end
    return moved
end


local function setupGuardClone(guardModel)
    -- DISABLED: Guard manipulation is extremely detectable
    return nil, nil
end

local function hideOriginalGuard(guardModel)
    -- DISABLED: Teleporting server-owned NPCs is the loudest possible tampering
    return
end

local function restoreOriginalGuard()
    -- DISABLED: Guard manipulation is extremely detectable
    return
end

local function switchGuard(areaName)
    -- DISABLED: Guard manipulation is extremely detectable
    return
end

local function restoreAllGuards()
    -- DISABLED: Guard manipulation is extremely detectable
    return
end

local function startGuardEnforce()
    -- DISABLED: Guard manipulation is extremely detectable
    return
end

local function stopGuardEnforce()
    -- DISABLED: Guard manipulation is extremely detectable
    return
end

---------- MOVEMENT (LennonHub Proto 34/43/44) ----------

-- CloverHub (a working Steal An Egg script) ships this message to its users:
--   "Tween Speed reset to 400 - your saved 800 was from the removed Fly build."
-- They REMOVED flying because it got detected, and settled on a 400 stud/sec
-- default. Hop/teleport at thousands of studs/sec is exactly the "fly" class

-- MEASURED: a plain downward raycast hits non-collidable markers first -
-- Areas.Ground, GuardAreas.*.Bounds, Center, and worst of all "mainsky".
local function solidGroundY(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    local char = getChar()
    if char then table.insert(ignore, char) end
    if activeGuardClone then table.insert(ignore, activeGuardClone) end
    -- EVERY player character, not just ours. Other people's torsos and hats
    -- are CanCollide, so they pass the check below and get returned as solid
    -- and what stranded the carry 49 studs short of the plot for 10 seconds.
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character then table.insert(ignore, pl.Character) end
    end
    params.FilterDescendantsInstances = ignore
    params.IgnoreWater = true

    local origin = pos + Vector3.new(0, 80, 0)
    for _ = 1, 15 do
        local r = workspace:Raycast(origin, Vector3.new(0, -700, 0), params)
        if not r then return nil end
        if r.Instance.CanCollide then return r.Position.Y + GROUND_OFFSET end
        table.insert(ignore, r.Instance)
        params.FilterDescendantsInstances = ignore
    end
    return nil
end

local function getGroundY(pos)
    return solidGroundY(pos) or pos.Y
end

-- Is there solid geometry between where we are and where we are going?
local function handleAntiCollisionPushback()
    local hrp = getHRP()
    if not hrp then return end

    -- The AntiCollision script pushes characters back when they move too fast
    -- We detect this by monitoring velocity changes and adjust accordingly
    local currentVel = hrp.AssemblyLinearVelocity
    if currentVel.Magnitude > 50 then
        -- Likely being pushed back by AntiCollision
        -- Slow down our movement to reduce the effect
        return true
    end
    return false
end

-- Reports whether there is genuinely collidable floor under pos.
local function groundAt(pos)
    local y = solidGroundY(pos)
    if y then return y, true end
    return pos.Y, false
end

local function isBlocked(fromPos, toPos)
    local delta = toPos - fromPos
    if delta.Magnitude < 0.05 then return false end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local filterList = {}
    local char = getChar()
    if char then table.insert(filterList, char) end
    if activeGuardClone then table.insert(filterList, activeGuardClone) end
    params.FilterDescendantsInstances = filterList
    params.IgnoreWater = true
    return workspace:Raycast(fromPos, delta, params) ~= nil
end

local noclipOriginal = {}

local function enableNoclip()
    if noclipConn then return end
    -- CACHE THE PARTS. This walked GetDescendants() on the character every
    -- single physics step - accessories, hats, tool handles, the lot - and
    -- rewrote CanCollide on each. The part list only changes when the
    -- character does, so build it once and refresh it lazily.
    local cached, cachedFor = nil, nil
    noclipConn = RunService.Stepped:Connect(function()
        local char = getChar()
        if not char then return end
        if cachedFor ~= char or not cached then
            cached, cachedFor = {}, char
            for _, p in ipairs(char:GetDescendants()) do
                if p:IsA("BasePart") then
                    cached[#cached + 1] = p
                    if noclipOriginal[p] == nil then noclipOriginal[p] = p.CanCollide end
                end
            end
        end
        for i = 1, #cached do
            local p = cached[i]
            if p.Parent and p.CanCollide then p.CanCollide = false end
        end
    end)
    BlyxoTop.noclip = noclipConn   -- a local, so the re-execute sweep needs it here
end

-- Disconnecting alone left every part CanCollide = false, so the character
-- stayed non-collidable after each move: it floats, and it is an obvious
-- persistent tell. Put the original values back.
local function disableNoclip()
    if noclipConn then noclipConn:Disconnect() noclipConn = nil end
    for part, was in pairs(noclipOriginal) do
        if part and part.Parent then
            pcall(function() part.CanCollide = was end)
        end
    end
    noclipOriginal = {}
end

-- Bring the character back to a normal standing state after a fast move.
local function settleCharacter()
    disableNoclip()
    local hrp = getHRP()
    if hrp then
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health > 0 then
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Landed) end)
    end
end

-- Discrete sub-threshold hops along a corridor-safe route.
local function insideCorridor(pos)
    return pos.X >= K.CORRIDOR_X_MIN and pos.X <= K.CORRIDOR_X_MAX
       and pos.Z >= K.CORRIDOR_Z_MIN and pos.Z <= K.CORRIDOR_Z_MAX
end

-- Straight lines leave the strip sideways. Go to the corridor, run along it,
-- then step out to the target.
local function buildRoute(fromPos, toPos)
    local route = {}
    if insideCorridor(fromPos) and insideCorridor(toPos)
       and math.abs(fromPos.X - toPos.X) < 150 then
        route[#route + 1] = toPos
        return route
    end
    local ax = math.clamp(fromPos.X, K.CORRIDOR_X_MIN, K.CORRIDOR_X_MAX)
    local bx = math.clamp(toPos.X, K.CORRIDOR_X_MIN, K.CORRIDOR_X_MAX)
    route[#route + 1] = Vector3.new(ax, fromPos.Y, K.CORRIDOR_Z)
    route[#route + 1] = Vector3.new(bx, fromPos.Y, K.CORRIDOR_Z)
    route[#route + 1] = toPos
    return route
end

local function hopMoveTo(targetPos, onComplete)
    moveGeneration = moveGeneration + 1
    local generation = moveGeneration
    isMoving = true

    task.spawn(function()
        local hrp0 = getHRP()
        if not hrp0 then isMoving = false; if onComplete then onComplete() end return end

        local route = buildRoute(hrp0.Position, targetPos)
        local guard = 0

        for _, leg in ipairs(route) do
            local gy = solidGroundY(leg)
            local target = Vector3.new(leg.X, gy or leg.Y, leg.Z)

            while generation == moveGeneration and isMoving do
                local hrp = getHRP()
                if not hrp then break end
                local diff = target - hrp.Position
                local dist = diff.Magnitude
                if dist < 8 then break end

                guard = guard + 1
                if guard > 600 then break end

                local step = math.min(K.HOP_DISTANCE, dist)
                local next, landed = nil, false
                while step >= 6 do
                    local probe = hrp.Position + diff.Unit * step
                    local y = solidGroundY(probe)
                    if y then
                        next = Vector3.new(probe.X, y, probe.Z)
                        landed = true
                        break
                    end
                    step = step * 0.5
                end
                if not landed then break end -- no floor ahead; end this leg

                if noclipGated then
                    if isBlocked(hrp.Position, next) then enableNoclip() else disableNoclip() end
                end

                -- A PURELY VERTICAL LEG BUILDS A NaN CFRAME, AND THAT CRASHES
                -- THE CLIENT.
                --
                -- diff is guaranteed to be 8+ studs by the check above, so
                -- diff.Unit is safe. The look vector is not: it throws away Y,
                -- so a leg that is straight up or straight down leaves
                -- Vector3.new(0, 0, 0) and the call becomes
                --
                --     CFrame.new(next, next)      -- position == lookAt
                --
                -- which produces a CFrame full of NaN. Assigning that to a
                -- HumanoidRootPart is one of the few things that will take the
                -- whole client down rather than just erroring.
                --
                -- The final descent onto the plot IS a straight-down leg. That
                -- is why it crashed on delivery and nowhere else.
                --
                -- When there is no horizontal component there is no facing to
                -- compute, so keep the rotation we already have.
                local flat = Vector3.new(diff.X, 0, diff.Z)
                if flat.Magnitude <= 0.05 then
                    -- NOTHING HORIZONTAL LEFT, SO THIS LOOP IS DONE.
                    --
                    -- My first fix for the NaN wrote a valid straight-down
                    -- CFrame instead. That stopped the crash and immediately
                    -- caused snap-backs, because it made a leg run that never
                    -- used to: the anticheat validates vertical movement
                    -- against a jump-and-gravity trajectory
                    -- (LastVerticalSegmentDecision, Reachable, JumpPower,
                    -- Gravity) and a 40-stud drop in one hop is not reachable,
                    -- so it corrected us. Before the NaN guard that write
                    -- simply failed, which is why nobody ever saw this leg.
                    --
                    -- This is a HORIZONTAL hop loop. A purely vertical
                    -- remainder is not its job - arcDescend and gravity own
                    -- the drop - so it ends the leg instead of inventing a
                    -- teleport. No NaN, and no vertical move to be corrected.
                    break
                end
                hrp.CFrame = CFrame.new(next, next + flat.Unit)
                hrp.AssemblyLinearVelocity = Vector3.zero
                if K.HOP_GAP > 0 then task.wait(K.HOP_GAP) else RunService.Heartbeat:Wait() end
            end

            if generation ~= moveGeneration or not isMoving then break end
        end

        if generation == moveGeneration then
            isMoving = false
            settleCharacter()
            if onComplete then onComplete() end
        end
    end)
end

-- Raw single-leg tween. Do not call directly - go through cfMoveTo so the
-- corridor route is applied, otherwise a straight line leaves the map strip
-- raw speed was never the detection - my earlier conclusion there was wrong).
--      the server flagged 0.27s into our last run.
--   2. Humanoid.WalkSpeed is forced to 0 for the duration and restored after.
--      relocation rather than the character running impossibly fast.
-- must not zero velocity or PivotTo - doing that between every waypoint is a
local function tweenLeg(targetPos, speed, onComplete, isFinal)
    local hrp = getHRP()
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hrp or not char then
        if onComplete then onComplete() end
        return
    end

    moveGeneration = moveGeneration + 1
    local generation = moveGeneration
    isMoving = true

    -- cancel anything already in flight
    if BX.activeTweenConn then pcall(function() BX.activeTweenConn:Disconnect() end) BX.activeTweenConn = nil end
    if BX.activeTween then pcall(function() BX.activeTween:Cancel() end) BX.activeTween = nil end

    -- DO NOT zero WalkSpeed here. It used to, and that was actively harmful.
    --
    --     allowed = maxRecentWalkSpeed * 1.7 * dt + 14 + horizontalVelocity*dt
    -- The movement budget is PROPORTIONAL TO WALKSPEED. Setting WalkSpeed to 0
    -- while tweening at 400 studs/s collapsed the allowance to a constant 94
    -- The server also owns WalkSpeed - it pushes SetWalkSpeed through RigSync
    -- roughly once a second (WalkSpeedGovernor), so our write was being undone
    -- LOWERS your WalkSpeed - and the legality budget is WalkSpeed * 1.7. With
    if hum and hum.WalkSpeed > 0 then
        BX.serverWalkSpeed = hum.WalkSpeed
    end

    local groundY = getGroundY(targetPos)
    local target = Vector3.new(targetPos.X, groundY, targetPos.Z)
    local dist = (target - hrp.Position).Magnitude

    local function finish()
        if generation ~= moveGeneration then return end
        BX.restoreWalkSpeed()
        isMoving = false
        if onComplete then onComplete() end
    end

    if dist < 2 then
        finish()
        return
    end

    local spd = speed or TWEEN_SPEED
    local tween = TweenService:Create(
        hrp,
        TweenInfo.new(dist / spd, Enum.EasingStyle.Linear),
        { CFrame = CFrame.new(target) }
    )
    BX.activeTween = tween

    BX.activeTweenConn = tween.Completed:Connect(function(state)
        if BX.activeTween == tween then
            BX.activeTween = nil
            if BX.activeTweenConn then
                pcall(function() BX.activeTweenConn:Disconnect() end)
                BX.activeTweenConn = nil
            end
            if state == Enum.PlaybackState.Completed then
                local h = getHRP()
                -- Mid-route: hand straight over to the next segment without
                -- braking. Only the final segment comes to a stop.
                if h and not isFinal then
                    if onComplete then onComplete() end
                    return
                end
                if h then
                    h.AssemblyLinearVelocity = Vector3.zero
                    -- Angular velocity was never cleared. A spin surviving the
                    -- tween is what launches the character on the next physics
                    -- step - that is the "flung off the map" case.
                    h.AssemblyAngularVelocity = Vector3.zero
                end

                -- Only snap if we are essentially there already.
                --
                -- showed the cost: "seg 4 t=1s pos 920 remaining 397" then
                -- Dropped. That is what "it never carried it to the end" was.
                -- never got within the 7 studs carryEgg needs, and nothing was
                local gap = h and (target - h.Position).Magnitude or 0
                if not heldEggUid or gap <= K.SNAP_MAX then
                    pcall(function() char:PivotTo(CFrame.new(target)) end)
                else
                    trace(("tween: skipped %.0f-stud snap (carrying)"):format(gap))
                end
            end
            finish()
        end
    end)

    tween:Play()

    -- Watchdog. The old version only checked the TOTAL budget (dist/spd + 5),
    -- so a leg the server was silently reverting sat there for the tween's
    -- full duration before anyone noticed - measured at 14s of a 3467-stud leg
    task.spawn(function()
        local budget = (dist / spd) + 5
        local waited = 0
        local lastPos = hrp.Position
        local stuckFor = 0

        while waited < budget and BX.activeTween == tween do
            task.wait(0.25)
            waited = waited + 0.25

            local h = getHRP()
            if not h then break end
            local moved = (h.Position - lastPos).Magnitude
            lastPos = h.Position

            -- A live tween at `spd` should cover spd*0.25 studs per sample.
            -- Anything under 2 studs is not slow, it is stopped.
            if moved < 2 then
                stuckFor = stuckFor + 0.25
            else
                stuckFor = 0
            end

            if stuckFor >= K.NO_PROGRESS_LIMIT then
                trace(("tween: NO PROGRESS for %.1fs (%.0f studs still to go) - abandoning leg")
                    :format(stuckFor, (target - h.Position).Magnitude))
                break
            end
        end

        if BX.activeTween == tween then
            if waited >= budget then
                trace("tween: watchdog fired - tween never completed")
            end
            pcall(function() tween:Cancel() end)
            BX.activeTween = nil
            BX.stalled = true
            task.spawn(BX.diagnoseStall, "watchdog")
            finish()
        end
    end)
end

-- Public mover. Builds a corridor-safe route, then walks each leg with the
-- selected mode. NOW WITH SMART ANTICHEAT AVOIDANCE
-- The stall signature from the trace was: tween playing, WalkSpeed forced to 0
-- by us, server pushing SetWalkSpeed ~163 once a second, position frozen to
-- MEASURED: a guard ragdolls us roughly 0.8s after every successful steal.
-- There is nothing to do but wait. EndRagdoll typically lands ~2s later; after
function BX.groundNow(tag)
    local hrp = getHRP()
    if not hrp then return end

    -- Let the launch finish before trying to place ourselves, otherwise the
    -- residual velocity just carries us off again.
    local hum = getHumanoid()
    local t0 = os.clock()
    while os.clock() - t0 < 2 do
        local v = hrp.AssemblyLinearVelocity
        local st = hum and hum:GetState()
        if math.abs(v.Y) < 12 and st ~= Enum.HumanoidStateType.Freefall then break end
        task.wait(0.1)
    end

    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    local gy = solidGroundY(hrp.Position)
    if gy then
        pcall(function()
            hrp.CFrame = CFrame.new(hrp.Position.X, gy + 3, hrp.Position.Z) * hrp.CFrame.Rotation
        end)
        trace(("ground[%s]: dropped to %.0f"):format(tostring(tag), gy + 3))
    else
        trace("ground[" .. tostring(tag) .. "]: no floor found below us")
    end
    pcall(settleCharacter)
end

-- TWO DIFFERENT QUESTIONS, AND THEY MUST NOT SHARE A FUNCTION.
--
--   "Am I on the floor?"        -> the LOCAL humanoid. Movement cares about
--                                  this, and Anti Hit clears it in 0.00s, so
--                                  the answer is usually no and travel starts
--                                  immediately. That is correct.
--   "Will the server let me      -> the server's RagdollEndTime, which keeps
--    carry an egg?"                running through the stand-up.
--
-- I made waitForRagdollEnd answer the SECOND question, but nine callers ask it
-- the first - including the route guard and every travel leg. Every one of
-- them started waiting out a 2.5s knockdown they did not care about, which is
-- why both Main and Rift suddenly crawled. Reverted: this is the local test
-- again, and the server test lives in its own function below, used only by the
-- places that actually carry an egg.
function BX.waitForRagdollEnd(timeout)
    timeout = timeout or 8
    if not (BX.ragdollActive or isRagdolled()) then return true end

    trace("ragdoll: waiting for the server to release us")
    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        task.wait(0.15)
        if not BX.ragdollActive and not isRagdolled() then
            -- Small settle so we are back on our feet before moving.
            task.wait(0.25)
            trace(("ragdoll: released after %.1fs"):format(os.clock() - t0))
            pcall(recoverFromRagdoll)
            BX.groundNow("ragdoll-end")
            return true
        end
    end
    trace(("ragdoll: STILL held after %.1fs - giving up on this trip"):format(os.clock() - t0))
    return false
end

-- ONLY FOR THE CARRY. The server refuses CarryFieldEgg until its own
-- RagdollEndTime passes, and it says so: "Cannot carry eggs while knocked
-- down". Nothing else in the script needs to care, so nothing else calls this.
function BX.waitForCarryAllowed(timeout)
    local left = BX.ragdollRemaining and BX.ragdollRemaining() or 0
    if left <= 0 then return true end
    local deadline = os.clock() + math.min(timeout or 3, left + 0.2)
    while os.clock() < deadline do
        task.wait(0.05)
        if (BX.ragdollRemaining and BX.ragdollRemaining() or 0) <= 0 then return true end
    end
    return (BX.ragdollRemaining and BX.ragdollRemaining() or 0) <= 0
end

function BX.unstick(tag)
    local hrp = getHRP()
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hrp then return false end

    -- A ragdoll is not a pin we can break out of; it is the server holding us.
    if BX.ragdollActive or isRagdolled() then
        trace("unstick[" .. tostring(tag) .. "]: ragdolled, waiting it out")
        return BX.waitForRagdollEnd(8)
    end

    trace("unstick[" .. tostring(tag) .. "]: releasing control")

    -- Stop fighting the server for WalkSpeed and let the humanoid drive.
    pcall(BX.restoreWalkSpeed)
    pcall(function()
        if hum then
            hum.PlatformStand = false
            hum.Sit = false
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
    end)
    pcall(function()
        hrp.Anchored = false
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end)

    -- Let physics run unopposed for a beat. This is the part that matters:
    -- the server needs a window where we are not writing CFrame at all.
    task.wait(0.4)

    local before = hrp.Position
    -- HORIZONTAL nudge. This used to be Vector3.new(0, 3, 0) - straight up -
    -- and gravity pulled the character back down inside the 0.2s wait below,
    --     DIAG[stalled] authority probe: moved 8.0/8 studs -> we have authority
    pcall(function() hrp.CFrame = hrp.CFrame + Vector3.new(0, 0, -8) end)
    task.wait(0.2)
    local h = getHRP()
    local moved = h and (h.Position - before).Magnitude or 0
    local ok = moved > 2
    trace(("unstick[%s]: moved %.1f studs -> %s")
        :format(tostring(tag), moved, ok and "control regained" or "still pinned"))
    -- Put the character back so the probe itself is not a teleport.
    if ok and h then
        pcall(function() h.CFrame = CFrame.new(before) * h.CFrame.Rotation end)
    end
    return ok and true or false
end

function cfMoveTo(targetPos, speed, onComplete)
    local hrp = getHRP()
    if not hrp then
        if onComplete then onComplete() end
        return
    end

    -- Never start a route while ragdolled: the tween freezes in place, burns
    -- its 8s timeout per segment, and unstick reports "still pinned".
    if BX.ragdollActive or isRagdolled() then
        BX.waitForRagdollEnd(8)
    end

    -- Same reasoning as the ragdoll check above: starting a route while frozen
    -- means every segment of it times out.
    if isTrapped() then BX.waitForTrapEnd(9) end

    -- Respect the server's last word before starting anything new.
    --
    -- course - winning is outlasting them - so a 3s back-off per Relocate
    -- freezes the script solid. Measured in the v40 run: "relocate: #24 ...
    -- #29 - backing off 3s" back to back while the server dragged us
    -- 3948 -> 2148 -> 549 and the loop never moved.
    if BX.lastRelocate and not BX.teleportMode then
        local since = os.clock() - BX.lastRelocate
        if since < K.RELOCATE_COOLDOWN then
            local hold = K.RELOCATE_COOLDOWN - since
            trace(("cfMoveTo: holding %.1fs after a relocate"):format(hold))
            task.wait(hold)
        end
    end

    -- DIRECT routes skip buildRoute entirely. buildRoute drags every long move
    -- through K.CORRIDOR_Z (-370), which is INSIDE every guard box - fine for
    -- the ordinary run home, fatal on an escape. Measured, v26, Cherry Blossom:
    --   escape: Cherry Blossom via ledge, 60 studs -> 0.20s   (correct exit)
    --   SetWalkSpeed 194.7                                    (carry begins)
    --   SetWalkSpeed 204.1                  <- egg gone, 0.03s later
    -- that dropped 36 studs and re-entered the area it had just escaped.
    local direct = (BX.directThisRoute == true)
    BX.directThisRoute = false
    local route = direct and { targetPos } or buildRoute(hrp.Position, targetPos)

    -- Split anything long into K.MAX_SEGMENT chunks. buildRoute returns corridor
    -- waypoints, which can be thousands of studs apart; a single tween that
    -- big is the reason a stall cost 14 seconds instead of one.
    do
        -- Zigzag is opt-in PER ROUTE. It is armed only for the carry leg in
        -- returnToSafe; the run out to the egg always takes the short line,
        -- because a weaving approach drew a Relocate that knocked us off the
        local useZig = (BX.zigzagThisRoute == true)
        BX.zigzagThisRoute = false
        local segLen = useZig and K.ZIGZAG_SEGMENT or K.MAX_SEGMENT

        local segs = {}
        local cur = hrp.Position
        for _, leg in ipairs(route) do
            local d = (leg - cur).Magnitude
            if d > segLen then
                local n = math.ceil(d / segLen)
                for i = 1, n do
                    segs[#segs + 1] = cur:Lerp(leg, i / n)
                end
            else
                segs[#segs + 1] = leg
            end
            cur = leg
        end

        -- Weave across the corridor, perpendicular to travel, CLAMPED to the
        -- measured walkable strip (z -455..-285). Without the clamp a weave on
        -- waypoint is never offset - that one is home, and we have to arrive.
        if useZig and #segs > 1 then
            local side = 1
            for i = 1, #segs - 1 do
                local a = (i == 1) and hrp.Position or segs[i - 1]
                local dir = segs[i] - a
                local flat = Vector3.new(dir.X, 0, dir.Z)
                if flat.Magnitude > 1 then
                    local perp = Vector3.new(-flat.Unit.Z, 0, flat.Unit.X)
                    local off = segs[i] + perp * (K.ZIGZAG_WIDTH * side)
                    segs[i] = Vector3.new(
                        math.clamp(off.X, K.CORRIDOR_X_MIN, K.CORRIDOR_X_MAX),
                        segs[i].Y,
                        math.clamp(off.Z, K.CORRIDOR_Z_MIN, K.CORRIDOR_Z_MAX)
                    )
                    side = -side
                end
            end
            trace(("cfMoveTo: zigzag %d studs wide over %d segments"):format(K.ZIGZAG_WIDTH, #segs))
        end

        local dodged = BX.dodgeTraps(segs)
        if dodged > 0 then
            trace(("cfMoveTo: routed around traps, %d waypoints moved"):format(dodged))
        end

        route = segs
    end

    trace(("cfMoveTo: %d segments, mode=%s"):format(#route, MOVE_MODE))
    isMoving = true
    BX.routeActive = true
    -- Set here, SYNCHRONOUSLY, not inside the thread below: waitForMove() can
    -- read it before the thread has been scheduled, and a stale `true` left
    -- over from the previous route is exactly the lie we are trying to remove.
    BX.routeOk = false
    BX.routeFail = nil

    BX.routeGen = (BX.routeGen or 0) + 1
    local myRoute = BX.routeGen

    task.spawn(function()
        BX.stalled = false
        local stallRetries = 0
        local retryThis = false
        local i = 0
        local aborted = false
        while i < #route do
            if BX.routeGen ~= myRoute then
                trace("cfMoveTo: route superseded - yielding to the newer one")
                return
            end
            if not retryThis then i = i + 1 end
            retryThis = false
            local leg = route[i]
            local gy = solidGroundY(leg)
            local legTarget = Vector3.new(leg.X, gy or leg.Y, leg.Z)
            local done = false

            trace(("cfMoveTo: seg %d/%d -> %.0f,%.0f,%.0f (dist %.0f)"):format(
                i, #route, legTarget.X, legTarget.Y, legTarget.Z,
                (legTarget - (getHRP() and getHRP().Position or legTarget)).Magnitude))

            -- Noclip through anything solid in the way, exactly as hopMoveTo
            -- already does. The tween path never did this, which is why a
            -- Teleports button "completed" a 294-stud segment in 0.3s without
            -- looked fine because it starts from outside the barrier.
            -- NEVER NOCLIP WITH AN EGG IN HAND.
            -- Measured, the clean loss this was cut for:
            --   97.96 escape ... 0.26s  (window 0.63s) guard beaten
            --  102.26 DROP: carry ended                 0.07s, ~19 studs in
            if noclipGated then
                local h0 = getHRP()
                if heldEggUid and not BX.noclipWhileCarrying then
                    disableNoclip()
                elseif h0 and isBlocked(h0.Position, legTarget) then
                    enableNoclip()
                else
                    disableNoclip()
                end
            end
            if MOVE_MODE == "Hop" then
                hopMoveTo(legTarget, function() done = true end)
            else
                tweenLeg(legTarget, speed or TWEEN_SPEED, function() done = true end, i == #route)
            end

            local waited, lastLog = 0, 0
            local legBudget = math.max(8, (legTarget - (getHRP() and getHRP().Position or legTarget)).Magnitude / math.max(speed or TWEEN_SPEED, 1) + 5)
            -- CANCELLATION IS CHECKED IN HERE, not only between segments.
            --
            -- a segment ENDS, so a stop landing 0.02s into an 8s leg was not
            -- noticed for eleven seconds. Measured, the run this was cut for:
            --   16.12 ...seg 3 t=1s remaining 192  (tween already cancelled)
            --   25.24 seg 3 TIMED OUT after 8.0s
            -- could never arrive and the whole stall/unstick/retry machine ran
            local cancelled = false
            while not done and waited < legBudget do
                if BX.routeGen ~= myRoute
                   or (not stealing and not autoFeedEnabled and not BX.manualMove) then
                    cancelled = true
                    break
                end
                task.wait(0.03)
                waited = waited + 0.03
                if waited - lastLog >= 1 then
                    lastLog = waited
                    local h = getHRP()
                    if h then
                        trace(("  ...seg %d t=%.0fs pos %.0f,%.0f,%.0f remaining %.0f"):format(
                            i, waited, h.Position.X, h.Position.Y, h.Position.Z,
                            (legTarget - h.Position).Magnitude))
                    end
                end
            end
            if cancelled then
                trace(("cfMoveTo: seg %d cancelled after %.1fs - standing down"):format(i, waited))
                aborted = true
                BX.routeFail = "cancelled"
                break
            end

            trace(("cfMoveTo: seg %d %s after %.1fs"):format(i, done and "done" or "TIMED OUT", waited))

            if isTrapped() then
                BX.waitForTrapEnd(9)
                BX.stalled = false
                retryThis = true
                if not stealing and not autoFeedEnabled and not BX.manualMove then
                    aborted = true
                    BX.routeFail = "cancelled"
                    break
                end
                continue
            end

            if BX.stalled or not done then
                stallRetries = stallRetries + 1
                pcall(BX.diagnoseStall, BX.stalled and "stalled" or "timeout")

                if stallRetries > K.MAX_STALL_RETRIES then
                    trace(("cfMoveTo: route ABORTED after %d stalled segments"):format(stallRetries))
                    aborted = true
                    BX.routeFail = "stalled"
                    break
                end

                local regained = BX.unstick("seg" .. i)
                if not regained then
                    trace("cfMoveTo: route ABORTED - server has the part")
                    aborted = true
                    BX.routeFail = "pinned"
                    break
                end

                -- Retry this same segment rather than skipping ahead, so we do
                -- not leave the corridor by jumping to the next waypoint.
                BX.stalled = false
                trace(("cfMoveTo: retrying seg %d (%d/%d)"):format(i, stallRetries, K.MAX_STALL_RETRIES))
                retryThis = true
            else
                -- Clean segment: forgive one earlier hiccup so a long route is
                -- not killed by unrelated stalls spread across it.
                if stallRetries > 0 then stallRetries = stallRetries - 1 end
            end

            -- BX.manualMove covers the Teleports tab: without it a button press
            -- aborted after the first segment, because neither Auto Steal nor
            -- Auto Feed was running.
            if not stealing and not autoFeedEnabled and not BX.manualMove then
                aborted = true
                BX.routeFail = "cancelled"
                break
            end
        end
        -- A superseded route must not clear flags the live route depends on.
        if BX.routeGen ~= myRoute then return end
        if noclipGated then disableNoclip() end
        BX.routeOk = not aborted
        BX.routeActive = false
        isMoving = false
        if onComplete then onComplete() end
    end)
end

-- Returns TRUE only if the route reached its last waypoint. Callers that
-- ignore the result behave exactly as before.
local function waitForMove()
    while isMoving or BX.routeActive do task.wait(0.1) end
    return BX.routeOk == true
end

local function stopMovement()
    moveGeneration = moveGeneration + 1
    isMoving = false
    -- Must clear the route flag too, or waitForMove() blocks forever after the
    -- user switches Auto Steal off mid-route. Bumping routeGen also tells any
    -- route thread still in flight to stand down instead of racing the next one.
    BX.routeGen = (BX.routeGen or 0) + 1
    BX.routeActive = false
    BX.routeOk = false
    if BX.activeTweenConn then pcall(function() BX.activeTweenConn:Disconnect() end) BX.activeTweenConn = nil end
    if BX.activeTween then pcall(function() BX.activeTween:Cancel() end) BX.activeTween = nil end
    local h = getHRP()
    if h then h.AssemblyLinearVelocity = Vector3.zero end
    BX.restoreWalkSpeed()
    if moveConnection then
        pcall(function() moveConnection:Disconnect() end)
        moveConnection = nil
    end
    pcall(settleCharacter)
end

---------- ANTICHEAT COUNTERMEASURES (verified against the live client) ----------

-- Players.<you>.PlayerScripts.Game.ObbyAntiTPClient caches the Humanoid ONCE,
-- at CharacterAdded (its line 470), into an upvalue it later uses in punish():
-- We never touch the anticheat script itself, so there is nothing to detect -
function BX.swapHumanoid()
    if not BX.swapEnabled then
        trace("humanoid: swap SKIPPED (toggle off)")
        return false
    end
    local char = getChar()
    if not char then return false end

    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return false end
    if hum:GetAttribute(BX.SWAP_ATTR) == true then
        BX.swapped = true
        return true
    end

    -- the Health script re-asserts server health onto the humanoid
    local healthScript = char:FindFirstChild("Health")
    if healthScript then pcall(function() healthScript:Destroy() end) end

    hum.BreakJointsOnDeath = false
    hum.Archivable = true

    local clone = hum:Clone()
    if not clone then return false end
    clone.Name = "Humanoid"
    clone:SetAttribute(BX.SWAP_ATTR, true)
    clone:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
    clone:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
    clone:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
    clone.Health = hum.MaxHealth

    -- an Animator must exist or animations silently stop
    if not clone:FindFirstChildOfClass("Animator") then
        local anim = Instance.new("Animator")
        anim.Parent = clone
    end

    hum:Destroy()
    clone.Parent = char

    pcall(function()
        if workspace.CurrentCamera then
            workspace.CurrentCamera.CameraSubject = clone
        end
    end)

    -- re-seat the Animate script against the new humanoid
    pcall(function()
        local animate = char:FindFirstChild("Animate")
        if animate then
            local ac = animate:Clone()
            animate:Destroy()
            ac.Parent = char
            ac.Disabled = false
        end
    end)

    -- keep joints alive
    pcall(function()
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("Motor6D") then d.Enabled = true end
        end
    end)

    BX.swapped = true
    trace("humanoid: zombie desync applied (Dead state disabled)")
    return char:FindFirstChildOfClass("Humanoid") ~= nil
end

-- ObbyAntiTPClient only ARMS when Workspace.MonsterEventMap exists (refreshRegion
-- sets its region from that model; with no model the region is nil and check()
-- anticheat is fully disarmed. While that map IS present, moving >=300 studs is
function BX.monsterActive()
    return Workspace:FindFirstChild("MonsterEventMap") ~= nil
end

function BX.armRigSync()
    if BX.rigConn then return end
    local ok = pcall(function()
        local Remotes = require(RS.Shared.Remotes)
        BX.rigConn = Remotes.RigSync.Refresh.OnClientEvent:Connect(function(raw)
            local text = tostring(raw)
            -- SetWalkSpeed arrives ~1/s (WalkSpeedGovernor) and is already
            -- reported as "walkspeed: X -> Y" below. Everything else -
            -- Relocate, BeginRagdoll, EndRagdoll - is worth the raw payload.
            if not text:find("SetWalkSpeed") then
                trace("SERVER RigSync -> " .. text)
            end

            if text:find("Relocate") then
                BX.lastRelocate = os.clock()
                BX.relocates = (BX.relocates or 0) + 1
                BX.relocAt = os.clock()   -- read by the arc mover's speed clamp
                -- IN THE ARENA A RELOCATE IS NOT A ROUTE PROBLEM. The steal
                -- loop backs off 3s per Relocate, which is right for a tween
                -- across the map and wrong here: the fight tick just stops
                -- swinging while the server tows us to the door and back. The
                -- mover is slow and capped now, so there is nothing to back
                -- off from.
                if not (BX.inBossArena and BX.inBossArena()) then
                    BX.stalled = true
                    pcall(stopMovement)
                end
                trace(("relocate: #%d - backing off %ds"):format(BX.relocates, K.RELOCATE_COOLDOWN))

                -- AUTOMATIC SPEED BACKOFF.
                --
                -- a kick had exactly that: relocate bursts while the outbound
                -- leg ran at 800-850 studs/s.
                -- The game's own budget (ObbyAntiTPClient) is WalkSpeed * 1.7,
                local now = os.clock()
                if not BX.relocWindow or (now - BX.relocWindow) > K.RELOCATE_WINDOW then
                    BX.relocWindow = now
                    BX.relocBurst = 0
                end
                BX.relocBurst = (BX.relocBurst or 0) + 1

                if BX.relocBurst >= K.RELOCATE_BURST_LIMIT then
                    BX.relocBurst = 0
                    BX.relocWindow = now
                    local before = TWEEN_SPEED
                    TWEEN_SPEED = math.max(K.RELOCATE_SPEED_FLOOR, TWEEN_SPEED - K.RELOCATE_SPEED_DROP)
                    BX.carrySpeed = math.min(BX.carrySpeed or TWEEN_SPEED, TWEEN_SPEED)
                    if TWEEN_SPEED ~= before then
                        trace(("relocate: BURST of %d - speed %.0f -> %.0f")
                            :format(K.RELOCATE_BURST_LIMIT, before, TWEEN_SPEED))
                        toast(("Anticheat warning - speed cut to %d"):format(math.floor(TWEEN_SPEED)))
                    end
                end
            elseif text:find("SetWalkSpeed") then
                local n = tonumber(text:match("%[([%d%.]+)%]"))
                if n and n > 0 then
                    if BX.serverWalkSpeed and math.abs(n - BX.serverWalkSpeed) > 1 then
                        trace(("walkspeed: %.0f -> %.0f"):format(BX.serverWalkSpeed, n))
                    end
                    BX.serverWalkSpeed = n
                end
            elseif text:find("BeginRagdoll") or text:find("BeginImpulse") then
                BX.lastRelocate = os.clock()
                BX.ragdolls = (BX.ragdolls or 0) + 1
                BX.ragdollActive = true
                BX.ragdollStart = os.clock()
                BX.lastGuardHitAt = os.clock()

                -- THE SERVER TELLS US HOW LONG, AND WE THREW IT AWAY.
                --
                -- It matters because the server refuses a carry for that whole
                local dur = tonumber(text:match("%[%s*([%d%.]+)"))
                if dur and dur > 0 and dur < 30 then
                    BX.ragdollDur = dur
                    BX.ragdollEndsAt = os.clock() + dur
                    trace(("ragdoll: BEGIN - knocked down %.2fs (the server's own duration)"):format(dur))
                else
                    BX.ragdollEndsAt = os.clock() + 2.5
                    trace("ragdoll: BEGIN - guard hit us (no duration in payload, assuming 2.5s)")
                end
            elseif text:find("EndRagdoll") then
                BX.ragdollActive = false
                BX.ragdollEndsAt = nil
                trace(("ragdoll: END after %.1fs"):format(os.clock() - (BX.ragdollStart or os.clock())))
            end
        end)
    end)
    if ok and BX.rigConn then
        trace("rigsync: logger ARMED")
    else
        trace("rigsync: logger FAILED TO ARM - no server relocate data this run")
    end
end

-- Roblox renders the disconnect reason into a CoreGui prompt before tearing the
-- session down. Watching for it is read-only and gives us the exact kick text
-- the server sending us SetWalkSpeed and by a full successful steal cycle.
function BX.armKickLog()
    if _G.__BLYXO_KICKLOG then return end
    _G.__BLYXO_KICKLOG = true

    BX.sessionId = tostring(math.random(1000, 9999))
    BX.sessionStart = os.clock()
    trace("=== SESSION " .. BX.sessionId .. " START (heartbeat every 2s) ===")

    -- Only speak when something CHANGED. Parked idle this printed the same
    -- line every 2s forever - 60+ identical rows in the console between two
    -- interesting events, which is how the actual failure gets scrolled away.
    task.spawn(function()
        local lastLine
        local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
        while true do
            if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
            task.wait(2)
            local hrp = getHRP()
            local pos = hrp and string.format("%.0f,%.0f,%.0f",
                hrp.Position.X, hrp.Position.Y, hrp.Position.Z) or "?"
            local line = ("pos %s stealing=%s carrying=%s")
                :format(pos, tostring(stealing), tostring(heldEggUid ~= nil))
            if line ~= lastLine then
                lastLine = line
                print(("[BLYXO-HB] s%s t+%.0fs %s")
                    :format(BX.sessionId, os.clock() - BX.sessionStart, line))
            end
        end
    end)

    -- Dialog text is still logged, but explicitly marked UNRELIABLE so it is
    -- never mistaken for proof again.
    task.spawn(function()
        local cg = game:GetService("CoreGui")
        local seen = {}
        local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
        while true do
            if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
            pcall(function()
                for _, d in ipairs(cg:GetDescendants()) do
                    if d:IsA("TextLabel") and type(d.Text) == "string"
                       and #d.Text > 20
                       and (d.Text:find("removed for cheating")
                         or d.Text:find("kicked by this experience"))
                       and not seen[d.Text] then
                        seen[d.Text] = true
                        print("[BLYXO-DIALOG] (UNRELIABLE - may be a leftover from a previous session) "
                              .. string.gsub(d.Text, string.char(10), " "))
                    end
                end
            end)
            -- Every 15s, not every 2s. This walks the WHOLE of CoreGui - which
            -- on a loaded client is thousands of instances - to look for a
            -- kick dialog that, by its own comment, is unreliable evidence
            -- anyway. It is a post-mortem aid, and a kick message does not
            -- disappear in 15 seconds - or in 60, which is what it is now:
            -- it runs for the whole session, idle or not.
            task.wait(60)
        end
    end)
end

function BX.restoreWalkSpeed()
    -- The hover hold owns WalkSpeed while it is running. Without this the
    -- tween paths kept yanking it back down mid-route - the trace showed
    if BX.speedHoldConn then return end
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum and BX.savedWalkSpeed then
        hum.WalkSpeed = BX.savedWalkSpeed
        BX.savedWalkSpeed = nil
    end
end

function BX.diagnoseStall(tag)
    local hrp = getHRP()
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hrp then trace("DIAG[" .. tostring(tag) .. "]: no HRP") return end

    -- The readings below are free. Log them always.
    local ra = "?"
    pcall(function() ra = string.format("%.3f", hrp.ReceiveAge) end)
    trace(("DIAG[%s] ReceiveAge=%s Anchored=%s vel=%.1f state=%s platformStand=%s sit=%s")
        :format(tostring(tag), ra, tostring(hrp.Anchored),
                hrp.AssemblyLinearVelocity.Magnitude,
                tostring(hum and hum:GetState()),
                tostring(hum and hum.PlatformStand),
                tostring(hum and hum.Sit)))

    -- NEVER probe while carrying. Knowing why a leg stalled is not worth the
    -- egg it is being used to deliver.
    if heldEggUid then
        trace("DIAG[" .. tostring(tag) .. "]: probe SKIPPED (carrying an egg)")
        return
    end

    -- Only one probe at a time. Two overlapping probes each restore to their
    -- own `before`, so the second one undoes the first.
    if BX.probing then
        trace("DIAG[" .. tostring(tag) .. "]: probe SKIPPED (already probing)")
        return
    end
    BX.probing = true

    -- Full CFrame, so a restore keeps your facing.
    local before = hrp.CFrame
    local gen = moveGeneration
    local routeGen = BX.routeGen

    pcall(function() hrp.CFrame = before + Vector3.new(0, 0, -8) end)
    task.wait(0.25)

    local h = getHRP()
    local moved = h and (h.Position - before.Position).Magnitude or 0
    trace(("DIAG[%s] authority probe: moved %.1f/8 studs -> %s")
        :format(tostring(tag), moved,
                moved > 4 and "we have authority" or "WRITE REVERTED (server owns the part)"))

    -- Put us back ONLY if nothing else has taken over during those 250ms. A
    -- live tween, a newer route, or a displacement bigger than the probe
    local safeToRestore = h
        and gen == moveGeneration
        and routeGen == BX.routeGen
        and not BX.activeTween
        and not heldEggUid
        and moved <= 12

    if safeToRestore then
        pcall(function() h.CFrame = before end)
    else
        trace(("DIAG[%s] NOT restoring position - something else has control (moved %.0f)")
            :format(tostring(tag), moved))
    end

    BX.probing = false
end

function BX.armMonsterGuard()
    if BX.monConn then return end
    BX.monConn = Workspace.ChildAdded:Connect(function(child)
        if child.Name == "MonsterEventMap" and stealing then
            stealing = false
            stopProtect()
            stopMovement()
            toast("Monster Event started - auto steal STOPPED (kill zone)")
            trace("monsterevent: map appeared, halting steal")
        end
    end)
end

-- Arm diagnostics IMMEDIATELY, not down with the UI setup. A single error in a
-- later UI call aborts the whole chunk: the CreateSlider typo killed the script
-- at line 1633, which meant the RigSync logger never armed and we lost the
-- evidence for that run's snapback. Diagnostics must survive that.
task.spawn(function()
    pcall(BX.armManualWatch)
    pcall(BX.armRigSync)
    pcall(BX.armMonsterGuard)
    pcall(BX.armKickLog)
end)

---------- CARRY / PROTECT ----------

-- Re-asserts our claim on the carried egg. Rate-governed: the server counts
-- these, so we never fire faster than BX.REASSERT_GAP no matter what calls us.

-- REMOVED. This invoked AskFieldEggCarry on a timer. The legitimate client
-- never re-asserts a carry, and the reference build that survives never touches
-- this remote at all. Kept as a no-op so existing call sites stay valid.
function BX.reassert(reason)
    return false
end

local function startProtect()
    if protectThread then return end

    -- Primary path: react to the game's own CarryChanged signal, exactly like
    -- the real client does. Zero polling.
    if not BX.carryConn and EggState and EggState.CarryChanged then
        local okConn = pcall(function()
            BX.carryConn = EggState.CarryChanged:Connect(function()
                if isProtecting and heldEggUid then
                    BX.reassert("CarryChanged")
                end
            end)
        end)
        if okConn then trace("protect: bound to EggState.CarryChanged") end
    end

    -- Safety net only. Fires every PROTECT_INTERVAL (6s) instead of 0.5s.
    protectThread = task.spawn(function()
        BX.reassert("initial")
        while isProtecting and (stealing or autoFeedEnabled) do
            task.wait(PROTECT_INTERVAL)
            if isProtecting and heldEggUid then
                BX.reassert("fallback")
            end
        end
    end)
end

function stopProtect()
    isProtecting = false
    if protectThread then
        pcall(task.cancel, protectThread)
        protectThread = nil
    end
    if BX.carryConn then
        pcall(function() BX.carryConn:Disconnect() end)
        BX.carryConn = nil
    end
end


local acEnforceEnabled = false -- Permanently disabled

local function startACEnforce()
    -- DISABLED: Continuously deleting game scripts is easily detected
    return
end

local function stopACEnforce()
    -- DISABLED: Function not needed when AC enforce is disabled
    return
end

-- Passive AntiCollision handling - instead of deleting the script,
-- we detect when it pushes us back and adjust our movement

-- SMART ANTICHEAT BYPASS (Based on decompiled ObbyAntiTPClient)
-- REMOVED: bypassObbyAntiTP()

---------- CARRY ----------


-- Carry via the game's own ProximityPrompt instead of invoking the remote.
--
-- reference build that does NOT get kicked. That build never calls an egg
-- produces a call the legitimate client never makes in that shape.
-- THE PROMPTS ARE POOLED, NOT PER-EGG.
--
-- Read live: every steal prompt is
--     CarryAreaEgg[ProximityPrompt] < SmartPromptPart[Part] < Workspace
-- and there are ~54 SmartPromptParts sitting directly under Workspace. The
-- game MOVES one to whichever egg you are standing at and enables it. They are
-- not owned by an egg.
--
-- We arrive at up to 1200 studs/s, so the game has often not repositioned or
-- enabled a prompt for OUR egg yet. The old code fired whichever enabled
-- prompt was nearest to US - which, in that window, is a stale one still
-- parked at a different egg. It fires, returns true, and nothing is stolen:
--     carry: fired prompt at 0.9 studs -> true
--     carry: prompt fired but state is Slot - retrying    (x3)
--     loop: carried=false
--
-- Fix: aim at the EGG, not at ourselves. Only accept a prompt that is next to
-- the target egg, and give the game a moment to hand one over rather than
-- burning all three attempts inside half a second.
local function firePromptCarry(targetPos)
    if not fireproximityprompt then return false end
    local hrp = getHRP()
    if not hrp then return false end

    -- 38,016 DESCENDANTS, 12 MILLISECONDS, THREE TIMES PER GRAB.
    --
    -- Measured on a live server: Workspace:GetDescendants() returns 38k
    -- instances and takes 12.1ms to walk. This ran it once per grab attempt,
    -- so a three-attempt grab spent ~36ms blocking the main thread - and it
    -- did it while standing on a nest, which is both a visible hitch and time
    -- the guard uses to reach us.
    --
    -- There are only 61 ProximityPrompts in the whole place and the steal ones
    -- do not move, so the list is cached. No CollectionService tag exists for
    -- them (checked CarryAreaEgg / AreaEgg / CarryPrompt - all empty), so the
    -- walk still has to happen; it just happens once every K.PROMPT_CACHE
    -- seconds instead of three times a second.
    -- Wait for the game to hand a prompt to the target egg. Cheap poll, and it
    -- costs nothing when one is already there.
    local now = os.clock()
    if not BX.promptCache or (now - (BX.promptCacheAt or 0)) > K.PROMPT_CACHE then
        local list = {}
        for _, d in ipairs(Workspace:GetDescendants()) do
            if d:IsA("ProximityPrompt") then
                local txt = string.lower(tostring(d.ActionText) .. " "
                    .. tostring(d.ObjectText) .. " " .. d.Name)
                if txt:find("steal") or txt:find("carry") then
                    list[#list + 1] = d
                end
            end
        end
        BX.promptCache, BX.promptCacheAt = list, now
    end
    -- THE WAIT USED TO RUN BEFORE THE LIST WAS BUILT.
    --
    -- The order was: poll BX.promptCache for up to K.PROMPT_WAIT, and on every
    -- miss set BX.promptCacheAt = 0 to "force a rebuild" - except the rebuild
    -- is the block above, which had already run for the last grab and would
    -- not run again until this call returned. So the wait polled an unchanged
    -- list a dozen times and could not possibly find anything new. On the
    -- first grab of a session it polled an empty table.
    --
    -- That is "it arrives and just goes home again", and it shows up worst at
    -- low frame rates because that is when the prompt has not been handed over
    -- yet and the wait is the thing that was supposed to cover it.
    --
    -- The invalidation was never needed either: the cache holds the
    -- ProximityPrompt INSTANCES, and pooled prompts are reassigned by changing
    -- their Parent, which the loop re-reads every pass.
    --
    -- Building first and polling second is the whole fix. Same two blocks, in
    -- the order that works.
    if typeof(targetPos) == "Vector3" then
        local waitUntil = os.clock() + K.PROMPT_WAIT
        repeat
            local got = false
            for _, d in ipairs(BX.promptCache or {}) do
                if d.Parent and d.Enabled then
                    local pp = d.Parent
                    local pos = pp:IsA("BasePart") and pp.Position
                        or (pp:IsA("Model") and pp:GetPivot().Position)
                    if pos and (pos - targetPos).Magnitude <= K.PROMPT_NEAR then
                        got = true
                        break
                    end
                end
            end
            if got then break end
            task.wait(0.05)
        until os.clock() > waitUntil
    end


    local best, bestDist = nil, math.huge
    for _, d in ipairs(BX.promptCache) do
        -- Enabled is re-checked live; only the SEARCH is cached.
        if d.Parent and d.Enabled then
            do
                local parent = d.Parent
                local pos
                if parent then
                    if parent:IsA("BasePart") then pos = parent.Position
                    elseif parent:IsA("Model") then pos = parent:GetPivot().Position end
                end
                if pos then
                    -- Must belong to the egg we came for. Without this we
                    -- happily fire a pooled prompt still parked at a
                    -- different nest.
                    local onTarget = (typeof(targetPos) ~= "Vector3")
                        or ((pos - targetPos).Magnitude <= K.PROMPT_NEAR)
                    local dist = (hrp.Position - pos).Magnitude
                    if onTarget and dist <= (d.MaxActivationDistance + 8)
                       and dist < bestDist then
                        best, bestDist = d, dist
                    end
                end
            end
        end
    end

    if not best then return false end

    -- GET INSIDE THE RANGE THE SERVER CHECKS, NOT THE ONE WE CHECK.
    --
    -- This is "sometimes it just flies away without taking the egg", and it is
    -- a lie our own log told us. The search above accepts a prompt up to
    -- MaxActivationDistance + 8 away - 16 studs for these - and
    -- fireproximityprompt happily returns true from all 16 of them, because it
    -- is a local call. The SERVER re-checks the distance against
    -- MaxActivationDistance (8, measured on every steal prompt in the place)
    -- and silently drops anything further. So the trace reads
    --
    --     carry: fired prompt at 12.4 studs -> true
    --
    -- three times, all three "succeed", no egg is ever handed over, and the
    -- loop moves on to the next target believing it tried.
    --
    -- We know exactly where the prompt is, so close the gap first. Three studs
    -- inside the limit, one frame to replicate, then fire.
    do
        local limit = (best.MaxActivationDistance or 8) - 3
        if bestDist > limit then
            local parent = best.Parent
            local pos
            if parent then
                if parent:IsA("BasePart") then pos = parent.Position
                elseif parent:IsA("Model") then pos = parent:GetPivot().Position end
            end
            if pos then
                local from = hrp.Position
                local step = (pos - from)
                local want = pos - (step.Magnitude > 0.1 and step.Unit or Vector3.new(0, 0, 1))
                    * math.max(limit * 0.5, 2)
                pcall(function()
                    hrp.CFrame = CFrame.new(Vector3.new(want.X, from.Y, want.Z))
                    hrp.AssemblyLinearVelocity = Vector3.zero
                end)
                RunService.Heartbeat:Wait()
                local h2 = getHRP()
                if h2 then
                    bestDist = (h2.Position - pos).Magnitude
                    trace(("carry: stepped in to %.1f studs (server only accepts %.0f)")
                        :format(bestDist, best.MaxActivationDistance or 8))
                end
            end
        end
    end

    pcall(function()
        best.HoldDuration = 0
        best.RequiresLineOfSight = false
    end)
    local ok = pcall(function()
        fireproximityprompt(best, 0)
        fireproximityprompt(best)
    end)
    trace(("carry: fired prompt at %.1f studs -> %s"):format(bestDist, tostring(ok)))
    return ok
end

local function carryEgg(uid, slotKey)
    carryLocked = true
    local carried = false

    -- HOW WE KNOW THE STEAL LANDED.
    --
    -- It fires CarryChanged and NEVER writes t_2, the field-record table that
    -- only moves on a separate FieldEggShifted broadcast that may lag or never
    -- arrive. Measured, v29, Prehistoric:
    --   9.23  carry: fired prompt at 6.8 studs -> true
    --   9.46  SERVER RigSync -> SetWalkSpeed 195.37      <- we HAD it
    --   2. the server's own SetWalkSpeed drop (204 -> 195 above), which is
    local carrySignal = false
    local carryConn
    pcall(function()
        if EggState and EggState.CarryChanged then
            carryConn = EggState.CarryChanged:Connect(function(info)
                if type(info) ~= "table" or info.Uid == nil or info.Uid == uid then
                    carrySignal = true
                end
            end)
        end
    end)

    local hum0 = getHumanoid()
    local baseWS = (hum0 and hum0.WalkSpeed and hum0.WalkSpeed > 0) and hum0.WalkSpeed or nil

    -- ASK EVERY WITNESS, NOT JUST THE SLOW ONE.
    --
    -- This is where the "it stands on the nest before it moves" comes from.
    -- Measured, live, one real steal:
    --
    --     21.61  carry: fired prompt at 0.8 studs -> true
    --     21.76  prompt fired but state is Slot - retrying
    --     21.79  carry: fired prompt at 0.8 studs -> true
    --     21.93  prompt fired but state is Slot - retrying
    --     21.97  carry: fired prompt at 0.8 studs -> true
    --     22.12  prompt fired but state is Slot - retrying
    --     22.32  loop: still carrying ... - going home before anything else
    --
    -- The FIRST fire worked. We held the egg from 21.61 and did not start
    -- moving until 22.32 - 0.71s parked on the nest, and the guard's waking
    -- window is 0.63s. We were standing there past the moment he gets up,
    -- every single time, which is exactly why people get caught.
    --
    -- The grab was never in doubt; the CONFIRMATION was. ReadFieldEgg(uid)
    -- kept answering "Slot" through all three tries, and then the loop's own
    -- check - which reads the whole table with ReadFieldEggs - saw "Carried"
    -- 0.2s later. So the fix is not a longer wait or more retries, it is more
    -- witnesses, and the fastest one is an instance, not a field: the game
    -- puts the egg in your hands as a Tool with ItemType = "AssetEgg" the
    -- moment the carry is granted.
    local function reallyCarrying()
        if carrySignal then return true, "CarryChanged" end
        local h = getHumanoid()
        if h and baseWS and h.WalkSpeed and h.WalkSpeed < (baseWS - 1) then
            return true, "walkspeed drop"
        end

        -- The egg in your hand - but it has to be THIS egg.
        --
        -- The first version of this accepted any Tool with
        -- ItemType == "AssetEgg" and called that a confirmed carry. Caught it
        -- live: a "Spideron Egg" tool was sitting in the character with uid
        -- c84f32aa..., and that uid is neither a field egg nor an owned one -
        -- a leftover from some earlier state. Any grab attempt made while that
        -- thing is in hand would have been confirmed instantly, without having
        -- picked anything up, and the loop would then fly home empty.
        --
        -- EggToolDisplay.GetToolUid reads the UID attribute for exactly this
        -- reason. Match it, or the witness is worthless.
        local char = getChar()
        if char then
            for _, c in pairs(char:GetChildren()) do
                if c:IsA("Tool") and c:GetAttribute("ItemType") == "AssetEgg"
                   and tostring(c:GetAttribute("UID")) == tostring(uid) then
                    return true, "egg tool in hand"
                end
            end
        end

        local st
        pcall(function()
            local rec = EggState and EggState.ReadFieldEgg and EggState.ReadFieldEgg(uid)
            st = rec and rec.State
        end)
        if st == "Carried" then return true, st end

        -- The whole-table read, which is what finally noticed in the trace
        -- above. Cheap - measured at 0.0001s - so there is no reason to make
        -- it the last resort rather than a second opinion.
        local any
        pcall(function()
            local data = EggState and EggState.ReadFieldEggs and EggState.ReadFieldEggs()
            for _, rec in pairs(data and data.Records or {}) do
                if rec.State == "Carried" then any = rec.Uid break end
            end
        end)
        if any then return true, "ReadFieldEggs says Carried" end

        return false, st
    end

    -- Preferred: the legitimate prompt path.
    --
    -- MOVE ON THE FIRST FIRE, do not wait to be told it worked. The guard's
    -- 0.63s wake clock starts when the SERVER accepts the steal; EggState is
    -- replicated client state and lags it by the round trip. Measured:
    --   8.34  carry: fired prompt at 4.2 studs -> true
    --   8.53  carry: fired prompt at 0.5 studs -> true
    --   8.71  carry: fired prompt at 4.9 studs -> true
    if BX.instantCarry and EggState and EggState.CarryFieldEgg then
        local recPos
        pcall(function()
            local rec = EggState.ReadFieldEgg(uid)
            recPos = rec and rec.BoundsCFrame and rec.BoundsCFrame.Position
        end)
        local h = getHRP()
        local d = (recPos and h) and (recPos - h.Position).Magnitude or math.huge
        if BX.teleportMode and BX.tpEggCF and BX.tpUsedForThisEgg then
            -- RACE THE RELOCATE. Measured on the live server, this session.
            --
            --   CarryFieldEgg is a BLOCKING RemoteFunction: ~160ms round trip
            --   a bare PivotTo is relocated by the server after ~170ms
            -- PivotTo, then block 160ms inside the remote, then task.wait(0.12)
            -- - so the position was re-asserted once every ~280ms while the
            -- server relocated us every ~170ms. The character was NOT being
            -- 0.59s, Desert 3.46s, Jungle 5.28s": it was never distance, it
            local ch = getChar()
            local deadline = os.clock() + (BX.tpStealTimeout or 3)
            local lastMsg, tries, won = nil, 0, false
            local t0 = os.clock()

            -- (1) the hold, on its own thread.
            --
            -- THIS THREAD MUST BE ABLE TO DIE WITHOUT US. Caught live: the
            -- `holding = false` never runs - so the hold thread keeps
            -- server relocated it to 549 about 2.5 times a second, with no
            local holding = true
            BX.holdGen = (BX.holdGen or 0) + 1
            local myGen = BX.holdGen
            local holdTask = task.spawn(function()
                while holding and BX.holdGen == myGen and os.clock() < deadline do
                    if ch then pcall(function() ch:PivotTo(BX.tpEggCF) end) end
                    local h2 = getHRP()
                    if h2 then
                        h2.AssemblyLinearVelocity = Vector3.zero
                        h2.AssemblyAngularVelocity = Vector3.zero
                    end
                    RunService.Heartbeat:Wait()
                end
            end)

            -- (2) the staggered invokers
            local threads = math.max(1, K.CARRY_RACE_THREADS or 3)
            for i = 1, threads do
                task.spawn(function()
                    task.wait((i - 1) * (K.CARRY_RACE_STAGGER or 0.05))
                    while not won and os.clock() < deadline do
                        if not stealing and not autoFeedEnabled then return end
                        tries = tries + 1
                        local ok, res, msg = pcall(function()
                            return EggState.CarryFieldEgg(uid, slotKey)
                        end)
                        if msg ~= nil then lastMsg = tostring(msg) end
                        -- Re-check `won` AFTER the call returns: two calls can
                        -- be in flight at once, and only the first winner may
                        -- claim the carry.
                        if ok and res == true and not won then
                            won = true
                            return
                        end
                        if won then return end
                    end
                end)
            end

            while not won and os.clock() < deadline do
                if not stealing and not autoFeedEnabled then break end
                RunService.Heartbeat:Wait()
            end
            holding = false
            pcall(task.cancel, holdTask)

            if won then
                carried = true
                trace(("carry: accepted after %d calls in %.2fs (%d threads)")
                    :format(tries, os.clock() - t0, threads))
            else
                -- FUCK IT AFTER 3s. BX.tpStealTimeout used to be 8, which on a
                -- refusal meant eight seconds standing on a nest for a guard to
                -- to land lands inside ~0.4s, so anything still failing at 3s
                trace(("carry: gave up after %d calls in %.2fs - last: %s")
                    :format(tries, os.clock() - t0, tostring(lastMsg)))
            end
        elseif d <= 9 then
            local ok, res, msg = pcall(function()
                return EggState.CarryFieldEgg(uid, slotKey)
            end)
            if ok and res == true then
                carried = true
                trace(("carry: INSTANT - remote accepted at %.1f studs"):format(d))
            elseif ok then
                trace("carry: remote refused - " .. tostring(msg) .. " (falling back to prompt)")
            else
                trace("carry: remote errored - " .. tostring(res) .. " (falling back to prompt)")
            end
        else
            trace(("carry: remote skipped, %.1f studs from the egg record (needs <=9)"):format(d))
        end
    end

    -- WAIT ONLY IF THE SERVER IS STILL HOLDING US, AND ONLY THEN.
    --
    -- The server refuses CarryFieldEgg while its own RagdollEndTime is in the
    -- future - "Cannot carry eggs while knocked down" - and the three grab
    -- attempts take about half a second, so if we arrive early they all fail
    -- and the trip is wasted.
    --
    -- This is a no-op on a normal Main-tab steal: those targets are far enough
    -- that the tween outlasts the 2.5s knockdown, so ragdollRemaining is
    -- already 0 on arrival and nothing below runs. It only bites on SHORT
    -- trips - which is most rift targets, because the rift picks whichever pet
    -- is out rather than the far high-value eggs.
    --
    -- Deliberately conditional and short. An unconditional wait here is what
    -- left us standing on a nest for the guard, and that is not coming back.
    local held = BX.ragdollRemaining and BX.ragdollRemaining() or 0
    if held > 0 then
        local wait = math.min(held, K.GRAB_HOLD_MAX)
        trace(("carry: server still holds us %.2fs - waiting %.2fs before the grab")
            :format(held, wait))
        local deadline = os.clock() + wait
        while os.clock() < deadline do
            task.wait(0.05)
            if (BX.ragdollRemaining and BX.ragdollRemaining() or 0) <= 0 then break end
        end

        -- THE COUNTDOWN ENDS BEFORE THE SERVER DOES.
        --
        -- ragdollRemaining is RagdollEndTime minus the server clock, so it
        -- reaches zero the instant the deadline passes - but the server still
        -- has to process the release and send EndRagdoll. Measured, that gap
        -- is real and it cost us the egg:
        --     17.37 carry: fired prompt -> true      <- we thought we were free
        --     17.43 ragdoll: END after 2.4s          <- server released 60ms later
        -- so the first attempt was still inside the knockdown. A short grace
        -- covers the round trip.
        task.wait(K.GRAB_HOLD_GRACE)
    end

    -- HOW LONG WE ACTUALLY STAND HERE. Reported on success so a "it waits too
    -- long at the egg" can be answered with a number instead of a guess.
    local atEggAt = os.clock()

    local dashed = false
    for _ = 1, K.GRAB_TRIES do
        if carried then break end

        -- A REFUSAL WE ALREADY KNOW THE ANSWER TO IS NOT AN ATTEMPT.
        --
        -- The wait above should mean we are free by now, but the hold is read
        -- off a server clock and the release still has to travel. If we are
        -- demonstrably still knocked down, the server WILL refuse this prompt
        -- - it says so in the message - so spending one of GRAB_TRIES on it
        -- just burns the budget before the egg is grabbable. Sit the rest out
        -- instead; the deadline keeps it bounded.
        do
            local left = BX.ragdollRemaining and BX.ragdollRemaining() or 0
            if left > 0 then
                local deadline = os.clock() + math.min(left + K.GRAB_HOLD_GRACE,
                                                       K.GRAB_HOLD_MAX)
                while os.clock() < deadline do
                    task.wait(0.05)
                    if (BX.ragdollRemaining and BX.ragdollRemaining() or 0) <= 0 then
                        task.wait(K.GRAB_HOLD_GRACE)
                        break
                    end
                end
            end
        end

        if firePromptCarry(BX.carryTargetPos) then
            if not dashed and BX.dashOnPromptFire and BX.carryAreaId then
                dashed = true
                pcall(BX.guardExitDash, BX.carryAreaId)
            end
            -- CONFIRM WINDOW: 0.12s, not 0.30s.
            --
            -- Three fires at 0.30s is 0.9s of standing on the nest, and the
            -- guard's wake window (GuardChasePolicy.GetWakingDuration) is
            -- 0.63s. Measured, live, the run this was cut for:
            --   10.83 fired prompt at 1.5 studs
            --   11.14 state is Slot - retrying     <- 0.31s
            --   11.20 fired prompt at 0.8 studs
            local ok, st
            local t0 = os.clock()
            repeat
                ok, st = reallyCarrying()
                if ok then break end
                task.wait()
            until (os.clock() - t0) > K.GRAB_CONFIRM
            if ok then
                trace(("carry: confirmed Carried by EggState (%.2fs at the egg)")
                    :format(os.clock() - atEggAt))
                carried = true
                break
            end
            trace("carry: prompt fired but state is " .. tostring(st) .. " - retrying")
        end
        task.wait(0.03)
        if not stealing and not autoFeedEnabled then break end
    end

    -- Fallback: only if the prompt path is unavailable AND the user opted in.
    if not carried and BX.allowRemoteCarry then
        trace("carry: prompt failed, falling back to remote (opt-in)")
        for _ = 1, 2 do
            local ok, result = pcall(function()
                return EggState.CarryFieldEgg(uid, slotKey)
            end)
            if ok and result then carried = true break end
            task.wait(0.3)
            if not stealing and not autoFeedEnabled then break end
        end
    end

    if carryConn then pcall(function() carryConn:Disconnect() end) end

    task.delay(CARRY_LOCK_TIMEOUT, function()
        if not isProtecting then carryLocked = false end
    end)

    return carried
end

---------- SPEED CALIBRATION ----------

local function syncCalibLabel()
    if not calibLabel then return end
    pcall(function()
        calibLabel:Set(("%d studs/s  |  %d ok / %d failed  |  %d/%d to speed up")
            :format(math.floor(TWEEN_SPEED), calibStats.ok, calibStats.fail,
                    calibSuccesses, calibNeeded))
    end)
end

-- Modelled on CloverHub's "Tune speed from verified steals". Nudge up after a
-- run of clean steals, drop hard on any failure: a lost egg is cheap, a kick
-- is not, so the penalty is deliberately larger than the reward.
local function recordSpeedResult(ok)
    if ok then calibStats.ok = calibStats.ok + 1 else calibStats.fail = calibStats.fail + 1 end
    if not autoCalibrate then syncCalibLabel() return end

    if ok then
        calibSuccesses = calibSuccesses + 1
        if calibSuccesses >= calibNeeded and TWEEN_SPEED < calibMax then
            calibSuccesses = 0
            TWEEN_SPEED = math.min(TWEEN_SPEED + calibUpStep, calibMax)
            toast("Calibrate: " .. math.floor(TWEEN_SPEED) .. " studs/s")
        end
    else
        calibSuccesses = 0
        local before = TWEEN_SPEED
        TWEEN_SPEED = math.max(TWEEN_SPEED - calibDownStep, calibMin)
        if TWEEN_SPEED < before then
            toast("Calibrate: backing off to " .. math.floor(TWEEN_SPEED))
        end
    end
    syncCalibLabel()
end

---------- HOME (OUR OWN PLOT) ----------

-- Ask the game which plot is ours instead of guessing.
--
-- Re-resolved periodically because slots can change while we are connected.
K.HOME_TTL = 30

function BX.homePos()
    local now = os.clock()
    if BX.homeCached and (now - (BX.homeAt or 0)) < K.HOME_TTL then
        return BX.homeCached
    end

    local pos
    if PlotState then
        local ok, cf = pcall(function() return PlotState.FindRespawnCFrame() end)
        if ok and typeof(cf) == "CFrame" then
            pos = cf.Position
        end
    end

    -- THE FALLBACK WAS MY PLOT'S COORDINATES, AND EVERYONE ELSE INHERITED IT.
    --
    -- SAFE_POS_FALLBACK is a literal Vector3 measured on this account. When
    -- PlotState.FindRespawnCFrame returns nothing on somebody else's client -
    -- and it does, it is the first thing to resolve after a join and the last
    -- to recover after a hop - the carry was flown to MY plot instead of
    -- theirs. The trip works perfectly, the egg is never voided, and then the
    -- claim simply never fires because they are standing on a stranger's base.
    --
    -- That is the mobile video exactly: the egg survives four thousand studs
    -- through every zone with the Drop button up the whole way, and dies at
    -- the destination with "Delivery failed! The egg was returned to its
    -- nest". Nothing about the journey was wrong. The address was.
    --
    -- So ask three more times before falling back to a number, and every one
    -- of them is about THIS player: their plot model, then the spawn the game
    -- would respawn them at, then the SpawnTarget marker.
    if not pos then
        pcall(function()
            local slot = PlotState and PlotState.ResolveLocalSlot and PlotState.ResolveLocalSlot()
            local plots = slot and Workspace:FindFirstChild("Plots")
            local mine = plots and plots:FindFirstChild(tostring(slot))
            if mine then
                local ok, cf = pcall(function() return mine:GetPivot() end)
                if ok and typeof(cf) == "CFrame" then
                    pos = cf.Position
                    trace("home: PlotState gave nothing - using plot " .. tostring(slot))
                end
            end
        end)
    end

    if not pos then
        pcall(function()
            local sl = Workspace:FindFirstChildOfClass("SpawnLocation")
            if sl and sl:IsA("BasePart") then
                pos = sl.Position
                trace("home: no plot either - using this server's SpawnLocation")
            end
        end)
    end

    if not pos then
        pcall(function()
            local st = Workspace:FindFirstChild("SpawnTarget", true)
            if st and st:IsA("BasePart") then
                pos = st.Position
                trace("home: using the SpawnTarget marker")
            end
        end)
    end

    if not pos then
        pos = SAFE_POS_FALLBACK
        -- Loud, because at this point the delivery is aimed at coordinates
        -- from a different account and it is going to fail.
        trace("home: NOTHING resolved - falling back to a hardcoded point that"
            .. " is almost certainly not your plot. Deliveries will fail.")
    end

    if not BX.homeCached or (BX.homeCached - pos).Magnitude > 5 then
        local slot = "?"
        if PlotState then
            local ok2, sl = pcall(function() return PlotState.ResolveLocalSlot() end)
            if ok2 then slot = tostring(sl) end
        end
        trace(("home: plot %s at %.0f,%.0f,%.0f"):format(slot, pos.X, pos.Y, pos.Z))
    end

    BX.homeCached = pos
    BX.homeAt = now
    SAFE_POS = pos
    return pos
end

---------- RETURN TO SAFE ZONE ----------

-- Flow: tween out to the egg exactly like plain Auto Steal, steal it, then
-- come home fast. The carry leg is the dangerous one - every second walking
-- back with an egg is a second a guard can knock it out of our hands.
BX.tpBackEnabled = true

-- How close to home counts as "we made it".
K.SAFE_ARRIVE = 18

-- Hard ceiling on the carry leg. Never exceeded, by request.
K.CARRY_SPEED_CAP = 800
K.CARRY_SPEED_MIN = 150
-- The speed a script that demonstrably delivers actually uses: Zeroin, filmed
-- working, is Steal Mode = Tween with its slider at 40 = 400 studs/s. Used as
-- 250, and the reasoning is now measured rather than copied off a video.
-- ResolveFinalWalkSpeed = 205.5. The decompiled transport budget is
--     allowed = WalkSpeed * 1.7 * dt + 14 + velocity * dt
-- for tween carry is 205.5 * 1.7 = 349 studs/s.
--   294.09 DROP: 0 studs from home, 6.23s after the steal
-- [BX-DROPCALL], so the client never gave it up. That is a server verdict on
K.CARRY_REFERENCE = 500
K.CARRY_STEP_DOWN = 150  -- punishment for a lost egg, deliberately bigger

-- Self-tuning carry speed.
--
-- MEASURED: 800 studs/s (13.3 studs/frame) delivers the egg intact; 32 studs
K.CARRY_CLIMB_STEP = 90    -- how far to reach up when no ceiling is known yet
K.CARRY_CONVERGE = 15      -- gap at/under which we call the limit found
-- Set true only if a delivery is ever proven lost to SPEED rather than to a
-- guard catch. Measured evidence says it is the guard, so this stays false.
BX.carryFailIsCeiling = false

function BX.tuneCarrySpeed(state, used)
    local ok = (state == "Carried" or state == "Claimed" or state == nil)
    used = used or (BX.carrySpeed or 250)

    -- With CARRY_REFERENCE = 0 the carry is pinned to walking pace on purpose;
    -- letting the probe climb off it is what put us over budget in the first
    -- place, and distance-correlated failures are the result.
    if K.CARRY_REFERENCE == 0 then
        BX.carrySpeed = BX.legalWalkSpeed()
        return
    end

    -- Not probing: a success changes nothing, and a refusal still drops us to
    -- the floor so a genuinely bad speed cannot persist.
    if not BX.carryProbe then
        if not ok then
            -- The player's own floor, not the constant. On this account they
            -- are the same number; on a slower one the constant was the thing
            -- keeping every carry over budget.
            local floor = (BX.carryFloor and BX.carryFloor()) or K.CARRY_FLOOR
            BX.carrySpeed = floor
            BX.carryNow = floor
            trace(("carry: refused at %.0f - back to %d studs/s"):format(used or -1, floor))
        end
        return
    end

    if ok then
        -- Known-good floor moves up to whatever just worked.
        BX.carryLow = math.max(BX.carryLow or 0, used)
        local next_
        if BX.carryHigh then
            -- Bisect toward the ceiling.
            if (BX.carryHigh - BX.carryLow) <= K.CARRY_CONVERGE then
                next_ = BX.carryLow   -- converged: sit at the safe max
                trace(("carry LIMIT ~= %.0f studs/s (bracket %.0f..%.0f)")
                    :format(BX.carryLow, BX.carryLow, BX.carryHigh))
            else
                next_ = math.floor((BX.carryLow + BX.carryHigh) / 2)
                trace(("carry probe: %.0f OK -> bisect up to %.0f (hi=%.0f)")
                    :format(used, next_, BX.carryHigh))
            end
        else
            -- No ceiling yet: keep reaching higher.
            next_ = math.min(K.CARRY_SPEED_CAP, used + K.CARRY_CLIMB_STEP)
            trace(("carry probe: %.0f OK -> climb to %.0f"):format(used, next_))
        end
        BX.carrySpeed = math.clamp(next_, K.CARRY_SPEED_MIN, K.CARRY_SPEED_CAP)
        return
    end

    -- Fail: do NOT treat this as a speed ceiling any more.
    --
    -- Measured (see the note in returnToSafe): the egg is taken by a guard
    -- that physically catches you about 2s after the steal, not by a speed
    local voided = BX.deliveryVoided and (os.clock() - BX.deliveryVoided) < 5
    if BX.carryFailIsCeiling or voided then
        BX.deliveryVoided = nil
        BX.carryHigh = math.min(BX.carryHigh or math.huge, used)
        trace(("carry: %.0f studs/s VOIDED by the server - ceiling set"):format(used))
    else
        trace(("carry: delivery lost at %.0f studs/s - NOT slowing down (guard catch, not speed)"):format(used))
        return
    end
    local next_
    if BX.carryLow and BX.carryLow < BX.carryHigh then
        next_ = math.floor((BX.carryLow + BX.carryHigh) / 2)
        trace(("carry probe: %.0f REWOUND -> bisect down to %.0f (lo=%.0f)")
            :format(used, next_, BX.carryLow))
    else
        next_ = math.max(K.CARRY_SPEED_MIN, used - K.CARRY_STEP_DOWN)
        trace(("carry probe: %.0f REWOUND -> drop to %.0f (no floor yet)")
            :format(used, next_))
    end
    BX.carrySpeed = math.clamp(next_, K.CARRY_SPEED_MIN, K.CARRY_SPEED_CAP)
    toast(("Carry limit probe: %d studs/s"):format(math.floor(BX.carrySpeed)))
end

-- WHAT IS AND IS NOT ALLOWED, all measured in the live client.
--
-- The legality budget, decompiled from the game's own ObbyAntiTPClient:
--     allowed = WalkSpeed * 1.7 * dt + 14 + horizontalVelocity * dt
-- At the ~171 WalkSpeed this account has, that is about 290 studs/s sustained.
--   base -> Titan Temple  (INTO the areas)   4286 studs -> reverted instantly
--   Cosmic -> our plot    (OUT of the areas) 2896 studs -> HELD, 0 drift, 2s+
--     t=0.25  distHome=47   eggState=Dropped
function BX.armDropWatch()
    if BX.dropConn then return end

    local ok = pcall(function()
        BX.dropConn = FieldEggCarryRE.OnClientEvent:Connect(function(state)
            if typeof(state) ~= "table" then return end
            -- ANY carry ending, including the prime's Forest egg, which is
            -- never our "held" egg - the prime uses this as a hit witness.
            if state.IsCarrying == false then BX.anyCarryEndAt = os.clock() end
            if state.IsCarrying == false and heldEggUid then
                local guard = "?"
                pcall(function()
                    local areas = Workspace.__OBJECTS.Areas:FindFirstChild("GuardAreas")
                    for _, m in ipairs(areas:GetChildren()) do
                        local g = m:FindFirstChild("Guard")
                        if g and g:GetAttribute("TargetPlayer") == LocalPlayer.Name then
                            guard = m.Name .. "/" .. tostring(g:GetAttribute("GuardState"))
                        end
                    end
                end)
                local reason = tostring(state.Reason or state.DropReason or "not reported")
                BX.lastCarryEndAt = os.clock()
                trace(("DROP: carry ended, reason=%s guardChasing=%s"):format(reason, guard))

                do
                    local bits = {}
                    for k, v in pairs(state) do
                        bits[#bits + 1] = tostring(k) .. "=" .. tostring(v)
                    end
                    table.sort(bits)
                    trace("DROP: payload { " .. table.concat(bits, ", ") .. " }")
                end

                -- WHERE, and THROUGH WHAT. The loss lands 0.07s into the leg
                -- that crosses into the plot, and cfMoveTo turns noclip on
                -- whenever that leg raycasts as blocked - which it does,
                -- because the plot sits behind SafeZoneBarriers. Phasing a
                do
                    local h = getHRP()
                    local hp = BX.homePos()
                    local h0 = getHRP()
                    local dHome = (hp and h0)
                        and Vector3.new(hp.X - h0.Position.X, 0, hp.Z - h0.Position.Z).Magnitude or -1
                    trace(("DROP: %.0f studs from home, %.2fs after the steal")
                        :format(dHome, BX.carryConfirmedAt and (os.clock() - BX.carryConfirmedAt) or -1))
                    trace(("DROP: at %s noclip=%s carrySpeed=%s")
                        :format(h and ("%.0f,%.0f,%.0f"):format(h.Position.X, h.Position.Y, h.Position.Z) or "?",
                                tostring(noclipConn ~= nil),
                                tostring(BX.carrySpeed)))
                end

                -- WHO WAS NEXT TO US. The nearest guard at the moment the
                -- carry ended - name, flat distance, state and target - so a
                -- catch can be pinned on the guard that actually did it.
                pcall(function()
                    local h = getHRP()
                    local GA = workspace.__OBJECTS.Areas.GuardAreas
                    local best, bestD, bestName
                    for _, a in ipairs(GA:GetChildren()) do
                        local g = BX.findAreaGuard(a.Name)
                        if g and h then
                            local gp = g:IsA("Model") and g:GetPivot().Position or g.Position
                            local d = Vector3.new(gp.X - h.Position.X, 0, gp.Z - h.Position.Z).Magnitude
                            if not bestD or d < bestD then best, bestD, bestName = g, d, a.Name end
                        end
                    end
                    if best then
                        trace(("DROP: nearest guard %s at %.0f studs, state=%s target=%s")
                            :format(bestName, bestD, tostring(best:GetAttribute("GuardState")),
                                    tostring(best:GetAttribute("TargetPlayer") or "-")))
                    end
                end)

                local lost = heldEggUid
                heldEggUid = nil
                heldEggSlotKey = nil
                carryLocked = false
                BX.lostEgg = reason
                pcall(stopProtect)
                isProtecting = false
                pcall(recordSpeedResult, false)

                -- Force the next read to be fresh. Without this the dropdown
                -- can sit on a cached list for up to EGG_CACHE_TTL and still
                -- show nothing where the egg should be.
                BX.eggCacheAt = 0

                trace("DROP: released carry state for " .. tostring(lost))
                -- A DELIVERY ALSO ENDS THE CARRY. The server drops the carry
                -- state and THEN claims the egg - measured 0.04s apart:
                --     44.93 DROP: carry ended, reason=not reported
                --     44.97 CLAIM: server claimed our egg -> Koi Egg
                -- so this said "Lost the egg" after every successful steal.
                -- Wait for the claim; only a carry that ended WITHOUT one is
                -- a lost egg.
                local droppedAt = os.clock()
                task.delay(1.5, function()
                    if (BX.eggClaimedAt or 0) >= droppedAt then return end
                    -- Got it back mid-carry (see returnToSafe): not lost.
                    if heldEggUid ~= nil then return end
                    toast("Lost the egg")
                end)
            end
        end)
    end)
    trace("drop watch: " .. (ok and BX.dropConn and "armed" or "FAILED to arm"))
end

-- =====================================================================
--  DELIVERY (the piece that was missing entirely)
-- Reaching the safe zone was never "delivering" the egg. The game has a
-- separate PLACE step, and this hub never called it - so every carried egg
-- ended the carry and snapped the egg back to its nest ("delivery failed,
-- returning egg"). You did the whole trip but never pressed "place".

-- DELIVERY IS POSITIONAL, NOT A REMOTE. Confirmed by decompiling the game's
-- own AreaEggs controller: stealing is EggState.CarryFieldEgg; there is NO

-- Fires true once the server claims our carried egg.
-- LISTEN TO THE SERVER'S OWN ALERTS.
-- The delivery failure never comes through FieldEggCarry or the redeem verdict
-- the client - three separate runs produced no data because of it. This writes
function BX.armCarrySampler()
    if BX.sampleConn then return end
    local last, lastT = nil, 0
    BX.sampleConn = RunService.Heartbeat:Connect(function()
        if not heldEggUid then last = nil return end
        local now = os.clock()
        if now - lastT < 0.25 then return end
        local dt = now - lastT
        lastT = now
        local h, hm = getHRP(), getHumanoid()
        if not h or not hm then return end
        if last and BX.carrySamples then
            local d = ((h.Position - last) * Vector3.new(1, 0, 1)).Magnitude
            local vel = (h.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
            trace(("carry sample: rate=%.0f ws=%.1f vel=%.0f gap=%+.0f")
                :format(d / dt, hm.WalkSpeed, vel, (d / dt) - vel))
        end
        last = h.Position
    end)
    trace("carry sampler: armed")
end

function BX.armAlertWatch()
    if BX.alertConn then return end
    local ok = pcall(function()
        local net = RS.Packages.Networking
        local raise = net:FindFirstChild("RE/Alerts/Raise")
        if not raise then return end
        BX.alertConn = raise.OnClientEvent:Connect(function(...)
            for i = 1, select("#", ...) do
                local v = select(i, ...)
                if type(v) == "table" and type(v.Message) == "string" then
                    trace("SERVER ALERT -> " .. v.Message)
                    -- THE ONE UNAMBIGUOUS "TOO FAST" SIGNAL.
                    --
                    -- is why tuneCarrySpeed stopped treating losses as a speed
                    if v.Message:find("returned to its nest") then
                        BX.deliveryVoided = os.clock()
                        trace("carry: server VOIDED the delivery - treating this speed as a ceiling")
                    end
                end
            end
        end)
    end)
    trace("alert watch: " .. (ok and BX.alertConn and "armed" or "FAILED to arm"))
end

function BX.armClaimWatch()
    if BX.claimConn then return end
    local ok = pcall(function()
        BX.claimConn = EggState.FieldClaimed:Connect(function(info)
            BX.eggClaimedAt = os.clock()
            local name = (type(info) == "table" and (info.DisplayName or info.AssetCategory)) or "egg"
            trace("CLAIM: server claimed our egg -> " .. tostring(name))
            BlyxoStealDone(name)
        end)
    end)
    trace("claim watch: " .. (ok and BX.claimConn and "armed" or "FAILED to arm"))
end

-- Where to carry a stolen egg to get it claimed: a point INSIDE our plot. The
-- SpawnPoint (RespawnPointCFrame) sits in the plot's safe zone; CenterPoint is
-- the fallback. NOT the corridor - stopping at the corridor is exactly why
-- deliveries never registered.
-- and its arrival test is 28 studs on XZ:
-- reference never goes to the plot at all. It walks to the world SpawnLocation
K.SAFE_ZONE_ARRIVE = 28

function BX.safeZonePos()
    local sl = workspace:FindFirstChildOfClass("SpawnLocation")
    if sl and sl:IsA("BasePart") then
        return sl.Position + Vector3.new(0, 4, 0), "SpawnLocation"
    end
    local st = workspace:FindFirstChild("SpawnTarget", true)
    if st and st:IsA("BasePart") then
        return st.Position + Vector3.new(0, 4, 0), "SpawnTarget"
    end
    local pp
    pcall(function() pp = BX.plotDeliverPos() end)
    if typeof(pp) == "Vector3" then return pp, "plot (fallback)" end
    return SAFE_POS_FALLBACK, "hardcoded fallback"
end

function BX.plotDeliverPos()
    if PlotState then
        local plot
        local ok = pcall(function() plot = PlotState.ResolvePlot() end)
        if ok and type(plot) == "table" then
            if typeof(plot.RespawnPointCFrame) == "CFrame" then
                return plot.RespawnPointCFrame.Position
            end
            if plot.CenterPoint then return plot.CenterPoint.Position end
        end
    end
    return BX.homePos()
end

-- Is the server still treating this uid as carried by us?
function BX.stillCarrying(uid)
    local st
    pcall(function()
        local rec = EggState and EggState.ReadFieldEgg and EggState.ReadFieldEgg(uid)
        st = rec and rec.State
    end)
    return st == "Carried", st
end

function BX.eggToolUid(timeout)
    local deadline = os.clock() + (timeout or 0)
    repeat
        local char = getChar()
        local backpack = LocalPlayer:FindFirstChild("Backpack")
        for _, container in ipairs({ char, backpack }) do
            if container then
                for _, d in ipairs(container:GetChildren()) do
                    if d:IsA("Tool") and d:GetAttribute("ItemType") == "AssetEgg" then
                        local uid = d:GetAttribute("UID")
                        if type(uid) == "string" and uid ~= "" then return uid end
                    end
                end
            end
        end
        if os.clock() >= deadline then break end
        task.wait(0.05)
    until false
    return nil
end

-- The actual deposit. Returns (planted, message). message is the SERVER's own
-- rejection text on failure ("Get closer", "Not carrying", ...), which is the
-- ground truth for tuning if a plot ever refuses an edge plant.
function BX.plantHeldEgg(uid)
    if not (EggState and EggState.PlantEgg and PlotState) then
        return false, "PlantEgg/PlotState unavailable"
    end

    -- Resolve the TOOL uid, not the field uid we were handed.
    local toolUid = BX.eggToolUid(0.4)
    if not toolUid then
        return false, "no egg tool equipped yet"
    end

    local plot
    local okP = pcall(function() plot = PlotState.ResolvePlot() end)
    if not okP or type(plot) ~= "table" or not plot.PetArea or not plot.CenterPoint then
        return false, "could not resolve your plot"
    end

    local area = plot.PetArea
    -- A point on the PetArea's top surface. Randomised within the footprint so
    -- repeated deliveries don't all target the exact same stud (which the
    -- server can reject as occupied). area.CFrame handles a rotated plot.
    local half = area.Size * 0.5
    local margin = 3
    local ox = (math.random() * 2 - 1) * math.max(0, half.X - margin)
    local oz = (math.random() * 2 - 1) * math.max(0, half.Z - margin)
    local worldPos = (area.CFrame * CFrame.new(ox, half.Y, oz)).Position
    local localCF = plot.CenterPoint.CFrame:ToObjectSpace(CFrame.new(worldPos))

    local ok, a, b = pcall(function() return EggState.PlantEgg(toolUid, localCF) end)
    if not ok then return false, tostring(a) end
    return a == true, (typeof(b) == "string" and b or nil)
end

-- Try the deposit up to `tries` times, short pause between.
function BX.tryPlantHeld(uid, tries)
    local planted, msg = false, nil
    for _ = 1, (tries or 3) do
        planted, msg = BX.plantHeldEgg(uid)
        if planted then return true, msg end
        -- If the server no longer thinks we're carrying, stop hammering.
        local carrying = BX.stillCarrying(uid)
        if not carrying then return false, msg or "no longer carrying" end
        task.wait(0.25)
    end
    return false, msg
end

-- REAL, SERVER-AUTHORITATIVE WALKING via Humanoid:MoveTo. Unlike cfMoveTo's
-- CFrame tween (which the server treats as teleporting and relocates), this
-- Walks toward `pos` (flat XZ target), re-issuing MoveTo because Roblox's own
-- MoveTo self-cancels after ~8s. Returns true once within `reach` studs.
function BX.walkTo(pos, timeout, reach)
    local hum = getHumanoid()
    if not hum then return false end
    reach = reach or 6
    local deadline = os.clock() + (timeout or 12)
    hum:MoveTo(pos)
    local nextPing = os.clock() + 1.5
    while os.clock() < deadline do
        local h = getHRP()
        if not h then return false end
        local flat = Vector3.new(pos.X - h.Position.X, 0, pos.Z - h.Position.Z)
        if flat.Magnitude <= reach then return true end
        -- Interrupted (ragdoll/trap) - wait it out, then resume.
        if BX.ragdollActive or isRagdolled() then BX.waitForRagdollEnd(4) end
        if isTrapped() then BX.waitForTrapEnd(9) end
        if os.clock() >= nextPing then
            hum = getHumanoid()
            if hum then hum:MoveTo(pos) end
            nextPing = os.clock() + 1.5
        end
        task.wait(0.1)
    end
    return false
end

-- Walk the corridor route to a destination for real, segment by segment.
function BX.walkRoute(dest, timeout)
    local hrp = getHRP()
    if not hrp then return false end
    local route = buildRoute(hrp.Position, dest)
    for _, wp in ipairs(route) do
        if not heldEggUid then break end
        local gy = solidGroundY(wp) or wp.Y
        BX.walkTo(Vector3.new(wp.X, gy, wp.Z), timeout or 12, 8)
    end
    local h = getHRP()
    return h ~= nil and (Vector3.new(dest.X - h.Position.X, 0, dest.Z - h.Position.Z)).Magnitude <= 12
end

-- Clear the guard area's Bounds before the guard finishes waking.
--
-- GuardChasePolicy.ResolveWalkSpeed:
-- nil ("never catches") when our speed already beats the guard's speed at hit
--     if arg1.ExitDistance / n1 <= GuardChasePolicy_m.GetWakingDuration() then
-- GetWakingDuration() = 0.63.
-- which is the west one, 320-540 studs away - never inside the window. The
-- right target is simply the NEAREST edge. Every guard box is ~150 studs deep
local K_WAKE_WINDOW = 0.63

-- Nearest way out of the box that has real, same-level floor to land on.
-- Shared by the egg filter and the dash so they can never disagree.
-- Returns dist, target, label - or nil if there is no viable exit.
function BX.bestGuardExit(areaId, fromPos)
    if not areaId then return nil end
    local ok, bounds = pcall(function()
        return Workspace.__OBJECTS.Areas.GuardAreas[areaId].Bounds
    end)
    if not ok or not bounds or not bounds:IsA("BasePart") then return nil end

    local half = bounds.Size * 0.5
    local rel = bounds.CFrame:PointToObjectSpace(fromPos)
    if math.abs(rel.X) > half.X or math.abs(rel.Z) > half.Z then
        return nil  -- already outside the box
    end

    -- X EDGES ONLY. The Z edges are all in the walls: measured, every guard
    -- box runs z -439..-289 while the walkable band is -455..-285, so a Z
    -- already safely are, so it can never walk us into a wall.
    local margin = 14
    local cands = {
        { p = Vector3.new(half.X + margin, rel.Y, rel.Z),  n = "+X" },
        { p = Vector3.new(-half.X - margin, rel.Y, rel.Z), n = "-X" },
    }

    local best
    for _, c in ipairs(cands) do
        local world = bounds.CFrame:PointToWorldSpace(c.p)
        -- STAY ON THE MAP. Measured across all eleven areas: every guard box
        -- ends at z=-289 (Desert -293), so the +Z candidate plus this margin
        if world.Z < K.WALL_SAFE_Z_MIN or world.Z > K.WALL_SAFE_Z_MAX
            or world.X < K.CORRIDOR_X_MIN or world.X > K.CORRIDOR_X_MAX then
            continue
        end
        local gy = solidGroundY(world)
        -- Same floor, not a wall top. Cherry Blossom's z edge raycasts as
        -- perfectly good ground at y=106 against a floor at 68; taking it
        -- the egg. 8 studs is enough slack for ramps and kerbs.
        if gy and math.abs(gy - fromPos.Y) <= 8 then
            local target = Vector3.new(world.X, gy, world.Z)
            local d = (Vector3.new(target.X - fromPos.X, 0, target.Z - fromPos.Z)).Magnitude
            if not best or d < best.d then
                best = { d = d, target = target, n = c.n }
            end
        end
    end

    if not best then return nil end
    return best.d, best.target, best.n
end

-- True when that exit is reachable inside the waking window. Judged at the
-- CARRYING WalkSpeed the server knows about, not at our tween speed, because
--     Cherry Blossom  nest z -395 -> -450 = 55 studs -> 0.30s at 183
--     Titan Temple    nest z -330 -> -450 = 120 studs -> 0.66s at 183,
--                                                       0.35s at the 347 cap
-- the dash at 800 studs/s. The egg-transport budget is about WalkSpeed*1.7
-- (~347), and exceeding it sets the egg to Dropped. It was speeding, not
local LEDGE_MAX_RISE = 45
local LEDGE_WALK_Z   = -452
local LEDGE_DROP_X   = 3480   -- first x west of the wall with 67.6 floor
local LEDGE_Y        = 107

function BX.ledgeGuardExit(areaId, fromPos)
    if not areaId then return nil end
    local ok, bounds = pcall(function()
        return Workspace.__OBJECTS.Areas.GuardAreas[areaId].Bounds
    end)
    if not ok or not bounds or not bounds:IsA("BasePart") then return nil end
    local half = bounds.Size * 0.5
    local rel = bounds.CFrame:PointToObjectSpace(fromPos)
    if math.abs(rel.X) > half.X or math.abs(rel.Z) > half.Z then return nil end

    -- Step outward past the -Z edge looking for the wall top, and keep going
    -- while the ledge holds so we land in the MIDDLE of it rather than on the
    -- lip. The wall top is only 12 studs of standing room (z -442..-454, void
    -- hit would leave us 6 studs outside with the drop right behind us.
    local valid, firstY = {}, nil
    for extra = 6, 40, 2 do
        local world = bounds.CFrame:PointToWorldSpace(
            Vector3.new(rel.X, rel.Y, -half.Z - extra))
        local gy = solidGroundY(world)
        if not gy then break end
        local rise = gy - fromPos.Y
        if rise <= 8 or rise > LEDGE_MAX_RISE then break end
        -- must stay the SAME ledge, not step up onto something else
        if firstY and math.abs(gy - firstY) > 3 then break end
        firstY = firstY or gy
        valid[#valid + 1] = {
            d = (Vector3.new(world.X - fromPos.X, 0, world.Z - fromPos.Z)).Magnitude,
            target = Vector3.new(world.X, gy, world.Z),
            rise = rise,
        }
    end
    if #valid == 0 then return nil end
    -- One step (2 studs) back from the far lip. Stepping back in OBJECT space
    -- by taking the previous candidate, not by adding world +Z - the bounds
    -- parts are axis-aligned today but nothing guarantees that.
    local best = valid[math.max(1, #valid - 1)]
    return best.d, best.target, best.rise
end

-- ONE decision, used by both the egg filter and the dash.
--
-- same-level ground at 67.6, it just happens to be 252 studs away - and the
-- dash took it because it only fell back to the ledge when bestGuardExit
--   escape: Cherry Blossom via +X edge, 252 studs @ 347 studs/s -> 0.73s
--                                                       (window 0.63s)
-- 0.73 > 0.63, so the guard woke, chased, and the game executed the verdict
function BX.planGuardExit(areaId, fromPos, carryWalkSpeed)
    local budget = K_WAKE_WINDOW * 0.85
    local ws = math.max(carryWalkSpeed or 1, 1)
    local cap = ws / 0.8961 * 1.7        -- egg-transport ceiling, WalkSpeed*1.7

    -- Prefer a flat edge: no climb, and it clears at the stat speed the server
    -- knows about, so it holds whichever speed the server actually measures.
    local d, target = BX.bestGuardExit(areaId, fromPos)
    if d and (d / ws) <= budget then
        return "edge", d, target
    end

    if not BX.useLedgeExit then return nil end
    -- The ledge needs real movement (the climb is travel), so it is judged
    -- against the speed we may legally move at, not the stat speed.
    local ld, ltarget = BX.ledgeGuardExit(areaId, fromPos)
    if ld and (ld / cap) <= budget then
        return "ledge", ld, ltarget
    end
    return nil
end

-- CAN WE ACTUALLY OUT-RUN THIS AREA'S GUARD?
--
-- From the decompiled GuardChasePolicy.ResolveCatchDuration:
--     if playerSpeed >= ResolveWalkSpeed(guardBase, ref, dist) then
--         return nil          -- never caught
-- speed. Data.Guards bases, against our WalkSpeed of ~205:
-- Measured, and this is the whole "delivery failed" story: Cherry Blossom
-- lost the egg, Titan Temple lost the egg (home in 3.90s and still lost it),
function BX.canOutrunGuard(areaId)
    if not areaId then return true end
    local ok, data = pcall(function()
        return require(RS.Data.Guards).Directory[areaId]
    end)
    if not ok or type(data) ~= "table" or not data.WalkSpeed then return true end
    -- COMPARE THE CARRY AGAINST THE CHASE, NOT WALKSPEED AGAINST BASE.
    --
    -- This used to test our Humanoid.WalkSpeed (about 207) against the guard's
    -- BASE speed. Both numbers were wrong for the question being asked:
    --
    --   * We do not carry at WalkSpeed. The carry leg moves by CFrame at
    --     BX.carrySpeedNow(), currently 430.
    --   * The guard does not chase at base. GuardChasePolicy.ResolveWalkSpeed
    --     accelerates it to base * 4 once you are past its FlatRadius, which
    --     is exactly what running home does.
    --
    -- Measured from Data.Guards.Directory:
    --     Snow            base  98.0  ->  chase 392    carry 430   we win
    --     Cherry Blossom  base 222.0  ->  chase 888    carry 430   it wins
    --     Titan Temple    base 229.5  ->  chase 918    carry 430   it wins
    --
    -- That is the "Sakura and Titan do not work". Before the game update we
    -- travelled at 800-1400 and outran them; at 430 those two guards are twice
    -- our speed, so the egg is taken back every single time.
    local carry = (BX.carrySpeedNow and BX.carrySpeedNow()) or K.CARRY_FLOOR
    local chase = data.WalkSpeed * K.GUARD_CHASE_MULT
    return carry > chase * (K.OUTRUN_MARGIN or 1.02)
end

function BX.guardExitIsSafe(areaId, fromPos, carryWalkSpeed)
    -- FLIGHT CLEARS ANY BOX. This gate exists because walking out of a guard
    -- box takes longer than the 0.63s wake window for some areas, so their
    -- eggs were filtered out of the list entirely. At 1200 studs/s a 150-stud
    -- box is cleared in 0.13s, so the gate is meaningless while flying - and
    if BX.flyEnabled then return true end
    return BX.planGuardExit(areaId, fromPos, carryWalkSpeed) ~= nil
end

-- Sealed areas need the ledge, and the way home from the ledge is along the
-- wall top and down at its west end - NOT straight back across the box.
function BX.ledgeWalkHome(spd)
    local h = getHRP()
    if not h then return end
    trace(("escape: on the ledge, walking west to x=%d then down"):format(LEDGE_DROP_X))
    -- BOTH legs are direct. Anything routed here goes back over the wall.
    BX.directThisRoute = true
    cfMoveTo(Vector3.new(3560, LEDGE_Y, LEDGE_WALK_Z), spd)
    waitForMove()
    local down = Vector3.new(LEDGE_DROP_X, 0, LEDGE_WALK_Z)
    local gy = solidGroundY(down) or 70.6
    BX.directThisRoute = true
    cfMoveTo(Vector3.new(LEDGE_DROP_X, gy, LEDGE_WALK_Z), spd)
    waitForMove()
end

function BX.exitCorridorHome(areaId, exitPos, spd)
    local ok, bounds = pcall(function()
        return Workspace.__OBJECTS.Areas.GuardAreas[areaId].Bounds
    end)
    if not ok or not bounds then return end
    local westEdge = bounds.Position.X - bounds.Size.X * 0.5
    local tx = westEdge - 30
    local h = getHRP()
    if not h or h.Position.X <= tx then return end
    -- Remember the side we came out on. The carry route home must STAY on it:
    -- K.CORRIDOR_Z is -370, which runs straight through every guard box
    BX.escapeCorridorZ = math.clamp(exitPos.Z, K.WALL_SAFE_Z_MIN, K.WALL_SAFE_Z_MAX)
    trace(("escape: clearing %s westward along z=%.0f to x=%.0f")
        :format(tostring(areaId), exitPos.Z, tx))
    BX.directThisRoute = true
    cfMoveTo(Vector3.new(tx, exitPos.Y, BX.escapeCorridorZ), spd)
    waitForMove()
end

-- LEDGE EXIT: OFF. I was wrong about this one and the game says so.
--
-- edge, and the dash onto it really does clear the 0.63s window. What it does
-- not do is let you WALK on it. Measured, v27, Cherry Blossom:
--   cfMoveTo: seg 1/1 -> 3560,107,-452 (dist 466)   commanded 265 studs/s
--   seg 1 t=1s pos 3982,107,-434 remaining 422      44 studs in 1.1s (~40/s)
--   seg 1 done after 1.6s                           never arrived
--   Relocate -> 491,76,-423   relocate: #3          anticheat sent us home
BX.useLedgeExit = false

-- DASH ON PROMPT FIRE: OFF. Also measured wrong, same run.
--
-- not take, we dashed 500 studs away, and every retry then fired out of
--   11.47 carry: fired prompt at 2.3 studs -> true
--   11.47 escape: Cherry Blossom via ledge, 53 studs ...
--   15.04 loop: carried=false            and no SetWalkSpeed carry ever
-- after replication instead of 450ms.
BX.dashOnPromptFire = false

-- Is a guard actually after us right now?
--
-- of running unconditionally - the escape dash was costing 546 studs of tween
-- caught because we assumed safety is not.
function BX.guardChasingUs(areaId)
    local me = LocalPlayer.Name
    local seen = false
    local ok = pcall(function()
        local areas = Workspace.__OBJECTS.Areas:FindFirstChild("GuardAreas")
        if not areas then return end
        for _, m in ipairs(areas:GetChildren()) do
            if not areaId or m.Name == areaId then
                local g = m:FindFirstChild("Guard")
                if g and g:GetAttribute("TargetPlayer") == me then
                    seen = true
                    return
                end
            end
        end
    end)
    if not ok then return true end
    return seen
end


function BX.guardExitDash(areaId)
    local h = getHRP()
    if not h then return end
    -- TELEPORT MODE: no dash, no corridor leg. Teleporting home leaves the
    -- bounds in the same instant, and every millisecond spent here is taken
    -- straight out of the guard's ~2.5s window. Measured on the Snow run:
    --   47.68 escape dash, 37 studs
    --   49.28 that leg done             <- 1.6s gone
    --   50.23 DROP: carry ended         <- only 0.93s of holding
    -- The proven delivery needed 3.47s of holding at home to get the claim.
    -- Going straight there gives us the whole budget instead of a third of it.
    if BX.teleportMode then
        trace("escape: skipped - teleport home leaves the box instantly")
        return
    end

    local hum = getHumanoid()
    -- Fall back to the last speed the SERVER told us, not to a base-16 read.
    local raw = hum and hum.WalkSpeed or 0
    local ws = (raw > K.WALKSPEED_SANE_MIN) and raw
        or (BX.serverWalkSpeed and BX.serverWalkSpeed > K.WALKSPEED_SANE_MIN and BX.serverWalkSpeed)
        or 204
    local carry = ws * 0.8961
    local cap = ws * 1.7

    local kind, dist, target = BX.planGuardExit(areaId, h.Position, carry)
    if not kind then
        -- Already outside the box is the normal, harmless case - the dash is
        -- also called as a fallback from returnToSafe after it has already
        -- run once. Only say something when we are genuinely stuck inside.
        if BX.bestGuardExit(areaId, h.Position) == nil
            and BX.ledgeGuardExit(areaId, h.Position) == nil then
            return
        end
        trace("escape: NO exit fits the 0.63s window: " .. tostring(areaId))
        return
    end

    -- Speed is capped by the EGG TRANSPORT budget, not by the window. Moving a
    -- carried egg faster than ~WalkSpeed*1.7 sets its State to Dropped - the
    -- measured rule that killed every teleport-home attempt, and what really
    local spd = math.clamp(dist / 0.20, 200, cap)
    trace(("escape: %s via %s, %.0f studs @ %.0f studs/s -> %.2fs (window %.2fs, cap %.0f)")
        :format(tostring(areaId), kind, dist, spd, dist / spd, K_WAKE_WINDOW, cap))
    BX.lastRelocate = nil
    -- TWEEN, NOT PivotTo. v33 made this an instant PivotTo and that broke the
    -- escape completely - which is what "delivery failed even when I walked
    -- The server does not adopt a PivotTo position. Measured directly: with
    -- PlatformStand holding the character 2.0 studs from a Titan Temple egg
    -- for 1.85s with no snapback, the server still answered
    -- we never moved off the nest, the chase is resolved from there, the egg
    -- 40-60 studs and ~200 studs/s the exit still takes only 0.2-0.3s, well
    -- inside the 0.63s window, so nothing is lost by doing it properly.
    BX.directThisRoute = true
    cfMoveTo(target, spd)
    waitForMove()
    BX.escapeCorridorZ = target.Z
    if kind == "ledge" then
        BX.ledgeWalkHome(spd)
    else
        BX.exitCorridorHome(areaId, target, spd)
    end
end

-- ONE CFrame set onto solid ground. The only kind of movement teleport mode
-- performs: no tween, no MoveTo, no hop chain.
-- MEASURED, and this correction matters: hrp.CFrame does NOT move the
--   A  hrp.CFrame  +1200 -> moved  -0     (never moved at all)
--   B  char:PivotTo +1200 -> moved +1200, still +1200 after 1.0s settle
-- does. That is exactly the shape of the escape dash (40-60 studs).
-- This is the whole trick, and it is why every one-shot teleport test failed.
-- A single PivotTo is reverted ~0.3s later. Re-asserting it every ~0.2s
function BX.tpHold(cf, seconds, tag)
    local char = getChar()
    local hrp = getHRP()
    if not char or not hrp then return false end
    local deadline = os.clock() + (seconds or 1.0)
    while os.clock() < deadline do
        pcall(function() char:PivotTo(cf) end)
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        task.wait(0.15)
    end
    if tag then trace(("tp: held %s for %.1fs"):format(tostring(tag), seconds or 1.0)) end
    return true
end

-- Close a gap using only jumps the server accepts.
--
-- Measured on a quiet server (the ladder in CONFIG): one hop of <=200 studs
-- lands and HOLDS with zero relocates; 400 comes straight back. So this walks
-- and never asks for a jump that will be refused. For the normal case - a
function BX.legalHopTo(pos, maxHops, noGround)
    local char = getChar()
    if not char or not pos then return false end
    local function gap()
        local h = getHRP()
        if not h then return math.huge end
        return Vector3.new(pos.X - h.Position.X, 0, pos.Z - h.Position.Z).Magnitude
    end
    for _ = 1, (maxHops or 5) do
        local d = gap()
        if d <= 6 then break end
        local h = getHRP()
        if not h then return false end
        local to = Vector3.new(pos.X - h.Position.X, 0, pos.Z - h.Position.Z)
        local step = (to.Magnitude <= K.LEGAL_JUMP) and to or to.Unit * K.LEGAL_JUMP
        local np = h.Position + step
        local gy = noGround and np.Y or (solidGroundY(np) or pos.Y)
        if noGround and to.Magnitude <= K.LEGAL_JUMP then gy = pos.Y end
        pcall(function() char:PivotTo(CFrame.new(np.X, gy, np.Z)) end)
        local h2 = getHRP()
        if h2 then
            h2.AssemblyLinearVelocity = Vector3.zero
            h2.AssemblyAngularVelocity = Vector3.zero
        end
        task.wait(K.LEGAL_JUMP_SETTLE)
    end
    local final = gap()
    trace(("hop: legal-jump approach finished %.1f studs from target"):format(final))
    return final <= 8
end

---------- FIRST-AREA PRIME (pick up, drop, immediately) ----------
--
-- I do not have the mechanism. What I can rule out from the decompiled code:
--     create one. Measured on the Snow guard, sampling GuardState every 0.5s
--     after a deliberate drop: Waking -> ReturningHome -> Sleeping. It never
--     attribute was sampled every 0.25s across a 4260-stud flight and tracked
-- FIRST AREA deliberately: that guard is the slowest in the game (WalkSpeed
-- 16, HitDistance 2.5), it is next to the safe zone, and it is not the guard


-- A prime that takes no hit is a wasted cycle, so try again before giving up.
K.PRIME_RETRIES = 3
K.PRIME_RETRY_GAP = 0.4

K.PRIME_TIMEOUT = 3
-- How long to stand in the first-area guard's reach waiting for its hit. The
-- Forest guard walks at 16 and has to close the last couple of studs, so this
-- is generous; if nothing lands we drop by hand and carry on.
K.PRIME_HIT_WAIT = 4.0
-- Longest we will spend forcing the stand-up after the prime's hit. The
-- server re-applies the knockdown for its own duration, so this re-asserts
-- rather than calling once; it exits the moment the humanoid is actually up.
K.PRIME_RECOVER = 1.0

-- The first area is the one nearest the safe zone; resolved from the map so a
-- renamed or reordered area cannot break it.
-- WHY THE FOREST STEP WAS SKIPPED ON A FRESH JOIN.
--
-- This reads Workspace.__OBJECTS.Areas.GuardAreas, which is streamed in a
-- moment after you spawn. Turn Auto Steal on before that lands and the whole
-- thing returns nil - and primeFirstArea's `if not areaId then return false`
-- was silent, so the Forest prime was simply skipped with nothing said about
-- it. Once the areas exist it resolves correctly (measured: 11 areas, Forest
-- leftmost at x=553), so the only problem was asking too early.
--
-- Waiting is cheap and happens at most once: the result is cached forever.
function BX.firstAreaId(waitFor)
    if BX.firstAreaCached then return BX.firstAreaCached end

    if waitFor then
        local deadline = os.clock() + waitFor
        while os.clock() < deadline do
            local there = false
            pcall(function()
                there = Workspace.__OBJECTS.Areas.GuardAreas:GetChildren()[1] ~= nil
            end)
            if there then break end
            task.wait(0.2)
        end
    end

    local best, bestX
    local ok = pcall(function()
        for _, a in ipairs(Workspace.__OBJECTS.Areas.GuardAreas:GetChildren()) do
            local b = a:FindFirstChild("Bounds")
            if b and b:IsA("BasePart") then
                local x = b.Position.X - b.Size.X * 0.5
                if not best or x < bestX then best, bestX = a.Name, x end
            end
        end
    end)
    if ok and best then BX.firstAreaCached = best end
    return BX.firstAreaCached
end

-- Pick up an egg in the first area and drop it again immediately.
function BX.primeFirstArea()
    if not BX.primeEnabled then return false end
    -- Give the areas up to 5s to stream in. Only ever waits on the first
    -- call of a session, because the answer is then cached.
    local areaId = BX.firstAreaId(5)
    if not areaId then
        trace("prime: the guard areas have not loaded yet - skipping the Forest step")
        BX.primeHitLanded = false
        return false
    end

    local rec
    pcall(function()
        for _, r in pairs(EggState.ReadFieldEggs().Records) do
            if r.AreaId == areaId and r.State == "Slot" then
                if not rec then rec = r end
            end
        end
    end)
    if not rec or not rec.BoundsCFrame then
        trace("prime: no egg available in " .. tostring(areaId))
        BX.primeHitLanded = false
        return false
    end
    local pos = rec.BoundsCFrame.Position

    -- Same mover as every other leg - there is no reason the first hop of the
    -- cycle should travel differently from the rest of it.
    -- TWEEN for the prime, not the walk.
    --
    -- The walk overshoots and wanders; the tween lands on the mark, which is
    -- the whole point here - the pickup needs us inside the server's range or
    -- it answers "Get closer to the egg". Measured that directly: standing 769
    -- studs out, CarryFieldEgg with the correct slot key (Forest:Slot_003)
    -- still refused for range alone.
    local movedAt = os.clock()
    BX.arcTweenTo(pos, K.ARC_SPEED, "prime", 4)

    -- First-area eggs are the ones that need a FirstAreaSlotKey; without it
    -- the server refuses the carry outright.
    local slotKey = AreaEggSlotIdentity.LooksLikeFirstAreaUid(rec.Uid)
        and AreaEggSlotIdentity.SlotKey(rec.AreaId, rec.NestId) or nil

    local got = false
    local deadline = os.clock() + K.PRIME_TIMEOUT
    local rehops = 0
    while os.clock() < deadline and not got do
        -- PULLED BACK MID-GRAB: GO STRAIGHT BACK.
        --
        -- The first hop of a cycle sometimes gets a server Relocate ~0.2s
        -- after it lands, putting us back at spawn. This loop then spent the
        -- whole K.PRIME_TIMEOUT asking to pick up an egg 90 studs away, gave
        -- up, and the retry a second later worked - that is "the first steal
        -- never picks up, the second one does". Measured:
        --     114.68 arc: prime 90 studs in 0.21s
        --     114.87 SERVER RigSync -> Relocate   (back to 532,73,-356)
        --     117.76 prime: could not pick up in Forest
        --     118.33 arc: prime ... -> steal succeeds
        -- So when a relocate lands after the hop, hop again at once and keep
        -- trying, instead of burning the timeout and the whole attempt.
        if (BX.relocAt or 0) > movedAt and rehops < 2 then
            rehops = rehops + 1
            trace(("prime: server pulled us back - hopping straight back (%d/2)"):format(rehops))
            BX.lastRelocate = nil
            movedAt = os.clock()
            BX.arcTweenTo(pos, K.ARC_SPEED, "prime", 4)
            deadline = os.clock() + K.PRIME_TIMEOUT
        end
        local ok, res = pcall(function() return EggState.CarryFieldEgg(rec.Uid, slotKey) end)
        if ok and res == true then got = true break end
        RunService.Heartbeat:Wait()
    end
    if not got then
        trace("prime: could not pick up in " .. tostring(areaId))
        BX.primeHitLanded = false
        return false
    end

    -- TAKE THE HIT HERE. THIS IS THE POINT OF THE PRIME.
    --
    -- Dropping the egg by hand was never the same thing as losing it to a
    -- guard, and that is why deliveries fail: the sequence that works is
    -- The first area is where this costs nothing. From Data.Guards.Directory:
    --     Forest  WalkSpeed 16   HitDistance 2.5   FlatRadius 20
    -- at Titan Temple (WalkSpeed 229.5, HitDistance 7) is what loses the real
    -- egg, which is why the target steal still leaves immediately.
    pcall(BX.startAntiHit)

    local hitBefore = BX.lastGuardHitAt or 0
    local g = BX.findAreaGuard(areaId)
    local gpart = g and BX.guardAnchorPart(g)
    if gpart then
        -- Stand inside its reach. It is asleep until the steal wakes it, and
        -- at WalkSpeed 16 it will not come to us in any useful time, so we go
        -- to it.
        local want = gpart.Position
        local hh = getHRP()
        if hh then
            local gy = solidGroundY(want) or hh.Position.Y
            pcall(function() getChar():PivotTo(CFrame.new(want.X, gy, want.Z)) end)
        end
    else
        trace("prime: no guard found in " .. tostring(areaId) .. " - dropping instead")
    end

    -- ANCHOR THROUGH THE HIT. NO FLING, NO GETTING UP.
    --
    -- it just was never applied to the prime.
    local anchorCF
    do
        local hh = getHRP()
        if hh then
            anchorCF = hh.CFrame
            pcall(function() hh.Anchored = true end)
        end
    end

    local dl = os.clock() + K.PRIME_HIT_WAIT
    local hit = false
    BX.primeWitnessAt = nil
    while os.clock() < dl do
        local hh = getHRP()
        if hh then
            hh.AssemblyLinearVelocity = Vector3.zero
            hh.AssemblyAngularVelocity = Vector3.zero
            if anchorCF then pcall(function() hh.CFrame = anchorCF end) end
        end
        if (BX.lastGuardHitAt or 0) > hitBefore or BX.ragdollActive then hit = true break end
        -- MORE THAN ONE WITNESS. The two above both come from the RigSync
        -- event; on executors where that never arrives (Delta reports) every
        -- prime read as "no hit", was retried, then the whole cycle skipped -
        -- a new chicken egg every few seconds, a hundred times, never the
        -- target. These need nothing but the game's own state:
        --   * the carry of the Forest egg ended while we stood by its guard
        --     (we did not drop it; the hand-drop is only after this loop),
        --   * the character is knocked down,
        --   * the egg's record went to Dropped/GuardCarried - the hit knocked
        --     it loose. NOT "Slot": ReadFieldEgg is known to lag and still say
        --     Slot for a moment after a successful pickup, which would fake a
        --     hit and send the real steal out unprimed.
        --
        -- ...BUT LET THE KNOCKDOWN LAND HERE BEFORE LEAVING. These witnesses
        -- see the hit a few hundredths of a second BEFORE the server's
        -- BeginRagdoll arrives, and leaving on them sent the knockdown into
        -- the teleport instead - measured: witness at 7.50, TP at 7.51,
        -- BeginRagdoll at 7.53, "landed 28 studs from the egg", no pickup.
        -- The RigSync-driven path always left AFTER the knockdown began, while
        -- still anchored here, and landed on the egg. So once a witness fires,
        -- stay anchored until the knockdown starts (or 0.35s, for the
        -- executors where RigSync never arrives at all).
        local witnessed = (BX.anyCarryEndAt or 0) > hitBefore or isRagdolled()
        if not witnessed then
            local okR, r = pcall(EggState.ReadFieldEgg, rec.Uid)
            local stNow = okR and type(r) == "table" and r.State or nil
            witnessed = (stNow == "Dropped" or stNow == "GuardCarried")
        end
        if witnessed then
            BX.primeWitnessAt = BX.primeWitnessAt or os.clock()
            if BX.ragdollActive or os.clock() - BX.primeWitnessAt >= 0.35 then
                hit = true
                break
            end
        end
        if not heldEggUid and not EggState.ReadFieldEgg(rec.Uid) then break end
        RunService.Heartbeat:Wait()
    end

    -- Always unanchor, on every path out of the loop.
    do
        local hh = getHRP()
        if hh then pcall(function() hh.Anchored = false end) end
    end

    BX.primeHitLanded = hit and true or false
    if hit then
        trace(("prime: took the %s guard's hit after %.2fs"):format(
            tostring(areaId), K.PRIME_HIT_WAIT - (dl - os.clock())))
    else
        -- Nothing came. Fall back to the old behaviour so the cycle still
        -- moves on rather than standing here.
        pcall(function() return EggState.DropFieldEgg("PlayerRequest") end)
        trace(("prime: no hit inside %.1fs - dropped by hand instead"):format(K.PRIME_HIT_WAIT))
    end

    -- STRAIGHT ON TO THE TARGET. No waiting for the server's EndRagdoll.
    --
    -- the egg" you saw. We were never thrown - the anchor above saw to that -
    if hit then
        -- FORCE THE RECOVERY. BX.readyAfterRagdoll is the file's own
        -- get-up-now helper - it clears PlatformStand/Sit, restores AutoRotate
        -- the steal path uses. Re-asserted for a few frames because the server
        local t0 = os.clock()
        while os.clock() - t0 < K.PRIME_RECOVER do
            pcall(BX.readyAfterRagdoll)
            local hm = getHumanoid()
            if hm and not hm.PlatformStand then
                local st = hm:GetState()
                if st ~= Enum.HumanoidStateType.Physics
                   and st ~= Enum.HumanoidStateType.Ragdoll
                   and st ~= Enum.HumanoidStateType.FallingDown then
                    break
                end
            end
            RunService.Heartbeat:Wait()
        end
        -- Clear the flags too, so nothing downstream decides to wait out a
        -- knockdown we have already stood up from.
        BX.ragdollActive = false
        BX.ragdollEndsAt = nil
        local ch, hh = getChar(), getHRP()
        if ch and hh then
            local gy = solidGroundY(hh.Position)
            if gy then pcall(function() ch:PivotTo(CFrame.new(hh.Position.X, gy, hh.Position.Z)) end) end
        end
        trace(("prime: recovered in %.2fs - going straight for the target"):format(os.clock() - t0))
    end
    BX.primedAt = os.clock()
    return true
end

---------- DECOY DROP (the thing every working script does) ----------
--
-- it is worth reading because it makes guard speed irrelevant.
--         return true                  -- wakes, but never enters chase
-- So: A GUARD WITH A PENDING EGG RETRIEVAL CANNOT CHASE. And RegisterDroppedEgg
-- guard to the DroppedPosition, attaches the egg at EggPickupDistance, then
-- walks to _homeCFrame and only deposits within 20 studs. The whole time it
-- This is why the guard-speed gate stops mattering: Cherry Blossom (222) and

-- How long one decoy is assumed to keep a guard busy before we lay another.
-- The retrieval is a walk out plus a walk home, so this is deliberately short
-- of the real duration rather than over it.
K.DECOY_TTL = 25

-- Cheapest Slot egg in this area that is not the one we actually want.
function BX.pickDecoyEgg(areaId, avoidUid)
    local best, bestVal
    local ok = pcall(function()
        for _, rec in pairs(EggState.ReadFieldEggs().Records) do
            if rec.AreaId == areaId and rec.State == "Slot" and rec.Uid ~= avoidUid then
                local v = tonumber(rec.Income) or 0
                if not best or v < bestVal then best, bestVal = rec, v end
            end
        end
    end)
    if not ok then return nil end
    return best
end

---------- FLIGHT (velocity, not CFrame) ----------
--
-- THE THING THAT ACTUALLY WORKS. Measured end to end on the live server:
--   CFrame chain, 60 studs/frame   2275 studs in 0.59s, 0 relocates
--                                  the client stood 0.0 studs from it. Stop
--                                  asserting and we snap back 400-570 studs.
--                                  The client moved; the server never did.
--   VELOCITY 1200                  2275 studs in 0.36s (6303 studs/s
K.FLY_SPEED = 1200         -- empty-handed. 1200 measured clean.
-- CARRY SPEED: 900, MEASURED end to end, not inferred.
--
-- This was 340, taken from the file's "transport budget" of WalkSpeed * 1.7.
-- Monster Event, so it was never binding anything. At 340 a 1430-stud carry
-- takes 4.2s and the delivery became a coin flip against the guard - the
-- trace has two losses (one dropped 6.2 studs from home) against one win.
-- Full cycle at 900, live: egg 401 studs out, outbound flight 1200, steal
-- accepted, carry home at 900 with ZERO relocates, 0.78s from steal to home,
K.FLY_CARRY_SPEED = 1000

-- Fly the MIDDLE of the map, not the straight line.
--
-- WHY THIS BEATS THE OLD flyTo. flyTo zeroes Y - `local to = Vector3.new(x, 0,
-- way. That is why it needed the three-leg corridor routing in flyRouteTo:
-- 140 was my invention and it is why it looked nothing like the reference.
-- Low altitude is safe here because this mover writes CFrame rather than
-- corridor walls that forced the old flyTo into three-leg routing do not
K.ARC_CRUISE_UP = 18       -- studs above the higher end to cruise at
K.ARC_RAMP_FRAC = 0.12     -- share of the flat distance spent climbing/diving
K.ARC_RAMP_MAX = 220       -- ...but never more ramp than this
K.ARC_RAMP_MIN = 40        -- ...nor less, or the climb is a vertical jerk
-- LEAVE FAST, CLIMB SLOWLY. These are two different ramps and conflating
-- them is what got you caught: the speed ramp used to run the WHOLE length of
-- the height ramp, so we crawled out of the nest at 0.28 * cruise while a
-- woken guard was standing next to us. The `/` shape comes from the HEIGHT
-- ramp; the speed has no reason to take that long.
K.ARC_START_SPEED = 0.45   -- fraction of cruise speed we leave the ground at
K.ARC_SPEED_RAMP_FRAC = 0.28  -- speed reaches cruise in this share of the climb
K.ARC_SLOW_RADIUS = 50     -- switch to the careful approach inside this
-- The final approach is a DECELERATION, not a crawl. At 140 the last 50
-- studs took 0.36s, all of it spent creeping up on a nest with a guard
-- standing on it, and the guard's grace after a steal is only 0.63s total -
-- so a third of the budget was gone before the steal even fired. 260 still
-- reads as a clear slow-down from 1500 and costs 0.19s.
K.ARC_SLOW_SPEED = 260
K.ARC_ARRIVE = 5
K.ARC_MAX_DT = 0.05        -- longest SINGLE step we will write, in seconds
-- How long after a relocate we defer to the anticheat's own allowance, and the
-- WalkSpeed multiple to assume when its debug table is out of reach. 1.04 is
-- the low end of what was measured live (the Short window ran 1.04-1.11).
K.RELOC_CLAMP_FOR = 6
K.RELOC_CLAMP_RATIO = 1.04
-- Longest whole frame we will spend at once. Past this the client has hitched
-- badly enough that catching up in one go would be a teleport, so the excess
-- is dropped - but 0.25s covers anything down to 4fps.
K.ARC_MAX_FRAME = 0.25
-- Most unspent travel time we will hold on to. Two seconds covers a serious
-- hitch; beyond that the client has been frozen long enough that catching up
-- would look like teleporting, so the rest is genuinely forfeited.
K.ARC_MAX_DEBT = 2.0

-- GO FASTER BY CAPPING THE STEP, NOT THE SPEED.
--
-- The snapback this file measured is not about studs per SECOND, it is about
--     13.3 studs/frame is under whatever the per-step threshold is;
--     32 studs/frame is over it.
-- 800 studs/s at 60fps is exactly 13.3 studs/frame - which is why 800 became
-- "the proven speed". It was never the speed that was proven, it was the step.
-- client that works out at ~1200 studs/s, half again as fast as before and
-- Step one of the ladder. Raise in increments watching for "relocate: #" in
-- the log: 1200 -> 1500 -> 1800. The reference clip measures at ~2100.
-- The step cap tracks it: speed / 60.
-- BACK TO 1200. Empirical, from your runs: 1200 travelled clean, 1500 gave
-- "relocate: #29 ... #30" inside a single outbound leg and dragged the
-- effective speed down to 710 studs/s - slower than 1200 ends up being.
--
-- Whether 1500 is reachable at all depends on the spoof actually attaching.
-- The arc now logs "(N ac states)" when it arms: if N is 0 the state table
-- was never found, nothing is being rewritten, and no amount of speed will
-- work. If N is non-zero and 1500 still relocates, then 1500 is simply past
-- what this server tolerates and 1200 is the answer.
K.ARC_MAX_STEP = 20        -- ceiling on one frame's displacement (hitch guard)
K.ARC_SPEED = 1200         -- outbound cruise
-- THE CARRY IS BACK ON THE TUNED SPEED. nil = use whatever tuneCarrySpeed
-- has converged on for this account and server.
-- I set this to 1000 last turn because you asked for a faster return, and
-- real and still holds: moving a HELD egg over the transport budget sets its
-- State to Dropped, and that is independent of the prime, the guard hit, or
K.ARC_CARRY_SPEED = nil

-- Ground height under a point, falling back to the point's own Y.
local function arcGroundY(p, fallback)
    local gy = solidGroundY(p)
    return gy or fallback or p.Y
end

-- One arc leg. Returns true if we finished within reach of the target.
--
-- `speed` is the CRUISE speed. Carrying legs must pass the carry budget here,
-- its State to Dropped and a guard walks it home, which is measured and

function BX.arcTweenTo(pos, speed, tag, arrive, cancel)
    local char, h = getChar(), getHRP()
    if not char or not h or not pos then return false end
    -- When this leg began, and whether it carries an egg - see the relocate
    -- clamp below for why a carry only answers to relocates of its own.
    local legAt, legCarrying = os.clock(), heldEggUid ~= nil
    -- NEVER INSIDE THE BOSS ARENA. The boss fight has its own mover; two
    -- things writing the character's pivot every frame is what made the fight
    -- jitter and drift.
    if BX.inBossArena and BX.inBossArena() then
        trace("arc: refusing to move - in the boss arena")
        return false
    end
    local hum = getHumanoid()

    arrive = arrive or K.ARC_ARRIVE
    speed = math.max(speed or K.FLY_SPEED, 40)

    local start = h.Position
    local flatTotal = Vector3.new(pos.X - start.X, 0, pos.Z - start.Z).Magnitude
    if flatTotal < 1 then return true end

    -- Cruise altitude: above whichever end sits higher, so the flat middle
    -- clears the ground between them.
    local startGround = arcGroundY(start, start.Y)
    local endGround = arcGroundY(pos, pos.Y)
    local landY = endGround
    local cruiseY = math.max(startGround, endGround, start.Y, pos.Y) + K.ARC_CRUISE_UP

    -- Ramp lengths. On a short hop there is not room for a full climb and
    -- dive, so they share the distance rather than overlapping.
    local ramp = math.clamp(flatTotal * K.ARC_RAMP_FRAC, K.ARC_RAMP_MIN, K.ARC_RAMP_MAX)
    if ramp * 2 > flatTotal * 0.9 then ramp = flatTotal * 0.45 end

    -- A trip too short to be worth climbing for is flown flat.
    if flatTotal < K.ARC_RAMP_MIN * 2 then cruiseY = math.max(start.Y, pos.Y) end

    local wasPS = hum and hum.PlatformStand or false
    if hum then hum.PlatformStand = true end

    -- Spoof only when empty-handed - see the note on K.ARC_SPOOF_HEADROOM.
    local spoof = BX.arcSpoof and hum and (heldEggUid == nil)

    -- WHY THE CARRY LEG IS NOT CLAMPED TO THE ANTICHEAT'S ALLOWANCE.
    --
    -- I clamped it for one build and it was a bad trade. The reasoning was
    -- sound and the numbers were real - the carry runs unspoofed at ~499 while
    -- the anticheat allows ~230, which is 2.2x over and is why Titan, the
    -- longest leg at 4293 studs, is where the snap-back happens.
    --
    -- But holding the carry at 230 hands the guard the trip. Chase speeds go
    -- to base * 4: Prehistoric 608, Cosmic 800, Cherry Blossom 888, Titan 918.
    -- At 230 they all catch you, everywhere, and the result was worse than the
    -- occasional relocate it was meant to prevent.
    --
    -- So the speed stays. The snap-back is a real and identified bug, but the
    -- cure has to be something that does not slow the carry down - spoofing
    -- the carry leg, or shortening it - and not this.
    local savedWS, claimWS
    if spoof then
        pcall(BX.acArm)

        -- THE GAME UPDATE DELETED THE STATE TABLE THIS SPOOF WRITES TO.
        --
        -- The whole trick was: raise Humanoid.WalkSpeed far past legal, then
        -- keep the CLIENT anticheat's own record clean so nothing reports it.
        -- After the 2026-09 update that record is gone - swept the live heap
        -- for its twelve marker fields (MaxHorizontalSpeed, ThreatLevel,
        -- GroundContactWitness, InitializingUntil, ...) and every one of them
        -- returned zero hits.
        --
        -- So the WalkSpeed write is now naked. Measured straight after the
        -- update: Humanoid.WalkSpeed = 1620 against a legal 207.86, and the
        -- server answered with eight Relocates in five seconds -
        --     relocate: #1 ... #8 - backing off 3s
        -- which is the "it snapped me back to tweening to the egg".
        --
        -- Rather than guess at a replacement, detect the absence and travel
        -- honestly: leave WalkSpeed alone and step positions at the speed the
        -- carry leg has always got away with. If a future update brings the
        -- table back, acArm finds it again and the spoof resumes by itself.
        if #BX.acStates == 0 then
            spoof = false
            -- Start from what the anticheat actually permits rather than from
            -- a number I picked. The bisect below still runs, so a client that
            -- turns out to have more room will find it - it just no longer
            -- starts 2.3x over the line and spends its first legs being
            -- relocated.
            BX.noSpoofSpeed = BX.noSpoofSpeed or BX.acLegalSpeed()
            speed = math.min(speed, BX.noSpoofSpeed)
            -- Remember what this leg is being run at, and how many Relocates
            -- we had before it started, so the end of the leg can judge it.
            BX.noSpoofLegSpeed = speed
            BX.noSpoofLegRelocs = BX.relocates or 0
            -- Put back anything a previous spoofed leg left inflated, or the
            -- server sees an illegal WalkSpeed before we have taken a step.
            pcall(function()
                local legal = BX.legalWalkSpeed and BX.legalWalkSpeed() or 200
                if hum.WalkSpeed > legal + 1 then hum.WalkSpeed = legal end
            end)
            if os.clock() - (BX.noSpoofAt or 0) > 20 then
                BX.noSpoofAt = os.clock()
                trace(("arc: no anticheat state to spoof (game update) - travelling at %d studs/s")
                    :format(speed))
            end
        end
    end
    if spoof then
        BX.spoofMoving = true          -- stops acPush writing velocity itself
        savedWS = hum.WalkSpeed
        claimWS = math.clamp(speed * K.ARC_SPOOF_HEADROOM, 16, K.ARC_WS_MAX)
        hum.WalkSpeed = claimWS
        trace(("arc: spoof armed for %s - claiming WalkSpeed %.0f for %.0f studs/s (%d ac states)")
            :format(tostring(tag or "leg"), claimWS, speed, #BX.acStates))
    end

    local t0 = os.clock()
    local deadline = t0 + math.max(flatTotal / speed, 0.3) * 3 + 6
    local ok = false
    local lastT = os.clock()
    -- Unspent frame time, carried forward. Reset per trip.
    local arcDebt = 0

    while os.clock() < deadline do
        if cancel and cancel() then break end
        local hh = getHRP()
        if not hh then break end

        local now = os.clock()
        -- FRAME TIME IS NOT DISCARDED ANY MORE - SEE THE SUB-STEP BELOW.
        --
        -- This used to be min(now - lastT, 0.05), and everything past 0.05s
        -- was simply thrown away. On a 60fps desktop that never bites, but a
        -- phone running at 10-15fps loses half of every frame:
        --     20 fps -> 430 studs/s   (100% of target)
        --     15 fps -> 322 studs/s   ( 75%)
        --     10 fps -> 215 studs/s   ( 50%)
        -- so the carry home took twice as long as the script planned, the
        -- guard caught up, and the egg went back to its nest - which is
        -- exactly the "Lost the egg / Delivery failed - egg Slot" the Delta
        -- mobile players are seeing.
        --
        -- The clamp is kept for what it was actually for: no single PivotTo
        -- may jump a huge distance, because that is what climbs geometry and
        -- flings us. The full frame is spent, just in several small writes
        -- rather than one big one.
        -- A LAG SPIKE MUST NOT COST DISTANCE PERMANENTLY.
        --
        -- Sub-stepping already fixed steady low frame rates, but a one-off
        -- hitch longer than K.ARC_MAX_FRAME still had its excess thrown away,
        -- and every discarded millisecond makes the trip longer in real time.
        -- On the longest carry in the game that is what decides the outcome:
        --
        --     Titan Temple  4293 studs   8.6s at 500 studs/s
        --     Cherry Blossom 3522        7.0s
        --     everything else <= 1777    <= 3.6s
        --
        -- Titan is the only leg long enough for accumulated stalls to matter,
        -- which is exactly why it is the only area that fails on laggy
        -- clients and succeeds on fast ones.
        --
        -- So the excess is not dropped, it is BANKED and repaid over the
        -- following frames - still at most K.ARC_MAX_FRAME of travel in any
        -- one frame, so nothing teleports. The trip takes the same wall-clock
        -- time on a stuttering client as on a smooth one, which is the whole
        -- point.
        local raw = now - lastT
        lastT = now
        arcDebt = math.min((arcDebt or 0) + raw, K.ARC_MAX_DEBT)
        local frameDt = math.min(arcDebt, K.ARC_MAX_FRAME)
        arcDebt = arcDebt - frameDt

        local subSteps = math.max(1, math.ceil(frameDt / K.ARC_MAX_DT))
        local dt = frameDt / subSteps

        local flat = Vector3.new(pos.X - hh.Position.X, 0, pos.Z - hh.Position.Z)
        local rem = flat.Magnitude
        if rem <= arrive then ok = true break end

        local done = math.max(flatTotal - rem, 0)

        -- SPEED: ramp up over the first `ramp` studs, hold, ramp down over the
        -- last `ramp`, then crawl the final K.ARC_SLOW_RADIUS.
        local want
        local speedRamp = math.max(ramp * K.ARC_SPEED_RAMP_FRAC, 1)
        if rem <= K.ARC_SLOW_RADIUS then
            want = math.min(K.ARC_SLOW_SPEED, speed)
        elseif rem < ramp then
            local f = rem / ramp
            want = math.max(speed * f, math.min(K.ARC_SLOW_SPEED, speed))
        elseif done < speedRamp then
            want = speed * (K.ARC_START_SPEED + (1 - K.ARC_START_SPEED) * (done / speedRamp))
        else
            want = speed
        end

        -- WHILE IT IS RELOCATING US, MOVE AT THE SPEED IT ALLOWS.
        --
        -- Your log, one run:
        --
        --     relocate: #69 ... #90          one every ~0.7s, ninety of them
        --     arc: spoof armed - claiming WalkSpeed 1620 for 1200 studs/s
        --     arc: prime 1363 studs in 9.41s (cruise 1200) -> 417.5 short
        --
        -- The spoof IS armed and still it gets relocated, because the spoof
        -- raises Humanoid.WalkSpeed and the server's own WalkSpeedGovernor
        -- pushes the real value back about once a second. The anticheat sizes
        -- its allowance off the LIVE WalkSpeed, so for most of every second the
        -- allowance is ~230 while we are asking for 1200.
        --
        -- The result is not fast. 1363 studs took 9.41s and still finished 417
        -- short - about 100 studs/s of actual progress, because every relocate
        -- drags us backwards. Travelling at the permitted speed is FASTER than
        -- being dragged back five times a second.
        --
        -- So this is not a speed cap, it is a fallback: full speed while the
        -- spoof is holding, and the anticheat's own number for a few seconds
        -- after it objects. A client where the spoof works never touches it.
        --
        -- A CARRY ONLY ANSWERS TO RELOCATES THAT HAPPEN DURING THE CARRY.
        -- A relocate on the empty-handed hop to the egg - now followed at once
        -- by a second hop and a successful grab - left BX.relocAt seconds
        -- old when the carry home began, so the whole trip home crawled at
        -- the ~216 studs/s allowance: below most guards' starting speed
        -- (Titan 229), and the "it starts lagging and going slow the moment
        -- it steals" report. Empty-handed legs keep the clamp as before.
        local relocCounts = BX.relocAt and (not legCarrying or BX.relocAt >= legAt)
        if relocCounts and (os.clock() - BX.relocAt) < K.RELOC_CLAMP_FOR then
            local allow
            pcall(function()
                for _, st in ipairs(BX.acStates or {}) do
                    local hd = rawget(st, "HorizontalDebug")
                    if type(hd) == "table" and hd.Short and hd.Short.Duration then
                        allow = hd.Short.AllowedHorizontalDistance / hd.Short.Duration
                        return
                    end
                end
            end)
            if not allow then
                local hum2 = getHumanoid()
                local ws = hum2 and hum2.WalkSpeed or 0
                if ws > K.WALKSPEED_SANE_MIN then allow = ws * K.RELOC_CLAMP_RATIO end
            end
            if allow and allow > 0 and want > allow then
                if not BX.saidClamp or (os.clock() - BX.saidClamp) > 5 then
                    BX.saidClamp = os.clock()
                    trace(("arc: relocated - holding %d studs/s (what it allows) instead of %d")
                        :format(math.floor(allow), math.floor(want)))
                end
                want = allow
            end
        end

        -- HEIGHT: climb over the first ramp, hold the cruise, dive over the
        -- last. The dive lands on the target's own Y, not on the cruise.
        local wantY
        if done < ramp then
            wantY = start.Y + (cruiseY - start.Y) * (done / ramp)
        elseif rem < ramp then
            wantY = landY + (cruiseY - landY) * (rem / ramp)
        else
            wantY = cruiseY
        end

        -- One frame's worth of travel, applied as `subSteps` writes of the
        -- same size the desktop path has always used.
        local arrived = false
        for _ = 1, subSteps do
            local hp = hh.Position
            local f2 = Vector3.new(pos.X - hp.X, 0, pos.Z - hp.Z)
            local rem2 = f2.Magnitude
            if rem2 <= arrive then arrived = true break end

            local step = math.min(rem2, want * dt, K.ARC_MAX_STEP)
            local nxt = hp + f2.Unit * step
            local dest = Vector3.new(nxt.X, wantY, nxt.Z)

            pcall(function()
                if hum then hum:Move(Vector3.zero, false) end
                char:PivotTo(CFrame.lookAt(dest, dest + f2.Unit))
                hh.AssemblyLinearVelocity = Vector3.zero
                hh.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        if arrived then ok = true break end

        -- Tell the anticheat a story its own WalkSpeed can account for: the
        -- direction we actually moved, at a speed the claimed WalkSpeed
        -- permits. Then zero the real velocity again, because the CFrame write
        -- IS the movement and a matching velocity would double it.
        if spoof then
            -- RE-ASSERT THE CLAIM EVERY FRAME.
            --
            -- Setting WalkSpeed once before the loop is not enough: the game
            -- runs a governor that writes it back roughly once a second - the
            -- "walkspeed: 207 -> 199" line in the trace is it doing exactly
            -- that. The moment it lands we are travelling at cruise with a
            -- WalkSpeed of 207 behind us, which is the contradiction the
            -- validator relocates for. That is the "sometimes" - it depends
            -- entirely on when the governor fires.
            --
            -- acPush also caps the velocity it reports at hum.WalkSpeed, so a
            -- reset would make us report 207 while moving 1500 - wrong twice
            -- over.
            if hum.WalkSpeed < claimWS - 1 then hum.WalkSpeed = claimWS end
            local told = flat.Unit * math.min(want, claimWS)
            if #BX.acStates > 0 then
                BX.acPush(hh, hum, told)
            else
                BX.spoofAc(claimWS, told)
            end
            pcall(function() hh.AssemblyLinearVelocity = Vector3.zero end)
        end

        -- YIELD. THIS LINE IS THE WHOLE "IT FREEZES MY GAME".
        --
        -- Without it this is a bare `while os.clock() < deadline` that never
        -- measured between iterations, so with no frame boundary dt is ~0,
        -- step is ~0, and the remaining distance never falls. It spins for the
        RunService.Heartbeat:Wait()
    end

    local hz = getHRP()
    if hz and char then
        local gy = solidGroundY(hz.Position)
        if gy and math.abs(hz.Position.Y - gy) > 1 then
            pcall(function() char:PivotTo(CFrame.new(hz.Position.X, gy, hz.Position.Z)) end)
        end
    end
    if spoof and hum then
        BX.spoofMoving = false
        -- Leaving an inflated WalkSpeed behind is what voids the next delivery.
        local legal = BX.legalWalkSpeed()
        pcall(function() hum.WalkSpeed = math.max(legal, 16) end)
    end
    if hum then
        hum.PlatformStand = wasPS
        local st = hum:GetState()
        if st == Enum.HumanoidStateType.Freefall
           or st == Enum.HumanoidStateType.PlatformStanding
           or st == Enum.HumanoidStateType.Physics then
            pcall(function() hum:ChangeState(Enum.HumanoidStateType.Landed) end)
        end
    end
    hz = getHRP()
    if hz then
        hz.AssemblyLinearVelocity = Vector3.zero
        hz.AssemblyAngularVelocity = Vector3.zero
    end
    -- TUNE THE UNSPOOFED SPEED ON THE WAY OUT.
    --
    -- Judged on Relocates, not on lost eggs: this leg is empty-handed.
    if BX.noSpoofLegSpeed then
        -- BISECT, DO NOT CRAWL.
        --
        -- A 100-a-leg climb takes eight trips to reach parity with a spoofed
        -- client, which is minutes of being slower for no reason. Bracket it
        -- instead: double toward the spoofed speed while legs come back clean,
        -- and halve the gap once the server pushes back. Converges in about
        -- three legs either way.
        local used = BX.noSpoofLegSpeed or K.ARC_SPEED_NOSPOOF
        local hadRelocs = (BX.relocates or 0) > (BX.noSpoofLegRelocs or 0)

        if hadRelocs then
            BX.noSpoofHigh = used                     -- this speed is too fast
        else
            BX.noSpoofLow = math.max(BX.noSpoofLow or K.ARC_SPEED_NOSPOOF, used)
        end

        local low = BX.noSpoofLow or K.ARC_SPEED_NOSPOOF
        local nextSpeed
        if BX.noSpoofHigh then
            if (BX.noSpoofHigh - low) <= K.NOSPOOF_CONVERGE then
                nextSpeed = low                       -- settled at the safe max
            else
                nextSpeed = math.floor((low + BX.noSpoofHigh) / 2)
            end
        else
            nextSpeed = math.min(K.ARC_SPEED, low * 2)
        end

        nextSpeed = math.clamp(nextSpeed, K.NOSPOOF_FLOOR, K.ARC_SPEED)
        if nextSpeed ~= (BX.noSpoofSpeed or K.ARC_SPEED_NOSPOOF) then
            trace(("travel: %s at %d - next leg %d studs/s (bracket %d..%s)")
                :format(hadRelocs and "relocated" or "clean", used, nextSpeed,
                        low, tostring(BX.noSpoofHigh or "-")))
        end
        BX.noSpoofSpeed = nextSpeed
        BX.noSpoofLegSpeed = nil
    end

    local gap = hz and Vector3.new(pos.X - hz.Position.X, 0, pos.Z - hz.Position.Z).Magnitude or 9999
    trace(("arc: %s %.0f studs in %.2fs (cruise %.0f, up %.0f) -> %.1f short")
        :format(tostring(tag or "leg"), flatTotal, os.clock() - t0, speed,
                cruiseY - start.Y, gap))
    return ok or gap <= arrive + 4
end

-- Straight down onto the ground where we are standing. This is the last step
-- of the cycle: over the middle of the pen, then drop to ground level.
function BX.arcDescend(tag)
    local char, h = getChar(), getHRP()
    if not char or not h then return false end
    local hum = getHumanoid()
    local gy = solidGroundY(h.Position)
    if not gy then
        -- Nothing under us to land on: let physics have it back and fall.
        if hum then hum.PlatformStand = false end
        return false
    end
    local x, z = h.Position.X, h.Position.Z
    local from = h.Position.Y
    if from - gy <= 2 then
        if hum then hum.PlatformStand = false end
        return true
    end

    if hum then hum.PlatformStand = true end
    local t0 = os.clock()
    local dur = math.clamp((from - gy) / math.max(K.ARC_DROP_SPEED, 50), 0.05, 1.2)
    while os.clock() - t0 < dur do
        local f = (os.clock() - t0) / dur
        local y = from + (gy - from) * f
        local hh = getHRP()
        if not hh then break end
        pcall(function()
            char:PivotTo(CFrame.new(x, y, z) * (hh.CFrame - hh.CFrame.Position))
            hh.AssemblyLinearVelocity = Vector3.zero
        end)
        RunService.Heartbeat:Wait()
    end
    pcall(function() char:PivotTo(CFrame.new(x, gy, z)) end)
    if hum then
        hum.PlatformStand = false
        hum:ChangeState(Enum.HumanoidStateType.Landed)
    end
    trace(("arc: %s descended %.0f studs to ground"):format(tostring(tag or "land"), from - gy))
    return true
end
K.ARC_DROP_SPEED = 400

---------- RIDE THE GUARD ----------
--
-- Read off the newer reference clip, frame by frame. At 9.8s the target is
-- "TRex - Secret - 21.24M" and the player is stood on desert sand. At 10.2s
-- them - desert at 10.2s, volcano at 11.6s, snow at 12.4s - with the game's
-- in hand. At 15.2s they are back in the green start area banking it.
-- Why this survives the teleport patch, and why it is not a trick at all:
-- Measured from the live game: each area's guard is


-- The guard for an area: the live one if it has spawned, else the authored one.

-- =====================================================================
-- HOVER WALK - the movement the working reference actually uses.
-- So: WalkSpeed raised, HipHeight raised, and then ordinary walking.
-- WHY THIS BEATS THE ANTICHEAT WHERE EVERYTHING ELSE FAILED. The legality
-- budget, decompiled from the game's own ObbyAntiTPClient, is
--     allowed = WalkSpeed * 1.7 * dt + 14 + velocity * dt
-- the character faster than the budget and hoped:
--   - CFrame tween: velocity term is zero, always over budget -> egg taken
K.HOVER_WALKSPEED = 300
K.HOVER_HIP_HEIGHT = 5     -- studs of float; the shadow gap in the reference
-- ARRIVE TIGHT. This was 8, and 8 is useless: the server wants us inside about
-- 4 studs of the egg record and answers anything further with "Get closer to
-- the egg". Measured, the run this was cut for:
--   11.45 hover: outbound into nest 37 studs -> 5.5 short
--   13.22 hover: outbound 48 studs -> 5.0 short      (retry 1)
--   14.86 hover: outbound 21 studs -> 5.5 short      (retry 2)
--   15.12 carry: fired prompt at 8.1 studs ... Slot  (x3)
K.HOVER_ARRIVE = 2.5
K.HOVER_TIMEOUT = 14
-- Braking. A humanoid at 400 studs/s cannot stop inside 2.5 studs - it sails
-- past and the router calls it a stall, which is the other half of "it moved
-- too far". Inside this radius the held WalkSpeed is scaled down towards
K.HOVER_BRAKE_DIST = 90
K.HOVER_BRAKE_MIN = 55
-- How far short of the target the fast corridor leg aims.
--
-- Was 160, sized against an 81-stud overshoot measured at cruise 400. Overshoot
-- does not scale linearly - at cruise 800 it measured 285:
--   then "carry home into nest 192 studs" walking back EAST to the plot
-- That recovery is ~1.5s of a window that only lasts ~3.8s, which is most of
-- the reason we never get inside the plot while still holding the egg.
-- Precise legs also get their own speed ceiling. A humanoid at WalkSpeed 800
K.HOVER_PRECISE_CRUISE = 250

-- INSPECTED IN THE LIVE CLIENT, and it settles what has been guesswork:
--
--   TreadmillUtil.ResolveFinalWalkSpeed(stat)  = 205.5   <- what we are entitled to
--   TreadmillUtil.WalkSpeedToSpeedPower(206)   = 515,259,670   (matches the stat)
--   TreadmillUtil.WalkSpeedToSpeedPower(400)   = 421,789,332,274
--   TreadmillUtil.WalkSpeedToSpeedPower(800)   = 421,789,332,274  (saturated)
-- Running WalkSpeed 400-800 presents a speed power ~846x the one the account
-- server code. It is why the delivery kept being voided and the egg walked
-- CACHED, BECAUSE THIS RUNS EVERY FRAME.
--
-- BX.speedHoldConn is a Heartbeat handler and it calls this on every frame the
-- hold is active - which is the whole of every travel leg. Each call was a
-- pcall around a freshly created closure, a require, two FindFirstChild and a
-- pair of logarithms inside ResolveFinalWalkSpeed.
--
-- Measured on this client: 0.0142ms a call, so 0.85ms of every second at
-- 60fps, plus 3.7KB/s of garbage from the closure - during travel, which is
-- exactly when frames matter.
--
-- The Speed leaderstat moves on the scale of minutes. Half a second of cache
-- is invisible to behaviour and removes the whole cost.
function BX.legalWalkSpeed()
    local now = os.clock()
    if BX.lwsValue and (now - (BX.lwsAt or 0)) < 0.5 then
        return BX.lwsValue
    end
    local result = BX.legalWalkSpeedUncached()
    BX.lwsValue, BX.lwsAt = result, now
    return result
end

function BX.legalWalkSpeedUncached()
    local ok, v = pcall(function()
        local TU = require(RS.Shared.Util.TreadmillUtil)
        local lp = LocalPlayer
        local ls = lp:FindFirstChild("leaderstats")
        local sp = ls and ls:FindFirstChild("Speed")
        if sp and tonumber(sp.Value) then
            return math.min(TU.ResolveFinalWalkSpeed(tonumber(sp.Value)), TU.MAX_WALK_SPEED)
        end
        return nil
    end)
    if ok and type(v) == "number" and v > 0 then
        -- Take whatever the SERVER has actually set if it is higher.
        --
        -- WalkSpeedGovernor computes WalkSpeed as
        -- ResolveFinalWalkSpeed, which only produces the base. So an active
        -- ...but read that boost off the SERVER'S OWN number, never off the
        --     local live = hum and hum.WalkSpeed or 0
        --     ResolveFinalWalkSpeed(stat) = 206.796
        --     Humanoid.WalkSpeed          = 675      <- left by the outbound leg
        local srv = BX.serverWalkSpeed
        if type(srv) == "number" and srv > K.WALKSPEED_SANE_MIN then
            return srv
        end
        return v
    end
    return BX.serverWalkSpeed or 205
end

---------- UGI CHECK BYPASS (REMOVED) ----------

-- This section used to locate UGI's WCall wrapper on the heap and hook it so
-- the game's own speed checks quietly failed to run, after which a client
-- Humanoid.WalkSpeed write would stick. It was the engine behind the Walk
BX.bypassActive = false

-- The one place that answers "what speed are we allowed to move at". With the
-- walkspeed feature removed there is only ever one answer: the server's.
function BX.targetWalkSpeed()
    return BX.legalWalkSpeed()
end

function BX.startSpeedHold(ws, hip)
    if ws == false then
        ws = nil          -- hold height only; never touch WalkSpeed
    else
        ws = ws or K.HOVER_WALKSPEED
    end
    hip = hip or K.HOVER_HIP_HEIGHT
    BX.hoverWS, BX.hoverHip = ws, hip
    if BX.speedHoldConn then return end
    BX.speedHoldBase = nil
    BX.speedHoldConn = RunService.Heartbeat:Connect(function()
        local ch = getChar()
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if not hum then return end
        if BX.speedHoldBase == nil then BX.speedHoldBase = hum.HipHeight end
        -- Re-assert every frame. The governor overwrites roughly 1/s, and a
        -- single overwritten frame at this speed is a stall the router then
        -- BX.hoverWS == nil means "do not raise WalkSpeed" - the carry leg,
        -- where an over-cap WalkSpeed is what voids the delivery.
        -- But it must not leave it STRANDED either. The precise-arrival hold
        -- writes WalkSpeed 16 to plant the feet on the egg; when the carry then
        -- switched to hold-height-only, nothing wrote WalkSpeed again and the
        -- character crawled the whole way home at 16 studs/s. Measured live:
        if BX.hoverWS then
            if hum.WalkSpeed ~= BX.hoverWS then hum.WalkSpeed = BX.hoverWS end
        else
            local legal = BX.legalWalkSpeed()
            if hum.WalkSpeed < legal - 1 then hum.WalkSpeed = legal end
        end
        local wantHip = (BX.speedHoldBase or 2) + BX.hoverHip
        if hum.HipHeight ~= wantHip then hum.HipHeight = wantHip end
    end)
    trace(("hover: speed hold ON (WalkSpeed=%d hip=+%d)"):format(ws, hip))
end

function BX.stopSpeedHold()
    if BX.speedHoldConn then
        pcall(function() BX.speedHoldConn:Disconnect() end)
        BX.speedHoldConn = nil
    end
    local ch = getChar()
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if hum and BX.speedHoldBase then
        pcall(function() hum.HipHeight = BX.speedHoldBase end)
    end
    -- AND PUT WALKSPEED BACK. This only restored HipHeight, which is how the
    -- character kept ending up stranded: hoverWalkTo parks the hold at 16 on a
    -- and if the hold is stopped at that moment nothing ever writes WalkSpeed
    -- again. That is the "crawls at 16 studs/s for the rest of the session"
    if hum and hum.WalkSpeed < K.WALKSPEED_SANE_MIN then
        local fix = BX.legalWalkSpeed()
        pcall(function() hum.WalkSpeed = fix end)
        trace(("hover: restored WalkSpeed %.0f on hold release"):format(fix))
    end
    BX.speedHoldBase = nil
    BX.hoverWS = nil
    trace("hover: speed hold OFF")
end

-- ARRIVAL SNAP vs BRAKING RAMP.
--
-- capping precise legs at 250, and K.HOVER_APPROACH_MARGIN aiming 400 studs
-- short because at cruise 800 the overshoot measured 285. The lost carries are
-- all the same shape, past the plot rather than short of it: 63, 81, 63 studs.
-- one frame of travel (~5 studs at cruise 300, ~13 at 800) and lands exactly.
-- WHAT DOES NOT WORK, both measured live rather than reasoned about:
--     WalkSpeed 300, PlatformStand false, state Running throughout: the
BX.driveWalk = true

-- Ask for a full stop, right now. Move(zero) clears MoveDirection so the
-- humanoid stops driving itself, and zeroing the assembly velocity removes
-- whatever the physics step had already applied.
function BX.driveStop()
    local hm = getHumanoid()
    local hh = getHRP()
    if hm then
        local hp = getHRP()
        if hp then pcall(function() hm:MoveTo(hp.Position) end) end
        -- Belt and braces. Nothing in the drive path writes WalkSpeed any more,
        -- but this is the one function every leg exits through, so a stranded
        -- value gets caught here rather than on the next carry.
        if hm.WalkSpeed < K.WALKSPEED_SANE_MIN then
            pcall(function() hm.WalkSpeed = BX.legalWalkSpeed() end)
        end
    end
    if hh then
        hh.AssemblyLinearVelocity = Vector3.new(0, hh.AssemblyLinearVelocity.Y, 0)
        hh.AssemblyAngularVelocity = Vector3.zero
    end
end

-- Walk to a point with the humanoid's own pathing. MoveTo is re-issued every
-- frame: Roblox abandons a MoveTo after 8s, and re-issuing also re-aims when
-- (2.5) because the server measures range to the egg record and refuses
-- anything looser. Corridor waypoints do not - braking to a halt on each one
function BX.hoverWalkTo(pos, timeout, tag, arrive)
    local hum = getHumanoid()
    local h = getHRP()
    if not hum or not h or not pos then return false end

    -- REPAIR BEFORE MOVING. WalkSpeed is written by a lot of things here - the
    -- speed hold, the precise-arrival plant, the server's own governor - and a
    if hum.WalkSpeed < K.WALKSPEED_SANE_MIN then
        local fix = BX.legalWalkSpeed()
        trace(("hover: repairing stranded WalkSpeed %.1f -> %.1f"):format(hum.WalkSpeed, fix))
        hum.WalkSpeed = fix
    end

    -- A humanoid left in Physics / PlatformStanding / Seated cannot walk, and
    -- MoveTo into one is a silent no-op: it reports no error and simply never
    do
        local st = hum:GetState()
        if hum.PlatformStand or hum.Sit
           or st == Enum.HumanoidStateType.Physics
           or st == Enum.HumanoidStateType.PlatformStanding
           or st == Enum.HumanoidStateType.Seated then
            trace("hover: humanoid was not in a walking state - restoring")
            pcall(function()
                hum.PlatformStand = false
                hum.Sit = false
                hum.AutoRotate = true
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end)
        end
    end

    local t0 = os.clock()
    local limit = timeout or K.HOVER_TIMEOUT
    local start = h.Position
    local lastPos, stuckFor = start, 0
    -- Seeded at a 60 Hz frame and corrected to the real step each iteration.
    -- Clamped both ways so one hitch cannot make the arrival clamp wild.
    local dt = 1 / 60
    -- Remember the cruise speed so braking can restore it on the way out.
    -- When BX.hoverWS is nil we are deliberately NOT overriding WalkSpeed
    -- (the carry leg), so cruise is whatever the server actually allows us.
    local cruise = BX.hoverWS or BX.legalWalkSpeed()
    -- DO NOT INHERIT THE ARRIVAL PLANT. The precise branch at the end of this
    -- function parks the hold at 16 so the humanoid cannot walk itself off the
    -- ESCAPE leg that follows a successful steal starts at 16 studs/s and the
    -- for this leg. (The plant still works, because it is re-applied after
    if BX.hoverWS and BX.hoverWS < K.WALKSPEED_SANE_MIN then
        cruise = BX.targetWalkSpeed()
        BX.hoverWS = cruise
        trace(("hover: clearing a stale arrival plant, cruise -> %.0f"):format(cruise))
    end
    arrive = arrive or K.HOVER_ARRIVE
    -- BRAKE ON EVERY LEG, and scale the braking distance to how fast we are
    -- actually going. Disabling it on corridor legs was wrong: at 682 studs/s
    -- MoveTo sails ~80 studs past the waypoint, and measured, that overshoot
    --   home 492,-423  drop 429,-386   63 studs west of the plot
    --   home 522,-272  drop 441,-339   81 studs west
    --   home 472,-202  drop 409,-388   63 studs west
    local precise = arrive <= 5
    -- Cap the approach speed on a precise leg so stopping is physically
    -- possible; braking distance alone cannot fix 800 studs/s of momentum.
    local holdsSpeed = (BX.hoverWS ~= nil)
    if precise and not BX.driveWalk then cruise = math.min(cruise, K.HOVER_PRECISE_CRUISE) end
    local brakeDist = math.max(K.HOVER_BRAKE_DIST, cruise * 0.22)
    local brakeMin = precise and K.HOVER_BRAKE_MIN or (cruise * 0.35)

    while os.clock() - t0 < limit do
        local hh = getHRP()
        local hm = getHumanoid()
        if not hh or not hm then break end
        local flat = Vector3.new(pos.X - hh.Position.X, 0, pos.Z - hh.Position.Z)
        local left = flat.Magnitude
        if left <= arrive then break end

        -- Brake into the target. BX.hoverWS is what the speed hold re-asserts
        -- every Heartbeat, so this has to move THAT - writing hum.WalkSpeed
        -- carry leg BX.hoverWS is nil and must stay nil.
        -- The braking ramp exists only because MoveTo cannot stop on a mark.
        if holdsSpeed and not BX.driveWalk then
            if left < brakeDist then
                local t = math.clamp(left / brakeDist, 0, 1)
                BX.hoverWS = math.max(brakeMin, cruise * t)
            elseif BX.hoverWS ~= cruise then
                BX.hoverWS = cruise
            end
        elseif holdsSpeed and BX.hoverWS ~= cruise then
            BX.hoverWS = cruise
        end

        -- MOVETO, NOT MOVE. Measured in the live client, and this is not a
        -- preference - it is the difference between moving and not moving:
        --   at WalkSpeed 300, PlatformStand false, state Running the whole
        --   time, moved the character 0.0 studs. Raw velocity writes from the
        --   same spot moved it 135 studs.
        hm:MoveTo(Vector3.new(pos.X, hh.Position.Y, pos.Z))

        -- STOP DEAD ON THE MARK, WITHOUT SLOWING DOWN FIRST.
        --
        -- The correction is bounded by one frame of travel - about 5 studs at
        if BX.driveWalk and left > 0 and left <= K.SNAP_MAX_JUMP
           and (hm.WalkSpeed * dt) >= left then
            local dest = Vector3.new(pos.X, hh.Position.Y, pos.Z)
            hh.CFrame = CFrame.new(dest) * hh.CFrame.Rotation
            -- Keep the vertical component: this must not cancel gravity or a
            -- fall already in progress.
            hh.AssemblyLinearVelocity = Vector3.new(0, hh.AssemblyLinearVelocity.Y, 0)
            hh.AssemblyAngularVelocity = Vector3.zero
            hm:MoveTo(hh.Position)
            break
        end

        -- Stall detector: walking can be blocked by geometry the router did
        -- not know about, and burning the whole timeout in place is the
        -- failure mode this whole file keeps rediscovering.
        local moved = (hh.Position - lastPos).Magnitude
        lastPos = hh.Position
        stuckFor = (moved < 0.5) and (stuckFor + 1) or 0
        if stuckFor > 90 then
            trace(("hover[%s]: stalled %.0f studs from target"):format(
                tostring(tag or "leg"), flat.Magnitude))
            break
        end
        dt = math.clamp(RunService.Heartbeat:Wait(), 1 / 240, 0.1)
    end

    -- Stop driving the moment the loop ends, however it ended - arrival,
    -- timeout or stall. Without this the last MoveDirection stays asserted and
    -- the character keeps walking away from the mark it just hit.
    if BX.driveWalk then pcall(BX.driveStop) end

    -- PLANT THE FEET ON ARRIVAL.
    --
    -- sliding while the carry attempts run. Measured, the run this was cut for:
    --   13.58 hover: outbound into nest 189 studs -> 2.2 short
    --   13.84 carry: fired prompt at 3.2 studs
    --   14.01 carry: fired prompt at 3.0 studs
    --   14.19 carry: fired prompt at 4.6 studs     <- drifting outward
    -- 2.8 studs is accepted and 3.0 is refused, so drifting even one stud is
    if precise then
        local hs = getHRP()
        local hmS = getHumanoid()
        if hs then
            hs.AssemblyLinearVelocity = Vector3.zero
            hs.AssemblyAngularVelocity = Vector3.zero
        end
        if hmS and hs then hmS:MoveTo(hs.Position) end
        -- Low hold speed so the humanoid does not walk itself off the mark
        -- while the carry remote and the prompt are being tried.
        if holdsSpeed then BX.hoverWS = 16 end

        -- AND COME BACK DOWN. This is the actual reason the steal was being
        -- refused at the nest.
        --   13.58 hover: outbound into nest 189 studs -> 2.2 short
        --   13.84 carry: fired prompt at 3.2 studs
        BX.hoverHip = 0
        local settle = os.clock()
        while os.clock() - settle < 0.18 do RunService.Heartbeat:Wait() end
        local hs2 = getHRP()
        if hs2 then hs2.AssemblyLinearVelocity = Vector3.zero end
    elseif holdsSpeed then
        BX.hoverWS = cruise
    end

    local h2 = getHRP()
    local left = h2 and Vector3.new(pos.X - h2.Position.X, 0, pos.Z - h2.Position.Z).Magnitude or 9999
    local dt = os.clock() - t0
    local travelled = h2 and (h2.Position - start).Magnitude or 0
    trace(("hover: %s %.0f studs in %.2fs (%.0f studs/s) -> %.1f short"):format(
        tostring(tag or "leg"), travelled, dt, travelled / math.max(dt, 0.001), left))
    return left <= arrive
end

-- Same corridor routing the fly path uses: onto the middle lane, along it, then
-- sideways into the target. Walking a straight diagonal puts us against a wall
-- The detector does not care about WalkSpeed. It cares that POSITION MATCHES
-- budget, which credits the velocity term:
-- At 380 studs/s with a legal ws=205 and dt=0.11: moved 42, allowed
-- 38.3 + 14 + 42 = 94. Inside, because the velocity creating the distance is
-- WHY THIS IS NOT THE OLD flyTo. That ran at 960-1200 with WalkSpeed inflated
-- to 400-800 and PlatformStand on (which is why the character went prone and
K.VEL_CARRY_SPEED = 900
-- Longest carry that has ever survived a FAST delivery. Desert is 414 studs and
-- delivered at ~400 studs/s; Jungle is 636 and never has. 450 sits between the
--   426 studs, commanded 500 -> "DELIVERED - server claimed the egg"
--  2285 studs, commanded 900 -> "Delivery failed! The egg was returned"
--  2290 studs, commanded 500 -> "Delivery failed! The egg was returned"
-- The SAME commanded speed delivers at 426 studs and is voided at 2290, so
-- (~205 studs/s) and its own failure mode is being caught by a guard, but it
K.FAST_CARRY_MAX_DIST = 450
-- Held WalkSpeed for the LONG carry, where velocity writes get the delivery
-- voided. 300 is TreadmillUtil.MAX_WALK_SPEED - the game's own ceiling, and a
-- third without presenting a rate the WalkSpeed cannot explain. Drop it to
-- BX.legalWalkSpeed() (~205) if long deliveries start being refused again.
-- TIME IS THE BUDGET, NOT SPEED. Every accepted delivery took 1.32s; every
-- refusal took 2.97s or more, at 205, at 500 and at 900, by velocity and by
-- 11.43s in the air and refused like all the rest. So the carry runs fast and
-- Furthest egg worth taking. 426 studs delivered; 2269+ never has. Sized with
-- The deliverable budget, from this script's own logs rather than a guess.
-- A 3512-stud carry from Cherry Blossom banked cleanly ("arc: carry home 3512
-- studs in 7.40s" then DELIVERED), so 700 was far too pessimistic and would
-- have limited us to the first three areas. 3600 keeps the far end reachable
-- while still sorting anything beyond it below the eggs we know we can bank.
-- How long a cached ProximityPrompt list stays good. They do not move; this
-- only needs to be short enough to pick up newly streamed areas.
K.PROMPT_CACHE = 3
-- How close a pooled prompt must be to the target egg to count as ITS prompt.
K.PROMPT_NEAR = 12
-- How long to let the game hand a prompt to the egg we just arrived at.
K.PROMPT_WAIT = 0.6

-- GuardChasePolicy.ResolveWalkSpeed tops out at base * this.
K.GUARD_CHASE_MULT = 4

K.CARRY_MAX_DIST = 3600
K.VEL_ARRIVE = 3
-- Largest gap the arrival snap may close with a CFrame write. Anything bigger
-- than this is a teleport, not a rounding correction - see the note at the
-- snap itself. One frame at 500 studs/s is ~8 studs, so this is about the
K.SNAP_MAX_JUMP = 8
K.VEL_TIMEOUT = 16

function BX.velocityCarryTo(pos, timeout, tag, arrive, speed)
    local h = getHRP()
    local hum = getHumanoid()
    if not h or not hum or not pos then return false end
    arrive = arrive or K.VEL_ARRIVE

    local t0 = os.clock()
    local limit = timeout or K.VEL_TIMEOUT
    local start = h.Position
    local lastPos, stuckFor = start, 0
    local legal = BX.legalWalkSpeed()
    -- Previous frame's duration, used to predict the next one. Seeded at
    -- 60 Hz and clamped so a hitch cannot make the arrival test wild.
    local dt = 1 / 60

    while os.clock() - t0 < limit do
        local hh, hm = getHRP(), getHumanoid()
        if not hh or not hm then break end
        local flat = Vector3.new(pos.X - hh.Position.X, 0, pos.Z - hh.Position.Z)
        local left = flat.Magnitude
        if left <= arrive then break end

        -- NO EASING. This used to ramp down inside K.VEL_BRAKE_DIST and then
        -- cap at left/0.06, and that is exactly the "slows down before it
        -- stops" behaviour: measured, the final leg crawled in at 185 studs/s
        local want = speed or K.VEL_CARRY_SPEED

        -- STOP DEAD. Once the next frame's travel would reach or pass the
        -- target, put us exactly on it and stop. The correction is bounded by
        -- one frame (~8 studs at 500, ~15 at 900), so it is small, and it
        -- BOUNDED. The snap must never be a visible jump: measured at a flat
        -- 900, it fired with 29 studs left and produced
        --   "vel: carry home onto middle 29 studs in 0.01s (2635 studs/s)"
        if left > 0 and left <= K.SNAP_MAX_JUMP and want * dt >= left then
            hh.CFrame = CFrame.new(Vector3.new(pos.X, hh.Position.Y, pos.Z))
                * hh.CFrame.Rotation
            hh.AssemblyLinearVelocity = Vector3.new(0, hh.AssemblyLinearVelocity.Y, 0)
            hh.AssemblyAngularVelocity = Vector3.zero
            break
        end

        -- VELOCITY ONLY - no MoveTo.
        --
        -- Those fight: the humanoid's own controller damps toward WalkSpeed
        -- ownership of its own character), unlike CFrame and WalkSpeed which
        local dir = flat.Unit
        hh.AssemblyLinearVelocity = Vector3.new(
            dir.X * want,
            hh.AssemblyLinearVelocity.Y,
            dir.Z * want
        )

        local moved = (hh.Position - lastPos).Magnitude
        lastPos = hh.Position
        stuckFor = (moved < 0.5) and (stuckFor + 1) or 0
        if stuckFor > 60 then
            trace(("vel[%s]: stalled %.0f studs from target"):format(tostring(tag or "leg"), left))
            break
        end
        dt = math.clamp(RunService.Heartbeat:Wait(), 1 / 240, 0.1)
    end

    -- Come to rest under our own power, not by teleporting to a stop.
    local hs = getHRP()
    if hs then
        hs.AssemblyLinearVelocity = Vector3.new(0, hs.AssemblyLinearVelocity.Y, 0)
    end

    local h2 = getHRP()
    local leftEnd = h2 and Vector3.new(pos.X - h2.Position.X, 0, pos.Z - h2.Position.Z).Magnitude or 9999
    local dt = os.clock() - t0
    local travelled = h2 and (h2.Position - start).Magnitude or 0
    trace(("vel: %s %.0f studs in %.2fs (%.0f studs/s) -> %.1f short"):format(
        tostring(tag or "leg"), travelled, dt, travelled / math.max(dt, 0.001), leftEnd))
    return leftEnd <= arrive
end


function BX.findAreaGuard(areaId)
    if not areaId then return nil end
    local live = workspace:FindFirstChild("_Guards")
    if live then
        for _, g in ipairs(live:GetChildren()) do
            if g.Name == areaId or g:GetAttribute("AreaId") == areaId then return g end
        end
    end
    local ok, a = pcall(function()
        return workspace.__OBJECTS.Areas.GuardAreas[areaId]
    end)
    if ok and a then return a:FindFirstChild("Guard") end
    return nil
end


-- The part to ride. Any big body part will do now that we attach rather than
-- stand, so CanCollide is irrelevant - prefer the guard's root, then the
-- biggest part in the rig.
function BX.guardAnchorPart(guard)
    if not guard then return nil end
    local root = guard:FindFirstChild("HumanoidRootPart")
        or guard:FindFirstChild("Collider")
        or guard:FindFirstChild("Head")
    if root and root:IsA("BasePart") then return root end
    local best
    for _, d in ipairs(guard:GetDescendants()) do
        if d:IsA("BasePart") then
            local v = d.Size.X * d.Size.Y * d.Size.Z
            if not best or v > best.v then best = { p = d, v = v } end
        end
    end
    return best and best.p or nil
end

function BX.tpTo(pos, tag)
    local char = getChar()
    local h = getHRP()
    if not char or not h then return false end
    local gy = solidGroundY(pos)
    local dest = Vector3.new(pos.X, gy or pos.Y, pos.Z)
    local ok = pcall(function() char:PivotTo(CFrame.new(dest)) end)
    if ok then
        h.AssemblyLinearVelocity = Vector3.zero
        h.AssemblyAngularVelocity = Vector3.zero
    end
    trace(("tp: %s -> %.0f,%.0f,%.0f (%.0f studs, PivotTo)")
        :format(tostring(tag), dest.X, dest.Y, dest.Z, (dest - h.Position).Magnitude))
    return ok
end

---------- SAFE-ZONE ANCHOR ----------
--
-- Read off the reference clip frame by frame (7.7s, four consecutive steals):
-- drawn. Four times, one press each, no second attempt, and the base is never
-- the server never accepts the outbound teleport to begin with. Our own trace
-- while the client heartbeat still read x=3385. Server-side we never left the

function BX.inSafeZone(pos)
    if not pos then return false end
    return pos.X <= K.SAFE_ZONE_X_MAX
        and pos.Z >= K.SAFE_ZONE_Z_MIN
        and pos.Z <= K.SAFE_ZONE_Z_MAX
end

function BX.captureSafeAnchor(tag, force)
    local h = getHRP()
    if not h then return false end
    local p = h.Position
    if not force and not BX.inSafeZone(p) then return false end
    BX.tpAnchorCF = CFrame.new(p.X, p.Y, p.Z)
    BX.tpAnchorAt = os.clock()
    trace(("anchor: safe spot from %s -> %.0f,%.0f,%.0f (in zone=%s)")
        :format(tostring(tag), p.X, p.Y, p.Z, tostring(BX.inSafeZone(p))))
    return true
end

-- Anchor first. Failing that, a point on the line at our current Z - the
-- shortest crossing available, which is what the old code computed and is
-- still the right guess when we have never stood in the zone this session.
function BX.safeReturnCF()
    -- An anchor from a different server, or one captured while we were
    -- standing somewhere that turned out not to be the doorway band, is worse
    -- than the computed point - so it has to still pass the box test.
    if BX.tpAnchorCF and BX.inSafeZone(BX.tpAnchorCF.Position) then
        return BX.tpAnchorCF, "anchor"
    end
    if BX.tpAnchorCF then
        trace("anchor: discarding a safe spot that is no longer inside the doorway band")
        BX.tpAnchorCF = nil
    end
    local h = getHRP()
    local z = math.clamp((h and h.Position.Z) or K.SAFE_FALLBACK_Z,
        K.SAFE_ZONE_Z_MIN + 8, K.SAFE_ZONE_Z_MAX - 8)
    -- solidGroundY already adds GROUND_OFFSET, so this is a standing height.
    local y = solidGroundY(Vector3.new(K.SAFE_EDGE_X, K.SAFE_STAND_Y, z))
        or K.SAFE_STAND_Y
    return CFrame.new(K.SAFE_EDGE_X, y, z), "line"
end

---------- DELIVERY FORENSICS ----------
--
-- WHY THIS EXISTS. Eight different theories have been tried against
-- rate/velocity consistency, the plot vs the safe zone, the WalkSpeedGovernor,
K.DIAG_KEEP = 120
K.DIAG_MUTE = {
    ["RE/PenRoster/CoinsGathered"] = true,
    ["RE/ProfileMirror/ProfileDelta"] = true,
    ["RE/SoundBus/Play"] = true,
    ["RE/Telemetry/Report"] = true,
}

BX.diag = { events = {}, n = 0 }

local function diagPush(kind, name, payload)
    local d = BX.diag
    d.n = d.n + 1
    d.events[(d.n - 1) % K.DIAG_KEEP + 1] = {
        t = os.clock(), kind = kind, name = name, payload = payload,
    }
end

-- Compact, bounded stringify. Remote payloads are game data and can be deep;
-- printing them raw is how a trace becomes unreadable.
function BX.diagDump(v, depth)
    depth = depth or 0
    local tv = typeof(v)
    if tv == "table" then
        if depth >= 3 then return "{...}" end
        local parts, count = {}, 0
        for k, val in pairs(v) do
            count = count + 1
            if count > 12 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(k) .. "=" .. BX.diagDump(val, depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif tv == "Instance" then
        return v.ClassName .. ":" .. v.Name
    elseif tv == "Vector3" then
        return ("(%.0f,%.0f,%.0f)"):format(v.X, v.Y, v.Z)
    elseif tv == "CFrame" then
        return ("CF(%.0f,%.0f,%.0f)"):format(v.Position.X, v.Position.Y, v.Position.Z)
    elseif tv == "string" then
        return #v > 120 and (v:sub(1, 120) .. "...") or v
    end
    return tostring(v)
end

-- Snapshot of what the anticheat currently believes about us. This is the
-- half we have never actually looked at when a delivery was refused.
function BX.diagAcSnapshot()
    local st = BX.acState
    if type(st) ~= "table" then return "acState=<not found>" end
    local ok, out = pcall(function()
        local ev = rawget(st, "Evidence") or {}
        local last = rawget(st, "LastSample")
        return ("acState threat=%s supported=%s locked=%s evidence{speed=%s tp=%s fly=%s} lastSample=%s")
            :format(
                tostring(rawget(st, "ThreatLevel")),
                tostring(rawget(st, "IsSupportedNow")),
                tostring(rawget(st, "ValidationLocked")),
                tostring(ev.Speed), tostring(ev.Teleport), tostring(ev.Flight),
                type(last) == "table"
                    and ("{ws=%s pos=%s}"):format(tostring(last.WalkSpeed),
                        BX.diagDump(last.Position))
                    or "nil")
    end)
    return ok and out or "acState=<read failed>"
end

-- Print the recorded window, oldest first, with times relative to now.
function BX.diagFlush(reason)
    local d = BX.diag
    if d.n == 0 then return end
    trace("=== DELIVERY FORENSICS (" .. tostring(reason) .. ") ===")

    pcall(function()
        local h = getHRP()
        local sl = workspace:FindFirstChildOfClass("SpawnLocation")
        local pos = h and h.Position
        local dSpawn = (pos and sl) and (Vector3.new(pos.X - sl.Position.X, 0,
                                        pos.Z - sl.Position.Z).Magnitude) or -1
        local home = BX.homePos and select(1, pcall(BX.homePos)) and BX.homePos() or nil
        local dHome = (pos and typeof(home) == "Vector3")
            and Vector3.new(pos.X - home.X, 0, pos.Z - home.Z).Magnitude or -1
        trace(("WHERE: pos %s | %.0f studs from SpawnLocation | %.0f from home | inZone=%s | carrying=%s | %.2fs since steal")
            :format(
                pos and ("%.0f,%.0f,%.0f"):format(pos.X, pos.Y, pos.Z) or "?",
                dSpawn, dHome,
                tostring(pos and BX.inSafeZone and BX.inSafeZone(pos)),
                tostring(heldEggUid ~= nil),
                os.clock() - (BX.carryStartedAt or os.clock())))
    end)

    trace(BX.diagAcSnapshot())
    local now = os.clock()
    local first = math.max(1, d.n - K.DIAG_KEEP + 1)
    for i = first, d.n do
        local e = d.events[(i - 1) % K.DIAG_KEEP + 1]
        if e then
            trace((" %+.2fs %s %s %s"):format(e.t - now, e.kind, e.name,
                tostring(e.payload)))
        end
    end
    trace("=== END FORENSICS ===")
    d.events, d.n = {}, 0
end

-- Hook every RemoteEvent/RemoteFunction under the networking folder. Inbound
-- only: we are listening to what the SERVER says, not touching what we send.
function BX.armDiag()
    if BX.diagArmed then return end
    BX.diagArmed = true
    local n = 0
    pcall(function()
        local net = RS.Packages and RS.Packages:FindFirstChild("Networking")
        if not net then return end
        for _, r in ipairs(net:GetChildren()) do
            if r:IsA("RemoteEvent") then
                local nm = r.Name
                BlyxoTop[#BlyxoTop + 1] = r.OnClientEvent:Connect(function(...)
                    -- Only while an egg is in hand, or just after - that is the
                    -- window the verdict lands in.
                    if not heldEggUid and (os.clock() - (BX.lastCarryEndAt or 0)) > 3 then
                        return
                    end
                    if K.DIAG_MUTE[nm] then return end
                    local args = {}
                    for i = 1, select("#", ...) do
                        args[#args + 1] = BX.diagDump((select(i, ...)))
                    end
                    diagPush("RE", nm, table.concat(args, " | "))
                    -- The verdict itself: dump immediately, while the state is
                    -- still what the server just judged.
                    if nm:find("Alert") or nm:find("Verdict") or nm:find("Redeem") then
                        trace(("FORENSICS trigger: %s -> %s"):format(nm, table.concat(args, " | ")))
                        task.defer(BX.diagFlush, nm)
                    end
                end)
                n = n + 1
            end
        end
    end)
    trace(("forensics: armed on %d remotes"):format(n))
end

---------- HOVER PAD (ground support) ----------
--
-- WHY THIS EXISTS, and why the spoof alone was not enough.
-- paper over - and it is why the delivery was still refused with the spoof
K.PAD_NAME = "__BlyxoPad"
K.PAD_SIZE = 8
K.PAD_HEIGHT = 1

BX.pad = nil

function BX.padOffset()
    local hrp = getHRP()
    local hum = getHumanoid()
    if not hrp or not hum then return 3 end
    if hum.RigType == Enum.HumanoidRigType.R15 then
        return hrp.Size.Y * 0.5 + math.max(hum.HipHeight, 0.5)
    end
    return hrp.Size.Y * 0.5 + 2
end

-- WHY JUMPING STOPPED WORKING.
--
-- frame. You never left the ground, so the jump did nothing.
K.PAD_RISE_VY = 3   -- studs/s upward that count as "jumping, not walking"

function BX.updatePad(atPos)
    local p = BX.pad
    if not p or not p.Parent then return false end
    local hrp = getHRP()
    if not hrp then return false end
    local pos = (typeof(atPos) == "Vector3") and atPos or hrp.Position
    local off = BX.padOffset()
    local wantY = pos.Y - off - 0.55

    if not BX.spoofMoving then
        local vy = hrp.AssemblyLinearVelocity.Y
        -- BX.jumping() is in here because the request arrives BEFORE the
        -- velocity does: on the frame you press space vy is still 0, and
        local rising = BX.jumping() or vy > K.PAD_RISE_VY
        local hum = getHumanoid()
        if hum then
            local st = hum:GetState()
            rising = rising or ((st == Enum.HumanoidStateType.Jumping
                or st == Enum.HumanoidStateType.Freefall) and vy > 0)
        end
        -- Rising: leave the pad where it is, so there is something to jump
        -- off and something to land back on. Never raise it, only lower it.
        if rising and BX.padY then
            wantY = math.min(BX.padY, wantY)
        end
    end

    BX.padY = wantY
    p.CFrame = CFrame.new(pos.X, wantY, pos.Z)
    return true
end

function BX.ensurePad()
    if BX.pad and BX.pad.Parent then
        BX.updatePad()
        return BX.pad
    end
    -- Sweep any pad left behind by a previous run before making another.
    for _, c in ipairs(workspace:GetChildren()) do
        if c:IsA("BasePart") and c.Name == K.PAD_NAME then
            pcall(function() c:Destroy() end)
        end
    end
    local p = Instance.new("Part")
    p.Name = K.PAD_NAME
    p.Anchored = true
    p.CanCollide = true      -- must be solid: the support check is a raycast
    p.CanQuery = true        -- and the raycast must be able to see it
    p.CanTouch = false       -- but it should fire no touch events
    p.CastShadow = false
    p.Transparency = 1
    p.Material = Enum.Material.SmoothPlastic
    p.Size = Vector3.new(K.PAD_SIZE, K.PAD_HEIGHT, K.PAD_SIZE)
    p.Parent = workspace
    BX.pad = p
    BX.updatePad()

    if not BX.padConn then
        BX.padConn = RunService.PreSimulation:Connect(function()
            if not BX.updatePad() then BX.ensurePad() end
        end)
    end
    trace("pad: ground support pad created")
    return p
end

function BX.destroyPad()
    if BX.padConn then
        pcall(function() BX.padConn:Disconnect() end)
        BX.padConn = nil
    end
    if BX.pad then
        pcall(function() BX.pad:Destroy() end)
        BX.pad = nil
    end
    for _, c in ipairs(workspace:GetChildren()) do
        if c:IsA("BasePart") and c.Name == K.PAD_NAME then
            pcall(function() c:Destroy() end)
        end
    end
    trace("pad: removed")
end

---------- JUMP KEEPER (idle only) ----------
--
-- pad sweep and the state reset only run while Auto Steal is OFF, because
-- those two ARE things the movers set on purpose, so they must never fight.
-- 0.6s covers a full jump arc at this game's gravity (measured: apex at
-- ~0.25s, back on the floor by ~0.45s).
K.JUMP_WINDOW = 0.6
BX.userJumpUntil = 0

-- True while the player's own jump owns the vertical axis.
function BX.jumping()
    return os.clock() < (BX.userJumpUntil or 0)
end

-- WHY YOU COULD NOT JUMP AFTER AUTO STEAL.
--
-- Auto Steal swaps the Humanoid for a clone (BX.swapHumanoid) and destroys the
-- original. Walking survives that - Player:Move finds whatever humanoid the
-- character has - but Roblox's ControlModule keeps the humanoid it found at
-- spawn and writes `Jump = true` into THAT one. After the swap it is writing
-- into a destroyed object, so the space bar, the mobile jump button and the
-- gamepad all do nothing, until you respawn.
--
-- Two fixes, so it holds on every device - and BOTH ONLY WITH AUTO STEAL OFF.
-- During a steal the controls are left exactly as they always were, so the
-- movers see no difference. Switching Auto Steal off re-points the
-- ControlModule at the live humanoid (BX.repointControls), and while idle
-- every jump request - JumpRequest fires for keyboard, touch and gamepad
-- alike - is also handed straight to the live humanoid.
function BX.repointControls(hum)
    pcall(function()
        local pm = LocalPlayer:FindFirstChild("PlayerScripts")
            and LocalPlayer.PlayerScripts:FindFirstChild("PlayerModule")
        if not pm then return end
        local controls = require(pm):GetControls()
        if controls and hum and controls.humanoid ~= hum then
            controls.humanoid = hum
            trace("jump: controls re-pointed at the live humanoid")
        end
    end)
end

pcall(function()
    BlyxoTop.jump = UserInputService.JumpRequest:Connect(function()
        BX.userJumpUntil = os.clock() + K.JUMP_WINDOW
        if stealing then return end
        local hum = getHumanoid()
        if hum and hum.Health > 0 and hum:GetAttribute(BX.SWAP_ATTR) == true then
            local st = hum:GetState()
            if st ~= Enum.HumanoidStateType.Jumping and st ~= Enum.HumanoidStateType.Freefall then
                hum.Jump = true
            end
        end
    end)
end)

K.JUMP_KEEP_INTERVAL = 0.4
K.JUMP_HEIGHT_MIN = 0.5
K.JUMP_HEIGHT_DEFAULT = 7.2
K.JUMP_POWER_DEFAULT = 50

BX.jumpBaseHeight = nil
BX.jumpBasePower = nil

function BX.jumpKeep(idle)
    local ch = getChar()
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if not hum or not hrp or hum.Health <= 0 then return end

    -- Remember the account's real values while they are still good, exactly
    -- like the reference does: only sane readings are ever recorded, so a
    -- trap that already zeroed the property cannot poison the baseline.
    if type(hum.JumpHeight) == "number" and hum.JumpHeight > K.JUMP_HEIGHT_MIN then
        BX.jumpBaseHeight = hum.JumpHeight
    end
    if type(hum.JumpPower) == "number" and hum.JumpPower > 1 then
        BX.jumpBasePower = hum.JumpPower
    end

    if type(hum.JumpHeight) == "number" and hum.JumpHeight < K.JUMP_HEIGHT_MIN then
        hum.JumpHeight = BX.jumpBaseHeight or K.JUMP_HEIGHT_DEFAULT
        trace(("jumpkeep: JumpHeight was 0, restored to %.1f"):format(hum.JumpHeight))
    end
    if type(hum.JumpPower) == "number" and hum.JumpPower < 1 then
        hum.JumpPower = BX.jumpBasePower or K.JUMP_POWER_DEFAULT
        trace(("jumpkeep: JumpPower was 0, restored to %.0f"):format(hum.JumpPower))
    end
    if not idle then return end

    -- 1. Sweep any pad the loop did not clean up. Nothing should be holding
    -- ground support open with the script idle.
    if BX.pad or BX.padConn then
        pcall(BX.destroyPad)
        trace("jumpkeep: removed a hover pad left behind by a previous run")
    else
        -- FindFirstChild, not a full walk of workspace. This ran every
        -- K.JUMP_KEEP_INTERVAL and workspace here has hundreds of children.
        local stray = workspace:FindFirstChild(K.PAD_NAME)
        if stray and stray:IsA("BasePart") then
            pcall(function() stray:Destroy() end)
            trace("jumpkeep: swept an orphaned hover pad")
        end
    end

    -- 3. Hand the humanoid back able to move. Anchored roots and a parked
    -- state are the other two ways a cancelled leg leaves you stuck.
    if hrp.Anchored then
        hrp.Anchored = false
        trace("jumpkeep: root was anchored, released")
    end
    if hum.PlatformStand or hum.Sit then
        hum.PlatformStand = false
        hum.Sit = false
    end
    local st = hum:GetState()
    if st == Enum.HumanoidStateType.Physics
       or st == Enum.HumanoidStateType.PlatformStanding
       or st == Enum.HumanoidStateType.Seated then
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
    end
    -- The steal legs disable these to stop the humanoid fighting a CFrame
    -- write; with the loop off they are the reason a jump never leaves the
    -- ground even with a normal JumpHeight.
    if not hum:GetStateEnabled(Enum.HumanoidStateType.Jumping) then
        hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
    end
    if not hum:GetStateEnabled(Enum.HumanoidStateType.Freefall) then
        hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
    end
    if not hum:GetStateEnabled(Enum.HumanoidStateType.Landed) then
        hum:SetStateEnabled(Enum.HumanoidStateType.Landed, true)
    end
end

task.spawn(function()
    local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
    while true do
        if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
        task.wait(K.JUMP_KEEP_INTERVAL)
        -- ONLY WHILE IDLE. Every one of the writes above is something a steal
        -- leg does on purpose while it is running.
        -- state reset only happen while idle, because those are things a
        pcall(BX.jumpKeep, not stealing)
    end
end)

---------- ANTICHEAT NEUTRALISER (ported from the working hub) ----------
--
-- WHY THIS REPLACES THE PREVIOUS SPOOF. The earlier version found the state
-- and it did not hold: a carry that ended 20 studs from SpawnLocation, well
-- inside the safe band, was still voided - on the run that logged 13 relocates
-- and a 16320 studs/s frame. Position was never the problem; the movement was.
--      "Authoritative WalkSpeed", ...), and harvests their upvalues. Cheap,
--      studs, puts us straight back. That is what a relocate actually is, and
K.AC_CONST_MARKS = {
    "VerticalTrajectory", "CorrectionContext", "PivotTo", "Relocate",
    "Authoritative WalkSpeed", "BeginImpulse", "LastValidatedGroundedSample",
}
K.AC_SAMPLE_FIELDS = {
    "LastGoodSample", "LastObservedSample", "LastValidatedSample",
    "LastValidatedGroundedSample", "LastConfirmedGroundSample",
    "LastSample", "LastGameplayTrustedSample",
}
-- Failed heap sweeps before we accept the anticheat state is gone.
K.AC_SCAN_GIVEUP = 3
-- ...and how long before trying again anyway.
--
-- WAS 20s, AND THAT WAS A HITCH EVERY 20 SECONDS OF EVERY STEAL. Each retry
-- is a getgc(true) sweep: ~196,000 objects, 43ms on a desktop (measured, see
-- findAcState), several times that on a phone - plus a throwaway array of
-- every object in the VM for the GC to clean up. Since the 2026-09 update the
-- table it looks for does not exist, so every one of those sweeps fails. Once
-- the give-up budget is spent, look again every 3 minutes; a respawn still
-- resets the budget immediately (see the CharacterAdded handler), which
-- covers the late-loading client this retry was for.
K.AC_SCAN_RETRY = 180
K.AC_UNDO_THRESHOLD = 1.5   -- studs a validator may move us before we undo it
K.AC_BIG = 10000000

BX.acStates = {}
BX.acHooked = {}
BX.acSeen = {}

-- Does this closure look like one of the anticheat's validators?
function BX.acIsValidator(fn)
    if not debug or type(debug.getconstants) ~= "function" then return false end
    local ok, consts = pcall(debug.getconstants, fn)
    if not ok or type(consts) ~= "table" then return false end
    local blob = {}
    local n = 0
    for _, c in pairs(consts) do
        n = n + 1
        if n > 50 then break end
        blob[#blob + 1] = tostring(c)
    end
    local joined = table.concat(blob, "|")
    for _, mark in ipairs(K.AC_CONST_MARKS) do
        if joined:find(mark, 1, true) then return true, mark end
    end
    -- The speed comparator has no unique string, but it always mentions all
    -- three of these together.
    if joined:find("WalkSpeed", 1, true)
       and joined:find("AssemblyLinearVelocity", 1, true)
       and joined:find("Magnitude", 1, true) then
        return true, "ALVvsWalkSpeed"
    end
    return false
end

function BX.acLooksLikeState(t)
    if type(t) ~= "table" then return false end
    local okA, a = pcall(rawget, t, "LastGoodSample")
    local okB, b = pcall(rawget, t, "SafeGroundCheckpoints")
    return okA and type(a) == "table" and okB and type(b) == "table"
end

-- Collect the anticheat's state tables out of its own validators' upvalues.
-- TWO WAYS IN, NOT ONE. THIS IS THE "WORKS FOR HIM, NOT FOR ME" GATE.
--
-- Everything downstream keys off #BX.acStates: if it is zero, arcTweenTo turns
-- the spoof off and clamps travel to what the anticheat allows, which for a
-- low-speed account is barely walking pace and loses Titan every time.
--
-- And this function had exactly one way to fill it - walking
-- getconnections(PostSimulation) and reading validator upvalues. An executor
-- without getconnections returned 0 here and was locked out for the whole
-- session, EVEN THOUGH BX.findAcState can reach the very same table through
-- getgc and may already have it sitting in BX.acState. Two discovery routes
-- existed and only one of them counted.
--
-- Worth being precise about what the spoof actually does, because it changes
-- who this matters for. Measured on this account with the hub closed:
--
--     unspoofed   Short allows 27.63 studs over 0.12s -> 230 studs/s  (ws 208)
--     spoofed     Short allows 26.55 studs over 0.12s -> 221 studs/s
--
-- The allowance is the SAME. MaxHorizontalSpeed = 10000000 raises nothing. The
-- spoof works by rewriting the recorded samples so the anticheat's own history
-- says we never moved - which is independent of WalkSpeed entirely. So a
-- 1-speed account with the spoof armed travels exactly as fast as a 300-speed
-- one, and every area including Titan is open to it. The speed stat is not
-- what decides this. Reaching the table is.
--
-- Hence: try the connection walk, and if it comes back empty fall back to the
-- getgc route rather than reporting failure.
function BX.acCollect()
    if type(getconnections) ~= "function" then
        -- No connection walk on this executor. The getgc route may still work,
        -- so ask it before giving up on the whole session.
        return BX.acCollectFallback()
    end
    local found, seen = {}, {}
    pcall(function()
        for _, conn in ipairs(getconnections(RunService.PostSimulation)) do
            local fn = conn.Function
            if fn and BX.acIsValidator(fn) then
                -- Re-enable: a disabled validator still holds the upvalue we
                -- need, and leaving it off is itself detectable.
                pcall(function() conn:Enable() end)
                for i = 1, 24 do
                    local ok, a, b = pcall(debug.getupvalue, fn, i)
                    local up = ok and (b == nil and a or b) or nil
                    if up == nil then break end
                    if type(up) == "table" and not seen[up] and BX.acLooksLikeState(up) then
                        seen[up] = true
                        found[#found + 1] = up
                    end
                end
            end
        end
    end)
    -- MERGE, NEVER REPLACE.
    --
    -- Measured: a standalone probe of PostSimulation finds 3 validators and 2
    -- our real position and WalkSpeed while we spoofed the other one. The
    -- reference pushes to every entry of t154 and never rebuilds it downward:
    -- ...BUT DROP THE DEAD ONES FIRST. THIS IS THE RESTART BUG.
    --
    -- The state table is PER CHARACTER - it carries a Character field, and
    -- findAcState already refuses a cached one whose Character is not the
    -- current character. This list never got the same treatment. Every
    -- respawn the anticheat builds a fresh table, and the old one stayed in
    -- BX.acStates for the rest of the session.
    --
    -- That is worse than finding nothing. The gate everything reads is
    --
    --     if #BX.acStates == 0 then spoof = false ... end
    --
    -- so a list full of corpses says "we are spoofed, travel at full speed"
    -- while every write lands in a table the anticheat stopped reading. The
    -- live one records the real movement, and you get relocated.
    --
    -- Which is exactly the report: it works, then it stops, and closing Roblox
    -- and the executor fixes it - because a fresh process starts this list
    -- empty and the only table in it is the live one.
    BX.acPruned = 0
    do
        local char = LocalPlayer.Character
        local keep = {}
        for i = 1, #BX.acStates do
            local st = BX.acStates[i]
            local alive = false
            pcall(function()
                alive = type(st) == "table"
                    and rawget(st, "Player") == LocalPlayer
                    and (char == nil or rawget(st, "Character") == char)
            end)
            if alive then keep[#keep + 1] = st else BX.acPruned = BX.acPruned + 1 end
        end
        if BX.acPruned > 0 then
            trace(("ac: dropped %d dead state table(s) from a previous character"
                .. " - they were keeping the spoof switched on while it wrote to nothing")
                :format(BX.acPruned))
        end
        BX.acStates = keep
    end

    local known = {}
    for i = 1, #BX.acStates do known[BX.acStates[i]] = true end
    for i = 1, #found do
        if not known[found[i]] then
            known[found[i]] = true
            BX.acStates[#BX.acStates + 1] = found[i]
        end
    end
    if #BX.acStates == 0 then return BX.acCollectFallback() end
    return #BX.acStates
end

-- The getgc route, used when the connection walk finds nothing. findAcState
-- already knows how to do this; all that was missing was letting its result
-- count towards the gate everything else reads.
function BX.acCollectFallback()
    BX.acStates = BX.acStates or {}
    if #BX.acStates > 0 then return #BX.acStates end
    if type(getgc) ~= "function" then return 0 end

    local ok = pcall(function() BX.findAcState(true) end)
    local st = ok and BX.acState or nil
    if type(st) == "table" then
        BX.acStates[1] = st
        trace("ac: state found through getgc - the connection walk saw nothing,"
            .. " so the spoof would have stayed off")
        return 1
    end
    return 0
end

-- Rewrite one recorded sample so it agrees with where we are and what the
-- humanoid claims it can do.
function BX.acFixSample(s, hum, pos, vel)
    if type(s) ~= "table" or not pos then return end
    local look = Vector3.new(0, 0, -1)
    local cam = workspace.CurrentCamera
    if cam then
        local lv = cam.CFrame.LookVector
        local flat = Vector3.new(lv.X, 0, lv.Z)
        if flat.Magnitude > 0.001 then look = flat.Unit end
    end
    pcall(function()
        s.Position = pos
        -- Same NaN trap as the mover: a zero look vector makes
        -- CFrame.new(pos, pos), which is all NaN.
        if typeof(look) == "Vector3" and look.Magnitude > 0.001 then
            s.CFrame = CFrame.new(pos, pos + look)
        else
            s.CFrame = CFrame.new(pos)
        end
        s.LinearVelocity = vel
        s.AngularVelocity = Vector3.zero
        s.IsSupported = true
        s.Timestamp = os.clock()
        if hum then
            s.WalkSpeed = hum.WalkSpeed
            s.JumpPower = hum.JumpPower
            s.JumpHeight = hum.JumpHeight
            s.UseJumpPower = hum.UseJumpPower
            s.HumanoidState = Enum.HumanoidStateType.Running
        end
        s.Gravity = workspace.Gravity
    end)
end

-- The full state write. This is the part the previous version was missing.
function BX.acSpoofState(st, hrp, hum, pos, vel)
    if not BX.acLooksLikeState(st) then return end

    local halfRoot = (type(st.ExpectedRootHalfHeight) == "number") and st.ExpectedRootHalfHeight or 1
    local groundGap = (type(st.ExpectedHipHeight) == "number")
        and (st.ExpectedHipHeight + halfRoot * 0.5) or 2.51

    pcall(function()
        local now = os.clock()
        st.MaxHorizontalSpeed = K.AC_BIG
        st.MaxVerticalSpeed = K.AC_BIG
        st.IsSupportedNow = true
        st.LastSupportedAt = now
        st.LastCorrectionAt = 0
        st.HighestYSinceGround = pos.Y
        st.MovementMode = "Grounded"
        st.TelemetryRepeatCount = 0
        st.ValidationLocked = false
        st.MonitorRunning = false
        st.MonitorPending = false
        st.ThreatLevel = "Trusted"
        st.WasMeaningfullyFalling = false
        -- The validator treats its own start-up window as untrusted-but-exempt.
        -- Parking it an hour ahead keeps it permanently in that window.
        st.InitializingUntil = now + 3600
        st.SupportStartedAt = now
        st.ValidationStartedAt = now

        local witness = st.GroundContactWitness
        if type(witness) == "table" then
            witness.GroundDistance = groundGap
            witness.GroundPosition = Vector3.new(pos.X, pos.Y - groundGap, pos.Z)
            if hrp and hrp.Parent then witness.Character = hrp.Parent end
            if type(witness.ContactSample) == "table" then
                BX.acFixSample(witness.ContactSample, hum, pos, vel)
            end
        end

        local ev = st.Evidence
        if type(ev) == "table" then
            ev.Speed, ev.Flight, ev.Teleport = 0, 0, 0
        end

        local vt = st.LastVerticalTrajectoryDecision
        if type(vt) == "table" then
            vt.Active = false
            vt.CorrectionStarted = false
            vt.ConsecutiveInvalidWindows = 0
            vt.EvidenceEventCount = 0
            vt.MeaningfulDescent = false
            vt.LandingCandidate = false
            vt.CurrentY, vt.PeakY, vt.StartY = pos.Y, pos.Y, pos.Y
            vt.AirborneDuration = 0
            vt.LandingDuration = 0
            vt.LatestLegalSampleAge = 0
            vt.AllowedRise = K.AC_BIG
            vt.AllowedAirborneDuration = K.AC_BIG
            vt.Evidence = 0
            vt.PrimaryEvidenceSource = "None"
        end

        local vs = st.LastVerticalSegmentDecision
        if type(vs) == "table" then
            vs.Active = false
            vs.CorrectionStarted = false
            vs.Displacement = 0
            vs.Excess = 0
            vs.AllowedDistance = K.AC_BIG
            vs.Decision = "Reachable"
            vs.CurrentY, vs.PreviousY = pos.Y, pos.Y
            vs.MovementContext = "OrdinaryStationaryY"
        end
    end)

    for _, field in ipairs(K.AC_SAMPLE_FIELDS) do
        BX.acFixSample(st[field], hum, pos, vel)
    end
    local hist = st.SampleHistory
    if type(hist) == "table" then
        for _, s in pairs(hist) do BX.acFixSample(s, hum, pos, vel) end
    end
    local checks = st.SafeGroundCheckpoints
    if type(checks) == "table" then
        for _, s in pairs(checks) do BX.acFixSample(s, hum, pos, vel) end
    end
end

-- Clamp what we report to something the humanoid's own WalkSpeed explains,
-- then push that story into every state table.
function BX.acPush(hrp, hum, vel)
    if not hrp or not hum then return end
    local cap = math.max(10, hum.WalkSpeed or 16)
    local out = vel
    if out.Magnitude > cap + 1 then
        out = out.Magnitude > 0.0001 and out.Unit * cap or Vector3.zero
    end
    if not BX.spoofMoving then
        pcall(function() hrp.AssemblyLinearVelocity = out end)
    end
    for i = 1, #BX.acStates do
        BX.acSpoofState(BX.acStates[i], hrp, hum, hrp.Position, out)
    end
end

-- Wrap the validators so any correction they apply is immediately undone.
function BX.acHookValidators()
    if type(hookfunction) ~= "function" or type(getconnections) ~= "function" then
        trace("ac: cannot hook validators on this executor")
        return 0
    end
    local n = 0
    for _, conn in ipairs(getconnections(RunService.PostSimulation)) do
        local fn = conn.Function
        if fn and not BX.acHooked[fn] and BX.acIsValidator(fn) then
            local box = { old = fn }
            local repl = function(...)
                local hrp, hum = getHRP(), getHumanoid()
                local beforeCF, beforeVel
                if hrp and hum then
                    beforeCF = hrp.CFrame
                    beforeVel = hrp.AssemblyLinearVelocity
                    BX.updatePad(hrp.Position)
                    BX.acPush(hrp, hum, beforeVel)
                end

                local packed
                local ok, err = pcall(function(...)
                    packed = table.pack(box.old(...))
                end, ...)

                -- THE UNDO. Anything the validator moved is put straight back.
                if hrp and beforeCF then
                    local moved = (hrp.Position - beforeCF.Position).Magnitude
                    -- While the mover is driving, a step is legitimately large,
                    -- so only a correction well beyond one step counts as a
                    -- relocate. Undoing at 1.5 studs during our own movement is
                    local limit = BX.spoofMoving
                        and math.max(K.AC_UNDO_THRESHOLD, (K.SPOOF_SPEED or 500) * 0.1)
                        or K.AC_UNDO_THRESHOLD
                    if moved > limit then
                        pcall(function()
                            hrp.CFrame = beforeCF
                            hrp.AssemblyLinearVelocity = beforeVel
                        end)
                        if os.clock() - (BX.acUndoAt or 0) > 1 then
                            BX.acUndoAt = os.clock()
                            trace(("ac: undid relocate %.1f studs"):format(moved))
                        end
                    end
                end
                if hrp and hum then BX.acPush(hrp, hum, beforeVel or hrp.AssemblyLinearVelocity) end
                if beforeVel and hrp then
                    pcall(function()
                        if BX.jumping() then
                            hrp.AssemblyLinearVelocity = Vector3.new(
                                beforeVel.X,
                                hrp.AssemblyLinearVelocity.Y,
                                beforeVel.Z)
                        else
                            hrp.AssemblyLinearVelocity = beforeVel
                        end
                    end)
                end

                if not ok then error(err) end
                return table.unpack(packed, 1, packed.n)
            end
            if type(newcclosure) == "function" then repl = newcclosure(repl) end
            local okHook, orig = pcall(hookfunction, fn, repl)
            if okHook then
                box.old = orig or fn
                BX.acHooked[fn] = box.old
                n = n + 1
            end
        end
    end
    if n > 0 then trace(("ac: wrapped %d validators"):format(n)) end
    return n
end

function BX.acUnhook()
    for fn, orig in pairs(BX.acHooked) do
        if type(restorefunction) == "function" then
            pcall(restorefunction, fn)
        elseif type(hookfunction) == "function" and orig then
            pcall(hookfunction, fn, orig)
        end
        BX.acHooked[fn] = nil
    end
    trace("ac: validators restored")
end

function BX.acArm()
    local n = BX.acCollect()
    BX.acHookValidators()
    trace(("ac: %d state table(s) located"):format(n))
    return n > 0
end

K.SPOOF_CLAMP = 0.15        -- minimum impulse duration
K.SPOOF_PADDING = 24        -- slack added to impulse distance
-- 500: the highest speed this account has been observed DELIVERING at
-- ("rate=506 ws=205.6 vel=500 gap=+6" then "DELIVERED"). Not a guess.
K.SPOOF_SPEED = 800         -- default travel speed (outbound only, empty-handed)
function BX.safeZonePoint()
    local sl = workspace:FindFirstChildOfClass("SpawnLocation")
    if sl and sl:IsA("BasePart") then
        return sl.Position + Vector3.new(0, 4, 0)
    end
    local st = workspace:FindFirstChild("SpawnTarget", true)
    if st and st:IsA("BasePart") then
        return st.Position + Vector3.new(0, 4, 0)
    end
    return BX.homePos()
end
K.SPOOF_FIELDS = {
    "LastObservedSample", "LastSample", "LastGoodSample",
    "LastGameplayTrustedSample", "LastValidatedSample",
    "LastValidatedGroundedSample", "LastConfirmedGroundSample",
    "CandidateGroundedSample",
}

BX.acState = nil

-- Structural search. Cached, because a getgc(true) sweep is expensive and the
-- table is stable for the life of a character.
function BX.findAcState(force)
    if not force and BX.acState then
        local st = BX.acState
        if rawget(st, "Character") == LocalPlayer.Character then return st end
    end
    BX.acState = nil
    if type(getgc) ~= "function" then return nil end
    -- GONE IS GONE. Once the give-up budget has been spent this session the
    -- table does not exist (the 2026-09 update removed it - every sweep since
    -- has come back empty), and each further sweep is a whole-heap walk:
    -- 43ms on a desktop, a freeze on a phone executor, on every Auto Steal
    -- start and every respawn. Stop looking for good.
    if BX.acGone then return nil end

    local ch = getChar()
    local hum = getHumanoid()
    local rp = getHRP()
    -- NOT A FAILURE, JUST TOO EARLY. Returning here means we never looked, so
    -- the caller must not count it against the give-up budget - see the note
    -- on BX.acScanFails. Under a loader that auto-executes on join this is the
    -- normal state for the first few seconds.
    if not (ch and hum and rp) then
        BX.acScanSkipped = true
        return nil
    end
    BX.acScanSkipped = false

    local found
    pcall(function()
        -- NO pcall IN HERE. rawget on a table bypasses metatables and cannot
        -- error, so wrapping the walk in one bought nothing and cost most of
        -- the sweep: measured, 196,079 GC objects with 35,097 tables took 43ms
        -- total, of which 27ms was the guarded rawget. At 30fps that is more
        -- than a frame dropped, every time the scan runs.
        --
        -- Cheapest test first, too. `Player` rejects almost everything on the
        -- first comparison, so the later fields are only reached by the
        -- handful of tables that could plausibly be it.
        for _, o in ipairs(getgc(true)) do
            if type(o) == "table"
               and rawget(o, "Player") == LocalPlayer
               and rawget(o, "Character") == ch
               and rawget(o, "Humanoid") == hum
               and rawget(o, "RootPart") == rp
               and type(rawget(o, "SampleHistory")) == "table"
               and type(rawget(o, "Evidence")) == "table" then
                found = o
                return
            end
        end
    end)

    BX.acState = found
    if found ~= BX.acFoundLast then
        BX.acFoundLast = found
        trace(found and "spoof: anticheat state located"
                     or "spoof: state NOT found - running unprotected")
    end
    return found
end

-- Rewrite one recorded sample so it agrees with where we actually are.
local function fixSample(sample, ws, cf, pos, vel)
    if type(sample) ~= "table" then return end
    rawset(sample, "WalkSpeed", ws)
    if cf then
        rawset(sample, "CFrame", cf)
        rawset(sample, "Position", pos)
        rawset(sample, "LinearVelocity", vel)
        rawset(sample, "AngularVelocity", Vector3.zero)
    end
end

function BX.spoofAc(ws, vel)
    local st = BX.acState
    if type(st) ~= "table" then return false end
    vel = vel or Vector3.zero

    local ok = pcall(function()
        local rp = rawget(st, "RootPart")
        local cf = (rp and rp.Parent) and rp.CFrame or nil
        local pos = cf and cf.Position or nil

        for _, field in ipairs(K.SPOOF_FIELDS) do
            fixSample(rawget(st, field), ws, cf, pos, vel)
        end
        for _, s in pairs(rawget(st, "SampleHistory") or {}) do
            fixSample(s, ws, cf, pos, vel)
        end
        for _, s in pairs(rawget(st, "SafeGroundCheckpoints") or {}) do
            fixSample(s, ws, cf, pos, vel)
        end

        local ev = rawget(st, "Evidence")
        if type(ev) == "table" then
            ev.Speed, ev.Teleport, ev.Flight = 0, 0, 0
        end

        -- Only present on some builds; harmless when absent.
        local imp = rawget(st, "ImpulseContext")
        if type(imp) == "table" then
            local maxSpeed = math.max(tonumber(imp.MaxHorizontalSpeed) or 0, ws)
            local dur = math.max((tonumber(imp.ExpiresAt) or 0) - (tonumber(imp.StartedAt) or 0),
                                 K.SPOOF_CLAMP)
            imp.MaxHorizontalSpeed = maxSpeed
            if pos then imp.OriginPosition = pos end
            imp.MaxHorizontalDistance = math.max(tonumber(imp.MaxHorizontalDistance) or 0,
                                                 maxSpeed * dur + K.SPOOF_PADDING * 2)
            fixSample(imp.PreMovementSafeSample, ws, cf, pos, vel)
        end

        -- Clear suspicion. Only when no correction is already in flight -
        -- overwriting mid-correction is what turns one flag into a relocate
        -- burst.
        if rawget(st, "CorrectionContext") == nil then
            rawset(st, "FirstSuspiciousAt", nil)
            if rawget(st, "ThreatLevel") == "Observing" then
                rawset(st, "ThreatLevel", "Trusted")
            end
            if rawget(st, "ValidationLocked") == true then
                rawset(st, "ValidationLocked", false)
            end
        end
    end)
    return ok
end

-- Keep the record clean even while standing still, so a leftover flag from a
-- ragdoll or a bad frame does not sit there waiting to be reported.
function BX.startSpoofHold()
    if BX.spoofConn then return end
    BX.findAcState(true)
    BX.acScanFails = 0
    BX.spoofConn = RunService.Heartbeat:Connect(function()
        local st = BX.acState
        if not st or rawget(st, "Character") ~= LocalPlayer.Character then
            -- STOP SWEEPING THE HEAP FOR SOMETHING THAT NO LONGER EXISTS.
            --
            -- findAcState is a getgc(true) sweep - it walks every live table
            -- in the VM. That was fine when it usually succeeded on the first
            -- try. After the 2026-09 update the anticheat state is gone
            -- entirely (verified: all twelve of its marker fields return zero
            -- hits), so this failed every time and kept re-sweeping the whole
            -- heap every 3 seconds, for the entire session, on a Heartbeat.
            -- That is a large part of the reported lag.
            --
            -- Give up after a few attempts and say so once. A respawn clears
            -- the counter, so if a later update brings the table back it will
            -- be found again without a reload.
            -- GIVING UP IS TEMPORARY NOW, AND THAT MATTERS FOR LOADERS.
            --
            -- This used to `return` forever once the budget was spent, which
            -- is fine when the state genuinely no longer exists - but it is
            -- wrong when we simply looked too early.
            --
            -- Pasting the script by hand happens after the game has finished
            -- loading, so the state is there on the first sweep. A key-system
            -- loader auto-executes on join, sweeps three times before the
            -- client has built its anticheat state, gives up permanently, and
            -- the speed spoof never arms for the whole session. That is both
            -- reported symptoms at once: travel drops from 1200 to the 500
            -- fallback (slow trip to the egg), and 500 cannot outrun Titan
            -- Temple's 918 chase speed, so the last area loses every egg.
            --
            -- So: after the budget, keep looking, just rarely.
            local now = os.clock()
            local spent = (BX.acScanFails or 0) >= K.AC_SCAN_GIVEUP
            local gap = spent and K.AC_SCAN_RETRY or 3
            if now - (BX.acScanAt or 0) > gap then
                BX.acScanAt = now
                task.spawn(function()
                    pcall(BX.findAcState, true)
                    if BX.acState then
                        BX.acScanFails = 0
                        trace("spoof: anticheat state found - full speed available")
                    elseif BX.acScanSkipped then
                        -- Character was not ready; we never looked. Costs
                        -- nothing.
                    else
                        BX.acScanFails = (BX.acScanFails or 0) + 1
                        if BX.acScanFails == K.AC_SCAN_GIVEUP then
                            BX.acGone = true   -- see findAcState: no more sweeps
                            trace("spoof: no anticheat state after "
                                .. K.AC_SCAN_GIVEUP .. " sweeps - the game update removed it,"
                                .. " so the scan is off (travelling at legal speed)")
                        end
                    end
                end)
            end
            return
        end
        BX.acScanFails = 0
        if BX.spoofMoving then return end   -- the mover owns the values mid-route
        local hum = getHumanoid()
        local hrp = getHRP()
        if not hum or not hrp then return end
        BX.spoofAc(math.max(hum.WalkSpeed, 16),
                   hrp.AssemblyLinearVelocity * Vector3.new(1, 0, 1))
    end)
    trace("spoof: hold ON")
end

function BX.stopSpoofHold()
    pcall(BX.destroyPad)
    if BX.spoofConn then
        pcall(function() BX.spoofConn:Disconnect() end)
        BX.spoofConn = nil
    end
    BX.spoofMoving = false
    trace("spoof: hold OFF")
end


K.STEAL_SPEED = 300
-- How long to keep the engine running at the pad waiting for the verdict.
-- Theirs is 4s before Bank gives up and goes back to Return:
-- The measured verdict landed 0.45s after arrival, so 4s is generous, which is
K.BANK_HOLD = 4.0
-- Which carry mover to use. "modelmove" is the stepped Character:MoveTo from
-- the small working autofarm (see BX.modelMoveCarryTo); "humanoid" is the
-- Humanoid.WalkSpeed replicates from the client that owns the character, so
-- CLAIMED from every area including Prehistoric at 2143 studs. Every scripted
-- The combination that has NEVER been tried is the one below: the server's own
K.CARRY_USE_SERVER_SPEED = true

function BX.kiraCarryTo(dest, speed, arrive, cancel, tag)
    local hrp, hum = getHRP(), getHumanoid()
    if not hrp or not hum or typeof(dest) ~= "Vector3" then return false end

    -- v1151(): the travel speed, clamped exactly as theirs is - unless we are
    -- deferring to the server's governed WalkSpeed, in which case `speed` is
    -- re-read every frame below and nothing is written.
    speed = math.clamp(tonumber(speed) or K.STEAL_SPEED, 0, 500)
    arrive = arrive or K.SAFE_ZONE_ARRIVE

    BX.acCollect()
    pcall(BX.findAcState)

    local start = hrp.Position
    local total = Vector3.new(dest.X - start.X, 0, dest.Z - start.Z).Magnitude
    local paceNow = K.CARRY_USE_SERVER_SPEED
        and math.max(BX.legalWalkSpeed(), 16) or math.max(speed, 16)
    local deadline = os.clock() + math.max(total / paceNow, 0.1) * 2.5 + 12
    local t0 = os.clock()
    local lastPos, deadAt = start, os.clock()
    local pushed = 0
    local banking, bankUntil = false, 0
    local flings, lastGY, lastSnapAt = 0, nil, 0

    trace(("%s: %.0f studs at %.0f studs/s (%s), %d ac state(s)")
        :format(tag or "carry", total, paceNow,
                K.CARRY_USE_SERVER_SPEED and "clamped down to the server's" or "written",
                #BX.acStates))

    while os.clock() < deadline do
        if cancel and cancel() then break end
        RunService.Stepped:Wait()

        local h, hm = getHRP(), getHumanoid()
        if not h or not hm or hm.Health <= 0 then break end

        -- v1227(): arrival is 28 studs on XZ, nothing else.
        local flat = Vector3.new(dest.X - h.Position.X, 0, dest.Z - h.Position.Z)
        local mag = flat.Magnitude

        -- BANK. Reaching the pad is NOT the end of the leg.
        --
        --   9.14  carry home: arrived, 24 studs out after 3.20s
        -- The carry ARRIVED - 24 studs out, inZone=true - and the server took
        -- 0.45s to render its verdict. This function used to return at the
        -- first line, which tore down the AC pushes and left Humanoid.WalkSpeed
        -- The reference never leaves it. v1182 is ONE permanent Stepped
        -- u1127 pointed at the safe zone, keeps WalkSpeed re-asserted and keeps
        if mag <= arrive then
            if not banking then
                banking = true
                bankUntil = os.clock() + K.BANK_HOLD
                trace(("%s: at the pad, %.0f studs out after %.2fs (%d pushes) - holding for the verdict")
                    :format(tag or "carry", mag, os.clock() - t0, pushed))
            end
            if os.clock() > bankUntil then
                trace((tag or "carry") .. ": bank hold expired, still carrying")
                pcall(function() hm:Move(Vector3.zero, false) end)
                return true
            end
        end

        -- v1154(): desired flat velocity, with their taper inside 8 studs and
        -- their dead stop under 1.4.
        -- current WalkSpeed IS the budget, re-read live so the carry malus is
        local pace = speed
        if K.CARRY_USE_SERVER_SPEED then
            -- The budget is what the SERVER says, not what the humanoid happens
            -- to be carrying. The outbound leg leaves WalkSpeed at
            pace = math.max(BX.legalWalkSpeed(), 16)
        end

        local want = pace
        if mag < 8 then want = math.clamp(pace * (mag / 8), math.min(18, pace), math.max(pace, 18)) end
        local desired = (banking or mag < 1.4) and Vector3.zero
            or Vector3.new(flat.Unit.X * want, 0, flat.Unit.Z * want)

        -- v1182 tail, verbatim in order and content.
        pcall(function()
            hm.PlatformStand = false
            hm.Sit = false
            hm.AutoRotate = true
            hm.AutoJumpEnabled = true

            -- v1686.WalkSpeed = math.clamp(v1151(), 16, 1300)
            -- v1686.WalkSpeed = math.clamp(v1151(), 16, 1300)
            -- Humanoid.WalkSpeed replicates from the owning client, so the 675
            -- carry. Clamp it DOWN to the server's value, never up.
            if K.CARRY_USE_SERVER_SPEED then
                if hm.WalkSpeed > pace + 0.5 then hm.WalkSpeed = pace end
            else
                hm.WalkSpeed = math.clamp(speed, 16, 1300)
            end

            local st = hm:GetState()
            if st == Enum.HumanoidStateType.PlatformStanding
               or st == Enum.HumanoidStateType.Physics
               or st == Enum.HumanoidStateType.Seated then
                hm:ChangeState(Enum.HumanoidStateType.Running)
            end

            if desired.Magnitude > 1 then
                hm:Move(desired.Unit, false)
            else
                hm:Move(Vector3.zero, false)
            end

            -- v1685.AssemblyLinearVelocity =
            --     Vector3.new(v1695.X, alv.Y, v1695.Z)
            h.AssemblyLinearVelocity =
                Vector3.new(desired.X, h.AssemblyLinearVelocity.Y, desired.Z)
        end)

        -- local v1712 = math.max(10, WalkSpeed or 16)
        -- local v1713 = alv.Magnitude > v1712 + 1 and alv.Unit * v1712 or alv
        -- for i = 1, #t154 do v1141(t154[i], root, hum, root.Position, v1713) end
        local alv = h.AssemblyLinearVelocity
        local cap = math.max(10, hm.WalkSpeed or 16)
        local told = alv
        if alv.Magnitude > cap + 1 then
            told = alv.Magnitude > 0.0001 and alv.Unit * cap or Vector3.zero
        end
        if #BX.acStates > 0 then
            for i = 1, #BX.acStates do
                BX.acSpoofState(BX.acStates[i], h, hm, h.Position, told)
            end
            pushed = pushed + 1
        else
            BX.spoofAc(cap, told)
        end

        if banking then
            deadline = math.max(deadline, bankUntil + 0.5)
            lastPos, deadAt = h.Position, os.clock()
        elseif (h.Position - lastPos).Magnitude > 2 then
            lastPos, deadAt = h.Position, os.clock()
        elseif os.clock() - deadAt > 1.5 then
            deadAt = os.clock()
            trace((tag or "carry") .. ": not advancing")
        end
    end

    local h2 = getHRP()
    local gap = h2 and Vector3.new(dest.X - h2.Position.X, 0, dest.Z - h2.Position.Z).Magnitude or 9999
    local hm2 = getHumanoid()
    if hm2 then pcall(function() hm2:Move(Vector3.zero, false) end) end
    trace(("%s: left the leg %.0f studs out after %.2fs (%d pushes, banked=%s)")
        :format(tag or "carry", gap, os.clock() - t0, pushed, tostring(banking)))
    return banking or gap <= arrive
end

-- =====================================================================
-- THE Model:MoveTo CARRY.
-- What makes it a genuinely different mover from the four already measured
-- here is what it does NOT do. There is no WalkSpeed write, no
-- usual pushes back in would stop it being the thing that was measured working.
-- Everything measured here so far, for the record:
-- The bank hold is kept, because the trace is unambiguous that the verdict
-- lands 0.2-0.5s AFTER arrival and leaving during that window cannot help.
K.MODEL_MOVE_SPEED = 430
-- AUTO-TUNE THE CARRY, WITH 430 AS A FLOOR IT CAN NEVER GO BELOW.
--
-- CLIMB FASTER. The floor stays 430 because that is the number this file has
-- trips to reach 900 and never goes past it. The reference autofarm runs 430
-- so 900 was not a measured ceiling - it was a guess.
-- SPEED PROBING IS OFF, AND IT COSTS AN EGG EVERY TIME IT RUNS.
--
-- Two separate tuners here climb the carry speed until the server refuses,
-- and a refusal is not free - the refused carry is the egg going back to its
-- nest. Straight from a live log:
--     carry tune: 1 clean deliveries - trying 580 studs/s
--     carry: 590 studs/s VOIDED by the server - ceiling set
--     return: NOT claimed - egg state=Slot inPlot=false
-- That last line is the "anticheat, egg was returned to nest" being reported.
--
-- Worse, K.CARRY_STEP_AFTER was 1: it probed again after EVERY successful
-- delivery, so a fresh session sacrifices an egg almost immediately. Anyone
-- whose session had already found its ceiling stopped seeing it, which is why
-- it looked executor-specific - it is really session-specific.
--
-- 430 is the speed that has delivered from the beginning and is what the
-- unspoofed outbound leg uses too. Sitting there costs a little time and
-- loses no eggs. Set BX.carryProbe = true to hunt for the ceiling again.
BX.carryProbe = false

-- 500, NOT 430. 430 was a conservative choice when the game update killed the
-- speed spoof, not a measured limit. This script's own probe logs bracket the
-- real ceiling: "carry probe: 500 OK" and "carry: 590 studs/s VOIDED by the
-- server". 500 is the fastest value observed to bank, and it also clears
-- Volcano's 452 chase speed, which 430 did not.
-- THIS NUMBER WAS MEASURED ON ONE ACCOUNT, AND THAT IS THE BUG.
--
-- 500 is the fastest speed that banked reliably HERE, on a character with
-- WalkSpeed 207.9. But the server's carry budget is not a constant - it scales
-- with YOUR walk speed, which is why this file is full of WalkSpeed * 1.7 and
-- BX.legalWalkSpeed(). Measured live in one ordinary server, six players:
--
--     122, 150, 175, 187, 208, 225
--
-- So 500 is 2.4x walk speed for the account it was tuned on and 4.1x for the
-- slowest player in that list. For them every single carry is over budget, the
-- server voids it, and they get "Delivery failed" over and over - which is
-- exactly the 90% being reported. Worse, carryRefused reset to this same
-- constant, so the tuner could never climb DOWN to a speed that worked. The
-- floor was a floor through the ceiling.
--
-- Now it is a ratio instead of a number. 500 / 207.87 = 2.405, so this account
-- lands on 500 and nothing about the confirmed-working build changes; everyone
-- else gets the same multiple of their own speed.
K.CARRY_RATIO = 2.4
K.CARRY_FLOOR = 500

-- THE GUARD IS THE OTHER HALF OF THIS, AND IT SETS A HARD BOTTOM.
--
-- GuardChasePolicy.ResolveWalkSpeed, the game's own function:
--
--     speed = base                                   while stray <= FlatRadius
--     speed = min(base * ((stray/20 - 1) * 0.5 + 1), base * 4)
--
-- I had this backwards for a while and it matters, so: the distance fed to
-- ResolveWalkSpeed is NOT how far the guard has strayed from home. It is how
-- far away YOU are. GuardComponent._updateChase:
--
--     self._humanoid.WalkSpeed = self:_getChaseWalkSpeed(
--         GuardDistance.XZ(self._root.Position, target.Position))
--
-- So the guard runs faster the further you get. Titan Temple:
--
--     you  0 studs away -> 230      you 140 studs away -> 918  (capped)
--     you 60            -> 459      you 200            -> 918
--     you 100           -> 688      you 300            -> 918
--
-- AND THAT IS WHY THE CARRY SPEED CANNOT BE LOWERED. ResolveCatchDuration
-- returns nil - never caught - when your speed is at least the guard's speed
-- at the CURRENT distance. At the moment of the steal he is standing on the
-- nest, so that distance is tiny and his speed is just `base`. Beat base and
-- the chase never develops at all.
--
--     Titan base 229.5     carry at 499  -> never catches you
--                          carry at 216  -> caught immediately
--
-- I clamped the carry to the anticheat's ~216 allowance for one build and
-- every guard in the game caught the player, which is this line of maths. The
-- guard floor below (base * 1.06, hard minimum 245) exists precisely to keep
-- the carry above that number, and nothing may clamp underneath it.
--
-- So there are two different numbers that matter. The first is the guard's
-- STARTING speed - the fastest base in the game is Titan at 229.5 - and
-- anything under that loses the egg instantly, before the chase even develops.
-- That is the hard bottom, and the old K.CARRY_HARD_MIN of 150 sat underneath
-- every guard in the game.
--
-- The second is what the acceleration does to your escape window. Feeding
-- ResolveCatchDuration a Titan guard that has already strayed 100 studs:
--
--     carry 245 -> caught after 0.31s
--     carry 300 -> caught after 0.34s
--     carry 500 -> caught after 0.52s
--     carry 700 -> never caught
--
-- Half a second at 500. That is the whole margin, and it is why the 0.71s
-- stall on the nest was fatal - the stall was longer than the entire escape
-- window. Speed is what buys that window, so the floor is a floor: it never
-- drops below what beats the local guard off the mark.
K.CARRY_HARD_MIN = 245
K.GUARD_START_MARGIN = 1.06

-- The slowest carry that still beats this area's guard at the moment it wakes.
function BX.guardFloor(areaId)
    areaId = areaId or BX.carryAreaId
    if not areaId then return K.CARRY_HARD_MIN end
    local base
    pcall(function()
        local d = require(RS.Data.Guards).Directory[areaId]
        base = d and d.WalkSpeed
    end)
    if type(base) ~= "number" or base <= 0 then return K.CARRY_HARD_MIN end
    return math.max(K.CARRY_HARD_MIN, base * K.GUARD_START_MARGIN)
end

function BX.carryFloor()
    local ws
    pcall(function() ws = BX.legalWalkSpeed and BX.legalWalkSpeed() end)
    local floor = (type(ws) == "number" and ws > 0)
        and (ws * K.CARRY_RATIO) or K.CARRY_FLOOR

    -- BX.carryDeepFloor only exists once refusals have driven us below the
    -- ratio, and it is what lets a player whose real budget is lower still
    -- find it instead of failing forever.
    if BX.carryDeepFloor then floor = math.min(floor, BX.carryDeepFloor) end

    -- ...but never below the guard. Losing the egg to the server for going too
    -- fast and losing it to the guard for going too slow are both losing the
    -- egg, and only one of them is avoidable by slowing down.
    floor = math.max(floor, BX.guardFloor())

    -- NEVER FASTER THAN V1. THIS IS THE SNAP-BACK.
    --
    -- The floor above is walkSpeed * K.CARRY_RATIO, and the walk speed comes
    -- from BX.legalWalkSpeed(), which prefers BX.serverWalkSpeed - captured as
    --
    --     BX.serverWalkSpeed = hum.WalkSpeed
    --
    -- straight off the live Humanoid. The outbound leg's spoof writes
    --
    --     hum.WalkSpeed = speed * K.ARC_SPOOF_HEADROOM     -- 1.35, to 4000
    --
    -- so when that capture lands mid-spoof the number is inflated. A 1200
    -- stud/s outbound leg leaves 1620 behind, the floor becomes 1620 * 2.4 =
    -- 3888, and the old ceiling here was K.CARRY_CEILING - so the carry ran at
    -- 1400 instead of 500. The anticheat allows about 216. That is the
    -- snap-back, and it is intermittent because it depends on whether the
    -- capture caught the spoofed value before the server governor pulled it
    -- back down.
    --
    -- Clamping to K.CARRY_FLOOR instead fixes it without touching the source
    -- or adding a single lookup: a slow account still scales DOWN, and nobody
    -- ever scales up past the 500 V1 carried at.
    return math.clamp(floor, K.CARRY_HARD_MIN, K.CARRY_FLOOR)
end

-- WHY THERE IS NO SIDEWAYS ESCAPE HERE ANY MORE.
--
-- I built one. The game hands you GuardEscapePrediction.ResolveExitDistance
-- and a ClosestExitPoint per area, and on paper the numbers are wonderful -
-- Titan Temple, the area everybody calls impossible, is 33 studs from the edge
-- of the guard box. Go out the short side instead of running 4293 studs home
-- and no guard can reach you.
--
-- On paper. Raycast it from a real Titan egg at (4797, -325) and every way out
-- is a wall:
--
--     +Z  36 studs to the edge   BLOCKED by WallDeco at 25
--     -Z 114                     BLOCKED by MainSideWall at 107
--     +X 331                     BLOCKED
--     -X 529 (toward home)       BLOCKED
--
-- Build.TitanTempleZone has WALL LEFT at Z=-441.7 and WALL RIGHT at Z=-286.7,
-- and the Bounds edges are at -438.8 and -288.8 - inside the walls. Cosmic is
-- built the same way. These zones are walled corridors, and ClosestExitPoint
-- is a doorway used for the game's "you need X speed" sign, not a route
-- anybody can walk.
--
-- So the carry goes straight home, the way it always did. The measurements are
-- kept here because they are the reason not to try this again.

-- HOW LONG WE ACTUALLY HAVE, straight out of the game's own maths. Logged at
-- the start of every carry so a report can be read instead of guessed at:
-- "caught after 0.52s" and "never caught" are very different bug reports.
function BX.guardWindow(areaId, speed)
    areaId = areaId or BX.carryAreaId
    if not areaId then return nil end
    local secs
    pcall(function()
        local P = require(RS.Shared.Modules.GuardAreas.GuardChasePolicy)
        local d = require(RS.Data.Guards).Directory[areaId]
        if not (P and d and d.WalkSpeed) then return end
        -- How far the guard has already come for us. That is what decides
        -- which point on the acceleration curve it is running at.
        local stray = 1
        local g = BX.findAreaGuard and BX.findAreaGuard(areaId)
        local hrp = getHRP()
        if g and hrp then
            local gp = g:IsA("Model") and g:GetPivot().Position or g.Position
            if gp then stray = math.max((gp - hrp.Position).Magnitude, 1) end
        end
        secs = P.ResolveCatchDuration(d.WalkSpeed, d.FlatRadius or 20,
            stray, stray + 200, speed)
    end)
    return secs
end
K.CARRY_CEILING = 1400
K.CARRY_STEP = 150
K.CARRY_STEP_AFTER = 1

BX.carryNow = K.MODEL_MOVE_SPEED
BX.carryGood = K.MODEL_MOVE_SPEED   -- fastest speed that has actually delivered
BX.carryWins = 0
BX.carryCapped = false

function BX.carrySpeedNow()
    local floor = BX.carryFloor()
    -- Ceiling is V1's 500 unless deliberately probing. K.CARRY_CEILING is 1400
    -- and nothing carrying an egg has any business there.
    local ceiling = BX.carryProbe and K.CARRY_CEILING or K.CARRY_FLOOR
    return math.clamp(BX.carryNow or floor, floor, math.max(ceiling, floor))
end

function BX.carryDelivered()
    BX.banked = (BX.banked or 0) + 1
    BX.carryGood = BX.carrySpeedNow()
    if BX.carryCapped then return end
    -- Not probing: hold the speed that just worked.
    if not BX.carryProbe then return end
    BX.carryWins = (BX.carryWins or 0) + 1
    if BX.carryWins >= K.CARRY_STEP_AFTER and BX.carryGood < K.CARRY_CEILING then
        BX.carryWins = 0
        BX.carryNow = math.min(BX.carryGood + K.CARRY_STEP, K.CARRY_CEILING)
        trace(("carry tune: %d clean deliveries - trying %d studs/s")
            :format(K.CARRY_STEP_AFTER, BX.carryNow))
    end
end

function BX.carryRefused()
    BX.refused = (BX.refused or 0) + 1
    BX.carryWins = 0

    local floor = BX.carryFloor()
    if BX.carryGood and BX.carrySpeedNow() > BX.carryGood then
        -- We have banked at a lower speed before; go back to it and stay.
        BX.carryCapped = true
        BX.carryNow = BX.carryGood
        BX.carryDeepFails = 0
        trace(("carry tune: refused - back to the last speed that banked (%d) and staying there")
            :format(BX.carryNow))
        return
    end

    -- NOTHING HAS EVER BANKED, AND WE ARE ALREADY AT THE FLOOR.
    --
    -- The old code set the speed back to the floor here and stopped, so an
    -- account whose real budget sits below the floor failed every carry for
    -- ever with no way out. Two of those in a row is enough to say the floor
    -- itself is wrong for this player, so drop it 15% and let it keep
    -- searching. It cannot cost an egg that was not already being lost.
    BX.carryDeepFails = (BX.carryDeepFails or 0) + 1
    if BX.carryDeepFails >= 2 then
        BX.carryDeepFails = 0
        local lower = math.max(K.CARRY_HARD_MIN, floor * 0.85)
        if lower < floor - 1 then
            BX.carryDeepFloor = lower
            trace(("carry tune: %d refusals at %d studs/s and nothing has ever banked"
                .. " - the floor is wrong for this account, trying %d")
                :format(BX.refused, math.floor(floor), math.floor(lower)))
        end
    end
    BX.carryNow = BX.carryFloor()
end
-- The trip BACK to a dropped egg is empty-handed. There is no carry for the
-- server to void, so it can run as fast as the outbound leg does.

K.MODEL_MOVE_MAX_DT = 0.05   -- longest frame we will step for, in seconds
K.MODEL_MOVE_MAX_RISE = 8    -- studs above the floor that mean we are airborne

function BX.startVoidWatch()
    if BX.voidWatchThread then return end
    BX.voidWatchThread = task.spawn(function()
        local anchor = nil
        -- RUN IN THE ARENA TOO. This is the one thing in the file that can
        -- actually save a fall, and `while stealing` meant it was switched off
        -- for the entire boss fight - the place with a hole in the floor.
        while stealing or (BX.inBossArena and BX.inBossArena()) do
            task.wait(0.2)
            local c, h = getChar(), getHRP()
            if c and h then
                local pos = h.Position
                local inArena = BX.inBossArena and BX.inBossArena()
                -- In the arena the raycast IS the boundary test; the corridor
                -- bounds are main-map numbers and meaningless at x = -15000.
                local gy = inArena and BX.groundAt(pos) or solidGroundY(pos)
                -- BOUNDS ARE NOT THE TEST. GROUND IS.
                --
                -- The corridor box is X 430..5070, Z -455..-285, and plenty of
                -- legitimate ground sits outside it - the log has
                -- "voidwatch: off the map at (597, 71, -324) - pulled back",
                -- which is solid floor a few studs from the safe zone. Every
                -- one of those was a teleport backwards for no reason, and it
                -- is the "sometimes tps back".
                --
                -- A downward ray already answers the only question that
                -- matters. The box is kept purely as a far-outside sanity
                -- check, widened so it cannot fire on real floor.
                local outside = (not inArena) and
                    (pos.X < K.CORRIDOR_X_MIN - K.VOID_BOUNDS_SLACK
                     or pos.X > K.CORRIDOR_X_MAX + K.VOID_BOUNDS_SLACK) or false
                if gy and not outside and math.abs(pos.Y - gy) <= K.MODEL_MOVE_MAX_RISE then
                    anchor = Vector3.new(pos.X, gy, pos.Z)
                    BX.voidMisses = 0
                end

                -- ONE MISSED RAYCAST IS NOT A FALL.
                --
                -- This fired on `not gy` alone, and solidGroundY returns nil
                -- for perfectly ordinary reasons - standing on a nest, inside
                -- the support pad, a ray that starts inside geometry. Measured
                -- live during a rift run:
                --     35.35 arc: prime 92 studs           <- Forest prime, fine
                --     35.45 voidwatch: off the map at (600, 71, -333)
                -- (600, 71, -333) is solid floor next to the safe zone. It
                -- teleported us home mid-prime, which is the "Forest part bugs
                -- out": the prime never finished because we were dragged off it.
                --
                -- Falling is not subtle. It needs BOTH a run of failed probes
                -- AND real evidence - we are well below the last ground we
                -- stood on, or genuinely outside the map.
                local falling = anchor and (pos.Y < anchor.Y - K.VOID_DROP_PROOF)
                if (not gy) or outside then
                    BX.voidMisses = (BX.voidMisses or 0) + 1
                else
                    BX.voidMisses = 0
                end

                if (BX.voidMisses or 0) >= K.VOID_MISSES_NEEDED and (falling or outside) then
                    BX.voidMisses = 0
                    local back = anchor
                        or (inArena and BX.arenaCentre and BX.arenaCentre())
                        or select(1, BX.safeZonePos())
                    if back then
                        BX.voidSaves = (BX.voidSaves or 0) + 1
                        pcall(function()
                            h.AssemblyLinearVelocity = Vector3.zero
                            h.AssemblyAngularVelocity = Vector3.zero
                            c:MoveTo(back)
                            h.CFrame = CFrame.new(back)
                        end)
                        trace(("voidwatch: off the map at (%.0f, %.0f, %.0f) - pulled back (#%d)")
                            :format(pos.X, pos.Y, pos.Z, BX.voidSaves))
                        task.wait(0.3)
                    end
                end
            end
        end
        BX.voidWatchThread = nil
    end)
end

function BX.stopVoidWatch()
    local t = BX.voidWatchThread
    BX.voidWatchThread = nil
    if t then pcall(task.cancel, t) end
end

K.PIN_TARGET = Vector3.new(546.8, 70.6, -364.6)
K.PIN_FLOAT = 6.7
K.PIN_HOLD = 6.0        -- how long to stay pinned waiting for the claim

function BX.pinDeliver()
    local part = workspace:FindFirstChild("SpawnLocation", true)
    if not (part and part:IsA("BasePart")) then
        trace("pin: no SpawnLocation in Workspace")
        return false
    end

    local homeCF, hadCollide, hadAnchor = part.CFrame, part.CanCollide, part.Anchored
    part.CanCollide = false

    local target = CFrame.new(K.PIN_TARGET)
    local lift = Vector3.new(0, K.PIN_FLOAT, 0)
    local drop = CFrame.new(0, -K.PIN_FLOAT, 0)
    local startClaim = BX.eggClaimedAt
    local claimed = false

    -- Their exact per-frame body, on Heartbeat, held rather than ridden.
    local conn = RunService.Heartbeat:Connect(function()
        local hrp = getHRP()
        if not hrp or not hrp.Parent then return end
        part.CFrame = hrp.CFrame * drop
        hrp.CFrame = target + lift
        part.CFrame = target
    end)

    trace("pin: holding at the bypass point with SpawnLocation underfoot")
    local deadline = os.clock() + K.PIN_HOLD
    while os.clock() < deadline do
        if BX.eggClaimedAt ~= startClaim then claimed = true break end
        if heldEggUid == nil then break end
        RunService.Heartbeat:Wait()
    end

    pcall(function() conn:Disconnect() end)
    -- Put the map back the way we found it. The shipped builds leave
    -- SpawnLocation parked at the bypass point with collision off, which is
    -- both rude to everyone else in the server and trivially visible.
    pcall(function()
        part.CFrame = homeCF
        part.CanCollide = hadCollide
        part.Anchored = hadAnchor
    end)
    local h = getHRP()
    if h then
        pcall(function()
            h.AssemblyLinearVelocity = Vector3.zero
            h.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    trace(("pin: released after %.1fs - claimed=%s, still carrying=%s")
        :format(K.PIN_HOLD - math.max(deadline - os.clock(), 0),
                tostring(claimed), tostring(heldEggUid ~= nil)))
    return claimed
end

---------- MANUAL CARRY RECORDER ----------
--
-- Ground truth, because inference has run out. Every theory this session has
-- Passive: it never moves the character and never touches a remote. It arms
-- itself whenever a carry begins - including with Auto Steal OFF - samples the
BX.manual = { on = false }

function BX.armManualWatch()
    if BX.manualConn then return end
    local m = BX.manual

    local function start(uid)
        m.on = true
        m.uid = uid
        m.t0 = os.clock()
        m.auto = stealing == true
        m.samples = 0
        m.maxRate = 0
        local h = getHRP()
        m.from = h and h.Position or nil
        trace(("MANUAL: carry started (autoSteal=%s) uid=%s")
            :format(tostring(m.auto), tostring(uid):sub(1, 12)))
    end

    local function finish(how)
        if not m.on then return end
        m.on = false
        local h = getHRP()
        local pos = h and h.Position
        local sl = workspace:FindFirstChildOfClass("SpawnLocation")
        local dSpawn = (pos and sl) and Vector3.new(pos.X - sl.Position.X, 0,
                                       pos.Z - sl.Position.Z).Magnitude or -1
        local home = nil
        pcall(function() home = BX.plotDeliverPos() end)
        local dHome = (pos and typeof(home) == "Vector3")
            and Vector3.new(pos.X - home.X, 0, pos.Z - home.Z).Magnitude or -1
        trace(("MANUAL RESULT: %s | autoSteal=%s | %.2fs | ended %.0f from plot, %.0f from SpawnLocation | peak %.0f studs/s")
            :format(tostring(how), tostring(m.auto), os.clock() - (m.t0 or os.clock()),
                    dHome, dSpawn, m.maxRate or 0))
    end

    pcall(function()
        BX.manualCarryConn = EggState.CarryChanged:Connect(function(info)
            if type(info) ~= "table" then return end
            if info.IsCarrying then start(info.Uid) else finish("carry ended") end
        end)
    end)
    pcall(function()
        BX.manualClaimConn = EggState.FieldClaimed:Connect(function()
            if BX.manual.on then finish("CLAIMED - delivery accepted") end
        end)
    end)
    pcall(function()
        local raise = RS.Packages.Networking:FindFirstChild("RE/Alerts/Raise")
        if raise then
            BX.manualAlertConn = raise.OnClientEvent:Connect(function(...)
                if not BX.manual.on then return end
                for i = 1, select("#", ...) do
                    local v = select(i, ...)
                    if type(v) == "table" and type(v.Message) == "string"
                       and v.Message:find("returned to its nest") then
                        finish("REFUSED - " .. v.Message)
                    end
                end
            end)
        end
    end)

    local last, lastT = nil, 0
    BX.manualConn = RunService.Heartbeat:Connect(function()
        if not BX.manual.on then last = nil return end
        local now = os.clock()
        if now - lastT < 0.25 then return end
        local dt = now - lastT
        lastT = now
        local h, hm = getHRP(), getHumanoid()
        if not h or not hm then return end
        if last then
            local rate = ((h.Position - last) * Vector3.new(1, 0, 1)).Magnitude / dt
            if rate > (BX.manual.maxRate or 0) then BX.manual.maxRate = rate end
            local home = nil
            pcall(function() home = BX.plotDeliverPos() end)
            local dHome = (typeof(home) == "Vector3")
                and Vector3.new(h.Position.X - home.X, 0, h.Position.Z - home.Z).Magnitude or -1
            trace(("MANUAL: rate=%.0f ws=%.1f vel=%.0f | %.0f from plot | %.1fs")
                :format(rate, hm.WalkSpeed,
                        (h.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude,
                        dHome, now - (BX.manual.t0 or now)))
        end
        last = h.Position
    end)
    trace("MANUAL: recorder armed - steal one egg by hand with Auto Steal OFF")
end

---------- TAKE THE HIT, KEEP THE EGG ----------
--
-- "Make it hit by guard first." I wrote that off as ragdoll grace and never
--   * A guard rouses 0.6s after EVERY steal - "RE/GuardPatrol/Rouse" is in
-- We were not blocking either, which is why taking a hit would have simply
BX.dropBlocked = false

K.DROP_ALWAYS_ALLOW = { PlayerRequest = true }

function BX.dropAllowed(reason)
    if not stealing then return true end
    if reason and K.DROP_ALWAYS_ALLOW[reason] then return true end
    return false
end

function BX.blockEggDrop()
    if BX.dropBlocked then return end
    local ok = pcall(function()
        -- 1. The client-side helper.
        local orig = EggState.DropFieldEgg
        if type(orig) == "function" then
            EggState.DropFieldEgg = function(reason, ...)
                if not BX.dropAllowed(reason) then
                    trace("drop: refused " .. tostring(reason) .. " - keeping the egg")
                    return
                end
                return orig(reason, ...)
            end
        end

        -- 2. The remote it ultimately drives. Some builds call this directly,
        --    so blocking only the helper leaves a hole.
        local ew = Remotes and Remotes.EggWorld
        local ask = ew and ew.AskFieldEggDrop
        local inst = (typeof(ask) == "Instance") and ask
            or (type(ask) == "table" and ask.Remote)
        if inst and typeof(inst) == "Instance" and not BX.dropProxy then
            BX.dropProxy = true
            ew.AskFieldEggDrop = setmetatable({
                InvokeServer = function(_, payload, ...)
                    local reason = type(payload) == "table" and payload.Reason
                    if not BX.dropAllowed(reason) then
                        trace("drop: refused remote " .. tostring(reason or "?"))
                        return
                    end
                    return inst:InvokeServer(payload, ...)
                end,
            }, { __index = inst })
        end
    end)
    BX.dropBlocked = ok and true or false
    trace("drop: guard-hit drop " .. (BX.dropBlocked and "BLOCKED" or "block FAILED"))
    return BX.dropBlocked
end

-- Stand and let the roused guard reach us, so the chase resolves before we
-- leave with the egg. Bounded: if no hit lands we carry on regardless, because
-- standing next to a nest forever is worse than an unresolved chase.
K.HIT_WAIT = 3.0
-- The guard's waking time, read from the game rather than guessed:
--     GuardChasePolicy.GetWakingDuration() -> 0.63
K.WAKE_WINDOW = 0.63
K.WAKE_PAD = 0.35

function BX.wakeDelay()
    local d = K.WAKE_WINDOW
    pcall(function()
        local GCP = require(RS.Shared.Modules.GuardAreas.GuardChasePolicy)
        local v = GCP and GCP.GetWakingDuration and GCP.GetWakingDuration()
        if type(v) == "number" and v > 0 then d = v end
    end)
    return d + K.WAKE_PAD
end

function BX.waitOutWake()
    local since = BX.carryStartedAt or BX.carryConfirmedAt
    if not since then return end
    local need = BX.wakeDelay()
    local waited = os.clock() - since
    if waited >= need then
        trace(("wake: already %.2fs since the steal, no dwell needed"):format(waited))
        return
    end
    trace(("wake: holding %.2fs more for the run-back wake delay (%.2fs)")
        :format(need - waited, need))
    local deadline = since + need
    while os.clock() < deadline do
        if heldEggUid == nil then
            trace("wake: carry ended during the dwell")
            return
        end
        RunService.Heartbeat:Wait()
    end
end

-- BAIT THE HIT BEFORE THE STEAL, NOT AFTER IT.
--
-- every time at ~0.81s. Same hit, opposite outcome, purely because of ordering.
K.BAIT_HIT = false   -- see the re-grab note; standing empty-handed provokes nothing
K.BAIT_WAIT = 4.0        -- give the guard time to actually walk over
K.BAIT_RAGDOLL_WAIT = 5.0

function BX.baitGuardHit()
    if not K.BAIT_HIT then return false end
    if heldEggUid then return false end          -- never with an egg in hand
    local before = BX.lastGuardHitAt or 0
    local t0 = os.clock()
    local deadline = t0 + K.BAIT_WAIT
    trace("bait: standing empty-handed to draw the guard's hit before stealing")
    while os.clock() < deadline do
        if not stealing then return false end
        if (BX.lastGuardHitAt or 0) > before then
            trace(("bait: hit taken after %.2fs - guard has had its go, stealing now")
                :format(os.clock() - t0))
            BX.waitForRagdollEnd(K.BAIT_RAGDOLL_WAIT)
            BX.lastBaitAt = os.clock()
            return true
        end
        RunService.Heartbeat:Wait()
    end
    trace(("bait: no hit inside %.1fs - stealing anyway"):format(K.BAIT_WAIT))
    return false
end

K.REGRAB_ARRIVE = 5

-- STEAL -> RAGDOLL -> HOME.
--
-- STEAL_RAGDOLL_WAIT is how long to stand waiting for a guard that may never
K.STEAL_RAGDOLL_WAIT = 3.0
K.STEAL_RAGDOLL_HOLD = 6.0

-- How close the guard has to be, as a multiple of its own HitDistance, before
-- we stop waiting for the hit and just leave. Read off the recording: at Titan
-- Temple (HitDistance 7) the guard was on top of us as the steal landed and
-- the egg was gone within a second. 0 = always wait, math.huge = never wait.
-- the "get ragdolled" step was silently never performed. The guard sits AT the
-- is a few studs - against a threshold of HitDistance * 3, which is 7.5 studs
-- That is why it stopped working: the version that banked eggs waited for the
-- never wait at all.
K.HIT_WAIT_SKIP_MULT = 0


-- How long to keep hammering the carry after the knockdown, from where we
-- stand, before giving up and walking back to the egg instead.
K.RESTEAL_WINDOW = 3.0

-- How far to look for a replacement egg when our uid stops existing.
K.RESTEAL_RETARGET_DIST = 40

-- With Anti Hit armed we stand back up ourselves, so there is no reason to sit
-- out the server's full ragdoll. Without it we wait for the real EndRagdoll.
K.ANTIHIT_RAGDOLL_WAIT = 1.0

-- The furthest teleport the SERVER actually adopts. Measured on this account:
-- 100 and 200 studs are kept, 400 and 800 are reverted within ~0.3s, and a
K.TP_MAX_ADOPTED = 200
-- How long to let the server agree with an outbound teleport before deciding
-- it refused, and how close counts as landed.
K.TP_SETTLE = 0.35
K.TP_LANDED = 30
-- The outbound teleport. ON: instant TP to the egg, falling back to the arc
-- tween only when the server refuses a jump (see the note at the outbound
-- leg for how often that happens).
K.OUTBOUND_TP = true
-- After landing, how long to let the game hand a prompt to the egg before
-- grabbing anyway. The guard's waking window is 0.63s and this runs BEFORE the
-- steal, so it costs nothing from that budget.
K.TP_PROMPT_WAIT = 1.2
-- How long to idle before rescanning when nothing matches the filters. Long
-- enough that waiting is free, short enough to catch a respawn quickly.
K.IDLE_RESCAN = 4
-- Auto refresh: how often to look at the field, and the shortest gap between
-- two rebuilds. The poll is nearly free; the rebuild is the part worth rating.
K.AUTO_REFRESH_POLL = 3
K.AUTO_REFRESH_GAP = 15


-- Where the egg is right now, whatever state it is in.
-- HOW FAR THIS AREA'S GUARD CAN REACH. Data.Guards.Directory, measured:
function BX.guardHitRange(areaId)
    local hd = 7
    pcall(function()
        local gd = require(RS.Data.Guards).Directory[
            require(RS.Data.Areas).Directory[areaId].GuardId]
        if gd and tonumber(gd.HitDistance) then hd = tonumber(gd.HitDistance) end
    end)
    return hd
end

function BX.stepOutOfGuardReach(areaId)
    local g = BX.findAreaGuard(areaId)
    local part = g and BX.guardAnchorPart(g)
    local h = getHRP()
    if not part or not h then return false end
    -- HOW FAR TO BACK OFF, AND WHY IT IS NOT "AS FAR AS POSSIBLE".
    --
    --     if GuardDistance.XZ(guard, target) <= ResolveHitDistance(HitDistance)
    -- What there IS, is a speed curve. GuardChasePolicy.ResolveWalkSpeed:
    -- with ref = FlatRadius = 20 for every guard. So inside 20 studs the guard
    local reach = BX.guardHitRange(areaId)
    local want = math.min(reach + 8, K.GUARD_FLAT_RADIUS - 2)
    if want <= reach + 2 then want = reach + 8 end
    if (part.Position - h.Position).Magnitude >= want then return false end

    -- NEVER STEP SOMEWHERE THERE IS NO FLOOR.
    --
    -- beyond it, which is why it only threw us into the void out there.
    -- height AND sits inside the measured walkable band. Directly away from the
    local away = Vector3.new(h.Position.X - part.Position.X, 0, h.Position.Z - part.Position.Z)
    local base = away.Magnitude > 0.5 and away.Unit or Vector3.new(-1, 0, 0)

    for i = 0, 7 do
        -- 0, then +/-45, +/-90 ... around the guard.
        local ang = (i == 0) and 0 or (math.pi / 4) * math.ceil(i / 2) * ((i % 2 == 0) and 1 or -1)
        local dir = Vector3.new(
            base.X * math.cos(ang) - base.Z * math.sin(ang), 0,
            base.X * math.sin(ang) + base.Z * math.cos(ang))
        local spot = part.Position + dir * want

        local inBand = spot.Z >= K.WALL_SAFE_Z_MIN and spot.Z <= K.WALL_SAFE_Z_MAX
            and spot.X >= K.CORRIDOR_X_MIN and spot.X <= K.CORRIDOR_X_MAX
        if inBand then
            local gy = solidGroundY(spot)
            -- Same floor we are standing on, not a wall top and not a drop.
            if gy and math.abs(gy - h.Position.Y) <= 10 then
                local c = getChar()
                if c then
                    pcall(function() c:MoveTo(Vector3.new(spot.X, gy, spot.Z)) end)
                    local hh = getHRP()
                    if hh then
                        hh.AssemblyLinearVelocity = Vector3.zero
                        hh.AssemblyAngularVelocity = Vector3.zero
                    end
                end
                trace(("guard: backed off %.0f studs (reach %.0f, floor at %.0f)")
                    :format(want, reach, gy))
                return true
            end
        end
    end

    trace("guard: nowhere safe to back off to - staying put")
    return false
end

function BX.guardStatus(areaId)
    local g = BX.findAreaGuard(areaId)
    if not g then return nil end
    local st = g:GetAttribute("GuardState")
    local target = g:GetAttribute("TargetPlayer")
    return tostring(st or "?"), tostring(target or ""), (g:GetAttribute("Sleeping") == true)
end

-- KEEP DISTANCE FOR AS LONG AS WE ARE WAITING, not once.
--
-- the safe zone, and on its WALK BACK to the nest it passes us - and because we
K.GUARD_WATCH_GAP = 0.35
-- Data.Guards: every guard has FlatRadius = 20. Inside it they move at base
-- speed; outside it they accelerate toward base * 4.
K.GUARD_FLAT_RADIUS = 20

function BX.holdGuardDistance(areaId, untilClock)
    local nextCheck = 0
    while stealing and os.clock() < untilClock do
        if os.clock() >= nextCheck then
            nextCheck = os.clock() + K.GUARD_WATCH_GAP
            if not isRagdolled() then
                local g = BX.findAreaGuard(areaId)
                local part = g and BX.guardAnchorPart(g)
                local h = getHRP()
                if part and h then
                    local reach = BX.guardHitRange(areaId)
                    -- A moving guard needs more room than a parked one: give it
                    -- the distance it can cover before we look again.
                    local hum = g:FindFirstChildOfClass("Humanoid")
                    local closing = (hum and hum.WalkSpeed or 0) * K.GUARD_WATCH_GAP
                    if (part.Position - h.Position).Magnitude <= reach + 6 + closing then
                        BX.stepOutOfGuardReach(areaId)
                    end
                end
            end
        end
        RunService.Heartbeat:Wait()
    end
end

function BX.eggPosNow(uid)
    local rec
    pcall(function()
        rec = EggState and EggState.ReadFieldEgg and EggState.ReadFieldEgg(uid)
    end)
    if type(rec) ~= "table" then return nil, nil end
    local pos = rec.BoundsCFrame and rec.BoundsCFrame.Position
    return pos, rec.State
end

-- Go back to a dropped egg and take it again. Returns true if it is in hand.
--
-- Two things have to be waited out first, both measured:
--   14.44 DROP: carry ended, 0.84s after the steal
-- 1. The field record lags the drop. Reading it 0.02s later still shows the old
K.REGRAB_WAIT = 8.0
-- Longest the grab will stand on a nest waiting for the server's hold to
-- clear. The hold is 2.5s, but the trip has usually eaten most of it by
-- the time we arrive; this caps the worst case.
-- THIS 0.8 IS WHY FARM AND RIFT ARRIVE AND NEVER GRAB.
--
-- Straight out of a failing Titan Temple run:
--
--     59.66  loop: ARC to the egg (4205 studs)
--     59.66  tp: outbound -> 4801,71,-333        <- instant, we are there
--     60.28  carry: remote refused - Cannot carry eggs while knocked down
--     60.28  carry: server still holds us 1.69s - waiting 0.80s
--     61.36  carry: fired prompt at 0.8 studs -> true
--     61.52  carry: prompt fired but state is Slot - retrying
--     61.55  ... 61.73 ...  three fires, every one refused
--     61.91  loop: carried=false
--     62.12  ragdoll: END after 2.5s             <- 0.21s AFTER we gave up
--
-- The server told us exactly how long it was holding us - 1.69s - and this
-- clamped the wait to 0.80. So every prompt was fired inside the knockdown,
-- was refused for that reason, and the loop gave up two tenths of a second
-- before it would have worked. Then it flew home and did the whole thing
-- again.
--
-- The comment that used to be here said the hold "has almost always expired
-- before we arrive". That was true when the outbound leg was a 4000-stud
-- tween. It stopped being true the moment the outbound became an instant
-- teleport: we now land about 0.6s into a 2.5s knockdown, so there is up to
-- 1.9s left to sit out. The same thing has always bitten rift, for the same
-- reason - rift takes whichever pet is out, which is usually a short trip.
--
-- The knockdown is a bounded quantity the server publishes, at most 2.5s. So
-- cover it. The loop below still breaks the instant the hold clears, so a
-- normal long carry waits nothing at all; this ceiling only exists to stop a
-- bad clock reading parking us here forever.
K.GRAB_HOLD_MAX = 2.75
-- The server needs a moment to actually release us after its own countdown
-- expires; without this the first grab lands inside the tail of the knockdown.
K.GRAB_HOLD_GRACE = 0.25
-- How long to wait for EggState to report Carried before calling an attempt
-- failed. Was 0.12s, which with a 0.03s gap fitted three whole attempts into
-- half a second - fast enough to burn every try on one slow server reply.
-- THE WHOLE GRAB HAS TO FIT INSIDE THE GUARD'S WAKE TIME.
--
-- GuardChasePolicy.GetWakingDuration is 0.63s. I had this at 0.20 x 4 =
-- 0.92s, plus the hold grace - over a second stood on a nest, which is long
-- enough for the guard to wake and take the egg straight back. Reported as
-- "a bit slow when it takes the egg which makes me lose the egg".
K.GRAB_CONFIRM = 0.14
K.GRAB_TRIES = 3

K.REGRAB_RAGDOLL_WAIT = 6.0
-- How long to let the incoming knockdown register. Measured gap between the
-- drop and BeginRagdoll: 0.04-0.06s.
K.REGRAB_SETTLE = 0.08
-- How often to re-read the egg record while waiting for it to become takeable.
-- The old 0.1 added up to a fifth of a second of pure polling latency per
-- cycle for no benefit - the record is a local table read.
-- A dropped egg is usually being walked home by a guard, so expect to need
-- more than one go at it.
K.REGRAB_TRIES = 4
K.REGRAB_POLL = 0.03
K.REGRAB_HOP_MAX = 60
-- How long to keep waiting for YOUR chosen egg while it is unavailable (being
-- carried back by a guard, mid-steal by someone else, etc). Generous, because
-- a normal cycle makes it unavailable for several seconds by design.
K.SELECTED_HOLD = 30
K.SELECTED_POLL = 0.3

-- Put the humanoid back in a state that can actually move and grab. The
-- ragdoll leaves it PlatformStanding / in Physics, and firing a prompt or
-- stepping a model in that state is where the glitchiness came from.
function BX.readyAfterRagdoll()
    local hm, h = getHumanoid(), getHRP()
    if not hm or not h then return end
    pcall(function()
        hm.PlatformStand = false
        hm.Sit = false
        hm.AutoRotate = true
        local st = hm:GetState()
        if st == Enum.HumanoidStateType.Physics
           or st == Enum.HumanoidStateType.PlatformStanding
           or st == Enum.HumanoidStateType.FallingDown
           or st == Enum.HumanoidStateType.Ragdoll
           or st == Enum.HumanoidStateType.Seated then
            hm:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
        h.AssemblyLinearVelocity = Vector3.zero
        h.AssemblyAngularVelocity = Vector3.zero
    end)
end

---------- ANTI HIT ----------

-- WHAT THIS CAN AND CANNOT DO, verified against the live game.
--
-- THE BUG THIS FIXES, and it is why Anti Hit did nothing at all. The old
-- This game never enters Ragdoll or FallingDown. Anti Hit was watching for
-- something that never happens, and its stand-up branch tested the same two
-- states, so it never fired either.
-- AND DISABLING STATES IS POINTLESS ANYWAY. Measured on the live client:
-- WHY THIS IS NOT A PLAIN MAGNITUDE TEST ANY MORE - THE JUMP BUG.
K.ANTIHIT_RISE = 150       -- upward studs/s that no legal jump can produce
K.ANTIHIT_FLAT_MULT = 2.5  -- flat speed over WalkSpeed * this = not our doing
K.ANTIHIT_FLAT_MIN = 150   -- ...but never react below this, whatever WalkSpeed is
K.ANTIHIT_JOINT_GAP = 0.25 -- seconds between Motor6D sweeps (they are not free)
BX.antiHitEnabled = true

-- How much of the server's knockdown is left. The carry remote is refused
-- until this reaches zero, so anything wanting to steal should WAIT on it
-- rather than hammer and collect refusals.
function BX.ragdollRemaining()
    local left = 0
    if BX.ragdollEndsAt then left = math.max(left, BX.ragdollEndsAt - os.clock()) end
    -- The bat/slap path publishes an explicit attribute instead, on the server
    -- clock. BatController.Server:
    --     u4:SetAttribute("RagdollEndTime", workspace:GetServerTimeNow() + v13)
    pcall(function()
        local t = LocalPlayer:GetAttribute("RagdollEndTime")
        if type(t) == "number" then
            left = math.max(left, t - workspace:GetServerTimeNow())
        end
    end)
    return math.max(0, left)
end

function BX.startAntiHit()
    if BX.antiHitConn or not BX.antiHitEnabled then return end
    BX.antiHitBlocked = 0
    BX.antiHitUps = 0
    BX.antiHitJointAt = 0
    BX.antiHitConn = RunService.Heartbeat:Connect(function()
        local hum, hrp = getHumanoid(), getHRP()
        if not hum or not hrp then return end

        -- CANCEL THE LAUNCH. The BeginRagdoll payload carries an impulse - the
        -- one in the trace had Y = +791 - and the server applies it with
        -- jump, or flat faster than our own WalkSpeed could ever produce.
        if BX.jumping() then return end

        local v = hrp.AssemblyLinearVelocity
        local flat = (v * Vector3.new(1, 0, 1)).Magnitude
        local flatCap = math.max((hum.WalkSpeed or 16) * K.ANTIHIT_FLAT_MULT,
                                 K.ANTIHIT_FLAT_MIN)
        if v.Y > K.ANTIHIT_RISE or flat > flatCap then
            -- Keep the flat motion we can account for; only the part we
            -- cannot explain is removed. Zeroing everything is what froze
            -- ordinary walking as well as jumping.
            local keep = Vector3.zero
            if flat > 0.001 then
                keep = (v * Vector3.new(1, 0, 1)).Unit * math.min(flat, hum.WalkSpeed or 16)
            end
            hrp.AssemblyLinearVelocity = Vector3.new(keep.X, math.min(v.Y, 0), keep.Z)
            hrp.AssemblyAngularVelocity = Vector3.zero
            BX.antiHitBlocked = (BX.antiHitBlocked or 0) + 1
            if BX.antiHitBlocked <= 3 or BX.antiHitBlocked % 20 == 0 then
                trace(("antihit: cancelled a launch (up %.0f, flat %.0f vs cap %.0f) (#%d)")
                    :format(v.Y, flat, flatCap, BX.antiHitBlocked))
            end
        end

        -- STAND BACK UP. Physics is the state this game puts us in - see the
        -- note above - so that is what is tested here. Testing only Ragdoll and
        -- FallingDown, as this did, meant this branch never ran once.
        local st = hum:GetState()
        if hum.PlatformStand or hum.Sit
           or st == Enum.HumanoidStateType.Physics
           or st == Enum.HumanoidStateType.Ragdoll
           or st == Enum.HumanoidStateType.FallingDown
           or st == Enum.HumanoidStateType.PlatformStanding then
            pcall(function()
                hum.PlatformStand = false
                hum.Sit = false
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end)
            BX.antiHitUps = (BX.antiHitUps or 0) + 1
            -- A ragdoll unbinds the rig's joints (RagdollJoints.Bind); without
            -- these the character stays a heap on the floor whatever state we
            -- ask for.
            local now = os.clock()
            if now - (BX.antiHitJointAt or 0) > K.ANTIHIT_JOINT_GAP then
                BX.antiHitJointAt = now
                local char = getChar()
                if char then
                    for _, d in ipairs(char:GetDescendants()) do
                        if d:IsA("Motor6D") and not d.Enabled then d.Enabled = true end
                    end
                end
            end
        end
    end)
    trace("antihit: ARMED (watching Physics/PlatformStand - what this game actually uses)")
end

function BX.stopAntiHit()
    if not BX.antiHitConn then return end
    pcall(function() BX.antiHitConn:Disconnect() end)
    BX.antiHitConn = nil
    trace(("antihit: off (%d launches cancelled, %d stand-ups)")
        :format(BX.antiHitBlocked or 0, BX.antiHitUps or 0))
end

function BX.nearestGrabbableEgg(maxDist)
    local h = getHRP()
    if not h then return nil end
    local best, bestD
    pcall(function()
        for _, rec in pairs(EggState.ReadFieldEggs().Records) do
            if (rec.State == "Slot" or rec.State == "Dropped")
               and typeof(rec.BoundsCFrame) == "CFrame" then
                local p = rec.BoundsCFrame.Position
                local d = (p - h.Position).Magnitude
                if d <= (maxDist or 40) and (not bestD or d < bestD) then
                    best, bestD = rec, d
                end
            end
        end
    end)
    return best, bestD
end

function BX.regrabEgg(uid, slotKey)
    -- Let the knockdown register before testing for it. The trace shows the
    -- drop at 14.44 and BeginRagdoll at 14.50 - checking in between sees a
    -- character that is not ragdolled yet and waits for nothing. 0.06s is
    task.wait(K.REGRAB_SETTLE)

    -- Knockdown first: "Cannot carry eggs while knocked down" is the server's
    -- own refusal text, so there is no point asking until it is over. Prefer
    -- the duration the server actually sent over waiting on our own flags.
    do
        local left = BX.ragdollRemaining()
        if left > 0 then
            trace(("regrab: knocked down for another %.2fs - waiting it out"):format(left))
            local until_ = os.clock() + math.min(left, K.REGRAB_RAGDOLL_WAIT) + 0.05
            while os.clock() < until_ do RunService.Heartbeat:Wait() end
        end
    end
    if BX.ragdollActive then
        trace("regrab: still down - waiting for the server to release us")
    end
    BX.waitForRagdollEnd(K.REGRAB_RAGDOLL_WAIT)
    -- ...and the server's own hold, which the line above cannot see.
    BX.waitForCarryAllowed(K.REGRAB_RAGDOLL_WAIT)

    -- Then wait for the egg to actually be takeable again. Straight after the
    -- drop the record is stale, and if a guard is walking it back it reads
    -- GuardCarried until it is deposited.
    local deadline = os.clock() + K.REGRAB_WAIT
    local pos, st
    local logged
    repeat
        pos, st = BX.eggPosNow(uid)
        if st == "Claimed" then
            trace("regrab: egg is Claimed - it actually banked")
            return false
        end
        if st == nil then
            trace("regrab: egg record gone")
            return false
        end
        if st == "Slot" or st == "Dropped" then break end
        if st ~= logged then
            logged = st
            trace(("regrab: egg is %s - waiting for it to settle"):format(tostring(st)))
        end
        task.wait(K.REGRAB_POLL)
    until os.clock() > deadline

    if st ~= "Slot" and st ~= "Dropped" then
        trace(("regrab: gave up, egg still %s after %.1fs"):format(tostring(st), K.REGRAB_WAIT))
        return false
    end
    if not pos then
        trace("regrab: no position on the record")
        return false
    end

    -- Stand the character back up before moving it. Stepping a model that is
    -- still PlatformStanding from the ragdoll is what looked like a glitch.
    BX.readyAfterRagdoll()

    local h = getHRP()
    local d = h and (pos - h.Position).Magnitude or 0
    trace(("regrab: %s is %s, %.0f studs away - going back for it")
        :format(tostring(uid), tostring(st), d))

    -- CHASE IT, DO NOT AIM AT WHERE IT WAS.
    --
    -- The position was read once, before travelling. A dropped egg does not
    -- stay put: a guard picks it up and walks it back to its nest, so by the
    -- time we arrive the record has moved and the carry is refused for range
    -- forever. That is the "it goes for the dropped egg and never picks it
    -- up".
    --
    -- So re-read the record every attempt, close whatever gap is there NOW,
    -- and only then ask. Several goes, because the egg is moving and one of
    -- them will land.
    for attempt = 1, K.REGRAB_TRIES do
        local pNow, sNow = BX.eggPosNow(uid)
        if sNow == "Claimed" then
            trace("regrab: egg banked while we were on the way")
            return false
        end
        if not pNow then
            trace("regrab: record gone while we were on the way")
            return false
        end

        local hh = getHRP()
        local gap = hh and Vector3.new(pNow.X - hh.Position.X, 0, pNow.Z - hh.Position.Z).Magnitude or 9999

        if gap > K.REGRAB_HOP_MAX then
            BX.arcTweenTo(pNow, K.ARC_SPEED, "regrab", K.REGRAB_ARRIVE)
        elseif gap > 2 then
            -- Close: put us on it outright rather than nudging.
            local c = getChar()
            local gy = solidGroundY(pNow) or (pNow.Y + 2)
            if c then
                pcall(function() c:PivotTo(CFrame.new(pNow.X, gy, pNow.Z)) end)
                local h2 = getHRP()
                if h2 then
                    h2.AssemblyLinearVelocity = Vector3.zero
                    h2.AssemblyAngularVelocity = Vector3.zero
                end
            end
            RunService.Heartbeat:Wait()
        end

        -- Getting back can earn another hit.
        if BX.ragdollActive or isRagdolled() then
            BX.waitForRagdollEnd(K.REGRAB_RAGDOLL_WAIT)
        end
        BX.readyAfterRagdoll()

        if carryEgg(uid, slotKey) == true then
            trace(("regrab: got it back on attempt %d"):format(attempt))
            return true
        end

        local h3 = getHRP()
        local p3 = select(1, BX.eggPosNow(uid))
        trace(("regrab: attempt %d failed, egg now %.0f studs away")
            :format(attempt, (h3 and p3) and (p3 - h3.Position).Magnitude or -1))
        task.wait(K.REGRAB_POLL)
    end

    trace(("regrab: gave up after %d attempts"):format(K.REGRAB_TRIES))
    return false
end

-- ARE WE ACTUALLY CARRYING? ASK THE GAME, NOT OUR OWN FLAG.
--
-- heldEggUid is set by the CALLERS of carryEgg, never by carryEgg itself, and
-- the drop watch clears it the moment the server ends a carry. So there is a
-- window where the game has handed us an egg but our flag says otherwise -
-- and the return leg is gated on that flag:
--     if heldEggUid then BX.returnToSafe() end
-- Miss it and you stand on the nest holding an egg, going nowhere. That is
-- the "it picked it up and never went to the safe zone".
--
-- EggState is the authority. Returns the uid we are holding, or nil.
-- Same answer as it always gave: the first Carried egg on the map. The only
-- addition is BX.carryMute - eggs the steal loop has given up delivering for
-- 15s after three instant, unclaimed trips home (see the "still carrying"
-- block in the steal loop). That is what stops the frozen-client spin; the
-- steal decisions themselves are untouched.
BX.carryMute = {}
function BX.carryingUid()
    local found
    pcall(function()
        if not (EggState and EggState.ReadFieldEggs) then return end
        local data = EggState.ReadFieldEggs()
        local now = os.clock()
        for _, rec in pairs(data and data.Records or {}) do
            if rec.State == "Carried" and not ((BX.carryMute[rec.Uid] or 0) > now) then
                found = rec.Uid
                break
            end
        end
    end)
    return found
end

function BX.takeGuardHit()
    if not BX.wantGuardHit then return false end
    if not heldEggUid then return false end
    local before = BX.lastGuardHitAt or 0
    local deadline = os.clock() + K.HIT_WAIT
    trace("hit: waiting for the guard to land one (drop is blocked)")
    while os.clock() < deadline do
        if (BX.lastGuardHitAt or 0) > before then
            trace(("hit: taken after %.2fs - chase resolved, egg still held=%s")
                :format(K.HIT_WAIT - (deadline - os.clock()), tostring(heldEggUid ~= nil)))
            -- Let the ragdoll finish before running, or the first strides are
            -- spent on the floor anyway.
            BX.waitForRagdollEnd(4)
            return true
        end
        RunService.Heartbeat:Wait()
    end
    trace("hit: no guard hit inside " .. tostring(K.HIT_WAIT) .. "s - carrying anyway")
    return false
end

function BX.returnToSafe()
    local SAFE_POS = BX.homePos()
    local hrp = getHRP()
    -- ONLY SHORT-CIRCUIT EMPTY-HANDED. This measured the distance to the PLOT
    -- and returned before doing anything, carrying or not - so a steal that
    -- hand the trip is judged against the safe zone below, never here.
    if hrp and not heldEggUid and (SAFE_POS - hrp.Position).Magnitude < K.SAFE_ARRIVE then
        trace("return: already at safe zone")
        return
    end

    if not heldEggUid then
        BX.waitForRagdollEnd(8)
        BX.groundNow("return")
    end

    -- =====================================================================
    -- WHY THERE IS NO TELEPORT HOME. Direct experiment, carrying a real egg:
    --   t=0.25  distHome=47   eggState=Dropped
    --   t=0.50  distHome=140  eggState=Dropped
    -- Read that carefully: the TELEPORT WORKED - we arrived 47 studs from
    -- carried egg faster than the legality budget sets its State to Dropped,
    -- That is why every "successful" teleport home arrived empty-handed.
    -- WalkSpeed*1.7*0.12 + 14 + 80 it moved ~128 studs per 0.12s, about
    if heldEggUid then
        local uid = heldEggUid
        local uidSlot = heldEggSlotKey   -- kept for a mid-carry regrab

        -- NO DWELL HERE. v98 held still for the run-back wake delay before
        -- moving; the trace above BX.wantGuardHit shows the guard ends the
        -- carry at ~0.81s, so any stationary wait with the egg in hand is

        -- FIRST, before the trip home: clear the bounds inside the 0.63s
        -- waking window. I retired this in v21 after measuring the exit west
        -- at 320-540 studs, but west was the wrong edge - the boxes are only
        -- ~150 deep in Z, so the NEAREST edge is 22-45 studs and clears the
        -- instant the steal lands - the Drop button is already up 0.4s later.
        -- They do not steal, escape, and then look for a ride; the mount IS
        -- want to be standing on - all inside the ~2s window before the guard
        -- This ran after every steal regardless. The cost, measured:
        if not rode and not BX.flyEnabled and not BX.hoverEnabled
           and BX.guardChasingUs(BX.carryAreaId) then
            pcall(BX.guardExitDash, BX.carryAreaId)
        end

        -- LIMIT-FINDER: BX.carrySpeed is driven by a binary search in
        -- BX.tuneCarrySpeed - it climbs after a successful delivery and backs
        -- Seed from the budget the server itself just handed us. Taking an egg
        -- makes the server push its own WalkSpeed down (measured: SetWalkSpeed
        -- maxRecentWalkSpeed * 1.7. Riding at 1.6x leaves a little headroom.
        -- because the ceiling moves with each egg's weight.
        -- "return: CARRYING - probe at 327 studs/s", the same number forever,
        -- never once been allowed to back off. That is the delivery bug.
        -- THIS IS WHY A FAST ACCOUNT LOSES EGGS, AND IT IS TWO BUGS.
        --
        -- The carry leg never used BX.carryFloor() or BX.carrySpeedNow(). It
        -- built its own number:
        --
        --     ws = hum.WalkSpeed
        --     BX.carrySpeed = math.max(BX.carrySpeed or 0, ws * 1.3, 500)
        --     speed = clamp(BX.carrySpeed, 150, K.CARRY_SPEED_CAP)   -- cap 800
        --
        -- FIRST: math.max against its own previous value is a ratchet. It can
        -- only ever go UP. One inflated reading and every carry for the rest of
        -- the session runs at that speed, however many eggs it costs.
        --
        -- SECOND: `ws` is the LIVE Humanoid.WalkSpeed, and the outbound leg's
        -- spoof writes hum.WalkSpeed = speed * 1.35 - up to 4000. Read it while
        -- a spoofed leg is still in flight and ws * 1.3 is thousands, clamped
        -- to 800. So the carry runs at 800 against an anticheat allowance of
        -- about 230, on the longest leg in the game.
        --
        -- A high-speed account meets this sooner: WalkSpeed is capped at 300 by
        -- the game, so ws * 1.3 = 390 on its own, and any spoof residue pushes
        -- it straight to the 800 cap. That is the "3B speed and it still says
        -- delivery failed" - not their speed helping, their speed feeding a
        -- ratchet that was never bounded properly.
        --
        -- The fix is to use the one function that already reasons about this:
        -- BX.carryFloor() knows the account's real walk speed (from the
        -- leaderstat, which the spoof cannot touch), the area's guard floor,
        -- and is capped at the 500 V1 carried at. No ratchet, no live-Humanoid
        -- reading, no 800.
        BX.carrySpeed = BX.carryFloor()
        local speed = math.clamp(BX.carrySpeed, K.CARRY_SPEED_MIN, K.CARRY_FLOOR)
        trace(("return: CARRYING - probe at %.0f studs/s (lo=%s hi=%s)"):format(
            speed, tostring(BX.carryLow and math.floor(BX.carryLow) or "-"),
            tostring(BX.carryHigh and math.floor(BX.carryHigh) or "-")))
        -- ZIGZAG IS FORCE-DISABLED. Reported patched/detected in the live
        -- game, and the weave is exactly the kind of movement that draws a
        -- Relocate. The UI option is left in place but no longer arms it.
        BX.zigzagThisRoute = false

        -- Note when we started so we only count a claim that happens on THIS
        -- trip, not a stale one from earlier.
        pcall(BX.armClaimWatch)
    pcall(BX.armAlertWatch)
    pcall(BX.armCarrySampler)
        local tripStart = os.clock()
        BX.eggClaimedAt = nil

        -- The egg has to reach OUR PLOT. The old code aimed at
        -- Areas.SeparationLine, but that part only spans x 355..749 (it marks
        -- egg's own X and shifting Z by 15 produced a target 24 studs SIDEWAYS
        -- of the nest - measured in the trace as "dist=24". The tween finished
        -- in 0.03s, we stood on the nest, and the guard took the egg 0.6s
        -- Carry at the transport budget, NOT at TWEEN_SPEED. Measured: an 800
        -- studs/s carry completed the whole 3535-stud trip and arrived inside
        -- "NOT claimed - egg state=Slot inPlot=true". The position was never
        local h = getHRP()
        local dist = h and SAFE_POS and (SAFE_POS - h.Position).Magnitude or 0
        if BX.teleportMode then
            -- ONE SHOT BACK TO THE SAFE-ZONE LINE. Not a hold loop, and not
            -- the plot. See the SAFE-ZONE ANCHOR block above for the read of
            -- the reference clip this comes from and why the destination is
            -- What this replaces, and why it was wrong: 3.5s of re-asserting
            -- a computed edge point at the EGG's Z - a spot we had never
            -- stood on - followed by 9s of re-asserting the plot. 12.5s and
            local dest, how = BX.safeReturnCF()
            trace(("return: ONE-SHOT to the safe zone via %s -> %.0f,%.0f,%.0f (was %.0f studs out)")
                :format(how, dest.X, dest.Y, dest.Z, dist))

            local ch = getChar()
            local function put()
                if ch then pcall(function() ch:PivotTo(dest) end) end
                local hh = getHRP()
                if hh then
                    hh.AssemblyLinearVelocity = Vector3.zero
                    hh.AssemblyAngularVelocity = Vector3.zero
                end
            end
            put()

            -- Bounded settle: re-assert only while the server has not
            -- answered, and only for K.SAFE_TP_WINDOW. Past that, more writes
            -- have never once turned into a claim in any trace we have - they
            local claimedOk = false
            local settleEnd = os.clock() + (K.SAFE_TP_WINDOW or 1.2)
            local writes = 1
            while os.clock() < settleEnd do
                if BX.eggClaimedAt and BX.eggClaimedAt >= tripStart then
                    claimedOk = true
                    break
                end
                if not heldEggUid then break end
                put()
                writes = writes + 1
                task.wait(K.SAFE_TP_REASSERT or 0.1)
            end

            -- "IT SAYS DELIVERED AND ALSO FAILED, AND YOU STILL GET THE EGG."
            --
            -- Two verdict paths end a carry and they did not agree. The walk
            -- path treats "we are no longer carrying it AND it is not back on
            -- the field" as delivered:
            --
            --     local carrying, st = BX.stillCarrying(uid)
            --     if not carrying then
            --         if st == nil then claimed = true end
            --     end
            --
            -- This one had no such fallback. It listened for FieldClaimed and
            -- nothing else, for 0.6s. FieldClaimed is a replicated signal, so
            -- on any client where it lands late - or where armClaimWatch never
            -- armed at all - the egg is claimed on the server, the player sees
            -- it appear on their plot, and the hub still says "Delivery failed".
            --
            -- And that verdict has consequences, which is the second half of
            -- the report. The success branch does this:
            --
            --     selectedEggUid = nil
            --     BX.awaitUserPick = true      -- "pick your next one"
            --
            -- The failure branch does not, so the loop keeps the same target
            -- and immediately heads back out for it. Delivered, told it failed,
            -- sent straight back for the egg you already have.
            --
            -- So: same fallback, same question, and the state read is authoritative
            -- where the signal is only advisory.
            if not claimedOk then
                local tail = os.clock() + (K.SAFE_TP_CLAIM_TAIL or 0.6)
                while os.clock() < tail do
                    if BX.eggClaimedAt and BX.eggClaimedAt >= tripStart then
                        claimedOk = true
                        break
                    end
                    local carrying, st2 = BX.stillCarrying(uid)
                    if not carrying and st2 == nil then
                        claimedOk = true
                        trace("return: FieldClaimed never fired, but the egg is off the field"
                            .. " and out of our hands - counting it delivered")
                        break
                    end
                    task.wait(0.05)
                end
            end

            -- The old second leg, kept but off. BX.safeTpPlotFallback = true
            -- restores it if a server ever turns out to need it.
            if not claimedOk and BX.safeTpPlotFallback then
                local homeCF = CFrame.new(SAFE_POS.X, SAFE_POS.Y + 3, SAFE_POS.Z)
                trace("return: safe zone did not claim - falling back to the plot")
                local dl = os.clock() + (K.SAFE_TP_PLOT_WINDOW or 2.5)
                while os.clock() < dl do
                    if ch then pcall(function() ch:PivotTo(homeCF) end) end
                    local h2 = getHRP()
                    if h2 then
                        h2.AssemblyLinearVelocity = Vector3.zero
                        h2.AssemblyAngularVelocity = Vector3.zero
                    end
                    if BX.eggClaimedAt and BX.eggClaimedAt >= tripStart then
                        claimedOk = true
                        break
                    end
                    if not heldEggUid then break end
                    task.wait(0.15)
                end
            end

            trace(("return: teleport delivery claimed=%s (%d position writes, %.2fs door to door)")
                :format(tostring(claimedOk), writes, os.clock() - tripStart))
            if claimedOk then
                BlyxoStealDone()
                heldEggUid = nil
                heldEggSlotKey = nil
                carryLocked = false
                pcall(stopProtect)
                isProtecting = false
            else
                local st
                pcall(function()
                    local rec = EggState and EggState.ReadFieldEgg and EggState.ReadFieldEgg(uid)
                    st = rec and rec.State
                end)
                trace(("return: NOT claimed at the safe zone - egg state=%s"):format(tostring(st)))
                toast("Delivery failed - egg " .. tostring(st or "gone"))
                -- Let go of it either way. Leaving heldEggUid, carryLocked and
                -- the protect thread set after a failed trip means the next
                -- pass starts believing it is still carrying something it is
                -- not, and every check downstream reads that stale state.
                heldEggUid = nil
                heldEggSlotKey = nil
                carryLocked = false
                pcall(stopProtect)
                isProtecting = false
            end
            BX.tuneCarrySpeed(claimedOk and "Claimed" or "Lost", speed)
            return
        end
        -- ROUTE HOME ON THE ESCAPE SIDE, not down the middle.
        --
        -- Measured, v36, a clean Desert steal that still lost the egg:
        --   escape: Desert via edge, 50 studs -> 0.20s      (escape was FINE)
        --   return: carrying HOME at 150 studs/s            (WalkSpeed was 160)
        -- Speed was below our own WalkSpeed, so it was never the transport
        -- budget. buildRoute forces every long leg onto K.CORRIDOR_Z (-370),
        -- The exit corridors are clear of every box and were measured
        local savedCorridorZ = K.CORRIDOR_Z
        if BX.escapeCorridorZ then
            K.CORRIDOR_Z = BX.escapeCorridorZ
            trace(("return: routing home along z=%.0f (clear of the guard boxes)")
                :format(K.CORRIDOR_Z))
        end
        -- Report the speed we will ACTUALLY move at. The fly branch below
        -- ignores `speed` and uses K.FLY_CARRY_SPEED, so this line read
        -- "carrying HOME at 267 studs/s" while the trace two lines later said
        -- "carry home down middle ... (960 studs/s)". Two different numbers
        trace(("return: carrying HOME at %.0f studs/s (dist=%.0f)"):format(
            BX.flyEnabled and K.FLY_CARRY_SPEED or speed, dist))

        -- The outbound leg can leave a relocate on the clock, and cfMoveTo
        -- opens by sleeping out K.RELOCATE_COOLDOWN (3s) before it moves a
        BX.lastRelocate = nil

        -- buildRoute reads K.CORRIDOR_Z synchronously inside cfMoveTo, so it is
        -- restored immediately after the route is built, further down.
        BX.restoreCorridorZ = savedCorridorZ

        -- Watcher aborts the route the moment the server ends our carry, so a
        -- lost egg does not also cost the 2s NO_PROGRESS watchdog mid-field.
        local droppedMidTween = false
        local watcherTask = task.spawn(function()
            task.wait(0.05)
            while isMoving or BX.routeActive do
                if not heldEggUid then
                    droppedMidTween = true
                    return
                end
                task.wait(0.05)
            end
        end)
        -- PLANT WHILE STILL CARRYING, IN PARALLEL WITH THE TRIP.
        --
        -- why that can never work:
        -- It fired 1.3s AFTER the egg left, so there was no tool to place and
        --   16.76 carry: INSTANT - remote accepted at 2.8 studs
        --   17.17 plant[live]: try 1 at 2295 studs -> false (no egg tool equipped yet)
        -- 0.41s into a carry the heartbeat confirms (carrying=true), with no
        -- custom UI, not a Roblox Tool - so BX.eggToolUid can never resolve

        -- CARRY TO THE PLOT'S DELIVERY POINT, NOT THE RESPAWN POINT.
        --
        -- stopping at the corridor is exactly why deliveries never registered."
        -- I switched this to the plot when you asked why a Forest steal was
        local DELIVER_POS = SAFE_POS
        do
            local okD, dp, how = pcall(BX.safeZonePos)
            if okD and typeof(dp) == "Vector3" then
                DELIVER_POS = dp
                trace(("return: delivering to the safe zone via %s -> %.0f,%.0f,%.0f")
                    :format(tostring(how), dp.X, dp.Y, dp.Z))
            end
        end

        -- CARRY EXACTLY AS A MANUAL CARRY DOES. Measured, not inferred.
        --
        -- A successful manual carry from Jungle, sampled every ~0.11s:
        --   ... 679 studs in 4.04s, then CLAIMED - delivery succeeded
        -- vel=0 - so the server sees position advancing at hundreds of studs/s
        -- 123-414 studs and over in a sample or two; Jungle onward is 636+ and
        -- So the carry walks. Humanoid:MoveTo at the WalkSpeed the server gave
        -- Measured by area (carry distance to the plot):
        local carryDist = 9999
        do
            local h0 = getHRP()
            if h0 and DELIVER_POS then
                carryDist = Vector3.new(DELIVER_POS.X - h0.Position.X, 0,
                                        DELIVER_POS.Z - h0.Position.Z).Magnitude
            end
        end
        local fastOK = (carryDist <= K.FAST_CARRY_MAX_DIST)
        trace(("return: carry %.0f studs -> %s"):format(
            carryDist, fastOK and ("FAST " .. K.VEL_CARRY_SPEED) or "WALK (over the safe distance)"))

        -- RIDE THE PATH HOME. This replaces every previous carry mode and it
        -- is the one that addresses the actual failure.
        -- failed! The egg was returned to its nest." The trip was never the
        -- Measured live on this account, this server, empty-handed so no egg
        --   jump  100 studs -> kept 100   HELD
        --   jump  200 studs -> kept 200   HELD
        --   jump  400 studs -> kept   0   REVERTED
        --   jump  800 studs -> kept   0   REVERTED
        local tpViable = (BX.carryMoveMode == "Instant TP")
            and (carryDist <= K.TP_MAX_ADOPTED)
        if BX.carryMoveMode == "Instant TP" and not tpViable then
            trace(("return: Instant TP skipped - %.0f studs is past the %d-stud "
                .. "the server will adopt, using the tween carry instead")
                :format(carryDist, K.TP_MAX_ADOPTED))
        end

        -- CARRY HOME. Arc to the safe zone, then straight down.
        --
        -- That is deliberate: a held egg over the transport budget is set to
        -- Dropped by the server, which is independent of the path shape.
        local carrySpeed = K.ARC_CARRY_SPEED or speed
        pcall(BX.stopSpeedHold)
        -- HOW LONG WE HAVE, not how fast we feel. Straight out of the game's
        -- own ResolveCatchDuration, so a lost egg can be read instead of
        -- argued about: "never catches us" and "catches us in 0.31s" are
        -- completely different bugs that used to produce the same report.
        do
            local w = BX.guardWindow and BX.guardWindow(BX.carryAreaId, carrySpeed)
            trace(("guard: %s at %d studs/s in %s"):format(
                w == nil and "never catches us" or ("catches us in %.2fs"):format(w),
                math.floor(carrySpeed), tostring(BX.carryAreaId or "?")))
        end

        trace(("return: ARC carry to the safe zone at %d studs/s"):format(carrySpeed))
        -- STOP THE MOMENT THE EGG IS GONE.
        --
        -- The watcher above only reads the old route mover's flags (isMoving,
        -- BX.routeActive); the carry has been an arc for a while and sets
        -- neither, so the watcher quit on its first tick and never fired. And
        -- the arc itself had no cancel, so a guard hit mid-carry (more likely
        -- on a laggy phone) knocked the egg loose and we kept flying all the
        -- way to the safe zone without it - then the loop started a whole new
        -- cycle instead of going back for the egg we had just dropped.
        -- GUARD TRACKER - WHAT THE ROBBED AREA'S GUARD IS DOING, 4x A SECOND.
        --
        -- Reported: "it lags and the guard catches me". The log shows where
        -- and when (Cherry Blossom, dropped 1.38s in, right at the zone border)
        -- but not how: by the game's own GuardChasePolicy a guard chasing a
        -- 479 studs/s carry levels off ~66 studs behind and never reaches its
        -- 7-stud HitDistance, and yet it did. This records the guard's state,
        -- target and flat distance to us through the carry, so the next catch
        -- says whether it was a chase, a lunge, or the server holding our
        -- position back. Read-only; stops with the carry.
        local trackAt0 = os.clock()
        local trackArea = BX.carryAreaId
        task.spawn(function()
            local lastLine = ""
            while heldEggUid == uid and os.clock() - trackAt0 < 20 do
                pcall(function()
                    local g = BX.findAreaGuard(trackArea)
                    local h = getHRP()
                    if not (g and h) then return end
                    local gp = g:IsA("Model") and g:GetPivot().Position or g.Position
                    local d = Vector3.new(gp.X - h.Position.X, 0, gp.Z - h.Position.Z).Magnitude
                    local line = ("chase: +%.2fs %s guard %s target=%s dist=%.0f | us x=%.0f"):format(
                        os.clock() - trackAt0, tostring(trackArea),
                        tostring(g:GetAttribute("GuardState")),
                        tostring(g:GetAttribute("TargetPlayer") or "-"), d, h.Position.X)
                    if line:sub(18) ~= lastLine then trace(line) lastLine = line:sub(18) end
                end)
                task.wait(0.25)
            end
        end)
        BX.arcTweenTo(DELIVER_POS, carrySpeed, "carry home", 5,
            function() return heldEggUid == nil end)
        if heldEggUid == nil then
            droppedMidTween = true
        else
            BX.arcDescend("deliver")
        end

        if BX.restoreCorridorZ then
            K.CORRIDOR_Z = BX.restoreCorridorZ
            BX.restoreCorridorZ = nil
        end
        pcall(task.cancel, watcherTask)
        if droppedMidTween then
            trace("return: carry ended mid-route")
        end

        -- ...AND GO BACK FOR IT. BX.regrabEgg already waits out the
        -- knockdown, follows the egg if a guard is walking it back, and tries
        -- several times. Got it: carry home again from here. At most twice
        -- per steal, so a guard that keeps landing hits cannot hold us in a
        -- loop - after that the steal loop moves on as before.
        if droppedMidTween and stealing and uid
           and (BX.midCarryRegrabs or 0) < 2 then
            BX.midCarryRegrabs = (BX.midCarryRegrabs or 0) + 1
            trace(("return: egg knocked loose mid-carry - going back for it (%d/2)")
                :format(BX.midCarryRegrabs))
            if BX.regrabEgg(uid, uidSlot) and stealing then
                heldEggUid, heldEggSlotKey = uid, uidSlot
                BX.carryStartedAt, BX.carryConfirmedAt = os.clock(), os.clock()
                BX.lostEgg = nil
                isProtecting = true
                pcall(startProtect)
                trace("return: got it back - carrying it home again")
                return BX.returnToSafe()
            end
            trace("return: could not get it back - moving on")
        end

        -- Hold inside the plot and wait for the server to claim it. The claim
        -- fires within a moment of the egg entering the zone.
        -- positional and this block used to fire it 1.3s after the drop.)

        local claimed = false
        local waitEnd = os.clock() + 4
        while os.clock() < waitEnd do
            if BX.eggClaimedAt and BX.eggClaimedAt >= tripStart then claimed = true break end
            -- Also treat "no longer carrying, and not reverted to a field
            -- state" as delivered.
            local carrying, st = BX.stillCarrying(uid)
            if not carrying then
                if st == nil then claimed = true end  -- gone from field = claimed
                break
            end
            task.wait(0.15)
        end

        if claimed then
            trace("return: DELIVERED - server claimed the egg on your plot")
            pcall(BX.carryDelivered)

            if selectedEggUid and uid == selectedEggUid then
                selectedEggUid = nil
                BX.pickWasUser = false
                BX.awaitUserPick = true
                BX.selHoldSince = nil
                BX.selHoldLast = nil
                trace("return: that was your egg - waiting for you to pick the next one")
                BlyxoStealDone(nil, true)
            else
                -- Folded into the one steal message - see BlyxoStealDone.
                BlyxoStealDone()
            end
            heldEggUid = nil
            heldEggSlotKey = nil
            carryLocked = false
            pcall(stopProtect)
            isProtecting = false
            BX.tuneCarrySpeed("Carried", speed)
            return
        end

        -- Not claimed. Read the egg's final state so the log shows whether it
        -- reverted (Slot/Dropped = we didn't make it into the zone in time) or
        -- is still carried (zone not reached).
        local st
        pcall(function()
            local rec = EggState and EggState.ReadFieldEgg and EggState.ReadFieldEgg(uid)
            st = rec and rec.State
        end)
        local h = getHRP()
        local inPlot = false
        pcall(function() inPlot = PlotState and PlotState.ContainsLocalPoint and h and PlotState.ContainsLocalPoint(h.Position) end)
        -- ONE LINE THAT MAKES CROSS-USER REPORTS COMPARABLE.
        --
        -- "the egg was returned to its nest" on its own says nothing about
        -- WHY, so every report turned into a guessing round. Print the things
        -- that actually vary between players and between attempts: how far the
        -- carry was, how fast it ran, how long it took, which area it started
        -- in, and the player's legal walk speed. A handful of these lines from
        -- different accounts will show the pattern immediately.
        local why = "-"
        pcall(function()
            local h0 = getHRP()
            local dp = DELIVER_POS
            local dist = (h0 and dp)
                and Vector3.new(dp.X - h0.Position.X, 0, dp.Z - h0.Position.Z).Magnitude or -1
            why = ("dist=%.0f carrySpeed=%.0f legalWS=%.0f area=%s took=%.2fs")
                :format(carryDist or -1, speed or -1,
                        BX.legalWalkSpeed and BX.legalWalkSpeed() or -1,
                        tostring(BX.carryAreaId or "?"),
                        BX.carryConfirmedAt and (os.clock() - BX.carryConfirmedAt) or -1)
            if dist >= 0 then why = why .. (" endGap=%.0f"):format(dist) end
        end)
        trace(("return: NOT claimed - egg state=%s inPlot=%s | %s")
            :format(tostring(st), tostring(inPlot), why))
        pcall(BX.carryRefused)
        toast("Delivery failed - egg " .. tostring(st or "gone"))
        BX.tuneCarrySpeed(st, speed)
        return
    end

    if BX.teleportMode then
        BX.tpTo(SAFE_POS, "return home (empty)")
        task.wait(BX.tpSettle or 0.35)
        return
    end
    trace("return: tween to safe zone")
    cfMoveTo(SAFE_POS, TWEEN_SPEED)
    waitForMove()
end

---------- STEAL LOOP ----------

-- X IS DECLARED HERE, NOT WHERE IT IS FILLED IN.
--
-- stealLoop reads X.riftWanted, and a Lua local is invisible to any function
-- written ABOVE its declaration. X used to be declared with the UI, a few
-- thousand lines below this, so inside stealLoop the name resolved to the
-- GLOBAL X - which is nil. The moment rift mode actually reached that line it
-- threw "attempt to index nil with 'riftWanted'", and because the loop runs
-- on task.spawn the error killed the thread silently:
--     [17.89s] autosteal: ON
--     [17.89s] loop: got 54 eggs
--     ...nothing at all for twelve seconds...
--     [29.94s] rift: auto OFF
-- No stall, no idle - the loop was simply dead, which is why plain auto steal
-- was fine (it never touches X) and only rift mode "stopped working".
local X

local function stealLoop()
    trace("stealLoop: begin")
    pcall(BX.armDropWatch)
    pcall(BX.armClaimWatch)
    if BX.monsterActive() then
        stealing = false
        toast("Monster Event is active - refusing to steal (instant kill zone)")
        trace("stealLoop: ABORT - MonsterEventMap present")
        return
    end
    BX.swapHumanoid()
    bypassAnticheat();  trace("stealLoop: bypassAnticheat done (gated=" .. tostring(not legacyAcBypass) .. ")")
    -- FORENSICS IS OFF BY DEFAULT NOW. It connects to EVERY RemoteEvent under
    -- the networking folder - "forensics: armed on 138 remotes" - and each
    -- inbound message runs a handler that serialises its arguments into
    -- strings. This game is chatty (income ticks, roster updates, egg state)
    -- so that is a constant string-building load on the client for data
    -- nobody reads unless something has gone wrong. Turn it on from the
    -- Config tab when you actually want a delivery post-mortem.
    if BX.forensicsEnabled then pcall(BX.armDiag) end
    pcall(BX.blockEggDrop)
    pcall(BX.acArm)
    pcall(BX.startSpoofHold); trace("stealLoop: spoof " .. (BX.acState and "ARMED" or "state not found"))
    setupAntiDeath();   trace("stealLoop: setupAntiDeath done (gated=" .. tostring(not antiDeathEnabled) .. ")")
    antiRagdoll();      trace("stealLoop: antiRagdoll done")
    startACEnforce();   trace("stealLoop: startACEnforce done (gated=" .. tostring(not acEnforceEnabled) .. ")")
    if guardManipEnabled then startGuardEnforce() end
    trace("stealLoop: guardManip=" .. tostring(guardManipEnabled))

    -- "Auto Steal ON" already said this; only the risky mode earns a message.
    if guardManipEnabled then toast("Stealing (guard manip ON - risky)") end

    local idleCycles = 0
    while stealing do
        -- EVERY PASS YIELDS AT LEAST ONE FRAME. NO EXCEPTIONS.
        --
        -- Caught live (2026-09-11): BX.carryingUid() kept reporting a Carried
        -- egg that would not deliver, returnToSafe() found itself already
        -- home and returned instantly, and `continue` went straight round
        -- again - hundreds of passes inside 0.03s, never yielding:
        --     282.24 loop: still carrying 7904... - going home before anything else
        --     282.24 arc: carry home 2 studs in 0.00s
        --     282.24 return: NOT claimed - egg state=Dropped
        --     282.24 loop: still carrying 7904...        <- and again, forever
        -- A Luau loop that never yields freezes the whole client: that is the
        -- "game freezes / crashes when I turn it on", and it hits phones and
        -- emulators hardest. One Heartbeat per pass costs nothing next to a
        -- steal, and makes a spin of this kind impossible whatever the cause.
        RunService.Heartbeat:Wait()
        if not stealing then break end

        -- Guard against exactly the failure the log caught: a loop that hits a
        -- `continue` path every iteration, does no work, and never stops.
        -- NOTHING TO TAKE RIGHT NOW IS NOT A REASON TO STOP.
        --
        -- This used to switch Auto Steal off after eight idle cycles. That
        -- guard exists for a real failure - a loop hitting `continue` every
        -- pass and spinning hot - but it cannot tell that apart from the
        -- ordinary case of "everything matching your filter has just been
        -- taken and has not respawned yet".
        --
        -- With an area or rarity picked that happens constantly: you take the
        -- one Divine on the map, and eight cycles later the run is dead. That
        -- is the "it steals one egg and stops".
        --
        -- So: stop SPINNING, do not stop STEALING. Sleep long enough that the
        -- idle loop costs nothing, then look again. Eggs come back, and the
        -- only thing that should end a run is you.
        if idleCycles >= 8 then
            idleCycles = 0
            if not BX.saidWaiting or (os.clock() - BX.saidWaiting) > 30 then
                BX.saidWaiting = os.clock()
                trace("stealLoop: nothing matches right now - waiting for a respawn")
                toast("Nothing to take yet - waiting")
            end
            BX.eggCache = nil
            task.wait(K.IDLE_RESCAN)
            continue
        end

        local hrp = getHRP()
        local hum = getHumanoid()
        if not hrp or not hum or hum.Health <= 0 then
            if hum and hum.Health <= 0 then
                -- died mid-run: treat as a failed attempt and slow down
                recordSpeedResult(false)
            end
            task.wait(1)
            continue
        end

        if isRagdolled() then
            recoverFromRagdoll()
            task.wait(0.1)
        end

        -- STANDING STILL WITH AN EGG IS ALWAYS WRONG.
        --
        -- Whatever route got us here - a lag drop, a regrab, a race between
        -- the drop watch and the carry - if the game says we are holding an
        -- egg at the top of a cycle, the only correct action is to take it
        -- home. Without this the loop would happily start a fresh steal while
        -- already carrying, or sit here doing nothing.
        do
            local have = BX.carryingUid()
            if have then
                heldEggUid = heldEggUid or have
                heldEggSlotKey = heldEggSlotKey or nil
                BX.carryConfirmedAt = BX.carryConfirmedAt or os.clock()
                trace("loop: still carrying " .. tostring(have) .. " - going home before anything else")
                local tripAt = os.clock()
                BX.returnToSafe()
                BX.lostEgg = nil
                -- A trip home that ends instantly did nothing - we were
                -- already there and the game would not take the egg. Three
                -- of those in a row for the same egg: stop insisting, park
                -- it for 15s and let the loop get on with its life.
                if os.clock() - tripAt < 0.2 then
                    if BX.fastTripUid == have then
                        BX.fastTrips = (BX.fastTrips or 0) + 1
                    else
                        BX.fastTripUid, BX.fastTrips = have, 1
                    end
                    if BX.fastTrips >= 3 then
                        BX.carryMute[have] = os.clock() + 15
                        BX.fastTripUid, BX.fastTrips = nil, 0
                        if heldEggUid == have then heldEggUid = nil end
                        trace("loop: " .. tostring(have) .. " will not deliver - ignoring it for 15s")
                        task.wait(1)
                    else
                        task.wait(0.25)
                    end
                else
                    BX.fastTripUid, BX.fastTrips = nil, 0
                end
                continue
            end
        end

        -- (the per-pass "evaluateEggs" line is gone - the count line below
        -- says everything it said, and only when it changes)
        -- Force a fresh read. The 20s cache meant a Dropped egg, or one a
        -- guard had just carried back to its nest, stayed invisible to the
        cachedEggs = evaluateEggs(true)
        trace("loop: " .. #cachedEggs .. " eggs")
        if #cachedEggs == 0 then
            idleCycles = idleCycles + 1
            task.wait(2)
            continue
        end

        -- RIFT MODE ONLY CHOOSES THE EGG. NOTHING ELSE DIFFERS.
        --
        -- This used to be a whole parallel branch further down with its own
        -- matching, its own cooldown handling and its own retry - and every
        -- bug in it was a bug the main path did not have, because the two had
        -- drifted apart. There is no reason for that: "steal the rift pet" and
        -- "steal the egg you picked" are the same job with a different way of
        -- choosing the uid.
        --
        -- So rift mode now does exactly one thing - write selectedEggUid - and
        -- everything after this point is the code the Main tab already uses.
        if BX.riftOnly then
            local want = X.riftWanted and X.riftWanted() or nil

            -- A pet you picked by hand that we now have (a pet or an egg on
            -- its way) is done - chasing it again is the duplicate problem.
            if want and BX.riftPet and not want[BX.riftPet] then
                trace("rift: already have " .. X.petName(BX.riftPet) .. " - dropping the pick")
                BX.riftPet, BX.riftCommitted = nil, nil
            end

            -- EVERY REQUIREMENT COVERED: nothing left to steal for this rift.
            if want and next(want) == nil then
                selectedEggUid, BX.riftCommitted = nil, nil
                BlyxoNote("rift-covered", BX.riftAutoTrade
                    and "Rift: all 3 covered - trading in once they have hatched"
                    or "Rift: all 3 covered - turn on Auto trade-in or trade at the Rift", 120)
                task.wait(2)
                continue
            end

            -- COMMIT TO ONE EGG, THE WAY MAIN DOES.
            --
            -- Main sets selectedEggUid once and every pass afterwards resolves
            -- that same uid. Rift was re-running "find a matching egg" on every
            -- pass, so a respawn, a sort change or another player taking one
            -- could swap the target mid-approach - which never happens on the
            -- Main tab and is why the two felt different.
            --
            -- So the pick is held until the egg is genuinely no longer takeable,
            -- and only then do we choose again.
            -- THIS IS "RIFT AUTO STEAL JUST GOES BACK AND FORTH".
            --
            -- Every other path in this loop respects BX.unreachable. When a
            -- carry fails the uid is stamped:
            --
            --     idleCycles = idleCycles + 1
            --     BX.unreachable[target.Uid] = tick()
            --
            -- and follow-best then skips it for K.UNREACHABLE_COOLDOWN and
            -- takes the next egg instead. Rift did the exact opposite. It
            -- re-resolved the SAME committed uid every pass and then wiped its
            -- cooldown outright:
            --
            --     BX.unreachable[pick.uid] = nil
            --
            -- So an egg that cannot actually be taken - another player already
            -- carrying it, a record that says Slot when the server disagrees,
            -- a nest the prompt will not answer for - is picked again on the
            -- very next pass. Out to the egg, prompt refused, retreat home,
            -- out to the same egg. Forever, and only in rift mode, because
            -- rift mode is the only branch that clears the cooldown.
            --
            -- The commit stays - it was added so a respawn or another player
            -- cannot swap the target mid-approach, and that is still right.
            -- It just no longer outranks "this one is not working".
            local pick = nil
            if BX.riftCommitted then
                for _, egg in ipairs(cachedEggs) do
                    if egg.uid == BX.riftCommitted and egg.grabbable
                       and not BX.unreachable[egg.uid] then
                        pick = egg
                        break
                    end
                end
                if not pick then BX.riftCommitted = nil end
            end

            -- Prefer one that has not just failed. Only if EVERY matching egg
            -- is on cooldown do we take a cooled-down one anyway - the same
            -- two-pass rule follow-best already uses, because idling is worse
            -- than a retry when there is nothing else on the map.
            if not pick and want then
                local fallback = nil
                for _, egg in ipairs(cachedEggs) do
                    local match = BX.riftPet and (egg.pet == BX.riftPet)
                        or (not BX.riftPet and want[egg.pet] == true)
                    if egg.grabbable and match then
                        if not BX.unreachable[egg.uid] then pick = egg break end
                        fallback = fallback or egg
                    end
                end
                if not pick and fallback then
                    pick = fallback
                    BX.unreachable[fallback.uid] = nil
                    trace(("rift: every %s on the map is on cooldown - retrying %s")
                        :format(BX.riftPet and X.petName(BX.riftPet) or "match",
                                tostring(fallback.name)))
                end
            end

            if pick then
                BX.riftCommitted = pick.uid
                if selectedEggUid ~= pick.uid then
                    selectedEggUid = pick.uid
                    BX.selHoldUid = pick.uid
                    BX.selHoldSince, BX.selHoldLast = nil, nil
                    trace(("rift: taking %s (%s)"):format(tostring(pick.name), tostring(pick.pet)))
                end
            else
                -- Nothing wanted is out. Clear the selection so the normal
                -- path cannot fall back to some other egg, and wait.
                selectedEggUid = nil
                BX.riftCommitted = nil
                if BX.riftPet and X.riftForgetPick and X.riftForgetPick() then
                    BX.riftWaitAt = 0
                elseif os.clock() - (BX.riftWaitAt or 0) > 8 then
                    BX.riftWaitAt = os.clock()
                    local names = {}
                    for id in pairs(want or {}) do names[#names + 1] = X.petName(id) end
                    table.sort(names)
                    local waitingFor = BX.riftPet and X.petName(BX.riftPet)
                        or table.concat(names, ", ")
                    trace("rift: waiting for " .. tostring(waitingFor))
                    -- The trace stays every 8s; the note on screen once per 2 min.
                    BlyxoNote("rift-wait", "Rift: waiting for " .. tostring(waitingFor), 120)
                end
                task.wait(1)
                continue
            end
        end

        -- Eggs we failed to reach or carry go on a short cooldown. Without
        -- it the "pick the best egg" rule hands back the same unreachable egg
        -- every two seconds forever.
        for uid, at in pairs(BX.unreachable) do
            if tick() - at > K.UNREACHABLE_COOLDOWN then BX.unreachable[uid] = nil end
        end

        -- The lock lasts only while the guard is fetching. Re-arm once the
        -- retrieval has plausibly finished so the next area gets its own decoy.
        if BX.decoyDone and BX.decoyAt and (os.clock() - BX.decoyAt) > (K.DECOY_TTL or 25) then
            BX.decoyDone = false
        end

        local target = nil
        local pickedByUser = false
        if selectedEggUid then
            for _, egg in ipairs(cachedEggs) do
                if egg.uid == selectedEggUid then
                    pickedByUser = true
                    if egg.grabbable then target = egg.record end
                    break
                end
            end
        end

        -- HOLD THE SELECTION THROUGH THE STEAL CYCLE.
        --
        -- then Dropped - so a successful steal was itself enough to lose your
        -- RIFT MODE IGNORES THE SELECTION ENTIRELY.
        --
        -- This hold waits for the egg in the Target Egg box to become
        -- grabbable again, and `continue`s while it does. With rift mode on
        -- that starved it completely: the box had auto-selected some ordinary
        -- egg, that egg was mid-cycle, and the loop sat here polling it - so
        -- the rift branch further down never ran at all. Straight from the
        -- log: "rift: auto ON", "autosteal: ON", then nothing for five
        -- seconds until it was switched off again.
        --
        -- Fixing the later `if not target` guard was not enough, because the
        -- loop never got that far. Rift mode does not use selectedEggUid for
        -- anything, so it must not be gated on it here either.
        if selectedEggUid and (not target) and (not BX.followBest) then
            local _, st = BX.eggPosNow(selectedEggUid)
            local alive = (st ~= nil) and (st ~= "Claimed")
            -- Whoever set the clock, it only counts if it was started for the
            -- egg we are actually holding out for.
            if BX.selHoldUid ~= selectedEggUid then
                BX.selHoldUid = selectedEggUid
                BX.selHoldSince = nil
                BX.selHoldLast = nil
            end
            BX.selHoldSince = BX.selHoldSince or os.clock()
            local held = os.clock() - BX.selHoldSince

            if alive and held < K.SELECTED_HOLD then
                if st ~= BX.selHoldLast then
                    BX.selHoldLast = st
                    trace(("loop: selected egg is %s - holding your selection (%.0fs/%.0fs)")
                        :format(tostring(st), held, K.SELECTED_HOLD))
                end
                task.wait(K.SELECTED_POLL)
                continue
            end

            trace(("loop: releasing the selection - egg is %s after %.0fs")
                :format(tostring(st or "gone"), held))
            selectedEggUid = nil
            BX.selHoldSince = nil
            BX.selHoldLast = nil

            if BX.pickWasUser then
                BX.awaitUserPick = true
                BX.pickWasUser = false
                trace("loop: your egg is done - waiting for you to pick the next one")
                BlyxoPickPrompt("Egg done - pick your next one")
            end
        elseif target then
            -- Got it this pass; reset the hold clock for next time.
            BX.selHoldSince = nil
            BX.selHoldLast = nil
        end

        -- (The old "your egg left the field" branch lived here and cleared
        -- selectedEggUid unconditionally. The block above replaces it: the
        -- Claimed, or K.SELECTED_HOLD has run out - never merely because it

        -- Only auto-pick when you have not chosen anything. A GuardCarried egg
        -- is listed for visibility but walking to one just stands us next to a
        -- guard holding it.
        if BX.awaitUserPick and not selectedEggUid and not BX.followBest then
            task.wait(0.5)
            continue
        end

        -- NOTHING SELECTED = NOTHING TO DO.
        --
        -- This used to auto-pick whenever selectedEggUid was nil, which is
        if not selectedEggUid and not BX.followBest then
            if not BX.saidPickOne then
                BX.saidPickOne = true
                trace("loop: no egg selected - waiting for you to pick one")
                BlyxoPickPrompt("Pick an egg to steal")
            end
            task.wait(0.5)
            continue
        end
        BX.saidPickOne = false

        if not target and BX.followBest and not BX.riftOnly then
            for _, egg in ipairs(cachedEggs) do
                if egg.grabbable and not BX.unreachable[egg.uid] then
                    target = egg.record
                    break
                end
            end
            -- Everything is on cooldown: take the best one anyway rather than
            -- idling. A stale cooldown is a worse failure than a retry.
            if not target then
                for _, egg in ipairs(cachedEggs) do
                    if egg.grabbable then
                        target = egg.record
                        BX.unreachable[egg.uid] = nil
                        break
                    end
                end
            end
        end

        if not target then
            idleCycles = idleCycles + 1
            trace("loop: no usable target record (idle " .. idleCycles .. "/8)")
            task.wait(2)
            continue
        end

        if guardManipEnabled then
            pcall(switchGuard, target.AreaId)
        end

        -- PRIME IN THE FIRST AREA, then go for the real target. Note this is
        -- deliberately NOT the target's own area - doing it there wakes the
        -- guard we are about to rob and loses the egg immediately.
        -- THE FOREST PRIME IS THE METHOD, NOT AN OPTIMISATION.
        --
        -- The whole sequence is: steal an egg in the first area, let the guard
        -- catch you, THEN tween to the egg you actually want. Taking that hit
        -- up front is what makes the real steal survive - it is the same
        -- reason Anti Hit stopped being a toggle.
        --
        -- I put a 45s cooldown on this while chasing a slow cycle, which was
        -- wrong: it skipped the Forest step on most passes and broke the one
        -- thing that makes the steal work. The slow cycle was never the prime,
        -- it was grabbing during the knockdown the prime creates - fixed where
        -- that actually happens, in the grab.
        --
        -- So it runs every cycle again, exactly as before.
        -- THE PRIME IS A PRECONDITION, NOT A FORMALITY.
        --
        -- You spotted this yourself: "if you steal and get hit in forest first
        -- then steal the selected egg it works". That is the whole method -
        -- the real steal only survives because the guard's hit has already
        -- been spent in the first area.
        --
        -- But primeFirstArea had three silent early-returns (areas not loaded,
        -- no Slot egg in Forest, pickup refused) and a fourth path where no
        -- guard turned up inside PRIME_HIT_WAIT, and that last one DROPS THE
        -- EGG BY HAND and carries on regardless. A hand-drop is not a guard
        -- hit - the comment on that very branch says so - so the cycle went to
        -- the target unprimed and the egg came straight back to its nest.
        -- Sometimes primed, sometimes not: exactly the "sometimes it works".
        --
        -- Now a prime that did not land is retried, and if it still will not
        -- land we skip the cycle rather than spend a trip on a steal we know
        -- is going to fail.
        -- NEVER PRIME WHILE HOLDING AN EGG.
        --
        -- primeFirstArea flies to the first area, grabs a Forest egg and walks
        -- into that guard on purpose. Doing that with the real egg already in
        -- hand throws it away - the Forest guard hits us, the server drops what
        -- we are carrying, and the run reads exactly as reported: "it steals
        -- the egg and goes back to the Forest guard, never to the safe zone".
        --
        -- The normal path returns home before the next cycle, so this should
        -- never be true. It costs one comparison to make sure a stalled return
        -- can never turn into a thrown-away egg.
        if heldEggUid and BX.primeEnabled then
            trace("prime: still carrying an egg - going home instead of priming")
        end

        if BX.primeEnabled and not heldEggUid and target.AreaId ~= BX.firstAreaId() then
            local primed = false
            for attempt = 1, K.PRIME_RETRIES do
                pcall(BX.primeFirstArea)
                if BX.primeHitLanded then primed = true break end
                if attempt < K.PRIME_RETRIES then
                    trace(("prime: no hit landed (try %d/%d) - going again")
                        :format(attempt, K.PRIME_RETRIES))
                    task.wait(K.PRIME_RETRY_GAP)
                end
            end

            -- NEVER A CHICKEN LOOP. Skipping an unprimed cycle is right once;
            -- skipping every cycle - which is what happens when the hit is
            -- genuinely landing but cannot be seen - means stealing Forest
            -- eggs forever and never the target. After two skipped cycles in
            -- a row, go for the target anyway; a steal attempt beats an
            -- endless prime.
            if primed then
                BX.primeSkips = 0
            else
                BX.primeSkips = (BX.primeSkips or 0) + 1
                if BX.primeSkips <= 2 then
                    trace(("prime: could not take a hit in the first area - skipping this cycle"
                          .. " rather than stealing unprimed (%d/2)"):format(BX.primeSkips))
                    task.wait(1)
                    continue
                end
                trace("prime: still no hit after 2 skipped cycles - going for the target anyway")
                BX.primeSkips = 0
            end

            -- NO WAITING HERE. Prime, take the hit, LEAVE.
            --
            -- I put a knockdown wait in this spot and it was wrong. The
            -- sequence is: steal in the first area, take the guard's hit, and
            -- tween straight to the target. The travel is what covers the
            -- knockdown, and on a normal trip it covers all of it.
        end

        if isProtecting and heldEggUid then
            stopProtect()
            heldEggUid = nil
            heldEggSlotKey = nil
            carryLocked = false
            task.wait(0.2)
        end

        trace(("loop: moving to %s @ %d studs/s (mode=%s)"):format(
            tostring(target.AreaId), math.floor(TWEEN_SPEED), MOVE_MODE))

        -- Outbound: fast tween to within ~70 studs, then walk the final
        -- segment. The new AC checks recent movement velocity at carry
        -- time; ~70 studs of WalkSpeed movement fills its window with
        do
            local h0 = getHRP()
            local eggPos = target.BoundsCFrame.Position
            local toEgg = h0 and (eggPos - h0.Position) or Vector3.zero
            -- OUTBOUND IS A TWEEN. Teleporting TO a far egg does not work:
            -- the server clamps you back to the field entrance. Measured
            --   carry: teleport steal never accepted in 23 tries
            -- Jungle 709, Snow 999 all landed; nothing past ~1000 studs did.
            -- what makes the return a zero-stud move server-side and why the
            BX.captureSafeAnchor("outbound")

            BX.tpUsedForThisEgg = false
            local tpOutOk = BX.teleportMode and h0
                and (eggPos - (BX.homePos() or eggPos)).Magnitude <= (BX.tpOutMaxDist or 900)
            -- OUTBOUND. Arc only: climb, cruise, dive, then the last 50
            -- studs slow so we arrive on the nest instead of skidding past.
            trace(("loop: ARC to the egg (%.0f studs)"):format(toEgg.Magnitude))
            BX.outboundAt = os.clock()   -- a relocate after this pulled us off the egg
            -- OUTBOUND: TELEPORT IF ASKED, OTHERWISE TWEEN.
            --
            -- The sequence stays exactly as it is - prime in Forest, take the
            -- guard hit, then go for the selected egg, then TWEEN home with it.
            -- The only thing this changes is that middle leg, and only the
            -- outbound half of it.
            --
            -- Why it is the outbound leg and nothing else: we are EMPTY-HANDED
            -- there. The carry-void rule that reverts a fast-moving egg cannot
            -- apply to a hand with no egg in it, and this is also the only leg
            -- the sample spoof covers (arcTweenTo spoofs when heldEggUid is
            -- nil). A jump the anticheat's own record says never happened is
            -- the one place a teleport has a chance.
            --
            -- It is a toggle and it is OFF by default, because the evidence is
            -- mixed: K.TP_MAX_ADOPTED is 200, and the note above BX.tpTo says
            -- the server has refused outbound teleports before - the client
            -- read x=3385 while the server never moved us. On a client whose
            -- spoof holds it may go straight through; on one where it does not,
            -- the relocate clamp added earlier will catch it and the run
            -- continues at legal speed instead of fighting.
            -- Teleport out by default. It was a toggle for one build while
            -- it was being proven; it works, so it is simply how the outbound
            -- leg travels now - and it still falls back to the tween the
            -- moment the server refuses one.
            --
            -- NOT ANY MORE: THE SERVER REFUSES IT MOST OF THE TIME. Measured
            -- 2026-09-11, five Prehistoric trips (~2220 studs):
            --     9.8s  landed 27 studs short -> walked the rest
            --     24.2s refused -> Relocate -> tween
            --     33.2s refused -> Relocate -> tween
            --     42.3s refused -> Relocate -> tween
            --     51.5s "landed" -> Relocate 0.1s later anyway
            -- So one trip teleported, one walked, three tweened - "it insta tps
            -- to one egg and tweens to the other" - and every refusal also
            -- cost a relocate, a 3s backoff and a speed clamp. The tween did
            -- the same distance in 2.2s and landed within 1-2 studs.
            -- Kept ON anyway by request (K.OUTBOUND_TP): instant TP first,
            -- tween only when the server refuses the jump.
            BX.outboundTp = false
            if BX.tpTo and K.OUTBOUND_TP then
                local from = getHRP() and getHRP().Position
                BX.tpTo(eggPos, "outbound")
                task.wait(K.TP_SETTLE)
                local h2 = getHRP()
                local gap = (h2 and eggPos) and (h2.Position - eggPos).Magnitude or 9999
                BX.outboundTp = gap <= K.TP_LANDED
                if gap > K.TP_LANDED then
                    -- The server did not take it. Fall back to the tween that
                    -- has always worked rather than standing in the wrong place.
                    trace(("tp: outbound refused - %.0f studs off, tweening instead")
                        :format(gap))
                    BX.arcTweenTo(eggPos, K.ARC_SPEED, "outbound", 4)
                else
                    trace(("tp: outbound landed %.0f studs from the egg"):format(gap))

                    -- ARRIVING IS NOT THE SAME AS BEING READY TO GRAB.
                    --
                    -- "it went to the egg but forgot to steal it" is this: a
                    -- tween arrives gradually, so by the time we are stood on
                    -- the nest the game has long since moved a pooled prompt
                    -- onto our egg and the server has our position. A teleport
                    -- skips all of that - we are there on one frame, and the
                    -- prompt is still parked at whatever nest it was serving.
                    -- Firing then does nothing, three times, and the loop gives
                    -- up and goes home.
                    --
                    -- So wait for the thing that is actually missing: a steal
                    -- prompt sitting next to THIS egg. Poll the cache we
                    -- already keep - the prompts are reassigned by changing
                    -- their Parent, which is re-read every pass, so no rebuild
                    -- is needed. Bounded, and it exits the moment one appears.
                    local until_ = os.clock() + K.TP_PROMPT_WAIT
                    local ready = false
                    repeat
                        for _, d in ipairs(BX.promptCache or {}) do
                            if d.Parent and d.Enabled then
                                local pp = d.Parent
                                local ppos = pp:IsA("BasePart") and pp.Position
                                    or (pp:IsA("Model") and pp:GetPivot().Position)
                                if ppos and (ppos - eggPos).Magnitude <= K.PROMPT_NEAR then
                                    ready = true
                                    break
                                end
                            end
                        end
                        if ready then break end
                        task.wait(0.05)
                    until os.clock() > until_
                    trace(("tp: prompt %s after %.2fs"):format(
                        ready and "arrived" or "never showed",
                        os.clock() - (until_ - K.TP_PROMPT_WAIT)))
                end
            else
                BX.arcTweenTo(eggPos, K.ARC_SPEED, "outbound", 4)
            end

            -- FINAL APPROACH - ONLY IF WE ARE ACTUALLY SHORT.
            --
            -- This must still run in every mode: it was once gated on
            -- 0.87s walk it did not need while the guard's 0.63s wake clock
            local arrivedGap
            do
                local h = getHRP()
                arrivedGap = h and Vector3.new(eggPos.X - h.Position.X, 0,
                                               eggPos.Z - h.Position.Z).Magnitude or 9999
            end
            if BX.teleportMode then
                -- Re-aim the hold at where we ACTUALLY are relative to the
                -- egg, and let carryEgg's race hold it there.
                if arrivedGap > 7 then BX.legalHopTo(eggPos) end
                BX.tpEggCF = CFrame.new(eggPos.X, eggPos.Y + 2, eggPos.Z)
                BX.tpUsedForThisEgg = true
            elseif arrivedGap > 7 then
                trace(("loop: %.1f studs short on arrival, closing"):format(arrivedGap))
                -- Knocked down: anything written to the character now is
                -- undone by the ragdoll (a hop "finished 0.0 studs" from the
                -- egg and was 14.4 away a moment later). Let it end first.
                if BX.ragdollActive or isRagdolled() then
                    BX.waitForRagdollEnd(3)
                    pcall(BX.readyAfterRagdoll)
                end
                -- A teleport that landed short closes the gap with a second,
                -- short hop - not a visible walk ("why do you move when you
                -- instant tp"). Hops under K.TP_MAX_ADOPTED are the ones the
                -- server keeps.
                if BX.flyEnabled or BX.outboundTp then
                    BX.legalHopTo(eggPos, 2)
                else
                    BX.walkTo(eggPos, 4, 6)
                end
            end
        end
        trace("loop: move finished")
        if not stealing then break end

        local isFirst = AreaEggSlotIdentity.LooksLikeFirstAreaUid(target.Uid)
        local slotKey = isFirst and AreaEggSlotIdentity.SlotKey(target.AreaId, target.NestId) or nil

        -- Proximity check: server rejects carry with "Get closer" if we
        -- landed short (relocate, terrain, etc.).
        -- Measure this FLAT, on x/z only, because that is the test BX.walkTo
        -- "7 studs short (try 1/3)".."(try 3/3)" at 9.42s, no time passing and
        local function eggGap()
            local h = getHRP()
            if not h then return 9999 end
            local p = target.BoundsCFrame.Position
            return Vector3.new(p.X - h.Position.X, 0, p.Z - h.Position.Z).Magnitude
        end
        for attempt = 1, 3 do
            local gap = eggGap()
            if gap <= 7 then break end
            trace(("loop: %.1f studs short, closing in (try %d/3)"):format(gap, attempt))
            if BX.teleportMode or BX.outboundTp then
                BX.legalHopTo(target.BoundsCFrame.Position)
            else
                BX.walkTo(target.BoundsCFrame.Position, 4, 5)
            end
        end

        do
            local gap = eggGap()
            if gap > 7 then
                trace(("loop: could not reach the egg (%.1f studs short, %s) - retreating")
                    :format(gap, tostring(BX.routeFail or "short")))
                idleCycles = idleCycles + 1
                recordSpeedResult(false)
                -- Do not try this egg again straight away; something about the
                -- path to it is not working right now.
                BX.unreachable[target.Uid] = tick()
                local home = BX.homePos()
                if home then
                    if BX.teleportMode then
                        BX.tpTo(home, "retreat")
                        task.wait(BX.tpSettle or 0.35)
                    else
                        cfMoveTo(home, TWEEN_SPEED)
                        waitForMove()
                    end
                end
                task.wait(0.5)
                continue
            end
        end

        -- Set BEFORE the steal: carryEgg dashes on the first prompt fire and
        -- needs to know whose box it is clearing.
        BX.carryAreaId = target.AreaId
        -- The pooled prompts are matched against THIS, not against us.
        BX.carryTargetPos = target.BoundsCFrame and target.BoundsCFrame.Position or nil
        local carried = carryEgg(target.Uid, slotKey)
        -- PULLED BACK DURING THE GRAB: GO STRAIGHT BACK FOR IT, ONCE.
        --
        -- Same thing the prime hits: the server Relocates us to spawn a
        -- moment after the outbound hop lands, so the grab asks from the
        -- wrong place and is refused. Measured:
        --     30.05 tp: prompt arrived / loop: move finished
        --     30.07 SERVER RigSync -> Relocate      (back to 514,70,-362)
        --     30.30 carry: remote refused - Enter the gameplay area first
        --     32.29 loop: carried=false             -> whole cycle thrown away
        -- and the next cycle - a fresh prime and a second guard hit later -
        -- took the very same egg. Hopping straight back and grabbing again
        -- gets it on this cycle instead.
        if not carried and stealing and BX.outboundAt
           and (BX.relocAt or 0) > BX.outboundAt and target.BoundsCFrame then
            trace("loop: server pulled us back during the grab - going straight back for it")
            BX.lastRelocate = nil
            BX.outboundAt = os.clock()
            BX.arcTweenTo(target.BoundsCFrame.Position, K.ARC_SPEED, "outbound", 4)
            if stealing then carried = carryEgg(target.Uid, slotKey) end
        end
        -- Stamp the steal so the attach can be judged against the guard's
        -- 0.63s wake window (GuardChasePolicy.GetWakingDuration, already in
        if carried then BX.carryConfirmedAt = os.clock() end
        trace("loop: carried=" .. tostring(carried))
        -- Only a SUCCESSFUL steal counts as progress. Clearing this on every
        -- attempt disarmed the spin guard entirely: a loop failing the carry
        -- forever reset the counter forever and never tripped the 8-cycle
        -- abort, which is why a broken run had to be noticed by the user.
        if carried then
            idleCycles = 0
        else
            idleCycles = idleCycles + 1
            BX.unreachable[target.Uid] = tick()
        end
        recordSpeedResult(carried)

        if carried then
            stolenUids[target.Uid] = tick()
            heldEggUid = target.Uid
            BX.midCarryRegrabs = 0      -- fresh steal: fresh regrab budget
            heldEggSlotKey = slotKey
            -- Which guard's box we have to clear before its 0.63s wake ends.
            BX.carryAreaId = target.AreaId
            BX.carryStartedAt = os.clock()
            isProtecting = true
            BX.lostEgg = nil
            startProtect()

            pcall(BX.startAntiHit)

            -- AND REFUSE THE DROP. THIS WAS NEVER TURNED ON.
            --
            -- UNCALLED - nothing anywhere invoked it. Its own header says why
            --   "We were not blocking either, which is why taking a hit would
            pcall(BX.blockEggDrop)

            -- THE SECOND HIT IS THIS BLOCK. IT IS ON PURPOSE.
            --
            -- K.STEAL_RAGDOLL_WAIT (3s) waiting for a guard that may never
            -- where the guard is WalkSpeed 16 / HitDistance 2.5 and costs
            do
                local hitBefore = BX.lastGuardHitAt or 0
                local h0 = getHRP()
                local anchorCF = h0 and h0.CFrame or nil

                -- PIN FROM BEFORE THE HIT, NOT AFTER IT.
                --
                -- why this only goes wrong out there.
                -- loses ground in the far areas, because the impulse is applied
                -- to land inside 4 studs.
                local pinning = BX.takeHitOnSteal and true or false
                if pinning then
                task.spawn(function()
                    local h1 = getHRP()
                    if h1 then pcall(function() h1.Anchored = true end) end
                    local deadline = os.clock()
                        + K.STEAL_RAGDOLL_WAIT + K.STEAL_RAGDOLL_HOLD + 3
                    while pinning and os.clock() < deadline do
                        local hh = getHRP()
                        if hh then
                            hh.AssemblyLinearVelocity = Vector3.zero
                            hh.AssemblyAngularVelocity = Vector3.zero
                            if anchorCF then
                                pcall(function() hh.CFrame = anchorCF end)
                            end
                        end
                        RunService.Heartbeat:Wait()
                    end
                    -- Always unanchor, on every exit including the deadline and
                    -- a respawn handing us a different root part.
                    local h2 = getHRP()
                    if h2 then pcall(function() h2.Anchored = false end) end
                end)
                end

                -- DO NOT WAIT FOR A HIT WE ARE ALREADY STANDING INSIDE.
                --
                -- which BX.blockEggDrop cannot stop because the client is
                -- never asked. Titan Temple's HitDistance is 7 studs, so at
                -- finished picking the egg up - there was never a version of
                -- wait (the old behaviour), or to math.huge to never wait.
                -- K.STEAL_RAGDOLL_WAIT (3s) hoping the guard connects, and
                -- GuardChasePolicy.GetWakingDuration gives us 0.63s before it
                local skipWait = not BX.takeHitOnSteal
                if skipWait then
                    trace("steal: leaving immediately - not waiting for a hit")
                end
                -- Only worth asking when we might actually wait. With
                -- takeHitOnSteal off the answer changes nothing, and this
                -- block requires a module and walks the guard rig - work we
                -- were doing in the one second that matters.
                if not skipWait then
                    local hd = 7
                    pcall(function()
                        local gd = require(RS.Data.Guards).Directory[target.AreaId]
                        if gd and tonumber(gd.HitDistance) then hd = tonumber(gd.HitDistance) end
                    end)
                    local g = BX.findAreaGuard(target.AreaId)
                    local part = g and BX.guardAnchorPart(g)
                    if part and h0 then
                        local gdist = (part.Position - h0.Position).Magnitude
                        if gdist <= hd * K.HIT_WAIT_SKIP_MULT then
                            skipWait = true
                            trace(("ragdoll: guard is %.0f studs away (hit range %.0f) - not waiting, leaving now")
                                :format(gdist, hd))
                        else
                            trace(("ragdoll: guard is %.0f studs away (hit range %.0f) - safe to wait")
                                :format(gdist, hd))
                        end
                    end
                end

                if not skipWait then
                    trace(("ragdoll: holding up to %.1fs for the guard to knock us down")
                        :format(K.STEAL_RAGDOLL_WAIT))

                    local dl = os.clock() + K.STEAL_RAGDOLL_WAIT
                    while stealing and os.clock() < dl do
                        if (BX.lastGuardHitAt or 0) > hitBefore or BX.ragdollActive then break end
                        RunService.Heartbeat:Wait()
                    end
                end

                if (BX.lastGuardHitAt or 0) > hitBefore or BX.ragdollActive then
                    -- ANTI-FLING. The guard's hit is not just a knockdown, it
                    -- carries an impulse - the payload measured in the trace
                    trace("ragdoll: hit landed - already pinned, riding it out")

                    -- Waited out inline rather than through
                    -- BX.waitForRagdollEnd: that helper finishes with
                    -- With Anti Hit armed we do not wait for the server's
                    local rdl = os.clock() + (BX.antiHitEnabled
                        and K.ANTIHIT_RAGDOLL_WAIT or K.STEAL_RAGDOLL_HOLD)
                    while os.clock() < rdl do
                        if not isRagdolled()
                           and (BX.antiHitEnabled or not BX.ragdollActive) then break end
                        RunService.Heartbeat:Wait()
                    end
                    pinning = false
                    -- Unanchor HERE too, not only in the pin thread:
                    -- that thread clears it on its next Heartbeat, and
                    -- the re-steal below must never run against a root
                    do local hu = getHRP()
                        if hu then pcall(function() hu.Anchored = false end) end
                    end

                    pcall(recoverFromRagdoll)
                    BX.readyAfterRagdoll()

                    -- Land back exactly where we were hit, so the re-steal
                    -- below is in range on its first attempt.
                    local hh = getHRP()
                    if hh and anchorCF then
                        local drift = (hh.Position - anchorCF.Position).Magnitude
                        if drift > 1 then
                            pcall(function() hh.CFrame = anchorCF end)
                            hh.AssemblyLinearVelocity = Vector3.zero
                            hh.AssemblyAngularVelocity = Vector3.zero
                        end
                        trace(("ragdoll: released %.1f studs from where we were hit"):format(drift))

                        local ep = select(1, BX.eggPosNow(target.Uid))
                        local hh2 = getHRP()
                        if ep and hh2 then
                            local d = (ep - hh2.Position).Magnitude
                            if d > K.REGRAB_ARRIVE then
                                trace(("ragdoll: %.1f studs from the egg - stepping back onto it"):format(d))
                                local c2 = getChar()
                                if c2 then
                                    pcall(function()
                                        c2:MoveTo(Vector3.new(ep.X, ep.Y + 2, ep.Z))
                                    end)
                                    local hh3 = getHRP()
                                    if hh3 then
                                        hh3.AssemblyLinearVelocity = Vector3.zero
                                        hh3.AssemblyAngularVelocity = Vector3.zero
                                    end
                                    RunService.Heartbeat:Wait()
                                end
                            end
                        end
                    end
                else
                    trace("ragdoll: nobody came inside the window - heading home anyway")
                end

                pinning = false
                do local hu2 = getHRP()
                    if hu2 then pcall(function() hu2.Anchored = false end) end
                end

                local restealUid, restealSlot = target.Uid, slotKey
                if heldEggUid == nil then
                    BX.lostEgg = nil
                    local retaken = false

                    -- WAIT OUT THE SERVER'S KNOCKDOWN FIRST.
                    --
                    -- K.RESTEAL_WINDOW at 3s and a 2.5s knockdown, nearly the
                    -- whole budget was spent collecting refusals, which is why
                    -- it "keeps getting hit and never steals".
                    do
                        local left = BX.ragdollRemaining()
                        if left > 0 then
                            trace(("resteal: knocked down for another %.2fs - waiting it out")
                                :format(left))
                            local until_ = os.clock() + left + 0.05
                            do
                                local gs, gt = BX.guardStatus(target.AreaId)
                                if gs then
                                    trace(("guard: %s%s"):format(tostring(gs),
                                        (gt ~= "" and gt ~= "nil") and (" (after " .. gt .. ")") or ""))
                                end
                            end
                            BX.holdGuardDistance(target.AreaId, until_)
                            BX.readyAfterRagdoll()

                            -- Back onto the egg for the grab. One short hop,
                            -- well inside what the server accepts.
                            local ep = select(1, BX.eggPosNow(restealUid))
                            local hh = getHRP()
                            if ep and hh and (ep - hh.Position).Magnitude > K.REGRAB_ARRIVE then
                                local c = getChar()
                                if c then
                                    pcall(function()
                                        c:MoveTo(Vector3.new(ep.X, ep.Y + 2, ep.Z))
                                    end)
                                    local h2 = getHRP()
                                    if h2 then
                                        h2.AssemblyLinearVelocity = Vector3.zero
                                        h2.AssemblyAngularVelocity = Vector3.zero
                                    end
                                    RunService.Heartbeat:Wait()
                                end
                            end
                        end
                    end

                    local rdl = os.clock() + K.RESTEAL_WINDOW
                    while stealing and os.clock() < rdl do
                        -- Another hit can land while we are retrying; do not
                        -- spend the rest of the window asking through it.
                        local again = BX.ragdollRemaining()
                        if again > 0 then
                            local until2 = os.clock() + again + 0.05
                            while stealing and os.clock() < until2 do
                                RunService.Heartbeat:Wait()
                            end
                            BX.readyAfterRagdoll()
                            rdl = math.max(rdl, os.clock() + 1.0)
                        end
                        local _, st = BX.eggPosNow(restealUid)

                        -- Record gone or banked: re-target by position.
                        if st == nil or st == "Claimed" then
                            local rec, d = BX.nearestGrabbableEgg(K.RESTEAL_RETARGET_DIST)
                            if not rec then
                                trace("resteal: our egg is gone and nothing else is in reach")
                                break
                            end
                            restealUid = rec.Uid
                            restealSlot = AreaEggSlotIdentity.LooksLikeFirstAreaUid(rec.Uid)
                                and AreaEggSlotIdentity.SlotKey(rec.AreaId, rec.NestId) or nil
                            target = rec
                            trace(("resteal: our egg is gone - re-targeting %s %.0f studs away")
                                :format(tostring(rec.AssetCategory), d or -1))
                        elseif st == "Slot" or st == "Dropped" then
                            if carryEgg(restealUid, restealSlot) then
                                retaken = true
                                trace("resteal: took it again on the spot")
                                break
                            end
                        end
                        RunService.Heartbeat:Wait()
                    end

                    if not retaken then
                        trace("resteal: not in range any more - walking back for it")
                        retaken = BX.regrabEgg(restealUid, restealSlot)
                    end

                    if retaken then
                        heldEggUid = restealUid
                        heldEggSlotKey = restealSlot
                        BX.carryAreaId = target.AreaId
                        BX.carryStartedAt = os.clock()
                        BX.carryConfirmedAt = os.clock()
                        idleCycles = 0
                    else
                        trace("resteal: could not retake the egg")
                    end
                end

                -- Trust the game over our own bookkeeping. If EggState says
                -- an egg is Carried, we are going home with it, whatever
                -- heldEggUid happens to say after a drop/regrab race.
                local reallyHave = heldEggUid or BX.carryingUid()
                if reallyHave and not heldEggUid then
                    heldEggUid = reallyHave
                    BX.carryConfirmedAt = BX.carryConfirmedAt or os.clock()
                    trace("return: EggState says we ARE carrying - our flag had been cleared,"
                          .. " heading home anyway")
                end

                if reallyHave then
                    -- HOW LONG DID WE STAND THERE. The guard wakes 0.63s after
                    -- the steal, so anything much over that is a hit we chose
                    -- to take. If this number is large, the delay is in this
                    -- block, not in the trip itself.
                    trace(("return: leaving %.2fs after the carry landed")
                        :format(os.clock() - (BX.carryConfirmedAt or os.clock())))
                    BX.returnToSafe()
                end

                pcall(BX.stopAntiHit)
            end

            -- BX.lostEgg is set by the drop watch when the server ends our
            -- carry - GuardHit, PlayerSlap, death. The trip home still
            -- finishes, because home is out of the guard's reach and standing
            if BX.lostEgg then
                trace("loop: carry was lost (" .. tostring(BX.lostEgg) .. "), re-targeting now")
                BX.lostEgg = nil
                idleCycles = idleCycles + 1
                continue
            end
        end

        task.wait(stealDelay)
    end
end

---------- CHARACTER RESPAWN ----------

BlyxoTop.charAdded = LocalPlayer.CharacterAdded:Connect(function()
    task.wait(1)
    -- The anticheat state table is per-character, so the cached one is stale
    -- the moment we respawn. Re-find it before anything moves.
    --
    -- This used to refresh only BX.acState, and only when BX.spoofConn was
    -- already set - so BX.acStates, which is the list the travel gate actually
    -- reads, kept the previous character's table and the spoof spent the rest
    -- of the session writing to a corpse. Clear both, always, then re-arm.
    BX.acState = nil
    BX.acStates = {}
    BX.acScanFails = 0
    BX.carryDeepFloor = nil
    pcall(BX.findAcState, true)
    pcall(BX.acArm)
    trace(("respawn: re-armed the anticheat state (%d table(s) live)")
        :format(#(BX.acStates or {})))
    -- apply unconditionally, the reference build does this on every spawn
    pcall(BX.swapHumanoid)
    if stealing then
        bypassAnticheat()
        setupAntiDeath()
        antiRagdoll()
    end
end)

---------- UI: MAIN TAB ONLY ----------

-- Every other tab (Event, Eggs, Teleports, Misc) and its features have been
-- removed. This is the whole surface now: pick an egg, steal it.

-- One table instead of nine top-level locals: Luau caps a function at 200
-- and the main chunk was at 195, which is what "Out of local registers when
-- trying to allocate showSelected" meant.
local UI = {}

-- One table for everything the tabs below need. The main chunk is near Luau's
-- 200-local ceiling, so each of these being its own local is not affordable -
-- than after the Main tab because X.el (below) has to exist before the first
-- Declared far above, before stealLoop - see the note there. This is the
-- assignment, not the declaration.
X = {}

-- Handles to the elements that own a persisted setting. The Config tab reads
-- and writes them; without a handle a loaded profile changes the variable but
-- leaves the widget showing the old value, which reads as "load did nothing".
X.el = {}

-- HOME. Created before Main because tab order is creation order.
--
-- CreateText is used rather than Stat/Progress because its update methods are
-- THE VERSION AS A PILL, NOT AS PART OF THE SUBTITLE.
--
-- Rayfield has a tag strip beside the title for exactly this. Window:CreateTag
-- takes `text` or `title` - `name` is silently not one of its keys, and the
-- constructor asserts "A Tag requires an icon, text, or both" if you use it.
-- Colour defaults to an orange (255,175,15); this matches the Mono accent the
-- hub now loads with.
pcall(function()
    Window:CreateTag({ title = "V3.1", color = Color3.fromRGB(206, 206, 212) })
end)

-- OUR LOGO ON THE "TAP TO SHOW" PILL, NOT RAYFIELD'S.
--
-- The `icon` passed to CreateWindow only reaches the title bar. The collapsed
-- pill has its own ImageLabel, CollapsedIcon, hard-wired to the Rayfield logo
-- (rbxassetid://80387863064905). Swap it for ours, and hold it there: if the
-- library ever writes its logo back, the change signal puts ours back.
task.spawn(function()
    local LOGO = "rbxassetid://95108798243406"
    for _ = 1, 40 do
        local icon = nil
        for _, root in ipairs({ (gethui and gethui()) or nil, game:GetService("CoreGui") }) do
            -- FindFirstChild(name, true) is a native search, far cheaper than
            -- walking GetDescendants of CoreGui in Luau every retry.
            local ok, d = pcall(function() return root:FindFirstChild("CollapsedIcon", true) end)
            if ok and d and d:IsA("ImageLabel") and d.Parent and d.Parent.Name == "BlyxoHub" then
                icon = d
                break
            end
        end
        if icon then
            icon.Image = LOGO
            BlyxoTop.logoGuard = icon:GetPropertyChangedSignal("Image"):Connect(function()
                if icon.Image ~= LOGO then icon.Image = LOGO end
            end)
            return
        end
        task.wait(0.25)
    end
end)

-- Tabs are text only, on purpose: the icons were tried (Lucide names that
-- never resolved, then Material) and the sidebar reads cleaner without them.
local HomeTab = Window:CreateTab({ name = "Home" })

HomeTab:CreateSection({ name = "Discord" })

-- ONE ELEMENT, NOT TWO.
--
-- This used to be a Text saying "discord.gg/..." sitting above a Button that
-- copied the same link. Two rows, one fact, and nothing explaining why they
-- were separate. The invite is what the button DOES, so it belongs in the
-- button's description.
HomeTab:CreateButton({
    name = "Join Discord",
    description = "discord.gg/9KSXyabAYV",
    callback = function()
        local invite = "https://discord.gg/9KSXyabAYV"
        local copied = false
        for _, fn in pairs({ setclipboard, toclipboard, set_clipboard }) do
            if type(fn) == "function" and pcall(fn, invite) then copied = true break end
        end
        -- Blocked on some executors (Madium answers "attempt to call a blocked
        -- function"), so it is best-effort and the clipboard is the real path.
        pcall(function() game:GetService("GuiService"):OpenBrowserWindow(invite) end)
        print("[BLYXO] Discord: " .. invite)
        toast(copied and "Invite copied to clipboard" or ("Join at " .. invite))
    end,
})

HomeTab:CreateSection({ name = "Updates" })

-- WHAT CHANGED, IN PLAIN WORDS.
--
-- One line per change, written as the thing you can now do - not as the code
-- that does it. Newest at the top, and it stops at five: a changelog nobody
-- scrolls is a changelog nobody reads.
HomeTab:CreateText({
    name = "Latest",
    text = "V3.1\n"
        .. "- Stats overlay: session time, FPS and ping (Misc)\n"
        .. "- New loading screen with the Discord built in\n"
        .. "- Cleaner menu: no white outlines, no tab icons\n"
        .. "- BlyxoHub logo on notifications and the hide pill\n"
        .. "\nV3\n"
        .. "- Every Auto Steal now teleports straight to the egg\n"
        .. "- Auto refresh when night ends - no more manual refresh\n"
        .. "- Farm keeps going instead of stopping after one egg\n"
        .. "- Fixed getting caught on the way back with high speed\n"
        .. "- Themes and a background image in Misc\n"
        .. "- Less console spam, lighter on phones\n"
        .. "- Auto collect rift pets (for the eggs)",
})

BlyxoSplash.step("Building Main", 0.7)
local StealTab = Window:CreateTab({ name = "Main" })

-- FIRST THING ON THE TAB. CreateText is the Gen2 element for a title plus a
-- body (docs.sirius.menu/rayfield-gen2/elements/text); it holds no value so it
-- takes no flag.
StealTab:CreateText({
    name = "How it works",
    text = "Pick an egg, turn on Auto Steal. The guard hitting you the first"
        .. " time is meant to happen - it grabs the egg again straight after.",
})

-- WAS 15, and that is the whole "Target Egg does not show all the eggs" bug.
--
-- value, so the cheaper two thirds of the map never appeared.
-- Every entry here is a GUI frame the dropdown has to construct. 80 of them
-- is a visible stall and nobody scrolls that far - the list is sorted best
-- first, so the useful entries are all at the top.
-- 60, SO EVERY EGG ON THE MAP IS SELECTABLE.
--
-- The field holds 53-55 eggs, so 25 showed you less than half and the rest
-- were simply unreachable from the UI - the "some eggs missing from Target
-- Egg" report. The reason it was capped was GUI build cost: Refresh tears
-- down and rebuilds every row, and 80 rows was a visible stall.
--
-- That cost is now conditional. applyOptions compares the option signature
-- first and only rebuilds when the list genuinely changed, so the expensive
-- path runs on a real change rather than on every refresh - which is what
-- made 25 necessary in the first place.
UI.MAX_EGGS = 60

-- Pet name and income only. AssetCategory on the field-egg record IS the pet,
-- read locally, no reveal remote needed.
-- 54 EGGS ON THE FIELD, 31 ROWS IN THE BOX. THAT IS THIS FUNCTION.
--
-- The label was name + income, and UI.labelToUid is keyed BY that label. Two
-- eggs of the same pet earn the same, so they produced the same string: the
-- second overwrote the first in the map and the dropdown showed the same row
-- twice. Counted live on one server - 54 stealable eggs, 31 distinct labels,
-- 23 eggs unreachable. Nearly half the map, and it looked like the list was
-- just short.
--
-- Weight is what separates them, because the scale roll is per egg. The two
-- Dodos that used to be one row are now 7.3kg and 20.4kg. buildOptions still
-- guarantees uniqueness afterwards, for the rare pair that matches on both.
function UI.eggLabel(egg)
    local suffix = ""
    if egg.guardHeld then suffix = "  (guard)"
    elseif egg.dropped then suffix = "  (floor)" end

    -- Name and income, and nothing else. The weight only appears when you have
    -- actually asked to target by weight, because then it is the number you
    -- are choosing on and a list sorted by an invisible field is a guessing
    -- game. Everywhere else it is clutter.
    local weight = ""
    if BX.targetBy == "Weight" then
        local kg = tonumber(egg.kg) or 0
        if kg > 0 then weight = ("  |  %.1fkg"):format(kg) end
    end
    return egg.name .. "  |  " .. formatNumber(egg.value) .. "/s" .. weight .. suffix
end

-- WHAT THE LIST IS SHOWING RIGHT NOW, label -> uid.
--
-- This is the fix for "I select an egg and it never steals it". The labels
UI.labelToUid = {}

function UI.buildOptions()
    local options = {}
    UI.labelToUid = {}
    -- EVERY ROW MUST BE ITS OWN EGG. labelToUid is keyed by the string, so a
    -- repeat silently threw away the egg that got there first. Weight splits
    -- almost all of them; this closes the rest.
    local used = {}
    for i, egg in ipairs(cachedEggs) do
        if i > UI.MAX_EGGS then break end
        local label = UI.eggLabel(egg)
        if used[label] then
            local n = used[label] + 1
            used[label] = n
            label = label .. ("  #%d"):format(n)
        else
            used[label] = 1
        end
        UI.labelToUid[label] = egg.uid
        table.insert(options, label)
    end
    if #options == 0 then
        table.insert(options, "No eggs found")
    end
    return options
end

-- The name is the stable half of a label: everything before the separator.
local function labelName(value)
    if type(value) ~= "string" then return nil end
    local name = value:match("^(.-)%s%s|%s%s")
    return name or value
end

function UI.eggForLabel(value)
    if type(value) ~= "string" or value == "" or value == "No eggs found"
       or value == "Loading..." then
        return nil
    end

    -- 1. The list you clicked on. Exact, and immune to the loop's churn.
    local uid = UI.labelToUid[value]
    if uid then
        for _, egg in ipairs(cachedEggs) do
            if egg.uid == uid then return egg end
        end
        -- Selected while the egg is mid-cycle (carried, guard-held, dropped),
        -- so it is not in the current list. That is still a valid choice -
        -- the loop's own hold logic is built to wait for exactly this.
        return { uid = uid, name = labelName(value) or value }
    end

    -- 2. Exact match against the current labels.
    for _, egg in ipairs(cachedEggs) do
        if UI.eggLabel(egg) == value then return egg end
    end

    -- 3. Name only, so a changed rate or a (guard)/(floor) suffix cannot
    --    cost you the selection.
    local want = labelName(value)
    if want then
        for _, egg in ipairs(cachedEggs) do
            if egg.name == want then return egg end
        end
    end

    return nil
end

-- Forward-declared so the callback can see it. Refresh() and Set() both
-- re-run this callback through the library's guarded dispatcher, so without
-- this flag a single refresh recurses into toast() and back into the UI.
UI.suppress = false

function UI.onDropdown(value)
    if UI.suppress then return end
    -- Single-select hands back a bare string, but .value is always a table, so
    -- accept both rather than depending on which one this build passes.
    if typeof(value) == "table" then value = value[1] end
    local egg = UI.eggForLabel(value)
    if not egg then
        -- Never fail silently here again. This return is what made the bug
        -- invisible: the click did nothing and said nothing.
        trace("target: could not resolve " .. tostring(value) .. " - selection ignored")
        toast("Could not select that egg - refresh and try again")
        return
    end
    selectedEggUid = egg.uid

    -- RESET THE HOLD CLOCK, OR PICKING A NEW EGG KILLS THE LOOP.
    --
    -- selection it had just been given, and - because pickWasUser was true -
    BX.selHoldSince = nil
    BX.selHoldLast = nil
    BX.selHoldUid = egg.uid
    -- Deliberately choosing an egg also forgives an earlier failure to reach
    -- it; otherwise the cooldown quietly outvotes you.
    if BX.unreachable then BX.unreachable[egg.uid] = nil end

    -- You chose this one, so when it is banked the loop stops instead of
    -- helping itself to the next egg. Choosing again clears the hold.
    BX.pickWasUser = true
    BX.awaitUserPick = false
    BX.saidPickOne = false
    trace("target: " .. egg.name .. " (" .. egg.uid .. ")")
    toast("Target: " .. egg.name)
end

-- Deliberately NOT calling evaluateEggs() before the UI exists. Reading game
-- module data ahead of the dropdown builder cost us our Plugin capability and
-- crashed the very next Instance.new.
StealTab:CreateSection({ name = "Steal" })

eggDropdown = StealTab:CreateDropdown({
    name = "Target Egg",
    options = { "Loading..." },
    flag = "TargetEgg",
    callback = UI.onDropdown,
})

function UI.applyOptions(options)
    local d = eggDropdown
    if not d then return false end

    -- DO NOT REBUILD AN IDENTICAL LIST.
    --
    -- d:Refresh() tears down and rebuilds every option frame in the dropdown.
    -- With UI.MAX_EGGS entries that is the freeze you get when Auto Steal
    -- starts: the loop's first act is UI.refresh, which rebuilds the whole
    -- list, and constructing that many GUI rows blocks the frame. None of the
    -- anticheat setup is slow - measured on this client, all of it together is
    -- 13ms - so the dropdown was the whole 2 seconds.
    --
    -- The egg list barely changes between refreshes, so compare first and
    -- rebuild only when it really differs.
    local sig = table.concat(options, "")
    if sig == UI.lastOptionSig then
        UI.labelToUid = UI.labelToUid or {}
        return true
    end
    UI.lastOptionSig = sig

    UI.suppress = true
    local applied, err = pcall(d.Refresh, d, options)

    -- BELT AND BRACES FOR THE CAPABILITY NARROWING - see the long note in
    -- UI.refresh. A yield clears it, so if this is the one thing that threw,
    -- give up a frame and try once more rather than losing the whole list.
    if not applied and tostring(err):find("capability") then
        task.wait()
        applied, err = pcall(d.Refresh, d, options)
        if applied then trace("dropdown: rebuilt after yielding (capability)") end
    end

    if not applied then
        trace("dropdown: :Refresh() threw: " .. tostring(err))
    end

    -- Last resort: drive the element's own state directly. Refresh() is just a
    -- diff over d.options plus a relabel, so if the wrapper throws we can still
    -- seed the list and let Add() build the frames it is missing.
    if not applied then
        local ok, err = pcall(function()
            if type(d.Add) == "function" then
                d.options = {}
                for _, opt in ipairs(options) do d:Add(opt) end
                return true
            end
            error("no Add() either")
        end)
        if ok then
            trace("dropdown: options applied via :Add() loop")
            applied = true
        else
            trace("dropdown: :Add() fallback threw: " .. tostring(err))
        end
    end
    UI.suppress = false

    if not applied then
        trace("dropdown: NO option setter worked - targeting still works, list is cosmetic")
    end
    return applied
end

-- The dropdown kept displaying "Loading..." because replacing the OPTION LIST
-- does not change the SELECTED VALUE - the placeholder from CreateDropdown was
-- WHICH EGG THE SCRIPT PICKS FOR ITSELF.
--
-- Best value that we can also get home. The dropdown stays sorted by value so
-- you can still choose a Titan Temple egg by hand; this is only the automatic
-- choice, and it is where sending ourselves 4000 studs out every cycle was
-- costing eggs.
--
-- Falls back to the plain best if nothing is in budget, because refusing to
-- steal at all is worse than a risky carry.
function UI.bestBankable()
    local eggs = cachedEggs or {}
    local homeP
    pcall(function() homeP = BX.safeZonePos() end)

    if typeof(homeP) == "Vector3" then
        for _, e in ipairs(eggs) do
            if e.grabbable and typeof(e.position) == "Vector3" then
                local d = Vector3.new(e.position.X - homeP.X, 0, e.position.Z - homeP.Z).Magnitude
                if d <= K.CARRY_MAX_DIST then return e end
            end
        end
    end
    for _, e in ipairs(eggs) do
        if e.grabbable then return e end
    end
    return eggs[1]
end

function UI.showSelected()
    local d = eggDropdown
    if not d then return end
    local label
    for _, egg in ipairs(cachedEggs) do
        if egg.uid == selectedEggUid then label = UI.eggLabel(egg) break end
    end

    -- THE BOX MUST NOT SHOW AN EGG THAT IS NOT THE TARGET.
    --
    --     [28.12s] dropdown: value set to Mantaris  |  13M/s
    local auto = UI.bestBankable()
    if not label and auto then
        selectedEggUid = auto.uid
        BX.selHoldSince = nil
        BX.selHoldLast = nil
        BX.selHoldUid = selectedEggUid
        BX.awaitUserPick = false
        BX.saidPickOne = false
        label = UI.eggLabel(auto)
        trace(("target: showing and selecting %s in %s (the old selection is gone)")
            :format(tostring(auto.name), tostring(auto.area)))
    end
    label = label or "No eggs found"
    -- Documented signature is Set(value, skipCallback). Passing skipCallback
    -- is cleaner than our re-entry flag, so use it and keep the flag as a
    -- backstop for the older method names.
    UI.suppress = true
    local ok, err = pcall(d.Set, d, label, true)
    UI.suppress = false
    if not ok then
        trace("dropdown: :Set() threw: " .. tostring(err))
    elseif label ~= BX.lastDropdownLabel then
        BX.lastDropdownLabel = label
        trace("dropdown: value set to " .. tostring(label))
    end
end

function UI.refresh(force)
    -- REBUILDING THE UI RE-FIRES ITS OWN CALLBACKS.
    --
    -- applyOptions tears down and rebuilds the dropdown, and the library
    -- re-dispatches every control it touches - including the Auto Steal
    -- toggle, with whatever value it had cached. The trace shows it plainly:
    --
    --     autosteal: callback value=true ... UNPROMPTED FLIP
    --     stealLoop: begin
    --     autosteal: ON
    --     autosteal: callback value=false ... UNPROMPTED FLIP   (1.05s later)
    --     autosteal: OFF
    --
    -- Turning the toggle on starts the loop, the loop refreshes the list, the
    -- refresh re-fires the toggle with a stale false, and Auto Steal switches
    -- itself off about a second after you press it. That is "I enabled it and
    -- it did nothing".
    --
    -- This flag lets the toggle tell a real click from the library talking to
    -- itself. See the guard at the top of the Auto Steal callback.
    UI.refreshing = true

    -- Every game-module touch in the evaluation happens on a disposable
    -- scheduler thread, so the dropdown calls below still hold the Plugin
    -- capability they need to build option frames.
    cachedEggs = BX.offthread(function() return evaluateEggs(force ~= false) end) or {}

    -- YIELD ONCE. THIS ONE LINE IS "IT DID NOT DETECT THE SECRET COSMIC EGG".
    --
    -- Luau narrows a thread's capabilities the moment it calls into a game
    -- module, and it stays narrowed until that thread next yields. Measured on
    -- a live client, on one thread, in this order:
    --
    --     Instance write, fresh thread .............. OK
    --     EggState.ReadFieldEggs(), then write ...... "The current thread
    --         cannot access 'Instance' (lacking capability Plugin)"
    --     task.wait(), then write ................... OK
    --
    -- The auto-refresh watcher reads the field with ReadFieldEggs and, on the
    -- SAME thread with nothing in between, calls this function. offthread does
    -- not save it either: evaluateEggs never yields, so its spawned thread
    -- finishes synchronously, the `while not done` loop never runs, and no
    -- yield ever happens. Every Instance call below then threw:
    --
    --     dropdown: :Refresh() threw: ... lacking capability Plugin
    --     dropdown: :Add() fallback threw: ... lacking capability Plugin
    --     dropdown: NO option setter worked - targeting still works, list is cosmetic
    --     dropdown: :Set() threw: ... lacking capability Plugin
    --
    -- and that is the whole bug. The hub SAW the new egg - the same pass logged
    -- "eggs: 55 stealable, best Koi 12305461/s" - it just could not put it in
    -- the list, so the dropdown kept showing the field from before the respawn.
    -- A secret that spawns while you are watching never appears.
    --
    -- One frame. Every caller is covered, whatever thread it came in on.
    task.wait()

    UI.applyOptions(UI.buildOptions())
    -- Auto-target the best egg so the script works without touching the list.
    if #cachedEggs > 0 then
        local stillThere = false
        for _, e in ipairs(cachedEggs) do
            if e.uid == selectedEggUid then stillThere = true break end
        end
        -- Only auto-target when nothing is chosen yet, or Follow Best is on.
        -- Reassigning a user's explicit pick just because it briefly left the
        -- list is how you end up stealing something you did not ask for.
        if not stillThere and (BX.followBest or not selectedEggUid)
           and not BX.awaitUserPick then
            selectedEggUid = cachedEggs[1].uid
            trace("target: auto-selected " .. cachedEggs[1].name)
        end
    end
    UI.showSelected()
    UI.refreshing = false
    trace("refresh: done")
    return cachedEggs
end

task.spawn(function()
    task.wait(1)
    pcall(UI.refresh, true)
end)

---------- WALK SPEED ----------
--
-- MEASURED IN THE LIVE CLIENT, and it corrects two things this file was built
--          allowed = WalkSpeed * 1.7 * dt + 14 + velocity * dt
--      budget quoted all through this file only arms INSIDE the Monster Event
--   2. NOTHING IS PUSHING WALKSPEED BACK. Sampled ten times over 2.5s: a flat
--      ResolveFinalWalkSpeed(our Speed stat) returns. The SERVER is the one
--      holding us at 300. The once-a-second SetWalkSpeed described elsewhere

-- WALKSPEED CONTROL REMOVED.
--
-- raised WalkSpeed stick - is gone by request. Nothing in this hub writes
-- Humanoid.WalkSpeed on the user's behalf any more; whatever the server's
-- WalkSpeedGovernor sets is what we move at, and BX.legalWalkSpeed() is the

StealTab:CreateButton({
    name = "Refresh Eggs",
    callback = function()
        local ok, err = pcall(UI.refresh, true)
        if not ok then
            trace("refresh: ERROR " .. tostring(err))
            toast("Refresh failed")
            return
        end
        if #cachedEggs > 0 then
            toast(#cachedEggs .. " eggs | best " .. cachedEggs[1].name)
        else
            toast("No eggs found")
        end
    end,
})

---------- FARM ----------

X.el.autoSteal = StealTab:CreateToggle({
    name = "Auto Steal",
    flag = "AutoSteal",
    callback = function(value)
        -- THE TOGGLE WAS SWITCHING ITSELF OFF, AND THIS IS WHY.
        --
        --     [28.79s] autosteal: ON
        --     [30.66s] hover: speed hold OFF     <- teardown, unprompted
        --     [30.68s] autosteal: OFF
        value = value and true or false

        -- IGNORE THE LIBRARY TALKING TO ITSELF.
        --
        -- UI.refresh rebuilds the dropdown, and rebuilding re-dispatches this
        -- callback with a stale value. Since the loop refreshes the list the
        -- moment it starts, that fed straight back and switched Auto Steal off
        -- about a second after every press. A real click never lands inside
        -- UI.refreshing, so this costs nothing and closes the loop.
        if UI.refreshing then
            trace(("autosteal: ignoring value=%s - fired by the UI refresh, not a click")
                :format(tostring(value)))
            return
        end

        local age = BX.autoStealSetAt and (os.clock() - BX.autoStealSetAt) or -1
        trace(("autosteal: callback value=%s (current=%s, %.2fs since the last one)")
            :format(tostring(value), tostring(stealing), age))
        if value ~= stealing and age >= 0 and age < 3 then
            local ok, tb = pcall(function() return debug.traceback() end)
            trace("autosteal: UNPROMPTED FLIP - caller stack:\n" .. (ok and tostring(tb) or "no traceback"))
        end
        BX.autoStealSetAt = os.clock()

        if value == stealing then
            -- Already in this state; nothing to do either way.
            return
        end

        stealing = value
        if value then
            stealThread = task.spawn(function()
                -- Outside the library's dispatch now, so this cannot re-enter
                -- the toggle.
                pcall(UI.refresh, true)
                stealLoop()
            end)
            pcall(BX.startVoidWatch)
            trace("autosteal: ON")
            toast("Auto Steal ON")
        else
            BX.holdGen = (BX.holdGen or 0) + 1
            if stealThread then pcall(task.cancel, stealThread) stealThread = nil end
            pcall(BX.stopVoidWatch)
            -- Drop the raised WalkSpeed/HipHeight, or the character keeps
            -- hovering at 400 studs/s with Auto Steal visibly off.
            pcall(BX.stopSpeedHold)
            pcall(BX.acUnhook)
            pcall(BX.stopSpoofHold)
            pcall(BX.stopAntiHit)
            stopMovement()
            disableNoclip()
            stopProtect()
            stopACEnforce()
            stopGuardEnforce()
            restoreAllGuards()
            carryLocked = false
            heldEggUid = nil
            heldEggSlotKey = nil
            for _, c in ipairs(antiDeathConns) do pcall(function() c:Disconnect() end) end
            restoreAntiDeath()
            -- Give jumping back: the controls still point at the humanoid the
            -- swap destroyed. Only now, never mid-steal.
            pcall(function() BX.repointControls(getHumanoid()) end)
            trace("autosteal: OFF")
            toast("Auto Steal OFF")
        end
    end,
})

-- ANTI HIT, MOVEMENT, MOVE SPEED and STEAL DELAY are no longer settings.
--
-- Movement is always the tween. Instant TP is removed from the UI because it
-- cannot work - measured on this account, empty-handed:
--   2256-stud hold: client sits on the pad for the whole hold, and 0.25s after
--   we stop asserting it the server puts us back. It never adopted it.
--   Chained legal jumps do not help either: 10 x 200 asked, 93 kept.
-- The server simply never believes a long teleport, so there is nothing at the
BX.antiHitEnabled = true
BX.carryMoveMode = "Tween"

-- THE ESP BUILDS ITS DATA ON ONE THREAD AND DRAWS IT ON ANOTHER.
--
-- MEASURED IN THE LIVE CLIENT, this session, and this is the whole reason the
-- overlay never appeared:
-- and then tried to parent a card lost the card, silently, because every ESP
--                    to be narrowed because it is discarded immediately. It
--                    the drawing thread can never be narrowed and the parent
-- Diagnostics that cost frames are opt-in now.
BX.forensicsEnabled = false   -- hooks all 138 remotes; only for post-mortems
BX.carrySamples = false       -- one formatted trace line 4x a second while carrying

BX.espOn = false
BX.espPool = {}
K.ESP_NAME = "BlyxoESP"
K.ESP_REFRESH = 0.4
K.ESP_MAX = 250

-- MEASURE THE CLIENT ALL SESSION, NOT ONCE.
--
-- This used to sample 4 seconds, 3 seconds after load, and decide for the
-- whole session. A phone that starts at 40 and sinks to 21 once it is farming
-- - ESP up, carrying, a full server - never got low-end mode at all: reported
-- on a Samsung S23 at 21fps, the laggy state where guards land hits. Now a
-- frame count runs the whole time (one increment per frame, nothing else),
-- every 5s it is averaged, and two low windows in a row (~10s) switch
-- low-end mode on. Touch devices use 30 rather than 25: a phone at 25-30 is
-- already struggling. Once on it stays on for the session - flipping back and
-- forth would rebuild things twice for nothing.
-- (A function, not a `do` block: the main chunk is at the register ceiling.)
;(function()
    local frames = 0
    BlyxoTop.liteFrames = RunService.Heartbeat:Connect(function() frames = frames + 1 end)

    local function goLite(fps)
        if liteMode then return end
        liteMode = true
        BX.lite = true   -- mirrored for anything that wants to read it
        -- Draw less, poll less. None of this changes whether a steal works.
        K.ESP_MAX = 30           -- cards drawn at all: the 30 best eggs
        K.ESP_REFRESH = 1.0      -- was 0.4
        K.ESP_VIS_HZ = 6         -- was 20
        K.ESP_BUILD_PER_PASS = 5 -- was 12: fewer new cards per refresh
        -- NOT UI.MAX_EGGS. Cutting the dropdown to 15 of 53 eggs HIDES
        -- eggs, which is a loss of function, not of decoration - it is
        -- the "some eggs missing from Target Egg" report. Lite mode may
        -- only make things cheaper to DRAW, never fewer to choose from.
        K.BOSS_DODGE_GAP = 0.12  -- was 0.08
        trace(("lite mode ON - %.0f fps, trimming the UI and ESP"):format(fps))
        toast(("Low-end mode on (%.0f fps)"):format(fps))
    end

    task.spawn(function()
        local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
        local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
        local limit = touch and 30 or LITE_FPS
        local lowWindows, first = 0, true
        task.wait(3)   -- skip the load spike
        while not liteMode do
            if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
            frames = 0
            local t0 = os.clock()
            task.wait(5)
            local fps = frames / math.max(os.clock() - t0, 0.001)
            if first then
                first = false
                trace(("client runs at %.0f fps%s"):format(fps, fps < limit and "" or " - full detail"))
            end
            if fps < limit then
                lowWindows = lowWindows + 1
                if lowWindows >= 2 then goLite(fps) end
            else
                lowWindows = 0
            end
        end
        -- Nothing left to decide: stop counting.
        pcall(function() BlyxoTop.liteFrames:Disconnect() end)
    end)
end)()

local function espHex(c)
    if typeof(c) ~= "Color3" then return "#DDDDDD" end
    return ("#%02X%02X%02X"):format(
        math.clamp(math.floor(c.R * 255 + 0.5), 0, 255),
        math.clamp(math.floor(c.G * 255 + 0.5), 0, 255),
        math.clamp(math.floor(c.B * 255 + 0.5), 0, 255))
end

local function espEscape(t)
    return (tostring(t):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- EVERYTHING THAT TOUCHES THE GAME HAPPENS HERE, AND NOWHERE ELSE.
--
-- loop, so with Auto Steal off its positions are from whenever you last
-- opened the menu. evaluateEggs further hides anything in stolenUids for 120s
-- WHERE THE CARD TEXT COMES FROM, resolved here so the drawing thread never
-- has to ask: ReplicatedStorage.Data.Assets.Directory[AssetCategory] gives
function BX.espEggs()
    local out = {}
    local data = BX.snapshot(true)
    if not (data and type(data.Records) == "table") then return out end

    for _, rec in ipairs(data.Records) do
        if type(rec) == "table" and rec.Uid
           and typeof(rec.BoundsCFrame) == "CFrame"
           -- Slot and Dropped are on the ground; GuardCarried is being walked
           -- home and is still a real egg you want to see. Carried (another
           -- player has it) and Claimed (banked) are gone.
           and (rec.State == "Slot" or rec.State == "Dropped"
                or rec.State == "GuardCarried") then

            -- BottomCFrame first. That is the egg's base; BoundsCFrame is the
            -- slot volume and sits lower, which is why cards read as buried
            -- same way, bottom + 4 studs, then falls back to bounds.
            local pos = rec.BoundsCFrame.Position
            if typeof(rec.BottomCFrame) == "CFrame" then
                pos = rec.BottomCFrame.Position + Vector3.new(0, 4, 0)
            end

            local e = {
                uid = rec.Uid,
                position = pos,
                title = tostring(rec.AssetCategory or "Egg"),
                sub = "",
                icon = "",
                accent = Color3.fromRGB(194, 142, 54),
                tall = false,
                value = 0,
            }

            -- One un-streamed asset category must not take the whole overlay
            -- down with it, so every directory touch is individually guarded.
            local dir
            pcall(function() dir = AssetsDir and AssetsDir[rec.AssetCategory] or nil end)

            pcall(function()
                e.title = (dir and dir.DisplayName) or getEggDisplayName(rec) or e.title
            end)
            pcall(function() e.value = calcEggValue(rec) or 0 end)

            local rarityName, rarityColor = "?", Color3.fromRGB(200, 200, 200)
            pcall(function()
                if dir and dir.Rarity then
                    rarityName = dir.Rarity.DisplayName or dir.Rarity._id or rarityName
                    if typeof(dir.Rarity.Color) == "Color3" then
                        rarityColor = dir.Rarity.Color
                    end
                else
                    rarityName = getEggRarity(rec) or rarityName
                end
            end)
            e.accent = rarityColor

            -- SUB: rate, then the rarity in its own colour, then weight. The
            -- rarity is the thing your eye should catch and it sits
            -- mid-sentence, so it is inline RichText rather than its own label.
            local bits = { formatNumber(e.value) .. "/s" }
            bits[#bits + 1] = ('<font color="%s"><b>%s</b></font>')
                :format(espHex(rarityColor), espEscape(rarityName))

            pcall(function()
                local kg = dir and dir.Egg and tonumber(dir.Egg.WeightKg)
                if kg then
                    bits[#bits + 1] = (kg >= 100 and ("%.0fkg"):format(kg)
                        or ("%.1fkg"):format(kg))
                end
            end)
            if rec.State == "GuardCarried" then bits[#bits + 1] = "guard"
            elseif rec.State == "Dropped" then bits[#bits + 1] = "floor" end

            local line = table.concat(bits, "  \u{B7}  ")

            -- Mutations get their own line and the card grows to fit rather
            -- than truncating them - a mutated egg is the one you care about.
            pcall(function()
                if type(rec.Mutations) == "table" and #rec.Mutations > 0 then
                    local names = {}
                    for _, m in ipairs(rec.Mutations) do
                        names[#names + 1] = espEscape(
                            type(m) == "table" and (m._id or m.DisplayName or "?") or m)
                    end
                    if #names > 0 then
                        line = line .. "\n" .. table.concat(names, " \u{B7} ")
                        e.tall = true
                    end
                end
            end)
            e.sub = line

            pcall(function() e.icon = tostring((dir and dir.Icon) or "") end)

            out[#out + 1] = e
        end
    end

    -- Best first, so the cap (if it is ever reached) drops the eggs you care
    -- least about rather than an arbitrary slice.
    table.sort(out, function(a, b) return (a.value or 0) > (b.value or 0) end)
    return out
end

function BX.espFolder()
    local f = workspace:FindFirstChild(K.ESP_NAME)
    if f and f:IsA("Folder") then return f end
    f = Instance.new("Folder")
    f.Name = K.ESP_NAME
    f.Parent = workspace
    return f
end

-- One card. Built once, then reused for whatever egg lands in this slot.
local function espMakeCard()
    local anchor = Instance.new("Part")
    anchor.Name = "EggAnchor"
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanQuery = false
    anchor.CanTouch = false
    anchor.CastShadow = false
    anchor.Transparency = 1
    anchor.Size = Vector3.new(0.2, 0.2, 0.2)
    anchor.Parent = BX.espFolder()

    local bb = Instance.new("BillboardGui")
    bb.Name = "EggCard"
    bb.AlwaysOnTop = true
    bb.LightInfluence = 0
    -- Not math.huge: the property is a float and some clients reject inf.
    bb.MaxDistance = 1e6
    bb.Size = UDim2.fromOffset(190, 40)
    bb.StudsOffset = Vector3.new(0, 3, 0)
    bb.Active = false
    bb.Adornee = anchor
    -- ON THE PART, not in a ScreenGui. See the note at the top of this
    -- section: a protected container needs a capability the drawing thread
    -- may not have, and this needs none.
    bb.Parent = anchor

    local frame = Instance.new("Frame")
    -- Offset, not scale: the UIScale below does the growing, and the
    -- billboard is sized to match (see BlyxoEspScale), so the card is scaled
    -- exactly once.
    frame.Size = UDim2.fromOffset(190, 40)
    frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    frame.BackgroundTransparency = 0.42
    frame.BorderSizePixel = 0
    frame.ClipsDescendants = true
    frame.Parent = bb

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    -- ONE KNOB FOR THE WHOLE CARD. A BillboardGui sized in Offset is a
    -- CONSTANT PIXEL SIZE at any distance - that is why the cards ballooned
    local scale = Instance.new("UIScale")
    scale.Scale = 1
    scale.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.78
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = frame

    -- Rarity bar down the left edge.
    local accent = Instance.new("Frame")
    accent.Size = UDim2.new(0, 2, 1, -8)
    accent.Position = UDim2.fromOffset(3, 4)
    accent.BorderSizePixel = 0
    accent.BackgroundColor3 = Color3.fromRGB(194, 142, 54)
    accent.ZIndex = 2
    accent.Parent = frame
    local aCorner = Instance.new("UICorner")
    aCorner.CornerRadius = UDim.new(0, 2)
    aCorner.Parent = accent

    local icon = Instance.new("ImageLabel")
    icon.BackgroundTransparency = 1
    icon.Position = UDim2.fromOffset(9, 8)
    icon.Size = UDim2.fromOffset(24, 24)
    icon.ScaleType = Enum.ScaleType.Fit
    icon.Image = ""
    icon.ZIndex = 2
    icon.Parent = frame

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(38, 3)
    title.Size = UDim2.new(1, -44, 0, 15)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 12
    title.Text = ""
    title.TextColor3 = Color3.fromRGB(246, 242, 234)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextTruncate = Enum.TextTruncate.AtEnd
    title.ZIndex = 2
    title.Parent = frame

    local sub = Instance.new("TextLabel")
    sub.BackgroundTransparency = 1
    sub.Position = UDim2.fromOffset(38, 18)
    sub.Size = UDim2.new(1, -44, 0, 20)
    sub.Font = Enum.Font.Gotham
    sub.TextSize = 10
    sub.Text = ""
    sub.RichText = true
    sub.TextColor3 = Color3.fromRGB(168, 158, 144)
    sub.TextXAlignment = Enum.TextXAlignment.Left
    sub.TextYAlignment = Enum.TextYAlignment.Top
    sub.TextTruncate = Enum.TextTruncate.AtEnd
    sub.ZIndex = 2
    sub.Parent = frame

    return {
        anchor = anchor, bb = bb, frame = frame, stroke = stroke,
        accent = accent, icon = icon, title = title, sub = sub,
        scale = scale, baseH = 40,
    }
end

function BX.espClear()
    for _, c in ipairs(BX.espPool) do
        pcall(function() c.anchor:Destroy() end)
    end
    BX.espPool = {}
    pcall(function()
        local f = workspace:FindFirstChild(K.ESP_NAME)
        if f then f:Destroy() end
    end)
    -- Sweep the ScreenGui older builds put the cards in, so upgrading does not
    -- leave a dead container behind.
    for _, p in ipairs({ (gethui and select(2, pcall(gethui))) or nil,
                         select(2, pcall(game.GetService, game, "CoreGui")) }) do
        pcall(function()
            local g = p and p:FindFirstChild(K.ESP_NAME)
            if g then g:Destroy() end
        end)
    end
end

-- PURE GUI. No module call, no game table, nothing that can narrow this
-- thread - see the note at the top of this section. `eggs` is plain data
-- already resolved by BX.espEggs on a throwaway thread.
function BX.espUpdate(eggs)
    if type(eggs) ~= "table" then return end
    local shown = 0
    -- BUILD A FEW CARDS PER PASS, NOT ALL OF THEM IN ONE FRAME.
    --
    -- Switching Egg ESP on built every card at once: 55 eggs x ~10 instances
    -- (part, billboard, frame, labels, icon, strokes) created and parented in a
    -- single frame - the freeze people saw the moment they toggled it, and far
    -- worse on phones. Twelve new cards per refresh (every K.ESP_REFRESH s)
    -- fills a full field in about two seconds with no spike; cards that
    -- already exist are simply reused, as before.
    local built = 0

    for i, egg in ipairs(eggs) do
        if i > K.ESP_MAX then break end
        if typeof(egg.position) == "Vector3" then
            local card = BX.espPool[shown + 1]
            if not card or not card.anchor or not card.anchor.Parent then
                if built >= (K.ESP_BUILD_PER_PASS or 12) then break end
                built = built + 1
                card = espMakeCard()
                BX.espPool[shown + 1] = card
            end
            shown = shown + 1

            local isTarget = (egg.uid == selectedEggUid)

            -- WRITE ONLY WHAT CHANGED. This rewrote ~8 properties on every
            -- card every K.ESP_REFRESH (0.4s) - over 400 writes a refresh on a
            -- full field, nearly all of them the same value again. The
            -- position is compared on its own (eggs mostly sit still); the
            -- rest is keyed on the card's content.
            if card.lastPos ~= egg.position then
                card.lastPos = egg.position
                card.anchor.CFrame = CFrame.new(egg.position)
            end
            if not card.bb.Enabled then card.bb.Enabled = true end
            local key = table.concat({ egg.uid, tostring(isTarget), tostring(egg.title),
                tostring(egg.sub), tostring(egg.icon), tostring(egg.tall) }, "\0")
            if card.key ~= key then
                card.key = key
                card.title.Text = (isTarget and "\u{25B8} " or "") .. tostring(egg.title)
                card.sub.Text = tostring(egg.sub)
                card.baseH = egg.tall and 52 or 40
                card.frame.Size = UDim2.fromOffset(190, card.baseH)
                local s = card.lastScale or 1
                card.bb.Size = UDim2.fromOffset(190 * s, card.baseH * s)
                card.icon.Image = tostring(egg.icon or "")
                card.icon.Visible = card.icon.Image ~= ""
                card.accent.BackgroundColor3 = egg.accent or Color3.fromRGB(194, 142, 54)

                -- Your target is the one you need to find in a field of 55, so
                -- it is the only one that gets a solid border and a brighter card.
                if isTarget then
                    card.baseAlpha, card.baseStroke = 0.15, 0
                else
                    card.baseAlpha, card.baseStroke = 0.42, 0.78
                end
                -- Applied by the visibility pass, which folds these together
                -- with the distance fade; writing them here would fight it.
                card.lastFade = nil
            end
        end
    end

    -- Park the leftovers rather than destroying them; the count moves up and
    -- down constantly as eggs are taken and respawn.
    for i = shown + 1, #BX.espPool do
        local c = BX.espPool[i]
        if c and c.bb then c.bb.Enabled = false end
    end
    BX.espShown = shown
end

-- KEEP THE CARDS THE SIZE OF WHAT THEY LABEL.
--
-- Offset-sized billboards do not shrink with range, so a card 1500 studs away
-- This runs on RenderStepped because it has to track the camera smoothly; it
-- off, and it touches no game module so the thread can never narrow.
-- I had this scaling by 90/distance, which is why a far egg was a speck and a
K.ESP_MAX_DIST = 1400     -- past this a card is hidden rather than shrunk
K.ESP_FADE_BAND = 250     -- ...with a short fade in over the last stretch

-- THROTTLED. This walked up to K.ESP_MAX cards EVERY RENDERED FRAME, doing a
-- magnitude and several property writes each - at 55 eggs and 120fps that is
-- 6600 distance checks a second for an overlay whose opacity nobody can see
-- changing faster than about 20 times a second.
K.ESP_VIS_HZ = 20

-- CARDS SCALE WITH DISTANCE - BOTH ESPS, SAME RULE.
--
-- Egg ESP was a constant pixel size at any range, so it never told you how
-- far an egg was, and it did not match My Plot ESP. Now a card is 1.25x right
-- next to you and shrinks smoothly to 0.6x at ~500 studs, and stays there -
-- the floor is what stops a far egg turning into a speck, the reason the old
-- 90/distance version was taken out. My Plot ESP calls the same function.
function BlyxoEspScale(dist)
    return math.clamp(1.25 - (tonumber(dist) or 0) / 800, 0.6, 1.25)
end

BlyxoTop.espVis = RunService.RenderStepped:Connect(function()
    if not BX.espOn then return end
    local now = os.clock()
    if now - (BX.espVisAt or 0) < 1 / K.ESP_VIS_HZ then return end
    BX.espVisAt = now
    local cam = workspace.CurrentCamera
    if not cam then return end
    local eye = cam.CFrame.Position
    local pool = BX.espPool
    for i = 1, (BX.espShown or 0) do
        local c = pool[i]
        if c and c.bb and c.anchor and c.anchor.Parent then
            local d = (c.anchor.Position - eye).Magnitude
            local show = d <= K.ESP_MAX_DIST
            if c.bb.Enabled ~= show then c.bb.Enabled = show end
            if show then
                -- Size follows distance (BlyxoEspScale); opacity fades only
                -- over the last K.ESP_FADE_BAND studs, so cards at the edge
                -- of range dissolve instead of popping. The billboard and the
                -- UIScale move together, so the card grows as a whole rather
                -- than overflowing its frame.
                local s = BlyxoEspScale(d)
                if math.abs((c.lastScale or -1) - s) > 0.01 or c.lastH ~= c.baseH then
                    c.lastScale, c.lastH = s, c.baseH
                    if c.scale then c.scale.Scale = s end
                    c.bb.Size = UDim2.fromOffset(190 * s, (c.baseH or 40) * s)
                end
                local fade = math.clamp((K.ESP_MAX_DIST - d) / K.ESP_FADE_BAND, 0, 1)
                if math.abs((c.lastFade or -1) - fade) > 0.02 then
                    c.lastFade = fade
                    c.frame.BackgroundTransparency = 1 - (1 - c.baseAlpha) * fade
                    c.title.TextTransparency = 1 - fade
                    c.sub.TextTransparency = 1 - fade
                    c.icon.ImageTransparency = 1 - fade
                    c.stroke.Transparency = 1 - (1 - c.baseStroke) * fade
                end
            end
        end
    end
end)

-- THIS THREAD IS THE DRAWING THREAD AND MUST STAY CLEAN. It is spawned from
-- the main chunk, so it starts with full capabilities; the only thing it ever
task.spawn(function()
    local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
    while true do
        if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
        task.wait(K.ESP_REFRESH)
        if BX.espOn then
            local eggs = BX.offthread(function() return BX.espEggs() end, 3)
            if BX.espOn then pcall(BX.espUpdate, eggs) end
        end
    end
end)

-- No toggles for the travel shape. Arc travel IS how Auto Steal moves now -
-- it is not an option sitting beside the old movers, it replaces them.

StealTab:CreateSection({ name = "ESP" })

StealTab:CreateToggle({
    name = "Egg ESP",
    description = "Shows every egg through walls",
    value = false,
    flag = "EggESP",
    callback = function(v)
        BX.espOn = v and true or false
        if BX.espOn then
            trace("esp: ON")
            toast("Egg ESP ON")
        else
            pcall(BX.espClear)
            trace("esp: OFF")
            toast("Egg ESP OFF")
        end
    end,
})

-- ============================================================================
-- MY PLOT ESP - the eggs you have placed, and when each one hatches
-- ============================================================================
--
-- Egg ESP above draws FIELD eggs (EggState.ReadFieldEggs). Eggs you have
-- placed on your plot are not in that table at all. What the game has:
--   * Workspace.PlacedEggRenders.<UserId>_<eggUid>  - the model on the plot
--   * EggState.ReadOwnerEggs(UserId)[eggUid]       - the record, with
--       Placement.PlacedAt (server time) and GrowthSpeedMultiplier
--   * Data.Assets.Directory[AssetCategory].Egg     - DisplayName, GrowthTime
--   * EggState.IsReadyToHatch(eggUid)              - the game's own verdict
-- so it hatches at PlacedAt + GrowthTime / GrowthSpeedMultiplier (a Stag Egg:
-- 10800s, three hours).
--
-- Same threading rule as Egg ESP: game modules are read on a throwaway thread
-- (BX.offthread) every 5s; the cards and the once-a-second countdown run on a
-- clean thread that never touches a module. Own folder, so switching Egg ESP
-- off never takes these with it. In its own function: the main chunk is at
-- the 200-local ceiling.
;(function()
    local on = false
    local cards = {}          -- uid -> card
    local latest = {}         -- last data pass
    local FOLDER = "BlyxoPlotESP"
    local GREEN = Color3.fromRGB(87, 242, 135)

    local function folder()
        local f = workspace:FindFirstChild(FOLDER)
        if f then return f end
        f = Instance.new("Folder")
        f.Name = FOLDER
        f.Parent = workspace
        return f
    end

    local function clear()
        cards = {}
        local f = workspace:FindFirstChild(FOLDER)
        if f then pcall(function() f:Destroy() end) end
    end

    local function fmtLeft(s)
        s = math.max(0, math.floor(s))
        local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
        if h > 0 then return ("%dh %02dm"):format(h, m) end
        if m > 0 then return ("%dm %02ds"):format(m, s % 60) end
        return ("%ds"):format(s)
    end

    -- Game side. Plain data out; nothing here builds an Instance.
    local function readPlot()
        local out = {}
        local rendered = workspace:FindFirstChild("PlacedEggRenders")
        if not rendered then return out end
        local me = LocalPlayer.UserId
        local prefix = tostring(me) .. "_"
        local recs = {}
        pcall(function() recs = EggState.ReadOwnerEggs(me) or {} end)
        for _, m in ipairs(rendered:GetChildren()) do
            if m:IsA("Model") and m.Name:sub(1, #prefix) == prefix then
                local uid = m.Name:sub(#prefix + 1)
                local rec = recs[uid]
                local e = {
                    uid = uid, pos = nil, title = "Egg", rarity = "",
                    color = Color3.fromRGB(200, 200, 200), icon = "", muts = "",
                    readyAt = nil, ready = false, value = 0,
                }
                pcall(function() e.pos = m:GetPivot().Position end)
                if rec then
                    local dir
                    pcall(function() dir = AssetsDir and AssetsDir[rec.AssetCategory] end)
                    -- THE PET INSIDE, NOT THE SHELL - the same thing Egg ESP
                    -- shows. AssetCategory is the pet; its DisplayName and
                    -- Icon are what hatches, and calcEggValue prices it
                    -- exactly as it prices a field egg.
                    pcall(function()
                        e.title = (dir and dir.DisplayName ~= "" and dir.DisplayName)
                            or tostring(rec.AssetCategory)
                        e.icon = tostring((dir and dir.Icon) or "")
                    end)
                    pcall(function()
                        e.value = calcEggValue({
                            Uid = uid, AssetCategory = rec.AssetCategory,
                            AssetScale = rec.AssetScale, Mutations = rec.Mutations,
                        }) or 0
                    end)
                    pcall(function()
                        if dir and dir.Rarity then
                            e.rarity = tostring(dir.Rarity.DisplayName or dir.Rarity._id or "")
                            if typeof(dir.Rarity.Color) == "Color3" then e.color = dir.Rarity.Color end
                        end
                    end)
                    pcall(function()
                        local grow = dir and dir.Egg and tonumber(dir.Egg.GrowthTime)
                        local placed = rec.Placement and tonumber(rec.Placement.PlacedAt)
                        local mult = math.max(tonumber(rec.GrowthSpeedMultiplier) or 1, 0.01)
                        if grow and placed then e.readyAt = placed + grow / mult end
                    end)
                    pcall(function()
                        if type(rec.Mutations) == "table" and #rec.Mutations > 0 then
                            local names = {}
                            for _, mu in ipairs(rec.Mutations) do
                                names[#names + 1] = tostring(type(mu) == "table"
                                    and (mu.DisplayName or mu._id or "?") or mu)
                            end
                            e.muts = table.concat(names, " \u{B7} ")
                        end
                    end)
                end
                pcall(function() e.ready = EggState.IsReadyToHatch(uid) == true end)
                if e.pos then out[#out + 1] = e end
            end
        end
        return out
    end

    -- Drawing side. Same look as the Egg ESP cards: dark card, rarity bar,
    -- icon, name, and one line of detail.
    local function makeCard()
        local anchor = Instance.new("Part")
        anchor.Name = "PlotEggAnchor"
        anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.CanTouch = true, false, false, false
        anchor.CastShadow = false
        anchor.Transparency = 1
        anchor.Size = Vector3.new(0.2, 0.2, 0.2)
        anchor.Parent = folder()

        local bb = Instance.new("BillboardGui")
        bb.AlwaysOnTop = true
        bb.LightInfluence = 0
        bb.MaxDistance = 1e6
        bb.Size = UDim2.fromOffset(190, 40)
        bb.StudsOffset = Vector3.new(0, 4, 0)
        bb.Adornee = anchor
        bb.Parent = anchor

        -- Built exactly like an Egg ESP card - 190 wide, offset-sized frame,
        -- one UIScale - so the two scale identically (BlyxoEspScale).
        local frame = Instance.new("Frame")
        frame.Size = UDim2.fromOffset(190, 40)
        frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        frame.BackgroundTransparency = 0.42
        frame.BorderSizePixel = 0
        frame.Parent = bb
        Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
        local scale = Instance.new("UIScale", frame)
        local stroke = Instance.new("UIStroke", frame)
        stroke.Color = Color3.fromRGB(255, 255, 255)
        stroke.Transparency = 0.78

        local bar = Instance.new("Frame")
        bar.Size = UDim2.new(0, 2, 1, -8)
        bar.Position = UDim2.fromOffset(3, 4)
        bar.BorderSizePixel = 0
        bar.Parent = frame
        Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 2)

        local icon = Instance.new("ImageLabel")
        icon.BackgroundTransparency = 1
        icon.Position = UDim2.fromOffset(9, 8)
        icon.Size = UDim2.fromOffset(24, 24)
        icon.ScaleType = Enum.ScaleType.Fit
        icon.Parent = frame

        local title = Instance.new("TextLabel")
        title.BackgroundTransparency = 1
        title.Position = UDim2.fromOffset(38, 3)
        title.Size = UDim2.new(1, -44, 0, 15)
        title.Font = Enum.Font.GothamBold
        title.TextSize = 12
        title.TextColor3 = Color3.fromRGB(246, 242, 234)
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.TextTruncate = Enum.TextTruncate.AtEnd
        title.Parent = frame

        local sub = Instance.new("TextLabel")
        sub.BackgroundTransparency = 1
        sub.Position = UDim2.fromOffset(38, 18)
        sub.Size = UDim2.new(1, -44, 0, 32)
        sub.Font = Enum.Font.Gotham
        sub.TextSize = 10
        sub.RichText = true
        sub.TextColor3 = Color3.fromRGB(168, 158, 144)
        sub.TextXAlignment = Enum.TextXAlignment.Left
        sub.TextYAlignment = Enum.TextYAlignment.Top
        sub.TextTruncate = Enum.TextTruncate.AtEnd
        sub.Parent = frame

        return { anchor = anchor, bb = bb, frame = frame, scale = scale,
                 bar = bar, icon = icon, title = title, sub = sub, baseH = 40 }
    end

    -- Size follows the camera, 20 times a second, same rule as Egg ESP.
    local lastScaleAt = 0
    local scaleConn = RunService.RenderStepped:Connect(function()
        if not on then return end
        local now = os.clock()
        if now - lastScaleAt < (BX.lite and 0.2 or 0.05) then return end
        lastScaleAt = now
        local cam = workspace.CurrentCamera
        if not cam then return end
        local eye = cam.CFrame.Position
        for _, c in pairs(cards) do
            if c.anchor and c.anchor.Parent then
                local s = BlyxoEspScale((c.anchor.Position - eye).Magnitude)
                if math.abs((c.lastScale or -1) - s) > 0.01 or c.lastH ~= c.baseH then
                    c.lastScale, c.lastH = s, c.baseH
                    c.scale.Scale = s
                    c.bb.Size = UDim2.fromOffset(190 * s, c.baseH * s)
                end
            end
        end
    end)

    local function hex(c)
        return ("#%02X%02X%02X"):format(math.floor(c.R * 255 + 0.5),
            math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
    end

    local function draw()
        local now = workspace:GetServerTimeNow()
        local seen = {}
        for _, e in ipairs(latest) do
            seen[e.uid] = true
            local c = cards[e.uid]
            if not c or not c.anchor.Parent then
                c = makeCard()
                cards[e.uid] = c
            end
            c.anchor.CFrame = CFrame.new(e.pos)
            c.bar.BackgroundColor3 = e.color
            c.icon.Image = e.icon
            c.icon.Visible = e.icon ~= ""
            c.title.Text = e.title
            -- Same order as Egg ESP: rate, rarity in its colour - then what
            -- only a placed egg has, the hatch timer. Mutations get their own
            -- line and the card grows to fit, as they do on Egg ESP.
            local bits = {}
            if (e.value or 0) > 0 then bits[#bits + 1] = formatNumber(e.value) .. "/s" end
            if e.rarity ~= "" then
                -- Some rarities are near-black (Secret is #2E2E2E) and vanish
                -- on a dark card; lift those toward white for the text only.
                local c3 = e.color
                if 0.299 * c3.R + 0.587 * c3.G + 0.114 * c3.B < 0.35 then
                    c3 = c3:Lerp(Color3.new(1, 1, 1), 0.6)
                end
                bits[#bits + 1] = ('<font color="%s"><b>%s</b></font>'):format(hex(c3), e.rarity)
            end
            local left = e.readyAt and (e.readyAt - now)
            if e.ready or (left and left <= 0) then
                bits[#bits + 1] = ('<font color="%s"><b>Ready</b></font>'):format(hex(GREEN))
            elseif left then
                bits[#bits + 1] = fmtLeft(left)
            end
            local text = table.concat(bits, "  \u{B7}  ")
            if e.muts ~= "" then text = text .. "\n" .. e.muts end
            c.sub.Text = text
            c.baseH = (e.muts ~= "") and 52 or 40
            c.frame.Size = UDim2.fromOffset(190, c.baseH)
        end
        -- Hatched, picked up or sold: the card goes with it.
        for uid, c in pairs(cards) do
            if not seen[uid] then
                pcall(function() c.anchor:Destroy() end)
                cards[uid] = nil
            end
        end
    end

    local lastRead = 0
    task.spawn(function()
        local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
        while true do
            if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then
                pcall(function() scaleConn:Disconnect() end)
                clear()
                return
            end
            task.wait(1)
            if on then
                if os.clock() - lastRead >= 5 then
                    lastRead = os.clock()
                    latest = BX.offthread(readPlot, 3) or latest
                end
                if on then pcall(draw) end
            end
        end
    end)

    StealTab:CreateToggle({
        name = "My Plot ESP",
        description = "The pet inside each egg on your plot, and when it hatches",
        value = false,
        flag = "PlotESP",
        callback = function(v)
            on = v and true or false
            if on then
                latest, lastRead = {}, 0
                trace("plot esp: ON")
                toast("My Plot ESP ON")
            else
                clear()
                trace("plot esp: OFF")
                toast("My Plot ESP OFF")
            end
        end,
    })
end)()

-- ============================================================================
-- BLYXOHUB USER TAGS - see who else runs the hub, no server involved
-- ============================================================================
--
-- A small BlyxoHub tag over the head of every hub user in the server,
-- yourself included. Only hub users can see it: it is a local BillboardGui in
-- our own container, so nobody without the script has anything to draw.
--
-- HOW HUBS FIND EACH OTHER WITHOUT A SERVER. Clients cannot message each
-- other, but animations you play on your own character DO replicate - track,
-- speed and weight, all of it (checked live: another player's run track read
-- back at Speed 17.596, and weight-0 tracks are listed too). So every hub
-- plays one of Roblox's own default animations (R15 "point", 507770453 - it
-- loads in any game) at weight 0.001, which is invisible, and at a signature
-- speed no real animation uses. Every hub scans the other players' playing
-- tracks for that pair. The speed changes daily (from the server clock, which
-- every Roblox server shares), and today's, yesterday's and tomorrow's are all
-- accepted so the midnight rollover never drops anyone.
--
-- One limit, and it is Roblox's: Auto Steal swaps the Humanoid for a
-- client-only clone (BX.swapHumanoid), and animations on a client-only
-- Humanoid do not replicate. Someone who has run Auto Steal this life is not
-- seen by others until they respawn. Seeing others is unaffected.
--
-- In its own function: the main chunk is at the 200-local ceiling.
;(function()
    local Players = game:GetService("Players")
    local ANIM_R15 = "rbxassetid://507770453"   -- Roblox default "point" (R15)
    local ANIM_R6 = "rbxassetid://128853357"    -- Roblox default "point" (R6)
    local ANIM_NUM = { ["507770453"] = true, ["128853357"] = true }
    local LOGO = "rbxassetid://95108798243406"
    local NEAR, FAR = 35, 60                    -- full until NEAR, gone by FAR
    local FOLDER = "BlyxoMates"

    local function day() return math.floor(workspace:GetServerTimeNow() / 86400) end
    local function sigFor(d) return 0.0101 + (d % 40) * 0.0002 end
    local function isSig(speed)
        local d = day()
        for _, dd in ipairs({ d, d - 1, d + 1 }) do
            if math.abs((tonumber(speed) or 0) - sigFor(dd)) < 0.00004 then return true end
        end
        return false
    end
    local function isBeacon(track)
        local id = track.Animation and track.Animation.AnimationId or ""
        return ANIM_NUM[id:match("%d+$") or ""] == true and isSig(track.Speed)
    end

    ---------- our own beacon ----------

    -- ONE TRACK PER CHARACTER, REUSED - NEVER A NEW ONE EVERY CHECK.
    --
    -- This used to LoadAnimation a brand-new track whenever the old one was
    -- not playing, every 2 seconds, and never destroyed the old one. On a
    -- client where anything stops the track (an emote, the game's own
    -- animation handling, some rigs), that is a new AnimationTrack every
    -- check - ~1800 an hour, all held by the Animator - and the animation
    -- system gets slower and slower: the "it starts lagging and going slow
    -- out of nowhere" after a while. Now the track is loaded once for each
    -- Animator and simply played again if something stopped it; a track from
    -- a previous life or a previous copy of the hub is destroyed, not just
    -- stopped.
    local myTrack, myAnimator, myDay = nil, nil, nil
    local function beacon()
        local ch = LocalPlayer.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        local animator = hum and hum:FindFirstChildOfClass("Animator")
        if not animator or hum.Health <= 0 then return end
        -- A client-only (swapped) Humanoid replicates nothing; do not bother.
        if hum:GetAttribute(BX.SWAP_ATTR) == true then return end
        local d = day()

        if myTrack and myAnimator == animator then
            -- Same character: at most a replay, never a reload.
            if not myTrack.IsPlaying then
                myTrack:Play(0, 0.001, sigFor(d))
            elseif myDay ~= d then
                myTrack:AdjustSpeed(sigFor(d))
            end
            myDay = d
            return
        end

        -- New character (or first run): drop the old track for good, and
        -- any beacon a previous copy of the hub left on this Animator.
        if myTrack then pcall(function() myTrack:Stop(0) myTrack:Destroy() end) end
        for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
            if isBeacon(t) then pcall(function() t:Stop(0) t:Destroy() end) end
        end
        local a = Instance.new("Animation")
        a.AnimationId = (hum.RigType == Enum.HumanoidRigType.R6) and ANIM_R6 or ANIM_R15
        local tr = animator:LoadAnimation(a)
        tr.Priority = Enum.AnimationPriority.Core
        tr.Looped = true
        tr:Play(0, 0.001, sigFor(d))
        myTrack, myAnimator, myDay = tr, animator, d
    end

    ---------- tags ----------

    -- IN THE WORKSPACE, NOT gethui(). Measured: a BillboardGui inside the
    -- protected UI container never renders - its image never even loads -
    -- while the same billboard in a workspace folder, adorned to the head,
    -- does (the Egg ESP cards live in the workspace for the same reason). A
    -- client-made folder is local; nobody else ever sees it.
    local folder
    local function getFolder()
        if folder and folder.Parent then return folder end
        local parent = workspace
        folder = parent:FindFirstChild(FOLDER) or Instance.new("Folder")
        folder.Name = FOLDER
        folder.Parent = parent
        return folder
    end

    local tags = {}   -- player -> { bb, parts = {{obj, prop, rest}}, born, seen, alpha }

    local function makeTag(p)
        local th = BlyxoThemeCurrent or {}
        local bgTop = th.bgTop or Color3.fromRGB(26, 26, 30)
        local bgBot = th.bgBottom or Color3.fromRGB(14, 14, 17)
        local accent = th.accent or Color3.fromRGB(206, 206, 212)
        local element = th.element or Color3.fromRGB(41, 41, 48)

        local bb = Instance.new("BillboardGui")
        bb.Name = "Tag_" .. p.UserId
        bb.AlwaysOnTop = true
        bb.LightInfluence = 0
        bb.MaxDistance = FAR + 5
        bb.Size = UDim2.fromOffset(130, 30)
        bb.StudsOffset = Vector3.new(0, 2.8, 0)
        bb.ResetOnSpawn = false

        local pill = Instance.new("Frame")
        pill.AnchorPoint = Vector2.new(0.5, 0.5)
        pill.Position = UDim2.fromScale(0.5, 0.5)
        pill.AutomaticSize = Enum.AutomaticSize.X
        pill.Size = UDim2.fromOffset(0, 24)
        pill.BackgroundColor3 = Color3.new(1, 1, 1)
        pill.BorderSizePixel = 0
        pill.Parent = bb
        Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)
        local g = Instance.new("UIGradient", pill)
        g.Color = ColorSequence.new(bgTop, bgBot)
        g.Rotation = 90
        local stroke = Instance.new("UIStroke", pill)
        stroke.Color = Color3.new(1, 1, 1)
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        local sg = Instance.new("UIGradient", stroke)
        sg.Color = ColorSequence.new(accent, element)
        sg.Rotation = 90
        local pad = Instance.new("UIPadding", pill)
        pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 8), UDim.new(0, 10)
        local list = Instance.new("UIListLayout", pill)
        list.FillDirection = Enum.FillDirection.Horizontal
        list.VerticalAlignment = Enum.VerticalAlignment.Center
        list.Padding = UDim.new(0, 5)
        list.SortOrder = Enum.SortOrder.LayoutOrder

        local logo = Instance.new("ImageLabel")
        logo.LayoutOrder = 1
        logo.BackgroundTransparency = 1
        logo.Size = UDim2.fromOffset(15, 15)
        logo.Image = LOGO
        logo.ScaleType = Enum.ScaleType.Fit
        logo.Parent = pill

        local text = Instance.new("TextLabel")
        text.LayoutOrder = 2
        text.BackgroundTransparency = 1
        text.AutomaticSize = Enum.AutomaticSize.X
        text.Size = UDim2.fromOffset(0, 16)
        text.Font = Enum.Font.GothamBold
        text.TextSize = 12
        text.TextColor3 = Color3.fromRGB(240, 240, 246)
        text.Text = "BlyxoHub"
        text.Parent = pill

        bb.Parent = getFolder()
        return {
            bb = bb, born = os.clock(), seen = os.clock(), alpha = -1,
            parts = {
                { pill, "BackgroundTransparency", 0.08 }, { stroke, "Transparency", 0.45 },
                { logo, "ImageTransparency", 0 }, { text, "TextTransparency", 0 },
            },
        }
    end

    local function dropTag(p)
        local t = tags[p]
        if t then pcall(function() t.bb:Destroy() end) end
        tags[p] = nil
    end

    local function scan()
        local now = os.clock()
        for _, p in ipairs(Players:GetPlayers()) do
            do
                local ch = p.Character
                local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                local animator = hum and hum:FindFirstChildOfClass("Animator")
                -- You always wear your own tag - no need to detect yourself.
                local found = (p == LocalPlayer)
                if not found and animator then
                    for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do
                        if isBeacon(tr) then found = true break end
                    end
                end
                local head = ch and (ch:FindFirstChild("Head") or ch:FindFirstChild("HumanoidRootPart"))
                if found and head then
                    local t = tags[p] or makeTag(p)
                    t.self = (p == LocalPlayer)
                    tags[p] = t
                    t.seen = now
                    if t.bb.Adornee ~= head then t.bb.Adornee = head end
                elseif tags[p] and now - tags[p].seen > 8 then
                    -- A missed scan or two is normal (respawning, streaming);
                    -- only a sustained absence takes the tag away.
                    dropTag(p)
                end
            end
        end
    end

    -- Distance fade (and a 0.3s fade-in when a tag first appears), 10 times a
    -- second, writing only when the value actually moved.
    local lastFadeAt = 0
    BlyxoTop.mateFade = RunService.RenderStepped:Connect(function()
        local now = os.clock()
        if now - lastFadeAt < (BX.lite and 0.25 or 0.1) or not next(tags) then return end
        lastFadeAt = now
        local cam = workspace.CurrentCamera
        if not cam then return end
        local eye = cam.CFrame.Position
        for _, t in pairs(tags) do
            local head = t.bb.Adornee
            if head and head.Parent then
                local d = (head.Position - eye).Magnitude
                local a = math.clamp((FAR - d) / (FAR - NEAR), 0, 1)
                    * math.clamp((now - t.born) / 0.3, 0, 1)
                -- Your own tag steps aside in first person, where it would
                -- sit right in front of the camera.
                if t.self and d < 2 then a = 0 end
                if math.abs(a - t.alpha) > 0.03 or (a == 0) ~= (t.alpha == 0) then
                    t.alpha = a
                    t.bb.Enabled = a > 0
                    for _, part in ipairs(t.parts) do
                        part[1][part[2]] = 1 - (1 - part[3]) * a
                    end
                end
            end
        end
    end)

    BlyxoTop.mateLeave = Players.PlayerRemoving:Connect(dropTag)

    task.spawn(function()
        local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
        local lastBeacon = 0
        while true do
            if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then
                for p in pairs(tags) do dropTag(p) end
                pcall(function() if folder then folder:Destroy() end end)
                pcall(function() if myTrack then myTrack:Stop(0) myTrack:Destroy() end end)
                return
            end
            -- Our own beacon only needs checking now and then; the scan for
            -- other hub users stays at 2s so tags appear promptly.
            if os.clock() - lastBeacon >= 10 then
                lastBeacon = os.clock()
                pcall(beacon)
            end
            pcall(scan)
            task.wait(BX.lite and 4 or 2)
        end
    end)
end)()

StealTab:CreateSection({ name = "Plot" })

function BX.netCall(name, ...)
    local net = RS.Packages and RS.Packages:FindFirstChild("Networking")
    local rf = net and net:FindFirstChild(name)
    if not rf then return false, "remote not found: " .. name end
    local ok, a, b = pcall(function(...) return rf:InvokeServer(...) end, ...)
    if not ok then return false, tostring(a) end
    return a, b
end

BX.autoDoff = true
K.TREADMILL_PAD = 6
K.TREADMILL_POLL = 1.5

function BX.treadmillPart()
    local plot
    local ok = pcall(function() plot = PlotState.ResolvePlot() end)
    if not ok or type(plot) ~= "table" or not plot.PlotFolder then return nil end
    local p = plot.PlotFolder:FindFirstChild("TreadmillBottom", true)
    if p and p:IsA("BasePart") then return p end
    return nil
end

function BX.onTreadmill()
    local part = BX.treadmillPart()
    local h = getHRP()
    if not part or not h then return false end
    local rel = part.CFrame:PointToObjectSpace(h.Position)
    local half = part.Size * 0.5
    return math.abs(rel.X) <= half.X + K.TREADMILL_PAD
       and math.abs(rel.Z) <= half.Z + K.TREADMILL_PAD
       and math.abs(rel.Y) <= 12
end

task.spawn(function()
    local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
    while true do
        if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
        task.wait(K.TREADMILL_POLL)
        if BX.autoDoff and BX.onTreadmill() then
            local ok, msg = BX.netCall("RF/Treadmill/AskDoff")
            trace(("treadmill: standing on the belt - AskDoff -> %s %s")
                :format(tostring(ok), tostring(msg or "")))
            if ok == true then toast("Got you off the treadmill") end
            task.wait(2)   -- do not re-ask while the server is acting on it
        end
    end
end)

X.el.autoDoff = StealTab:CreateToggle({
    name = "Stay off the treadmill",
    description = "Gets you off the treadmill",
    value = true,
    flag = "AutoDoff",
    callback = function(v)
        BX.autoDoff = v and true or false
        toast("Treadmill guard " .. (BX.autoDoff and "ON" or "OFF"))
    end,
})

StealTab:CreateButton({
    name = "Equip best pets",
    description = "Equips your strongest pets",
    callback = function()
        local ok, msg = BX.netCall("RF/Haul/WearBest")
        trace(("wearbest -> %s %s"):format(tostring(ok), tostring(msg or "")))
        toast(ok == true and "Equipped your best pets" or ("Refused: " .. tostring(msg or ok)))
    end,
})

trace("ui: Main tab built")
---------- EVENT TAB ----------

-- ============================================================================
-- FARM
-- ============================================================================
--
-- Laid out like Main on purpose: one line saying what it does, then the
-- controls, then Refresh and Auto Steal in the same order and the same place.
-- Nobody should have to learn a second tab.
BlyxoSplash.step("Building Farm", 0.78)
local FarmTab = Window:CreateTab({ name = "Farm" })

FarmTab:CreateText({
    name = "How it works",
    text = "Pick what you want, then start Auto Steal HERE and it only takes"
        .. " those. Starting it on Main ignores these and takes everything.",
})

FarmTab:CreateSection({ name = "Steal" })

do
    local AreasMod = needModule(RS, "Data", "Areas")
    local areaNames = {}
    if AreasMod and AreasMod.Directory then
        for name in pairs(AreasMod.Directory) do areaNames[#areaNames + 1] = tostring(name) end
    end
    table.sort(areaNames)
    if #areaNames == 0 then
        areaNames = { "Abyss Ocean", "Cherry Blossom", "Cosmic", "Desert", "Forest",
            "Jungle", "Lake", "Prehistoric", "Snow", "Titan Temple", "Volcano" }
    end

    -- Weakest first, the way the game orders them - Rarity.RarityNumber, 1..10.
    local rarityNames = {}
    do
        local seen, rows = {}, {}
        for _, d in pairs(AssetsDir or {}) do
            local r = d and d.Rarity
            local nm = r and r.DisplayName
            if nm and not seen[nm] then
                seen[nm] = true
                rows[#rows + 1] = { nm = nm, num = tonumber(r.RarityNumber) or 0 }
            end
        end
        table.sort(rows, function(a, b) return a.num < b.num end)
        for _, row in ipairs(rows) do rarityNames[#rarityNames + 1] = row.nm end
    end

    local function toSet(list)
        local set = {}
        if type(list) == "table" then
            for _, v in pairs(list) do set[tostring(v)] = true end
        elseif type(list) == "string" and list ~= "" then
            set[list] = true
        end
        return set
    end

    local function count(set)
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        return n
    end

    -- A FILTER MEANS "KEEP TAKING THESE", NOT "TAKE ONE AND STOP".
    --
    -- Picking a rarity and watching Auto Steal grab one egg and then sit there
    -- is the loop doing what it does for a hand-picked target: on delivery it
    -- clears the selection, sets awaitUserPick, and waits to be told what is
    -- next. Right for one egg you chose by name. Wrong when you have described
    -- a whole category.
    --
    -- It is also why it can sit on a chicken nest while a secret is up in
    -- Prehistoric: holding a selection means never re-reading which egg is
    -- best. followBest is the existing, tested flag for "re-pick every cycle",
    -- so a live filter simply turns it on and gives it back when the filters
    -- are cleared.
    function BX.farmFiltering()
        return count(BX.farmAreas or {}) > 0 or count(BX.farmRarities or {}) > 0
    end

    function BX.syncFollowBest()
        if BX.userFollowBest == nil then
            BX.userFollowBest = BX.followBest and true or false
        end
        local want = BX.farmFiltering() or BX.farmActive or BX.userFollowBest
        if BX.followBest ~= want then
            BX.followBest = want
            BX.awaitUserPick = false
            trace("farm: follow-best " .. (want and "ON (filter active)" or "back to your setting"))
        end
    end

    FarmTab:CreateDropdown({
        name = "Areas",
        options = areaNames,
        multiSelect = true,
        flag = "FarmAreas",
        callback = function(list)
            BX.farmAreas = toSet(list)
            BX.eggCache = nil
            BX.syncFollowBest()
            trace("farm: areas = " .. (count(BX.farmAreas) == 0 and "all" or tostring(count(BX.farmAreas))))
            pcall(UI.refresh, true)
        end,
    })

    FarmTab:CreateDropdown({
        name = "Rarities",
        options = rarityNames,
        multiSelect = true,
        flag = "FarmRarities",
        callback = function(list)
            BX.farmRarities = toSet(list)
            BX.eggCache = nil
            BX.syncFollowBest()
            trace("farm: rarities = " .. (count(BX.farmRarities) == 0 and "any" or tostring(count(BX.farmRarities))))
            pcall(UI.refresh, true)
        end,
    })

    -- PICK BY WEIGHT OR BY INCOME.
    --
    -- The scale roll is per egg, so the same pet turns up at 7.3kg and 20.4kg
    -- on the same map. Income cannot see that difference at all - both rows
    -- said the same number - so weight is a genuinely different target, not a
    -- reordering of the same one.
    FarmTab:CreateDropdown({
        name = "Target By",
        options = { "Income", "Weight" },
        flag = "FarmTargetBy",
        callback = function(v)
            BX.targetBy = (v == "Weight") and "Weight" or "Income"
            BX.eggCache = nil
            trace("farm: targeting by " .. BX.targetBy)
            pcall(UI.refresh, true)
        end,
    })

    FarmTab:CreateButton({
        name = "Refresh Eggs",
        callback = function()
            local ok, err = pcall(UI.refresh, true)
            if not ok then
                trace("refresh: ERROR " .. tostring(err))
                toast("Refresh failed")
                return
            end
            if #cachedEggs > 0 then
                toast(#cachedEggs .. " eggs | best " .. cachedEggs[1].name)
            else
                toast("Nothing matches your filters")
            end
        end,
    })

    -- THE SAME SWITCH, NOT A SECOND ONE.
    --
    -- This does not steal anything itself. It presses the Auto Steal toggle on
    -- Main, so there is exactly one piece of code that starts and stops the
    -- loop and it is the one that already works. The watcher below keeps this
    -- toggle showing the truth when Main is used instead.
    X.el = X.el or {}
    X.el.farmAuto = FarmTab:CreateToggle({
        name = "Auto Steal",
        description = "Same as Main, but only takes what you picked above",
        flag = "FarmAutoSteal",
        callback = function(v)
            if X.farmSyncing then return end
            local el = X.el and X.el.autoSteal
            if not el then
                toast("Auto Steal is not ready yet")
                return
            end
            v = v and true or false

            -- CLAIM THE RUN BEFORE STARTING IT. The stamp is what tells the
            -- watcher below that this start was ours, so the filter goes live
            -- for it. A start from Main carries no stamp and stays unfiltered.
            if v then
                BX.farmActive = true
                BX.farmStartedAt = os.clock()

                -- AND KEEP GOING AFTER THE FIRST ONE.
                --
                -- This is "it only steals one egg and then sits there". On
                -- delivery the loop does:
                --
                --     selectedEggUid = nil
                --     BX.awaitUserPick = true
                --
                -- and then blocks on
                --
                --     if BX.awaitUserPick and not selectedEggUid
                --        and not BX.followBest then task.wait(0.5) continue end
                --
                -- which is right for Main - you picked that egg, you get asked
                -- what is next. It is wrong for Farm, where the whole point is
                -- "take everything matching these filters". followBest is the
                -- flag that means exactly that, so a farm run turns it on and
                -- gives it back when the run ends. Main's own setting is
                -- remembered, not overwritten.
                BX.syncFollowBest()
                trace("farm: starting a FILTERED run (follow-best on)")
            else
                BX.farmActive = false
                BX.syncFollowBest()
            end
            BX.eggCache = nil
            pcall(function() el.Set(el, v) end)

            -- MAIN'S TOGGLE IGNORES ITSELF DURING A REFRESH.
            --
            -- Its callback opens with
            --     if UI.refreshing then ... return end
            -- which protects it from the library re-dispatching stale values.
            -- But a real press from here lands the same way, so pressing Farm's
            -- switch while the egg list happened to be rebuilding did nothing
            -- at all - and the watcher then saw stealing=false and flicked this
            -- toggle back off. It looked like the button refused to stay on.
            task.spawn(function()
                for _ = 1, 12 do
                    task.wait(0.1)
                    if stealing == v then return end
                    if not UI.refreshing then
                        trace("farm: the switch did not take - pressing again")
                        pcall(function() el.Set(el, v) end)
                        return
                    end
                end
            end)
        end,
    })

    task.spawn(function()
        local wasStealing = false
        local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
        while true do
            if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
            task.wait(0.2)

            -- WHOSE RUN IS THIS. A run that starts without Farm having just
            -- stamped it came from Main, so the filter is dropped for it. Two
            -- seconds is generous for the gap between our stamp and the loop
            -- actually flipping `stealing`.
            if stealing and not wasStealing then
                if os.clock() - (BX.farmStartedAt or -99) > 2 then
                    if BX.farmActive then
                        BX.farmActive = false
                        BX.eggCache = nil
                        trace("farm: started from Main - filter off for this run")
                    end
                    -- ...and follow-best goes back to whatever the filters
                    -- and your own setting say it should be. A live filter
                    -- keeps it on even from Main, because a filter means "keep
                    -- taking these"; with no filter it is yours again.
                    BX.syncFollowBest()
                end
            elseif not stealing and wasStealing then
                BX.farmActive = false
                -- The loop can end without anyone touching the toggle - no
                -- eggs left, a teleport, an error. Re-derive rather than
                -- restore a remembered value that may now be wrong.
                BX.syncFollowBest()
            end
            wasStealing = stealing

            -- Mirror Main without touching Main. Setting a toggle re-fires its
            -- own callback, so the flag stops that bouncing straight back.
            pcall(function()
                local el = X.el and X.el.farmAuto
                if not el then return end
                if X.farmAutoShown ~= stealing then
                    X.farmAutoShown = stealing
                    X.farmSyncing = true
                    el.Set(el, stealing)
                    X.farmSyncing = false
                end
            end)
        end
    end)
end

FarmTab:CreateSection({ name = "AFK" })

-- ============================================================================
-- STAY ON TREADMILL
-- ============================================================================
--
-- HOW THE TREADMILL ACTUALLY WORKS, read out of PlayerScripts.Game.Plots.
-- TreadmillStaticController:
--
--     RunService.Heartbeat:Connect(tryEnterStaticTreadmill)
--
-- and tryEnterStaticTreadmill raycasts 8 studs DOWN from your
-- HumanoidRootPart, filtered to your own treadmill render and its belt part.
-- If the ray hits, it calls Treadmill.AskWearStill:InvokeServer() itself.
--
-- So there is nothing for us to fire. The game checks every frame and puts you
-- on the belt the moment you stand over it. This toggle only has to get you
-- there and keep you there, which is why it touches no remotes at all.
do
    function BX.treadmillSpot()
        local slot
        pcall(function() slot = PlotState and PlotState.ResolveLocalSlot() end)
        if not slot then return nil end

        -- Rebuilt by the client on every treadmill upgrade, so look it up
        -- fresh rather than caching it.
        local folder = Workspace:FindFirstChild("__ClientTreadmillRenders")
        local render = folder and folder:FindFirstChild("TreadmillRender_" .. tostring(slot))
        local root = render and render:FindFirstChild("Root")
        if root and root:IsA("BasePart") then
            return root.Position
        end

        -- The belt part on the plot. Measured: 0.001 studs thick, sitting ~4
        -- studs under Root, so stand above it rather than in it.
        local plots = Workspace:FindFirstChild("Plots")
        local plot = plots and plots:FindFirstChild(tostring(slot))
        local bottom = plot and plot:FindFirstChild("TreadmillBottom")
        if bottom and bottom:IsA("BasePart") then
            return bottom.Position + Vector3.new(0, 4, 0)
        end
        return nil
    end

    X.el = X.el or {}
    X.el.treadmill = FarmTab:CreateToggle({
        name = "Stay On Treadmill",
        description = "Stands on your treadmill and keeps you there",
        flag = "StayTreadmill",
        callback = function(v)
            v = v and true or false

            -- ONE THING DRIVES THE CHARACTER AT A TIME. Auto Steal is already
            -- flying you across the map; a hold pulling you back to the plot
            -- is how eggs get dropped mid-carry.
            if v and stealing then
                BX.treadmill = false
                toast("Turn Auto Steal off first")
                trace("treadmill: refused - Auto Steal is running")
                pcall(function()
                    local el = X.el and X.el.treadmill
                    if el then el.Set(el, false) end
                end)
                return
            end

            BX.treadmill = v
            trace("treadmill: " .. (v and "ON" or "OFF"))
            if not v then
                -- YOU HAVE TO ASK THE GAME TO LET YOU OFF.
                --
                -- Switching the hold off only stopped us putting you back. It
                -- did not dismount you, because mounting is the game's own
                -- doing: TreadmillStaticController runs tryEnterStaticTreadmill
                -- on Heartbeat and calls AskWearStill the instant you are stood
                -- over the belt. So you were still wearing it, and stepping off
                -- just put you straight back on the next frame.
                --
                -- Treadmill.AskDoff is the other half of that pair. Call it,
                -- then step clear of the belt so the Heartbeat check does not
                -- immediately re-wear you.
                pcall(function()
                    local R = needModule(RS, "Shared", "Remotes")
                    if R and R.Treadmill and R.Treadmill.AskDoff then
                        R.Treadmill.AskDoff:InvokeServer()
                    end
                end)
                pcall(function()
                    local spot = BX.treadmillSpot()
                    local h = getHRP()
                    if spot and h then
                        h.CFrame = CFrame.new(spot + Vector3.new(0, 3, 14))
                    end
                end)
                toast("Off the treadmill")
                return
            end

            if not BX.treadmillSpot() then
                BX.treadmill = false
                toast("No treadmill on your plot yet")
                trace("treadmill: no render and no belt part for our slot")
                pcall(function()
                    local el = X.el and X.el.treadmill
                    if el then el.Set(el, false) end
                end)
                return
            end
            toast("Heading to your treadmill")
        end,
    })

    task.spawn(function()
        local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
        while true do
            if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
            task.wait(0.5)
            if BX.treadmill and not stealing then
                pcall(function()
                    if heldEggUid then return end
                    local spot = BX.treadmillSpot()
                    local hrp = getHRP()
                    if not spot or not hrp then return end

                    local gap = (hrp.Position - spot).Magnitude
                    if gap > 25 then
                        trace(("treadmill: %.0f studs away, going back"):format(gap))
                        BX.arcTweenTo(spot, K.ARC_SPEED, "treadmill", 4)
                    elseif gap > 3 then
                        -- Drifted off the belt. The entry raycast is only 8
                        -- studs long, so a few studs of slide stops the payout.
                        hrp.CFrame = CFrame.new(spot)
                    end
                end)
            end
        end
    end)
end

BlyxoSplash.step("Building Event", 0.84)
local EventTab = Window:CreateTab({ name = "Event" })

-- THE BOSS EVENT. Read out of the live game, not guessed.
--
-- ReplicatedStorage.Data.BossEvent:
--     window length measured at 330s
-- The reward currency is BossTokens (Data.Currency.Configs.BossTokens) and the
-- boss drops an Alien Skeleton Boss asset (Data.Assets.Configs).

X.boss = {}
BX.autoBoss = false

K.BOSS_SNAP_TTL = 1.0

function X.bossSnapshot(force)
    if not force and X.bossSnap and (os.clock() - (X.bossSnapAt or 0)) < K.BOSS_SNAP_TTL then
        return X.bossSnap
    end
    local net = RS.Packages:FindFirstChild("Networking")
    local rf = net and net:FindFirstChild("RF/BossEvent/AskSnapshot")
    if not rf then return nil end
    local ok, snap = pcall(function() return rf:InvokeServer() end)
    if not ok or type(snap) ~= "table" then return nil end
    X.bossSnap, X.bossSnapAt = snap, os.clock()
    return snap
end

local function fmtClock(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    if sec < 60 then return sec .. "s" end
    return ("%dm %02ds"):format(sec // 60, sec % 60)
end

EventTab:CreateSection({ name = "Boss" })

X.boss.line = EventTab:CreateText({ name = "Abyss Overlord", text = "Reading..." })

EventTab:CreateButton({
    name = "Enter the boss world",
    description = "Only works while it is open",
    callback = function()
        local net = RS.Packages:FindFirstChild("Networking")
        local rf = net and net:FindFirstChild("RF/BossEvent/AskEnter")
        if not rf then toast("Boss remote not found") return end
        local ok, accepted, msg = pcall(function() return rf:InvokeServer() end)
        trace(("boss: AskEnter -> ok=%s accepted=%s msg=%s")
            :format(tostring(ok), tostring(accepted), tostring(msg)))
        if accepted == true then
            toast("Entering the boss world")
        elseif msg and tostring(msg):find("defeated") then
            BX.bossDeadWindow = true
            toast("Boss already defeated - waiting for the next one")
        else
            toast(tostring(msg or "Refused"))
        end
    end,
})

EventTab:CreateToggle({
    name = "Auto enter",
    description = "Joins as soon as it opens",
    value = false,
    flag = "AutoBoss",
    callback = function(v)
        BX.autoBoss = v and true or false
        trace("boss: auto enter " .. tostring(BX.autoBoss))
        toast("Auto enter " .. (BX.autoBoss and "ON" or "OFF"))
    end,
})

EventTab:CreateToggle({
    name = "Auto fight",
    description = "Breaks the crystals, then the boss",
    value = false,
    flag = "AutoBossFight",
    callback = function(v)
        BX.autoBossFight = v and true or false
        if BX.autoBossFight then
            pcall(BX.startBossDodge)
            pcall(BX.startBossMover)
            -- The arena floor has a pit in it; this is what pulls us back out.
            pcall(BX.startVoidWatch)
        else
            pcall(BX.stopBossDodge)
            pcall(BX.stopBossMover)
        end
        toast("Auto fight " .. (BX.autoBossFight and "ON" or "OFF"))
    end,
})

EventTab:CreateButton({
    name = "Claim mastery rewards",
    description = "Collects everything you have earned",
    callback = function()
        local n = BX.claimBossMilestones()
        toast(n > 0 and ("Claimed " .. n) or "Nothing to claim yet")
    end,
})


-- THE FIGHT ITSELF, read out of PlayerScripts.Game.BossEventClient.
--
--     BLACK_HOLE_FOLLOW_SPEED_FRACTION = 0.4   -- it chases at 40% of WalkSpeed
-- The black hole follows at 40% of our WalkSpeed, so simply keeping the target
-- SWING GAP MUST CLEAR THE TOOL'S OWN COOLDOWN.
-- This was 0.35, and that is why the crystals never broke. Read out of
-- Every Activate inside 0.6s of the last one is swallowed by that debounce
-- before a single packet is sent, so swinging every 0.35s meant roughly every
K.BOSS_SWING_GAP = 0.65
K.BOSS_REACH = 9

-- ...AND THE SWING IS REFUSED OUTRIGHT IN THESE STATES. Same file, _onActivated
-- checks all of these BEFORE firing RE/BatSwing/Trigger:
--     _isEquipped                       -- the controller must have seen Equipped
--     _tryActivate (0.6s)               -- the debounce above
-- is why standing next to them is what counts - there is nothing for us to aim.
K.BOSS_EQUIP_SETTLE = 0.25
-- How far above us a hand may be and still be worth swinging at. Anything
-- higher is the boss holding its arms up and is not reachable on foot.
K.BOSS_HAND_REACH_Y = 30
-- How far above us a hand may be and still be worth WALKING TOWARDS. Swinging
-- needs BOSS_HAND_REACH_Y; this is the wider "it is on its way down, get into
-- position" band. Past it the arm is parked in the sky and we hold.
K.BOSS_HAND_CHASE_Y = 90
-- Studs of upward movement between ticks that counts as "this arm is
-- retracting". Small, because the tick is 0.12s and the arms move fast.
K.HAND_RISE_EPS = 2
-- How long we commit to a chosen hand before allowing a different one.
K.HAND_COMMIT = 1.5
-- STAND OUTSIDE THE THING, NOT INSIDE IT.
--
-- K.BOSS_REACH is measured to a target's CENTRE, and a crystal's Hitbox is
-- 55 x 55 x 55 - measured live. So "get within 9 studs" meant walking 27 studs
-- INSIDE the tower, which is why it ends up stuck in the crystal and the swing
-- never feels like it connects. The hitbox is CanCollide=false but the tower
K.BOSS_SURFACE_MARGIN = -20

function BX.targetReach(part)
    if typeof(part) == "Vector3" then return K.BOSS_REACH end
    if not (part and part:IsA("BasePart")) then return K.BOSS_REACH end
    local half = math.max(part.Size.X, part.Size.Z) * 0.5
    -- Clamped to a floor of 6 so a negative margin cannot ask for a reach of
    -- zero, which would leave the mover chasing a point it can never satisfy.
    -- MAX, NOT MIN. This clamped the reach DOWN to K.BOSS_REACH (9), so for a
    -- crystal whose Hitbox is 55 x 55 x 55 - half-extent 27.5 - it walked to
    -- 9 studs from the CENTRE, i.e. 18 studs inside the crystal. Standing
    -- inside the mesh is what throws the camera around while swinging.
    --     min(9, 27.5 + 7) =  9.0   <- wrong, inside
    --     max(9, 27.5 + 7) = 34.5   <- outside, just clear of the surface
    return math.max(K.BOSS_REACH, half + K.BOSS_SURFACE_MARGIN)
end
-- WHY THE MOVEMENT STUTTERED, AND WHY IT IS ITS OWN LOOP NOW.
--
-- The old shape was: one loop, waking every K.BOSS_SWING_GAP (0.65s), which
-- called a mover that ran for K.BOSS_STEP_SLICE (0.4s) and then returned. So
-- the character moved for 0.4s, stood completely still for 0.25s, moved for
-- 0.4s, stood still... That is the "tween stops, then steps, then stops" -
-- teleports the model, and it lifts the model up whenever the destination
-- 430 IS WHAT WAS GETTING US RELOCATED IN THE ARENA.
--
-- Straight off the live log, mid-fight:
--     SERVER RigSync -> Relocate {-14504, 96, -243}
--     relocate: #1 - backing off 3s      ... #2 ... #3 ... #4
-- with the heartbeat bouncing between the crystal at -14943,-601 and the
-- arena entrance at -14519,-252. The server was dragging us back to the door
-- every few seconds, and each Relocate triggers a 3s stall, so the fight tick
-- got one swing in ("boss: swinging at the crystal (1 swings)") and then
-- spent the rest of the phase being towed around.
--
-- The mover writes CFrame at this speed with no per-frame cap, which is the
-- same mistake the travel arc had. The game's budget is WalkSpeed * 1.7, and
-- the step cap is what actually keeps a frame hitch from spiking past it.
-- 200 was set when the mover still fought collision and the server was
-- sending Relocate. With noclip on there is nothing to grind against, and the
-- hands land 300-600 studs away - at 200 studs/s that is a three second walk
-- for an arm that is only down for a moment. Raised, but nowhere near the
-- 1200 used outside the arena, because Relocate is still the limit here.
K.BOSS_STEP_SPEED = 420
K.BOSS_MAX_STEP = 14       -- studs in one frame, whatever the frame rate
K.ARENA_SINK_MAX = 6       -- studs below the last real floor that means we fell through
K.BOSS_Y_TAU = 0.12        -- seconds to close ~63% of a height change
-- GO THROUGH THE SCENERY, DO NOT CLIMB IT.
--
-- Climbing was still the physics engine's problem to solve, and it showed:
-- every rock became a little ramp, the height ease chased the top of it, and
-- the walk turned into a series of hops. Measured, the arena carries 195
-- collidable parts and 42 of them stand under 15 studs - that is 42 chances
-- per crossing to snag on something.
--
-- With the character non-collidable none of them exist as far as we are
-- concerned. There is nothing to grind against, nothing to step onto and
-- nothing to route around, so the path is a straight line and the only height
-- change left is the floor itself. The mover already writes CFrame directly,
-- so collision was never doing anything for us except getting in the way.
K.BOSS_STUCK_TIME = 2.5    -- with noclip on, this should essentially never fire
-- How far off the direct line we will turn to get round the pit, in order.
-- It stops at 150: past that we would be walking away from the target, and
-- something else is wrong.
K.BOSS_RIM_SWEEP = { 25, 50, 75, 100, 125, 150 }
K.BOSS_RIM_LOOKAHEAD = 6   -- extra studs checked so we do not commit to a ledge
K.BOSS_MOVE_ARRIVE = 1.5   -- how close counts as "there", so we stop cleanly
K.BOSS_SWING_SLACK = 4     -- must exceed BOSS_MOVE_ARRIVE, or they deadlock
-- Facing tolerance while swinging. cos(25 degrees) - inside this we are aimed
-- well enough and must not touch the CFrame at all, or the camera snaps.
K.BOSS_AIM_COS = 0.906
K.BOSS_AIM_EASE = 0.35     -- share of the turn taken per tick, so it sweeps
-- Hand positions come off a moving bone and jitter frame to frame. Follow
-- them through a low-pass filter instead of raw, or the mover chases noise.
K.BOSS_TRACK_TAU = 0.18
-- A move bigger than this is the arm genuinely relocating, not jitter, so the
-- filter resets to it rather than crawling across the arena.
K.BOSS_TRACK_JUMP = 60

BX.bossGoal = nil          -- { pos = Vector3, reach = number } or nil

-- ANTI-FLING FOR THE ARENA.
--
-- The slam and the black hole both knock you with an impulse, and an impulse
-- is applied and integrated inside one physics step - by the time a Heartbeat
-- runs you have already been thrown. Over a floor with a hole in it that
-- launch is how you end up in the pit, so the launch is what has to be
-- cancelled, not recovered from.
--
-- Only the part we cannot explain is removed: horizontal motion is clamped to
-- what our own WalkSpeed could produce and upward motion is dropped, while
-- downward motion is left alone so gravity still works and the void watch can
-- still see a fall.
K.ARENA_FLING_UP = 60      -- upward studs/s no walk can produce
K.ARENA_FLING_MULT = 2.0   -- flat speed over WalkSpeed * this is not ours

function BX.arenaAntiFling()
    local h, hum = getHRP(), getHumanoid()
    if not h or not hum then return end
    local v = h.AssemblyLinearVelocity
    local flat = (v * Vector3.new(1, 0, 1)).Magnitude
    local cap = math.max((hum.WalkSpeed or 16) * K.ARENA_FLING_MULT, 120)
    if v.Y <= K.ARENA_FLING_UP and flat <= cap then return end
    local keep = Vector3.zero
    if flat > 0.001 then
        keep = (v * Vector3.new(1, 0, 1)).Unit * math.min(flat, hum.WalkSpeed or 16)
    end
    h.AssemblyLinearVelocity = Vector3.new(keep.X, math.min(v.Y, 0), keep.Z)
    h.AssemblyAngularVelocity = Vector3.zero
    BX.flingsCancelled = (BX.flingsCancelled or 0) + 1
    if os.clock() - (BX.flingAt or 0) > 2 then
        BX.flingAt = os.clock()
        trace(("boss: cancelled a launch (up %.0f, flat %.0f) - %d so far")
            :format(v.Y, flat, BX.flingsCancelled))
    end
end

function BX.startBossMover()
    if BX.bossMoveConn then return end
    -- Nothing in the arena should be able to block a step.
    pcall(enableNoclip)
    BX.bossMoveConn = RunService.Heartbeat:Connect(function(dt)
        if not BX.autoBossFight then return end
        if not BX.inBossArena() then return end

        -- Before anything else: do not let the boss throw us into the pit.
        pcall(BX.arenaAntiFling)

        -- ONE WRITER, TWO SOURCES OF DESTINATION. Getting out of a hazard
        -- outranks reaching a target, but both are driven by this loop and
        -- this loop only - see the note above BX.dodgeBossHazards for why the
        local dodging = BX.bossDodge ~= nil
        local goal = BX.bossDodge or BX.bossGoal
        if not goal then return end

        local h = getHRP()
        local hum = getHumanoid()
        if not h or not hum then return end

        -- 5. DEAD MAN'S GUARD. Whatever else is happening - a dodge, a knock,
        -- a hand that moved - if there is no longer ground under US, getting
        -- back onto some outranks every other goal.
        if BX.groundAt(h.Position) then
            BX.lastSolid = h.Position
        elseif BX.lastSolid then
            local back = Vector3.new(BX.lastSolid.X - h.Position.X, 0, BX.lastSolid.Z - h.Position.Z)
            if back.Magnitude > 1 then
                local st2 = math.min(back.Magnitude,
                                     math.min(dt, K.MODEL_MOVE_MAX_DT) * K.BOSS_STEP_SPEED,
                                     K.BOSS_MAX_STEP)
                local nb = h.Position + back.Unit * st2
                local gyb = BX.groundAt(nb) or BX.lastSolid.Y
                pcall(function()
                    hum.PlatformStand = false
                    h.CFrame = CFrame.lookAt(Vector3.new(nb.X, gyb, nb.Z),
                                             Vector3.new(nb.X, gyb, nb.Z) + back.Unit)
                    h.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                end)
                if os.clock() - (BX.rescueAt or 0) > 1 then
                    BX.rescueAt = os.clock()
                    trace("boss: no ground underneath - walking back to solid")
                end
            end
            return
        end

        local flat = Vector3.new(goal.pos.X - h.Position.X, 0, goal.pos.Z - h.Position.Z)
        local reach = dodging and 0 or (goal.reach or K.BOSS_REACH)
        local left = flat.Magnitude - reach
        if left <= K.BOSS_MOVE_ARRIVE then
            if dodging then BX.bossDodge = nil else BX.bossGoal = nil end
            return
        end

        -- STUCK ON SCENERY. The arena floor has rocks and props on it, and a
        -- CFrame step into one just gets refused by physics - we sit there
        -- grinding against it with a goal we can never reach. Watch actual
        -- progress rather than trusting the step: if the distance to the goal
        -- has not fallen in K.BOSS_STUCK_TIME, slide sideways for a moment and
        -- come at it from a different line.
        local now = os.clock()
        if not BX.stuckBest or left < BX.stuckBest - 2 then
            BX.stuckBest, BX.stuckSince = left, now
        end
        local dirUse = flat.Unit
        if BX.stuckSince and (now - BX.stuckSince) > K.BOSS_STUCK_TIME then
            -- Perpendicular, alternating side each time so we do not grind
            -- into the same corner twice.
            BX.stuckFlip = not BX.stuckFlip
            local sgn = BX.stuckFlip and 1 or -1
            dirUse = Vector3.new(-flat.Unit.Z * sgn, 0, flat.Unit.X * sgn)
            BX.stuckSince = now
            BX.stuckBest = nil
            if now - (BX.stuckLogAt or 0) > 2 then
                BX.stuckLogAt = now
                trace("boss: not making progress - sidestepping around whatever is in the way")
            end
        end

        local step = math.min(left,
                              math.min(dt, K.MODEL_MOVE_MAX_DT) * K.BOSS_STEP_SPEED,
                              K.BOSS_MAX_STEP)
        local nxt = h.Position + dirUse * step

        if not dodging and BX.inAnyHazard and BX.inAnyHazard(nxt, 0) then return end

        -- NO GROUND THERE = DO NOT GO THERE, BUT DO NOT GIVE UP EITHER.
        --
        -- A missing probe is never a reason to guess a height - falling back
        -- to our current Y is what used to walk us out over the void at
        -- altitude and drop us when the leg ended. That part was right.
        --
        -- Abandoning the goal was not. The arena has a hole through the middle,
        -- so when a hand comes down on the far side the straight line crosses
        -- it: we reached the rim, the probe came back empty, the goal was
        -- cleared - and the fight tick immediately re-issued the same goal,
        -- which failed at the same rim. That is the "I am on the other side of
        -- the map and can never reach the hand": not stuck on scenery, stuck in
        -- a one-frame loop against the edge of the pit.
        --
        -- Noclip cannot help here. A hole is an absence of floor, not an
        -- obstacle to pass through. What works is what a person does - follow
        -- the rim round until the way ahead is solid again.
        local function groundFor(dir, dist)
            local probe = h.Position + dir * dist
            return BX.groundAt(Vector3.new(probe.X, h.Position.Y, probe.Z))
        end

        local gy = groundFor(dirUse, step)

        -- NOCLIP MEANS THE FLOOR CANNOT CATCH US EITHER.
        --
        -- Collision is off for the whole fight, so nothing stops a bad Y from
        -- putting us under the map - and the ground probe returns nil often
        -- enough (over the pit, inside a prop) that "no answer" must never be
        -- allowed to mean "keep the current height". Remember the last real
        -- floor and refuse to write below it.
        if gy then
            BX.arenaFloorY = gy
        elseif BX.arenaFloorY and h.Position.Y < BX.arenaFloorY - K.ARENA_SINK_MAX then
            pcall(function()
                h.CFrame = CFrame.new(h.Position.X, BX.arenaFloorY, h.Position.Z)
                h.AssemblyLinearVelocity = Vector3.zero
            end)
            if os.clock() - (BX.sinkAt or 0) > 2 then
                BX.sinkAt = os.clock()
                trace("boss: dropped below the floor - lifted back onto it")
            end
            return
        end

        if not gy then
            -- Sweep outward from the direction we wanted, alternating sides,
            -- and take the first heading that has floor under it. Sticking to
            -- the side we used last frame stops us oscillating on the spot at
            -- the point where both sides look equally good.
            local found = nil
            for _, deg in ipairs(K.BOSS_RIM_SWEEP) do
                for _, sgn in ipairs(BX.rimSide == -1 and { -1, 1 } or { 1, -1 }) do
                    local a = math.rad(deg * sgn)
                    local d = Vector3.new(
                        dirUse.X * math.cos(a) - dirUse.Z * math.sin(a), 0,
                        dirUse.X * math.sin(a) + dirUse.Z * math.cos(a))
                    local g = groundFor(d, step)
                    -- Look a little further along that heading too, so we do
                    -- not commit to a ledge that ends immediately.
                    if g and groundFor(d, step + K.BOSS_RIM_LOOKAHEAD) then
                        found, gy = d, g
                        BX.rimSide = sgn
                        break
                    end
                end
                if found then break end
            end

            if not found then
                -- Genuinely nowhere to step: we are on an island. Now it is
                -- fair to drop the goal.
                if dodging then BX.bossDodge = nil else BX.bossGoal = nil end
                return
            end

            dirUse = found
            nxt = h.Position + dirUse * step
            -- Following the rim is progress even though the straight-line
            -- distance may not fall, so the stuck timer must not fire.
            BX.stuckSince = now
            if now - (BX.rimLogAt or 0) > 2 then
                BX.rimLogAt = now
                trace("boss: hole in the way - following the rim round to the target")
            end
        end
        -- EASE THE HEIGHT, FRAME-RATE INDEPENDENTLY.
        --
        -- The probe returns a new ground Y every frame and snapping straight
        -- onto it is what made the crystal approach judder: the floor is not
        -- perfectly flat, so each sample steps us up or down by a few studs.
        --
        -- A fixed per-frame share also moves at whatever rate the client
        -- happens to render, so the same walk looked different at 30fps and
        -- 144fps and juddered whenever the frame time wobbled. As a time
        -- constant instead, the approach is identical on any machine.
        local curY = h.Position.Y
        local k = 1 - math.exp(-dt / K.BOSS_Y_TAU)
        local easedY = curY + (gy - curY) * k
        local dest = Vector3.new(nxt.X, easedY, nxt.Z)
        pcall(function()
            hum.PlatformStand = false
            hum:Move(Vector3.zero, false)
            h.CFrame = CFrame.lookAt(dest, dest + flat.Unit)
            -- Y is left alone: zeroing it here is what would fight gravity and
            -- the jump window. Only the horizontal carry is ours.
            h.AssemblyLinearVelocity = Vector3.new(0, h.AssemblyLinearVelocity.Y, 0)
            h.AssemblyAngularVelocity = Vector3.zero
        end)
    end)
end

function BX.stopBossMover()
    BX.bossGoal, BX.bossDodge, BX.bossAim = nil, nil, nil
    -- Put collision back. disableNoclip restores each part's original value
    -- rather than just dropping the connection, which would leave the
    -- character permanently non-collidable.
    if not stealing then pcall(disableNoclip) end
    if BX.bossMoveConn then
        pcall(function() BX.bossMoveConn:Disconnect() end)
        BX.bossMoveConn = nil
    end
end

-- ORBIT, DO NOT RETREAT.
--
-- BLACK_HOLE_FOLLOW_SPEED_FRACTION = 0.4: it moves at 40% of our speed and
-- can never catch anything that keeps moving. Backing away from it is what
-- dragged us off the crystal; standing still is what lets it sit on us and
-- hit once a second (BLACK_HOLE_HIT_INTERVAL = 1). Neither is necessary.
--
-- Instead we slide TANGENTIALLY - around the target, at the same radius, so
-- we stay in bat range the whole time and the hole trails permanently behind.
-- A crystal Hitbox is 55 wide and reach is 7.5 studs from its centre, so
-- there is a full circumference of room to keep moving in.
K.ORBIT_TRIGGER = 34       -- start circling when the hole is this close
K.ORBIT_STEP = 0.55        -- radians of arc to aim ahead each tick

function BX.orbitPoint(tpos, reach)
    local h = getHRP()
    local bh = workspace:FindFirstChild("BossBlackHole")
    if not h or not bh or not bh:IsA("BasePart") then return nil end
    local toHole = Vector3.new(bh.Position.X - h.Position.X, 0, bh.Position.Z - h.Position.Z)
    if toHole.Magnitude > K.ORBIT_TRIGGER then return nil end

    local rel = Vector3.new(h.Position.X - tpos.X, 0, h.Position.Z - tpos.Z)
    if rel.Magnitude < 1 then rel = Vector3.new(1, 0, 0) end
    local ang = math.atan2(rel.Z, rel.X)
    local r = math.max(reach, 6)
    local function at(a)
        return Vector3.new(tpos.X + math.cos(a) * r, h.Position.Y, tpos.Z + math.sin(a) * r)
    end
    -- Go whichever way around opens more distance on the hole.
    local p1, p2 = at(ang + K.ORBIT_STEP), at(ang - K.ORBIT_STEP)
    local function fromHole(p)
        return Vector3.new(p.X - bh.Position.X, 0, p.Z - bh.Position.Z).Magnitude
    end
    local first, second = p1, p2
    if fromHole(p2) > fromHole(p1) then first, second = p2, p1 end
    if BX.onArenaFloor(first) then return first end
    if BX.onArenaFloor(second) then return second end
    return nil
end

-- Cached for the same reason: a RECURSIVE FindFirstChild walks the same 38k
-- instances, and the fight tick asks for the arena eight times a second, with
-- the mover and the hazard scan asking again on top of that.
function BX.bossArena()
    local a = BX.arenaCache
    if a and a.Parent then return a end
    a = workspace:FindFirstChild("BossArena") or workspace:FindFirstChild("BossArena", true)
    BX.arenaCache = a
    return a
end

function BX.inBossArena()
    return LocalPlayer:GetAttribute("InBossArena") == true
end

-- A bat is a Tool the game marks IsBat (the gear item is "Bat [X1]" now);
-- the name test stays as a fallback for older builds. (On BX, not a local:
-- the main chunk is at the register ceiling.)
function BX.isBatTool(t)
    return t:IsA("Tool") and (t:GetAttribute("IsBat") == true or t.Name:find("Bat") ~= nil)
end

function BX.equipBat()
    local char = getChar()
    if not char then return nil end
    for _, t in ipairs(char:GetChildren()) do
        if BX.isBatTool(t) then return t end
    end
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        for _, t in ipairs(bp:GetChildren()) do
            if BX.isBatTool(t) then
                -- EQUIP IT THE WAY THE GAME DOES. Reparenting the tool from an
                -- executor does not reliably fire Tool.Equipped for the bat's
                -- own controller, and that controller refuses every swing it
                -- did not see equipped (CLIENT_TOOL_NOT_EQUIPPED) - the "auto
                -- equip does nothing". Humanoid:EquipTool is the real path;
                -- reparenting stays only as the fallback.
                local hum = getHumanoid()
                local ok = hum and pcall(function() hum:EquipTool(t) end)
                if not ok or t.Parent ~= char then t.Parent = char end
                trace("boss: equipped " .. t.Name)
                return t
            end
        end
    end
    return nil
end

-- ONE SWING, STRAIGHT TO THE SERVER.
--
-- Read out of Shared.Modules.BatController.Client: a click runs
--     Tool.Activated -> _onActivated -> (equipped? gameplay area? 0.6s
--     debounce? not ragdolled?) -> Remotes.BatSwing.Trigger:FireServer(
--         target, "<UserId>:<seq>:<serverTimeMs>")
-- where `target` is the nearest PLAYER in range (the bat is a PvP weapon too)
-- and nil otherwise - the boss and crystals are resolved by the server from
-- where we stand. bat:Activate() only works if the controller saw the tool
-- equipped, which on some executors it never does: "I have to click to attack".
-- So the swing is fired exactly as the controller fires it, and the bat's own
-- hit animation is played so it still looks like a swing.
function BX.batSwing(bat)
    local ok = pcall(function()
        local net = RS.Packages:FindFirstChild("Networking")
        local rem = net and net:FindFirstChild("RE/BatSwing/Trigger")
        assert(rem, "no BatSwing remote")
        BX.batSeq = (BX.batSeq or 0) + 1
        rem:FireServer(nil, ("%d:%d:%d"):format(LocalPlayer.UserId, BX.batSeq,
            math.floor(workspace:GetServerTimeNow() * 1000)))
    end)
    if not ok then
        -- Remote not where it should be: fall back to the tool itself.
        pcall(function() bat:Activate() end)
        return
    end
    pcall(function()
        local anim = bat:FindFirstChild("HitAnim")
        local hum = getHumanoid()
        local animator = hum and hum:FindFirstChildOfClass("Animator")
        if anim and animator then
            if BX.batAnimFor ~= animator then
                BX.batAnimTrack = animator:LoadAnimation(anim)
                BX.batAnimFor = animator
            end
            BX.batAnimTrack:Play()
        end
        local snd = bat:FindFirstChild("Slash", true)
        if snd and snd:IsA("Sound") then snd:Play() end
    end)
end

-- WHAT IS ACTUALLY HITTABLE, READ OUT OF THE GAME'S OWN CLIENT.
--
-- THE HEALTH MUST BE A NUMBER. Ours accepted `hp == nil` as "probably fine",
K.BOSS_HAND_BONES = { "UpperHand1.R", "UpperHand1.L", "LowerHand1.R", "LowerHand1.L" }

function BX.bossModel()
    local arena = BX.bossArena()
    if not arena then return nil end
    local boss = arena:FindFirstChild("Boss", true)
    if boss and boss:IsA("Model") then return boss end
    return nil
end

-- nil while the boss is still arriving, "crystals" or "hands" otherwise.
function BX.bossPhase()
    local boss = BX.bossModel()
    if not boss then return nil end
    if boss:GetAttribute("Spawning") then return nil end
    if boss:GetAttribute("PhaseTwoAt") ~= nil then return "hands" end
    return "crystals"
end

-- Returns target, kind. Target is a BasePart for a crystal and a Vector3 for
-- a hand. Returns nil when there is genuinely nothing to hit, and the caller
-- must then HOLD POSITION - see the note in the fight loop about why walking
-- to the boss body is never right.
function BX.bossTarget()
    local h = getHRP()
    if not h then return nil end
    local phase = BX.bossPhase()
    if not phase then return nil end

    if phase == "crystals" then
        local arena = BX.bossArena()
        local towers = arena and arena:FindFirstChild("CrystalTowers", true)
        if not towers then return nil end
        local best, bestD
        for _, d in ipairs(towers:GetDescendants()) do
            if d:IsA("BasePart") and d.Name == "Hitbox" then
                -- The game's own test, verbatim. A missing attribute means
                -- the tower is not live yet, NOT that it is full health.
                local hp = d:GetAttribute("Health")
                if type(hp) == "number" and hp > 0 then
                    local dist = (d.Position - h.Position).Magnitude
                    if not bestD or dist < bestD then best, bestD = d, dist end
                end
            end
        end
        if best then return best, "crystal" end
        -- Crystal phase with no live crystal = they are between spawns. Wait.
        return nil
    end

    -- PHASE TWO: THE HANDS, AND ONLY THE HANDS.
    --
    -- Measured in a live fight from the arena floor:
    -- CENTRE. That is why this walked to the middle the moment phase two
    -- started: the hands were all 170-310 studs up, the body fallback was the
    -- never a target - the arm hits are what damage the boss - so the
    local boss = BX.bossModel()
    if not boss then return nil end

    local myY = h.Position.Y
    local low, lowD          -- has a health bar AND is low enough to swing at
    local any, anyD, anyUp   -- has a health bar, whatever height
    local seen = 0
    for _, bn in ipairs(K.BOSS_HAND_BONES) do
        local bone = boss:FindFirstChild(bn, true)
        -- The Health GUI is the game's own "this arm is down and damageable"
        -- flag - BossEventClient's stepArmBeam gives up without it - so a hand
        -- that has one is a hand worth walking to.
        -- NO HEALTH-BAR GATE. Measured live in a real phase two: not one bone
        -- in the boss ever carries a "Health" child - "Health objects anywhere
        -- in the boss: NONE" - so this condition was false every frame and we
        -- never targeted a hand at all. Meanwhile BossArmHits read 10, so the
        -- swings DO register. The bar is not the signal; proximity is.
        if bone and bone:IsA("Bone") then
            local pos
            pcall(function() pos = bone.TransformedWorldCFrame.Position end)
            pos = pos or bone.WorldPosition
            if pos then
                seen = seen + 1

                -- 4. DO NOT CHASE AN ARM THAT IS LEAVING.
                --
                -- When the boss pulls a hand back into its body the target
                -- walks to the body, and the body sits over the pit in the
                -- middle of the arena. Comparing this frame's height with the
                -- last one tells us which way it is going, so a retracting arm
                -- is simply not a target: the next slam brings it back down
                -- and that is the one worth walking to.
                BX.handY = BX.handY or {}
                local prev = BX.handY[bn]
                BX.handY[bn] = pos.Y
                local rising = prev ~= nil and (pos.Y - prev) > K.HAND_RISE_EPS

                if not rising then
                    local flat = Vector3.new(pos.X - h.Position.X, 0, pos.Z - h.Position.Z).Magnitude
                    if not anyD or flat < anyD then
                        any, anyD, anyUp = pos, flat, pos.Y - myY
                    end
                    if (pos.Y - myY) <= K.BOSS_HAND_REACH_Y then
                        if not lowD or flat < lowD then low, lowD = pos, flat end
                    end
                end
            end
        end
    end

    -- 3. STAND WHERE THERE IS FLOOR, EVEN IF THE HAND IS NOT OVER ANY.
    --
    -- A hand directly above the central pit is still worth swinging at, but
    -- the spot underneath it will kill us. Walk as far along the line as the
    -- ground lasts and swing from there instead.
    local function landable(p)
        if not p then return nil end
        -- The spot under the hand is fine AND we can get there: go straight.
        if BX.onArenaFloor(p) and BX.clearLine(h.Position, p) then return p end

        -- Otherwise the straight line crosses the hole. Walk the ring round
        -- to it; the angle sweep is the fallback for small obstacles.
        local wp, ang = BX.ringWaypoint(h.Position, p)
        if not wp then wp, ang = BX.detourAround(h.Position, p) end
        if wp then
            if os.clock() - (BX.handPitAt or 0) > 2 then
                BX.handPitAt = os.clock()
                trace(("boss: pit in the way - walking round the ring (%+.0f deg)"):format(ang or 0))
            end
            return wp
        end

        -- No way round found this tick; get as close as the floor allows and
        -- re-plan from there next tick.
        return BX.lastSolidToward(h.Position, p)
    end

    -- ONLY PATHFIND FOR A HAND WE WOULD ACTUALLY WALK TO.
    --
    -- landable() runs the pit avoidance - ring waypoints, detours, ground
    -- probes - and it was being run on `any` before the height gate below had
    -- decided whether `any` was worth chasing at all. Straight from a live
    -- phase two:
    --     boss: pit in the way - walking round the ring (+22 deg)
    --     boss: 4 hand(s) damageable but the nearest is 657 studs up - holding
    -- a route computed round the pit, for a hand 657 studs in the air, which
    -- was then correctly ignored. Pure waste, and the trace reads as though
    -- the script is walking somewhere when it is standing still.
    low = landable(low)
    if any and (anyUp or 0) <= K.BOSS_HAND_CHASE_Y then
        any = landable(any)
    else
        any = nil
    end

    -- HOLD THE HAND WE PICKED.
    --
    -- The arms move constantly, so re-running "nearest" eight times a second
    -- swapped target mid-approach and the character wandered between them -
    -- that is the goofy movement once the hands are out. Once a hand is
    -- chosen we stay on it for K.HAND_COMMIT seconds unless it stops being a
    -- candidate at all.
    local now = os.clock()
    if BX.handPick and (now - (BX.handPickAt or 0)) < K.HAND_COMMIT then
        local keep = BX.handPick
        local stillGood = (low and (low - keep).Magnitude < 220)
            or (any and (any - keep).Magnitude < 220)
        if stillGood then return keep, "hand" end
    end
    if low then
        BX.handPick, BX.handPickAt = low, now
        return low, "hand"
    end

    -- WHY WE WERE WALKING WITH NOTHING TO HIT.
    --
    -- This used to be an unconditional `if any then return any end`, and
    -- `any` is the nearest hand AT ANY HEIGHT. Between slams the arms sit
    -- 170-310 studs up, so the moment phase two began this returned one of
    -- them and the mover set off across the arena to stand underneath a hand
    -- that could never be swung at - which is the "why am I moving when
    -- there is nothing to hit" - and the hold-for-the-slam branch below it
    -- was unreachable code that never ran once.
    --
    -- A hand still coming down IS worth repositioning for, so the gate is a
    -- generous multiple of swing height rather than swing height itself. Any
    -- higher than that and it is not descending yet: stand still and wait.
    if any and (anyUp or 0) <= K.BOSS_HAND_CHASE_Y then
        BX.handPick, BX.handPickAt = any, os.clock()
        return any, "hand"
    end

    -- A HAND WE CANNOT REACH IS NOT A TARGET.
    --
    -- The hands sit 170-650 studs up between slams, measured live, so we hold
    -- rather than walk under one. Tested on `anyUp` rather than `any`: the
    -- gate above nils `any` once it is out of chase range, and testing that
    -- would silence this message in exactly the case it exists to explain.
    if anyUp then
        if os.clock() - (BX.handHighAt or 0) > 2 then
            BX.handHighAt = os.clock()
            trace(("boss: %d hand(s) damageable but the nearest is %.0f studs up"
                .. " (need <= %d) - holding for the slam")
                :format(seen, anyUp or -1, K.BOSS_HAND_REACH_Y))
        end
    end
    return nil
end

-- WHAT PHASE TWO ACTUALLY LOOKS LIKE, LOGGED ONCE A SECOND.
--
-- from the decompiled client rather than observed. If it does nothing, this
-- says why in one line instead of needing another 30-minute wait to guess
function BX.traceHands()
    if os.clock() - (BX.handTraceAt or 0) < 1 then return end
    BX.handTraceAt = os.clock()
    local boss = BX.bossModel()
    local h = getHRP()
    if not boss or not h then return end
    local rows = {}
    for _, bn in ipairs(K.BOSS_HAND_BONES) do
        local bone = boss:FindFirstChild(bn, true)
        if not bone then
            rows[#rows + 1] = bn .. "=missing"
        else
            local pos
            pcall(function() pos = bone.TransformedWorldCFrame.Position end)
            pos = pos or bone.WorldPosition
            rows[#rows + 1] = ("%s health=%s up=%.0f flat=%.0f"):format(
                bn, tostring(bone:FindFirstChild("Health") ~= nil),
                pos and (pos.Y - h.Position.Y) or -1,
                pos and Vector3.new(pos.X - h.Position.X, 0, pos.Z - h.Position.Z).Magnitude or -1)
        end
    end
    trace("boss hands: " .. table.concat(rows, " | "))
end

-- WHAT ACTUALLY KILLS YOU IN THERE, MEASURED DURING A LIVE FIGHT.
--
-- ground hazards can be cleared vertically, but the slam boxes are 75 studs
K.HAZARD_CLEAR = 6
K.HAZARD_CACHE = 0.1       -- seconds a hazard list stays good for
K.HAZARD_SLAM_CLEAR = 12    -- the slam is huge; leave it more room
K.BLACK_HOLE_CLEAR = 6

-- Every part in the arena that can hurt us, wherever it lives.
-- THE ARENA FLOOR IS FINITE AND THE HAZARDS ARE NOT. THIS IS THE FALL.
-- Measured in a live fight, mid-event:
-- The outer rings reach roughly 250 studs BEYOND the floor edge on every
function BX.arenaFloor()
    local arena = BX.bossArena()
    local f = arena and arena:FindFirstChild("Floor", true)
    if f and f:IsA("BasePart") then return f end
    return nil
end

-- True when pos is over the floor with `margin` studs to spare. No floor
-- found means we cannot judge, and refusing every move would be worse than
-- allowing them, so it answers true.
-- IS THERE ACTUALLY GROUND THERE. Not "is it inside the Floor part's box".
--
-- The old test used the Floor MeshPart's bounding box, and the box is a full
-- 1408 x 1426 rectangle. The floor is not. Probed on a 13x13 grid during a
-- live fight, # = ground, . = nothing:
--
--     ....#####....
--     ...#######...
--     ...########..
--     #############
--     #############
--     ####.....####     <- the middle is a PIT
--     #####....####
--     #####.....###
--     ######...####
--     #######..###.
--     .###########.
--     .#.########..
--     ...#######...
--
-- 51 of 169 cells had nothing under them, the centre included. The box said
-- "floor" for every one of them, which is how the mover walked into the pit
-- and how the arm chase ended in a fall - the boss retracts its hand to its
-- body, the body is the middle, and the middle is a hole.
--
-- A downward ray is the only thing that knows the difference.
-- Probes are raycasts and they add up. lastSolidToward walked its line in 24
-- steps, on the 0.12s fight tick, on top of one per mover frame and one per
-- void-watch tick - that is where the lag came from.
-- ARM THE ANTICHEAT SPOOF AROUND THE ARC.
--
-- The arc wrote CFrame and hoped. Every other fast mover this file has had
-- rewrote the anticheat's own state table while it moved - that is what
-- BX.acArm / acPush / spoofAc exist for, and the deleted spoofMoveTo was the
-- only thing still using them, so the cleanup quietly took the protection
-- away along with the mover.
--
-- Two halves, and BOTH are needed:
--   1. claim a WalkSpeed that can explain the speed we are travelling at
--   2. push a velocity consistent with that WalkSpeed into the state table
-- The validator compares reported velocity against WalkSpeed, so a high
-- velocity with a legal WalkSpeed is exactly the contradiction that gets you
-- Relocated.
--
-- EMPTY-HANDED ONLY. An over-cap WalkSpeed is the one thing the egg-redeem
-- check rejects, so the carry leg never touches any of this.
BX.arcSpoof = true
K.ARC_SPOOF_HEADROOM = 1.35   -- claimed WalkSpeed = speed * this
-- NOT a game clamp. Tested live: asked for 1300/1600/2000/3000/5000 and the
-- humanoid accepted every one of them. 1300 was a number inherited from the
-- old mover, and it was pinning the claimed WalkSpeed while the real speed
-- climbed - the exact gap the validator looks for.
K.ARC_WS_MAX = 4000
-- Speed used when there is no anticheat state to spoof. 430 is what the carry
-- leg steps at with the humanoid untouched, and that has been delivering all
-- along, so it is the one number here with evidence behind it.
-- THE UNSPOOFED TRAVEL SPEED, AND WHY IT CLIMBS.
--
-- Clients that cannot arm the anticheat spoof - no getgc, or a getgc that
-- yields no tables, which is the common case on mobile executors - were pinned
-- at this number forever. There was a downward backoff on Relocate bursts and
-- nothing that ever went back up, so a phone travelled at 500 while a desktop
-- did 1200, took twice as long to reach the egg, and gave the guard twice as
-- long to be in the way.
--
-- 500 was my conservative pick after the game update, not a measured ceiling.
-- The honest way to find the real one is to probe - and the OUTBOUND leg is
-- the safe place to do it, because we are empty-handed. A refusal there costs
-- a Relocate and a few seconds; it cannot cost an egg. That is the opposite of
-- the carry tuner, which paid for every probe with a lost egg and is why that
-- one stays off.
--
-- So: start here, step up after each clean leg, and drop back the moment the
-- server starts relocating us. Ceiling is the spoofed speed, since there is no
-- point going faster than the fast path.
-- ...ALL OF WHICH WAS GUESSWORK, AND THE ANTICHEAT WILL JUST TELL YOU.
--
-- The new AC keeps a state table on the heap - findable by LastGoodSample and
-- SafeGroundCheckpoints, same as the old one - and inside it is HorizontalDebug,
-- which is the check itself, already computed, live. Read off this account:
--
--     Short  0.12s allows  26.55 studs ->  221 studs/s   (WalkSpeed x 1.064)
--     Main   0.45s allows 109.11 studs ->  242 studs/s   (WalkSpeed x 1.166)
--     Long   0.90s allows 217.62 studs ->  242 studs/s   (WalkSpeed x 1.163)
--
-- with WalkSpeed 207.87. Three sliding windows; you must satisfy all three, so
-- the real ceiling is the tightest of them: 221 studs/s.
--
-- K.ARC_SPEED_NOSPOOF was 500. That is 2.3x the limit. Every client that
-- cannot arm the spoof has been travelling at more than double what the
-- anticheat permits, collecting Relocates, and losing eggs to snap-backs -
-- and the bisect above was searching for a number the game was prepared to
-- state outright.
--
-- So ask instead of guessing. The windows can be READ without spoofing
-- anything - reading is passive, and nothing is written - and when the table
-- is out of reach the ratio still holds: the binding Short window is
-- WalkSpeed x 1.064, which needs only the Humanoid and therefore works on
-- every executor alive.
K.AC_SHORT_RATIO = 1.064     -- measured, Short window / (WalkSpeed * Duration)
K.AC_SAFETY = 0.94           -- sit under the line, not on it
K.ARC_SPEED_NOSPOOF = 500    -- last-resort fallback only
K.NOSPOOF_CONVERGE = 80      -- bracket width we stop narrowing at
K.NOSPOOF_FLOOR = 120        -- a slow account's honest speed is still low
BX.noSpoofSpeed = nil        -- resolved on first use

-- The fastest we may move without the anticheat objecting. Live if we can see
-- the table, derived from WalkSpeed if we cannot.
function BX.acLegalSpeed()
    local best
    pcall(function()
        for _, st in ipairs(BX.acStates or {}) do
            local hd = rawget(st, "HorizontalDebug")
            if type(hd) == "table" then
                for _, name in ipairs({ "Short", "Main", "Long" }) do
                    local w = hd[name]
                    if type(w) == "table"
                       and type(w.AllowedHorizontalDistance) == "number"
                       and type(w.Duration) == "number" and w.Duration > 0 then
                        local v = w.AllowedHorizontalDistance / w.Duration
                        if v > 0 and (not best or v < best) then best = v end
                    end
                end
            end
        end
    end)

    if not best then
        local ws
        pcall(function()
            local hum = getHumanoid()
            ws = hum and hum.WalkSpeed
            if not ws or ws <= K.WALKSPEED_SANE_MIN then
                ws = BX.legalWalkSpeed and BX.legalWalkSpeed() or nil
            end
        end)
        if type(ws) == "number" and ws > 0 then best = ws * K.AC_SHORT_RATIO end
    end

    if not best then return K.ARC_SPEED_NOSPOOF end
    return math.max(best * K.AC_SAFETY, K.NOSPOOF_FLOOR)
end

K.SOLID_PROBE_STEPS = 8
K.ARENA_GROUND_BAND = 25   -- ground more than this above the floor is not ground
K.FLOOR_PROBE_UP = 40      -- start the ray this far above the point
K.FLOOR_PROBE_DOWN = 220   -- and accept ground within this far below it

function BX.groundAt(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    local ch = getChar()
    if ch then ignore[#ignore + 1] = ch end
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character then ignore[#ignore + 1] = pl.Character end
    end

    -- DO NOT TREAT A CRYSTAL TOWER AS GROUND. The towers are tall meshes on
    -- the floor, so a ray fired beside one hits its TOP and reports ground at
    -- y=148 against a floor at 92.5. The mover then climbed us up the tower,
    -- the server saw a player 55 studs in the air, and Relocated us to the
    -- door - the "relocate: #1 #2 #3" bouncing in the live log.
    local arena = BX.bossArena and BX.bossArena()
    if arena then
        for _, nm in ipairs({ "CrystalTowers", "Boss", "SlamIndicator",
                              "SlamArmHitbox", "SlamRestHitbox" }) do
            local d = arena:FindFirstChild(nm, true)
            if d then ignore[#ignore + 1] = d end
        end
    end
    for _, nm in ipairs({ "BossHazards", "BossBlackHole" }) do
        local d = workspace:FindFirstChild(nm)
        if d then ignore[#ignore + 1] = d end
    end

    params.FilterDescendantsInstances = ignore
    params.IgnoreWater = true
    -- START THE RAY FROM ABOVE THE FLOOR, NOT FROM ABOVE US.
    --
    -- Casting from pos.Y + 40 works while you are standing on something. It
    -- stops working the moment you are falling: once you are more than
    -- FLOOR_PROBE_DOWN below the floor the ray begins under it, finds nothing,
    -- and the rescue cannot even tell where solid ground was. Anchoring the
    -- origin to the arena floor means the probe keeps answering all the way
    -- down.
    local top = pos.Y + K.FLOOR_PROBE_UP
    local f = BX.arenaFloor and BX.arenaFloor()
    if f then top = math.max(top, f.Position.Y + K.FLOOR_PROBE_UP) end
    local reach = math.max(K.FLOOR_PROBE_DOWN, (top - pos.Y) + K.FLOOR_PROBE_DOWN)
    local r = workspace:Raycast(Vector3.new(pos.X, top, pos.Z),
                                Vector3.new(0, -reach, 0), params)
    if not r then return nil end
    if f and (r.Position.Y - f.Position.Y) > K.ARENA_GROUND_BAND then return nil end
    return r.Position.Y
end

function BX.onArenaFloor(pos)
    return BX.groundAt(pos) ~= nil
end

-- The nearest point on the line from `from` to `to` that still has ground, so
-- a target standing over the pit can still be approached as far as is safe.
function BX.lastSolidToward(from, to)
    local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
    local dist = flat.Magnitude
    if dist < 1 then return nil end
    local dir = flat.Unit
    local best
    local step = math.max(dist / K.SOLID_PROBE_STEPS, 20)
    local d = step
    while d <= dist do
        local p = from + dir * d
        local gy = BX.groundAt(Vector3.new(p.X, from.Y, p.Z))
        if not gy then break end
        best = Vector3.new(p.X, gy, p.Z)
        d = d + step
    end
    return best
end

-- WALK AROUND THE PIT, DO NOT STOP AT ITS EDGE.
--
-- The arena floor is a ring with a hole in the middle. When the boss puts a
-- hand down on the far side, the straight line to it crosses the hole, so
-- lastSolidToward stopped us at the near lip and we just stood there - "it
-- can't tween there because there's a hole in the middle and it doesn't want
-- to go".
--
-- The floor is a RING, so there is always a way round: give up on the
-- straight line and aim at a point off to one side that has ground both under
-- it and onward from it. Sweep outward in angle - small detours first, so we
-- take the shortest way round rather than the first one that happens to work,
-- and try both directions at each angle so we go round whichever side is
-- shorter.
K.AROUND_ANGLES = { 25, 45, 70, 95, 120, 145 }
K.AROUND_RADIUS_FRAC = 0.55   -- how far along the detour leg to place the waypoint
K.AROUND_MIN_RADIUS = 90

-- True if every sample between a and b has ground under it.
function BX.clearLine(a, b)
    local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
    local dist = flat.Magnitude
    if dist < 1 then return true end
    local dir = flat.Unit
    local step = math.max(dist / K.SOLID_PROBE_STEPS, 20)
    local d = step
    while d < dist do
        local p = a + dir * d
        if not BX.groundAt(Vector3.new(p.X, a.Y, p.Z)) then return false end
        d = d + step
    end
    return true
end

-- WALK THE RING.
--
-- The angle sweep below could not solve a hand on the FAR side: it looks for
-- one waypoint with a clear line to the target, and when the pit sits between
-- you and the far rim there is no such point - every straight line from a
-- detour spot still crosses the hole. A single hop cannot round a ring.
--
-- The floor IS a ring, so navigate it as one: take the arena centre, our
-- bearing around it and the target's bearing, and step our bearing toward
-- theirs while holding our current radius. Repeat each tick and we walk the
-- annulus round to the far side. Short way round is whichever direction the
-- angle difference is smaller.
K.RING_STEP_DEG = 22       -- how far around to aim each tick
K.RING_RADIUS_TRIES = { 1.0, 0.85, 1.15, 0.7, 1.3 }

function BX.ringWaypoint(from, to)
    local mid = BX.arenaCentre and BX.arenaCentre()
    if not mid then return nil end
    local a = Vector3.new(from.X - mid.X, 0, from.Z - mid.Z)
    local b = Vector3.new(to.X - mid.X, 0, to.Z - mid.Z)
    if a.Magnitude < 20 or b.Magnitude < 20 then return nil end

    local ang1 = math.atan2(a.Z, a.X)
    local ang2 = math.atan2(b.Z, b.X)
    local diff = ang2 - ang1
    while diff > math.pi do diff = diff - 2 * math.pi end
    while diff < -math.pi do diff = diff + 2 * math.pi end
    local step = math.min(math.abs(diff), math.rad(K.RING_STEP_DEG))
    if diff < 0 then step = -step end
    local want = ang1 + step

    -- Hold our radius, but try a few nearby ones: the ring has a width and the
    -- exact radius we are on may clip a prop or a thin spot.
    for _, mul in ipairs(K.RING_RADIUS_TRIES) do
        local r = a.Magnitude * mul
        local p = Vector3.new(mid.X + math.cos(want) * r, from.Y, mid.Z + math.sin(want) * r)
        local gy = BX.groundAt(p)
        if gy then
            local wp = Vector3.new(p.X, gy, p.Z)
            if BX.clearLine(from, wp) then return wp, math.deg(step) end
        end
    end
    return nil
end

-- A waypoint that gets us round the hole toward `to`, or nil if the direct
-- line is already fine (or nothing works).
function BX.detourAround(from, to)
    if BX.clearLine(from, to) then return nil end
    local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
    local dist = flat.Magnitude
    if dist < 1 then return nil end
    local dir = flat.Unit
    local r = math.max(dist * K.AROUND_RADIUS_FRAC, K.AROUND_MIN_RADIUS)

    for _, deg in ipairs(K.AROUND_ANGLES) do
        for _, sign in ipairs({ 1, -1 }) do
            local a = math.rad(deg) * sign
            local d2 = Vector3.new(
                dir.X * math.cos(a) - dir.Z * math.sin(a), 0,
                dir.X * math.sin(a) + dir.Z * math.cos(a))
            local wp = from + d2 * r
            local gy = BX.groundAt(Vector3.new(wp.X, from.Y, wp.Z))
            if gy then
                wp = Vector3.new(wp.X, gy, wp.Z)
                -- It only helps if we can both REACH it and continue from it.
                if BX.clearLine(from, wp) and BX.clearLine(wp, to) then
                    return wp, deg * sign
                end
            end
        end
    end

    -- Nothing single-hop works. Take the best partial: somewhere off the
    -- straight line that we can at least reach, so the next tick re-plans
    -- from a new angle instead of standing still.
    for _, deg in ipairs(K.AROUND_ANGLES) do
        for _, sign in ipairs({ 1, -1 }) do
            local a = math.rad(deg) * sign
            local d2 = Vector3.new(
                dir.X * math.cos(a) - dir.Z * math.sin(a), 0,
                dir.X * math.sin(a) + dir.Z * math.cos(a))
            local wp = from + d2 * r
            local gy = BX.groundAt(Vector3.new(wp.X, from.Y, wp.Z))
            if gy and BX.clearLine(from, Vector3.new(wp.X, gy, wp.Z)) then
                return Vector3.new(wp.X, gy, wp.Z), deg * sign
            end
        end
    end
    return nil
end

-- Somewhere to run to when everything nearby is either a hazard or a cliff.
function BX.arenaCentre()
    local f = BX.arenaFloor()
    if f then return f.Position end
    local a = BX.bossArena()
    if a and a.PrimaryPart then return a.PrimaryPart.Position end
    return nil
end

K.FLOOR_MARGIN = 25   -- how far inside the lip we insist on staying

-- CACHED FOR A FRAME OR TWO.
--
-- The dodge loop runs at K.BOSS_DODGE_GAP (0.08s) and the mover calls
-- inAnyHazard on every Heartbeat, and each of those was doing a full
-- GetDescendants on BossHazards plus four FindFirstChild walks. That is a
-- fresh allocation dozens of times a second for a list that changes maybe
-- once a second. Cache it briefly - hazards telegraph for 2s before they arm,
-- so an 0.1s-old list is never the reason we get hit.
function BX.hazardParts()
    local now = os.clock()
    if BX.hazardCache and (now - (BX.hazardCacheAt or 0)) < K.HAZARD_CACHE then
        return BX.hazardCache
    end

    local out = {}
    local folder = workspace:FindFirstChild("BossHazards")
    if folder then
        for _, d in ipairs(folder:GetDescendants()) do
            if d:IsA("BasePart") then out[#out + 1] = d end
        end
    end
    local arena = BX.bossArena()
    if arena then
        -- SlamIndicator is the 2-stud-thick telegraph that lands before the
        -- box does, so it counts as a hazard in its own right: getting off
        -- the telegraph is the entire point of the telegraph.
        for _, name in ipairs({ "SlamIndicator", "SlamArmHitbox", "SlamRestHitbox" }) do
            local d = arena:FindFirstChild(name)
            if d and d:IsA("BasePart") then out[#out + 1] = d end
        end
    end
    local bh = workspace:FindFirstChild("BossBlackHole")
    if bh and bh:IsA("BasePart") then out[#out + 1] = bh end

    BX.hazardCache, BX.hazardCacheAt = out, now
    return out
end

-- How much room we want outside a given part.
-- THE RED RINGS ARE 2 STUDS WIDE. STOP TREATING THEM LIKE WALLS.
-- Measured live: every RingSegment is 2 x 2 x ~190, and there are five
K.HAZARD_RING_CLEAR = 2

local function hazardClear(part)
    local n = part.Name
    if n == "BossBlackHole" then return K.BLACK_HOLE_CLEAR end
    if n:find("Slam") then return K.HAZARD_SLAM_CLEAR end
    if n:find("Ring") then return K.HAZARD_RING_CLEAR end
    return K.HAZARD_CLEAR
end

-- True if pos is inside part plus that clearance. Cylinders are radial: the
-- black hole is a Cylinder whose axis is X, so its radius is Size.Y * 0.5,
-- not half of its longest side.
local function inHazard(part, pos, extra)
    local clear = hazardClear(part) + (extra or 0)
    if part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
        local flat = Vector3.new(pos.X - part.Position.X, 0, pos.Z - part.Position.Z)
        return flat.Magnitude <= part.Size.Y * 0.5 + clear
    end
    local rel = part.CFrame:PointToObjectSpace(pos)
    local half = part.Size * 0.5
    return math.abs(rel.X) <= half.X + clear
        and math.abs(rel.Z) <= half.Z + clear
        and math.abs(rel.Y) <= half.Y + 8
end

function BX.inAnyHazard(pos, extra)
    -- With dodging off, nothing may refuse to move on account of a hazard
    -- either: the mover's step test and the fight tick's approach gate both
    -- ask this, and both were stopping us reaching the crystal.
    if not BX.bossDodgeEnabled then return nil end
    for _, part in ipairs(BX.hazardParts()) do
        if inHazard(part, pos, extra) then return part end
    end
    return nil
end

-- DODGE TOWARD THE TARGET, NOT JUST AWAY FROM THE HAZARD.
--
--    Every second or so it shoved you another 30 studs off the crystal, and
--    with a hand you never got a swing in at all. The escape has to be chosen
-- 2. IT TELEPORTED. Model:MoveTo is not a walk - it relocates the model, and
--    0.08s against a mover that is writing CFrame every frame is what made the
--     BLACK_HOLE_FOLLOW_SPEED_FRACTION = 0.4   -- 40% of our WalkSpeed
-- It can never catch anything moving faster than 0.4x its target's speed, and
K.DODGE_RING_POINTS = 16

BX.bossAim = nil            -- where the fight tick currently wants us
BX.bossDodge = nil          -- { pos = Vector3 } published for the mover

-- Rank: closest to what we are trying to hit; failing that, least movement.
local function dodgeScore(spot, here)
    local aim = BX.bossAim
    if typeof(aim) == "Vector3" then
        return Vector3.new(spot.X - aim.X, 0, spot.Z - aim.Z).Magnitude
    end
    return Vector3.new(spot.X - here.X, 0, spot.Z - here.Z).Magnitude
end

-- DODGING IS OFF. You said it: do not run from the thing that chases you.
--
-- Every "it moved me off the crystal" and "the hand never gets hit" traces
BX.bossDodgeEnabled = false

function BX.dodgeBossHazards()
    if not BX.bossDodgeEnabled then BX.bossDodge = nil return false end
    local h = getHRP()
    if not h then return false end

    local parts = BX.hazardParts()
    if #parts == 0 then BX.bossDodge = nil return false end

    local hit = nil
    for _, part in ipairs(parts) do
        if inHazard(part, h.Position) then hit = part break end
    end
    if not hit then
        -- Clear. Drop any dodge destination so the fight tick gets the
        -- character back immediately instead of finishing a stale escape.
        BX.bossDodge = nil
        return false
    end

    local here = h.Position
    local cands = {}

    if hit:IsA("Part") and hit.Shape == Enum.PartType.Cylinder then
        -- Black hole: a full ring around it, so "around" is available and not
        -- only "directly away".
        local want = hit.Size.Y * 0.5 + K.BLACK_HOLE_CLEAR + 4
        for i = 0, K.DODGE_RING_POINTS - 1 do
            local ang = (2 * math.pi / K.DODGE_RING_POINTS) * i
            cands[#cands + 1] = Vector3.new(
                hit.Position.X + math.cos(ang) * want, here.Y,
                hit.Position.Z + math.sin(ang) * want)
        end
    else
        local rel = hit.CFrame:PointToObjectSpace(here)
        local half = hit.Size * 0.5
        local clear = hazardClear(hit) + 4
        local outX = (rel.X >= 0 and 1 or -1) * (half.X + clear)
        local outZ = (rel.Z >= 0 and 1 or -1) * (half.Z + clear)
        cands[#cands + 1] = hit.CFrame:PointToWorldSpace(Vector3.new(rel.X, rel.Y, outZ))
        cands[#cands + 1] = hit.CFrame:PointToWorldSpace(Vector3.new(outX, rel.Y, rel.Z))
        cands[#cands + 1] = hit.CFrame:PointToWorldSpace(Vector3.new(rel.X, rel.Y, -outZ))
        cands[#cands + 1] = hit.CFrame:PointToWorldSpace(Vector3.new(-outX, rel.Y, rel.Z))
        -- The two corners as well: with a 75 x 249 slam box, going along it is
        -- often much shorter than going across it.
        cands[#cands + 1] = hit.CFrame:PointToWorldSpace(Vector3.new(outX, rel.Y, outZ))
        cands[#cands + 1] = hit.CFrame:PointToWorldSpace(Vector3.new(-outX, rel.Y, outZ))
    end

    -- Keep only escapes that are ON THE FLOOR and clear of everything else,
    -- then take the one nearest the target. That is the whole fix for "it
    -- moves me away from the crystals".
    local best, bestScore
    for _, spot in ipairs(cands) do
        if BX.onArenaFloor(spot) and not BX.inAnyHazard(spot, 0) then
            local sc = dodgeScore(spot, here)
            if not bestScore or sc < bestScore then best, bestScore = spot, sc end
        end
    end

    -- Nothing clear: on-floor still beats the void, so take the nearest of
    -- those instead. Being hit is survivable; falling out of the map is not.
    if not best then
        for _, spot in ipairs(cands) do
            if BX.onArenaFloor(spot) then
                local sc = dodgeScore(spot, here)
                if not bestScore or sc < bestScore then best, bestScore = spot, sc end
            end
        end
        if best then trace("boss: no clear escape - nearest on-floor spot inside " .. hit.Name) end
    end

    -- Every candidate is over the void. Head inward: the middle of the floor
    -- is always solid and the ring hazards are radial, so inward leaves them.
    if not best then
        local mid = BX.arenaCentre()
        if mid then
            local inward = Vector3.new(mid.X - here.X, 0, mid.Z - here.Z)
            if inward.Magnitude > 1 then
                best = here + inward.Unit * math.min(inward.Magnitude, 60)
                trace("boss: every escape was off the floor - stepping inward")
            end
        end
    end
    if not best then return true end

    -- PUBLISH IT, DO NOT TELEPORT TO IT. One writer owns the character.
    BX.bossDodge = { pos = best }
    BX.dodges = (BX.dodges or 0) + 1
    if BX.dodges <= 3 or BX.dodges % 40 == 0 then
        trace(("boss: dodging %s toward the target (%d dodges)"):format(hit.Name, BX.dodges))
    end
    return true
end

-- THE DODGE NEEDS ITS OWN CLOCK.
--
-- It used to run once per swing tick - every K.BOSS_SWING_GAP, 0.65s. The
K.BOSS_DODGE_GAP = 0.08

function BX.startBossDodge()
    if BX.bossDodgeThread then return end
    BX.bossDodgeThread = task.spawn(function()
        while BX.autoBossFight do
            task.wait(K.BOSS_DODGE_GAP)
            if BX.inBossArena() then
                pcall(BX.dodgeBossHazards)
            end
        end
        BX.bossDodgeThread = nil
    end)
end

function BX.stopBossDodge()
    local t = BX.bossDodgeThread
    BX.bossDodgeThread = nil
    if t then pcall(task.cancel, t) end
end

-- LEAVE WHEN IT IS DEAD. Otherwise we stand in an empty arena until the window
-- closes instead of going back to stealing eggs.
function BX.leaveBossArena()
    local arena = BX.bossArena()
    local exit = arena and arena:FindFirstChild("BossArenaLeaveTeleport", true)
    local part = exit and (exit:IsA("BasePart") and exit
        or exit:FindFirstChild("Hitbox", true)
        or exit:FindFirstChildWhichIsA("BasePart", true))
    if not part then return false end
    local c = getChar()
    if c then
        pcall(function() c:MoveTo(part.Position + Vector3.new(0, 3, 0)) end)
        trace("boss: dead - walking out")
        return true
    end
    return false
end

-- MASTERY MILESTONES. Data.BossMastery.Milestones, counted in KILLS:
--     3 -> RiftbornEgg    5 -> TokenBoost   10 -> RiftbeastsEgg
function BX.claimBossMilestones()
    local ok, BM = pcall(require, RS.Data.BossMastery)
    if not ok or type(BM) ~= "table" then return 0 end
    local claimed = 0
    local ids = {}
    for _, m in pairs(BM.Milestones or {}) do
        if type(m) == "table" and m.Id then ids[#ids + 1] = tostring(m.Id) end
    end
    if BM.InfiniteMilestoneId then ids[#ids + 1] = tostring(BM.InfiniteMilestoneId) end
    for _, id in ipairs(ids) do
        local got, msg = BX.netCall("RF/BossMastery/AskClaimMilestone", id)
        if got == true then
            claimed = claimed + 1
            trace("boss: claimed milestone " .. id)
        elseif msg and not tostring(msg):find("Not enough") then
            trace(("boss: milestone %s -> %s"):format(id, tostring(msg)))
        end
        task.wait(0.15)
    end
    return claimed
end

BX.autoBossFight = false

-- THE FIGHT TICK IS NOT THE SWING TICK.
--
-- These were the same number (0.65s, the bat's cooldown), which meant the
K.BOSS_TICK = 0.12
K.BOSS_WAIT_MAX = 2.5   -- longest we stand still waiting for a hazard to clear

task.spawn(function()
    local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
    while true do
        if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
        task.wait(K.BOSS_TICK)
        if BX.autoBossFight and BX.inBossArena() then
            pcall(function()
                local bat = BX.equipBat()

                -- NO BAT MUST NOT MEAN NO MOVEMENT.
                --
                -- This returned here when no bat was found - before the target
                -- was picked and before BX.bossGoal was set - so without a bat
                -- the mover had nothing to walk to and the character stood
                -- still in the arena: "it doesn't move to the crystals". In V3
                -- the bat was a permanent tool, so it never came up. The game
                -- has since made it a gear item with a use count (measured:
                -- "Bat [X1]", ItemType=Gear, Uses=1, CooldownActive), so it
                -- can be used up or simply not there. Now the fight carries on
                -- without one - moving, targeting, dodging - and only the swing
                -- waits for a bat.
                if not bat then
                    -- The game added RF/Codex/AskWearFieldBat alongside that
                    -- change; ask it for the arena bat, now and then, and log
                    -- what it says so the next fight shows whether it is right.
                    if os.clock() - (BX.fieldBatAskedAt or 0) > 5 then
                        BX.fieldBatAskedAt = os.clock()
                        local okW, msgW = BX.netCall("RF/Codex/AskWearFieldBat")
                        trace(("boss: no bat - AskWearFieldBat -> %s %s")
                            :format(tostring(okW), tostring(msgW or "")))
                    end
                elseif BX.batEquippedAt ~= bat then
                    -- A tool parented in this frame has not fired Equipped yet,
                    -- so the controller still says _isEquipped = false and
                    -- swallows the swing. Give it a beat the first time.
                    BX.batEquippedAt = bat
                    task.wait(K.BOSS_EQUIP_SETTLE)
                end

                -- Physics state = IsRagdolled = swing refused. Put the
                -- humanoid back before asking.
                local hmz = getHumanoid()
                if hmz then
                    local stt = hmz:GetState()
                    -- None turns up in the arena and is not a state the
                    -- humanoid can act from either; measured live mid-fight.
                    if hmz.PlatformStand or stt == Enum.HumanoidStateType.Physics
                       or stt == Enum.HumanoidStateType.PlatformStanding
                       or stt == Enum.HumanoidStateType.None then
                        BX.readyAfterRagdoll()
                    end
                end
                -- NO LONGER A HARD RETURN.
                --
                -- most of the fight, it follows you - we never picked a
                -- target, never aimed, and never swung. Combined with the
                -- dodge shoving us away, that is "the hand never gets hit".
                -- APPROACH defers, because the mover already prioritises the
                local inHaz = BX.dodgeBossHazards()

                -- Dead boss: claim and get out.
                local snap = X.bossSnapshot()
                if snap and tonumber(snap.BossHealth) and snap.BossHealth <= 0 then
                    BX.claimBossMilestones()
                    BX.leaveBossArena()
                    return
                end

                if BX.bossPhase() == "hands" then pcall(BX.traceHands) end

                local part, kind = BX.bossTarget()
                if not part then
                    BX.bossGoal, BX.bossAim = nil, nil
                    local ph = BX.bossPhase()
                    if BX.bossIdleAt ~= ph then
                        BX.bossIdleAt = ph
                        trace(("boss: nothing to hit (phase=%s) - holding position")
                            :format(tostring(ph or "spawning")))
                    end
                    return
                end
                BX.bossIdleAt = false

                -- bossTarget returns a BasePart for a crystal and a bare
                -- Vector3 for a hand - a Bone has no part to hold.
                local tpos = (typeof(part) == "Vector3") and part or part.Position

                local h = getHRP()
                if not h then return end
                local reach = BX.targetReach(part)

                -- FLAT DISTANCE, NOT 3D - AND THIS IS WHY IT NEVER SWUNG.
                --
                -- 27 studs above the floor: measured live, hitbox at y 120
                -- 55/2 + 7 = 34.5 studs, which is a FOOTPRINT number.
                -- = 43.8, which is never <= 34.5. So the tick believed it was
                -- always too far, always re-issued the approach, and never
                local d = Vector3.new(tpos.X - h.Position.X, 0, tpos.Z - h.Position.Z).Magnitude

                -- Close the gap with the mover that already works, then face
                -- the target so the swing lands.
                -- DO NOT WALK INTO THE SLAM TO REACH SOMETHING.
                -- DO NOT WALK INTO THE SLAM TO REACH SOMETHING, but do not
                local flatDir = Vector3.new(tpos.X - h.Position.X, 0, tpos.Z - h.Position.Z)
                local stand = h.Position + (flatDir.Magnitude > 0.001
                    and flatDir.Unit * math.max(flatDir.Magnitude - reach, 0) or Vector3.zero)
                if BX.inAnyHazard(Vector3.new(stand.X, h.Position.Y, stand.Z), 0) then
                    if not BX.bossWaitAt then
                        BX.bossWaitAt = os.clock()
                        trace("boss: target is inside a hazard - waiting for it to clear")
                    end
                    if os.clock() - BX.bossWaitAt < K.BOSS_WAIT_MAX then
                        BX.bossGoal = nil
                        return
                    end
                else
                    BX.bossWaitAt = nil
                end

                -- Tell the dodge what we are trying to reach, so when it has
                -- to move us it picks the escape nearest THIS rather than the
                -- first clear direction it happens to find.
                BX.bossAim = tpos

                -- SWING TOLERANCE > ARRIVAL TOLERANCE, OR THEY DEADLOCK.
                --
                -- The mover finishes when flat - reach <= K.BOSS_MOVE_ARRIVE,
                -- so it parks 1.5 studs FURTHER OUT than `reach`. If the tick
                -- then demands d <= reach exactly, the two disagree forever:
                -- the tick re-issues the goal, the mover says it has arrived,
                -- and nothing swings. Measured live - nine seconds sitting at
                -- d=8..9 against a reach of 7.5, one hit in the whole window.
                --
                -- The slack has to cover the arrival window with room to
                -- spare. Manual swings landed cleanly at 8 studs, so the
                -- server's own range is wider than our reach anyway.
                if d > reach + K.BOSS_SWING_SLACK then
                    -- Hand the destination to the continuous mover and come
                    -- straight back. This tick now runs every K.BOSS_TICK, so
                    -- move-for-0.4s-then-freeze.
                    -- SMOOTH THE THING WE ARE CHASING.
                    --
                    -- A hand's position comes from a skinned bone and moves
                    -- every frame, so handing the raw value to the mover made
                    -- it chase noise - the goal jumped a little in every
                    -- direction and the walk wobbled. Low-pass it: the filter
                    -- follows real movement within a couple of ticks and
                    -- ignores the jitter on top of it.
                    local smooth = tpos
                    if kind == "hand" then
                        local prev = BX.trackPos
                        if prev and (prev - tpos).Magnitude < K.BOSS_TRACK_JUMP then
                            local a = 1 - math.exp(-K.BOSS_TICK / K.BOSS_TRACK_TAU)
                            smooth = prev:Lerp(tpos, a)
                        end
                        BX.trackPos = smooth
                    else
                        BX.trackPos = nil
                    end

                    BX.bossGoal = { pos = smooth, reach = reach }
                    return
                end
                -- IN RANGE. Keep circling if the hole is on us - the goal
                -- stays at the same radius from the target, so this never
                -- costs us the swing.
                local orbit = BX.orbitPoint(tpos, reach)
                if orbit then
                    BX.bossGoal = { pos = orbit, reach = 0 }
                    if os.clock() - (BX.orbitAt or 0) > 3 then
                        BX.orbitAt = os.clock()
                        trace("boss: black hole is on us - orbiting the target")
                    end
                else
                    BX.bossGoal = nil
                end

                -- In range but still standing in something: let the dodge
                -- finish moving us before swinging, otherwise we swing from
                -- inside a slam box and eat it for nothing.
                if inHaz then return end

                -- IN RANGE: STAND STILL. THE CAMERA IS WATCHING.
                --
                -- This rewrote the root CFrame on every tick - eight times a
                -- second - whether or not we were already facing the target.
                -- Each write teleports the character in place, and the camera
                -- follows the root, so the view snapped eight times a second
                -- while swinging. That is the juddering.
                --
                -- Now it only turns when the aim is actually off, and it eases
                -- into the new angle instead of snapping to it. Position is
                -- taken from the CFrame we already hold rather than re-read,
                -- so standing still means standing still exactly.
                local hh = getHRP()
                if hh then
                    local flat = Vector3.new(tpos.X - hh.Position.X, 0, tpos.Z - hh.Position.Z)
                    if flat.Magnitude > 0.1 then
                        local wantDir = flat.Unit
                        local haveDir = hh.CFrame.LookVector * Vector3.new(1, 0, 1)
                        haveDir = haveDir.Magnitude > 0.001 and haveDir.Unit or wantDir
                        -- Dot of two unit vectors is the cosine of the angle
                        -- between them, so this is "more than N degrees off".
                        if haveDir:Dot(wantDir) < K.BOSS_AIM_COS then
                            local cur = hh.CFrame
                            local goal = CFrame.lookAt(cur.Position, cur.Position + wantDir)
                            pcall(function()
                                hh.CFrame = cur:Lerp(goal, K.BOSS_AIM_EASE)
                            end)
                        end
                    end
                end
                -- The swing is the only part that needs a bat - and one that
                -- is off cooldown, or the game swallows it.
                if not bat or not bat.Parent then return end
                if bat:GetAttribute("CooldownActive") == true then return end
                if os.clock() - (BX.lastSwingAt or 0) < K.BOSS_SWING_GAP then return end
                BX.lastSwingAt = os.clock()
                BX.batSwing(bat)
                BX.swings = (BX.swings or 0) + 1
                if BX.swings % 20 == 1 then
                    trace(("boss: swinging at the %s (%d swings)"):format(tostring(kind), BX.swings))
                end
            end)
        end
    end
end)

-- THE WINDOW IS SHORT. Data.BossEvent.IntervalSeconds is 1800, the window
-- itself is minutes, and the boss is only actually up for a couple of those.
-- the ENTER decision does, so the loop runs at 1s and the snapshot cache
task.spawn(function()
    local lastOpen = nil
    local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
    while true do
        if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
        -- POLL AT THE RATE THE ANSWER CHANGES.
        --
        -- This asked the server for a fresh boss snapshot once a SECOND, for
        -- the whole session, whether or not the event was open and whether or
        -- not the Event tab was even on screen. That is a remote round trip
        -- per second forever, purely to redraw a countdown.
        --
        -- The event runs on a 1800s cycle. While it is closed the only thing
        -- moving is a timer we can render from the last snapshot, so a slow
        -- poll is enough; in the arena the health bar matters and it goes back
        -- to once a second.
        local fast = (BX.inBossArena and BX.inBossArena())
            or (X.bossSnap and X.bossSnap.Open == true)
        -- Defaults inline: this loop's first iteration runs during chunk
        -- execution, before the K assignments further down have happened.
        task.wait(fast and (K.BOSS_POLL_FAST or 1) or (K.BOSS_POLL_IDLE or 10))
        pcall(function()
            -- The panel owns the fresh read; the fight tick then rides the
            -- cache it leaves behind.
            local snap = X.bossSnapshot(true)
            if not snap then
                X.boss.line.Set(X.boss.line, "Could not read the boss event")
                return
            end
            local now = workspace:GetServerTimeNow()
            local open = snap.Open == true
            local line
            if not open then
                line = "Closed - opens in " .. fmtClock((snap.OpensAt or now) - now)
                    .. " (every 30 min)"
            elseif BX.bossDeadWindow then
                line = "Already killed this round - next one in "
                    .. fmtClock((snap.OpensAt or now) - now)
            else
                line = "OPEN - closes in " .. fmtClock((snap.ClosesAt or now) - now)
            end
            X.boss.line.Set(X.boss.line, line)

            -- Fire once on the transition, not every three seconds while it is
            -- open - AskEnter is a server call and spamming it is exactly the
            -- was already open meant the edge never came and it never entered -
            -- Now: enter whenever it is open and we are not already inside,
            -- live. Without noticing that, auto enter asks every 5s for the
            if lastOpen ~= open then BX.bossDeadWindow = nil end

            local needEnter = BX.autoBoss and open and not BX.inBossArena()
                and not BX.bossDeadWindow
                and (os.clock() - (BX.lastEnterAsk or 0)) > 2
            if needEnter then
                BX.lastEnterAsk = os.clock()
                local accepted, msg = BX.netCall("RF/BossEvent/AskEnter")
                trace(("boss: auto enter -> accepted=%s msg=%s")
                    :format(tostring(accepted), tostring(msg)))
                if accepted == true then
                    toast("Boss world open - going in")
                elseif msg and tostring(msg):find("defeated") then
                    -- Not an error, just too late: the window stays open after
                    -- the kill. Say so once and stop asking until it resets.
                    BX.bossDeadWindow = true
                    trace("boss: already defeated this round - waiting for the next window")
                    toast("Boss already defeated - waiting for the next one")
                end
            end
            lastOpen = open
        end)
    end
end)

---------- RIFT ----------
--
-- The trade eats three pets, so it only ever happens with "Auto trade-in"
-- switched on (off by default) - see X.riftTryTrade. Everything else here
-- reads.
--
-- Everything comes from RF/Rift/AskState, which returns the lot:
--   BannerDisplayName, Requirements, PityCount/PityThreshold,
--   SecondsUntilRotation, PetOdds, FreeRefreshesRemaining
X.rift = {}
-- The dropdown is a list of pets you can go and steal RIGHT NOW, so it has
-- to track the field closely. At 6s it was routinely offering a pet that had
-- already been taken by the time you picked it.
-- Boss panel poll. Fast only when it matters: in the arena, or while the
-- event window is actually open. Otherwise the countdown is the only thing
-- moving and it does not need a server round trip every second.
K.BOSS_POLL_FAST = 1
K.BOSS_POLL_IDLE = 10
K.RIFT_POLL = 2.5
K.RIFT_STALE_MAX = 8       -- how long a failed read may keep showing the old list

function X.riftState(force)
    if not force and X.riftSnap and (os.clock() - (X.riftSnapAt or 0)) < K.RIFT_POLL then
        return X.riftSnap
    end
    local net = RS.Packages:FindFirstChild("Networking")
    local rf = net and net:FindFirstChild("RF/Rift/AskState")
    if not rf then return nil end
    local ok, st = pcall(function() return rf:InvokeServer() end)
    if not ok or type(st) ~= "table" then return nil end
    X.riftSnap, X.riftSnapAt = st, os.clock()
    return st
end

-- HOW MANY OF THE REQUIRED PETS WE HOLD.
--
-- This said 0/3 while the account actually held 2 of the 3. Measured live,
-- with Requirements = {"Lava frog", "Sabertooth Tiger", "Lava Iguana"}:
--     Save.Get(player).Inventory  ->  Lava frog x1, Sabertooth Tiger x2
-- so the answer was 2/3 and the old read could never have found it. Three
-- separate reasons, all of them fatal on their own:
--
--  1. WRONG FIELD. It scanned for `v.AssetCategory`. Owned pets do not have
--     that key - field eggs do. An inventory row is `{Category = "Shark",
--     Scale = ..., Gender = ...}` and a placed pet is
--     `Records[uid].ItemData.Category`. AssetCategory appears in neither, so
--     the scan matched nothing and returned an empty set every time.
--
--  2. WRONG SOURCE. AssetRoster.ReadSnapshot() only carries pets PLACED IN
--     PENS - 17 rows here - while the pets a rift wants are normally sitting
--     in the inventory, which is 86 rows and was never read at all.
--
--  3. OTHER PEOPLE'S PETS. That snapshot holds one entry per owner in the
--     server, not just ours - measured: owners 1119822372, 11563489586 and
--     10404483210 (us). Nothing filtered by OwnerUserId, so had the field
--     name matched, the count would have included strangers' pens.
--
-- So: read the inventory as the primary source, add pets we have already
-- placed, and count each requirement once. Returns nil only when neither
-- source can be read, so the line drops the count instead of lying about it.
function X.riftOwned(reqs)
    if type(reqs) ~= "table" or #reqs == 0 then return nil end

    local counts, got = {}, false

    -- The inventory: every pet owned but not placed. Rows are flat, keyed by
    -- uid, and the category field is plain `Category`.
    pcall(function()
        local Save = require(RS.Shared.Save)
        local data = Save.Get and Save.Get(LocalPlayer)
        if type(data) ~= "table" or type(data.Inventory) ~= "table" then return end
        for _, row in pairs(data.Inventory) do
            if type(row) == "table" then
                local cat = row.Category or (row.ItemData and row.ItemData.Category)
                if cat then
                    counts[cat] = (counts[cat] or 0) + 1
                    got = true
                end
            end
        end
    end)

    -- Plus anything already out in our own pen. OwnerUserId is checked on the
    -- entry, because the snapshot carries every owner in the server.
    pcall(function()
        local AR = require(RS.Client.AssetRoster)
        if type(AR.ReadSnapshot) ~= "function" then return end
        local snap = AR.ReadSnapshot()
        if type(snap) ~= "table" then return end
        for _, entry in pairs(snap) do
            if type(entry) == "table" and entry.OwnerUserId == LocalPlayer.UserId
               and type(entry.Records) == "table" then
                for _, rec in pairs(entry.Records) do
                    local cat = type(rec) == "table" and rec.ItemData and rec.ItemData.Category
                    if cat then
                        counts[cat] = (counts[cat] or 0) + 1
                        got = true
                    end
                end
            end
        end
    end)

    if not got then return nil end

    local have, missing = 0, {}
    for _, r in ipairs(reqs) do
        if (counts[r] or 0) > 0 then have = have + 1 else missing[#missing + 1] = r end
    end
    return have, missing
end

-- WHAT WE ALREADY HAVE TOWARDS THE RIFT - PETS *AND* EGGS.
--
-- "Auto steal rift pets" kept stealing the same pet over and over. Measured
-- (2026-09-11), Requirements = Parrotfish, Flaming Bull, Orca, account holding
-- 2 Flaming Bulls and 2 Orcas: riftWanted still returned all three, so the
-- loop went back for Bulls and Orcas it did not need - and every extra trip
-- home was another chance to meet the monster and drop the egg.
--
-- Two things were wrong. riftWanted ignored ownership entirely, and even the
-- have-count only knew about hatched pets - a stolen egg is an EGG until it
-- hatches (a Stag Egg takes 3h), so right after stealing requirement #1 it
-- still looked missing and the loop went straight back for another.
--
-- Per requirement this returns:
--   owned - pets of that kind anywhere (inventory, equipped, placed)
--   eggs  - unhatched eggs of that kind we own (EggState.ReadOwnerEggs)
--   uids  - inventory pets the Rift will actually accept, lightest first:
--           not equipped, and FuseKernel.MayEnterRift says yes. That is the
--           exact filter and order the game's own trade-in window uses.
-- Game modules narrow the calling thread, so callers go through
-- X.riftHaveCached, which reads on BX.offthread.
--
-- CHEAP UNLESS TRADING. The rift poll runs all session (every K.RIFT_POLL),
-- and deciding what is WANTED only needs a count per kind. Decoding every
-- pet for its weight and asking FuseKernel about each one is only worth
-- doing when a trade is actually about to happen, so that half runs only
-- with `forTrade` - otherwise it was per-pet work every few seconds, for the
-- whole session, whether or not the Event tab was ever opened.
function X.riftHave(reqs, forTrade)
    if type(reqs) ~= "table" or #reqs == 0 then return nil end
    local out, okAny = {}, false
    for _, r in ipairs(reqs) do out[r] = out[r] or { owned = 0, eggs = 0, uids = {} } end

    pcall(function()
        local Save = require(RS.Shared.Save)
        local data = Save.Get and Save.Get(LocalPlayer)
        if type(data) ~= "table" or type(data.Inventory) ~= "table" then return end
        okAny = true
        local FuseKernel, AssetItems
        if forTrade then
            pcall(function() FuseKernel = require(RS.Shared.Util.FuseKernel) end)
            pcall(function() AssetItems = require(RS.Shared.Util.AssetItems) end)
        end
        local equipped = {}
        for _, u in pairs(data.EquippedAssets or {}) do equipped[u] = true end
        local weight = {}
        for uid, row in pairs(data.Inventory) do
            local cat = type(row) == "table" and (row.Category or (row.ItemData and row.ItemData.Category))
            local slot = cat and out[cat]
            if slot then
                slot.owned += 1
                local may = forTrade and not equipped[uid]
                if may and FuseKernel and FuseKernel.MayEnterRift then
                    local ok, r = pcall(FuseKernel.MayEnterRift, uid, row)
                    may = ok and r == true
                end
                if may then
                    local w = math.huge
                    if AssetItems then
                        pcall(function() w = AssetItems.WeightKg(AssetItems.Decode(row)) end)
                    end
                    weight[uid] = w
                    slot.uids[#slot.uids + 1] = uid
                end
            end
        end
        for _, slot in pairs(out) do
            table.sort(slot.uids, function(a, b) return (weight[a] or 0) < (weight[b] or 0) end)
        end
    end)

    -- Pets already out in our own pen count as owned too.
    pcall(function()
        local snap = require(RS.Client.AssetRoster).ReadSnapshot()
        for _, entry in pairs(type(snap) == "table" and snap or {}) do
            if type(entry) == "table" and entry.OwnerUserId == LocalPlayer.UserId
               and type(entry.Records) == "table" then
                for _, rec in pairs(entry.Records) do
                    local cat = type(rec) == "table" and rec.ItemData and rec.ItemData.Category
                    if cat and out[cat] then out[cat].owned += 1 okAny = true end
                end
            end
        end
    end)

    pcall(function()
        for _, rec in pairs(EggState.ReadOwnerEggs(LocalPlayer.UserId) or {}) do
            local slot = type(rec) == "table" and out[rec.AssetCategory]
            if slot then slot.eggs += 1 okAny = true end
        end
    end)

    return okAny and out or nil
end

function X.riftHaveCached(reqs)
    local sig = type(reqs) == "table" and table.concat(reqs, "|") or ""
    if X.riftHaveMemo and X.riftHaveSig == sig and os.clock() - (X.riftHaveAt or 0) < 10 then
        return X.riftHaveMemo
    end
    local r = BX.offthread(function() return X.riftHave(reqs) end, 3)
    X.riftHaveMemo, X.riftHaveAt, X.riftHaveSig = r, os.clock(), sig
    return r
end

-- Only the requirements we have NOTHING of - no pet, no egg on the way. When
-- ownership cannot be read at all, everything is wanted (the old behaviour).
-- An empty set means the rift is covered: nothing left to steal for it.
function X.riftWanted()
    local st = X.riftState()
    local reqs = st and st.Requirements
    if type(reqs) ~= "table" or #reqs == 0 then return nil end
    local have = X.riftHaveCached(reqs)
    local set = {}
    for _, r in ipairs(reqs) do
        local h = have and have[r]
        if not h or (h.owned + h.eggs) == 0 then set[r] = true end
    end
    return set
end

-- PUT THE PETS IN THE RIFT - the same call the game's trade-in window makes.
--
-- Decompiled from PlayerScripts.GUI.RiftTradeIn: slot i takes a pet whose
-- Category is Requirements[i], the three inventory uids go to
--     Remotes.Rift.AskTradeIn:InvokeServer({ uid1, uid2, uid3 })
-- and on `true` the window plays its reveal and then calls
-- Rift.AskFinishReveal, which hands over the Rift Egg. A pending reward from
-- an earlier trade is finished the same way.
--
-- Opt-in only (Event tab, "Auto trade-in"): it destroys three pets. It takes
-- the lightest eligible pet of each kind - the one the game lists first - and
-- never an equipped one. Does nothing until all three are hatched pets.
function X.riftTryTrade()
    if X.riftTrading then return nil end
    X.riftTrading = true
    local result = BX.offthread(function()
        local net = RS.Packages:FindFirstChild("Networking")
        if not net then return nil end
        local st = X.riftState(true)
        if type(st) ~= "table" then return nil end
        if st.PendingReward then
            local fr = net:FindFirstChild("RF/Rift/AskFinishReveal")
            if fr then pcall(function() fr:InvokeServer() end) end
            return "revealed"
        end
        local reqs = st.Requirements
        if type(reqs) ~= "table" or #reqs < 3 then return nil end
        -- Cheap count first; the per-pet eligibility read only once all
        -- three kinds are actually owned as pets.
        local cheap = X.riftHave(reqs)
        if not cheap then return nil end
        for _, r in ipairs(reqs) do
            if not cheap[r] or cheap[r].owned == 0 then return nil end
        end
        local have = X.riftHave(reqs, true)
        if not have then return nil end
        local uids, used = {}, {}
        for i = 1, 3 do
            local slot = have[reqs[i]]
            for _, u in ipairs(slot and slot.uids or {}) do
                if not used[u] then uids[i] = u used[u] = true break end
            end
            if not uids[i] then return nil end      -- not ready yet
        end
        local rf = net:FindFirstChild("RF/Rift/AskTradeIn")
        if not rf then return nil end
        local ok, res, msg = pcall(function() return rf:InvokeServer(uids) end)
        if not ok or res ~= true then
            return "refused: " .. tostring(ok and (msg or res) or res)
        end
        task.wait(1)
        local fr = net:FindFirstChild("RF/Rift/AskFinishReveal")
        if fr then pcall(function() fr:InvokeServer() end) end
        return "traded"
    end, 12)
    X.riftTrading = false
    X.riftHaveAt = 0     -- the inventory just changed
    return result
end

-- Which of the wanted pets are actually on the field right now.
-- READ THE FIELD, NOT THE CACHE.
--
-- This used cachedEggs, which is only rebuilt by the steal loop or a manual
-- refresh - so the count sat still while eggs were taken and respawned, and
-- pressing Refresh appeared to do nothing. Read the records directly.
--
-- The read touches game modules, which narrows the calling thread, so it runs
-- through BX.offthread: the same split the ESP uses. The caller stays clean
-- and can still write to the GUI afterwards.
function X.riftFieldPets()
    local want = X.riftWanted()
    if not want then return nil end
    return BX.offthread(function()
        local data = BX.snapshot(true)
        if not (data and type(data.Records) == "table") then return nil end
        local seen, out = {}, {}
        for _, rec in ipairs(data.Records) do
            local st = rec.State
            if (st == "Slot" or st == "Dropped")
               and want[rec.AssetCategory] and not seen[rec.AssetCategory] then
                seen[rec.AssetCategory] = true
                out[#out + 1] = rec.AssetCategory
            end
        end
        return out
    end, 3)
end

-- Cached so the 6s repaint and the dropdown rebuild share one read.
function X.riftOnField(force)
    if force or not X.riftField or (os.clock() - (X.riftFieldAt or 0)) > K.RIFT_POLL then
        local fresh = X.riftFieldPets()
        if fresh then
            -- A real answer, including an empty one. `{}` is truthy in Lua, so
            -- "nothing is out" correctly replaces the list.
            X.riftField = fresh
            X.riftFieldOkAt = os.clock()
        else
            -- The read FAILED (no requirements yet, or the snapshot thread did
            -- not come back). This used to be `or X.riftField`, which kept the
            -- last good list forever - so the dropdown went on advertising a
            -- pet that had been gone for minutes. Tolerate a brief gap, then
            -- admit we do not know.
            if (os.clock() - (X.riftFieldOkAt or 0)) > K.RIFT_STALE_MAX then
                X.riftField = {}
            end
        end
        X.riftFieldAt = os.clock()
    end
    return X.riftField
end

-- Is this pet actually out right now?
function X.riftPetIsOut(id)
    for _, out in ipairs(X.riftOnField() or {}) do
        if out == id then return true end
    end
    return false
end

-- Drop a pick whose pet has left the field, and rebuild the list so it is
-- gone from the box too. Returns true if it dropped something.
function X.riftForgetPick()
    local id = BX.riftPet
    if not id or X.riftPetIsOut(id) then return false end
    BX.riftPet = nil
    trace("rift: " .. X.petName(id) .. " is no longer out - clearing the pick")
    toast(X.petName(id) .. " is gone - taking any rift pet")
    pcall(function()
        X.riftSuppress = true
        local opts = X.riftOptions()
        X.rift.optSig = table.concat(opts, "")
        X.rift.pick:Refresh(opts)
        X.rift.pick:Set(opts[1], true)
        X.riftSuppress = false
    end)
    return true
end

-- THE RIFT SPEAKS IN IDS, EVERYTHING ELSE SPEAKS IN NAMES.
--
-- Requirements come back as Directory ids - "Mantis", "Lava frog" - while the
-- egg list, the ESP and the game's own UI show the pet's DisplayName. Those
-- are not always the same word:
--     Directory["Mantis"].DisplayName        = "Mantaris"
--     Directory["Galaxy Gecko"].DisplayName  = "Cosmic Gecko"
-- so the Rift tab was naming pets that appeared nowhere else in the hub, and
-- a pet you had just hatched looked like a different animal entirely.
--
-- Ids stay the matching key - they are what the records carry - but nothing
-- shows one to you any more.
function X.petName(id)
    if not AssetsDir then return tostring(id) end
    local cfg = AssetsDir[id]
    return (cfg and cfg.DisplayName) and tostring(cfg.DisplayName) or tostring(id)
end

function X.petNames(ids)
    local out = {}
    for _, id in ipairs(ids or {}) do out[#out + 1] = X.petName(id) end
    return out
end

X.rift.none = "No pets spawned"

-- Only the wanted pets that are actually on the field, for the dropdown.
function X.riftOptions()
    local out = {}
    X.riftLabelToId = {}
    for _, id in ipairs(X.riftOnField() or {}) do
        local label = X.petName(id)
        X.riftLabelToId[label] = id
        out[#out + 1] = label
    end
    if #out == 0 then out[1] = X.rift.none end
    return out
end

EventTab:CreateSection({ name = "Rift" })

X.rift.line = EventTab:CreateText({ name = "Rift", text = "reading..." })

X.rift.pick = EventTab:CreateDropdown({
    name = "Rift pet",
    options = { X.rift.none },
    value = X.rift.none,
    flag = "RiftPet",
    callback = function(v)
        -- ONLY YOU CHANGE THIS BOX.
        --
        -- The pet list refreshes every few seconds, and Refresh/Set re-run this
        -- callback through the library's dispatcher - the same re-entrancy the
        -- egg dropdown already guards with UI.suppress. So a background refresh
        -- was silently re-aiming the run:
        --     35.09 rift: taking Orca
        --     35.94 rift: targeting Penguin      <- nobody touched the UI
        -- Main auto steal never does this because you pick once and it stays.
        if X.riftSuppress then return end
        if type(v) == "table" then v = v[1] end
        -- The box shows the pet's name; the loop matches on the id.
        local id = (v ~= X.rift.none) and ((X.riftLabelToId or {})[v] or v) or nil
        BX.riftPet = id
        BX.riftCommitted = nil          -- a NEW choice releases the old commit
        if BX.riftPet then
            trace(("rift: targeting %s (id %s)"):format(X.petName(id), tostring(id)))
            BlyxoNote("rift-pick", "Rift pet: " .. X.petName(id), 3)
        end
    end,
})

EventTab:CreateButton({
    name = "Refresh",
    description = "Re-read the rift and the pet list",
    callback = function()
        X.riftSnapAt = 0
        X.riftFieldAt = 0
        pcall(X.riftState, true)
        pcall(X.riftOnField, true)
        pcall(X.riftPaint)
        pcall(function()
            local opts = X.riftOptions()
            X.rift.optSig = table.concat(opts, "")
            X.rift.pick:Refresh(opts)
        end)
        local out = X.riftOnField() or {}
        BlyxoNote("rift-refresh", (#out > 0) and ("Rift: " .. table.concat(X.petNames(out), ", ")) or "Rift: none out", 2)
    end,
})

EventTab:CreateToggle({
    name = "Auto steal rift pets",
    description = "Steals only the rift pets",
    value = false,
    flag = "RiftAuto",
    callback = function(v)
        BX.riftOnly = v and true or false
        trace("rift: auto " .. (BX.riftOnly and "ON" or "OFF"))
        BlyxoNote("rift-auto", "Rift auto " .. (BX.riftOnly and "ON" or "OFF"), 2)
        -- Drive the Main tab's Auto Steal so one button is enough.
        local el = X.el and X.el.autoSteal
        if el then
            for _, fn in ipairs({ "Set", "SetValue", "Toggle" }) do
                if type(el[fn]) == "function" then
                    pcall(el[fn], el, BX.riftOnly)
                    return
                end
            end
        end
        if BX.riftOnly then toast("Now turn on Auto Steal") end
    end,
})

-- Off by default, and it says what it costs: a trade-in destroys the three
-- pets. See X.riftTryTrade for exactly which ones it picks.
BX.riftAutoTrade = false
EventTab:CreateToggle({
    name = "Auto trade-in",
    description = "Puts your 3 rift pets in the Rift when you have them (lightest first, never equipped)",
    value = false,
    flag = "RiftAutoTrade",
    callback = function(v)
        BX.riftAutoTrade = v and true or false
        X.riftTradeAt = 0
        trace("rift: auto trade-in " .. (BX.riftAutoTrade and "ON" or "OFF"))
        BlyxoNote("rift-trade-toggle", "Auto trade-in " .. (BX.riftAutoTrade and "ON" or "OFF"), 2)
    end,
})

-- One line. Banner, how many of its pets you can grab right now, which ones,
-- and how long before it rotates.
-- THE LABEL ANSWERS ONE QUESTION: WHAT DO I STILL NEED?
--
-- It used to print three lists side by side -
--     Lava frog, Sabertooth Tiger, Lava Iguana  |  out: Lava frog  |  52m
-- - which is every pet the rift wants, every wanted pet on the map, and a
-- timer, with nothing saying which ones you already have. You had to diff two
-- lists in your head to learn the only thing that matters.
--
-- Now the title carries the score and the body carries the next action:
--     Riftborn  2/3
--     Need Lava Iguana  ·  on the map now
-- and when there is nothing left to get:
--     Riftborn  3/3
--     All pets ready  ·  new rift in 52m
--
-- Pets you already own are never listed. You cannot act on them.
function X.riftPaint()
    -- Two pcalls, deliberately. Sharing one means a build where SetTitle is
    -- missing takes the body down with it: the error aborts the function
    -- before Set is ever reached, and the line freezes on its old text with
    -- nothing logged. The body is the half that matters, so it stands alone.
    -- Only when the text actually changed. This ran every K.RIFT_POLL for the
    -- whole session and pushed the same two strings into Rayfield each time,
    -- which re-measures and re-lays-out the element on every write.
    local function set(body, title)
        if title and title ~= X.riftLastTitle then
            X.riftLastTitle = title
            pcall(function() X.rift.line.SetTitle(X.rift.line, title) end)
        end
        if body ~= X.riftLastBody then
            X.riftLastBody = body
            pcall(function() X.rift.line.Set(X.rift.line, body) end)
        end
    end

    local st = X.riftState()
    if not st then return set("Could not read the rift", "Rift") end
    if st.Unlocked == false then
        local need = tonumber(st.UnlockSpeedPower)
        return set(need and ("Unlocks at " .. formatNumber(need) .. " speed") or "Locked", "Rift")
    end

    local reqs = st.Requirements or {}
    local have, missing = X.riftOwned(reqs)
    local banner = tostring(st.BannerDisplayName or st.BannerId or "Rift")
    local mins = math.max(0, math.floor((st.SecondsUntilRotation or 0) / 60))

    -- Title: the banner and the score. nil means the roster could not be read,
    -- so the score is dropped rather than shown as 0.
    local title = have and ("%s  %d/%d"):format(banner, have, #reqs) or banner

    if have and #reqs > 0 and have >= #reqs then
        return set(("All pets ready  \u{B7}  new rift in %dm"):format(mins), title)
    end

    -- Which of the ones we still need are stealable right now. This is the
    -- whole point of the line: go and get that one.
    local onField = {}
    for _, pet in ipairs(X.riftOnField() or {}) do onField[pet] = true end

    local want = missing or reqs
    if #want == 0 then return set(("New rift in %dm"):format(mins), title) end

    local ready = {}
    for _, pet in ipairs(want) do
        if onField[pet] then ready[#ready + 1] = X.petName(pet) end
    end

    -- Names, not ids, everywhere you can read them.
    local wantNames = X.petNames(want)

    local body
    if #ready > 0 then
        body = ("Steal %s now"):format(table.concat(ready, ", "))
    elseif #want == 1 then
        body = ("Need %s  \u{B7}  not spawned"):format(wantNames[1])
    else
        body = ("Need %d: %s  \u{B7}  none spawned"):format(#want, table.concat(wantNames, ", "))
    end

    set(("%s  \u{B7}  %dm"):format(body, mins), title)
end

task.spawn(function()
    local lastReady, lastBanner, lastPity = nil, nil, nil
    local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
    while true do
        if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
        task.wait(K.RIFT_POLL)
        pcall(function()
            local st = X.riftState(true)
            if not st then return end

            -- Same narrowing as UI.refresh: riftState reads the game's own
            -- modules, so every Rayfield write after it on this thread was
            -- being refused. It is all inside a pcall, so the panel simply
            -- stopped updating and said nothing - the rift dropdown and the
            -- countdown have both been frozen since load. One frame fixes it.
            task.wait()

            X.riftPaint()

            local opts = X.riftOptions()
            local sig = table.concat(opts, "")
            if sig ~= X.rift.optSig then
                X.rift.optSig = sig
                pcall(function()
                    X.riftSuppress = true
                    X.rift.pick:Refresh(opts)
                    X.riftSuppress = false
                end)
            end

            -- Auto trade-in: at most every 5s, on its own thread (it reads
            -- game modules and invokes remotes), and silent until something
            -- actually happens.
            if BX.riftAutoTrade and not X.riftTrading
               and os.clock() - (X.riftTradeAt or 0) > 5 then
                X.riftTradeAt = os.clock()
                task.spawn(function()
                    local r = X.riftTryTrade()
                    if r == "traded" then
                        trace("rift: traded the 3 pets in - Rift Egg claimed")
                        BlyxoNote("rift-traded", "Rift: traded in - Rift Egg added to your eggs", 5)
                    elseif r == "revealed" then
                        trace("rift: finished a pending reveal")
                    elseif r then
                        trace("rift: trade-in " .. tostring(r))
                        BlyxoNote("rift-trade-fail", "Rift trade-in " .. tostring(r), 60)
                    end
                end)
            end

            local reqs = st.Requirements or {}
            local have = X.riftOwned(reqs)
            local ready = have and #reqs > 0 and have >= #reqs or false
            -- The owned count flickers, so "ready" flips on and off; the
            -- cooldown turns that into one note, not one per flip.
            if ready and not lastReady then BlyxoNote("rift-ready", "Rift: all pets ready", 120) end
            lastReady = ready

            if lastBanner and st.BannerId ~= lastBanner then
                BlyxoNote("rift-banner", "Rift: new banner " .. tostring(st.BannerDisplayName or st.BannerId), 30)
            end
            lastBanner = st.BannerId

            local pc, pt = st.PityCount, st.PityThreshold
            if pc and pt and pc >= pt - 5 and lastPity and pc > lastPity then
                BlyxoNote("rift-pity", ("Rift: pity %d/%d"):format(pc, pt), 60)
            end
            lastPity = pc
        end)
    end
end)

pcall(function()
    local net = RS.Packages:FindFirstChild("Networking")
    local ev = net and net:FindFirstChild("RE/Rift/BannerRotated")
    if ev then
        BlyxoTop.bannerRotated = ev.OnClientEvent:Connect(function()
            X.riftSnapAt = 0
            pcall(X.riftPaint)
        end)
    end
end)

---------- MISC ----------

BlyxoSplash.step("Building Misc", 0.9)
local MiscTab = Window:CreateTab({ name = "Misc" })

MiscTab:CreateSection({ name = "Look" })

-- ============================================================================
-- THEMES
-- ============================================================================
--
-- Rayfield resolves the `theme` you pass at CreateWindow through:
--
--     if typeof(H) == 'table' then return H
--     elseif typeof(H) == 'string' then g:FindFirstChild(string.lower(H)) ...
--
-- and then merges whatever comes back over the default palette. A TABLE is the
-- reliable half of that - a name has to match one of its internal modules and
-- there is no API to list them, so these are written out here instead of
-- guessed at. Only the keys that carry the look are overridden; everything
-- else falls through to the library's own default.
--
-- The window reads its theme once, when it is built. There is an internal
-- _refreshElementThemes() that re-walks every element, so the live swap is
-- attempted through that - and if the library ever drops it, the choice is
-- saved and comes up correctly next launch instead of silently doing nothing.
do
    -- THE FIRST VERSION ONLY REPAINTED THE BUTTONS, AND THAT IS ON ME.
    --
    -- I overrode four keys. The window carries FORTY-SEVEN, dumped from a live
    -- one, and the ones that actually change the look of the whole thing are
    -- the backgrounds - WindowColor is the window itself, TabColor and
    -- TabBackground the tab strip, ElementGradient every row, FieldBackground
    -- and StatBackground the inputs and readouts. Accent alone is a button
    -- colour, which is exactly what you saw.
    --
    -- Each palette below sets a full background family plus its accent, so the
    -- whole surface moves together.
    local function pal(bgTop, bgBottom, tab, element, field, accent, accentLight)
        -- NO LIGHT OUTLINES ON THE CONTROLS.
        --
        -- Every button, toggle and card used to be stroked in `accent`. On Mono
        -- that is 206,206,212 - a white ring round every element, which is
        -- what made the menu look busy. The edge is now the element colour
        -- nudged a little toward the accent: enough to separate a control from
        -- the panel behind it, not enough to read as an outline. Hover lifts
        -- it a bit further so there is still feedback. The accent stays where
        -- it carries meaning - slider fill, toggle on, the dropdown highlight.
        local edge = element:Lerp(accent, 0.1)
        local edgeHover = element:Lerp(accent, 0.3)
        local t = {
            WindowColor = ColorSequence.new(bgTop, bgBottom),

            -- LEAVE THE TINTS ALONE. This is why the tabs went invisible.
            --
            -- TabColor is not the tab's background - it is a TINT, and the
            -- library's default for it is 255,255,255. So are ContentColor,
            -- TitlingColor, ActionColor and ElementTextHoverColor. Dumped from
            -- a live window, every one of them is pure white.
            --
            -- I set TabColor to the dark panel colour, which multiplied the
            -- tab label down to near-black on a near-black strip. The strip's
            -- background is TabBackground; that is the one that takes a
            -- colour. These stay white so text is readable whatever the
            -- palette does behind it.
            TabColor = Color3.fromRGB(255, 255, 255),
            ContentColor = Color3.fromRGB(255, 255, 255),
            TitlingColor = Color3.fromRGB(255, 255, 255),
            ActionColor = Color3.fromRGB(255, 255, 255),
            ElementTextHoverColor = Color3.fromRGB(255, 255, 255),
            TabBackground = ColorSequence.new(tab, bgBottom),
            TabStroke = ColorSequence.new(edge, tab),
            ElementGradient = ColorSequence.new(element, element),
            ElementStroke = edge,
            ElementStrokeGradient = ColorSequence.new(edge, element),
            ElementStrokeHover = edgeHover,
            FieldBackground = field,
            FieldGlow = accent,
            StatBackground = field,
            SliderBackground = field,
            SliderBackgroundHover = element,
            SliderProgress = ColorSequence.new(accentLight, accent),
            SliderHandle = accentLight,
            SliderStroke = accent,
            AccentColor = accent,
            AccentStroke = accentLight,
            DropdownHighlight = accent,
            NeutralButton = element,
            NeutralButtonHover = field,
            NeutralButtonStroke = edge,
            ToggleTrack = field,
            ToggleKnobOff = Color3.fromRGB(224, 224, 232),
            SurfaceStroke = edgeHover,
            ShadowColor = bgBottom,
        }
        -- The raw colours, for the hub's own surfaces (the stats overlay)
        -- that Rayfield knows nothing about. Kept beside the palette rather
        -- than inside it, so ChangeTheme never sees an unknown key.
        BlyxoThemeRaw = BlyxoThemeRaw or {}
        BlyxoThemeRaw[t] = { bgTop = bgTop, bgBottom = bgBottom, element = element,
                             accent = accent, accentLight = accentLight }
        return t
    end

    -- EVERY THEME CHANGE ALSO REPAINTS THE HUB'S OWN SURFACES.
    --
    -- The stats overlay is drawn by us, not Rayfield, so ChangeTheme never
    -- touched it: switch to Midnight and the menu went blue while the overlay
    -- stayed Mono grey. BlyxoThemeCurrent holds the raw colours of whatever
    -- is applied (the stats block reads it when it builds), and
    -- BlyxoOnTheme, if the overlay has registered one, recolours it live.
    -- "Default" is Rayfield's own palette, matched by the CreateWindow theme.
    function BlyxoApplyThemeExtras(pick)
        BlyxoThemeCurrent = (pick and BlyxoThemeRaw and BlyxoThemeRaw[pick]) or {
            bgTop = Color3.fromRGB(20, 20, 20), bgBottom = Color3.fromRGB(12, 12, 12),
            element = Color3.fromRGB(30, 30, 30),
            accent = Color3.fromRGB(220, 220, 220), accentLight = Color3.fromRGB(255, 255, 255),
        }
        if type(BlyxoOnTheme) == "function" then pcall(BlyxoOnTheme, BlyxoThemeCurrent) end
    end

    local THEMES = {
        ["Default"] = nil,
        ["Midnight"] = pal(
            Color3.fromRGB(22, 26, 44), Color3.fromRGB(12, 14, 26),
            Color3.fromRGB(30, 36, 58), Color3.fromRGB(34, 40, 64),
            Color3.fromRGB(26, 31, 50),
            Color3.fromRGB(120, 140, 255), Color3.fromRGB(170, 186, 255)),
        ["Forest"] = pal(
            Color3.fromRGB(18, 34, 26), Color3.fromRGB(10, 20, 15),
            Color3.fromRGB(24, 46, 34), Color3.fromRGB(28, 52, 39),
            Color3.fromRGB(21, 40, 30),
            Color3.fromRGB(88, 224, 131), Color3.fromRGB(146, 244, 178)),
        ["Ember"] = pal(
            Color3.fromRGB(38, 22, 16), Color3.fromRGB(22, 12, 9),
            Color3.fromRGB(52, 30, 21), Color3.fromRGB(58, 34, 24),
            Color3.fromRGB(45, 26, 18),
            Color3.fromRGB(255, 138, 76), Color3.fromRGB(255, 186, 142)),
        ["Rose"] = pal(
            Color3.fromRGB(38, 20, 30), Color3.fromRGB(22, 11, 18),
            Color3.fromRGB(52, 28, 41), Color3.fromRGB(58, 31, 46),
            Color3.fromRGB(45, 24, 36),
            Color3.fromRGB(240, 118, 176), Color3.fromRGB(255, 174, 210)),
        ["Mono"] = pal(
            Color3.fromRGB(26, 26, 30), Color3.fromRGB(14, 14, 17),
            Color3.fromRGB(36, 36, 42), Color3.fromRGB(41, 41, 48),
            Color3.fromRGB(31, 31, 37),
            Color3.fromRGB(206, 206, 212), Color3.fromRGB(240, 240, 246)),
    }

    local names = {}
    for name in pairs(THEMES) do names[#names + 1] = name end
    table.sort(names)

    -- ONE PLACE THAT APPLIES A THEME, so the dropdown and a loaded profile
    -- cannot drift apart.
    local themeDrop
    function X.setTheme(name, quiet)
        local pick = THEMES[tostring(name)]
        if pick == nil and tostring(name) ~= "Default" then return false end
        BX.theme = tostring(name)
        pcall(function() Window:ChangeTheme(pick or "default") end)
        BlyxoApplyThemeExtras(pick)
        if themeDrop then
            pcall(function() themeDrop.Set(themeDrop, tostring(name), true) end)
        end
        if not quiet then trace("theme: " .. tostring(name)) end
        return true
    end

    themeDrop = MiscTab:CreateDropdown({
        name = "Theme",
        options = names,
        flag = "HubTheme",
        callback = function(v)
            local pick = THEMES[tostring(v)]
            BX.theme = tostring(v)

            -- USE ChangeTheme, NOT THE FIELDS.
            --
            -- Writing Window.theme[key] and calling _refreshElementThemes was
            -- the wrong door, and it produced exactly what you saw: only the
            -- control you hovered repainted. That method walks tabs->elements
            -- and nothing else, and the elements re-read their colours lazily
            -- on a state change - which is why hovering "fixed" one button.
            --
            -- Window:ChangeTheme(t) is the real entry point. It merges the
            -- table, then walks themeProperties - every instance property the
            -- library registered when it built the window, chrome included -
            -- and tweens each one to the new value, before refreshing the
            -- elements. That is the whole surface at once.
            local applied = false
            pcall(function()
                Window:ChangeTheme(pick or "default")
                applied = true
            end)
            BlyxoApplyThemeExtras(pick)
            trace("theme: " .. tostring(v) .. (applied and " applied" or " saved"))
            toast(applied and ("Theme: " .. tostring(v))
                or ("Theme saved - reopen the hub to see it"))
        end,
    })

    -- MONO ON BY DEFAULT.
    --
    -- Applied after the dropdown exists so the control shows the truth rather
    -- than sitting on "Default" while the window is clearly not. Deferred one
    -- frame because ChangeTheme walks every registered property on the window
    -- and there is no reason to do that while the rest of the tabs are still
    -- being built.
    task.defer(function()
        pcall(function()
            Window:ChangeTheme(THEMES.Mono)
            BlyxoApplyThemeExtras(THEMES.Mono)
            BX.theme = "Mono"
            if themeDrop then themeDrop.Set(themeDrop, "Mono", true) end
            trace("theme: Mono applied on load")
        end)
    end)
end

-- ============================================================================
-- BACKGROUND IMAGE
-- ============================================================================
--
-- There is no theme key for this - all 47 of them are colours, fonts and
-- corner radii - so it goes in as an ImageLabel behind the window's content
-- rather than through the theme system.
--
-- Finding the frame to sit behind: the library builds its own ScreenGui with a
-- GUID name, so it cannot be looked up by name. The biggest Frame in the
-- container that is not ours is the window, and that is stable enough. It is
-- all pcall'd - a wrong guess leaves the hub exactly as it was.
do
    local bgLabel

    -- THE WINDOW'S OWN FILL HAS TO GO, AND THIS IS WHY.
    --
    -- The ScreenGui runs ZIndexBehavior.Global, not Sibling. Under Global,
    -- ZIndex is compared across the WHOLE gui with no regard for hierarchy -
    -- so a child at ZIndex 0 renders UNDER its parent at ZIndex 1, rather than
    -- above it the way Sibling would.
    --
    -- The window frame is ZIndex 1 with BackgroundTransparency 0. So the image
    -- was loading correctly, sitting in the right place at the right size, and
    -- being painted over by the window's own fill every frame. Proved it by
    -- putting a solid red panel there instead - also invisible.
    --
    -- So the window's fill is switched off while an image is active and the
    -- image becomes the background. Every control in the window is ZIndex >= 1
    -- and still draws on top. The original value is remembered so clearing the
    -- id brings the theme's gradient straight back.
    local savedWindowBg

    local function restoreWindowFill()
        if BX.bgGuardConn then
            pcall(function() BX.bgGuardConn:Disconnect() end)
            BX.bgGuardConn = nil
        end
        if not (bgLabel and savedWindowBg) then return end
        pcall(function()
            local host = bgLabel.Parent
            if host then host.BackgroundTransparency = savedWindowBg end
        end)
        savedWindowBg = nil
    end

    -- One fixed fade. The input for it was one control too many for something
    -- nobody tunes twice.
    K.BG_FADE = 0.35

    local function applyBackground(id, fade)
        restoreWindowFill()
        pcall(function() if bgLabel then bgLabel:Destroy() end end)
        bgLabel = nil
        id = tostring(id or ""):gsub("%s", "")
        if id == "" then return true, "cleared" end
        if not id:match("^%d+$") then
            id = id:match("(%d+)") or ""
            if id == "" then return false, "that is not an image id" end
        end

        local ok, why = pcall(function()
            local parent = (gethui and gethui()) or game:GetService("CoreGui")
            -- THE OUTERMOST FRAME, NOT THE BIGGEST.
            --
            -- Picking the largest frame anywhere in the tree lands on an inner
            -- content panel, and every sibling panel then draws over the top
            -- of the image. Take the biggest frame that has no Frame ancestor:
            -- that is the window shell, and a ZIndex 0 child of it sits behind
            -- everything the library puts inside.
            local best, bestArea
            for _, g in ipairs(parent:GetChildren()) do
                if g:IsA("ScreenGui") and g.Name ~= "BlyxoSplash" then
                    for _, f in ipairs(g:GetDescendants()) do
                        if f:IsA("Frame") and f.Visible
                           and not f:FindFirstAncestorWhichIsA("Frame") then
                            local a = f.AbsoluteSize.X * f.AbsoluteSize.Y
                            if a > 40000 and (not bestArea or a > bestArea) then
                                best, bestArea = f, a
                            end
                        end
                    end
                end
            end
            assert(best, "could not find the hub window")

            local img = Instance.new("ImageLabel")
            img.Name = "BlyxoBackground"
            img.Size = UDim2.fromScale(1, 1)
            img.BackgroundTransparency = 1
            -- TWO WAYS TO ASK ROBLOX FOR AN IMAGE, AND ONLY ONE WORKS PER ID.
            -- Tested with 8508980536, the id you gave me:
            --     rbxassetid://8508980536                        never loads
            --     rbxthumb://type=Asset&id=8508980536&w=420&h=420   LOADS
            -- rbxassetid only serves assets uploaded as Images; most ids
            -- people copy are Decals, and those stay blank forever. The
            -- thumbnail endpoint renders either kind, so the loader below
            -- falls back to it on its own.
            img.Image = "rbxassetid://" .. id
            img.ScaleType = Enum.ScaleType.Crop
            img.ImageTransparency = math.clamp(tonumber(fade) or K.BG_FADE, 0, 1)
            -- Solid backing, so a faded image still sits on something dark
            -- rather than on whatever is behind the hub.
            img.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
            img.BackgroundTransparency = 0
            img.BorderSizePixel = 0
            img.ZIndex = 0
            img.Parent = best

            savedWindowBg = best.BackgroundTransparency
            best.BackgroundTransparency = 1
            local c = Instance.new("UICorner", img)
            c.CornerRadius = UDim.new(0, 12)
            bgLabel = img

            -- KEEP THE FILL OFF WHILE THE IMAGE IS UP.
            --
            -- Applied from an auto-loaded profile, the image landed while the
            -- window was still opening (and a theme tween was running), and
            -- the library then animated the window's fill back to solid - on
            -- top of the image: "applied", loaded, and invisible. A manual
            -- load a few seconds later worked because nothing was animating.
            -- So while an image is active, any change to the fill is put back
            -- to transparent, and what the library wanted is remembered, so
            -- clearing the image still restores the right fill.
            if BX.bgGuardConn then pcall(function() BX.bgGuardConn:Disconnect() end) end
            BX.bgGuardConn = best:GetPropertyChangedSignal("BackgroundTransparency"):Connect(function()
                if bgLabel == img and img.Parent == best and best.BackgroundTransparency ~= 1 then
                    savedWindowBg = best.BackgroundTransparency
                    best.BackgroundTransparency = 1
                end
            end)

            -- SAY SO WHEN ROBLOX WILL NOT SERVE IT.
            --
            -- A silent nothing is the worst answer here, and it is the usual
            -- one: paste a decal id, or an id you do not have access to, and
            -- the ImageLabel simply stays blank forever. IsLoaded tells us,
            -- so wait a moment and report instead of leaving you guessing.
            task.spawn(function()
                for _ = 1, 5 do
                    task.wait(0.2)
                    if img.Parent == nil then return end
                    if img.IsLoaded then trace("background: loaded directly") return end
                end
                if img.Parent == nil then return end

                img.Image = ("rbxthumb://type=Asset&id=%s&w=420&h=420"):format(id)
                for _ = 1, 25 do
                    task.wait(0.2)
                    if img.Parent == nil then return end
                    if img.IsLoaded then
                        trace("background: loaded through the thumbnail endpoint")
                        return
                    end
                end
                if img.Parent then
                    trace("background: id " .. id .. " would not load either way")
                    toast("Roblox will not serve that id as an image")
                end
            end)
        end)
        return ok, ok and "applied" or tostring(why)
    end

    -- WAIT FOR THE WINDOW. applyBackground needs the hub window on screen at
    -- full size to hang the image on, and an auto-loaded profile applies ~0.6s
    -- after load - while the window is still opening behind the splash:
    --     0.71s background: could not find the hub window
    --     0.76s config: auto-loaded cat          (theme applied, image not)
    -- So when the window is not there yet, keep trying for a few seconds. A
    -- newer request (another profile, typing a new id) cancels the old one.
    X.setBackground = function(id, fade)
        BX.bgRequest = (BX.bgRequest or 0) + 1
        local mine = BX.bgRequest
        local ok, why = applyBackground(id, fade)
        if not ok and tostring(why):find("could not find the hub window") then
            task.spawn(function()
                -- 30s, not 10: the menu now stays hidden until the loading
                -- card (with its Discord step) has closed.
                for _ = 1, 60 do
                    task.wait(0.5)
                    if BX.bgRequest ~= mine then return end
                    local ok2, why2 = applyBackground(id, fade)
                    if ok2 or not tostring(why2):find("could not find the hub window") then
                        trace("background: " .. tostring(why2) .. " (once the window was up)")
                        return
                    end
                end
                trace("background: gave up - the hub window never appeared")
            end)
            return true, "waiting for the window"
        end
        return ok, why
    end

    X.el = X.el or {}
    X.el.bgInput = MiscTab:CreateInput({
        name = "Background Image",
        description = "Paste a Roblox image id - empty clears it",
        placeholder = "0000000000",
        flag = "HubBackground",
        callback = function(v)
            BX.bgImage = tostring(v or "")
            -- Through X.setBackground, not applyBackground: a profile restores
            -- this input too, and that can land before the window is up.
            local ok, why = X.setBackground(v, BX.bgFade)
            trace("background: " .. tostring(why))
            if why ~= "waiting for the window" then
                toast(ok and ("Background " .. why) or ("Background failed - " .. why))
            end
        end,
    })

end

-- ============================================================================
-- FPS BOOST
-- ============================================================================
--
-- Everything here is a PROPERTY CHANGE that is written down first and put back
-- when you switch it off. Nothing is destroyed. That matters in this script
-- specifically: the steal loop reads egg models, nest markers and prompt parts
-- out of the workspace, and the usual "delete every decal and particle" boost
-- would take those with it and break the thing you are here to run.
--
-- Rendering only. Nothing below is visible to the server.
do
    local Lighting = game:GetService("Lighting")
    local saved = nil

    local function boost(on)
        if on then
            if saved then return end
            saved = { emitters = {}, lighting = {}, terrain = {} }
            pcall(function()
                saved.lighting.GlobalShadows = Lighting.GlobalShadows
                saved.lighting.FogEnd = Lighting.FogEnd
                saved.lighting.Brightness = Lighting.Brightness
                Lighting.GlobalShadows = false
                Lighting.FogEnd = 1e6
            end)
            pcall(function()
                local t = workspace:FindFirstChildOfClass("Terrain")
                if t then
                    saved.terrain.Decoration = t.Decoration
                    saved.terrain.WaterWaveSize = t.WaterWaveSize
                    saved.terrain.WaterReflectance = t.WaterReflectance
                    t.Decoration = false
                    t.WaterWaveSize = 0
                    t.WaterReflectance = 0
                end
            end)
            pcall(function()
                settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
            end)
            -- Particles, trails and the rest: disabled, remembered, never
            -- destroyed. Post-processing goes too - it is the single biggest
            -- cost on a phone.
            pcall(function()
                for _, d in ipairs(workspace:GetDescendants()) do
                    if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke")
                       or d:IsA("Fire") or d:IsA("Sparkles") or d:IsA("Beam") then
                        if d.Enabled then
                            saved.emitters[#saved.emitters + 1] = d
                            d.Enabled = false
                        end
                    end
                end
                for _, d in ipairs(Lighting:GetDescendants()) do
                    if d:IsA("PostEffect") and d.Enabled then
                        saved.emitters[#saved.emitters + 1] = d
                        d.Enabled = false
                    end
                end
            end)
            trace(("fps: on - %d effects off"):format(#saved.emitters))
            toast("FPS Boost ON")
        else
            if not saved then return end
            pcall(function()
                for k, v in pairs(saved.lighting) do Lighting[k] = v end
            end)
            pcall(function()
                local t = workspace:FindFirstChildOfClass("Terrain")
                if t then for k, v in pairs(saved.terrain) do t[k] = v end end
            end)
            pcall(function()
                for _, d in ipairs(saved.emitters) do
                    if d and d.Parent then d.Enabled = true end
                end
            end)
            trace("fps: off - put everything back")
            toast("FPS Boost OFF")
            saved = nil
        end
    end

    MiscTab:CreateToggle({
        name = "FPS Boost",
        description = "Turns off effects and shadows - nothing is deleted",
        value = true,
        flag = "FpsBoost",
        callback = function(v) pcall(boost, v and true or false) end,
    })

    -- ON BY DEFAULT, BUT NOT DURING LOAD.
    --
    -- The sweep walks the workspace once - 29,417 descendants, measured at
    -- 17ms - and load is already the most expensive moment in the session.
    -- Deferring it by a couple of seconds means the menu is up and usable
    -- first, and the hitch lands somewhere nobody notices.
    --
    -- It is also the single biggest thing that helps a phone, which is why it
    -- defaults on rather than waiting to be found in a tab.
    task.delay(2, function()
        if BX.fpsBoosted == nil then
            BX.fpsBoosted = true
            pcall(boost, true)
        end
    end)

    -- Remember the state so the shutdown below can put the world back.
    local realBoost = boost
    boost = function(on)
        BX.fpsBoosted = on and true or false
        return realBoost(on)
    end
    X.setFpsBoost = boost
end

-- ============================================================================
-- STATS OVERLAY
-- ============================================================================
--
-- Session time, FPS and ping in one small pill, dressed in the Mono palette
-- the hub loads with: the same dark gradient, the same light-to-dark stroke.
--
-- FPS is counted on RenderStepped, so it is what you actually SEE, and only a
-- number is incremented per frame - no closure, no table, no garbage. The text
-- is rewritten twice a second (once a second in lite mode) and the FPS figure
-- is eased, so it reads as a steady number instead of a flicker.
--
-- Ping is the same "Data Ping" the F9 console shows. GetNetworkPing is only the
-- fallback because it reports a different, smaller figure.
--
-- MOVING IT. Drag with mouse or finger; the pill follows with a short ease,
-- stays on screen, and remembers where you left it (as a fraction of the
-- screen, so it survives a rotate or a new resolution). Double-click or
-- double-tap puts it back at the top.
--
-- WHY THE MOUSE IS READ, NOT LISTENED TO. Dragging on PC did not work when the
-- pill moved on InputChanged events alone. The mouse is now polled with GetMouseLocation inside the same RenderStepped handler
-- that counts frames, and the release comes from InputEnded, so letting go
-- outside the pill still ends the drag. Touch keeps InputChanged, because a
-- finger has no "location" to poll - but only for the finger that grabbed it.
--
-- ICONS are Google's Material Icons (schedule, show_chart, wifi), the white
-- 96px PNGs from google/material-design-icons, downloaded once into
-- BlyxoHub/icons and loaded with getcustomasset. White means ImageColor3 can
-- tint them, which is how the wifi icon shows a bad ping. Where the executor
-- has no getcustomasset or GitHub is unreachable, simple drawn shapes stand in.
--
-- A FUNCTION, NOT A `do` BLOCK. The main chunk is near Luau's 200-register
-- ceiling, and every local in a `do` block counts against it while the block
-- runs ("Out of local registers when trying to allocate ELEMENT"). A function
-- gets its own 200, and reaches the outer locals it needs as upvalues.
;(function()
    local Stats = game:GetService("Stats")
    local TweenService = game:GetService("TweenService")
    local TextService = game:GetService("TextService")
    local HttpService = game:GetService("HttpService")
    local sessionT0 = os.clock()

    -- Mono, from THEMES above: bgTop, bgBottom, element, accent, accentLight.
    local BG_TOP   = Color3.fromRGB(26, 26, 30)
    local BG_BOT   = Color3.fromRGB(14, 14, 17)
    local ELEMENT  = Color3.fromRGB(41, 41, 48)
    local ACCENT   = Color3.fromRGB(206, 206, 212)
    local ICON     = Color3.fromRGB(240, 240, 246)
    local TEXT     = Color3.fromRGB(220, 220, 220)
    -- Colour only where it means something: a number that has gone bad.
    local WARN     = Color3.fromRGB(240, 190, 90)
    local BAD      = Color3.fromRGB(240, 110, 110)

    local FONT, TEXT_SIZE = Enum.Font.GothamMedium, 13
    local STROKE_T = 0.45
    local POS_FILE = "BlyxoHub_stats_pos.json"

    local ICON_DIR = "BlyxoHub/icons"
    local ICON_BASE = "https://raw.githubusercontent.com/google/material-design-icons/3.0.1/"
    local ICON_SRC = {
        clock = "action/2x_web/ic_schedule_white_48dp.png",
        pulse = "editor/2x_web/ic_show_chart_white_48dp.png",
        wifi  = "notification/2x_web/ic_wifi_white_48dp.png",
    }
    local iconAsset = {}   -- kind -> rbxasset:// once downloaded

    local gui, pill, scaler, stroke = nil, nil, nil, nil
    local conn, dragConn, endConn, vpConn = nil, nil, nil, nil
    local bars, labels, fadeList, iconBoxes = {}, {}, {}, {}
    local frames, shownFps = 0, nil
    local target, moving, dragging = nil, false, false
    local grabInput, grabStart, grabPos = nil, nil, nil
    local baseScale, closing = 1, false

    local function mk(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do o[k] = v end
        o.Parent = parent
        return o
    end

    local function tw(o, t, props, style)
        pcall(function()
            TweenService:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quint,
                Enum.EasingDirection.Out), props):Play()
        end)
    end

    ---------- icons ----------

    local function line(parent, x1, y1, x2, y2)
        local dx, dy = x2 - x1, y2 - y1
        mk("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2),
            Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) + 1, 1.5),
            Rotation = math.deg(math.atan2(dy, dx)),
            BackgroundColor3 = ICON, BorderSizePixel = 0,
        }, parent)
    end

    -- The stand-ins, only used when the Material PNG could not be loaded.
    local function drawIcon(box, kind)
        if kind == "clock" then
            local ring = mk("Frame", {
                Position = UDim2.fromOffset(2, 2), Size = UDim2.fromOffset(12, 12),
                BackgroundTransparency = 1,
            }, box)
            mk("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
            mk("UIStroke", { Color = ICON, Thickness = 1.5 }, ring)
            line(box, 8, 8, 8, 5)
            line(box, 8, 8, 10.5, 8)
        elseif kind == "pulse" then
            local p = { {1, 9}, {4.5, 9}, {6.5, 4}, {9.5, 13}, {11.5, 9}, {15, 9} }
            for i = 1, #p - 1 do line(box, p[i][1], p[i][2], p[i + 1][1], p[i + 1][2]) end
        else
            for i = 1, 3 do
                local h = 2 + i * 3.5
                bars[i] = mk("Frame", {
                    Position = UDim2.fromOffset(2 + (i - 1) * 4.5, 14 - h),
                    Size = UDim2.fromOffset(3, h),
                    BackgroundColor3 = ICON, BorderSizePixel = 0,
                }, box)
                mk("UICorner", { CornerRadius = UDim.new(0, 1) }, bars[i])
            end
        end
    end

    local function fillIcon(box, kind)
        for _, c in ipairs(box:GetChildren()) do c:Destroy() end
        if kind == "wifi" then bars = {} end
        if iconAsset[kind] then
            mk("ImageLabel", {
                Name = "Img", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
                Image = iconAsset[kind], ImageColor3 = ICON, ScaleType = Enum.ScaleType.Fit,
            }, box)
        else
            drawIcon(box, kind)
        end
    end

    local function icon(parent, kind)
        local box = mk("Frame", { Size = UDim2.fromOffset(16, 16), BackgroundTransparency = 1 }, parent)
        iconBoxes[kind] = box
        fillIcon(box, kind)
        return box
    end

    local collectFade -- defined below; the icon loader re-runs it after a swap

    -- Download once, then every later load is a local file read. Runs on its
    -- own thread so a slow GitHub never holds up the pill appearing.
    task.spawn(function()
        if type(getcustomasset) ~= "function" or type(writefile) ~= "function" then return end
        pcall(function()
            if not isfolder("BlyxoHub") then makefolder("BlyxoHub") end
            if not isfolder(ICON_DIR) then makefolder(ICON_DIR) end
        end)
        local got = 0
        for kind, src in pairs(ICON_SRC) do
            local path = ICON_DIR .. "/" .. kind .. ".png"
            local ok = pcall(function()
                local have = type(isfile) == "function" and isfile(path)
                    and #readfile(path) > 100
                if not have then
                    local png = game:HttpGet(ICON_BASE .. src)
                    assert(type(png) == "string" and png:sub(2, 4) == "PNG", "not a png")
                    writefile(path, png)
                end
                iconAsset[kind] = getcustomasset(path)
            end)
            if ok then got += 1 end
        end
        trace(("stats: %d/3 Material icons ready"):format(got))
        if gui and not closing and got > 0 then
            for kind, box in pairs(iconBoxes) do
                if box.Parent and iconAsset[kind] then fillIcon(box, kind) end
            end
            if collectFade then collectFade() end
        end
    end)

    ---------- cells ----------

    -- A fixed minimum width per value, measured from its widest usual text, so
    -- the pill does not twitch wider and narrower as the digits change.
    local function cell(parent, order, kind, widest)
        local c = mk("Frame", {
            LayoutOrder = order, AutomaticSize = Enum.AutomaticSize.X,
            Size = UDim2.fromOffset(0, 18), BackgroundTransparency = 1,
        }, parent)
        mk("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
        }, c)
        icon(c, kind).LayoutOrder = 1
        local w = 0
        pcall(function()
            w = TextService:GetTextSize(widest, TEXT_SIZE, FONT, Vector2.new(1000, 100)).X
        end)
        return mk("TextLabel", {
            LayoutOrder = 2, AutomaticSize = Enum.AutomaticSize.X,
            Size = UDim2.fromOffset(math.ceil(w), 18), BackgroundTransparency = 1,
            Font = FONT, TextSize = TEXT_SIZE, TextColor3 = TEXT,
            TextXAlignment = Enum.TextXAlignment.Left, Text = "--",
        }, c)
    end

    local function divider(parent, order)
        mk("Frame", {
            LayoutOrder = order, Size = UDim2.fromOffset(1, 14),
            BackgroundColor3 = ACCENT, BackgroundTransparency = 0.82,
            BorderSizePixel = 0, Name = "Divider",
        }, parent)
    end

    -- FOLLOW THE HUB THEME. The palette comes from BlyxoThemeCurrent (set by
    -- the Misc tab's theme code) and BlyxoOnTheme repaints a live pill:
    -- background and border gradients, dividers, icons. Text stays neutral
    -- white and the warning colours stay what they are - those carry meaning.
    local function takeTheme(raw)
        if type(raw) ~= "table" then return end
        BG_TOP, BG_BOT = raw.bgTop or BG_TOP, raw.bgBottom or BG_BOT
        ELEMENT, ACCENT = raw.element or ELEMENT, raw.accent or ACCENT
        ICON = raw.accentLight or ICON
    end
    takeTheme(BlyxoThemeCurrent)

    function BlyxoOnTheme(raw)
        takeTheme(raw)
        if not pill then return end
        for _, d in ipairs(pill:GetDescendants()) do
            if d:IsA("UIGradient") and d.Parent == pill then
                d.Color = ColorSequence.new(BG_TOP, BG_BOT)
            elseif d:IsA("UIGradient") and d.Parent == stroke then
                d.Color = ColorSequence.new(ACCENT, ELEMENT)
            elseif d.Name == "Divider" then
                tw(d, 0.4, { BackgroundColor3 = ACCENT })
            end
        end
        for kind, box in pairs(iconBoxes) do
            for _, d in ipairs(box:GetDescendants()) do
                if d:IsA("ImageLabel") then
                    -- The wifi icon may be showing a bad-ping tone; the next
                    -- ping update sets it right either way.
                    if kind ~= "wifi" or (d.ImageColor3 ~= WARN and d.ImageColor3 ~= BAD) then
                        tw(d, 0.4, { ImageColor3 = ICON })
                    end
                elseif d:IsA("UIStroke") then
                    tw(d, 0.4, { Color = ICON })
                elseif d:IsA("Frame") and d.BackgroundTransparency < 1 then
                    tw(d, 0.4, { BackgroundColor3 = ICON })
                end
            end
        end
    end

    local function clock(s)
        s = math.floor(s)
        local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
        if h > 0 then return ("%d:%02d:%02d"):format(h, m, s % 60) end
        return ("%02d:%02d"):format(m, s % 60)
    end

    local function readPing()
        local ok, v = pcall(function()
            return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        if ok and type(v) == "number" and v > 0 then return v end
        ok, v = pcall(function() return LocalPlayer:GetNetworkPing() * 1000 end)
        return (ok and type(v) == "number") and v or nil
    end

    local function paint(obj, prop, color)
        if obj and obj[prop] ~= color then tw(obj, 0.35, { [prop] = color }) end
    end

    -- NUMBERS COUNT TO THEIR NEW VALUE instead of jumping: three steps over
    -- ~0.16s, twice a second at most. A change under 1 just sets the text,
    -- and an unchanged number writes nothing at all.
    local shownNum = {}
    local function countTo(label, key, to, fmt)
        if not label then return end
        local from = shownNum[key]
        shownNum[key] = to
        local final = fmt:format(math.floor(to + 0.5))
        if not from or math.abs(to - from) < 1 or liteMode then
            if label.Text ~= final then label.Text = final end
            return
        end
        task.spawn(function()
            for i = 1, 3 do
                if not label.Parent or shownNum[key] ~= to then return end
                label.Text = fmt:format(math.floor(from + (to - from) * (i / 3) + 0.5))
                if i < 3 then task.wait(0.08) end
            end
        end)
    end

    ---------- position ----------

    -- PC gets the big pill (36px tall, like a normal HUD); phones a smaller
    -- one; a small viewport (phone in landscape, tiny window) smaller still.
    -- TOUCH DEVICES SIZE BY SCREEN, NOT BY BEING TOUCH.
    --
    -- This was "touch = 0.85x", which put a tablet - a PC-sized screen - on
    -- the phone size: "on tablet it is a bit small". For touch the short side
    -- of the screen decides now: a phone (short side ~360-430) lands at
    -- ~0.8x as before, a tablet (~740-1030) at 1.2-1.25x, the same as a PC.
    local function pickScale()
        local vp = gui and gui.AbsoluteSize or Vector2.new(1000, 1000)
        local touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
        if not touch then return 1.2 end
        local short = math.min(vp.X, vp.Y)
        if short < 10 then return 0.85 end
        return math.clamp(short / 620, 0.78, 1.25)
    end

    local function defaultPos()
        local vy = gui and gui.AbsoluteSize.Y or 0
        return UDim2.fromScale(0.5, vy > 0 and (8 / vy) or 0.01)
    end

    local function clampPos(p)
        local vp, sz = gui.AbsoluteSize, pill.AbsoluteSize
        if vp.X < 1 or vp.Y < 1 then return p end
        local hx, hy = (sz.X / 2 + 4) / vp.X, (sz.Y + 4) / vp.Y
        local top = 4 / vp.Y
        return UDim2.fromScale(math.clamp(p.X.Scale, math.min(hx, 0.5), math.max(1 - hx, 0.5)),
                               math.clamp(p.Y.Scale, top, math.max(1 - hy, top)))
    end

    local function loadPos()
        local ok, t = pcall(function() return HttpService:JSONDecode(readfile(POS_FILE)) end)
        if ok and type(t) == "table" and tonumber(t.x) and tonumber(t.y) then
            return UDim2.fromScale(tonumber(t.x), tonumber(t.y))
        end
        return nil
    end

    local function savePos(p)
        if type(writefile) ~= "function" or not p then return end
        pcall(writefile, POS_FILE, HttpService:JSONEncode({ x = p.X.Scale, y = p.Y.Scale }))
    end

    local function moveTo(p)
        target = clampPos(p)
        moving = true
    end

    -- Screen point -> new target, relative to where the grab started.
    local function dragTo(at)
        if not gui or not grabStart then return end
        local vp = gui.AbsoluteSize
        if vp.X < 1 or vp.Y < 1 then return end
        local dx, dy = at.X - grabStart.X, at.Y - grabStart.Y
        moveTo(UDim2.fromScale(grabPos.X.Scale + dx / vp.X, grabPos.Y.Scale + dy / vp.Y))
    end

    ---------- fade ----------

    -- Every transparency the pill owns is written down at its resting value,
    -- so fading in and out is one loop instead of a CanvasGroup (which renders
    -- to a texture and softens the text).
    collectFade = function()
        fadeList = {}
        if not pill then return end
        local function add(o, prop) fadeList[#fadeList + 1] = { o, prop, o[prop] } end
        add(pill, "BackgroundTransparency")
        for _, d in ipairs(pill:GetDescendants()) do
            if d:IsA("TextLabel") then add(d, "TextTransparency")
            elseif d:IsA("ImageLabel") then add(d, "ImageTransparency")
            elseif d:IsA("UIStroke") then add(d, "Transparency")
            elseif d:IsA("Frame") and d.BackgroundTransparency < 1 then add(d, "BackgroundTransparency")
            end
        end
    end

    -- `fresh` starts from fully hidden; without it (turning round mid
    -- fade-out) the tween picks up from wherever the pill already is.
    local function fade(visible, t, fresh)
        for _, f in ipairs(fadeList) do
            if f[1].Parent then
                if fresh then f[1][f[2]] = 1 end
                if visible and fresh and f[1].Name == "Divider" then
                    -- Separators arrive a beat after the content they divide.
                    local o, p, v = f[1], f[2], f[3]
                    task.delay(0.15, function()
                        if o.Parent and not closing then tw(o, t, { [p] = v }) end
                    end)
                else
                    tw(f[1], t, { [f[2]] = visible and f[3] or 1 })
                end
            end
        end
        if visible then
            if fresh then scaler.Scale = baseScale * 0.9 end
            tw(scaler, t, { Scale = baseScale }, Enum.EasingStyle.Back)
        else
            tw(scaler, t, { Scale = baseScale * 0.9 })
        end
    end

    ---------- build ----------

    local function release()
        if not dragging then return end
        dragging, grabInput = false, nil
        if scaler then tw(scaler, 0.3, { Scale = baseScale }) end
        if stroke then tw(stroke, 0.3, { Transparency = STROKE_T }) end
        savePos(target)
    end

    local function build()
        local parent = (gethui and gethui()) or game:GetService("CoreGui")
        local old = parent:FindFirstChild("BlyxoStats")
        if old then old:Destroy() end

        gui = mk("ScreenGui", {
            Name = "BlyxoStats", DisplayOrder = 999990, ResetOnSpawn = false,
            ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        }, parent)

        -- A TextButton, not a Frame: a button is guaranteed to receive the
        -- click, and it sinks it, so grabbing the pill never also clicks the
        -- game behind it.
        pill = mk("TextButton", {
            AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.01),
            -- Taller on touch screens: a finger needs more to grab than a
            -- cursor, and this is the drag handle. 36 x 0.85 scale ~ 31px.
            AutomaticSize = Enum.AutomaticSize.X,
            Size = UDim2.fromOffset(0, (UserInputService.TouchEnabled
                and not UserInputService.KeyboardEnabled) and 36 or 30),
            BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.06,
            BorderSizePixel = 0, Active = true, AutoButtonColor = false,
            Text = "", Selectable = false,
        }, gui)
        mk("UICorner", { CornerRadius = UDim.new(0, 9) }, pill)
        mk("UIGradient", { Color = ColorSequence.new(BG_TOP, BG_BOT), Rotation = 90 }, pill)
        stroke = mk("UIStroke", {
            Color = Color3.new(1, 1, 1), Transparency = STROKE_T, Thickness = 1,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }, pill)
        mk("UIGradient", { Color = ColorSequence.new(ACCENT, ELEMENT), Rotation = 90 }, stroke)
        mk("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, pill)
        mk("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder,
        }, pill)
        baseScale = pickScale()
        scaler = mk("UIScale", { Scale = baseScale }, pill)

        labels.time = cell(pill, 1, "clock", "00:00")
        divider(pill, 2)
        labels.fps = cell(pill, 3, "pulse", "000 FPS")
        divider(pill, 4)
        labels.ping = cell(pill, 5, "wifi", "000 ms")

        -- Place it before the first frame so it does not glide in from 0,0.
        target = clampPos(loadPos() or defaultPos())
        pill.Position = target

        -- Rotating a phone or resizing the window: rescale, then pull the
        -- pill back on screen if the edge moved past it.
        vpConn = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
            baseScale = pickScale()
            if scaler and not dragging then scaler.Scale = baseScale end
            if target then moveTo(target) end
        end)

        local lastTap = 0
        pill.InputBegan:Connect(function(inp)
            local kind = inp.UserInputType
            if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end

            local now = os.clock()
            if now - lastTap < 0.3 then
                lastTap = 0
                release()
                moveTo(defaultPos())
                savePos(target)
                return
            end
            lastTap = now

            dragging, grabInput, grabPos = true, inp, target or pill.Position
            -- Mouse is measured in GetMouseLocation's space from the start, so
            -- the grab point and every later poll agree about the top bar.
            grabStart = (kind == Enum.UserInputType.MouseButton1)
                and UserInputService:GetMouseLocation() or inp.Position
            tw(scaler, 0.2, { Scale = baseScale * 1.05 }, Enum.EasingStyle.Back)
            tw(stroke, 0.2, { Transparency = 0.1 })
        end)

        -- Touch only. The mouse is polled in the RenderStepped handler.
        dragConn = UserInputService.InputChanged:Connect(function(inp)
            if dragging and grabInput and inp == grabInput
               and inp.UserInputType == Enum.UserInputType.Touch then
                dragTo(inp.Position)
            end
        end)

        endConn = UserInputService.InputEnded:Connect(function(inp)
            if not dragging or not grabInput then return end
            if inp == grabInput or (inp.UserInputType == Enum.UserInputType.MouseButton1
               and grabInput.UserInputType == Enum.UserInputType.MouseButton1) then
                release()
            end
        end)

        collectFade()
    end

    local function teardown()
        for _, c in ipairs({ conn, dragConn, endConn, vpConn }) do
            pcall(function() c:Disconnect() end)
        end
        conn, dragConn, endConn, vpConn = nil, nil, nil, nil
        if gui then pcall(function() gui:Destroy() end) end
        gui, pill, scaler, stroke = nil, nil, nil, nil
        bars, labels, fadeList, iconBoxes = {}, {}, {}, {}
        dragging, moving, closing, shownFps, grabInput = false, false, false, nil, nil
        shownNum = {}
    end

    local function show(on)
        if not on then
            if not gui or closing then return end
            closing = true
            release()
            fade(false, 0.22)
            local g = gui
            task.delay(0.25, function()
                if gui == g and closing then teardown() end
            end)
            return
        end
        if gui then
            -- Switched back on mid fade-out: turn round instead of rebuilding.
            if closing then closing = false fade(true, 0.3) end
            return
        end

        local ok, why = pcall(build)
        if not ok then
            trace("stats: could not build - " .. tostring(why))
            teardown()
            return
        end
        -- ENTRANCE: hidden now, animated on the first SMOOTH frame.
        --
        -- The pill appears during load, when single frames can take over half
        -- a second (measured: 0.62s on the frame after a script starts). A
        -- 0.35s tween that starts inside a frame like that is finished before
        -- it is ever drawn - the fade, the pop and the slide all just snapped.
        -- So: start fully hidden and 12px high, wait (at most 10 frames) for
        -- a frame under 50ms, then fade in and let the drag ease slide it
        -- down into place.
        for _, f in ipairs(fadeList) do
            if f[1].Parent then f[1][f[2]] = 1 end
        end
        scaler.Scale = baseScale * 0.9
        pcall(function()
            local vy = math.max(gui.AbsoluteSize.Y, 1)
            pill.Position = UDim2.fromScale(target.X.Scale, target.Y.Scale - 12 / vy)
        end)
        local entering = gui
        task.spawn(function()
            for _ = 1, 10 do
                if RunService.RenderStepped:Wait() < 0.05 then break end
            end
            if gui ~= entering or closing then return end
            fade(true, 0.35, true)
            moving = true
        end)
        -- The pill's width is only known once the layout has run, so clamp
        -- the saved spot again a moment later.
        task.delay(0.1, function() if pill and target then moveTo(target) end end)

        frames = 0
        -- One handler does all three per-frame jobs: count the frame, poll the
        -- mouse while dragging, and ease the pill toward its target. The ease
        -- is exponential in dt, so it feels the same at 30fps as at 144.
        conn = RunService.RenderStepped:Connect(function(dt)
            frames += 1
            if dragging and grabInput
               and grabInput.UserInputType == Enum.UserInputType.MouseButton1 then
                dragTo(UserInputService:GetMouseLocation())
            end
            if moving and target and pill then
                -- dt capped at 1/30s: one long frame must not make the ease
                -- jump the whole way in a single step.
                local p = pill.Position:Lerp(target, 1 - math.exp(-math.min(dt, 1 / 30) * 20))
                if math.abs(p.X.Scale - target.X.Scale) < 1e-4
                   and math.abs(p.Y.Scale - target.Y.Scale) < 1e-4 then
                    p = target
                    if not dragging then moving = false end
                end
                pill.Position = p
            end
        end)

        local myGui = gui
        local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
        task.spawn(function()
            local last = os.clock()
            while gui == myGui and myGui.Parent do
                task.wait(BX.lite and 1 or 0.5)
                if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then
                    teardown()
                    return
                end
                if gui ~= myGui then return end

                local now = os.clock()
                local fps = frames / math.max(now - last, 0.001)
                frames, last = 0, now
                shownFps = shownFps and (shownFps + (fps - shownFps) * 0.45) or fps

                labels.time.Text = clock(now - sessionT0)
                countTo(labels.fps, "fps", shownFps, "%d FPS")
                paint(labels.fps, "TextColor3", (shownFps < 25 and BAD) or (shownFps < 50 and WARN) or TEXT)

                local ms = readPing()
                if ms then
                    countTo(labels.ping, "ping", ms, "%d ms")
                    local tone = (ms > 250 and BAD) or (ms > 150 and WARN) or nil
                    paint(labels.ping, "TextColor3", tone or TEXT)
                    if not closing then
                        -- The wifi icon takes the same tone as the number.
                        local img = iconBoxes.wifi and iconBoxes.wifi:FindFirstChild("Img")
                        if img then paint(img, "ImageColor3", tone or ICON) end
                        -- Drawn stand-in: light as many bars as the ping deserves.
                        local lit = (ms > 250 and 1) or (ms > 150 and 2) or 3
                        for i, b in ipairs(bars) do
                            local want = i <= lit and 0 or 0.7
                            if b.Parent and b.BackgroundTransparency ~= want then
                                tw(b, 0.3, { BackgroundTransparency = want })
                            end
                        end
                    end
                else
                    labels.ping.Text = "-- ms"
                end
            end
        end)
    end

    X.el = X.el or {}
    X.el.statsHud = MiscTab:CreateToggle({
        name = "Stats Overlay",
        description = "Session time, FPS and ping - drag to move, double-click to reset",
        value = true,
        flag = "StatsHud",
        callback = function(v) show(v and true or false) end,
    })

    -- Same reasoning as the boost: on by default, but after the menu is up.
    task.delay(2, function()
        if BX.statsHudSet == nil then show(true) end
    end)
    local realShow = show
    show = function(on)
        BX.statsHudSet = true
        return realShow(on)
    end
    X.setStatsHud = show
end)()

MiscTab:CreateSection({ name = "Servers" })

function X.setClip(text)
    for _, fn in pairs({ setclipboard, toclipboard, set_clipboard }) do
        if type(fn) == "function" then
            local ok = pcall(fn, text)
            if ok then return true end
        end
    end
    return false
end

MiscTab:CreateButton({
    name = "Copy Job ID",
    callback = function()
        local id = tostring(game.JobId)
        if id == "" then
            toast("No Job ID (Studio?)")
            return
        end
        if X.setClip(id) then
            toast("Job ID copied")
        else
            toast("No clipboard function - see console")
        end
        trace("jobid: " .. id)
        print("[BLYXO] JobId: " .. id)
    end,
})

-- Roblox JobIds are GUIDs: 8-4-4-4-12 hex.
function X.looksLikeJobId(v)
    return typeof(v) == "string"
        and v:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x") ~= nil
end

MiscTab:CreateInput({
    name = "Join Job ID",
    description = "Paste an ID to join that server",
    placeholder = "00000000-0000-0000-0000-000000000000",
    flag = "JoinJobId",
    callback = function(v)
        v = tostring(v or ""):gsub("%s", "")
        if v == "" then return end

        if not X.looksLikeJobId(v) then
            toast("That is not a Job ID")
            trace("jobid: rejected " .. v)
            return
        end
        if v == tostring(game.JobId) then
            toast("You are already in that server")
            return
        end

        toast("Joining server...")
        trace("jobid: joining " .. v)
        task.spawn(function()
            local ok, err = pcall(function()
                game:GetService("TeleportService")
                    :TeleportToPlaceInstance(game.PlaceId, v, LocalPlayer)
            end)
            if not ok then
                trace("jobid: teleport failed - " .. tostring(err))
                toast("Join failed - server may be full or gone")
            end
        end)
    end,
})

-- Server hop: ask Roblox for public servers and pick one that is not this one
-- and has room. Needs HttpGet, which every executor provides.
-- THIS GAME USES 7-PLAYER SERVERS. Measured live: Players.MaxPlayers = 7, and
--      listed" fetches 1.9s apart, each with its own try 1/2/3 counter - and
--   2. A 429 STORM. games.roblox.com rate limits hard: measured, a THIRD list
--      of ~25 consecutive 429s about 0.13s apart. The list is now cached and
--      strategy - it burned its whole budget on five entries and gave up with
-- JOIN PRIVATE SERVER.
--
-- What it actually does, said plainly: hops to the emptiest PUBLIC server it
-- can find. Roblox never lists a zero-player server - measured, 200 listed and
-- every one of them at 1 - so "private" here means "as close to alone as the
-- server list allows", which in a 7-slot game is usually you and one other.
-- There is no way for a client to create a real private server: ReserveServer
-- answers "can only be called by the server", and this game's own
-- createPrivateServer / reserveServer Cmdr commands answer "You do not have
-- permission to run this function".
--
-- Shares the fetch with Server Hop above so the 20s cache and the 429 backoff
-- apply here too - games.roblox.com rate limits hard, and a second copy of the
-- fetch would just earn its own 429s.
MiscTab:CreateButton({
    name = "Join Private Server",
    description = "Hops to the emptiest server it can find",
    callback = function()
        if BX.hopping then
            toast("Already looking for a server")
            return
        end
        -- Teleporting mid-carry drops the egg; the server holds it against
        -- this instance.
        if heldEggUid then
            toast("Carrying an egg - bank it first")
            return
        end
        BX.hopping = true

        task.spawn(function()
            local TS = game:GetService("TeleportService")
            local HttpService = game:GetService("HttpService")
            local function finish(msg, isError)
                BX.hopping = false
                if msg then
                    trace("private: " .. msg)
                    if isError then toast(msg) end
                end
            end

            toast("Finding an empty server...")

            local list = BX.hopList
            if not list or (os.clock() - (BX.hopListAt or 0)) > 20 then
                local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100")
                    :format(game.PlaceId)
                local ok, body = pcall(function() return game:HttpGet(url) end)
                if not ok then
                    finish(tostring(body):find("429")
                        and "Roblox is rate limiting the server list - wait a few seconds"
                        or "Could not reach the server list", true)
                    return
                end
                local decoded
                if not pcall(function() decoded = HttpService:JSONDecode(body) end)
                   or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
                    finish("Server list unreadable", true)
                    return
                end
                list, BX.hopList, BX.hopListAt = decoded.data, decoded.data, os.clock()
            end

            -- Lowest headcount available. A missing "playing" field means the
            -- server is EMPTY - Roblox omits it rather than sending 0 - so
            -- `tonumber(...) or 0` is what finds the good ones. Testing it as
            -- a number threw them away.
            local best, pool = math.huge, {}
            for _, srv in ipairs(list) do
                if type(srv) == "table" and srv.id ~= game.JobId then
                    local n = tonumber(srv.playing) or 0
                    if n < (tonumber(srv.maxPlayers) or 7) then
                        -- elseif, not a second if: the first match would
                        -- otherwise seed the pool AND be appended to it, so
                        -- it got two entries and twice the odds.
                        if n < best then
                            best, pool = n, { srv.id }
                        elseif n == best then
                            pool[#pool + 1] = srv.id
                        end
                    end
                end
            end

            if #pool == 0 then
                finish("No server with room right now - try again", true)
                return
            end

            -- Random among the ties. Picking the first would send everyone
            -- running this to the same server, which is the one way to make
            -- the counts worse.
            local pick = pool[math.random(1, #pool)]
            trace(("private: %d server(s) at %d player(s) - joining %s")
                :format(#pool, best, tostring(pick)))
            toast(best <= 1 and "Joining an empty server" or ("Joining a %d-player server"):format(best))

            local okTp, err = pcall(function()
                TS:TeleportToPlaceInstance(game.PlaceId, pick, LocalPlayer)
            end)
            if not okTp then
                finish("Join failed: " .. tostring(err), true)
                return
            end
            finish()
        end)
    end,
})

MiscTab:CreateButton({
    name = "Server Hop",
    callback = function()
        -- One hopper at a time. Without this every click starts another.
        if BX.hopping then
            toast("Already looking for a server")
            return
        end
        BX.hopping = true

        task.spawn(function()
            local TS = game:GetService("TeleportService")
            local HttpService = game:GetService("HttpService")
            local conn

            -- Single exit point, so the guard and the connection cannot leak
            -- no matter which branch finishes the hop.
            local function finish(msg, isError)
                if conn then pcall(function() conn:Disconnect() end) conn = nil end
                BX.hopping = false
                if msg then
                    trace("hop: " .. msg)
                    if isError then toast(msg) end
                end
            end

            toast("Finding a server...")

            -- Cached briefly. Repeated clicks used to refetch every time and
            -- that is exactly what earned the 429s.
            local list = BX.hopList
            if not list or (os.clock() - (BX.hopListAt or 0)) > 20 then
                local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100")
                    :format(game.PlaceId)
                local ok, body = pcall(function() return game:HttpGet(url) end)
                if not ok then
                    local why = tostring(body)
                    if why:find("429") then
                        finish("Roblox is rate limiting the server list - wait a few seconds", true)
                    else
                        finish("Could not reach the server list", true)
                    end
                    return
                end
                local decoded
                if not pcall(function() decoded = HttpService:JSONDecode(body) end)
                   or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
                    finish("Server list unreadable", true)
                    return
                end
                list = decoded.data
                BX.hopList = list
                BX.hopListAt = os.clock()
            else
                trace("hop: reusing the cached server list")
            end

            local candidates = {}
            for _, srv in ipairs(list) do
                if type(srv) == "table" and srv.id ~= game.JobId
                   and type(srv.playing) == "number" and type(srv.maxPlayers) == "number"
                   and srv.playing < srv.maxPlayers then
                    candidates[#candidates + 1] = srv
                end
            end

            trace(("hop: %d candidates from %d listed"):format(#candidates, #list))
            if #candidates == 0 then
                if #list == 0 then
                    finish("Server list came back empty - try again in a moment", true)
                else
                    finish(("All %d listed servers are full"):format(#list), true)
                end
                return
            end

            table.sort(candidates, function(a, b) return a.playing > b.playing end)
            local pool = math.min(#candidates, 40)
            local budget = math.min(12, #candidates)

            local failReason
            conn = TS.TeleportInitFailed:Connect(function(_, result, msg)
                failReason = tostring(result) .. (msg and (" - " .. tostring(msg)) or "")
            end)

            toast("Hopping...")
            local tried, fullCount = 0, 0
            for _ = 1, budget do
                local idx = math.random(1, math.min(pool, #candidates))
                local chosen = table.remove(candidates, idx)
                if not chosen then break end
                tried += 1
                failReason = nil

                trace(("hop: try %d/%d - %s (%d/%d players)")
                    :format(tried, budget, tostring(chosen.id), chosen.playing, chosen.maxPlayers))

                local okTp, err = pcall(function()
                    TS:TeleportToPlaceInstance(game.PlaceId, chosen.id, LocalPlayer)
                end)
                if not okTp then
                    trace("hop: call threw - " .. tostring(err))
                    failReason = failReason or tostring(err)
                else
                    -- TeleportToPlaceInstance returns immediately and almost
                    -- never throws; the real answer arrives asynchronously on
                    local waited = 0
                    while waited < 5 and not failReason do
                        task.wait(0.2)
                        waited += 0.2
                    end
                    if not failReason then
                        trace("hop: teleport accepted, leaving")
                        finish()
                        return
                    end
                end

                if tostring(failReason):find("GameFull") then fullCount += 1 end
                trace(("hop: %s rejected - %s"):format(tostring(chosen.id), tostring(failReason)))
                if #candidates == 0 then break end

                -- Flood means Roblox is rate limiting the teleport itself;
                -- hammering it guarantees the next one fails too. A full server
                -- is just a stale cache entry, so move on quickly.
                task.wait(tostring(failReason):find("Flood") and 3 or 0.5)
            end

            -- The list we hold is clearly stale if everything came back full,
            -- so drop it and let the next click fetch a fresh one.
            if fullCount > 0 then
                BX.hopList = nil
                BX.hopListAt = nil
            end

            -- LAST RESORT: let Roblox pick the server.
            --
            -- gives up control of WHICH server, which is why it is the fallback
            trace(("hop: %d instance hops all failed, falling back to matchmaking"):format(tried))
            toast("No listed server accepted us - letting Roblox pick")

            failReason = nil
            local okFb, errFb = pcall(function()
                TS:Teleport(game.PlaceId, LocalPlayer)
            end)
            if okFb then
                local waited = 0
                while waited < 6 and not failReason do
                    task.wait(0.25)
                    waited += 0.25
                end
                if not failReason then
                    trace("hop: matchmaking teleport accepted, leaving")
                    finish()
                    return
                end
            else
                failReason = failReason or tostring(errFb)
            end

            local summary
            if fullCount >= tried then
                summary = ("All %d servers filled before we arrived - 7-slot servers, try again"):format(tried)
            else
                summary = ("Hop failed after %d tries: %s"):format(tried, tostring(failReason or "unknown"))
            end
            finish(summary, true)
        end)
    end,
})

trace("ui: Event + Misc tabs built")


X.rfCache = {}

function X.http()
    return game:GetService("HttpService")
end

-- deepFind polls, so a miss costs its whole timeout. Cache both outcomes:
-- false means "looked, not there", which is as worth remembering as a hit.
function X.remote(name, timeout)
    local hit = X.rfCache[name]
    if hit ~= nil then return hit or nil end
    local found = deepFind(net, name, timeout or 5)
    X.rfCache[name] = found or false
    return found
end

-- (ok, err, payload) is the shape every Ask* remote in this game returns. The
-- game's own callers destructure exactly these three - see Index._claimAll.
function X.ask(name, ...)
    local args = table.pack(...)
    return BX.offthread(function()
        local rf = X.remote(name)
        if not rf then return { ok = false, err = "remote not found: " .. name } end
        local called, a, b, c = pcall(function()
            return rf:InvokeServer(table.unpack(args, 1, args.n))
        end)
        if not called then return { ok = false, err = tostring(a) } end
        return { ok = a ~= false, err = b, payload = c, raw = a }
    end, 20)
end

-- Element setters vary by build and by element type. Try the documented
-- signature first, then the bare one. A profile that cannot repaint one widget
-- must not abort the rest of the load, so every path is pcall'd.
function X.setWidget(el, value)
    if not el then return false end
    if type(el.Set) ~= "function" then return false end
    if pcall(el.Set, el, value, true) then return true end
    return (pcall(el.Set, el, value))
end

-- Not every Rayfield build ships a text-only element. Probe once and fall back
-- to nil rather than assuming - a missing builder aborts the whole chunk.
function X.label(tab, text)
    for _, builder in ipairs({ "CreateParagraph", "CreateLabel" }) do
        if type(tab[builder]) == "function" then
            local ok, el = pcall(tab[builder], tab, { name = text, title = text, content = text })
            if ok and el then return el end
        end
    end
    return nil
end

function X.setLabel(el, text)
    if not el then return end
    for _, setter in ipairs({ "Set", "SetTitle", "SetText" }) do
        if type(el[setter]) == "function" then
            if pcall(el[setter], el, text) then return end
        end
    end
end




--=====================================================================



X.CFG_DIR = "BlyxoHub"

function X.cfgPath(name)
    return X.CFG_DIR .. "/profile_" .. tostring(name) .. ".json"
end

function X.cfgReady()
    if type(writefile) ~= "function" then return false end
    if type(isfolder) == "function" and type(makefolder) == "function"
       and not isfolder(X.CFG_DIR) then
        pcall(makefolder, X.CFG_DIR)
    end
    return true
end

function X.settings()
    -- THEME AND BACKGROUND BELONG IN HERE TOO.
    --
    -- They were never saved, so a profile could not carry them and loading one
    -- left whatever the hub happened to be showing - which reads exactly like
    -- the load wiped them. Two more fields, and a profile now describes how
    -- the hub looks as well as how it moves.
    -- EVERY SWITCH IN EVERY TAB, not the three I happened to think of.
    --
    -- A profile used to hold moveSpeed and stealDelay. Nothing from Misc,
    -- nothing from Farm, none of the toggles - so saving a profile and loading
    -- it back changed almost nothing, which is indistinguishable from it not
    -- working.
    --
    -- Rayfield already keeps every control that has a `flag` in Window.controls,
    -- keyed by that flag, each with a .value and a working
    -- Set(self, value, skipCallback). Verified on all four kinds this hub uses
    -- - Toggle, Input, Dropdown and multi-select Dropdown - so the honest fix
    -- is to walk that table rather than maintain a hand-written list that will
    -- fall behind again the next time a control is added.
    local controls = {}
    pcall(function()
        for flag, c in pairs(Window.controls or {}) do
            local v = c.value
            local kind = typeof(v)
            if kind == "boolean" or kind == "number" or kind == "string" then
                controls[flag] = v
            elseif kind == "table" then
                -- multi-select: store the chosen names as a plain array
                local list = {}
                for _, item in ipairs(v) do
                    if typeof(item) == "string" then list[#list + 1] = item end
                end
                controls[flag] = list
            end
        end
    end)

    return {
        version = 4,
        moveSpeed = TWEEN_SPEED,
        stealDelay = stealDelay,
        theme = BX.theme,
        background = BX.bgImage,
        controls = controls,
    }
end

function X.applySettings(cfg)
    if type(cfg) ~= "table" then return false, "not a profile" end
    local applied = {}

    local n = tonumber(cfg.moveSpeed)
    if n then
        TWEEN_SPEED = math.clamp(n, 100, 800)
        -- Outbound only; carry speed is owned by the limit finder.
        BX.carrySpeed = math.min(TWEEN_SPEED, (BX.serverWalkSpeed and BX.serverWalkSpeed * 1.5) or 250)
        BX.carryLow, BX.carryHigh = nil, nil
        BX.carryWins = 0
        applied[#applied + 1] = "speed"
    end

    n = tonumber(cfg.stealDelay)
    if n then
        stealDelay = math.clamp(n, 0, 5)
        applied[#applied + 1] = "delay"
    end



    -- Look, then apply. A profile written before version 3 carries neither
    -- field, and in that case the hub keeps what it is already showing rather
    -- than being reset to the default by an older save.
    if cfg.theme ~= nil and X.setTheme then
        if X.setTheme(tostring(cfg.theme), true) then
            applied[#applied + 1] = "theme"
        end
    end

    if cfg.background ~= nil and X.setBackground then
        local id = tostring(cfg.background)
        pcall(function() X.setBackground(id) end)
        BX.bgImage = id
        pcall(function()
            local el = X.el and X.el.bgInput
            if el then el.Set(el, id, true) end
        end)
        applied[#applied + 1] = "background"
    end

    -- RESTORE THE CONTROLS, VALUES BEFORE SWITCHES.
    --
    -- Order matters and table iteration order does not exist, so this runs in
    -- two passes. Everything that carries a SETTING - the area and rarity
    -- filters, the target mode, the inputs - goes first, then the toggles that
    -- act on those settings. Restoring Auto Steal before its filters would
    -- start a run against the previous profile's targets.
    --
    -- Callbacks are allowed to fire, deliberately: a profile that had Auto
    -- Steal on is expected to turn it on, not to draw a switch that lies.
    if type(cfg.controls) == "table" then
        local toggles, n = {}, 0
        for flag, value in pairs(cfg.controls) do
            local c = Window.controls and Window.controls[flag]
            if c and type(c.Set) == "function" then
                if typeof(value) == "boolean" then
                    toggles[#toggles + 1] = { c = c, v = value }
                else
                    pcall(function() c.Set(c, value) end)
                    n = n + 1
                end
            end
        end
        for _, item in ipairs(toggles) do
            pcall(function() item.c.Set(item.c, item.v) end)
            n = n + 1
        end
        if n > 0 then applied[#applied + 1] = n .. " controls" end
    end

    -- Set the VALUE above before the toggle below, or the hold arms for one
    -- frame at the previous profile's speed.
    trace("config: applied " .. table.concat(applied, ", "))
    return true, applied
end

function X.saveProfile(name)
    if not X.cfgReady() then return false, "no file API" end
    name = tostring(name or ""):gsub("[^%w_%-]", "")
    if name == "" then return false, "bad name" end
    local ok, body = pcall(function() return X.http():JSONEncode(X.settings()) end)
    if not ok then return false, "encode failed" end
    local wrote = pcall(writefile, X.cfgPath(name), body)
    return wrote, wrote and name or "write failed"
end

function X.loadProfile(name)
    if type(readfile) ~= "function" then return false, "no file API" end
    local path = X.cfgPath(name)
    if type(isfile) == "function" and not isfile(path) then return false, "no such profile" end
    local ok, body = pcall(readfile, path)
    if not ok then return false, "read failed" end
    local decoded
    local okJson = pcall(function() decoded = X.http():JSONDecode(body) end)
    if not okJson then return false, "corrupt profile" end
    return X.applySettings(decoded)
end

function X.listProfiles()
    if type(listfiles) ~= "function" then return {} end
    local ok, files = pcall(listfiles, X.CFG_DIR)
    if not ok or type(files) ~= "table" then return {} end
    local names = {}
    for _, path in ipairs(files) do
        local name = tostring(path):match("profile_([%w_%-]+)%.json$")
        if name then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

function X.profileOptions()
    local l = X.listProfiles()
    if #l == 0 then l = { "No profiles saved" } end
    return l
end

function X.refreshProfileList()
    local d = X.el.profileList
    if d and type(d.Refresh) == "function" then
        pcall(d.Refresh, d, X.profileOptions())
    end
end

-- ============================================================================
-- AUTO REFRESH
-- ============================================================================
--
-- Eggs come back on the game's own cycle, and until now the list only learned
-- about it when somebody pressed Refresh. So after a reset the dropdown still
-- showed the old field, "best egg" was whatever had already been taken, and a
-- filtered run sat there believing there was nothing to steal.
--
-- Rather than guess at the cycle length or reach into AreaEggResetCycle, this
-- watches the thing that actually matters: how many eggs are on the field. A
-- reset shows up as the count jumping, and that is true whoever caused it -
-- the nightly reset, another player banking one, a rift opening.
--
-- Reading the field is free. Measured: EggState.ReadFieldEggs is 0.005ms, so
-- this poll costs nothing next to a refresh, which is why it can afford to
-- check often and rebuild rarely.
task.spawn(function()
    local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
    local lastCount, lastAt = nil, 0
    while true do
        task.wait(K.AUTO_REFRESH_POLL)
        if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end

        local n
        pcall(function()
            local data = EggState and EggState.ReadFieldEggs and EggState.ReadFieldEggs()
            local c = 0
            for _, rec in pairs(data and data.Records or {}) do
                if rec.State == "Slot" or rec.State == "Dropped" then c = c + 1 end
            end
            n = c
        end)

        if n then
            if lastCount == nil then
                lastCount = n
            elseif n ~= lastCount then
                -- Only a GROWING field is a respawn worth rebuilding for; a
                -- shrinking one is just eggs being taken, and the loop already
                -- handles that without a UI rebuild.
                local grew = n > lastCount
                lastCount = n
                if grew and (os.clock() - lastAt) > K.AUTO_REFRESH_GAP then
                    lastAt = os.clock()
                    BX.eggCache = nil
                    BX.saidWaiting = nil
                    trace(("refresh: field grew to %d eggs - rebuilding the list"):format(n))
                    pcall(UI.refresh, true)
                end
            end
        end
    end
end)

-- ============================================================================
-- HEALTH LINE
-- ============================================================================
--
-- "It crashes after 20 minutes" arrives with no data, because nothing looked
-- at memory over time. One line in the trace every two minutes:
--     health: 20m | lua 380MB (+4) | client 3760MB (+12) | hub heap 41MB | 60fps
-- so the next report says which number was climbing. Costs one second of
-- frame counting every two minutes; nothing else.
task.spawn(function()
    local Stats = game:GetService("Stats")
    local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
    local t0, lastLua, lastTotal = os.clock(), nil, nil
    while true do
        task.wait(120)
        if ((getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN) ~= __gen then return end
        pcall(function()
            local frames = 0
            local c = RunService.RenderStepped:Connect(function() frames += 1 end)
            task.wait(1)
            c:Disconnect()
            local lua = Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.LuaHeap)
            local total = Stats:GetTotalMemoryUsageMb()
            trace(("health: %dm | lua %.0fMB (%+.0f) | client %.0fMB (%+.0f) | hub heap %.0fMB | %dfps")
                :format(math.floor((os.clock() - t0) / 60), lua, lua - (lastLua or lua),
                        total, total - (lastTotal or total), collectgarbage("count") / 1024, frames))
            lastLua, lastTotal = lua, total
        end)
    end
end)

-- ============================================================================
-- SHUTDOWN
-- ============================================================================
--
-- CLOSING THE MENU USED TO STOP NOTHING.
--
-- Rayfield's X button calls Window:Unload(), which destroys its own instances
-- and sets window.unloaded = true. It knows nothing about us, so every one of
-- our eleven background loops carried on: the steal loop still flying the
-- character around, the treadmill hold still dragging you back, the Farm
-- watcher, the heartbeat, all of it - for the rest of the session, with no UI
-- to turn any of it off.
--
-- That is the "laggy when closing", and on a phone it is a plausible route to
-- the crash: the work continues while the memory the UI held is being torn
-- down around it.
--
-- The generation counter already retires every loop, so shutdown is just
-- bumping it - and then putting back the two things we changed about the
-- world, so leaving the hub does not leave the game altered.
task.spawn(function()
    local __gen = (getgenv and getgenv().__BLYXO_GEN) or _G.__BLYXO_GEN
    while true do
        task.wait(1)
        local env = (type(getgenv) == "function" and getgenv()) or _G
        if env.__BLYXO_GEN ~= __gen then return end   -- a newer copy took over
        local closed = false
        pcall(function() closed = Window.unloaded == true end)
        if closed then
            trace("=== shutdown: menu closed, retiring everything ===")
            stealing = false
            BX.treadmill = false
            pcall(function() if X.setFpsBoost then X.setFpsBoost(false) end end)
            pcall(function() if X.setStatsHud then X.setStatsHud(false) end end)
            pcall(stopProtect)
            pcall(disableNoclip)
            -- Every connection this copy still holds, so nothing keeps
            -- running - or keeps its memory alive - after the menu is gone.
            for _, holder in ipairs({ BX, BlyxoTop }) do
                for _, v in pairs(holder) do
                    if typeof(v) == "RBXScriptConnection" then
                        pcall(function() v:Disconnect() end)
                    end
                end
            end
            -- Last thing: bump the generation so every loop, including this
            -- one, returns on its next tick.
            env.__BLYXO_GEN = (tonumber(env.__BLYXO_GEN) or 0) + 1
            return
        end
    end
end)

BlyxoSplash.step("Loading profiles", 0.95)
X.cfgTab = Window:CreateTab({ name = "Config" })
X.cfgTab:CreateSection({ name = "Profiles" })

X.cfgName = "default"
X.cfgTab:CreateInput({
    name = "Profile Name",
    description = "Letters and numbers only",
    placeholder = "default",
    value = "default",
    flag = "ProfileName",
    callback = function(v)
        local clean = tostring(v or ""):gsub("[^%w_%-]", "")
        X.cfgName = clean ~= "" and clean or "default"
    end,
})

X.cfgStatus = X.label(X.cfgTab, "No profile loaded")

X.cfgTab:CreateButton({
    name = "Save Profile",
    description = "Saves your current settings",
    callback = function()
        local ok, info = X.saveProfile(X.cfgName)
        if ok then
            toast("Saved profile: " .. tostring(info))
            X.setLabel(X.cfgStatus, "Saved: " .. tostring(info))
            trace("config: saved " .. tostring(info))
            X.refreshProfileList()
        else
            toast("Save failed: " .. tostring(info))
            trace("config: save failed - " .. tostring(info))
        end
    end,
})

X.el.profileList = X.cfgTab:CreateDropdown({
    name = "Load Profile",
    options = X.profileOptions(),
    flag = "ProfilePick",
    callback = function(v)
        if typeof(v) == "table" then v = v[1] end
        v = tostring(v)
        if v == "No profiles saved" then return end
        X.cfgName = v
        local ok, applied = X.loadProfile(v)
        if ok then
            local what = type(applied) == "table" and table.concat(applied, ", ") or ""
            toast("Loaded " .. v .. (what ~= "" and (" (" .. what .. ")") or ""))
            X.setLabel(X.cfgStatus, "Loaded: " .. v)
        else
            toast("Load failed: " .. tostring(applied))
        end
    end,
})

X.cfgTab:CreateButton({
    name = "Refresh Profile List",
    callback = function()
        X.refreshProfileList()
        toast(#X.listProfiles() .. " profile(s) on disk")
    end,
})

X.cfgTab:CreateButton({
    name = "Delete Profile",
    description = "Deletes the profile named above",
    callback = function()
        local path = X.cfgPath(X.cfgName)
        if type(isfile) ~= "function" or not isfile(path) then
            toast("No such profile: " .. tostring(X.cfgName))
            return
        end
        if pcall(delfile, path) then
            toast("Deleted " .. X.cfgName)
            trace("config: deleted " .. X.cfgName)
            X.refreshProfileList()
        else
            toast("Delete failed")
        end
    end,
})

-- ============================================================================
-- AUTO-LOAD A PROFILE ON START
-- ============================================================================
--
-- Pick one of your saved profiles (or Off) and it is loaded every time the
-- hub starts - through X.loadProfile, the same path as the Load dropdown, so
-- it applies exactly as loading it by hand does. The choice lives in its own
-- small file next to the profiles, not inside a profile, so loading a profile
-- can never change which one auto-loads. No `flag` on the dropdown for the
-- same reason.
X.AUTOLOAD_OFF = "Off"
function X.autoLoadPath() return X.CFG_DIR .. "/autoload.txt" end
function X.autoLoadName()
    local name
    pcall(function()
        if type(isfile) == "function" and isfile(X.autoLoadPath()) then
            name = tostring(readfile(X.autoLoadPath())):gsub("[^%w_%-]", "")
        end
    end)
    return (name and name ~= "") and name or nil
end
function X.autoLoadOptions()
    local l = { X.AUTOLOAD_OFF }
    for _, n in ipairs(X.listProfiles()) do l[#l + 1] = n end
    return l
end

X.cfgTab:CreateSection({ name = "Auto Load" })

X.el.autoLoadList = X.cfgTab:CreateDropdown({
    name = "Auto-load profile",
    options = X.autoLoadOptions(),
    callback = function(v)
        if X.autoLoadSuppress then return end
        if typeof(v) == "table" then v = v[1] end
        v = tostring(v)
        local ok = pcall(function()
            if type(isfolder) == "function" and not isfolder(X.CFG_DIR) then makefolder(X.CFG_DIR) end
            writefile(X.autoLoadPath(), v == X.AUTOLOAD_OFF and "" or v)
        end)
        if not ok then
            toast("Could not save the auto-load choice")
        elseif v == X.AUTOLOAD_OFF then
            toast("Auto-load off")
        else
            toast("Auto-loads " .. v .. " on start")
        end
        trace("config: auto-load " .. (v == X.AUTOLOAD_OFF and "off" or ("-> " .. v)))
    end,
})

-- Keep its options in step with the profile list (save / delete / refresh).
-- (Held on X, not in a local: the main chunk is at the register ceiling.)
X.refreshProfilesBase = X.refreshProfileList
X.refreshProfileList = function()
    X.refreshProfilesBase()
    local d = X.el.autoLoadList
    if d and type(d.Refresh) == "function" then
        X.autoLoadSuppress = true
        pcall(d.Refresh, d, X.autoLoadOptions())
        pcall(function() d.Set(d, X.autoLoadName() or X.AUTOLOAD_OFF, true) end)
        X.autoLoadSuppress = false
    end
end

-- Show the saved choice, then load it - a moment after the menu is up, so
-- every control a profile touches exists and the default theme has already
-- been applied (a profile's own theme then wins).
task.delay(0.6, function()
    local name = X.autoLoadName()
    local d = X.el.autoLoadList
    if d then
        X.autoLoadSuppress = true
        pcall(function() d.Set(d, name or X.AUTOLOAD_OFF, true) end)
        X.autoLoadSuppress = false
    end
    if not name then return end
    local ok, applied = X.loadProfile(name)
    if ok then
        X.cfgName = name
        X.setLabel(X.cfgStatus, "Auto-loaded: " .. name)
        trace("config: auto-loaded " .. name)
        toast("Auto-loaded " .. name)
    else
        trace("config: auto-load of " .. name .. " failed - " .. tostring(applied))
        toast("Auto-load failed: " .. tostring(applied))
    end
end)



--=====================================================================

trace("ui: Config tab built")

-- ============================================================================
-- SMOOTHER PAGE TRANSITIONS
-- ============================================================================
--
-- Rayfield switches tabs with a UIPageLayout:JumpTo - every tab page is a
-- ScrollingFrame side by side, and the layout slides between them with
-- EasingStyle.Exponential over 0.4s. Exponential is the harsh one: it sits
-- still, then snaps across at the end. Three quiet changes:
--   * the slide itself: Quint, ease-out, 0.32s - starts moving at once and
--     settles gently instead of snapping,
--   * the page coming in settles from 97.5% scale to 100%,
--   * a veil in the theme's own background colour, starting at 55% and
--     fading out over the page - a soft cross-fade, not a flash.
-- The veil takes no input. Low-end mode keeps only the softer slide.
-- In a function: the main chunk is at the 200-local ceiling.
;(function()
    local TS = game:GetService("TweenService")
    local layout
    pcall(function()
        for _, root in ipairs({ gethui and gethui() or nil, game:GetService("CoreGui") }) do
            if root then
                for _, d in ipairs(root:GetDescendants()) do
                    if d:IsA("UIPageLayout") and d.Parent
                       and d.Parent:FindFirstChild("Home") and d.Parent:FindFirstChild("Config") then
                        layout = d
                        return
                    end
                end
            end
        end
    end)
    if not layout then trace("ui: page layout not found - transitions unchanged") return end

    pcall(function()
        layout.EasingStyle = Enum.EasingStyle.Quint
        layout.EasingDirection = Enum.EasingDirection.Out
        layout.TweenTime = 0.32
    end)

    local pages = layout.Parent
    local veil
    pcall(function()
        veil = Instance.new("Frame")
        veil.Name = "BlyxoPageVeil"
        veil.AnchorPoint = pages.AnchorPoint
        veil.Position = pages.Position
        veil.Size = pages.Size
        veil.BackgroundTransparency = 1
        veil.BorderSizePixel = 0
        veil.Active = false
        veil.ZIndex = 50
        veil.Parent = pages.Parent
        local corner = pages.Parent:FindFirstChildOfClass("UICorner")
        if corner then Instance.new("UICorner", veil).CornerRadius = corner.CornerRadius end
    end)

    BlyxoTop.pageEnter = layout.PageEnter:Connect(function(page)
        if liteMode then return end
        pcall(function()
            local sc = page:FindFirstChild("BlyxoPageScale") or Instance.new("UIScale")
            sc.Name = "BlyxoPageScale"
            sc.Parent = page
            sc.Scale = 0.975
            TS:Create(sc, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
                { Scale = 1 }):Play()
        end)
        if veil then
            pcall(function()
                local th = BlyxoThemeCurrent
                veil.BackgroundColor3 = (th and th.bgBottom) or Color3.fromRGB(14, 14, 17)
                veil.BackgroundTransparency = 0.45
                TS:Create(veil, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                    { BackgroundTransparency = 1 }):Play()
            end)
        end
    end)
    trace("ui: page transitions softened")
end)()

-- THE "-" BUTTON DOES WHAT X DOES: COLLAPSE TO THE PILL.
--
-- In Rayfield Gen2 the X action's callback is Window:ToggleHide() - it folds
-- the window into the small "Tap to show" pill - and "-" calls
-- ToggleMinimise(), a different, shrunken window. Both are Action objects
-- whose click handler calls `self.callback` at click time, so the "-"
-- action's callback is simply pointed at the same ToggleHide. Nothing is
-- stacked on top of the library's own handler, and nothing is unloaded.
pcall(function()
    local act = Window.minimiseAction
    if act and type(act.callback) == "function" then
        act.callback = function() Window:ToggleHide() end
        trace("ui: minimise now collapses to the pill, same as X")
    else
        trace("ui: minimise action not found - left as Rayfield made it")
    end
end)

-- WHERE THE LOAD WENT, so a "takes a minute to load" report can be read
-- instead of guessed at: library download, waiting for the game, the
-- Discord step, building the menu.
pcall(function()
    local L, now = BlyxoLoadT, os.clock()
    trace(("=== load: %.1fs total | library %.1fs | game %.1fs | discord %.1fs | menu %.1fs ===")
        :format(now - L.start, (L.lib or L.start) - L.start, (L.game or L.lib or L.start) - (L.lib or L.start),
                (L.discord or L.game or 0) - (L.game or 0), now - (L.discord or L.game or now)))
end)
BlyxoSplash.done()


---------- DISCORD GATE ----------
--
-- is best-effort. That is the one rule this block must not break.
--      browser. MEASURED on this setup: Madium BLOCKS it - the call returns
--      no shellexecute or equivalent either, so on Madium this tier can never
--      fire. It is kept because most other executors do allow it, and there it
-- A spawned function gets its own register budget, and per the notes above
if false then task.spawn(function()
    local INVITE_CODE = "9KSXyabAYV"
    local INVITE_URL = "https://discord.gg/" .. INVITE_CODE

    -- The window's own theme, so the gate reads as part of the hub rather than
    -- a differently-coloured box in front of it. Same values as CreateWindow,
    -- plus the two greys the layout needs for hierarchy.
    local C = {
        Accent  = Color3.fromRGB(255, 255, 255),
        Stroke  = Color3.fromRGB(38, 38, 38),
        Text    = Color3.fromRGB(228, 228, 228),
        Sub     = Color3.fromRGB(138, 138, 138),
        Faint   = Color3.fromRGB(96, 96, 96),
        Bg      = Color3.fromRGB(12, 12, 12),
        Element = Color3.fromRGB(20, 20, 20),
        Blurple = Color3.fromRGB(88, 101, 242),
        Good    = Color3.fromRGB(87, 242, 135),
    }

    local function new(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do o[k] = v end
        if parent then o.Parent = parent end
        return o
    end

    local function corner(o, r)
        new("UICorner", { CornerRadius = UDim.new(0, r) }, o)
    end

    local function stroke(o, col, thick, trans)
        return new("UIStroke", {
            Color = col, Thickness = thick or 1, Transparency = trans or 0,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }, o)
    end

    local function httpFn()
        return (syn and syn.request) or request or http_request or httprequest
    end

    local function copyInvite()
        for _, fn in pairs({ setclipboard, toclipboard, set_clipboard }) do
            if type(fn) == "function" and pcall(fn, INVITE_URL) then return true end
        end
        return false
    end

    -- Tier 2. Blocked on Madium, fine on most others - hence the pcall and the
    -- honest return value rather than assuming it worked.
    local function openInBrowser()
        return (pcall(function()
            game:GetService("GuiService"):OpenBrowserWindow(INVITE_URL)
        end))
    end

    -- Tier 1. All ten ports are probed AT ONCE, and that is not a micro
    -- optimisation: measured with Discord closed, one probe costs 2.05s and
    -- ten fired together also cost 2.10s, while ten done one after another
    local function openInDiscordApp(onDone)
        local req = httpFn()
        if type(req) ~= "function" then onDone(false) return end
        local HttpService = game:GetService("HttpService")
        local body = HttpService:JSONEncode({
            cmd = "INVITE_BROWSER",
            args = { code = INVITE_CODE },
            nonce = HttpService:GenerateGUID(false),
        })

        local pending, answered = 10, false
        local function settle(ok, port)
            if answered then return end
            if ok then
                answered = true
                trace("discord: RPC accepted on port " .. tostring(port))
                onDone(true)
            elseif pending <= 0 then
                answered = true
                onDone(false)
            end
        end

        for port = 6463, 6472 do
            task.spawn(function()
                local ok, res = pcall(req, {
                    Url = ("http://127.0.0.1:%d/rpc?v=1"):format(port),
                    Method = "POST",
                    Headers = {
                        ["Content-Type"] = "application/json",
                        ["Origin"] = "https://discord.com",
                    },
                    Body = body,
                })
                -- Normalise to a number or nil, never `false`. The chained
                -- `ok and ... and tonumber(...)` yields FALSE when the request
                -- pending hit zero with the callback never firing.
                local code = nil
                if ok and type(res) == "table" then code = tonumber(res.StatusCode) end
                pending -= 1
                settle(code ~= nil and code >= 200 and code < 300, port)
            end)
        end
    end

    ---------- layout ----------

    local parent = (gethui and gethui()) or game:GetService("CoreGui")
    local gui = new("ScreenGui", {
        Name = "BlyxoWelcome", DisplayOrder = 999999, IgnoreGuiInset = true,
        ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, parent)

    -- The modal shade keeps the gate strict while the card itself stays quiet,
    -- compact, and visually consistent with Rayfield's dark surface language.
    local shade = new("TextButton", {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(3, 4, 8),
        BackgroundTransparency = 1, BorderSizePixel = 0, Text = "",
        AutoButtonColor = false, Active = true, Modal = true,
    }, gui)

    -- Local image support keeps the real brand mark intact. If the executor
    -- cannot load local assets, upload this PNG to Roblox and replace the
    -- fallback asset string below with its rbxassetid:// value.
    local LOGO_PATH = "C:\\Users\\calle\\Downloads\\Black & White Letter Z Logo.png"
    local LOGO_FALLBACK = ""
    local logoAsset = LOGO_FALLBACK
    for _, loader in pairs({ getsynasset, getcustomasset, getasset }) do
        if type(loader) == "function" then
            local ok, asset = pcall(loader, LOGO_PATH)
            if ok and type(asset) == "string" and asset ~= "" then
                logoAsset = asset
                break
            end
        end
    end

    local shadow = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(472, 362), BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 1, BorderSizePixel = 0,
    }, shade)
    corner(shadow, 22)

    local card = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(460, 350), BackgroundColor3 = C.Bg,
        BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true,
    }, shade)
    corner(card, 18)
    local cardStroke = stroke(card, Color3.fromRGB(48, 52, 68), 1, 1)

    local rule = new("Frame", {
        Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = C.Blurple,
        BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2,
    }, card)

    local content = new("Frame", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
    }, card)
    new("UIPadding", {
        PaddingTop = UDim.new(0, 30), PaddingLeft = UDim.new(0, 30),
        PaddingRight = UDim.new(0, 30), PaddingBottom = UDim.new(0, 26),
    }, content)

    local head = new("Frame", { Size = UDim2.new(1, 0, 0, 42), BackgroundTransparency = 1 }, content)
    local badge = new("Frame", {
        Size = UDim2.fromOffset(42, 42), BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 1, BorderSizePixel = 0,
    }, head)
    corner(badge, 13)
    local badgeText = new("TextLabel", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 21, TextColor3 = C.Accent,
        TextTransparency = 1, Text = "",
    }, badge)
    local badgeLogo = nil
    if logoAsset ~= "" then
        badgeLogo = new("ImageLabel", {
            Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
            Image = logoAsset, ImageTransparency = 1, ScaleType = Enum.ScaleType.Fit,
        }, badge)
    else
        -- Never show an empty black square when the executor cannot load the
        -- local PNG. The wordmark becomes the header instead.
        badge.Visible = false
    end
    local wordmarkLabel = new("TextLabel", {
        Position = UDim2.fromOffset(logoAsset ~= "" and 56 or 0, 1),
        Size = UDim2.new(1, logoAsset ~= "" and -56 or 0, 0, 22),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 17,
        TextColor3 = C.Text, TextTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left,
        Text = "BlyxoHub",
    }, head)
    local kicker = new("TextLabel", {
        Position = UDim2.fromOffset(logoAsset ~= "" and 56 or 0, 24),
        Size = UDim2.new(1, logoAsset ~= "" and -56 or 0, 0, 15),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
        TextColor3 = C.Faint, TextTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left,
        Text = "STEAL AN EGG  /  COMMUNITY",
    }, head)

    local title = new("TextLabel", {
        Position = UDim2.fromOffset(0, 68), Size = UDim2.new(1, 0, 0, 28),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 21,
        TextColor3 = C.Accent, TextTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Join the Discord",
    }, content)
    local blurb = new("TextLabel", {
        Position = UDim2.fromOffset(0, 101), Size = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 13,
        TextColor3 = C.Sub, TextTransparency = 1, TextWrapped = true, LineHeight = 1.15,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        Text = "Get updates and support from the community.",
    }, content)

    local pill = new("Frame", {
        Position = UDim2.fromOffset(0, 150), Size = UDim2.new(1, 0, 0, 46),
        BackgroundColor3 = C.Element, BackgroundTransparency = 1, BorderSizePixel = 0,
    }, content)
    corner(pill, 11)
    local pillStroke = stroke(pill, Color3.fromRGB(45, 48, 62), 1, 1)
    local invite = new("TextLabel", {
        Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -32, 1, 0),
        BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 13,
        TextColor3 = Color3.fromRGB(190, 196, 255), TextTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left, Text = "discord.gg/" .. INVITE_CODE,
    }, pill)

    local join = new("TextButton", {
        Position = UDim2.fromOffset(0, 210), Size = UDim2.new(1, 0, 0, 48),
        BackgroundColor3 = C.Blurple, BackgroundTransparency = 1, BorderSizePixel = 0,
        AutoButtonColor = false, Font = Enum.Font.GothamBold, TextSize = 14,
        TextColor3 = C.Accent, TextTransparency = 1, Text = "Join Discord   →",
    }, content)
    corner(join, 11)
    local status = new("TextLabel", {
        Position = UDim2.fromOffset(0, 274), Size = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12,
        TextColor3 = C.Faint, TextTransparency = 1, TextXAlignment = Enum.TextXAlignment.Center,
        Text = "Required to use the hub",
    }, content)

    ---------- motion ----------

    local QUAD = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local function tw(o, info, props)
        local t = TweenService:Create(o, info, props)
        t:Play()
        return t
    end

    -- Entrance: the card rises and fades rather than popping into place.
    card.Position = UDim2.new(0.5, 0, 0.5, 14)
    shadow.Position = UDim2.new(0.5, 0, 0.5, 18)
    tw(shade, QUAD, { BackgroundTransparency = 0.45 })
    tw(shadow, TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        BackgroundTransparency = 0.88, Position = UDim2.fromScale(0.5, 0.5),
    })
    tw(card, TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        BackgroundTransparency = 0, Position = UDim2.fromScale(0.5, 0.5),
    })
    tw(cardStroke, QUAD, { Transparency = 0 })
    tw(rule, QUAD, { BackgroundTransparency = 0 })
    for _, o in ipairs({ badge, pill }) do tw(o, QUAD, { BackgroundTransparency = 0 }) end
    tw(pillStroke, QUAD, { Transparency = 0 })
    tw(join, QUAD, { BackgroundTransparency = 0 })
    local fadeObjects = { badgeText, wordmarkLabel, kicker, title, blurb, invite, join, status }
    for _, o in ipairs(fadeObjects) do
        tw(o, QUAD, { TextTransparency = 0 })
    end
    if badgeLogo then tw(badgeLogo, QUAD, { ImageTransparency = 0 }) end

    -- Hover and press states, so the button feels like a control.
    local hovering = false
    join.MouseEnter:Connect(function()
        hovering = true
        tw(join, TweenInfo.new(0.12), { BackgroundColor3 = Color3.fromRGB(111, 123, 255) })
    end)
    join.MouseLeave:Connect(function()
        hovering = false
        tw(join, TweenInfo.new(0.12), { BackgroundColor3 = C.Blurple })
    end)
    join.MouseButton1Down:Connect(function()
        tw(join, TweenInfo.new(0.08), { BackgroundColor3 = Color3.fromRGB(73, 84, 205) })
    end)
    join.MouseButton1Up:Connect(function()
        tw(join, TweenInfo.new(0.12), {
            BackgroundColor3 = hovering and Color3.fromRGB(111, 123, 255) or C.Blurple,
        })
    end)

    local closed = false
    local function close()
        if closed then return end
        closed = true
        local out = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        tw(shade, out, { BackgroundTransparency = 1 })
        tw(shadow, out, { BackgroundTransparency = 1 })
        tw(card, out, { BackgroundTransparency = 1, Position = UDim2.new(0.5, 0, 0.5, 10) })
        task.delay(0.24, function() pcall(function() gui:Destroy() end) end)
    end

    join.MouseButton1Click:Connect(function()
        if closed then return end

        -- ORDER MATTERS. The clipboard copy and the browser attempt happen NOW,
        -- synchronously, because they are instant and they are what the user is
        local copied = copyInvite()
        local web = openInBrowser()
        print("[BLYXO] Discord: " .. INVITE_URL)

        join.Text = "Opening Discord"
        status.Text = web and "Opening the invite in your browser"
                       or (copied and "Invite copied to clipboard" or INVITE_URL)
        status.TextColor3 = (web or copied) and C.Good or C.Sub
        tw(status, TweenInfo.new(0.15), { TextTransparency = 0 })

        -- Rayfield's own notification too, for the users who look there.
        if web then
            toast("Opening the invite in your browser")
        elseif copied then
            toast("Invite copied - discord.gg/" .. INVITE_CODE)
        else
            toast("Join at " .. INVITE_URL .. " (see console)")
        end

        -- Long enough to actually read the status line, short enough not to
        -- feel like a wait.
        task.delay(0.9, function()
            close()
            task.delay(0.24, function()
                pcall(function() Window:ToggleHide() end)
            end)
        end)

        openInDiscordApp(function(opened)
            trace(("discord gate: app=%s web=%s clipboard=%s")
                :format(tostring(opened), tostring(web), tostring(copied)))
            if opened then toast("Discord is open - accept the invite there") end
        end)
    end)

    trace("ui: Discord gate shown (strict)")
end) end
