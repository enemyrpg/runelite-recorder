# RuneLite Recorder

RuneLite Recorder records **only the RuneLite window** (the Old School RuneScape
client) with `gpu-screen-recorder`, with a replay buffer as the main feature.
It finds RuneLite sessions on its own, selects the right window in the portal
without a dialog, restarts the capture when the window is resized (which
otherwise freezes the video), names clips after the logged-in character, and
can record the game's audio only.

It does not depend on how RuneLite is started (Bolt, the official launcher or
anything else).

## Plugin

| Field | Value |
| --- | --- |
| ID | `fredrikj/runelite-recorder` |
| Entries | Service: `service`; bar widget: `recorder`; panel: `sessions`; shortcut: `toggle` |

## Requirements

- **Hyprland.** Windows are found with `hyprctl`; other compositors are not supported.
- **[gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/about/)**, native
  (not the Flatpak). `gsr-cli` (shipped with it) is used to save replays and get
  the saved file's path; without it, signals are used instead.
- **xdg-desktop-portal-hyprland** (xdph) for window capture.

## Installation

Clone the repository into Noctalia's local plugin directory and enable it:

```sh
git clone https://github.com/EnemyRPG/runelite-recorder ~/.local/share/noctalia/plugins/runelite-recorder
noctalia msg plugins enable fredrikj/runelite-recorder
```

Then add the **RuneLite Recorder** widget to a bar and, if you like, the shortcut
to the Control Center.

## Portal picker setup

On Wayland, gpu-screen-recorder can only capture a single window through the
portal, and xdph normally asks which window to share. The plugin ships a picker
(`scripts/runelite-share-picker`, installed to the plugin data dir) that selects
the RuneLite window automatically. Before each start, the service leaves a
one-shot request with the window's address; the picker matches it by address,
then by title, then by class. Without a valid request (for example when a
browser shares the screen) it runs Hyprland's normal picker, so other screen
sharing works as before.

Point xdph at the picker once:

```sh
noctalia msg plugin fredrikj/runelite-recorder:service all setup-picker
systemctl --user restart xdg-desktop-portal-hyprland
```

`setup-picker` writes `custom_picker_binary` into `~/.config/hypr/xdph.conf`
(after saving a backup next to it). To do it by hand instead:

```
screencopy {
    custom_picker_binary = ~/.local/state/noctalia/plugins/data/fredrikj/runelite-recorder/bin/runelite-share-picker
}
```

The exact path is shown in the Noctalia log at startup when the picker is not
configured. Without the picker, recording still works, but the portal dialog
asks for the window every time.

## Usage

With the default `start_mode = auto`, the replay buffer starts when a RuneLite
session appears and stops when the last one closes (after `stop_grace`
seconds, in case the client restarts). If you stop the replay buffer yourself,
it stays off until a new session appears or you start it again.

**Sessions.** Every RuneLite client window (one per client process) is a
session. With several clients open, the `sessions` panel lists them with the
character name and marks the one being recorded; click one to move the capture
there. The chosen character is remembered and used next time
(`auto_session = last_character`). When the recorded client closes while others
run, the replay buffer moves to the next one (`follow_next_session`).

**Resizing.** gpu-screen-recorder's video freezes when the captured window
changes size (window size × monitor scale). The service checks the size every
second and restarts the capture once it has been stable for `resize_settle`
seconds, so dragging a window edge gives one restart. Moving the window to
another workspace or monitor with the same size and scale does not restart it.
A restart empties the replay buffer: the next clip starts at the restart.

**Saved clips** are named after the character logged in *when the clip is
saved*: `replay_<character>_<date>_<time>.mp4` by default, or `unknown` when no
character is logged in. Spaces become `_`.

