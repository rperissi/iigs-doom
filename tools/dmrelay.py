#!/usr/bin/env python3
"""dmrelay.py [--port 5100] [--log FILE]: the relay of a two-player
deathmatch (src/iigs/d_net65.s). Each game connects through its CoGS
card; the relay sends it one byte, its player number (0 to the first,
1 to the second), then, when both are in, the go byte 'G' to both, and
from then on forwards every byte of one to the other. The games send 9
byte records (the tic, the 5 byte command, the consistency word); the
relay does not look inside them.

It exits when a game closes its connection (the other is closed too)
or after --seconds of nothing. With --log the records seen each way are
counted there once a second."""
import argparse
import select
import socket
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument('--port', type=int, default=5100)
ap.add_argument('--seconds', type=float, default=600, help='exit after this long idle')
ap.add_argument('--log', help='write the byte counts here, else stderr')
args = ap.parse_args()

out = open(args.log, 'a') if args.log else sys.stderr


def say(msg):
    out.write('%.1f %s\n' % (time.time() - T0, msg))
    out.flush()


T0 = time.time()
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', args.port))
srv.listen(2)
say('relay on 127.0.0.1:%d' % args.port)

players = []
while len(players) < 2:
    r, _, _ = select.select([srv], [], [], args.seconds)
    if not r:
        say('no players: exit')
        sys.exit(1)
    c, addr = srv.accept()
    c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    n = len(players)
    c.sendall(bytes([n]))
    players.append(c)
    say('player %d from %s:%d' % (n, addr[0], addr[1]))
for c in players:
    c.sendall(b'G')
say('go')

counts = [0, 0]
last = time.time()
idle = time.time()
while True:
    r, _, _ = select.select(players, [], [], 1.0)
    now = time.time()
    for c in r:
        data = c.recv(4096)
        i = players.index(c)
        if not data:
            say('player %d closed (%d, %d bytes forwarded)' % (i, counts[0], counts[1]))
            for p in players:
                p.close()
            sys.exit(0)
        counts[i] += len(data)
        players[1 - i].sendall(data)
        idle = now
    if now - last >= 1.0:
        say('bytes %d %d' % (counts[0], counts[1]))
        last = now
    if now - idle > args.seconds:
        say('idle: exit (%d, %d bytes forwarded)' % (counts[0], counts[1]))
        sys.exit(1)
