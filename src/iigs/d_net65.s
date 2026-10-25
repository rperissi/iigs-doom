;;; The net game: two players in lockstep through a CoGS card.
;;;
;;; Each machine builds the tic commands of its player as before
;;; (D_BuildNewTiccmds, the ring cmds of g_game65.s) and sends each new one
;;; to the other machine as a 9 byte record: the tic (16 bits), the 5 bytes
;;; of the command, and the consistency word of that tic. A tic runs when
;;; both commands are in (netmaketic, the tics that can run, replaces
;;; maketic in TryRunTics), so the two games stay on the same tic with the
;;; same commands and the same random numbers. The consistency word is
;;; Doom's: the low word of the x of the player's mobj CMDS tics ago, as
;;; each machine computed it, compared when the command comes.
;;;
;;; The card (CoGS spec v0.8): frames of opcode, 16 bit length, payload
;;; through the DATA register of the slot; CONNECT (0x10) opens a TCP
;;; socket to the relay (tools/dmrelay.py, or with NETFLAGS 9 a WebSocket
;;; over TLS to the lobby's Pair room, lobby.a2cogs.com/ws/pair?r=ROOM,
;;; firmware 1.36), SEND (0x11) carries a record, and the DATA events
;;; (0x91) of the socket bring the records of the other machine. The relay
;;; tells each machine its player number and when both are in. Only
;;; socket 0 is used; the card is reset first.
;;;
;;; NETGAME (make NETGAME=1): D_DoomMain calls D_NetJoin before the
;;; graphics start (the card is found, slots 7 to 1, its network waited
;;; for, the relay joined, with the progress on the startup text screen,
;;; as IPXSETUP's "Attempting to find all players"), then D_NetStart
;;; instead of the title. Without it the game is the one-player game and
;;; this file only keeps netmaketic equal to maketic.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"
#include "tics.inc"

#if TICSTEP > 1
CMDS          .equ    16              ; (as g_game65.s)
#else
CMDS          .equ    8
#endif
#ifndef NETPORT
#define NETPORT 5100
#endif
#ifndef NETFLAGS
#define NETFLAGS 0                      ; CONNECT flags: 0 plain, 9 TLS + WS
#endif

;;; The card: its registers are CARD + the slot's offset (slot * 16, in
;;; cardoff, found by findCard: slots 7 to 1, the DEVSEL signature: ID $A2
;;; at +5, VERSION not 0 at +6, STATUS not $FF at +1), so one disk serves
;;; every machine. Every register access is lda/sta long:CARD+r,x: the
;;; absolute long indexed mode has no extra cycle, unlike abs,X with a 16
;;; bit index, whose cycle 3a reads the address twice and pops DATA twice
;;; on a 65816.
CARD          .equ    0xE0C080
R_DATA        .equ    0
R_STATUS      .equ    1
R_CONTROL     .equ    4
R_ID          .equ    5
R_VERSION     .equ    6
ST_RXAVAIL    .equ    0x80            ; STATUS: a byte waits at DATA
ST_TXROOM     .equ    0x40            ;   the TX FIFO has room
OP_TIME       .equ    0x05
OP_CONNECT    .equ    0x10
OP_SEND       .equ    0x11
EV_TIME       .equ    0x85
EV_CONNECTED  .equ    0x90
EV_DATA       .equ    0x91
EV_CLOSED     .equ    0x92
EV_ERROR      .equ    0x93
EV_SEND_ACK   .equ    0x9a
REC_SIZE      .equ    9
NS_NONE       .equ    0               ; netstate: nothing yet
NS_CONNECTED  .equ    1               ;   the socket is open
NS_NUMBERED   .equ    2               ;   the relay said which player we are
NS_GO         .equ    3               ;   both machines are in
NS_FAILED     .equ    4               ;   the connect failed (netfail: why)
ADB_ESCAPE    .equ    0x35            ; the ADB key code of Esc
ADBQ_MASK     .equ    31              ; (i_iigs65.s)
JOIN_TRIES    .equ    5               ; connects before giving up
NET_WAIT      .equ    90              ; s for the card's network
GO_WAIT       .equ    600             ; s for the other player

              .extern _Dp, _g_player, _g_gametic, maketic, cmds
              .extern _g_resident, _g_consoleplayer, _g_playeringame
              .extern _g_deathmatch, _g_netgame, _g_nomonsters, P_SwapTo, G_DeferedInitNew
              .extern I_Error, I_GetTime, prndindex, _g_psave, G_ExitLevel
              .extern printf, iigs_adbq, iigs_adbqhead, iigs_adbqtail

              .section znear, bss
              .public netmaketic, netslot
