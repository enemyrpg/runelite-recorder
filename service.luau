--!nonstrict
-- RuneLite Recorder - headless service.
--
-- Discovers RuneLite client sessions (one window + pid each), records one of
-- them with gpu-screen-recorder through the portal picker, and publishes the
-- result on the shared "status" channel. UI entries drive it through the
-- "command" channel; the CLI through onIpc.
--
-- Process invariant: at most one gsr process from this plugin exists. `proc` is
-- set from launch until the process is confirmed gone, and nothing is launched
-- while it is set.

local windows = require("./lib/hyprland.luau")
local gsr = require("./lib/gsr.luau")
local picker = require("./lib/picker.luau")

local TICK_MS = 250
local POLL_IDLE_MS = 3000 -- no session known
local POLL_ACTIVE_MS = 1000 -- at least one session known
-- A poll whose callback never arrives (or raised an error) must not block
-- discovery forever; after this long a new poll is allowed.
local POLL_STUCK_MS = 10000
local PID_WAIT_MS = 5000 -- launch wrapper must write the pid file within this
-- Alive this long (and, with gsr-cli, answering on its socket) = started. The
-- socket appears before the portal selection is done, so it alone is not enough.
local STARTED_MIN_MS = 2000
local STATUS_POLL_MS = 1000 -- gsr-cli status interval while starting
local KILL_AFTER_MS = 3000 -- SIGINT, then SIGKILL after this
local SAVE_TIMEOUT_MS = 30000

noctalia.setUpdateInterval(TICK_MS)

local dataDir = noctalia.pluginDataDir()

local sessions = {} -- ordered list, see lib/hyprland.luau
local pollPending = false
local pollStartedAt = 0
local nextPollAt = 0
local lastWarning = nil

local available = nil -- nil until checked
local ready = false -- runelite-gsr symlink and picker installed
local pickerConfigured = false

-- idle | starting | active | stopping
local state = "idle"
-- Current gsr process, or nil. Fields: token, pid, mode ("replay" | "record"),
-- sessionId, character, output, launchedAt, stopSentAt, killed, notifyOnStop,
-- statusCheckAt, statusPending, orphan.
local proc = nil
-- Capture to start once the current process is gone: { mode, sessionId, restart }.
-- Only one is kept; a newer command replaces it.
local queued = nil
local saving = false

local lastStatusJson = nil

-- ── Helpers ──────────────────────────────────────────────────────────────

local function log(msg)
    noctalia.log(`runelite_recorder: {msg}`)
end

local function cfg(key)
    return noctalia.getConfig(key)
end

local function tr(key, subst)
    return noctalia.tr(key, subst)
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

local function findSession(id)
    for _, s in sessions do
        if s.id == id then return s end
    end
    return nil
end

local function basename(path)
    return path:match("([^/]+)$") or path
end

-- Character name for file and folder names: spaces become "_", and anything
-- that is unsafe in a path or would be read as a format directive is replaced.
local function sanitizeName(name)
    local clean = (name or "unknown"):gsub("\u{a0}", " "):gsub("%s+", "_"):gsub("[/%c%%{}]", "_"):gsub("^%.+", "_")
    return if clean == "" then "unknown" else clean
end

-- strftime pattern plus the {character} token. formatTime treats "{...}" as its
-- own format syntax, so the token is split out and each piece formatted alone.
local function formatFilename(pattern, character)
    local name = sanitizeName(character)
    local parts = {}
    for piece in (pattern .. "{character}"):gmatch("(.-){character}") do
        table.insert(parts, if piece == "" then "" else noctalia.formatTime(piece))
    end
    return table.concat(parts, name)
end

-- Loose form of a character name for matching user input: case-insensitive,
-- and spaces, underscores and non-breaking spaces are all the same.
local function looseName(name)
    local spaced = (name or ""):gsub("\u{a0}", " "):gsub("[%s_]+", " ")
    return noctalia.string.trim(spaced):lower()
end

local function outputDirectory()
    local configured = cfg("directory")
    local dir = noctalia.expandPath(if type(configured) == "string" and configured ~= "" then configured else "~/Videos/RuneLite")
    return (dir:gsub("/+$", ""))
end

local function copyToClipboard(path)
    local uri = "file://" .. path:gsub("%%", "%%25"):gsub(" ", "%%20"):gsub("'", "%%27"):gsub('"', "%%22")
    noctalia.copyToClipboard(uri, "text/uri-list")
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
        ready = ready,
        pickerConfigured = pickerConfigured,
        sessions = list,
        state = state,
        mode = if proc then proc.mode else nil,
        recordingSession = if proc and not proc.orphan then proc.sessionId else nil,
        replayDuration = cfg("replay_duration"),
        audioSource = cfg("audio_source"),
    }
    -- Only publish real changes so watchers are not woken every tick.
    local encoded = noctalia.json.encode(status)
    if encoded == lastStatusJson then return end
    lastStatusJson = encoded
    noctalia.state.set("status", status)
