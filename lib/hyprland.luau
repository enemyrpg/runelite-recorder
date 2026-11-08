--!nonstrict
-- Hyprland window backend.
--
-- Every compositor-specific call lives in this module, so another compositor can
-- be supported later by providing a module with the same interface:
--
--   listSessions(opts, callback)  callback(sessions, err)
--   resetMatchCache()
--
-- A session is a client window whose class matches opts.classPattern and whose
-- title does not match opts.excludeTitle (both POSIX extended regexes, matched
-- case-insensitively). Hyprland reuses window addresses, so a session's identity
-- is address + pid, and each client process yields at most one session.

local M = {}

local HYPRCTL_TIMEOUT_MS = 3000
local MATCH_TIMEOUT_MS = 3000
local MATCH_CACHE_LIMIT = 256

-- Luau patterns are not regexes, so matching goes through grep -E. Results are
-- cached per (class, title) pair, which means grep only runs when a new window
-- or a new title shows up, not on every poll.
--
-- Arguments: <class regex> <title regex> then class/title pairs. Prints one line
-- per pair: "1" for a session, "0" otherwise.
local MATCH_SCRIPT = [[
cre=$1; tre=$2; shift 2
while [ "$#" -ge 2 ]; do
  if printf '%s\n' "$1" | grep -qiE -- "$cre" &&
     ! { [ -n "$tre" ] && printf '%s\n' "$2" | grep -qiE -- "$tre"; }; then
    echo 1
  else
    echo 0
  fi
  shift 2
done
]]

local matchCache = {}
local matchCacheSize = 0
local matchCacheKey = nil

function M.resetMatchCache()
    matchCache = {}
    matchCacheSize = 0
    matchCacheKey = nil
end

local function pairKey(class, title)
    return `{class}\0{title}`
end

local function runJson(argv, callback)
    local ok = noctalia.runAsync(argv, function(result)
        if result.exitCode ~= 0 or result.timedOut then
            callback(nil, `{argv[1]} {argv[3] or ""} failed (exit {result.exitCode})`)
            return
        end
        local value, err = noctalia.json.decode(result.stdout)
        if value == nil then
            callback(nil, `could not parse {argv[3] or "output"}: {err or "?"}`)
            return
        end
        callback(value, nil)
    end, HYPRCTL_TIMEOUT_MS)
    if not ok then
        callback(nil, `could not launch {argv[1]}`)
    end
end

-- Fills the cache for every pair in `windowPairs` that it does not know yet.
local function resolveMatches(opts, windowPairs, callback)
    local configKey = `{opts.classPattern}\0{opts.excludeTitle}`
    if configKey ~= matchCacheKey or matchCacheSize > MATCH_CACHE_LIMIT then
        M.resetMatchCache()
        matchCacheKey = configKey
    end

    local unknown = {}
    local seen = {}
    for _, p in windowPairs do
        local key = pairKey(p.class, p.title)
        if matchCache[key] == nil and not seen[key] then
            seen[key] = true
            table.insert(unknown, p)
        end
    end
    if #unknown == 0 then
        callback(nil)
        return
    end

    local argv = { "sh", "-c", MATCH_SCRIPT, "match", opts.classPattern, opts.excludeTitle }
    for _, p in unknown do
        table.insert(argv, p.class)
        table.insert(argv, p.title)
    end

    local ok = noctalia.runAsync(argv, function(result)
        local lines = {}
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            table.insert(lines, line)
        end
        if #lines ~= #unknown then
            callback(`window matching failed: {noctalia.string.trim(result.stderr or "")}`)
            return
        end
        for i, p in unknown do
            matchCache[pairKey(p.class, p.title)] = lines[i] == "1"
            matchCacheSize += 1
        end
        -- grep reports an invalid regex on stderr but still exits per pair.
        local stderr = noctalia.string.trim(result.stderr or "")
        callback(if stderr ~= "" then `window matching: {stderr}` else nil)
    end, MATCH_TIMEOUT_MS)
    if not ok then
        callback("could not launch window matcher")
    end