netmaketic:   .space  2               ; the tics that can run (D_NetUpdate)
netslot:      .space  2               ; the card's slot, 0 before findCard
cardoff:      .space  2               ;   its slot * 16 (CARD + cardoff)
netfail:      .space  2               ; the connect result (NS_FAILED)
nettime:      .space  4               ; the card's TIME (0: no network yet)
netflag:      .space  2               ; a TIME reply came
nettries:     .space  2               ; the connects so far
NT_T0:        .space  2
netsent:      .space  4               ; the tics sent
peerhave:     .space  4               ; the tics of the other player in
netstate:     .space  2
rxstate:      .space  2               ; the frame parser: 0-2 the header
rxop:         .space  2
rxlen:        .space  2               ;   the payload bytes left
rxidx:        .space  2               ;   the payload byte
recpos:       .space  2               ; the record coming in
rec:          .space  10
NT_T:         .space  4
NT_C:         .space  6               ; a command on its way to a save slot

              .section zfar, bss
peercmds:     .space  (CMDS * 8)      ; the other player's commands, as cmds
cons:         .space  (2 * CMDS * 2)  ; consistency[player][tic & (CMDS-1)]
peercons:     .space  (CMDS * 2)      ; the consistency words that came

              .section cfar, rodata
#ifdef NETGAME
hostStr:      .asciz  NETHOST
hostEnd:
HOSTLEN       .equ    hostEnd - hostStr - 1
#endif
msgCard:      .asciz  "I_NetInit: CoGS card in slot %i\n"
msgNoNet:     .asciz  "I_NetInit: waiting for the card's network...\n"
#if (NETFLAGS & 8)
msgJoin:      .asciz  "I_NetInit: joining lobby.a2cogs.com...\n"
#else
msgJoin:      .asciz  "I_NetInit: joining the relay...\n"
#endif
msgFind:      .asciz  "Attempting to find all players...\n"
msgRetry:     .asciz  "I_NetInit: connect failed (%i), retrying\n"
msgFound:     .asciz  "Found all players.\n"
errNoCard:    .asciz  "I_NetInit: no CoGS card in slots 1-7\n"
errNoNet:     .asciz  "I_NetInit: the card has no network\n"
errAbort:     .asciz  "I_NetInit: aborted\n"
errTimeout:   .asciz  "I_NetInit: no other player came\n"
errConnect:   .asciz  "I_NetInit: connect failed (%i)\n"
errCard:      .asciz  "D_Net: the card reports an error (%i)\n"
errClosed:    .asciz  "D_Net: the other player left (%i)\n"
errSend:      .asciz  "D_Net: send failed (%i)\n"
errTic:       .asciz  "D_Net: tic %i came, %i expected\n"
errResident:  .asciz  "D_NetCmds: player %i resident\n"
errCons:      .asciz  "consistency failure (%i should be %i) at tic %i\n"

;;; ---------------------------------------------------------------------------
;;; void D_NetJoin(void): before the graphics start: the card (findCard),
;;; its network (TIME, not 0), CONNECT to the relay (again after a
;;; failure, JOIN_TRIES times), the player number and the go from it. The
;;; progress goes on the startup text screen; Esc quits.
;;; void D_NetStart(void): after D_NetJoin, instead of the title: both
;;; players ready to be born, the game.
;;; (Run once: in ProgCode, bank 5 with netcode, so its jsrs reach.)
;;; ---------------------------------------------------------------------------
say           .macro  msg                   ; printf(msg, the value pushed)
              lda     ##.word0 \msg
              sta     dp:.tiny _Dp
              lda     ##.word2 \msg
              sta     dp:.tiny (_Dp+2)
              jsl     long:printf
              .endm

#ifdef NETGAME
              .section netstart, text
              .public D_NetJoin, D_NetStart
D_NetJoin:    jsr     .kbank findCard
              bne     1$
              lda     ##.word0 errNoCard
              ldx     ##.word2 errNoCard
              brl     error