end

local function setState(next)
    if state == next then return end
    log(`state {state} -> {next}`)
    state = next
    publishStatus()
end

-- ── Audio ────────────────────────────────────────────────────────────────

local function audioSources()
    local source = cfg("audio_source")
    if source == "none" then return {} end
    if source == "default_input" then return { "default_input" } end
    if source == "both" then return { "default_output|default_input" } end
    if source == "custom" then
        local list = {}
        for src in tostring(cfg("custom_audio_sources") or ""):gmatch("([^,]+)") do
            src = noctalia.string.trim(src)
            if src ~= "" then table.insert(list, src) end
        end
        return list
    end
    return { "default_output" }
end

-- ── Process control ──────────────────────────────────────────────────────

local startProcess, stopProcess

-- What the portal stream delivers; gsr freezes when this changes.
local function frameSize(s)
    return `{s.frameWidth}x{s.frameHeight}`
end

-- Called once the gsr process is confirmed gone.
local function onProcessExit()
    local p = proc
    proc = nil
    saving = false
    local wasState = state
    setState("idle")
    if p == nil then return end

    if p.orphan then
        log(`previous gsr process {p.pid} is gone`)
    elseif wasState == "stopping" then
        log(`gsr {p.pid} stopped ({p.mode})`)
        if p.mode == "record" and p.notifyOnStop then
            noctalia.runAsync({ "test", "-s", p.output }, function(result)
                if result.exitCode == 0 then
                    log(`recording saved: {p.output}`)
                    noctalia.notify(tr("notify.recording-saved"), basename(p.output))
                    if cfg("copy_to_clipboard") then copyToClipboard(p.output) end
                else
                    gsr.logTail(log, "recording stopped but no output file was found")
                    noctalia.notifyError(tr("notify.recording-failed"), tr("notify.stopped-early"))
                end
            end, 5000)
        elseif p.mode == "replay" and p.notifyOnStop then
            noctalia.notify(tr("notify.replay-stopped"))
        end
    elseif wasState == "starting" and gsr.portalCancelled() then
        log("window selection was cancelled in the portal dialog")
    else
        local what = if p.mode == "replay" then "replay buffer" else "recording"
        gsr.logTail(log, `{what} ended unexpectedly`)
        noctalia.notifyError(
            tr(if p.mode == "replay" then "notify.replay-failed" else "notify.recording-failed"),
            tr("notify.stopped-early")
        )
    end

    local next = queued
    queued = nil
    if next ~= nil then
        local s = findSession(next.sessionId)
        if s ~= nil then
            startProcess(next.mode, s, next.restart)
        else
            log("queued start dropped: its session is gone")
        end
    end
end

-- Stop the current process (if any). notify: show a stopped/saved notification.
function stopProcess(reason, notify)
    if proc == nil then return end
    if notify then proc.notifyOnStop = true end
    if state == "stopping" then return end

    log(`stopping gsr ({reason})`)
    setState("stopping")
    proc.stopSentAt = noctalia.nowMs()
    if proc.pid ~= nil then
        gsr.signal(proc.pid, "INT")
    end
end

