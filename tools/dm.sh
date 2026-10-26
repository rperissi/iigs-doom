#!/bin/sh
# Two headless IIgs machines play a deathmatch against each other through
# emulated CoGS cards (the MAME of reference/webifi-mame with the cogs
# slot device) and the relay tools/dmrelay.py on localhost.
#
# Build first: make NETGAME=1 AUTOJOIN=1 (the game opens its NETWORK GAME
# page and starts the join itself; the card in any slot, the relay port
# 5100). The disks of build/ go to build/dm/seatA and seatB, each machine
# boots its copy (tools/probe.lua swaps the disks on the loader's prompt)
# and runs to game tic TICS (default 300; the net game counts its tics
# from 0 when it starts, PROBE_TICGATE), then dumps the state of both
# players and the random index; tools/dmcmp.py compares the two dumps.
# Seat A walks forward and fires, seat B turns, from PROBE_TICPRESS (the
# emulated keys by MAME field name: "w  W" forward, Control fire, "Left
# Arrow" and "Right Arrow" turn, "a  A" and "d  D" strafe, Space use).
# KEYS_A / KEYS_B override them (TIC:KEY:TICS lists). PRESS_A / PRESS_B
# are keys by emulated seconds (PROBE_PRESS SECONDS:KEY:HOLD lists), for
# the NETWORK GAME page before the join (the boot takes some 220 s).
#
# Env: MAME (the binary), ZIP (cfg/zipN, default 7), TICS, RUN (the
# emulated bound, default 600), KEYS_A, KEYS_B, PORT, COOP_STARTS (below),
# TICPOKE (PROBE_TICPOKE TIC:ADDR:VALUE words; of no use in this MAME,
# the CPU does not see Lua's RAM writes to banks 02 and 04, so a level
# end comes from make NETGAME=1 BENCHEXIT=300 instead).
# Seat A is player 0 (it connects first).
# CARDBOOT=1: no floppies; each machine boots build/doom-hd.po FROM its
# CoGS card (the slot set to Your Card and the startup slot in the seat's
# battery RAM, the image served to the emulated card by a local range
# share on CARDPORT, default 8131), as the players will from the catalog.
# SLOTA / SLOTB pick the slots (default 5 and 7 then, 3 otherwise).
# LOBBY=1: the build was make NETGAME=1 LOBBY=1 ROOM=CODE AUTOJOIN=1 and
# the two machines meet through the lobby's ws/match over wss (the
# emulated card of cogs-1.36 does the WebSocket); no local relay is
# started. The room code is in the build, so one run per code at a time.
# STAGGER is WALL seconds between the two launches (default 4) while RUN
# is EMULATED seconds; at the bench's 10x, RUN=420 ends seat A some 42 s
# in, before a STAGGER=45 seat B has booted, and both sit alone on the
# page (a lost afternoon, 2026-10-25). RUN=800 or more with a long stagger.
cd "$(dirname "$0")/.." || exit 1
MAME=${MAME:-../webifi-mame/cogs}
ZIP=${ZIP:-7}
TICS=${TICS:-300}
RUN=${RUN:-600}
PORT=${PORT:-5100}
WORK=build/dm
[ -x "$MAME" ] || { echo "no mame at $MAME (MAME=...)" >&2; exit 1; }
[ -f build/disk1.po ] || { echo "make NETGAME=1 AUTOJOIN=1 first" >&2; exit 1; }
if ! grep -q "D_NetStart" build/doom.lst 2>/dev/null; then
    echo "build/doom.lst has no D_NetStart: make NETGAME=1 AUTOJOIN=1 first" >&2; exit 1
fi

G=$(python3 tools/symaddr.py build/doom.elf _g_gametic)
NG=$(python3 tools/symaddr.py build/doom.elf _g_netgame)   # the tic events: the net game only
sym() { python3 tools/symaddr.py build/doom.elf "$1"; }
DUMP="${DUMP_EXTRA:+$DUMP_EXTRA,}$(sym _g_gametic):4,$(sym prndindex):2,$(sym _g_frags):4,$(sym _g_consoleplayer):2,$(sym _g_player):9b,$(sym _g_psave):136"
# A: W from tic 40 for 60 tics, Control at 70 for 10, W at 150 for 60.
# B: Right from 40 for 20, Left at 120 for 20, Control at 160 for 10.
KEYS_A=${KEYS_A-40:w  W:60,70:Control:10,150:w  W:60}
KEYS_B=${KEYS_B-40:Right Arrow:20,120:Left Arrow:20,160:Control:10}

# COOP_STARTS=1: no deathmatch starts kept (the MAX_DMSTARTS of
# P_SpawnPlayerN becomes 0 in the loaded code), so the players spawn at
# their own starts, next to each other in E1M1: player 0 turning left
# about 72 degrees faces player 1. DMSTARTS=N keeps the first N starts of
# a map instead (DMSTARTS=1: player 0 at the first one, player 1 at his
# own start; E1M2's first is 51 units west of a shotgun, facing it).
POKE=${POKE-}
[ -n "$COOP_STARTS" ] && DMSTARTS=0
if [ -n "$DMSTARTS" ]; then
    POKE=${POKE:+$POKE,}$(python3 - <<'PY'
import os, struct, subprocess
addr = int(subprocess.check_output(['python3', 'tools/symaddr.py', 'build/doom.elf', 'P_SpawnPlayerN']).decode(), 16)
d = open('build/doom.elf', 'rb').read()
phoff, = struct.unpack_from('<I', d, 28)
phentsize, phnum = struct.unpack_from('<HH', d, 42)
for i in range(phnum):
    t, off, va, pa, fsz = struct.unpack_from('<IIIII', d, phoff + i * phentsize)
    if t == 1 and pa <= addr < pa + fsz:
        o = off + addr - pa
        k = d[o:o + 48].find(bytes([0xc9, 10, 0]))     # cmp ##MAX_DMSTARTS
        print('120:%06x:%02x' % (addr + k + 1, int(os.environ['DMSTARTS'])) if k >= 0 else '')
PY
)
    [ -n "$POKE" ] || { echo "DMSTARTS: no cmp ##MAX_DMSTARTS found" >&2; exit 1; }