1$:           lda     .near netslot
              pha
              say     msgCard
              pla
              jsr     .kbank cardReset
              jsl     long:I_GetTime        ; the network: TIME not 0
              sta     .near NT_T0
              stz     .near nettries        ; (the message once)
2$:           jsr     .kbank askTime
              lda     .near nettime
              ora     .near (nettime+2)
              bne     5$
              lda     .near nettries
              bne     3$
              inc     .near nettries
              say     msgNoNet
3$:           jsl     long:I_GetTime
              sec
              sbc     .near NT_T0
              cmp     ##(NET_WAIT * CONST_TICRATE)
              bcc     4$
              lda     ##.word0 errNoNet
              ldx     ##.word2 errNoNet
              brl     error
4$:           lda     ##(2 * CONST_TICRATE) ; again in 2 s
              jsr     .kbank pause
              bra     2$
5$:           say     msgJoin
              stz     .near nettries
6$:           stz     .near netstate        ; CONNECT: sock 0, flags, port, host
              stz     .near rxstate
              stz     .near recpos
              jsr     .kbank drainRx
              lda     ##OP_CONNECT
              jsr     .kbank push8
              lda     ##(5 + HOSTLEN)
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              lda     ##NETFLAGS
              jsr     .kbank push8
              lda     ##(NETPORT & 0xff)
              jsr     .kbank push8
              lda     ##(NETPORT >> 8)
              jsr     .kbank push8
              lda     ##HOSTLEN
              jsr     .kbank push8
              ldx     ##0
7$:           lda     long:hostStr,x
              jsr     .kbank push8
              inx
              cpx     ##HOSTLEN
              bcc     7$
              say     msgFind
              jsl     long:I_GetTime        ; the number and the go
              sta     .near NT_T
8$:           jsr     .kbank pollRx
              lda     .near netstate
              cmp     ##NS_GO
              beq     12$
              cmp     ##NS_FAILED
              beq     10$
              jsr     .kbank escPressed
              bne     9$
              jsl     long:I_GetTime
              sec
              sbc     .near NT_T
              cmp     ##(GO_WAIT * CONST_TICRATE)
              bcc     8$
              lda     ##.word0 errTimeout
              ldx     ##.word2 errTimeout
              brl     error
9$:           lda     ##.word0 errAbort
              ldx     ##.word2 errAbort
              brl     error
10$:          inc     .near nettries        ; failed: again, JOIN_TRIES times
              lda     .near nettries
              cmp     ##JOIN_TRIES
              bcc     11$
              lda     .near netfail
              pha
              lda     ##.word0 errConnect
              ldx     ##.word2 errConnect
              brl     error
11$:          lda     .near netfail
              pha
              say     msgRetry
              pla
              lda     ##(3 * CONST_TICRATE)
              jsr     .kbank pause
              brl     6$
12$:          say     msgFound
              rtl

;;; findCard: cardoff and netslot for the card, slots 7 to 1 (Z clear),
;;; or netslot 0 (Z set). The signature: ID $A2, VERSION not 0, STATUS not
;;; $FF, the presence probe of the card's spec. The first read of a slot
;;; is ID: a read of $C0n5 is harmless on the Apple cards.
findCard:     ldx     ##0x70
1$:           sep     #0x20
              lda     long:CARD+R_ID,x
              cmp     #0xa2
              bne     2$
              lda     long:CARD+R_VERSION,x
              beq     2$
              lda     long:CARD+R_STATUS,x
              cmp     #0xff
              bne     3$
2$:           rep     #0x20                 ; (16 bits: B would ride into X)
              txa
              sec
              sbc     ##0x10
              tax
              bne     1$
              stz     .near netslot
              rts
3$:           rep     #0x20
              stx     .near cardoff
              txa
              lsr     a
              lsr     a
              lsr     a
              lsr     a
              sta     .near netslot
              rts

;;; cardReset: soft reset: no sockets, empty FIFOs; a moment for it.
cardReset:    ldx     .near cardoff
              sep     #0x20
              lda     #0x01
              sta     long:CARD+R_CONTROL,x
              rep     #0x20
              lda     ##4
              jsr     .kbank pause
              jmp     .kbank drainRx

