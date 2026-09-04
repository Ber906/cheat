-- CloverHub main loader
if not game:IsLoaded() then
    game.Loaded:Wait()
end

local env = getgenv()

if env.__CloverHubLoading then
    warn("[CloverHub] Loader is already running.")
    return
end

env.__CloverHubLoading = true

local BASE_URL =
    "https://raw.githubusercontent.com/Ber906/cheat/refs/heads/main/"

local ROUTES = {
    ["107778070777162"] = { name = "Steal An Egg",   file = "CloverHubv2.lua" },
}

local success, loaderError = pcall(function()
    local route = ROUTES[tostring(game.PlaceId)]

    if not route then
        error(("Unsupported game. PlaceId: %s"):format(game.PlaceId))
    end

    local scriptUrl = BASE_URL .. route.file
    local source
    local lastError

    for attempt = 1, 3 do
        local fetched, result = pcall(game.HttpGet, game, scriptUrl)

        if fetched and type(result) == "string" and #result > 0 then
            source = result
            break
        end

        lastError = result
        task.wait(attempt * 0.5)
    end

    if not source then
        error(("Failed to download %s: %s")
            :format(route.name, tostring(lastError)))
    end

    local chunk, compileError = loadstring(source)

    if not chunk then
        error(("Failed to compile %s: %s")
            :format(route.name, tostring(compileError)))
    end

    chunk()
end)

env.__CloverHubLoading = nil

if not success then
    warn("[CloverHub] " .. tostring(loaderError))
end
