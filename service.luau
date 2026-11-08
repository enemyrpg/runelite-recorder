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
local scripts = require("./lib/scripts.luau")

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
-- How long to wait for on-save.sh to report the final path of a saved clip.
local SAVED_WAIT_MS = 8000
local SAVED_POLL_MS = 250
-- Stands in for the character name in a recording's file name until it is
-- saved; on-save.sh replaces it with the name at that moment.
local RECORD_MARKER = "RLRCHAR"
local ON_SAVE_SCRIPT = "on-save.sh"
local DEFAULT_REPLAY_PATTERN = "replay_{character}_%Y%m%d_%H%M%S"

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

-- Automatic start (start_mode = auto). The user stopping the replay buffer
-- suppresses it until a new session appears or the user starts it again.
local autoSuppressed = false
local autoFailures = 0
local autoRetryAt = 0
local AUTO_MAX_FAILURES = 3
local AUTO_RETRY_MS = 10000

-- The last session closed while capturing: wait stop_grace seconds in case the
-- client restarts, then stop. { mode, untilMs }
local pendingResume = nil

-- Last character the user picked, persisted in the plugin data dir.
local lastCharacter = nil

local lastStatusJson = nil
local onSaveReady = false
local writtenCharacter = nil -- last value written to <data>/character
-- Clips waiting for on-save.sh: { original, deadline, nextCheck, callback }
local savedWaits = {}

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

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", [['"'"']]) .. "'"
end

-- Settings on-save.sh reads at save time (sourced as shell assignments).
local function writeSaveConf()
    if dataDir == nil then return end
    local replayPattern = cfg("replay_filename_pattern")
    if type(replayPattern) ~= "string" or replayPattern == "" then
        replayPattern = DEFAULT_REPLAY_PATTERN
    end
    local post = cfg("post_save_script")
    post = if type(post) == "string" and post ~= "" then noctalia.expandPath(post) else ""
    local lines = {
        `output_dir={shellQuote(outputDirectory())}`,
        `replay_pattern={shellQuote(replayPattern)}`,
        `record_marker={shellQuote(RECORD_MARKER)}`,
        `per_character_folder={if cfg("per_character_folder") then "1" else "0"}`,
        `post_save_script={shellQuote(post)}`,
    }
    noctalia.writeFile(`{dataDir}/save.conf`, table.concat(lines, "\n") .. "\n")
end

-- Current character of the recorded session, read by on-save.sh.
local function writeCharacter(character)
    local value = character or ""
    if value == writtenCharacter or dataDir == nil then return end
    writtenCharacter = value
    noctalia.writeFile(`{dataDir}/character`, value .. "\n")
end

-- Calls callback(finalPath) once on-save.sh has handled `original`, or with
-- `original` if it does not report back in time.
local function awaitSaved(original, callback)
    table.insert(savedWaits, {
        original = original,
        deadline = noctalia.nowMs() + SAVED_WAIT_MS,
        nextCheck = 0,
        callback = callback,
    })
end

local function superviseSaved()
    if #savedWaits == 0 then return end
    local now = noctalia.nowMs()
    local remaining = {}
    for _, w in savedWaits do
        local done = false
        if now >= w.nextCheck then
            w.nextCheck = now + SAVED_POLL_MS
            local marker = `{dataDir}/saved/{basename(w.original)}`
            local contents = noctalia.readFile(marker)
            if contents ~= nil and contents ~= "" then
                noctalia.removeFile(marker)
                done = true
                w.callback(noctalia.string.trim(contents))
            elseif now >= w.deadline then
                log(`on-save.sh did not report {basename(w.original)}; using the original path`)
                done = true
                w.callback(w.original)
            end
        end
        if not done then table.insert(remaining, w) end
    end
    savedWaits = remaining
end

local function copyToClipboard(path)
    local uri = "file://" .. path:gsub("%%", "%%25"):gsub(" ", "%%20"):gsub("'", "%%27"):gsub('"', "%%22")
    noctalia.copyToClipboard(uri, "text/uri-list")
end

local function lastCharacterPath()
    return `{dataDir}/last_character`
end

local function loadLastCharacter()
    local contents = noctalia.readFile(lastCharacterPath())
    if contents == nil then return nil end
    local name = noctalia.string.trim(contents)
    return if name ~= "" then name else nil
end

local function rememberCharacter(session)
    if session == nil or session.character == nil or session.character == lastCharacter then return end
    lastCharacter = session.character
    noctalia.writeFile(lastCharacterPath(), lastCharacter .. "\n")
    log(`remembered character '{lastCharacter}'`)
end