;;; askTime: TIME to the card; nettime = its reply (0 without a reply
;;; within 2 s, as without a network).
askTime:      stz     .near netflag
              stz     .near nettime
              stz     .near (nettime+2)
              stz     .near rxstate
              lda     ##OP_TIME
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              jsl     long:I_GetTime
              sta     .near NT_T
1$:           jsr     .kbank pollRx
              lda     .near netflag
              bne     2$
              jsl     long:I_GetTime
              sec
              sbc     .near NT_T
              cmp     ##(2 * CONST_TICRATE)
              bcc     1$
2$:           rts

;;; pause: C tics go by.
pause:        sta     .near NT_T
              jsl     long:I_GetTime
              clc
              adc     .near NT_T
              sta     .near NT_T
1$:           jsl     long:I_GetTime
              sec
              sbc     .near NT_T
              bmi     1$
              rts

;;; escPressed: Z clear when Esc went down since the last call (the raw
;;; ADB ring of the interrupt, i_iigs65.s; the other keys are dropped).
escPressed:   ldx     .near iigs_adbqtail
1$:           cpx     .near iigs_adbqhead
              beq     3$
              lda     .near iigs_adbq,x     ; a key byte (bit 7: up)
              and     ##0x00ff
              inx
              cpx     ##(ADBQ_MASK + 1)
              bne     2$
              ldx     ##0
2$:           cmp     ##ADB_ESCAPE
              bne     1$
              stx     .near iigs_adbqtail   ; (A = ADB_ESCAPE: Z clear)
              rts
3$:           stx     .near iigs_adbqtail
              lda     ##0
              rts

D_NetStart:   lda     ##1                   ; a two-player deathmatch
              sta     .near _g_netgame
              sta     .near _g_deathmatch
#ifdef NOMONSTERS
              sta     .near _g_nomonsters
#endif
              sta     .near (_g_playeringame+2)
              sep     #0x20                 ; both players: a fresh struct,
              ldx     ##(SIZEOF_PL - 1)     ;   to be born (player 0 is
1$:           stz     .near _g_player,x     ;   resident, player 1 saved)
              lda     #0
              sta     long:(_g_psave + SIZEOF_PL),x
              dex
              bpl     1$
              rep     #0x20
              lda     ##CONST_PST_REBORN
              sta     .near (_g_player+OFS_PL_PLAYERSTATE)
              sta     long:(_g_psave + SIZEOF_PL + OFS_PL_PLAYERSTATE)
              lda     .near _g_consoleplayer
              jsl     long:P_SwapTo
              stz     .near netsent
              stz     .near (netsent+2)
              stz     .near peerhave
              stz     .near (peerhave+2)
              stz     .near netmaketic
              lda     ##CONST_SK_MEDIUM
              jsl     long:G_DeferedInitNew
              rtl
#endif

              .section netcode, text ; Code5d only (iigs.scm)

;;; ---------------------------------------------------------------------------
;;; void D_NetUpdate(void): TryRunTics, after D_BuildNewTiccmds: the new
;;; commands go out, the other player's come in, and netmaketic is the tic
;;; both have commands up to. The one-player game: netmaketic = maketic.
;;; ---------------------------------------------------------------------------
              .public D_NetUpdate
D_NetUpdate:  lda     .near _g_netgame
              bne     1$
              lda     .near maketic
              sta     .near netmaketic
              rtl
1$:           lda     .near netsent         ; the new tics out
              cmp     .near maketic
              beq     2$
              jsr     .kbank sendTic
              inc     .near netsent
              bne     1$
              inc     .near (netsent+2)
              bra     1$
2$:           jsr     .kbank pollRx         ; the other's in
              lda     .near peerhave        ; netmaketic = min(maketic, peerhave)
              sec
              sbc     .near maketic
              bmi     3$
              lda     .near maketic
              bra     4$
3$:           lda     .near peerhave
4$:           sta     .near netmaketic
              rtl