**Game audio only.** `audio_source = runelite` records RuneLite's audio through
gpu-screen-recorder's application capture, so Discord, music and other programs
are left out. See [Known limitations](#known-limitations).

Widget controls (each button is configurable):

| Action | Default |
| --- | --- |
| Left click | Open the `sessions` panel (`select_session`). |
| Right click | Save the replay (`save_replay`). Shows a short notice when no replay buffer runs. |
| Middle click | Start/stop the replay buffer (`toggle_replay`). |

Shortcut controls:

| Action | Behavior |
| --- | --- |
| Left click | Start/stop the replay buffer. |
| Right click | Save the replay. |

The widget is hidden while no RuneLite session runs (`hide_when_not_running`).
Disabling or reloading the plugin, or exiting Noctalia, stops an active capture.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `start_mode` | `select` | `auto` | `auto` starts the replay buffer when a session appears; `manual` waits for you. |
| `auto_session` | `select` | `last_character` | Session used when none is chosen: `last_character` (remembered character, else focused, else first), `focused`, or `first`. |
| `follow_next_session` | `bool` | `true` | Move the replay buffer to the next session when the recorded client closes. |
| `stop_grace` | `int` | `5` | Seconds to wait after the last client closes before stopping (0–120). |
| `directory` | `folder` | `~/Videos/RuneLite` | Output folder. |
| `filename_pattern` | `string` | `runelite_{character}_%Y%m%d_%H%M%S` | Regular recordings: strftime pattern plus `{character}`, without extension. |
| `replay_filename_pattern` | `string` | `replay_{character}_%Y%m%d_%H%M%S` | Saved replays: strftime pattern plus `{character}`, applied at save time. |
| `per_character_folder` | `bool` | `false` | Save clips in `<directory>/<character>/`. |
| `post_save_script` | `file` | | Executable run after a clip is saved and renamed, with the final path and the type (`replay` or `regular`). |
| `copy_to_clipboard` | `bool` | `false` | Copy the saved clip's URI to the clipboard. |
| `replay_duration` | `int` | `30` | Replay buffer length in seconds (5–3600). |
| `replay_storage` | `select` | `ram` | Keep the replay buffer in `ram` or on `disk`. |
| `frame_rate` | `int` | `60` | Capture frame rate (1–240). |
| `frame_rate_mode` | `select` | `vfr` | `vfr` (variable) or `cfr` (constant). |
| `video_codec` | `select` | `h264` | `h264`, `hevc`, `av1`, `vp8` or `vp9`. |
| `video_encoder` | `select` | `gpu` | `gpu` (hardware) or `cpu` (software, always H.264). |
| `video_bitrate_mode` | `select` | `qp` | `qp` (constant quality), `vbr` or `cbr`. |
| `video_qp` | `int` | `25` | Quality for `qp` mode (0–51, lower is better). |
| `video_quality` | `select` | `very_high` | Quality for `vbr` mode. |
| `video_bitrate` | `string` | `20000` | Bitrate in kbps for `cbr` mode. |
| `resolution` | `string` | `original` | `original` or `WIDTHxHEIGHT`. |
| `show_cursor` | `bool` | `true` | Include the cursor. |
| `color_range` | `select` | `limited` | `limited` or `full`. |
| `audio_source` | `select` | `runelite` | `runelite`, `runelite_mic` (game + microphone), `default_output`, `default_input`, `both`, `custom` or `none`. |
| `runelite_audio_app` | `string` | | Application name for game audio. Empty = detect (see below). |
| `custom_audio_sources` | `string` | | Comma-separated gpu-screen-recorder audio sources for `custom`. |
| `audio_codec` | `select` | `opus` | `opus`, `aac` or `flac`. |
| `audio_bitrate` | `int` | `0` | Audio bitrate in kbps; `0` = automatic. |
| `on_resize` | `select` | `restart` | On a window resize: `restart` the capture, or `stop` it and notify. |
| `resize_settle` | `int` | `3` | Seconds the size must stay the same before restarting (1–30). |
| `hide_when_not_running` | `bool` | `true` | Hide the widget while no RuneLite session runs. |
| `left_click` | `select` | `select_session` | Widget left click: `select_session`, `save_replay`, `toggle_replay`, `toggle_recording` or `none`. |
| `right_click` | `select` | `save_replay` | Widget right click (same choices). |
| `middle_click` | `select` | `toggle_replay` | Widget middle click (same choices). |
| `glyph_unavailable` | `glyph` | `video-off` | Widget glyph when gpu-screen-recorder or Hyprland is missing. |
| `glyph_no_runelite` | `glyph` | `device-gamepad-2` | Widget glyph when no RuneLite session runs. |
| `glyph_ready` | `glyph` | `video` | Widget glyph when RuneLite runs but nothing is captured. |
| `glyph_starting` | `glyph` | `video` | Widget glyph while a capture starts or stops. |
| `glyph_recording` | `glyph` | `player-record-filled` | Widget glyph while recording. |
| `glyph_replaying` | `glyph` | `repeat` | Widget glyph while the replay buffer runs. |
| `window_class` | `string` | `^net-runelite-client-RuneLite$` | Advanced: regex (extended, case-insensitive) for RuneLite's window class. |
| `exclude_title` | `string` | `^(RuneLite Launcher\|win[0-9]+)$` | Advanced: regex for window titles to ignore (splash screen, Java popups). |

Changing a setting while the replay buffer runs restarts it with the new
settings. A running regular recording keeps its settings until it ends.

### Game audio

RuneLite is a Java program, so its audio stream has a generic PipeWire name
(for example `PipeWire ALSA [java]`). When `runelite_audio_app` is empty, the
service runs `gpu-screen-recorder --list-application-audio` and uses the first
name that contains `runelite`, `java` or `openjdk`. The name only shows up while
RuneLite plays sound, so the last name found is remembered for later starts. To
check it yourself, run the command while RuneLite plays sound and put the name
in `runelite_audio_app`. If no name has ever been found, the capture starts
without game audio and a line is written to the log.

## IPC

The service is a singleton with no output, so the IPC target is always `all`:

```sh
noctalia msg plugin fredrikj/runelite-recorder:service all replay-start [session]
noctalia msg plugin fredrikj/runelite-recorder:service all replay-stop
noctalia msg plugin fredrikj/runelite-recorder:service all replay-toggle
noctalia msg plugin fredrikj/runelite-recorder:service all save
noctalia msg plugin fredrikj/runelite-recorder:service all record-toggle [session]
noctalia msg plugin fredrikj/runelite-recorder:service all select <character|address|next>
noctalia msg plugin fredrikj/runelite-recorder:service all setup-picker
noctalia msg plugin fredrikj/runelite-recorder:service all sessions
```

A session can be named by character (case-insensitive; `Balkan_Bob` matches
`Balkan Bob`), by Hyprland window address, or left out to use `auto_session`.
`select next` moves the capture to the next session. `sessions` writes the
session list to the Noctalia log.

Open the session panel with:

```sh
noctalia msg panel-toggle fredrikj/runelite-recorder:sessions
```

### Hotkey for saving

Hyprland 0.55 and newer (Lua configuration):

```lua
hl.bind("SUPER + F9", hl.dsp.exec_cmd("noctalia msg plugin fredrikj/runelite-recorder:service all save"))
```

Hyprland before 0.55 (`hyprland.conf`; check the
[Hyprland wiki](https://wiki.hypr.land/Configuring/Binds/) for your version):

```
bind = SUPER, F9, exec, noctalia msg plugin fredrikj/runelite-recorder:service all save
```

## Known limitations

- **Hyprland only.** The window code is kept in `lib/hyprland.luau` so other
  compositors can be added later.
- **Workspaces that are not shown** may give a still image until the workspace
  is shown again. This comes from the compositor, not from the plugin.
- **Game audio is shared between Java programs.** All RuneLite clients (and any
  other Java program playing sound) use the same PipeWire name, so with several
  clients open the clip contains the sound of all of them.
- **A restart after a resize** empties the replay buffer.
- **Native gpu-screen-recorder only**; the Flatpak is not supported.

## Running next to `noctalia/screen_recorder`

The official Screen Recorder plugin finds and stops gpu-screen-recorder by
process name. RuneLite Recorder runs gpu-screen-recorder through a symlink
named `runelite-gsr` and only signals its own pid, so the two plugins do not
adopt or stop each other's recordings.

## Debugging

The service logs its decisions (sessions, the gpu-screen-recorder command,
state changes, restarts) to the Noctalia log (`~/.cache/noctalia/noctalia.log`)
with the prefix `runelite_recorder:`. gpu-screen-recorder's own output is
written to `${XDG_STATE_HOME:-~/.local/state}/noctalia/runelite_recorder/gsr.log`
(replaced on every start); when a capture fails, its tail is copied into the
Noctalia log. The picker writes its decisions to
`$XDG_RUNTIME_DIR/runelite-recorder-picker.log`.

## License

MIT. See [LICENSE](LICENSE).