-- Session to use when none was named, following auto_session:
--   last_character  the remembered character if running, else focused, else first
--   focused         the focused RuneLite window, else first
--   first           the first session (oldest client)
-- excludeId skips one session (used when following the next one).
local function chooseSession(excludeId)
    local candidates = {}
    for _, sess in sessions do
        if sess.id ~= excludeId then table.insert(candidates, sess) end
    end
    if #candidates == 0 then return nil end

    local mode = cfg("auto_session")
    if mode ~= "first" and mode ~= "focused" and lastCharacter ~= nil then
        for _, sess in candidates do
            if sess.character ~= nil and looseName(sess.character) == looseName(lastCharacter) then
                return sess
            end
        end
    end
    if mode ~= "first" then
        for _, sess in candidates do
            if sess.focused then return sess end
        end
    end
    return candidates[1]
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
        startMode = if cfg("start_mode") == "manual" then "manual" else "auto",
        autoSuppressed = autoSuppressed,
        lastCharacter = lastCharacter,
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

-- PipeWire name of the RuneLite client's audio stream for gsr "app:<name>".
-- runelite_audio_app wins; otherwise it is detected from
-- `gpu-screen-recorder --list-application-audio` and remembered in the data
-- dir, because RuneLite only shows up there while it is playing sound.
local detectedAudioApp = nil
local audioDetectPending = false
local AUDIO_APP_PATTERNS = { "runelite", "java", "openjdk" }

local function audioAppCachePath()
    return `{dataDir}/audio_app`
end

local function configuredAudioApp()
    local value = cfg("runelite_audio_app")
    if type(value) == "string" then
        value = noctalia.string.trim(value)
        if value ~= "" then return value end
    end
    return nil
end

local function detectAudioApp()
    if audioDetectPending or configuredAudioApp() ~= nil then return end
    audioDetectPending = true
    local launched = noctalia.runAsync({ "gpu-screen-recorder", "--list-application-audio" }, function(result)
        audioDetectPending = false
        local found = nil
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            local name = noctalia.string.trim(line)
            local lower = name:lower()
            for _, pattern in AUDIO_APP_PATTERNS do
                if found == nil and lower:find(pattern, 1, true) then
                    found = name
                end
            end
        end
        if found ~= nil and found ~= detectedAudioApp then
            log(`RuneLite application audio: '{found}'`)
            detectedAudioApp = found
            noctalia.writeFile(audioAppCachePath(), found .. "\n")
        end
    end, 5000)
    if not launched then audioDetectPending = false end
end

local function loadAudioAppCache()
    local contents = noctalia.readFile(audioAppCachePath())
    if contents == nil then return end
    local name = noctalia.string.trim(contents)
    if name ~= "" then
        detectedAudioApp = name
        log(`remembered RuneLite application audio: '{name}'`)
    end
end

local function audioSources()
    local source = cfg("audio_source")
    if source == "none" then return {} end
    if source == "runelite" or source == "runelite_mic" then
        local app = configuredAudioApp() or detectedAudioApp
        if app == nil then
            log("no RuneLite application audio found yet (start a sound in RuneLite or set runelite_audio_app); "
                .. (if source == "runelite_mic" then "recording microphone only" else "recording without audio"))
            return if source == "runelite_mic" then { "default_input" } else {}
        end
        local spec = `app:{app}`
        return { if source == "runelite_mic" then `{spec}|default_input` else spec }
    end
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
        if p.mode == "record" then
            -- Every finished recording is renamed by on-save.sh; only notify
            -- when the user asked for the stop.
            local notify = p.notifyOnStop
            awaitSaved(p.output, function(path)
                noctalia.runAsync({ "test", "-s", path }, function(result)
                    if result.exitCode == 0 then
                        log(`recording saved: {path}`)
                        if notify then
                            noctalia.notify(tr("notify.recording-saved"), basename(path))
                        end
                        if cfg("copy_to_clipboard") then copyToClipboard(path) end
                    else
                        gsr.logTail(log, "recording stopped but no output file was found")
                        noctalia.notifyError(tr("notify.recording-failed"), tr("notify.stopped-early"))
                    end
                end, 5000)
            end)
        elseif p.mode == "replay" and p.notifyOnStop then
            noctalia.notify(tr("notify.replay-stopped"))
        end
    elseif findSession(p.sessionId) == nil then
        log(`gsr {p.pid} ended after its window closed`)
    elseif wasState == "starting" and gsr.portalCancelled() then
        log("window selection was cancelled in the portal dialog")
        autoSuppressed = true
    else
        autoFailures += 1
        autoRetryAt = noctalia.nowMs() + AUTO_RETRY_MS * autoFailures
        if autoFailures >= AUTO_MAX_FAILURES then
            log(`{autoFailures} failed starts in a row; automatic start paused until a new session appears`)
            autoSuppressed = true
        end
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

