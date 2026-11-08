#!/usr/bin/env bash
# on-save.sh - gpu-screen-recorder save script (-sc) for RuneLite Recorder.
#
# gsr calls this with: <file path> <type>   (type: regular | replay | screenshot)
#
# The character name is read when the clip is saved, not when gsr started,
# because the window title changes after login. The service keeps these files
# up to date in its data dir (this script lives in <data dir>/bin):
#   character   current character of the recorded session (empty = unknown)
#   save.conf   shell assignments: output_dir, replay_pattern, record_marker,
#               per_character_folder (1/0), post_save_script
#
# The final path is written to <data dir>/saved/<original file name> so the
# service can show it in the notification and copy it to the clipboard. The
# user's post_save_script then runs in the background with <final path> <type>.

src="$1"
type="$2"
data_dir="$(cd "$(dirname "$0")/.." && pwd)"

output_dir=""
replay_pattern="replay_{character}_%Y%m%d_%H%M%S"
record_marker=""
per_character_folder=0
post_save_script=""
# shellcheck source=/dev/null
[ -f "$data_dir/save.conf" ] && . "$data_dir/save.conf"

character="$(head -n 1 "$data_dir/character" 2>/dev/null)"
[ -n "$character" ] || character="unknown"
# Same rules as the service: spaces -> "_", path and format characters -> "_".
name="$(printf '%s' "$character" | sed 's/\xc2\xa0/ /g' | tr -s '[:space:]' '_' | tr '/%{}' '____' | tr -d '[:cntrl:]')"
case "$name" in .*) name="_${name#.}" ;; esac
[ -n "$name" ] || name="unknown"

dst="$src"
if [ -f "$src" ]; then
    src_dir="$(dirname "$src")"
    ext="${src##*.}"
    base=""
    case "$type" in
        replay)
            fmt="${replay_pattern//\{character\}/$name}"
            base="$(date +"$fmt")"
            ;;
        regular)
            base="$(basename "$src" ".$ext")"
            [ -n "$record_marker" ] && base="${base//"$record_marker"/$name}"
            ;;
    esac

    if [ -n "$base" ]; then
        target_dir="${output_dir:-$src_dir}"
        [ "$per_character_folder" = "1" ] && target_dir="$target_dir/$name"
        candidate="$target_dir/$base.$ext"
        mkdir -p "$(dirname "$candidate")"
        i=1
        while [ -e "$candidate" ] && [ "$candidate" != "$src" ]; do
            candidate="$target_dir/${base}_$i.$ext"
            i=$((i + 1))
        done
        if [ "$candidate" = "$src" ] || mv -n -- "$src" "$candidate"; then
            dst="$candidate"
        fi
    fi
fi

mkdir -p "$data_dir/saved"
printf '%s\n' "$dst" >"$data_dir/saved/$(basename "$src").tmp" &&
    mv -f "$data_dir/saved/$(basename "$src").tmp" "$data_dir/saved/$(basename "$src")"

if [ -n "$post_save_script" ] && [ -x "$post_save_script" ]; then
    setsid "$post_save_script" "$dst" "$type" </dev/null >/dev/null 2>&1 &
fi
exit 0
