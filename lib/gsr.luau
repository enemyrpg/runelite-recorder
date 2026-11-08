--!nonstrict
-- gpu-screen-recorder process handling.
--
-- gsr runs through a symlink named "runelite-gsr", so both /proc/<pid>/comm and
-- argv[0] differ from "gpu-screen-recorder". noctalia/screen_recorder finds and
-- signals gsr by name; with a different name it neither adopts nor kills ours.
--
-- The process is only ever addressed by pid. It is launched detached through
--   sh -c 'echo "<token> $$" > pidfile; exec runelite-gsr ...'
-- so the pid in the file is gsr itself. runAsync callbacks time out after at most
-- 60 s, so they cannot report when a long-running gsr exits; liveness is read
-- from /proc/<pid>/stat instead (no subprocess needed).

local M = {}

local PROCESS_NAME = "runelite-gsr"

-- Wrapper arguments: <pidfile> <token> <logfile> <gsr argv...>
local LAUNCH_SCRIPT = [[
pidfile=$1; token=$2; logfile=$3; shift 3
printf '=== runelite-gsr %s ===\n%s\n' "$(date '+%F %T')" "$*" > "$logfile"
printf '%s %s\n' "$token" "$$" > "$pidfile"
exec "$@" >> "$logfile" 2>&1 < /dev/null
]]

-- ── Paths ────────────────────────────────────────────────────────────────

function M.binaryPath(dataDir)
    return `{dataDir}/bin/{PROCESS_NAME}`
end

function M.pidFilePath(dataDir)
    return `{dataDir}/gsr.pid`
end

function M.ipcSocketPath()
    local dir = noctalia.getenv("XDG_RUNTIME_DIR")
    if dir == nil or dir == "" then dir = "/tmp" end
    return `{dir}/runelite-recorder-gsr.sock`
end

function M.logDir()
    local base = noctalia.getenv("XDG_STATE_HOME")
    if base == nil or base == "" then base = "~/.local/state" end
    return noctalia.expandPath(`{base}/noctalia/runelite_recorder`)
end

function M.logPath()
    return `{M.logDir()}/gsr.log`
end

function M.hasCli()
    return noctalia.commandExists("gsr-cli")
end

-- Create (or refresh) the runelite-gsr symlink to the native gpu-screen-recorder.
-- callback(ok, err)
function M.install(dataDir, callback)
    noctalia.mkdirAll(`{dataDir}/bin`)
    noctalia.mkdirAll(M.logDir())
    local script = [[
gsr=$(command -v gpu-screen-recorder) || { echo "gpu-screen-recorder not found" >&2; exit 1; }
gsr=$(readlink -f "$gsr")
ln -sfn "$gsr" "$1"
]]
    local launched = noctalia.runAsync({ "sh", "-c", script, "install", M.binaryPath(dataDir) }, function(result)
        if result.exitCode == 0 then
            callback(true, nil)
        else
            callback(false, noctalia.string.trim(result.stderr or "symlink failed"))
        end
    end, 5000)
    if not launched then
        callback(false, "could not launch symlink setup")
    end
end

-- ── Command line ─────────────────────────────────────────────────────────

local function cfg(key)
    return noctalia.getConfig(key)
end

local function oneOf(value, allowed, default)
    return if table.find(allowed, value) then value else default
end

local function scaledVideoQp(codec, qp)
    return qp * (if codec == "vp8" then 2 elseif codec == "av1" or codec == "vp9" then 4 else 1)
end

local function appendAll(list, items)
    for _, item in items do
        table.insert(list, item)
    end
end

function M.videoCodec()
    local codec = oneOf(cfg("video_codec"), { "h264", "hevc", "av1", "vp8", "vp9" }, "h264")
    if cfg("video_encoder") == "cpu" and codec ~= "h264" then
        return "h264", `cpu encoder forces h264 (configured {codec})`
    end
    return codec, nil
end

local function bitrateArgs(codec)
    local mode = oneOf(cfg("video_bitrate_mode"), { "qp", "vbr", "cbr" }, "qp")
    if mode == "qp" then
        local qp = tonumber(cfg("video_qp")) or 25
        return { "-bm", "qp", "-ffmpeg-video-opts", `qp={scaledVideoQp(codec, qp)}` }, nil
    elseif mode == "vbr" then
        return { "-bm", "vbr", "-q", oneOf(cfg("video_quality"), { "medium", "high", "very_high", "ultra" }, "very_high") }, nil
    end
    local bitrate = tonumber(cfg("video_bitrate"))
    if not bitrate or bitrate <= 0 or bitrate ~= math.floor(bitrate) then
        return nil, `invalid video bitrate: {cfg("video_bitrate")}`
    end
    return { "-bm", "cbr", "-q", tostring(bitrate) }, nil
end

-- audioSources: list of gsr -a values (already resolved by the caller), may be empty.
local function audioArgs(audioSources)
    if #audioSources == 0 then return {} end
    local args = { "-ac", oneOf(cfg("audio_codec"), { "opus", "aac", "flac" }, "opus") }
    local bitrate = cfg("audio_bitrate")
    if type(bitrate) == "number" and bitrate > 0 then
        appendAll(args, { "-ab", tostring(math.floor(bitrate)) })
    end
    for _, source in audioSources do
        appendAll(args, { "-a", source })
    end
    return args
end

