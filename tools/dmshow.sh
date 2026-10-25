#!/bin/sh
# Two IIgs machines on screen, side by side, in a deathmatch through
# emulated CoGS cards: the watchable version of tools/dm.sh. Real video
# and sound, unthrottled only through the boot (probe.lua PROBE_FASTLOAD
# drops to 1x when the game code runs), no exit, no scripted keys unless
# DEMO=1 (then dm.sh's walk-and-fire script runs on both). Click a window
# and that seat is yours: W/S forward and back, arrows turn, Control
# fires, Space uses. MAME takes Esc for itself (quit), so leave the Doom
# menu alone; Cmd-Q the window to stop a seat.
#
# Build first: make NETGAME=1 LOBBY=1 ROOM=CODE (the two meet in the
# lobby's Pair room; LOBBY= in the env uses the local relay of dm.sh
# instead, with the matching make NETGAME=1 build).
# Env: MAME (the binary), ZIP (cfg/zipN, default 7), DEMO, KEYS_A, KEYS_B,
# STAGGER (seconds between the seats, default 4), POS_A, POS_B (window
# x,y; default 0,40 and 700,40).
cd "$(dirname "$0")/.." || exit 1
MAME=${MAME:-../webifi-mame/cogs}
ZIP=${ZIP:-7}
PORT=${PORT:-5100}
LOBBY=${LOBBY-1}
WORK=build/dmshow
[ -x "$MAME" ] || { echo "no mame at $MAME (MAME=...)" >&2; exit 1; }
[ -f build/disk1.po ] || { echo "make NETGAME=1 LOBBY=1 first" >&2; exit 1; }
grep -q "D_NetStart" build/doom.lst 2>/dev/null || {
    echo "build/doom.lst has no D_NetStart: make NETGAME=1 LOBBY=1 first" >&2; exit 1; }

G=$(python3 tools/symaddr.py build/doom.elf _g_gametic)
if [ -n "$DEMO" ]; then
    KEYS_A=${KEYS_A-40:w  W:60,70:Control:10,150:w  W:60}
    KEYS_B=${KEYS_B-40:Right Arrow:20,120:Left Arrow:20,160:Control:10}
fi

rm -rf "$WORK"
mkdir -p "$WORK"
RELAY=
if [ -n "$LOBBY" ]; then
    strings build/doom.elf | grep -q "lobby.a2cogs.com" || {
        echo "the build has no lobby host: make NETGAME=1 LOBBY=1 first (or LOBBY= for the relay)" >&2; exit 1; }
    echo "lobby: $(strings build/doom.elf | grep -o 'lobby.a2cogs.com/ws/pair?r=[A-Za-z0-9-]*' | head -1)"
else
    python3 tools/dmrelay.py --port "$PORT" --log "$WORK/relay.log" --seconds 3600 &
    RELAY=$!
fi

ROOT=$(pwd)
seat() {
    s=$1; keys=$2; pos=$3; dir=$WORK/seat$s
    eval slot=\${SLOT$s:-3}                         # SLOTA / SLOTB: the card's slot
    mkdir -p "$dir/build" "$dir/snap"
    cp -R nvram "$dir/nvram"
    cp -R "cfg${ZIP:+/zip$ZIP}" "$dir/cfg"
    for f in build/disk[0-9].po; do cp "$f" "$dir/${f##*/}"; done
    disks=$(ls "$ROOT/$dir"/disk[0-9].po | sort | paste -sd, -)
    printf "CGN1\005dmnet\001x\000\000\000" > "$dir/cogs_nv"
    ( cd "$dir" && SDL_VIDEO_WINDOW_POS="$pos" \
      COGS_EMU_NVRAM="$ROOT/$dir/cogs_nv" \
      PROBE_DISKS="$disks" PROBE_SECONDS=0 PROBE_GAMETIC="$G" PROBE_FASTLOAD=1 \
      PROBE_TICPRESS="$keys" \
      "$ROOT/$MAME" apple2gs -rompath "$ROOT/roms" -ramsize 8M -sl$slot cogs \
      -flop3 "$ROOT/$dir/disk1.po" -window -nomaximize -skip_gameinfo \
      -autoboot_script "$ROOT/tools/probe.lua" \
      -snapshot_directory snap -nvram_directory nvram -cfg_directory cfg \
      > mame.log 2>&1 )
}
seat A "$KEYS_A" "${POS_A:-0,40}" &
PA=$!
sleep ${STAGGER:-4}                                 # seat A connects first: player 0
seat B "$KEYS_B" "${POS_B:-700,40}" &
PB=$!
trap 'kill $RELAY $PA $PB 2>/dev/null' EXIT INT TERM
echo "seats $PA $PB, work $WORK (logs $WORK/seatA/mame.log, seatB/mame.log)"
wait $PA $PB
