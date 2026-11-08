--!nonstrict
-- RuneLite Recorder - headless service.
--
-- Discovers RuneLite client sessions (one window + pid each) and publishes them
-- on the shared "status" channel. Recording is added on top of this in later
-- steps; for now the service only tracks and logs sessions.

local windows = require("./lib/hyprland.luau")

local TICK_MS = 250
local POLL_IDLE_MS = 3000 -- no session known
local POLL_ACTIVE_MS = 1000 -- at least one session known
-- A poll whose callback never arrives (or raised an error) must not block
-- discovery forever; after this long a new poll is allowed.
local POLL_STUCK_MS = 10000

noctalia.setUpdateInterval(TICK_MS)

local sessions = {} -- ordered list, see lib/hyprland.luau
local pollPending = false
local pollStartedAt = 0
local nextPollAt = 0
local lastWarning = nil
local available = nil
local lastStatusJson = nil

-- ── Helpers ──────────────────────────────────────────────────────────────

local function log(msg)
    noctalia.log(`runelite_recorder: {msg}`)
end

local function cfg(key)
    return noctalia.getConfig(key)
end

local function describe(s)
    local who = if s.character then `'{s.character}'` else "not logged in"
    return `{who} [{s.id}] {s.frameWidth}x{s.frameHeight} on {s.monitor or "?"} ws {s.workspace or "?"}`
end

local function windowOptions()
    return {
        classPattern = cfg("window_class") or "^net-runelite-client-RuneLite$",
        excludeTitle = cfg("exclude_title") or "",
    }
end

-- ── Status publication ───────────────────────────────────────────────────

local function publishStatus()
    local list = {}
    for _, s in sessions do
        table.insert(list, {
            id = s.id,
            address = s.address,
            pid = s.pid,
            title = s.title,
            character = s.character,
            frameWidth = s.frameWidth,
            frameHeight = s.frameHeight,
            monitor = s.monitor,
            workspace = s.workspace,
            visible = s.visible,
            focused = s.focused,
        })
    end
    local status = {
        available = available == true,
        sessions = list,
        recordingSession = nil,
        state = "idle",
    }
    -- Only publish real changes so watchers are not woken every poll.
    local encoded = noctalia.json.encode(status)
    if encoded == lastStatusJson then return end
    lastStatusJson = encoded
    noctalia.state.set("status", status)
end

-- ── Session tracking ─────────────────────────────────────────────────────

local function diffSessions(old, new)
    local oldById = {}
    for _, s in old do oldById[s.id] = s end
    local newById = {}
    for _, s in new do newById[s.id] = s end

    for _, s in new do
        local prev = oldById[s.id]
        if prev == nil then
            log(`session appeared: {describe(s)}`)
        else
            if prev.title ~= s.title then
                log(`session title changed: [{s.id}] '{prev.title}' -> '{s.title}'`)
            end
            if prev.frameWidth ~= s.frameWidth or prev.frameHeight ~= s.frameHeight then
                log(`session frame size changed: [{s.id}] {prev.frameWidth}x{prev.frameHeight} -> {s.frameWidth}x{s.frameHeight}`)
            end
            if prev.monitor ~= s.monitor or prev.workspace ~= s.workspace then
                log(`session moved: [{s.id}] {prev.monitor or "?"}/{prev.workspace or "?"} -> {s.monitor or "?"}/{s.workspace or "?"}`)
            end
        end
    end
    for _, s in old do
        if newById[s.id] == nil then
            log(`session closed: {describe(s)}`)
        end
    end
end

local function poll()
    local now = noctalia.nowMs()
    if pollPending and now - pollStartedAt < POLL_STUCK_MS then return end
    pollPending = true
    pollStartedAt = now
    local thisPoll = now
    windows.listSessions(windowOptions(), function(list, err)
        if pollStartedAt ~= thisPoll then return end -- superseded by a newer poll
        pollPending = false
        nextPollAt = noctalia.nowMs() + (if #sessions > 0 then POLL_ACTIVE_MS else POLL_IDLE_MS)

        if err ~= lastWarning then
            if err ~= nil then log(err) end
            lastWarning = err
        end
        if list == nil then return end

        diffSessions(sessions, list)
        sessions = list
        nextPollAt = noctalia.nowMs() + (if #sessions > 0 then POLL_ACTIVE_MS else POLL_IDLE_MS)
        publishStatus()
    end)
end

-- ── Availability ─────────────────────────────────────────────────────────

local function checkAvailability()
    local hasGsr = noctalia.commandExists("gpu-screen-recorder")
    local hasHyprland = windows.available()
    if not hasGsr then log("gpu-screen-recorder not found on PATH; recording unavailable") end
    if not hasHyprland then log("Hyprland not detected (hyprctl or HYPRLAND_INSTANCE_SIGNATURE missing)") end
    available = hasGsr and hasHyprland
    log(`service started (available={available})`)
end

-- ── Callbacks ────────────────────────────────────────────────────────────

function update()
    if available == nil then
        checkAvailability()
    end
    if not windows.available() then return end
    if noctalia.nowMs() >= nextPollAt then
        poll()
    end
end

function onConfigChanged()
    windows.resetMatchCache()
    nextPollAt = 0
end

function onIpc(event, _payload)
    if event == "sessions" then
        if #sessions == 0 then
            log("no RuneLite sessions")
        end
        for i, s in sessions do
            log(`session {i}: {describe(s)}{if s.focused then " (focused)" else ""}`)
        end
    else
        log(`unknown command '{event}'`)
    end
end

publishStatus()
