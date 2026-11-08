--!nonstrict
-- Portal picker integration (xdg-desktop-portal-hyprland custom_picker_binary).
--
-- Before gpu-screen-recorder starts with `-w portal`, the service writes a
-- one-shot request that tells scripts/runelite-share-picker which window to pick.
-- The picker is copied to the plugin data dir so its path stays stable no matter
-- how the plugin is installed.

local M = {}

local REQUEST_CLEANUP_MS = 20000
local XDPH_CONF = "~/.config/hypr/xdph.conf"

local pendingCleanup = nil -- { key, at }

local function runtimeDir()
    local dir = noctalia.getenv("XDG_RUNTIME_DIR")
    if dir == nil or dir == "" then
        dir = "/tmp"
    end
    return dir
end

function M.requestPath()
    return `{runtimeDir()}/runelite-recorder.pick`
end

function M.debugLogPath()
    return `{runtimeDir()}/runelite-recorder-picker.log`
end

-- Path of the installed picker, inside the plugin data dir.
function M.installedPath(dataDir)
    return `{dataDir}/bin/runelite-share-picker`
end

-- Copy the bundled picker to the data dir when it is missing or outdated.
-- callback(ok, err)
function M.install(dataDir, callback)
    local source, err = noctalia.readFile("scripts/runelite-share-picker")
    if source == nil then
        callback(false, `could not read bundled picker: {err or "?"}`)
        return
    end
    local target = M.installedPath(dataDir)
    noctalia.mkdirAll(`{dataDir}/bin`)
    if noctalia.readFile(target) ~= source then
        local ok, werr = noctalia.writeFile(target, source)
        if not ok then
            callback(false, `could not install picker: {werr or "?"}`)
            return
        end
    end
    local launched = noctalia.runAsync({ "chmod", "755", target }, function(result)
        callback(result.exitCode == 0, if result.exitCode == 0 then nil else "chmod failed on picker")
    end, 5000)
    if not launched then
        callback(false, "could not launch chmod")
    end
end

-- Write a one-shot request for one session. Returns the request key.
function M.writeRequest(session, classPattern, excludeTitle)
    local key = `{noctalia.nowMs()}-{math.random(1, 1e9)}`
    local contents = table.concat({
        key,
        session.address or "",
        session.title or "",
        classPattern or "",
        excludeTitle or "",
    }, "\n") .. "\n"
    local ok, err = noctalia.writeFile(M.requestPath(), contents)
    if not ok then
        return nil, err
    end
    pendingCleanup = { key = key, at = noctalia.nowMs() + REQUEST_CLEANUP_MS }
    return key, nil
end

-- Remove an unused request after a while, but only if it is still ours.
-- Called from the service tick.
function M.tick()
    if pendingCleanup == nil or noctalia.nowMs() < pendingCleanup.at then return end
    local key = pendingCleanup.key
    pendingCleanup = nil
    local contents = noctalia.readFile(M.requestPath())
    if contents ~= nil and contents:match("^[^\n]*") == key then
        noctalia.removeFile(M.requestPath())
        noctalia.log("runelite_recorder: removed unused picker request")
    end
end

-- The configured custom_picker_binary in xdph.conf, or nil.
function M.configuredPicker()
    local contents = noctalia.readFile(XDPH_CONF)
    if contents == nil then return nil end
    for line in contents:gmatch("[^\n]+") do
        if not line:match("^%s*#") then
            local value = line:match("^%s*custom_picker_binary%s*=%s*(.-)%s*$")
            if value ~= nil and value ~= "" then
                return noctalia.expandPath(value)
            end
        end
    end
    return nil
end

function M.isConfigured(dataDir)
    return M.configuredPicker() == M.installedPath(dataDir)
end

-- Point xdph.conf at the installed picker, keeping a backup of the old file.
-- Returns ok, message.
function M.setup(dataDir)
    local path = noctalia.expandPath(XDPH_CONF)
    local picker = M.installedPath(dataDir)
    local contents = noctalia.readFile(path) or ""

    if contents ~= "" then
        local backup = `{path}.bak-{noctalia.formatTime("%Y%m%d%H%M%S")}`
        local ok, err = noctalia.writeFile(backup, contents)
        if not ok then
            return false, `could not write backup {backup}: {err or "?"}`
        end
    end

    local replaced = false
    local lines = {}
    for line in (contents .. (if contents:sub(-1) == "\n" or contents == "" then "" else "\n")):gmatch("([^\n]*)\n") do
        if not replaced and not line:match("^%s*#") and line:match("^%s*custom_picker_binary%s*=") then
            local indent = line:match("^(%s*)")
            line = `{indent}custom_picker_binary = {picker}`
            replaced = true
        end
        table.insert(lines, line)
    end

    if not replaced then
        local inserted = false
        for i, line in lines do
            if line:match("^%s*screencopy%s*{") then
                table.insert(lines, i + 1, `    custom_picker_binary = {picker}`)
                inserted = true
                break
            end
        end
        if not inserted then
            if #lines > 0 and lines[#lines] ~= "" then
                table.insert(lines, "")
            end
            table.insert(lines, "screencopy {")
            table.insert(lines, `    custom_picker_binary = {picker}`)
            table.insert(lines, "}")
        end
    end

    local ok, err = noctalia.writeFile(path, table.concat(lines, "\n") .. "\n")
    if not ok then
        return false, `could not write {path}: {err or "?"}`
    end
    return true, path
end

return M