fi

rm -rf "$WORK"
mkdir -p "$WORK"
COGS_TEST=${COGS_TEST:-../../cogs-1.36/emu/mame/test}
if [ -n "$CARDBOOT" ]; then
    [ -f build/doom-hd.po ] || { echo "no build/doom-hd.po" >&2; exit 1; }
    CARDPORT=${CARDPORT:-8131}
    python3 "$COGS_TEST/range_http.py" build "$CARDPORT" > "$WORK/share.log" 2>&1 &
    SHARE=$!
    trap 'kill $SHARE 2>/dev/null' EXIT
    sleep 1
fi
if [ -n "$LOBBY" ]; then
    strings build/doom.elf | grep -q "lobby.a2cogs.com" || {
        echo "LOBBY=1 but the build has no lobby host: make NETGAME=1 LOBBY=1 AUTOJOIN=1 first" >&2; exit 1; }
    echo "lobby: $(strings build/doom.elf | grep -o 'lobby.a2cogs.com/ws/match[^ ]*' | head -1) code $(strings build/doom.elf | grep -A1 '^&c=$' | tail -1)" > "$WORK/relay.log"
    RELAY=
else
    python3 tools/dmrelay.py --port "$PORT" --log "$WORK/relay.log" --seconds 300 &
    RELAY=$!
    trap 'kill $RELAY 2>/dev/null' EXIT
fi

ROOT=$(pwd)
seat() {
    s=$1; keys=$2; dir=$WORK/seat$s
    eval press=\${PRESS_$s}
    if [ -n "$CARDBOOT" ]; then dflt=$([ "$s" = A ] && echo 5 || echo 7); else dflt=3; fi
    eval slot=\${SLOT$s:-$dflt}                     # SLOTA / SLOTB: the card's slot
    mkdir -p "$dir/build" "$dir/snap"
    cp -R nvram "$dir/nvram"
    eval z=\"\${ZIP_$s-\$ZIP}\"                      # ZIP_A / ZIP_B: that seat's
    cp -R "cfg${z:+/zip$z}" "$dir/cfg"            #   cfg (ZIP_B= : stock speed)
    if [ -n "$CARDBOOT" ]; then
        python3 "$COGS_TEST/bram_startup.py" "$dir/nvram/apple2gs/rtc" --slot "$slot" --startup "$slot" > /dev/null
        media=
        disks=
        volurl="http://127.0.0.1:$CARDPORT/doom-hd.po"
    else
        for f in build/disk[0-9].po; do cp "$f" "$dir/${f##*/}"; done
        disks=$(ls "$ROOT/$dir"/disk[0-9].po | sort | paste -sd, -)
        media="-flop3 $ROOT/$dir/disk1.po"
        volurl=
    fi
    printf "CGN1\005dmnet\001x\000\000\000" > "$dir/cogs_nv"
    ram=8M                                       # RAM_A / RAM_B: 4M reads the
    [ "$s" = A ] && ram="${RAM_A:-8M}"         #   levels from the card (the
    [ "$s" = B ] && ram="${RAM_B:-8M}"         #   lost-records case)
    nothr=-nothrottle                            # THROTTLE_A / THROTTLE_B=1:
    [ "$s" = A ] && [ -n "$THROTTLE_A" ] && nothr=   #   that seat at 1x (its level
    [ "$s" = B ] && [ -n "$THROTTLE_B" ] && nothr=   #   load takes real seconds)
    ( cd "$dir" && { [ -n "$volurl" ] && export COGS_VOL_URL="$volurl"; } ; \
      SDL_VIDEO_DRIVER=dummy SDL_VIDEODRIVER=dummy SDL_MAC_BACKGROUND_APP=1 \
      COGS_EMU_NVRAM="$ROOT/$dir/cogs_nv" COGS_EMU_FLASHCACHE="$ROOT/$dir/flashcache" \
      PROBE_DISKS="$disks" PROBE_SECONDS="$RUN" PROBE_GAMETIC="$G" PROBE_TICGATE="$NG" \
      PROBE_TICSHR="$TICS" PROBE_TICEXIT=1 PROBE_TEXTEXIT=1 PROBE_DUMP="$DUMP" \
      PROBE_TICPRESS="$keys" PROBE_PRESS="$press" PROBE_POKE="$POKE" PROBE_TICPOKE="$TICPOKE" \
      PROBE_EXTRA="${PROBE_EXTRA:-/dev/null}" \
      "$ROOT/$MAME" apple2gs -rompath "$ROOT/roms" -ramsize "$ram" -sl$slot cogs \
      $media -window -nomaximize -video none -sound none \
      $nothr -skip_gameinfo -autoboot_script "$ROOT/tools/probe.lua" \
      -snapshot_directory snap -nvram_directory nvram -cfg_directory cfg \
      > mame.log 2>&1 )
}
seat A "$KEYS_A" &
PA=$!
sleep ${STAGGER:-4}                                 # seat A connects first: player 0
seat B "$KEYS_B" &
PB=$!
trap 'kill $RELAY $SHARE $PA $PB 2>/dev/null' EXIT
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
