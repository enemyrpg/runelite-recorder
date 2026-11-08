--!nonstrict
-- Installs bundled helper scripts (scripts/<name>) into <data dir>/bin.
--
-- External programs (xdph, gpu-screen-recorder) run these scripts, so they need
-- a stable, executable path that does not depend on how the plugin was
-- installed.

local M = {}

function M.installedPath(dataDir, name)
    return `{dataDir}/bin/{name}`
end

-- Copy scripts/<name> when missing or outdated and make it executable.
-- callback(ok, err)
function M.install(dataDir, name, callback)
    local source, err = noctalia.readFile(`scripts/{name}`)
    if source == nil then
        callback(false, `could not read bundled {name}: {err or "?"}`)
        return
    end
    local target = M.installedPath(dataDir, name)
    noctalia.mkdirAll(`{dataDir}/bin`)
    if noctalia.readFile(target) ~= source then
        local ok, werr = noctalia.writeFile(target, source)
        if not ok then
            callback(false, `could not install {name}: {werr or "?"}`)
            return
        end
    end
    local launched = noctalia.runAsync({ "chmod", "755", target }, function(result)
        callback(result.exitCode == 0, if result.exitCode == 0 then nil else `chmod failed on {name}`)
    end, 5000)
    if not launched then
        callback(false, "could not launch chmod")
    end
end

return M