-- gsr arguments for a capture with the current settings.
local function captureArgs(mode, output)
    return gsr.buildArgs({
        mode = mode,
        output = output,
        audioSources = audioSources(),
        ipc = gsr.hasCli(),
        saveScript = if onSaveReady then scripts.installedPath(dataDir, ON_SAVE_SCRIPT) else nil,
    })
end

-- restart: nil for a user/auto start; { from, to } after a resize, or
-- { reason = "settings" } after a settings change (used for the single
-- "restarted" notification).
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
        output = `{dir}/{formatFilename(pattern, RECORD_MARKER)}.mp4`
    end

    detectAudioApp() -- refresh for the next start
    local args, err = captureArgs(mode, output)
    if not onSaveReady then
        log("on-save.sh is not installed; clips keep gsr's own names")
    end
    writeSaveConf()
    writeCharacter(session.character)
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
        argsKey = table.concat(args, "\0"),
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
    autoFailures = 0
    local s = findSession(proc.sessionId)
    log(`{proc.mode} active (pid {proc.pid}){if s then " for " .. describe(s) else ""}`)
    if proc.restart ~= nil and proc.restart.reason == "settings" then
        noctalia.notify(tr("notify.restarted-settings"))
    elseif proc.restart ~= nil then
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
    return chooseSession(nil)
end

-- ── Actions ──────────────────────────────────────────────────────────────

local function startCaptureOn(mode, session)
    pendingResume = nil
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

-- User-initiated start. A named session is remembered for last_character.
local function startCapture(mode, sessionArg)
    local session = resolveSession(sessionArg)
    if session == nil then
        log(`no RuneLite session to record{if sessionArg and sessionArg ~= "" then ` (wanted '{sessionArg}')` else ""}`)
        noctalia.notify(tr("notify.no-session"))
        return
    end
    if sessionArg ~= nil and sessionArg ~= "" then
        rememberCharacter(session)
    end
    autoSuppressed = false
    startCaptureOn(mode, session)
end

-- What will be running once pending work is done: queued start first, else the
-- live process unless it is being stopped.
local function effectiveMode()
    if queued ~= nil then return queued.mode end
    if proc ~= nil and not proc.orphan and state ~= "stopping" then return proc.mode end
    return nil
end