-- opts: {
--   mode = "replay" | "record",
--   output = directory (replay) or file path (record),
--   audioSources = { string },
--   ipc = boolean,
--   saveScript = path of the -sc script, or nil,
-- }
-- Returns argv (without the binary) or nil, err.
function M.buildArgs(opts)
    local codec = M.videoCodec()
    local bitrate, err = bitrateArgs(codec)
    if bitrate == nil then return nil, err end

    local fps = math.floor(tonumber(cfg("frame_rate")) or 60)
    local args = { "-w", "portal" }
    if opts.mode == "replay" then
        appendAll(args, { "-c", "mp4" })
    end
    appendAll(args, {
        "-fm", oneOf(cfg("frame_rate_mode"), { "vfr", "cfr" }, "vfr"),
        "-f", tostring(fps),
        "-k", codec,
    })
    if cfg("video_encoder") == "cpu" then
        appendAll(args, { "-encoder", "cpu" })
    end
    appendAll(args, audioArgs(opts.audioSources or {}))
    appendAll(args, bitrate)
    appendAll(args, {
        "-cursor", if cfg("show_cursor") then "yes" else "no",
        "-cr", oneOf(cfg("color_range"), { "limited", "full" }, "limited"),
    })
    local res = cfg("resolution")
    if type(res) == "string" and res:match("^%d+x%d+$") then
        appendAll(args, { "-s", res })
    end
    if opts.mode == "replay" then
        local duration = math.floor(tonumber(cfg("replay_duration")) or 30)
        appendAll(args, {
            "-r", tostring(duration),
            "-replay-storage", oneOf(cfg("replay_storage"), { "ram", "disk" }, "ram"),
        })
    end
    -- Never reuse a stored portal session: each start must go through the picker.
    appendAll(args, { "-restore-portal-session", "no" })
    if opts.ipc then
        appendAll(args, { "-ipc", M.ipcSocketPath() })
    end
    if opts.saveScript then
        appendAll(args, { "-sc", opts.saveScript })
    end
    appendAll(args, { "-v", "no", "-o", opts.output })
    return args, nil
end

-- ── Process ──────────────────────────────────────────────────────────────

-- Launch gsr detached. Returns the token to look for in the pid file.
function M.launch(dataDir, args)
    local token = `{noctalia.nowMs()}-{math.random(1, 1e9)}`
    local pidFile = M.pidFilePath(dataDir)
    noctalia.removeFile(pidFile)
    noctalia.removeFile(M.ipcSocketPath())
    local argv = { "sh", "-c", LAUNCH_SCRIPT, "runelite-recorder", pidFile, token, M.logPath(), M.binaryPath(dataDir) }
    appendAll(argv, args)
    if not noctalia.runAsync(argv) then
        return nil
    end
    return token
end

-- The pid written by the launch with this token, or nil if not there yet.
-- With no token, any pid in the file (used to find an orphan after a reload).
function M.readPid(dataDir, token)
    local contents = noctalia.readFile(M.pidFilePath(dataDir))
    if contents == nil then return nil end
    local fileToken, pid = contents:match("^(%S+)%s+(%d+)")
    if pid == nil then return nil end
    if token ~= nil and fileToken ~= token then return nil end
    return tonumber(pid)
end

-- True while pid is a live (non-zombie) runelite-gsr process.
function M.isAlive(pid)
    if pid == nil then return false end
    local stat = noctalia.readFile(`/proc/{pid}/stat`)
    if stat == nil then return false end
    local comm, state = stat:match("^%d+ %((.*)%) (%S)")
    return comm == PROCESS_NAME and state ~= "Z" and state ~= "X"
end

-- Send a signal to our own pid only, after checking it is still ours.
function M.signal(pid, signal)
    if not M.isAlive(pid) then return false end
    noctalia.runAsync({ "kill", "-s", signal, tostring(pid) })
    return true
end

-- Fire-and-forget stop that survives this runtime going away (onExit):
-- SIGINT, then SIGKILL after 3 s if the same process is still there.
function M.stopDetached(pid)
    if not M.isAlive(pid) then return end
    local script = [[
kill -s INT "$1" 2>/dev/null || exit 0
sleep 3
[ "$(cat "/proc/$1/comm" 2>/dev/null)" = "$2" ] && kill -s KILL "$1" 2>/dev/null
exit 0
]]
    noctalia.runAsync({ "sh", "-c", script, "stop", tostring(pid), PROCESS_NAME })
end

-- gsr-cli command against our socket. callback(ok, stdout, stderr)
function M.cli(args, timeoutMs, callback)
    local argv = { "gsr-cli", "-ipc", M.ipcSocketPath() }
    appendAll(argv, args)
    local launched = noctalia.runAsync(argv, function(result)
        callback(result.exitCode == 0 and not result.timedOut, result.stdout or "", result.stderr or "")
    end, timeoutMs)
    if not launched then
        callback(false, "", "could not launch gsr-cli")
    end
end

-- Echo the tail of gsr.log into the Noctalia log.
function M.logTail(log, reason)
    local contents = noctalia.readFile(M.logPath())
    if contents == nil or contents == "" then
        log(`{reason}; no gpu-screen-recorder output was captured`)
        return
    end
    if #contents > 1500 then
        contents = contents:sub(-1500)
    end
    log(`{reason}; last gpu-screen-recorder output:`)
    for line in contents:gmatch("[^\n]+") do
        log(`  {line}`)
    end
end

function M.portalCancelled()
    local contents = noctalia.readFile(M.logPath())
    if contents == nil then return false end
    return contents:find("canceled by the user", 1, true) ~= nil
        or contents:find("cancelled by the user", 1, true) ~= nil
end

return M