end

-- "RuneLite - <name>" when logged in, "RuneLite" otherwise.
local function characterFromTitle(title)
    local name = title:match("^RuneLite %- (.+)$")
    if name == nil then return nil end
    name = noctalia.string.trim(name)
    return if name ~= "" then name else nil
end

local function buildSessions(clients, monitors)
    local monitorById = {}
    local visibleWorkspaces = {}
    for _, m in monitors do
        if m.id ~= nil then
            monitorById[m.id] = m
        end
        -- An unused special workspace is reported with no id.
        for _, ws in { m.activeWorkspace, m.specialWorkspace } do
            if type(ws) == "table" and type(ws.id) == "number" and ws.id ~= 0 then
                visibleWorkspaces[ws.id] = true
            end
        end
    end

    local sessions = {}
    for _, c in clients do
        if matchCache[pairKey(c.class or "", c.title or "")] then
            local monitor = monitorById[c.monitor]
            local scale = if monitor and type(monitor.scale) == "number" then monitor.scale else 1
            local size = if type(c.size) == "table" then c.size else { 0, 0 }
            local workspace = if type(c.workspace) == "table" then c.workspace else {}
            table.insert(sessions, {
                id = `{c.address}/{c.pid}`,
                address = c.address,
                pid = c.pid,
                class = c.class,
                title = c.title,
                character = characterFromTitle(c.title or ""),
                width = size[1],
                height = size[2],
                scale = scale,
                -- What the portal stream delivers; a change here freezes the capture.
                frameWidth = math.floor(size[1] * scale + 0.5),
                frameHeight = math.floor(size[2] * scale + 0.5),
                monitor = if monitor then monitor.name else nil,
                workspace = workspace.name,
                workspaceId = workspace.id,
                visible = visibleWorkspaces[workspace.id] == true,
                focused = c.focusHistoryID == 0,
            })
        end
    end

    -- One session per client process. Java can map extra small windows with the
    -- same class (popups titled "win0", "win1", ...); keep the main one: a title
    -- starting with "RuneLite" wins, then the larger window.
    local byPid = {}
    for _, s in sessions do
        local best = byPid[s.pid]
        if best == nil then
            byPid[s.pid] = s
        else
            local sMain = (s.title or ""):match("^RuneLite") ~= nil
            local bMain = (best.title or ""):match("^RuneLite") ~= nil
            if (sMain and not bMain) or (sMain == bMain and s.width * s.height > best.width * best.height) then
                byPid[s.pid] = s
            end
        end
    end
    sessions = {}
    for _, s in byPid do
        table.insert(sessions, s)
    end

    -- Stable order: oldest client process first.
    table.sort(sessions, function(a, b)
        if a.pid ~= b.pid then return a.pid < b.pid end
        return a.address < b.address
    end)
    return sessions
end

-- opts: { classPattern: string, excludeTitle: string }
-- callback(sessions, err): sessions is nil on failure; err may be set as a
-- warning alongside a (possibly partial) result.
function M.listSessions(opts, callback)
    local clients, monitors = nil, nil
    local failed = false
    local remaining = 2

    local function finish()
        remaining -= 1
        if remaining > 0 or failed then return end

        local windowPairs = {}
        for _, c in clients do
            if type(c) == "table" and c.mapped ~= false then
                table.insert(windowPairs, { class = c.class or "", title = c.title or "" })
            end
        end
        resolveMatches(opts, windowPairs, function(warning)
            callback(buildSessions(clients, monitors), warning)
        end)
    end

    local function fail(err)
        if failed then return end
        failed = true
        callback(nil, err)
    end

    runJson({ "hyprctl", "-j", "clients" }, function(value, err)
        if value == nil then fail(err) return end
        clients = value
        finish()
    end)
    runJson({ "hyprctl", "-j", "monitors" }, function(value, err)
        if value == nil then fail(err) return end
        monitors = value
        finish()
    end)
end

function M.available()
    return noctalia.commandExists("hyprctl") and noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil
end

return M