-- restart: nil for a user/auto start, or { from, to } when restarting after a
-- resize (used for the single "restarted" notification).
function startProcess(mode, session, restart)
    if proc ~= nil then
        log("start refused: a gsr process is still running")
        return false
    end
    if not available or not ready then
        log(`start refused: available={available} ready={ready}`)
        noctalia.notifyError(tr(if mode == "replay" then "notify.replay-failed" else "notify.recording-failed"), tr("notify.unavailable"))
        return false
    end

    local dir = outputDirectory()
    noctalia.mkdirAll(dir)
    local output = dir
    if mode == "record" then
        local pattern = cfg("filename_pattern") or "runelite_{character}_%Y%m%d_%H%M%S"
        output = `{dir}/{formatFilename(pattern, session.character)}.mp4`
    end

    local args, err = gsr.buildArgs({
        mode = mode,
        output = output,
        audioSources = audioSources(),
        ipc = gsr.hasCli(),
    })
    if args == nil then
        log(`start aborted: {err}`)
        noctalia.notifyError(tr(if mode == "replay" then "notify.replay-failed" else "notify.recording-failed"), err)
        return false
    end

    local opts = windowOptions()
    local _, perr = picker.writeRequest(session, opts.classPattern, opts.excludeTitle)
    if perr ~= nil then
        log(`could not write picker request: {perr}`)
    end

    local token = gsr.launch(dataDir, args)
    if token == nil then
        log("start aborted: could not launch gsr")
        noctalia.notifyError(tr(if mode == "replay" then "notify.replay-failed" else "notify.recording-failed"), tr("notify.launch-failed"))
        return false
    end

    proc = {
        token = token,
        pid = nil,
        mode = mode,
        sessionId = session.id,
        character = session.character,
        output = output,
        launchedAt = noctalia.nowMs(),
        statusCheckAt = 0,
        restart = restart,
        -- Resize watching: frame size at start, last size seen, and since when.
        baseSize = frameSize(session),
        seenSize = frameSize(session),
        seenSince = noctalia.nowMs(),
        resized = false,
    }
    log(`starting {mode} of {describe(session)} -> {output}`)
    log(`gsr args: {table.concat(args, " ")}`)
    setState("starting")
    return true
end

local function markStarted()
    if state ~= "starting" or proc == nil then return end
    setState("active")
    local s = findSession(proc.sessionId)
    log(`{proc.mode} active (pid {proc.pid}){if s then " for " .. describe(s) else ""}`)
    if proc.restart ~= nil then
        -- One notification per restart, and only once the new capture runs.
        noctalia.notify(tr("notify.restarted-after-resize"), `{proc.restart.from} → {proc.restart.to}`)
    elseif proc.mode == "replay" then
        noctalia.notify(tr("notify.replay-active"), if proc.character then proc.character else nil)
    end
end

-- Per-tick process supervision.
local function superviseProcess()
    if proc == nil then return end
    local now = noctalia.nowMs()

    if proc.pid == nil then
        proc.pid = gsr.readPid(dataDir, proc.token)
        if proc.pid == nil then
            if now - proc.launchedAt > PID_WAIT_MS then
                log("gsr did not report a pid; treating launch as failed")
                gsr.logTail(log, "launch failed")
                onProcessExit()
            end
            return
        end
        log(`gsr pid {proc.pid}`)
        if state == "stopping" then
            -- A stop was requested before the pid was known.
            gsr.signal(proc.pid, "INT")
            proc.stopSentAt = now
        end
    end

    if not gsr.isAlive(proc.pid) then
        onProcessExit()
        return
    end

    if state == "starting" then
        if now - proc.launchedAt < STARTED_MIN_MS then
            -- too early to call it started
        elseif gsr.hasCli() then
            if not proc.statusPending and now >= proc.statusCheckAt then
                proc.statusPending = true
                proc.statusCheckAt = now + STATUS_POLL_MS
                local p = proc
                gsr.cli({ "status" }, 2000, function(ok, stdout)
                    p.statusPending = false
                    if proc == p and ok and stdout:find("running", 1, true) and not stdout:find("not running", 1, true) then
                        markStarted()
                    end
                end)
            end
        else
            markStarted()
        end
    elseif state == "stopping" then
        if not proc.killed and proc.stopSentAt and now - proc.stopSentAt >= KILL_AFTER_MS then
            log(`gsr {proc.pid} did not exit after SIGINT; sending SIGKILL`)
            proc.killed = true
            gsr.signal(proc.pid, "KILL")
        end
    end
end

-- ── Session choice ───────────────────────────────────────────────────────

-- arg: nil/"" (automatic), a session id, a window address, or a character name.
local function resolveSession(arg)
    if #sessions == 0 then return nil end
    if type(arg) == "string" and arg ~= "" then
        local wanted = looseName(arg)
        for _, s in sessions do
            if s.id == arg or (s.address or ""):lower() == wanted
                or (s.character ~= nil and looseName(s.character) == wanted) then
                return s
            end
        end
        return nil
    end
    for _, s in sessions do
        if s.focused then return s end
    end
    return sessions[1]
end

-- ── Actions ──────────────────────────────────────────────────────────────

local function startCapture(mode, sessionArg)
    local session = resolveSession(sessionArg)
    if session == nil then
        log(`no RuneLite session to record{if sessionArg and sessionArg ~= "" then ` (wanted '{sessionArg}')` else ""}`)
        noctalia.notify(tr("notify.no-session"))
        return
    end
    if proc == nil then
        startProcess(mode, session)
        return
    end
    if state ~= "stopping" and proc.mode == mode and proc.sessionId == session.id then
        queued = nil
        log(`{mode} already running for {describe(session)}`)
        return
    end
    -- Start once the current process is gone; the newest request wins.
    queued = { mode = mode, sessionId = session.id }
    log(`queued {mode} of {describe(session)}`)
    stopProcess(`switching to {mode} of {describe(session)}`, false)