;;; sendTic: SEND the record of tic netsent: the tic, cmds[tic], and the
;;; consistency word of the console player at that tic.
sendTic:      lda     ##OP_SEND
              jsr     .kbank push8
              lda     ##(1 + REC_SIZE)
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              lda     ##0                   ; sock 0
              jsr     .kbank push8
              lda     .near netsent         ; the tic
              jsr     .kbank push8
              xba
              jsr     .kbank push8
              lda     .near netsent         ; the command
              and     ##(CMDS - 1)
              asl     a
              asl     a
              asl     a
              tax
              lda     .near cmds,x
              jsr     .kbank push8
              xba
              jsr     .kbank push8
              lda     .near (cmds+2),x
              jsr     .kbank push8
              xba
              jsr     .kbank push8
              lda     .near (cmds+4),x
              jsr     .kbank push8
              lda     .near netsent         ; the consistency word
              jsr     .kbank consIndex
              jsr     .kbank ownRing
              tax
              lda     long:cons,x
              jsr     .kbank push8
              xba
              jsr     .kbank push8
              rts

;;; consIndex: C = the offset of tic C in a consistency ring.
consIndex:    and     ##(CMDS - 1)
              asl     a
              rts

;;; ---------------------------------------------------------------------------
;;; void D_NetCmds(void): G_Ticker: the commands of tic gametic go to the
;;; players: the console player's (the ring cmds) to the resident struct,
;;; which is his, and in a net game the other's (peercmds) to his save
;;; slot. Then the consistency check of the other's command against what
;;; this machine saw, and the words of this tic for both players.
;;; ---------------------------------------------------------------------------
              .public D_NetCmds
D_NetCmds:    lda     .near _g_gametic
              and     ##(CMDS - 1)
              asl     a
              asl     a
              asl     a
              tax
              lda     .near cmds,x
              sta     .near (_g_player+OFS_PL_CMD)
              lda     .near (cmds+2),x
              sta     .near (_g_player+OFS_PL_CMD+2)
              sep     #0x20
              lda     .near (cmds+4),x
              sta     .near (_g_player+OFS_PL_CMD+4)
              rep     #0x20
              lda     .near _g_netgame
              bne     1$
              rtl
1$:           lda     .near _g_consoleplayer
              cmp     .near _g_resident
              beq     2$
              lda     .near _g_resident
              pha
              lda     ##.word0 errResident
              ldx     ##.word2 errResident
              brl     error
2$:           lda     long:peercmds,x       ; the other player's command to
              sta     .near NT_C            ;   his save slot
              lda     long:(peercmds+2),x
              sta     .near (NT_C+2)
              lda     long:(peercmds+4),x
              sta     .near (NT_C+4)
              lda     .near _g_consoleplayer
              eor     ##1
              jsr     .kbank slotOf
              lda     .near NT_C
              sta     long:(_g_psave+OFS_PL_CMD),x
              lda     .near (NT_C+2)
              sta     long:(_g_psave+OFS_PL_CMD+2),x
              sep     #0x20
              lda     .near (NT_C+4)
              sta     long:(_g_psave+OFS_PL_CMD+4),x
              ;; a special command (BT_SPECIAL | BTS_NETEXIT, g_game65.s)
              ;; from either player: the level ends, on both machines
              cmp     #(0x80 | 3)
              beq     5$
              lda     .near (_g_player+OFS_PL_CMD+4)
              cmp     #(0x80 | 3)
              bne     6$
5$:           lda     #0                    ; (no buttons from it)
              sta     .near (_g_player+OFS_PL_CMD+4)
              sta     long:(_g_psave+OFS_PL_CMD+4),x
              rep     #0x20
              phx
              jsl     long:G_ExitLevel
              plx
              sep     #0x20
6$:           rep     #0x20
#ifdef BENCHEXIT
              lda     .near _g_gametic      ; the bench's level end (Makefile)
              cmp     ##BENCHEXIT
              bne     7$
              jsl     long:G_ExitLevel
7$:
#endif
              lda     .near (_g_gametic+2)  ; gametic >= CMDS: the check
              bne     3$
              lda     .near _g_gametic
              cmp     ##CMDS
              bcc     4$
3$:           lda     .near _g_gametic      ; the word that came with the
              jsr     .kbank consIndex      ;   command
              tax
              lda     long:peercons,x
              sta     .near NT_T
              txa                           ; the word this machine saw
              jsr     .kbank otherRing
              tax
              lda     long:cons,x
              cmp     .near NT_T
              beq     4$
              pha                           ; consistency failure (%i should
              lda     .near _g_gametic      ;   be %i) at tic %i
              pha
              lda     long:cons,x
              pha
              lda     .near NT_T
              pha
              lda     ##.word0 errCons
              ldx     ##.word2 errCons
              brl     error
