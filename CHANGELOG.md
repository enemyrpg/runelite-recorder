# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-08

First release.

### Added

- Records only the RuneLite window with gpu-screen-recorder through the
  xdg-desktop-portal-hyprland window picker. The replay buffer is the main mode,
  and regular start/stop recording is also available.
- Session discovery on Hyprland. The launcher splash screen and Java popup
  windows are skipped, and each client process counts as one session.
- Bundled portal picker (`runelite-share-picker`) that selects the requested
  window without a dialog. Other screen sharing still gets the normal picker.
  The `setup-picker` IPC command configures `xdph.conf` and keeps a backup.
- Automatic or manual start. Autostart picks the last character, the focused
  window or the first session, and stops after a grace period when the last
  client closes.
- Follows the next session when the recorded client closes, and remembers the
  last selected character.
- Restarts (or stops) the capture after the window frame size changes and has
  settled, since gpu-screen-recorder freezes the video on a resize.
- File names with the `{character}` token, resolved when the clip is saved, an
  optional folder per character, a post-save script, and copy to clipboard.
- Game-only audio through application capture, optionally mixed with the
  microphone.
- Bar widget with per-state icons, a tooltip, configurable click actions and
  hiding when RuneLite is not running.
- Sessions panel for switching the recorded client.
- Control-center shortcut and IPC commands for hotkeys.
- gpu-screen-recorder runs under its own process name (`runelite-gsr`) and is
  only signalled by pid, so it coexists with `noctalia/screen_recorder`.

[0.1.0]: https://github.com/enemyrpg/runelite-recorder/releases/tag/v0.1.0