-- Switch the capture to another session (panel click, `select` IPC). When
-- nothing runs, this starts the replay buffer there.
local function selectSession(arg)
    local session = nil
    if arg == "next" then
        local current = if queued then queued.sessionId elseif proc then proc.sessionId else nil
        for i, sess in sessions do
            if sess.id == current then
                session = sessions[(i % #sessions) + 1]
                break
            end
        end
        session = session or sessions[1]
    else
        session = resolveSession(arg)
    end
    if session == nil then
        log(`select: no session matches '{arg or ""}'`)
        noctalia.notify(tr("notify.no-session"))
        return
    end
    rememberCharacter(session)
    autoSuppressed = false
    startCaptureOn(effectiveMode() or "replay", session)
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
        if path == nil then
            log(`replay saved: {noctalia.string.trim(stdout)}`)
            noctalia.notify(tr("notify.replay-saved"))
            return
        end
        awaitSaved(path, function(final)
            log(`replay saved: {final}`)
            noctalia.notify(tr("notify.replay-saved"), basename(final))
            if cfg("copy_to_clipboard") then copyToClipboard(final) end
        end)
    end)
end

local function stopCapture(mode)
    if mode ~= "record" then
        autoSuppressed = true
    end
    pendingResume = nil
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

    local appeared = {}
    for _, s in new do
        local prev = oldById[s.id]
        if prev == nil then
            log(`session appeared: {describe(s)}`)
            table.insert(appeared, s.id)
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
    return appeared
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
        -- Do not let start_mode = auto bring it straight back.
        autoSuppressed = true
        stopProcess(`window resized {from} -> {size}`, false)
        noctalia.notify(tr("notify.stopped-after-resize"), `{from} → {size}`)
        return
    end
    log(`window resized {from} -> {size}; restarting {proc.mode}`)
    queued = { mode = proc.mode, sessionId = s.id, restart = { from = from, to = size } }
    stopProcess(`restart after resize {from} -> {size}`, false)
end

local function maybeAutoStart()
    if cfg("start_mode") == "manual" or autoSuppressed or not ready then return end
    if proc ~= nil or queued ~= nil or pendingResume ~= nil or #sessions == 0 then return end
    if noctalia.nowMs() < autoRetryAt then return end
    local session = chooseSession(nil)
    if session == nil then return end
    log(`auto-starting replay buffer (auto_session = {cfg("auto_session") or "last_character"})`)
    startCaptureOn("replay", session)
end

-- The recorded session has closed: follow the next one, wait for the client
-- to come back, or stop.
local function onRecordedSessionClosed()
    local mode = proc.mode
    local closedId = proc.sessionId
    local follow = cfg("follow_next_session") ~= false
    local nextSession = if follow then chooseSession(closedId) else nil

    if nextSession ~= nil then
        if mode == "replay" then
            log(`recorded session closed; following {describe(nextSession)}`)
            queued = { mode = "replay", sessionId = nextSession.id }
            stopProcess("recorded session closed", false)
        else
            -- A recording belongs to one character; save it. Auto mode then
            -- starts the replay buffer on the next session.
            stopProcess("recorded session closed", true)
        end
    elseif #sessions == 0 then
        local grace = math.clamp(math.floor(tonumber(cfg("stop_grace")) or 5), 0, 120)
        log(`last session closed; stopping in {grace}s unless a client comes back`)
        pendingResume = { mode = mode, untilMs = noctalia.nowMs() + grace * 1000 }
    else
        stopProcess("recorded session closed", true)
    end
end

-- Runs every tick while waiting for a client to come back.
local function superviseResume()
    if pendingResume == nil then return end
    if #sessions > 0 then
        local session = chooseSession(nil)
        local mode = pendingResume.mode
        pendingResume = nil
        if session ~= nil then
            log(`client came back; resuming {mode} on {describe(session)}`)
            startCaptureOn(mode, session)
        end
        return
    end
    if noctalia.nowMs() >= pendingResume.untilMs then
        local mode = pendingResume.mode
        pendingResume = nil
        log("no RuneLite session came back; stopping")
        if proc ~= nil then
            stopProcess("no RuneLite session left", true)
        elseif mode == "replay" then
            noctalia.notify(tr("notify.replay-stopped"))
        end
    end
end

local function onSessionsUpdated(appeared)
    if #appeared > 0 then
        detectAudioApp()
    end
    if #appeared > 0 and autoSuppressed and pendingResume == nil then
        log("new session appeared; automatic start allowed again")
        autoSuppressed = false
        autoFailures = 0
        autoRetryAt = 0
    end
    if queued ~= nil and findSession(queued.sessionId) == nil then
        log("queued start dropped: its session closed")
        queued = nil
    end
    if proc ~= nil and not proc.orphan and state ~= "stopping" and pendingResume == nil
        and findSession(proc.sessionId) == nil then
        onRecordedSessionClosed()
    end
    superviseResume()
    watchSize()
    maybeAutoStart()
    if proc ~= nil and not proc.orphan then
        local s = findSession(proc.sessionId)
        if s ~= nil then
            if s.character ~= proc.character then
                log(`recorded character is now '{s.character or "unknown"}'`)
                proc.character = s.character
            end
            writeCharacter(s.character)
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

        local appeared = diffSessions(sessions, list)
        sessions = list
        nextPollAt = noctalia.nowMs() + (if #sessions > 0 then POLL_ACTIVE_MS else POLL_IDLE_MS)
        onSessionsUpdated(appeared)
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

    lastCharacter = loadLastCharacter()
    loadAudioAppCache()
    detectAudioApp()
    adoptOrphan()

    -- Recording needs the runelite-gsr symlink. A failed picker install only
    -- means the portal dialog is shown instead of an automatic selection.
    gsr.install(dataDir, function(ok, err)
        if not ok then log(`runelite-gsr symlink setup failed: {err or "?"}`) end
        ready = ok
        publishStatus()
    end)
    writeSaveConf()
    scripts.install(dataDir, ON_SAVE_SCRIPT, function(ok, err)
        if not ok then log(`on-save.sh setup failed: {err or "?"}`) end
        onSaveReady = ok
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
    superviseResume()
    superviseSaved()
    maybeAutoStart()
    if noctalia.nowMs() >= nextPollAt then
        poll()
    end
    publishStatus()
end

-- A running gsr keeps the arguments it was started with. When a settings
-- change alters them, restart the replay buffer so the change applies now. A
-- regular recording is not split in two; the change applies to the next one.
local function applySettingsToRunningCapture()
    if proc == nil or proc.orphan or queued ~= nil or proc.argsKey == nil then return end
    if state ~= "starting" and state ~= "active" then return end
    local output = if proc.mode == "replay" then outputDirectory() else proc.output
    local args = captureArgs(proc.mode, output)
    if args == nil or table.concat(args, "\0") == proc.argsKey then return end
    if proc.mode == "record" then
        log("settings changed; they apply to the next recording")
        return
    end
    local s = findSession(proc.sessionId)
    if s == nil then return end
    log("settings changed; restarting the replay buffer")
    queued = { mode = "replay", sessionId = s.id, restart = { reason = "settings" } }
    stopProcess("settings changed", false)
end

function onConfigChanged()
    writeSaveConf()
    detectAudioApp()
    windows.resetMatchCache()
    nextPollAt = 0
    applySettingsToRunningCapture()
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
    elseif event == "select" then
        selectSession(arg)
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