4$:           lda     .near _g_gametic      ; the words of this tic: the
              jsr     .kbank consIndex      ;   console player's (resident)
              jsr     .kbank ownRing
              sta     .near NT_T
              lda     .near (_g_player+OFS_PL_MO)
              sta     dp:.tiny _Dp
              lda     .near (_g_player+OFS_PL_MO+2)
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank consWord
              ldx     .near NT_T
              sta     long:cons,x
              lda     .near _g_gametic      ; the other's
              jsr     .kbank consIndex
              jsr     .kbank otherRing
              sta     .near NT_T
              lda     .near _g_consoleplayer
              eor     ##1
              jsr     .kbank slotOf
              lda     long:(_g_psave+OFS_PL_MO),x
              sta     dp:.tiny _Dp
              lda     long:(_g_psave+OFS_PL_MO+2),x
              sta     dp:.tiny (_Dp+2)
              jsr     .kbank consWord
              ldx     .near NT_T
              sta     long:cons,x
              rtl

;;; ownRing, otherRing: C = an offset in a consistency ring, made the
;;; offset in the console player's ring, or the other player's.
ownRing:      ldx     .near _g_consoleplayer
              beq     1$
              clc
              adc     ##(CMDS * 2)
1$:           rts
otherRing:    ldx     .near _g_consoleplayer
              bne     1$
              clc
              adc     ##(CMDS * 2)
1$:           rts

;;; consWord: C = the consistency word of the mobj at _Dp[0-3]: the low
;;; word of its x, or the random index when there is none (as Doom).
consWord:     lda     dp:.tiny _Dp
              ora     dp:.tiny (_Dp+2)
              beq     1$
              ldy     ##OFS_MO_X
              lda     [.tiny _Dp],y
              rts
1$:           lda     .near prndindex
              rts

;;; slotOf: C = a player; X = the offset of his save slot from _g_psave.
slotOf:       ldx     ##0
              cmp     ##0
              beq     1$
              ldx     ##SIZEOF_PL
1$:           rts

;;; ---------------------------------------------------------------------------
;;; The card.
;;; ---------------------------------------------------------------------------

;;; push8: the low byte of C goes to the card when its TX FIFO has room.
;;; Keeps C and X.
push8:        pha
              phx
              ldx     .near cardoff
              sep     #0x20
1$:           lda     long:CARD+R_STATUS,x
              and     #ST_TXROOM
              beq     1$
              lda     3,s
              sta     long:CARD+R_DATA,x
              rep     #0x20
              plx
              pla
              rts

;;; rxAvail: Z clear when the card has a byte for us. (X: the card.)
rxAvail:      ldx     .near cardoff
              sep     #0x20
              lda     long:CARD+R_STATUS,x
              rep     #0x20
              and     ##ST_RXAVAIL
              rts

;;; pop8: C = the next byte from the card (there is one). (X: the card.)
pop8:         ldx     .near cardoff
              sep     #0x20
              lda     long:CARD+R_DATA,x
              rep     #0x20
              and     ##0x00ff
              rts

;;; drainRx: whatever the card has queued is dropped.
drainRx:      jsr     .kbank rxAvail
              beq     1$
              jsr     .kbank pop8
              bra     drainRx
1$:           rts

;;; pollRx: every byte the card has goes through the frame parser.
pollRx:       jsr     .kbank rxAvail
              beq     1$
              jsr     .kbank pop8
              jsr     .kbank feed
              bra     pollRx
1$:           rts

;;; feed: one byte C of the card's stream: the 3 byte header (opcode,
;;; length), then the payload bytes of the frame.
feed:         ldx     .near rxstate
              beq     hdrOp
              dex
              beq     hdrLo
              dex
              beq     hdrHi
              inc     .near rxidx           ; a payload byte: rxidx counts from 1
              ldx     .near rxop
              cpx     ##EV_DATA
              bne     2$
              brl     dataByte
2$:           cpx     ##EV_CONNECTED
              bne     3$
              brl     connByte
3$:           cpx     ##EV_SEND_ACK
              bne     4$
              brl     ackByte
4$:           cpx     ##EV_ERROR
              bne     5$
              brl     errByte
5$:           cpx     ##EV_CLOSED
              bne     6$
              brl     closedByte
