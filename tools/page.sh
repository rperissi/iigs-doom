#!/bin/sh
# One headless seat for the NETWORK GAME page: boots the floppy set in the
# CoGS build of MAME, presses keys by emulated second, saves the screen at
# given seconds and renders the saves as PNGs (tools/shrpng.py). The game
# code is up at about 220 s of emulated time (the floppy boot); a key
# before that lands in the loader.
#
#   RUN=236 SHR=234 PRESS="224:Esc:0.2,226:Down Arrow:0.2" tools/page.sh
#
# Env: MAME (the binary, default ../webifi-mame/cogs), RUN (emulated
# seconds), SHR (seconds to save, comma separated), PRESS (PROBE_PRESS
# SECONDS:KEY:HOLD list; letters and digits by name, "R"), DUMP and DUMPT
# (PROBE_DUMP ADDR:LEN and PROBE_DUMPTIMES seconds), OUT (the PNG prefix,
# default build/page/shr). The emulated card has the test Wi-Fi profile.
cd "$(dirname "$0")/.." || exit 1
MAME=${MAME:-../webifi-mame/cogs}
WORK=build/page; rm -rf "$WORK"; dir=$WORK/seatA
mkdir -p "$dir/build" "$dir/snap"
cp -R nvram "$dir/nvram"; cp -R cfg/zip7 "$dir/cfg"
for f in build/disk[0-9].po; do cp "$f" "$dir/${f##*/}"; done
ROOT=$(pwd)
disks=$(ls "$ROOT/$dir"/disk[0-9].po | sort | paste -sd, -)
printf "CGN1\005dmnet\001x\000\000\000" > "$dir/cogs_nv"
G=$(python3 tools/symaddr.py build/doom.elf _g_gametic)
( cd "$dir" && SDL_VIDEO_DRIVER=dummy SDL_VIDEODRIVER=dummy SDL_MAC_BACKGROUND_APP=1 \
  COGS_EMU_NVRAM="$ROOT/$dir/cogs_nv" \
  PROBE_DISKS="$disks" PROBE_SECONDS="$RUN" PROBE_GAMETIC="$G" PROBE_TEXTEXIT=1 \
  PROBE_SHR="$SHR" PROBE_PRESS="$PRESS" PROBE_DUMP="$DUMP" PROBE_DUMPTIMES="$DUMPT" \
  "$ROOT/$MAME" apple2gs -rompath "$ROOT/roms" -ramsize 8M -sl3 cogs \
  -flop3 "$ROOT/$dir/disk1.po" -window -nomaximize -video none -sound none \
  -nothrottle -skip_gameinfo -autoboot_script "$ROOT/tools/probe.lua" \
  -snapshot_directory snap -nvram_directory nvram -cfg_directory cfg > mame.log 2>&1 )
grep "^\[probe\]\|^PC=\|^[0-9A-F]*: " "$dir/mame.log" | grep -v "SHR saved" | tail -40
OUT=${OUT:-$WORK/shr}
for f in "$dir"/build/shr_*.bin; do
  [ -f "$f" ] || continue
  python3 tools/shrpng.py "$f" "${OUT}_$(basename "$f" .bin | sed 's/^shr_//').png"
done
ls "${OUT}"_*.png 2>/dev/null
