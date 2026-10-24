#!/bin/sh
# Two headless IIgs machines play a deathmatch against each other through
# emulated CoGS cards (the MAME of reference/webifi-mame with the cogs
# slot device) and the relay tools/dmrelay.py on localhost.
#
# Build first: make NETGAME=1 (COGSSLOT=3 is the default, the relay port
# 5100). The disks of build/ go to build/dm/seatA and seatB, each machine
# boots its copy (tools/probe.lua swaps the disks on the loader's prompt)
# and runs to game tic TICS (default 300), then dumps the state of both
# players and the random index; tools/dmcmp.py compares the two dumps.
# Seat A walks forward and fires, seat B turns, from PROBE_TICPRESS (the
# emulated keys by MAME field name: "w  W" forward, Control fire, "Left
# Arrow" and "Right Arrow" turn, "a  A" and "d  D" strafe, Space use).
# KEYS_A / KEYS_B override them (TIC:KEY:TICS lists).
#
# Env: MAME (the binary), ZIP (cfg/zipN, default 7), TICS, RUN (the
# emulated bound, default 600), KEYS_A, KEYS_B, PORT, COOP_STARTS (below),
# TICPOKE (PROBE_TICPOKE TIC:ADDR:VALUE words, on both seats: the same
# state on both, e.g. a level end: TICPOKE=300:$(tools/symaddr.py
# build/doom.elf _g_gameaction):6).
# Seat A is player 0 (it connects first).
cd "$(dirname "$0")/.." || exit 1
MAME=${MAME:-../webifi-mame/cogs}
ZIP=${ZIP:-7}
TICS=${TICS:-300}
RUN=${RUN:-600}
PORT=${PORT:-5100}
WORK=build/dm
[ -x "$MAME" ] || { echo "no mame at $MAME (MAME=...)" >&2; exit 1; }
[ -f build/disk1.po ] || { echo "make NETGAME=1 first" >&2; exit 1; }
if ! grep -q "D_NetStart" build/doom.lst 2>/dev/null; then
    echo "build/doom.lst has no D_NetStart: make NETGAME=1 first" >&2; exit 1
fi

G=$(python3 tools/symaddr.py build/doom.elf _g_gametic)
sym() { python3 tools/symaddr.py build/doom.elf "$1"; }
DUMP="${DUMP_EXTRA:+$DUMP_EXTRA,}$(sym _g_gametic):4,$(sym prndindex):2,$(sym _g_frags):4,$(sym _g_consoleplayer):2,$(sym _g_player):9b,$(sym _g_psave):136"
# A: W from tic 40 for 60 tics, Control at 70 for 10, W at 150 for 60.
# B: Right from 40 for 20, Left at 120 for 20, Control at 160 for 10.
KEYS_A=${KEYS_A-40:w  W:60,70:Control:10,150:w  W:60}
KEYS_B=${KEYS_B-40:Right Arrow:20,120:Left Arrow:20,160:Control:10}

# COOP_STARTS=1: no deathmatch starts kept (the MAX_DMSTARTS of
# P_SpawnPlayerN becomes 0 in the loaded code), so the players spawn at
# their own starts, next to each other in E1M1: player 0 turning left
# about 72 degrees faces player 1.
POKE=${POKE-}
if [ -n "$COOP_STARTS" ]; then
    POKE=${POKE:+$POKE,}$(python3 - <<'PY'
import struct, subprocess
addr = int(subprocess.check_output(['python3', 'tools/symaddr.py', 'build/doom.elf', 'P_SpawnPlayerN']).decode(), 16)
d = open('build/doom.elf', 'rb').read()
phoff, = struct.unpack_from('<I', d, 28)
phentsize, phnum = struct.unpack_from('<HH', d, 42)
for i in range(phnum):
    t, off, va, pa, fsz = struct.unpack_from('<IIIII', d, phoff + i * phentsize)
    if t == 1 and pa <= addr < pa + fsz:
        o = off + addr - pa
        k = d[o:o + 48].find(bytes([0xc9, 10, 0]))     # cmp ##MAX_DMSTARTS
        print('120:%06x:00' % (addr + k + 1) if k >= 0 else '')
PY
)
    [ -n "$POKE" ] || { echo "COOP_STARTS: no cmp ##MAX_DMSTARTS found" >&2; exit 1; }
fi

rm -rf "$WORK"
mkdir -p "$WORK"
python3 tools/dmrelay.py --port "$PORT" --log "$WORK/relay.log" --seconds 300 &
RELAY=$!
trap 'kill $RELAY 2>/dev/null' EXIT

ROOT=$(pwd)
seat() {
    s=$1; keys=$2; dir=$WORK/seat$s
    mkdir -p "$dir/build" "$dir/snap"
    cp -R nvram "$dir/nvram"
    cp -R "cfg${ZIP:+/zip$ZIP}" "$dir/cfg"
    for f in build/disk[0-9].po; do cp "$f" "$dir/${f##*/}"; done
    disks=$(ls "$ROOT/$dir"/disk[0-9].po | sort | paste -sd, -)
    printf "CGN1\005dmnet\001x\000\000\000" > "$dir/cogs_nv"
    ( cd "$dir" && SDL_VIDEO_DRIVER=dummy SDL_VIDEODRIVER=dummy SDL_MAC_BACKGROUND_APP=1 \
      COGS_EMU_NVRAM="$ROOT/$dir/cogs_nv" \
      PROBE_DISKS="$disks" PROBE_SECONDS="$RUN" PROBE_GAMETIC="$G" \
      PROBE_TICSHR="$TICS" PROBE_TICEXIT=1 PROBE_TEXTEXIT=1 PROBE_DUMP="$DUMP" \
      PROBE_TICPRESS="$keys" PROBE_POKE="$POKE" PROBE_TICPOKE="$TICPOKE" \
      PROBE_EXTRA="${PROBE_EXTRA:-/dev/null}" \
      "$ROOT/$MAME" apple2gs -rompath "$ROOT/roms" -ramsize 8M -sl3 cogs \
      -flop3 "$ROOT/$dir/disk1.po" -window -nomaximize -video none -sound none \
      -nothrottle -skip_gameinfo -autoboot_script "$ROOT/tools/probe.lua" \
      -snapshot_directory snap -nvram_directory nvram -cfg_directory cfg \
      > mame.log 2>&1 )
}
seat A "$KEYS_A" &
PA=$!
sleep ${STAGGER:-4}                                 # seat A connects first: player 0
seat B "$KEYS_B" &
PB=$!
trap 'kill $RELAY $PA $PB 2>/dev/null' EXIT
echo "relay $RELAY, seats $PA $PB, work $WORK"
wait $PA $PB
sleep 1
echo "---- relay ----"
cat "$WORK/relay.log"
for s in A B; do
    echo "---- seat $s ----"
    grep -v "WRONG\|EXPECTED\|FOUND\|might not\|doesn't\|^$" "$WORK/seat$s/mame.log" | grep "^\[probe\]\|^\[text\]\|^[0-9A-F]*:\|^PC=" | grep -v "SHR saved"
done
echo "---- compare ----"
python3 tools/dmcmp.py "$WORK/seatA/mame.log" "$WORK/seatB/mame.log"