6$:           cpx     ##EV_TIME
              bne     payloadDone
              brl     timeByte
payloadDone:  dec     .near rxlen           ; the frame ends with its length
              bne     1$
              stz     .near rxstate
1$:           rts
hdrOp:        sta     .near rxop
              inc     .near rxstate
              rts
hdrLo:        sta     .near rxlen
              inc     .near rxstate
              rts
hdrHi:        xba
              and     ##0xff00
              ora     .near rxlen
              sta     .near rxlen
              stz     .near rxidx
              inc     .near rxstate
              lda     .near rxlen           ; no payload: done
              bne     2$
              stz     .near rxstate
2$:           rts

;;; connByte: EV_CONNECTED: sock, result. result 0: connected.
connByte:     ldx     .near rxidx
              cpx     ##2
              bne     done
              cmp     ##0
              bne     failed
              lda     ##NS_CONNECTED
              sta     .near netstate
              brl     payloadDone
failed:       sta     .near netfail         ; D_NetJoin tries again
              lda     ##NS_FAILED
              sta     .near netstate
              brl     payloadDone

;;; timeByte: EV_TIME: the 4 bytes of the card's clock (0: no network).
timeByte:     ldx     .near rxidx           ; (rxidx counts from 1)
              dex
              sep     #0x20
              sta     .near nettime,x
              rep     #0x20
              cpx     ##3
              bne     done
              inc     .near netflag
              brl     payloadDone

;;; ackByte: EV_SEND_ACK: sock, result.
ackByte:      ldx     .near rxidx
              cpx     ##2
              bne     done
              cmp     ##0
              beq     done
              pha
              lda     ##.word0 errSend
              ldx     ##.word2 errSend
              brl     error

;;; errByte: EV_ERROR: sock, code, ...   closedByte: EV_CLOSED: sock, reason.
errByte:      ldx     .near rxidx
              cpx     ##2
              bne     done
              pha
              lda     ##.word0 errCard
              ldx     ##.word2 errCard
              brl     error
closedByte:   ldx     .near rxidx
              cpx     ##2
              bne     done
              ldx     .near netstate
              cpx     ##NS_GO
              bne     failed
              pha
              lda     ##.word0 errClosed
              ldx     ##.word2 errClosed
              brl     error
done:         brl     payloadDone

;;; dataByte: EV_DATA: sock, bytes. Before the go the relay sends our
;;; player number, then 'G'; after, the records of the other player.
dataByte:     ldx     .near rxidx
              cpx     ##1                   ; the sock byte
              beq     done
              ldx     .near netstate
              cpx     ##NS_GO
              beq     recByte
              cpx     ##NS_CONNECTED
              bne     1$
              and     ##1                   ; our number
              sta     .near _g_consoleplayer
              lda     ##NS_NUMBERED
              sta     .near netstate
              brl     payloadDone
1$:           cpx     ##NS_NUMBERED
              bne     done           ; (early bytes: dropped)
              cmp     ##'G'
              bne     done
              lda     ##NS_GO
              sta     .near netstate
              brl     payloadDone

;;; recByte: a byte of a record: tic (2), command (5), consistency (2).
recByte:      ldx     .near recpos
              sep     #0x20
              sta     .near rec,x
              rep     #0x20
              inx
              stx     .near recpos
              cpx     ##REC_SIZE
              bcc     done
              stz     .near recpos
              lda     .near rec             ; the tic we wait for
              cmp     .near peerhave
              beq     1$
              pei     dp:.tiny _Dp
              lda     .near peerhave
              pha
              lda     .near rec
              pha
              lda     ##.word0 errTic
              ldx     ##.word2 errTic
              brl     error
1$:           and     ##(CMDS - 1)
              asl     a
              asl     a
              asl     a
              tax
              lda     .near (rec+2)
              sta     long:peercmds,x
              lda     .near (rec+4)
              sta     long:(peercmds+2),x
              lda     .near (rec+6)
              sta     long:(peercmds+4),x
              lda     .near peerhave
              jsr     .kbank consIndex
              tax
              lda     .near (rec+7)
              sta     long:peercons,x
              inc     .near peerhave
              bne     2$
              inc     .near (peerhave+2)
2$:           brl     payloadDone

;;; error: I_Error(the format at X:C, the values pushed before).
error:        sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              jsl     long:I_Error
              rts
