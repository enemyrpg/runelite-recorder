--!nonstrict
-- RuneLite Recorder - control-center quick tile.
--
-- Mirrors the service's "status": active while the replay buffer or a
-- recording runs. Left click toggles the replay buffer, right click saves it.

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

local function send(action)
    noctalia.state.set("command", { action = action, nonce = noctalia.nowMs() })
end

local function applyStatus(st)
    local hasStatus = type(st) == "table"
    local available = hasStatus and st.available == true
    local active = hasStatus and (st.state == "active" or st.state == "starting")
    local recording = active and st.mode == "record"

    shortcut.setLabel(
        if recording then tr("shortcut.recording")
        elseif active then tr("shortcut.replay-active")
        else tr("shortcut.replay")
    )
    shortcut.setIcon(if recording then "player-record-filled" else "repeat", "video-off")
    shortcut.setActive(active)
    shortcut.setEnabled(available)
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)

function onClick()
    send("replay-toggle")
end

function onRightClick()
    send("save")
end