end

-- What will be running once pending work is done: queued start first, else the
-- live process unless it is being stopped.
local function effectiveMode()
    if queued ~= nil then return queued.mode end
    if proc ~= nil and not proc.orphan and state ~= "stopping" then return proc.mode end
    return nil
end

local function saveReplay()
    if proc == nil or proc.mode ~= "replay" or state ~= "active" then
        noctalia.notify(tr("notify.not-replaying"))
        return
    end
    if saving then
        log("save already in progress")
        return
    end

    if not gsr.hasCli() then
        log("saving replay (SIGUSR1)")
        gsr.signal(proc.pid, "USR1")
        noctalia.notify(tr("notify.replay-saved"))
        return
    end

    saving = true
    log("saving replay (gsr-cli save-replay)")
    gsr.cli({ "save-replay" }, SAVE_TIMEOUT_MS, function(ok, stdout, stderr)
        saving = false
        local path = nil
        for line in stdout:gmatch("[^\n]+") do
            local trimmed = noctalia.string.trim(line)
            if trimmed:sub(1, 1) == "/" then path = trimmed end
        end
        if not ok then
            log(`save-replay failed: {noctalia.string.trim(stderr)} {noctalia.string.trim(stdout)}`)
            noctalia.notifyError(tr("notify.save-failed"), noctalia.string.trim(stderr))
            return
        end
        log(`replay saved: {path or noctalia.string.trim(stdout)}`)
        noctalia.notify(tr("notify.replay-saved"), if path then basename(path) else nil)
        if path and cfg("copy_to_clipboard") then copyToClipboard(path) end
    end)
end

local function stopCapture(mode)
    if queued ~= nil and (mode == nil or queued.mode == mode) then
        log(`cancelled queued {queued.mode}`)
        queued = nil
    end
    if proc == nil or proc.orphan or (mode ~= nil and proc.mode ~= mode) then return end
    stopProcess("user request", true)
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

-- Called after every session poll. A frame-size change freezes the portal
-- stream, so once the size has been stable for resize_settle seconds the
-- capture is restarted (or stopped). Every new size resets the wait, so a drag
-- gives one restart. Returning to the original size still counts: the stream
-- may have frozen in between. A move to another monitor or workspace with the
-- same frame size is not a change.
local function watchSize()
    if proc == nil or proc.orphan or queued ~= nil then return end
    if state ~= "starting" and state ~= "active" then return end
    local s = findSession(proc.sessionId)
    if s == nil then return end

    local now = noctalia.nowMs()
    local size = frameSize(s)
    if size ~= proc.seenSize then
        log(`frame size changed: {proc.seenSize} -> {size} (waiting for it to settle)`)
        proc.seenSize = size
        proc.seenSince = now
        proc.resized = true
        return
    end
    if not proc.resized then return end

    local settleSeconds = math.clamp(math.floor(tonumber(cfg("resize_settle")) or 3), 1, 30)
    if now - proc.seenSince < settleSeconds * 1000 then return end
    proc.resized = false

    local from = proc.baseSize
    if cfg("on_resize") == "stop" then
        log(`window resized {from} -> {size}; stopping (on_resize = stop)`)
        stopProcess(`window resized {from} -> {size}`, false)
        noctalia.notify(tr("notify.stopped-after-resize"), `{from} → {size}`)
        return
    end
    log(`window resized {from} -> {size}; restarting {proc.mode}`)
    queued = { mode = proc.mode, sessionId = s.id, restart = { from = from, to = size } }
    stopProcess(`restart after resize {from} -> {size}`, false)
end

local function onSessionsUpdated()
    if queued ~= nil and findSession(queued.sessionId) == nil then
        log("queued start dropped: its session closed")
        queued = nil
    end
    if proc ~= nil and not proc.orphan and state ~= "stopping" and findSession(proc.sessionId) == nil then
        stopProcess("recorded session closed", true)
    end
    watchSize()
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
        onSessionsUpdated()
        publishStatus()
    end)
end

-- ── Startup ──────────────────────────────────────────────────────────────

