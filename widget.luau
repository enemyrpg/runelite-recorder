--!nonstrict
-- RuneLite Recorder - bar widget (thin presentation client).
--
-- Mirrors the service's "status" and drives it through the "command" channel.
-- Each mouse button runs the action chosen in its setting (left_click,
-- right_click, middle_click): select_session | save_replay | toggle_replay |
-- toggle_recording | none.

local status = nil

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

local function cfg(key)
    return noctalia.getConfig(key)
end

local function send(action)
    noctalia.state.set("command", { action = action, nonce = noctalia.nowMs() })
end

-- unavailable | no_runelite | ready | starting | recording | replaying
local function displayState(st)
    if type(st) ~= "table" or not st.available then return "unavailable" end
    if st.state == "starting" or st.state == "stopping" then return "starting" end
    if st.state == "active" then
        return if st.mode == "record" then "recording" else "replaying"
    end
    if #(st.sessions or {}) == 0 then return "no_runelite" end
    return "ready"
end

local DEFAULT_GLYPHS = {
    unavailable = "video-off",
    no_runelite = "device-gamepad-2",
    ready = "video",
    starting = "video",
    recording = "player-record-filled",
    replaying = "repeat",
}

local function glyphFor(name)
    local configured = cfg(`glyph_{name}`)
    if type(configured) == "string" and configured ~= "" then
        return configured
    end
    return DEFAULT_GLYPHS[name]
end

local function recordedCharacter(st)
    for _, s in st.sessions or {} do
        if s.id == st.recordingSession then
            return s.character or tr("panel.not-logged-in")
        end
    end
    return nil
end

local function audioLabel(source)
    if type(source) ~= "string" or source == "" then return "?" end
    return tr(`settings.audio_source.options.{source}`)
end

local function apply()
    local st = if type(status) == "table" then status else {}
    local ds = displayState(status)

    barWidget.setGlyph(glyphFor(ds))
    if ds == "recording" then
        barWidget.setGlyphColor("error")
        barWidget.setColor("error")
    elseif ds == "replaying" then
        barWidget.setGlyphColor("secondary")
        barWidget.setColor("secondary")
    elseif ds == "starting" then
        barWidget.setGlyphColor("primary")
        barWidget.setColor("primary")
    elseif ds == "ready" then
        barWidget.setGlyphColor("on_surface")
        barWidget.setColor("on_surface")
    else
        barWidget.setGlyphColor("on_surface_variant")
        barWidget.setColor("on_surface_variant")
    end

    local hide = cfg("hide_when_not_running") ~= false
    local running = ds ~= "unavailable" and ds ~= "no_runelite"
    barWidget.setVisible(running or not hide)

    local rows = {
        { key = tr("widget.tooltip.state"), value = tr(`widget.state.{ds}`) },
    }
    local character = recordedCharacter(st)
    if character ~= nil and (ds == "recording" or ds == "replaying" or ds == "starting") then
        table.insert(rows, { key = tr("widget.tooltip.character"), value = character })
    end
    if ds == "replaying" then
        table.insert(rows, {
            key = tr("widget.tooltip.replay-length"),
            value = tr("widget.seconds", { seconds = st.replayDuration or "?" }),
        })
    end
    table.insert(rows, { key = tr("widget.tooltip.audio"), value = audioLabel(st.audioSource) })
    table.insert(rows, { key = tr("widget.tooltip.sessions"), value = tostring(#(st.sessions or {})) })
    if st.available and st.pickerConfigured == false then
        table.insert(rows, { key = tr("widget.tooltip.picker"), value = tr("widget.picker-missing") })
    end
    barWidget.setTooltip(rows)
end

local function run(settingKey, default)
    local action = cfg(settingKey)
    if type(action) ~= "string" or action == "" then action = default end

    if action == "select_session" then
        noctalia.togglePanel("fredrikj/runelite-recorder:sessions")
    elseif action == "save_replay" then
        -- The service shows a short notice when no replay buffer runs.
        send("save")
    elseif action == "toggle_replay" then
        send("replay-toggle")
    elseif action == "toggle_recording" then
        send("record-toggle")
    end
end

function onClick()
    run("left_click", "select_session")
end

function onRightClick()
    run("right_click", "save_replay")
end

function onMiddleClick()
    run("middle_click", "toggle_replay")
end

status = noctalia.state.get("status")
apply()
noctalia.state.watch("status", function(value)
    status = value
    apply()
end)

-- Settings (glyphs, hiding) are read on every apply; refresh periodically so a
-- change shows without waiting for the next status update.
function update()
    apply()
end
