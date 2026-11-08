--!nonstrict
-- RuneLite Recorder - session picker panel.
--
-- Lists the RuneLite sessions the service publishes on "status" and marks the
-- one being recorded. Clicking a session sends "select" over the "command"
-- channel, which moves the capture there (or starts the replay buffer).

local status = nil
local open = false
local closeButton = true

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

-- Every command carries a nonce so two identical clicks are both delivered.
local function send(action, session)
    noctalia.state.set("command", { action = action, session = session, nonce = noctalia.nowMs() })
end

local function stateLine(st)
    if not st.available then return tr("panel.unavailable") end
    if st.state == "starting" then return tr("panel.state-starting") end
    if st.state == "stopping" then return tr("panel.state-stopping") end
    if st.state ~= "active" then return tr("panel.state-idle") end

    local character = tr("panel.not-logged-in")
    for _, s in st.sessions or {} do
        if s.id == st.recordingSession and s.character then
            character = s.character
        end
    end
    return tr(if st.mode == "record" then "panel.state-record" else "panel.state-replay", { character = character })
end

local function sessionRow(s, recording)
    local name = s.character or tr("panel.not-logged-in")
    local details = tr("panel.details", {
        pid = s.pid or "?",
        workspace = s.workspace or "?",
        width = s.frameWidth or 0,
        height = s.frameHeight or 0,
    })
    return ui.row({
        key = s.id,
        gap = 12,
        align = "center",
        padding = 10,
        radius = 10,
        fill = if recording then "primary/0.15" else "surface_container",
        border = if recording then "primary" else nil,
        borderWidth = if recording then 1 else nil,
        tooltip = if recording then tr("panel.recording-here") else tr("panel.select-hint"),
        onClick = function()
            send("select", s.id)
        end,
    }, {
        ui.glyph({
            name = if recording then "player-record-filled" else "device-gamepad-2",
            size = 20,
            color = if recording then "error" else "on_surface_variant",
        }),
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = name, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
            ui.label({ text = details, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
        }),
    })
end

local function render()
    if not open then return end
    local st = if type(status) == "table" then status else { available = false, sessions = {} }
    local sessions = st.sessions or {}
    local active = st.state == "active" or st.state == "starting"
    local replaying = active and st.mode == "replay"

    local header = {
        ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    }
    if closeButton then
        table.insert(header, ui.button({ glyph = "x", variant = "ghost", onClick = function() panel.close() end }))
    end

    local rows = {}
    if #sessions == 0 then
        table.insert(rows, ui.label({ text = tr("panel.no-sessions"), color = "on_surface_variant" }))
    end
    for _, s in sessions do
        table.insert(rows, sessionRow(s, active and s.id == st.recordingSession))
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
        ui.row({ align = "center", gap = 8 }, header),
        ui.label({ text = stateLine(st), color = if active then "primary" else "on_surface_variant" }),
        ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" }, rows),
        ui.row({ gap = 8, justify = "end" }, {
            ui.button({
                text = tr(if replaying then "panel.stop-replay" else "panel.start-replay"),
                glyph = if replaying then "player-stop" else "player-play",
                variant = "outline",
                enabled = st.available == true and (replaying or #sessions > 0),
                onClick = function() send("replay-toggle") end,
            }),
            ui.button({
                text = tr("panel.save-replay"),
                glyph = "device-floppy",
                variant = "primary",
                enabled = replaying and st.state == "active",
                onClick = function() send("save") end,
            }),
        }),
    }))
end

function onOpen(_context)
    open = true
    closeButton = noctalia.getSetting("shell.show_close_buttons") ~= false
    status = noctalia.state.get("status")
    render()
end

function onClose()
    open = false
end

noctalia.state.watch("status", function(value)
    status = value
    render()
end)
