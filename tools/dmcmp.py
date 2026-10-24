#!/usr/bin/env python3
"""dmcmp.py SEATA.log SEATB.log: compare the memory dumps tools/dm.sh
takes at the end of a deathmatch run (the hexdump lines of
tools/probe.lua). The game tic, the random index and the frags must
match; the struct of each player (the resident _g_player of the seat
that is him, the save slot of the other seat) must match byte for byte.
Exit 0 when they do."""
import re
import subprocess
import sys

SIZEOF_PL = 155


def dumps(path):
    mem = {}
    for line in open(path, errors='replace'):
        m = re.match(r'^([0-9A-F]{6}):((?: [0-9A-F]{2})+)$', line.rstrip())
        if m:
            base = int(m.group(1), 16)
            for i, b in enumerate(m.group(2).split()):
                mem[base + i] = int(b, 16)
    return mem


def region(mem, addr, n):
    try:
        return bytes(mem[addr + i] for i in range(n))
    except KeyError:
        return None


def sym(name):
    return int(subprocess.check_output(['python3', 'tools/symaddr.py', 'build/doom.elf', name]).decode(), 16)


a, b = dumps(sys.argv[1]), dumps(sys.argv[2])
if not a or not b:
    print('no dumps in %s' % ('both logs' if not a and not b else sys.argv[1] if not a else sys.argv[2]))
    sys.exit(1)
gametic, prnd, frags, console, player, psave = (
    sym(n) for n in ('_g_gametic', 'prndindex', '_g_frags', '_g_consoleplayer', '_g_player', '_g_psave'))
ok = True


def check(what, x, y):
    global ok
    if x is None or y is None:
        print('%-22s missing' % what)
        ok = False
    elif x == y:
        print('%-22s same  %s' % (what, x.hex() if len(x) <= 4 else '%d bytes' % len(x)))
    else:
        diff = [i for i in range(len(x)) if x[i] != y[i]]
        print('%-22s DIFFER A %s B %s%s' % (what, x.hex() if len(x) <= 4 else '', y.hex() if len(y) <= 4 else '',
                                          ' at offsets %s' % diff[:12] if len(x) > 4 else ''))
        ok = False


check('gametic', region(a, gametic, 4), region(b, gametic, 4))
check('prndindex', region(a, prnd, 2), region(b, prnd, 2))
check('frags', region(a, frags, 4), region(b, frags, 4))
# The relay numbers the players in the order they connect: each seat's
# resident struct is its console player's, the other's is in his save slot.
ca, cb = (region(m, console, 2) for m in (a, b))
if ca is None or cb is None or ca == cb or ca[0] > 1 or cb[0] > 1:
    print('console players: A %s B %s' % (ca and ca.hex(), cb and cb.hex()))
    sys.exit(1)
ca, cb = ca[0], cb[0]
print('seat A is player %d, seat B is player %d' % (ca, cb))


def struct(mem, mine, n):
    return region(mem, player if n == mine else psave + n * SIZEOF_PL, SIZEOF_PL)


OFS_MESSAGE = 113                       # the HUD message pointer: the console
                                        # player's is cleared when shown, not
                                        # the other's; not game state


def nomsg(p):
    return p and p[:OFS_MESSAGE] + b'\0' * 4 + p[OFS_MESSAGE + 4:]


for n in (0, 1):
    check('player %d struct' % n, nomsg(struct(a, ca, n)), nomsg(struct(b, cb, n)))
for n in (0, 1):
    p = struct(a, ca, n)
    if p:
        mo = int.from_bytes(p[0:4], 'little')
        health = int.from_bytes(p[35:37], 'little')
        print('player %d: mobj %06x health %d' % (n, mo, health))
sys.exit(0 if ok else 1)