local function checkPicker(notifyIfMissing)
    pickerConfigured = picker.isConfigured(dataDir)
    if pickerConfigured then return end
    local current = picker.configuredPicker()
    log(`portal picker not configured (custom_picker_binary = {current or "unset"}, expected {picker.installedPath(dataDir)})`)
    -- Once per Noctalia session, not on every script reload.
    if notifyIfMissing and not noctalia.state.get("picker-warned") then
        noctalia.state.set("picker-warned", true)
        noctalia.notify(tr("notify.picker-missing"), tr("notify.picker-missing-body"))
    end
end

local function adoptOrphan()
    -- A gsr from a previous runtime of this service (reload) may still be
    -- shutting down. Track it as stopping so nothing new starts until it is gone.
    local pid = gsr.readPid(dataDir, nil)
    if pid == nil or not gsr.isAlive(pid) then return end
    log(`found gsr {pid} from a previous run; stopping it`)
    proc = { pid = pid, orphan = true, mode = nil, launchedAt = noctalia.nowMs() }
    state = "stopping"
    proc.stopSentAt = noctalia.nowMs()
    gsr.signal(pid, "INT")
end

local function initialize()
    local hasGsr = noctalia.commandExists("gpu-screen-recorder")
    local hasHyprland = windows.available()
    if not hasGsr then log("gpu-screen-recorder not found on PATH; recording unavailable") end
    if not hasHyprland then log("Hyprland not detected (hyprctl or HYPRLAND_INSTANCE_SIGNATURE missing)") end
    if dataDir == nil then log("plugin data dir unavailable") end
    available = hasGsr and hasHyprland and dataDir ~= nil
    log(`service started (available={available}, gsr-cli={gsr.hasCli()})`)
    if not available then
        publishStatus()
        return
    end

    adoptOrphan()

    -- Recording needs the runelite-gsr symlink. A failed picker install only
    -- means the portal dialog is shown instead of an automatic selection.
    gsr.install(dataDir, function(ok, err)
        if not ok then log(`runelite-gsr symlink setup failed: {err or "?"}`) end
        ready = ok
        publishStatus()
    end)
    picker.install(dataDir, function(ok, err)
        if not ok then log(`picker setup failed: {err or "?"}`) end
        checkPicker(true)
        publishStatus()
    end)
end

-- ── Callbacks ────────────────────────────────────────────────────────────

function update()
    if available == nil then
        initialize()
    end
    if not available then return end
    picker.tick()
    superviseProcess()
    if noctalia.nowMs() >= nextPollAt then
        poll()
    end
    publishStatus()
end

function onConfigChanged()
    windows.resetMatchCache()
    nextPollAt = 0
    publishStatus()
end

function onIpc(event, payload)
    local arg = if type(payload) == "string" then noctalia.string.trim(payload)
        elseif type(payload) == "table" then payload.session else nil
    local shown = if arg and arg ~= "" then ` '{(arg:gsub("%c", "?"))}'` else ""
    log(`ipc '{event}'{shown} (state={state})`)

    if event == "replay-start" then
        startCapture("replay", arg)
    elseif event == "replay-stop" then
        stopCapture("replay")
    elseif event == "replay-toggle" then
        if effectiveMode() == "replay" then stopCapture("replay") else startCapture("replay", arg) end
    elseif event == "save" or event == "replay-save" then
        saveReplay()
    elseif event == "record-toggle" then
        if effectiveMode() == "record" then stopCapture("record") else startCapture("record", arg) end
    elseif event == "setup-picker" then
        local ok, msg = picker.setup(dataDir)
        if ok then
            log(`wrote custom_picker_binary to {msg}`)
            noctalia.notify(tr("notify.picker-configured"), tr("notify.picker-configured-body"))
        else
            log(`setup-picker failed: {msg}`)
            noctalia.notifyError(tr("notify.picker-setup-failed"), msg)
        end
        checkPicker(false)
        publishStatus()
    elseif event == "sessions" then
        if #sessions == 0 then log("no RuneLite sessions") end
        for i, s in sessions do
            local mark = if proc and proc.sessionId == s.id then " (recording)" elseif s.focused then " (focused)" else ""
            log(`session {i}: {describe(s)}{mark}`)
        end
    else
        log(`unknown command '{event}'`)
    end
end

function onExit(_signal, reason)
    if proc ~= nil and proc.pid ~= nil then
        log(`stopping gsr {proc.pid} (service exit: {reason or "?"})`)
        gsr.stopDetached(proc.pid)
    end
end

-- The widget, panel and shortcut drive the service through this channel.
noctalia.state.watch("command", function(cmd)
    local action = if type(cmd) == "table" then cmd.action else cmd
    if type(action) == "string" then
        onIpc(action, if type(cmd) == "table" then cmd else nil)
    end
end)

publishStatus()
