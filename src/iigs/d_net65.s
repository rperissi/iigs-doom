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
;;; over TLS to the lobby, lobby.a2cogs.com/ws/match?g=doom&v=1&n=NAME
;;; [&c=CODE], which queues the player like /v1/join and relays the two
;;; seats' frames; firmware 1.36), SEND (0x11) carries a record, and the DATA events
;;; (0x91) of the socket bring the records of the other machine. The relay
;;; tells each machine its player number and when both are in. Only
;;; socket 0 is used; the card is reset first.
;;;
;;; NETGAME (make NETGAME=1): NETWORK GAME is the second row of the main
;;; menu (D_NetMainMenu puts it in, out during a game): its page is the
;;; game (deathmatch or cooperative), the skill, the map, the monsters,
;;; a room code and FIND PLAYERS, which starts the join: a state machine
;;; run from D_NetUpdate (D_NetJoinTick), so the menu and the demo behind
;;; it go on: the card (findCard, slots 7 to 1), its network (TIME not
;;; 0), the relay (CONNECT, again after a failure), the player number and
;;; the go from it, and for player 1 the setup record of player 0 (the
;;; game is player 0's choice). Then the game (startGame): both players
;;; to be born, the tic counters from 0 on both machines, a new game at
;;; the next tic. The progress goes on the page, as IPXSETUP's
;;; "Attempting to find all players"; Esc cancels. AUTOJOIN (the bench):
;;; the game opens the page and starts the join itself instead of the
;;; title. Without NETGAME the game is the one-player game and this file
;;; only keeps netmaketic equal to maketic.

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
;;; NETROOM: the room code the page starts with (none: blank, the public
;;; room); make passes it only when ROOM is set.

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
OP_CLOSE      .equ    0x12
OP_HTTP       .equ    0x20
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
JOIN_TRIES    .equ    5               ; connects before giving up
NET_WAIT      .equ    90              ; s for the card's network
GO_WAIT       .equ    600             ; s for the other player
SETUP_TIC     .equ    0xffff          ; the special records (recByte):
NAME_TIC      .equ    0xfffe          ;   a player's name, letters 0-6
NAME2_TIC     .equ    0xfffd          ;   letter 7
REQ_TIC       .equ    0xfffc          ;   send the records from tic X again
                                      ;   (the lowest special tic)
SENT          .equ    16              ; the records sent, kept for REQ_TIC
REQ_WAIT      .equ    35              ; tics between two requests of a gap

;;; The page (m_menu65.s: MENU_SOUND, no menu of its own now, is its
;;; number; the skull goes by menuX, menuY and menuLine of it).
MENU_NET      .equ    14
MENU_LOAD     .equ    4
MENU_OPTIONS  .equ    6
MENU_SAVE     .equ    10
L_NETGM       .equ    68              ; the lumps (m_menu65.s)
L_OPTION      .equ    4
L_LOADG       .equ    6
L_QUITG       .equ    8
L_SAVEG       .equ    66
EV_DATA1      .equ    2               ; event_t (type 0: ev_keydown)
NM_ROWS       .equ    7               ; the rows
R_GAME        .equ    0
R_SKILL       .equ    1
R_MAP         .equ    2
R_MON         .equ    3
R_NAME        .equ    4
R_CODE        .equ    5
R_FIND        .equ    6
NM_X          .equ    60              ; the rows: x, y, the line
NM_Y          .equ    36
NM_LINE       .equ    16
NM_RIGHT      .equ    284             ;   the values end here
ST_Y          .equ    150             ; the status lines: y, the line
ST_LINE       .equ    10
ST_MAX        .equ    4               ;   lines shown (the older ones go)
CODE_MAX      .equ    8               ; the letters of a name or room code
JP_NONE       .equ    0               ; netphase: the page
JP_CARD       .equ    1               ;   FIND PLAYERS: the card
JP_TIME       .equ    2               ;   its network
JP_CONNECT    .equ    3               ;   CONNECT
JP_FIND       .equ    4               ;   the other player
JP_RETRY      .equ    5               ;   a moment before the next CONNECT
JP_SETUP      .equ    6               ;   player 1: the setup record
JP_ERROR      .equ    7               ;   it failed (the lines say why)

              .extern _Dp, _g_player, _g_gametic, maketic, cmds
              .extern _g_resident, _g_consoleplayer, _g_playeringame
              .extern _g_deathmatch, _g_netgame, _g_nomonsters, P_SwapTo
#ifdef NETGAME
              .extern M_NetLeft, M_NetLost
              .public rxstate, recpos   ; (lvRead, w_level65.s: a block read
#endif                                  ;   empties the card's queue)
              .extern _g_frags
              .extern I_Error, I_GetTime, prndindex, _g_psave, G_ExitLevel
#ifdef NETGAME
              .extern G_DeferedInitNewMap, _g_usergame, _g_menuactive, menutic
              .extern D_StartTitle, M_StartControlPanel, M_DrawSkull
              .extern I_MenuPalette, I_MenuPaletteBack, S_StartSound
              .extern uiMain, uiWriteLine, uiLineWidth, MT_X, MT_Y, MT_P
              .extern currentMenu, itemOn, menuversion, menuNum, menuX, menuY
              .extern menuLine, menuPrevItem, itemLump, itemRoutine
              .extern responderEventL, netGame, options, loadGame, saveGame
              .extern quitDoom, key_menu_up, key_menu_down, key_menu_left
              .extern key_menu_right, key_menu_enter, key_menu_escape
              .extern key_menu_back, key_fire
#endif

              .section znear, bss
              .public netmaketic, netslot
netmaketic:   .space  2               ; the tics that can run (D_NetUpdate)
netslot:      .space  2               ; the card's slot, 0 before findCard
cardoff:      .space  2               ;   its slot * 16 (CARD + cardoff)
netfail:      .space  2               ; the connect result (NS_FAILED)
nettime:      .space  4               ; the card's TIME (0: no network yet)
netflag:      .space  2               ; a TIME reply came
nettries:     .space  2               ; the connects so far
connshown:    .space  2               ; a retry's connect went through (said)
rtwait:       .space  2               ; the retry's wait (tics)
NT_T0:        .space  2
netphase:     .space  2               ; the join (JP_*)
hostlen:      .space  2               ; the host of CONNECT (hostbuf)
statn:        .space  2               ; the status lines: their count,
stat:         .space  (6 * ST_MAX)    ;   each a string, a number (0xffff:
                                      ;   none) and a string (0: none)
nm_ch:        .space  2               ; the key
nm_setup:     .space  2               ; the setup record came
NM_I:         .space  2
NM_S:         .space  2
NM_W:         .space  2
NM_MODE:      .space  2
NM_O:         .space  2
NM_T:         .space  2
NM_N:         .space  2
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
txtic:        .space  2               ; the tic of the record going out
gapwait:      .space  2               ; 1: records of the other player are
                                      ;   missing (a REQ_TIC is out)
reqtic:       .space  2               ; the tic the last REQ_TIC asked for
reqtime:      .space  4               ;   and when (I_GetTime)
reqrec:       .space  10              ;   the REQ_TIC record

              .section zfar, bss
peercmds:     .space  (CMDS * 8)      ; the other player's commands, as cmds
cons:         .space  (2 * CMDS * 2)  ; consistency[player][tic & (CMDS-1)]
peercons:     .space  (CMDS * 2)      ; the consistency words that came
sentrecs:     .space  (SENT * 16)     ; the last SENT records out (REC_SIZE
                                      ;   bytes at 16 each): sent again on
                                      ;   REQ_TIC. The card's block driver
                                      ;   empties the card's queue at every
                                      ;   read (a 4 MB machine reads the
                                      ;   level), so records get lost.
hostbuf:      .space  80              ; the host of CONNECT: NETHOST, and
                                      ;   with a WebSocket the name and code

#ifdef NETGAME
              .section near, data     ; the page's choices
nm_dm:        .word   1               ; GAME: 1 deathmatch, 0 cooperative
nm_skill:     .word   CONST_SK_MEDIUM
nm_map:       .word   1
nm_mon:       .word   1               ; MONSTERS: 1 on
nm_lens:                              ; the letters typed (typed: X)
nm_nlen:      .word   0               ;   YOUR NAME (none: DOOMGUY)
nm_clen:      .word   (nm_codeEnd - nm_code - 1) ;   ROOM CODE (none: public)
#endif

              .section cfar, rodata
#ifdef NETGAME
hostStr:      .asciz  NETHOST
hostEnd:
HOSTLEN       .equ    hostEnd - hostStr - 1
#endif
errCard:      .asciz  "D_Net: the card reports an error (%i)\n"
errClosed:    .asciz  "D_Net: the other player left (%i)\n"
errSend:      .asciz  "D_Net: send failed (%i)\n"
errTic:       .asciz  "D_Net: tic %i came, %i expected\n"
errResident:  .asciz  "D_NetCmds: player %i resident\n"
errCons:      .asciz  "consistency failure (%i should be %i) at tic %i\n"

;;; ---------------------------------------------------------------------------
;;; The NETWORK GAME page (NETGAME). m_menu65.s calls in through three
;;; hooks: D_NetMainMenu (M_StartControlPanel's end), D_NetDrawHook
;;; (M_Drawer, before the items) and D_NetResponder (M_Responder), and
;;; through the row's routine, D_NetMenuOpen. D_NetJoinTick is the join,
;;; from D_NetUpdate. D_NetStart (AUTOJOIN) starts it all at the start.
;;; (Run once or seldom, all in bank 5 with netcode so the jsrs reach:
;;; the page itself, netpage, in NetPage at the tail of the bank, the
;;; join, the names and the score, netstart, in ProgCode. The strings are
;;; in netstart too, so one bank serves them all; strPtr takes the bank
;;; of strTitle.)
;;; ---------------------------------------------------------------------------
status        .macro  s1, s2                ; a status line: the string, the
              lda     ##.word0 \s1          ;   number in X (0xffff: none),
              ldy     ##\s2                 ;   the string after it (0: none)
              jsr     .kbank addLine
              .endm

#ifdef NETGAME
              .section netpage, text  ; NetPage only (iigs.scm)

;;; D_NetMainMenu: uiMain (the last row: QUIT or END GAME), then NETWORK
;;; GAME as the second row when no game is on; during a game the row is
;;; out and the rows are the stock ones (the others' parent items follow).
              .public D_NetMainMenu
D_NetMainMenu:
              jsl     long:uiMain
              lda     .near _g_usergame
              bne     2$
              lda     ##6
              sta     long:menuNum
              ldx     ##0
1$:           lda     long:rowLumps,x
              sta     long:(itemLump+2),x
              lda     long:rowRoutines,x
              sta     long:(itemRoutine+2),x
              inx
              inx
              cpx     ##10
              bcc     1$
              lda     ##2
              sta     long:(menuPrevItem+MENU_OPTIONS)
              lda     ##3
              sta     long:(menuPrevItem+MENU_LOAD)
              lda     ##4
              sta     long:(menuPrevItem+MENU_SAVE)
              rtl
2$:           ldx     ##0
3$:           lda     long:(rowLumps+2),x
              sta     long:(itemLump+2),x
              lda     long:(rowRoutines+2),x
              sta     long:(itemRoutine+2),x
              inx
              inx
              cpx     ##6
              bcc     3$
              lda     ##1
              sta     long:(menuPrevItem+MENU_OPTIONS)
              lda     ##2
              sta     long:(menuPrevItem+MENU_LOAD)
              lda     ##3
              sta     long:(menuPrevItem+MENU_SAVE)
              rtl
rowLumps:     .word   L_NETGM, L_OPTION, L_LOADG, L_SAVEG, L_QUITG
rowRoutines:  .word   .word0 netGame, .word0 options, .word0 loadGame
              .word   .word0 saveGame, .word0 quitDoom

;;; D_NetMenuOpen: the row's routine: the page, at its first row.
              .public D_NetMenuOpen
D_NetMenuOpen:
              lda     ##MENU_NET
              sta     .near currentMenu
              stz     .near itemOn
              lda     ##NM_ROWS
              sta     long:(menuNum+MENU_NET)
              lda     ##NM_X
              sta     long:(menuX+MENU_NET)
              lda     ##NM_Y
              sta     long:(menuY+MENU_NET)
              lda     ##NM_LINE
              sta     long:(menuLine+MENU_NET)
              stz     .near netphase
              stz     .near statn
              rtl

;;; D_NetStart (AUTOJOIN): instead of the title: the title, the page, the
;;; join.
              .public D_NetStart
D_NetStart:   jsl     long:D_StartTitle
              jsl     long:M_StartControlPanel
              jsl     long:D_NetMenuOpen
              lda     ##R_FIND
              sta     .near itemOn
              lda     ##JP_CARD
              sta     .near netphase
              rtl

;;; D_NetDrawHook: M_Drawer, after the message and before the items:
;;; I_MenuPalette, and the page when it is the menu: the title, the rows
;;; with their values, the status lines, the skull; then M_Drawer is
;;; done (its return goes, ours is to its caller).
              .public D_NetDrawHook
D_NetDrawHook:
              jsl     long:I_MenuPalette
              lda     .near currentMenu
              cmp     ##MENU_NET
              beq     1$
              rtl
1$:           pei     dp:.tiny (_Dp+8)      ; (the saved scratch: the text)
              pei     dp:.tiny (_Dp+10)
              lda     ##20
              sta     .near MT_Y
              lda     ##.word0 strTitle
              jsr     .kbank putCenter
              stz     .near NM_I            ; the rows
2$:           lda     .near NM_I
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     ##NM_Y
              sta     .near MT_Y
              lda     ##NM_X
              sta     .near MT_X
              lda     .near NM_I
              asl     a
              tax
              lda     long:rowLabels,x
              jsr     .kbank putStr
              lda     .near NM_I
              asl     a
              tax
              jsr     .kbank valueOf
              beq     3$
              jsr     .kbank putRight
3$:           inc     .near NM_I
              lda     .near NM_I
              cmp     ##NM_ROWS
              bcc     2$
              stz     .near NM_I            ; the status lines
4$:           lda     .near NM_I
              cmp     .near statn
              bcs     5$
              asl     a                     ; y = ST_Y + 10 i
              sta     .near NM_O
              asl     a
              asl     a
              clc
              adc     .near NM_O
              clc
              adc     ##ST_Y
              sta     .near MT_Y
              lda     .near NM_O            ; 6 i
              asl     a
              clc
              adc     .near NM_O
              tax
              jsr     .kbank putStat
              inc     .near NM_I
              bra     4$
5$:           jsl     long:M_DrawSkull
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              tsc                           ; M_Drawer's return goes
              clc
              adc     ##3
              tcs
              rtl

;;; valueOf: C = the value string of row X (x 2), 0 for none; Z from it.
valueOf:      cpx     ##(2 * R_GAME)
              bne     1$
              lda     .near nm_dm
              beq     11$
              lda     ##.word0 strDM
              rts
11$:          lda     ##.word0 strCoop
              rts
1$:           cpx     ##(2 * R_SKILL)
              bne     2$
              lda     .near nm_skill
              asl     a
              tax
              lda     long:skillNames,x
              rts
2$:           cpx     ##(2 * R_MAP)
              bne     3$
              lda     .near nm_map
              clc
              adc     ##'0'
              sep     #0x20
              sta     long:(mapbuf+3)
              rep     #0x20
              lda     ##.word0 mapbuf
              rts
3$:           cpx     ##(2 * R_MON)
              bne     4$
              lda     .near nm_mon
              beq     31$
              lda     ##.word0 strOn
              rts
31$:          lda     ##.word0 strOff
              rts
4$:           cpx     ##(2 * R_CODE)
              bne     5$
              lda     .near nm_clen
              beq     41$
              lda     ##.word0 nm_code
              rts
41$:          lda     ##.word0 strPublic
              rts
5$:           cpx     ##(2 * R_NAME)
              bne     6$
              lda     .near nm_nlen
              beq     51$
              lda     ##.word0 nm_name
              rts
51$:          lda     ##.word0 strDefName
              rts
6$:           lda     ##0
              rts

;;; putStr: the string C (this bank) at MT_X, MT_Y; MT_X past it.
;;; strWidth: C = the width of the string C.
;;; putRight: the string C ending at NM_RIGHT. putCenter: centered on 160.
putStr:       sta     dp:.tiny (_Dp+8)
              lda     ##.word2 strTitle
              sta     dp:.tiny (_Dp+10)
              stz     .near MT_P
              jsl     long:uiWriteLine
              rts
strWidth:     sta     dp:.tiny (_Dp+8)
              lda     ##.word2 strTitle
              sta     dp:.tiny (_Dp+10)
              stz     .near MT_P
              jsl     long:uiLineWidth
              rts
putRight:     pha
              jsr     .kbank strWidth
              eor     ##0xffff              ; NM_RIGHT - the width
              sec
              adc     ##NM_RIGHT
              sta     .near MT_X
              pla
              bra     putStr
putCenter:    pha
              jsr     .kbank strWidth
              lsr     a
              eor     ##0xffff
              sec
              adc     ##160
              sta     .near MT_X
              pla
              bra     putStr

;;; putStat: the status line at X (its offset in stat), centered: the
;;; string, the number (not 0xffff) and the string after it (not 0).
;;; statPieces does the three: measured (NM_MODE 0, into NM_W) or put.
putStat:      stx     .near NM_S
              lda     .near (stat+2),x
              cmp     ##0xffff
              beq     1$
              jsr     .kbank toDec
1$:           stz     .near NM_MODE
              stz     .near NM_W
              jsr     .kbank statPieces
              lda     .near NM_W
              lsr     a
              eor     ##0xffff
              sec
              adc     ##160
              sta     .near MT_X
              inc     .near NM_MODE
statPieces:   ldx     .near NM_S
              lda     .near stat,x
              jsr     .kbank piece
              ldx     .near NM_S
              lda     .near (stat+2),x
              cmp     ##0xffff
              beq     1$
              lda     ##.word0 numbuf
              jsr     .kbank piece
1$:           ldx     .near NM_S
              lda     .near (stat+4),x
              beq     2$
              jsr     .kbank piece
2$:           rts
piece:        ldy     .near NM_MODE
              beq     1$
              brl     putStr
1$:           jsr     .kbank strWidth
              clc
              adc     .near NM_W
              sta     .near NM_W
              rts

;;; toDec: numbuf = C (0 to 99) in decimal.
toDec:        ldx     ##0
1$:           cmp     ##10
              bcc     2$
              sbc     ##10
              inx
              bra     1$
2$:           clc
              adc     ##'0'
              sta     .near NM_T            ; the ones
              txa
              beq     3$
              clc
              adc     ##'0'
              sep     #0x20
              sta     long:numbuf
              lda     .near NM_T
              sta     long:(numbuf+1)
              lda     #0
              sta     long:(numbuf+2)
              rep     #0x20
              rts
3$:           sep     #0x20
              lda     .near NM_T
              sta     long:numbuf
              lda     #0
              sta     long:(numbuf+1)
              rep     #0x20
              rts

;;; addLine: a status line: the string C, the number X (0xffff: none),
;;; the string Y after it (0: none). The oldest goes when ST_MAX are up.
;;; The page is drawn again (menuversion).
addLine:      sta     .near NM_T
              stx     .near NM_N
              sty     .near NM_S
              lda     .near statn
              cmp     ##ST_MAX
              bcc     2$
              ldx     ##0
1$:           lda     .near (stat+6),x
              sta     .near stat,x
              inx
              inx
              cpx     ##(6 * (ST_MAX - 1))
              bcc     1$
              lda     ##(ST_MAX - 1)
              sta     .near statn
2$:           lda     .near statn
              asl     a
              sta     .near NM_O
              asl     a
              clc
              adc     .near NM_O
              tax
              lda     .near NM_T
              sta     .near stat,x
              lda     .near NM_N
              sta     .near (stat+2),x
              lda     .near NM_S
              sta     .near (stat+4),x
              inc     .near statn
              inc     .near menuversion
              rts

;;; D_NetResponder: M_Responder's event (_Dp[0-3]): the page's keys when
;;; it is the menu (carry set: eaten), else the menus' (responderEvent).
;;; The page: up and down move, left, right and Return change a value
;;; (Return on FIND PLAYERS starts the join), letters and digits go in
;;; the room code and Delete takes one out, Esc goes back to the main
;;; menu. A join or its error: Esc stops it (the socket closes with the
;;; card's reset).
              .public D_NetResponder
D_NetResponder:
              lda     .near currentMenu
              cmp     ##MENU_NET
              beq     1$
              jsl     long:responderEventL
              rtl
1$:           lda     [.tiny _Dp]           ; key downs only
              bne     rNo
              ldy     ##EV_DATA1
              lda     [.tiny _Dp],y
              sta     .near nm_ch
              lda     .near netphase
              beq     rPage
              lda     .near nm_ch           ; a join or its error: Esc
              cmp     .near key_menu_escape
              bne     rNo
              lda     .near netphase
              cmp     ##JP_ERROR
              beq     2$
              lda     .near netslot
              beq     2$
              jsr     .kbank cardReset
2$:           stz     .near netphase
              stz     .near statn
              brl     rSwitch
rNo:          clc
              rtl
rPage:        lda     .near nm_ch
              cmp     .near key_menu_down
              bne     1$
              lda     .near itemOn          ; down: the next row, or the first
              inc     a
              cmp     ##NM_ROWS
              bcc     11$
              lda     ##0
11$:          sta     .near itemOn
              brl     rMove
1$:           cmp     .near key_menu_up
              bne     2$
              lda     .near itemOn          ; up: the row before, or the last
              bne     21$
              lda     ##NM_ROWS
21$:          dec     a
              sta     .near itemOn
              brl     rMove
2$:           cmp     .near key_menu_left
              bne     3$
              lda     ##0xffff              ; left: the value before
              bra     41$
3$:           cmp     .near key_menu_right
              bne     4$
31$:          lda     ##1                   ; right: the next
41$:          jsr     .kbank change
              lda     ##CONST_SFX_STNMOV
              brl     rYes
4$:           cmp     .near key_menu_enter
              bne     5$
              lda     .near itemOn
              cmp     ##R_FIND
              bne     31$                   ; (a value row: as right)
              lda     ##JP_CARD             ; FIND PLAYERS: the join
              sta     .near netphase
              stz     .near statn
              lda     ##CONST_SFX_PISTOL
              brl     rYes
5$:           cmp     .near key_menu_back   ; Delete: a letter of the name
              bne     6$                    ;   or the code
              jsr     .kbank typed
              bcc     9$
              lda     .near nm_lens,x
              beq     9$
              dec     a
              sta     .near nm_lens,x
              tya
              clc
              adc     .near nm_lens,x
              tax
              sep     #0x20
              lda     #0
              sta     long:nm_name,x
              rep     #0x20
              bra     rMove
6$:           cmp     .near key_menu_escape
              beq     9$
              cmp     .near key_fire
              beq     9$
              jsr     .kbank typed          ; a letter or a digit: the name
              bcc     rEat                  ;   or the code
              lda     .near nm_lens,x
              cmp     ##CODE_MAX
              bcs     rEat
              lda     .near nm_ch
              cmp     ##'0'
              bcc     rEat
              cmp     ##('9' + 1)
              bcc     7$
              cmp     ##'A'
              bcc     rEat
              cmp     ##('Z' + 1)
              bcc     7$
              cmp     ##'a'
              bcc     rEat
              cmp     ##('z' + 1)
              bcs     rEat
              sbc     ##('a' - 'A' - 1)     ; (carry clear) as upper case
7$:           pha
              tya
              clc
              adc     .near nm_lens,x
              inc     .near nm_lens,x
              tax
              pla
              sep     #0x20
              sta     long:nm_name,x
              lda     #0
              sta     long:(nm_name+1),x
              rep     #0x20
              bra     rMove
9$:           stz     .near currentMenu     ; back: the main menu, at the row
              lda     ##1
              sta     .near itemOn
              bra     rSwitch
rEat:         sec
              rtl
rMove:        lda     ##CONST_SFX_PSTOP
              bra     rYes
rSwitch:      lda     ##CONST_SFX_SWTCHX
rYes:         stz     dp:.tiny _Dp          ; S_StartSound(NULL, C)
              stz     dp:.tiny (_Dp+2)
              jsl     long:S_StartSound
              sec
              rtl

;;; typed: carry set when row itemOn is typed (YOUR NAME, ROOM CODE), with
;;; X its index into nm_lens and Y its buffer's offset from nm_name.
typed:        lda     .near itemOn
              sec
              sbc     ##R_NAME
              cmp     ##2
              bcs     1$
              asl     a
              tax
              beq     2$
              lda     ##(CODE_MAX + 1)
2$:           tay
              sec
              rts
1$:           clc
              rts

;;; change: the value of row itemOn, C = 1 the next, -1 the one before.
change:       ldx     .near itemOn
              cpx     ##R_GAME
              bne     1$
              lda     .near nm_dm
              eor     ##1
              sta     .near nm_dm
              rts
1$:           cpx     ##R_MON
              bne     2$
              lda     .near nm_mon
              eor     ##1
              sta     .near nm_mon
              rts
2$:           cpx     ##R_SKILL
              bne     3$
              clc
              adc     .near nm_skill
              bmi     9$
              cmp     ##(CONST_SK_NIGHTMARE + 1)
              bcs     9$
              sta     .near nm_skill
9$:           rts
3$:           cpx     ##R_MAP
              bne     9$
              clc
              adc     .near nm_map          ; 1 to 9, around
              beq     4$
              cmp     ##10
              bcc     5$
              lda     ##1
              bra     5$
4$:           lda     ##9
5$:           sta     .near nm_map
              rts

              .section netstart, text ; ProgCode only (iigs.scm)

;;; D_NetJoinTick: D_NetUpdate while a join is on: its next step
;;; (netphase). Nothing blocks for long: the card is polled, the times
;;; are I_GetTime's.
              .public D_NetJoinTick
D_NetJoinTick:
              lda     .near netphase
              asl     a
              tax
              jmp     (.kbank phases,x)
phases:       .word   .word0 tickNone, .word0 tickCard, .word0 tickTime
              .word   .word0 tickConnect, .word0 tickFind, .word0 tickRetry
              .word   .word0 tickSetup, .word0 tickNone

;;; The card: found, reset, asked for its TIME.
tickCard:     jsr     .kbank findCard
              beq     1$
              ldx     .near netslot
              status  strCard, 0
              jsr     .kbank cardReset
              jsl     long:I_GetTime
              sta     .near NT_T0
              stz     .near nettries        ; (the no-network line once)
              jsr     .kbank sendTime
              lda     ##JP_TIME
              sta     .near netphase
              rts
1$:           ldx     ##0xffff
              status  errNoCard, 0
toError:      lda     ##JP_ERROR
              sta     .near netphase
tickNone:     rts

;;; Its network: TIME not 0 (asked again each 2 s, NET_WAIT s).
tickTime:     jsr     .kbank pollRx
              lda     .near netflag
              beq     2$
              lda     .near nettime
              ora     .near (nettime+2)
              beq     1$
              lda     ##JP_CONNECT
              sta     .near netphase
              stz     .near nettries
              rts
1$:           lda     .near nettries
              bne     2$
              inc     .near nettries
              ldx     ##0xffff
              status  strNoNet, 0
2$:           jsl     long:I_GetTime
              sec
              sbc     .near NT_T0
              cmp     ##(NET_WAIT * CONST_TICRATE)
              bcc     3$
              ldx     ##0xffff
              status  errNoNet, 0
              brl     toError
3$:           jsl     long:I_GetTime
              sec
              sbc     .near NT_T
              cmp     ##(2 * CONST_TICRATE)
              bcc     4$
              jsr     .kbank sendTime
4$:           rts

;;; CONNECT to the relay (the lines once, not again for a retry).
tickConnect:  lda     .near nettries
              bne     1$
              ldx     ##0xffff
              status  strJoin, 0
              ldx     ##0xffff
              status  strFind, 0
1$:           sep     #0x20                 ; (the last session's name)
              lda     #0
              sta     long:peername
              rep     #0x20
              stz     .near connshown
              jsr     .kbank buildHost
              jsr     .kbank sendConnect
              jsl     long:I_GetTime
              sta     .near NT_T
              lda     ##JP_FIND
              sta     .near netphase
              rts

;;; The player number and the go (GO_WAIT s); a failed connect: again
;;; after 3 s, JOIN_TRIES times.
tickFind:     jsr     .kbank pollRx
              lda     .near netstate
              cmp     ##NS_GO
              bne     3$
              brl     go
3$:           cmp     ##NS_FAILED
              beq     connFailed
              cmp     ##NS_CONNECTED        ; a retry's connect went through:
              bcc     2$                    ;   the FAILED line stands, so say
              lda     .near connshown       ;   the finding is on again
              bne     2$
              inc     .near connshown
              lda     .near nettries
              beq     2$
              ldx     ##0xffff
              status  strFind, 0
2$:           jsl     long:I_GetTime
              sec
              sbc     .near NT_T
              cmp     ##(GO_WAIT * CONST_TICRATE)
              bcc     1$
              ldx     ##0xffff
              status  errTimeout, 0
              brl     toError
1$:           rts
connFailed:   inc     .near nettries
              lda     .near nettries
              cmp     ##JOIN_TRIES
              bcc     3$
              ldx     .near netfail
              status  strFailed, .word0 strParen
              brl     toError
3$:           ldx     .near netfail
              status  strFailed, .word0 strRetrying
              jsl     long:I_GetTime
              sta     .near NT_T
              lda     ##JP_RETRY
              sta     .near netphase
              rts
tickRetry:    jsl     long:I_GetTime
              sec
              sbc     .near NT_T
              ldy     ##(3 * CONST_TICRATE)
              ldx     .near netfail         ; the socket was busy (8, a card
              cpx     ##8                   ;   fetch on it): a second is
              bne     0$                    ;   plenty
              ldy     ##CONST_TICRATE
0$:           sty     .near rtwait
              cmp     .near rtwait
              bcc     1$
              lda     ##JP_CONNECT
              sta     .near netphase
1$:           rts

;;; The go: player 0 sends the setup record (the game is his) and starts;
;;; player 1 starts when it comes (setupRec, from recByte). The relay
;;; closing on us meanwhile (the other player left) is a failed connect:
;;; the join tries again like any other.
go:           ldx     ##0xffff
              status  strFound, 0
              jsr     .kbank sendName
              lda     .near _g_consoleplayer
              bne     1$
              jsr     .kbank sendSetup
              bra     startGame
1$:           lda     ##JP_SETUP
              sta     .near netphase
tickSetup:    jsr     .kbank pollRx
              lda     .near netstate
              cmp     ##NS_FAILED
              bne     4$
              brl     connFailed
4$:
              lda     .near nm_setup
              bne     startGame
              rts

;;; startGame: the net game: both players to be born (player 0 is
;;; resident, player 1 saved), the tic counters from 0 (the two machines
;;; count the same tics from here; the records go by them), a new game
;;; of the page's choices at the next tic, the menu closed.
startGame:    lda     ##1
              sta     .near _g_netgame
              sta     .near (_g_playeringame+2)
              lda     .near nm_dm
              sta     .near _g_deathmatch
              lda     .near nm_mon
              eor     ##1
              sta     .near _g_nomonsters
              sep     #0x20
              ldx     ##(SIZEOF_PL - 1)
1$:           stz     .near _g_player,x
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
              stz     .near netmaketic      ; (netsent and peerhave: 0 since
              stz     .near maketic         ;   the connect)
              stz     .near (maketic+2)
              stz     .near _g_gametic
              stz     .near (_g_gametic+2)
              stz     .near menutic
              ldx     .near nm_map
              lda     .near nm_skill
              jsl     long:G_DeferedInitNewMap
              jsl     long:I_MenuPaletteBack ; (clearMenus)
              stz     .near _g_menuactive
              stz     .near itemOn
              stz     .near currentMenu
              inc     .near menuversion
              stz     .near netphase
              stz     .near statn
              rts

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

;;; sendTime: TIME to the card; its reply comes to nettime (timeByte,
;;; netflag), 0 without a network.
sendTime:     stz     .near netflag
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
              rts

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

;;; buildHost: hostbuf, hostlen = NETHOST, and with a WebSocket (the
;;; lobby's ws/match, NETHOST ends in n=) the name, then &c= and the room
;;; code when one is typed (none: the public queue).
buildHost:    sep     #0x20
              ldx     ##0
1$:           lda     long:hostStr,x
              sta     long:hostbuf,x
              inx
              cpx     ##HOSTLEN
              bcc     1$
#if (NETFLAGS & 8)
              rep     #0x20
              lda     ##.word0 strDefName
              ldy     .near nm_nlen
              beq     2$
              lda     ##.word0 nm_name
2$:           jsr     .kbank appendStr
              lda     .near nm_clen
              beq     4$
              lda     ##.word0 strCodeArg
              jsr     .kbank appendStr
              lda     ##.word0 nm_code
              jsr     .kbank appendStr
4$:
#endif
              rep     #0x20
              stx     .near hostlen
              rts

;;; appendStr: the string C (this bank) to hostbuf at X (through _Dp:
;;; there is no long,y). m16 in and out.
appendStr:    sta     dp:.tiny _Dp
              lda     ##.word2 strTitle
              sta     dp:.tiny (_Dp+2)
              sep     #0x20
              ldy     ##0
1$:           lda     [.tiny _Dp],y
              beq     2$
              sta     long:hostbuf,x
              inx
              iny
              bra     1$
2$:           rep     #0x20
              rts

;;; sendConnect: the socket's state from nothing, CONNECT: sock 0, the
;;; flags, the port, the host.
sendConnect:  stz     .near netstate
              stz     .near rxstate
              stz     .near recpos
              stz     .near netsent
              stz     .near (netsent+2)
              stz     .near peerhave
              stz     .near (peerhave+2)
              stz     .near nm_setup
              stz     .near gapwait
              stz     .near reqtic
              jsr     .kbank drainRx
              lda     ##OP_CONNECT
              jsr     .kbank push8
              lda     .near hostlen
              clc
              adc     ##5
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
              lda     .near hostlen
              jsr     .kbank push8
              ldx     ##0
1$:           lda     long:hostbuf,x
              jsr     .kbank push8
              inx
              cpx     .near hostlen
              bcc     1$
              rts

;;; sendSetup: player 0's setup record to player 1: tic SETUP_TIC, the
;;; skill, the map, the game, the monsters. setupRec: it came (recByte).
sendSetup:    lda     ##OP_SEND
              jsr     .kbank push8
              lda     ##(1 + REC_SIZE)
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              lda     ##0                   ; sock 0
              jsr     .kbank push8
              lda     ##(SETUP_TIC & 0xff)
              jsr     .kbank push8
              jsr     .kbank push8
              lda     .near nm_skill
              jsr     .kbank push8
              lda     .near nm_map
              jsr     .kbank push8
              lda     .near nm_dm
              jsr     .kbank push8
              lda     .near nm_mon
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              jsr     .kbank push8
              jsr     .kbank push8
              rts
specialRec:   cmp     ##SETUP_TIC
              bne     1$
              lda     .near (rec+2)
              and     ##0x00ff
              sta     .near nm_skill
              lda     .near (rec+3)
              and     ##0x00ff
              sta     .near nm_map
              lda     .near (rec+4)
              and     ##0x00ff
              sta     .near nm_dm
              lda     .near (rec+5)
              and     ##0x00ff
              sta     .near nm_mon
              inc     .near nm_setup
              rts
1$:           cmp     ##NAME_TIC            ; the other player's name
              bne     2$
              ldx     ##0
              sep     #0x20
11$:          lda     .near (rec+2),x
              sta     long:peername,x
              inx
              cpx     ##7
              bcc     11$
              lda     #0
              sta     long:(peername+7)
              rep     #0x20
              rts
2$:           cmp     ##NAME2_TIC           ; NAME2_TIC: its letter 7
              bne     3$
              sep     #0x20
              lda     .near (rec+2)
              sta     long:(peername+7)
              rep     #0x20
              rts
3$:           jmp     .kbank resend         ; REQ_TIC: the records again

;;; sendName: the player's name (YOUR NAME, or DOOMGUY) to the other
;;; machine as two records, NAME_TIC with letters 0 to 6 and NAME2_TIC
;;; with letter 7, zero padded (namebuf).
sendName:     ldx     ##0
              sep     #0x20
              lda     #0
1$:           sta     long:namebuf,x
              inx
              cpx     ##16
              bcc     1$
              rep     #0x20
              ldx     ##.word0 strDefName
              lda     .near nm_nlen
              beq     2$
              ldx     ##.word0 nm_name
2$:           jsr     .kbank strPtr
              ldx     ##0
              sep     #0x20
3$:           lda     [.tiny _Dp],y
              beq     4$
              sta     long:namebuf,x
              iny
              inx
              bra     3$
4$:           rep     #0x20
              lda     ##NAME_TIC
              ldx     ##0
              jsr     .kbank nameRec
              lda     ##NAME2_TIC
              ldx     ##7
nameRec:      sta     .near NM_T            ; the record: tic C, namebuf + X
              stx     .near NM_S
              lda     ##OP_SEND
              jsr     .kbank push8
              lda     ##(1 + REC_SIZE)
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              lda     ##0                   ; sock 0
              jsr     .kbank push8
              lda     .near NM_T
              jsr     .kbank push8
              xba
              jsr     .kbank push8
              ldx     .near NM_S
              ldy     ##7
5$:           lda     long:namebuf,x
              jsr     .kbank push8
              inx
              dey
              bne     5$
              rts

;;; ---------------------------------------------------------------------------
;;; D_NetDrawName: the intermission's deathmatch rows: the name of player
;;; C (0 or 1) in the HUD font, ending at X, at Y; carry set. Carry clear
;;; and nothing drawn when the other player's name has not come.
;;; ---------------------------------------------------------------------------
              .public D_NetDrawName
D_NetDrawName:
              sty     .near MT_Y
              stx     .near NM_S
              cmp     .near _g_consoleplayer
              bne     1$
              lda     ##.word0 strDefName
              ldy     .near nm_nlen
              beq     2$
              lda     ##.word0 nm_name
              bra     2$
1$:           lda     long:peername
              and     ##0xff
              beq     9$
              lda     ##.word0 peername
2$:           pei     dp:.tiny (_Dp+8)
              pei     dp:.tiny (_Dp+10)
              pha
              jsr     .kbank strWidth
              eor     ##0xffff              ; the right end - the width
              sec
              adc     .near NM_S
              sta     .near MT_X
              pla
              jsr     .kbank putStr
              pla
              sta     dp:.tiny (_Dp+10)
              pla
              sta     dp:.tiny (_Dp+8)
              sec
              rtl
9$:           clc
              rtl

;;; ---------------------------------------------------------------------------
;;; void D_NetScore(void): G_DoCompleted in a deathmatch: the player's
;;; frags of the level to the lobby's board, a win when he has more than
;;; the other player, and the level played: POST /v1/score?g=doom&n=NAME
;;; &v=N&x=frags&m=add (x=wins, x=games), HTTP requests the card makes on
;;; sockets 1 to 3 while the game's socket 0 goes on; nothing is read back
;;; (the events of other sockets are skipped by the parser). Through the
;;; lobby only.
;;; ---------------------------------------------------------------------------
              .public D_NetScore
D_NetScore:
#if (NETFLAGS & 8)
              lda     .near _g_netgame
              beq     9$
              lda     .near _g_deathmatch
              beq     9$
              lda     .near _g_consoleplayer
              asl     a
              tax
              lda     .near _g_frags,x
              bmi     1$                    ; (suicides can take it below 0)
              beq     1$
              cmp     ##100
              bcc     0$
              lda     ##99
0$:           ldy     ##1                   ; sock 1
              ldx     ##.word0 tagFrags
              jsr     .kbank postScore
1$:           lda     .near _g_consoleplayer
              eor     ##1
              asl     a
              tax
              lda     .near _g_frags,x      ; the other player's
              ldx     .near _g_consoleplayer
              beq     2$
              ldx     ##2
2$:           cmp     .near _g_frags,x      ; less than his: a win
              bpl     3$
              lda     ##1
              ldy     ##2                   ; sock 2
              ldx     ##.word0 tagWins
              jsr     .kbank postScore
3$:           lda     ##1                   ; and a level played
              ldy     ##3                   ; sock 3
              ldx     ##.word0 tagGames
              jsr     .kbank postScore
#endif
9$:           rtl

;;; postScore: the request: the value C (0 to 99), the socket Y, the tag
;;; X (this bank): HTTP sock, flags 0, POST, the url (strScore, the name,
;;; &v=, two digits, the tag), hdrs_len 0, body_len 0.
SC_LEN        .equ    (12 + (strScoreEnd - strScore - 1) + 3 + 2)
postScore:    phy
              stx     .near NM_W            ; the tag, and its letters
              jsr     .kbank toDec          ; numbuf (X: the tens)
              ldx     .near NM_W
              jsr     .kbank strLen
              sta     .near NM_T
              ldx     .near nm_nlen         ; the name's letters
              bne     1$
              ldx     ##(strDefNameEnd - strDefName - 1)
1$:           stx     .near NM_S
              lda     ##OP_HTTP
              jsr     .kbank push8
              lda     .near NM_S
              clc
              adc     .near NM_T
              adc     ##SC_LEN
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              pla                           ; sock
              jsr     .kbank push8
              lda     ##0                   ; flags: the body as DATA (skipped)
              jsr     .kbank push8
              lda     ##4
              jsr     .kbank push8
              ldx     ##.word0 strPost
              jsr     .kbank pushStr
              lda     .near NM_S            ; url_len
              clc
              adc     .near NM_T
              adc     ##(SC_LEN - 12)
              jsr     .kbank push8
              ldx     ##.word0 strScore
              jsr     .kbank pushStr
              ldx     ##.word0 strDefName
              lda     .near nm_nlen
              beq     2$
              ldx     ##.word0 nm_name
2$:           jsr     .kbank pushStr
              ldx     ##.word0 strValArg
              jsr     .kbank pushStr
              lda     long:(numbuf+1)       ; one digit: a 0 before it
              and     ##0xff
              bne     3$
              lda     ##'0'
              jsr     .kbank push8
3$:           ldx     ##.word0 numbuf
              jsr     .kbank pushStr
              ldx     .near NM_W
              jsr     .kbank pushStr
              lda     ##0                   ; hdrs_len, body_len
              jsr     .kbank push8
              jsr     .kbank push8
              jsr     .kbank push8
              jmp     .kbank push8

;;; sockFilter: the socket byte (rxidx 1) of a socket event: another
;;; socket's (a score post's reply or close) is skipped as an unknown op
;;; (for the parser of netcode, which is full). Keeps C.
sockFilter:   ldx     .near rxidx
              cpx     ##1
              bne     1$
              ldx     .near rxop
              cpx     ##EV_TIME             ; (no socket byte)
              beq     1$
              cmp     ##0
              beq     1$
              stz     .near rxop
1$:           rts

;;; pushStr: the string X (this bank) to the card, through _Dp.
;;; strLen: C = the letters of the string X.
pushStr:      jsr     .kbank strPtr
1$:           lda     [.tiny _Dp],y
              and     ##0xff
              beq     2$
              jsr     .kbank push8
              iny
              bra     1$
2$:           rts
strLen:       jsr     .kbank strPtr
1$:           lda     [.tiny _Dp],y
              and     ##0xff
              beq     2$
              iny
              bra     1$
2$:           tya
              rts
strPtr:       stx     dp:.tiny _Dp
              lda     ##.word2 strTitle
              sta     dp:.tiny (_Dp+2)
              ldy     ##0
              rts

;;; The page's strings (and the buffers they are built in).
strTitle:     .asciz  "NETWORK GAME"
rowLabels:    .word   .word0 lblGame, .word0 lblSkill, .word0 lblMap
              .word   .word0 lblMon, .word0 lblName, .word0 lblCode, .word0 lblFind
lblGame:      .asciz  "GAME"
lblSkill:     .asciz  "SKILL"
lblMap:       .asciz  "MAP"
lblMon:       .asciz  "MONSTERS"
lblName:      .asciz  "YOUR NAME"
lblCode:      .asciz  "ROOM CODE"
lblFind:      .asciz  "FIND PLAYERS"
strDM:        .asciz  "DEATHMATCH"
strCoop:      .asciz  "COOPERATIVE"
strOn:        .asciz  "ON"
strOff:       .asciz  "OFF"
strPublic:    .asciz  "PUBLIC"
skillNames:   .word   .word0 sk0, .word0 sk1, .word0 sk2, .word0 sk3, .word0 sk4
sk0:          .asciz  "I'M TOO YOUNG TO DIE"
sk1:          .asciz  "HEY, NOT TOO ROUGH"
sk2:          .asciz  "HURT ME PLENTY"
sk3:          .asciz  "ULTRA-VIOLENCE"
sk4:          .asciz  "NIGHTMARE!"
mapbuf:       .asciz  "E1M1"
numbuf:       .space  4
strDefName:   .asciz  "DOOMGUY"             ; the name when none is typed
strDefNameEnd:
strCodeArg:   .asciz  "&c="
nm_name:      .byte   0                     ; the name (CODE_MAX letters),
              .space  CODE_MAX              ;   the room code right after
#ifdef NETROOM
nm_code:      .asciz  NETROOM               ; the room code (CODE_MAX letters)
#else
nm_code:      .byte   0
#endif
nm_codeEnd:
              .space  (CODE_MAX - (nm_codeEnd - nm_code - 1))
peername:     .byte   0                     ; the other player's name (none: 0)
              .space  CODE_MAX
namebuf:      .space  16                    ; the name as sent (zero padded)
strCard:      .asciz  "COGS CARD IN SLOT "
errNoCard:    .asciz  "NO COGS CARD IN SLOTS 1-7"
strNoNet:     .asciz  "WAITING FOR THE CARD'S NETWORK..."
errNoNet:     .asciz  "THE CARD HAS NO NETWORK"
#if (NETFLAGS & 8)
strJoin:      .asciz  "JOINING LOBBY.A2COGS.COM..."
#else
strJoin:      .asciz  "JOINING THE RELAY..."
#endif
strFind:      .asciz  "ATTEMPTING TO FIND ALL PLAYERS..."
strFailed:    .asciz  "CONNECT FAILED ("
strParen:     .asciz  ")"
strRetrying:  .asciz  "), RETRYING"
errTimeout:   .asciz  "NO OTHER PLAYER CAME"
strFound:     .asciz  "FOUND ALL PLAYERS."
strPost:      .asciz  "POST"
strScore:     .asciz  "https://lobby.a2cogs.com/v1/score?g=doom&n="
strScoreEnd:
strValArg:    .asciz  "&v="
tagFrags:     .asciz  "&x=frags&m=add"
tagWins:      .asciz  "&x=wins&m=add"
tagGames:     .asciz  "&x=games&m=add"
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
#ifdef NETGAME
              lda     .near netphase        ; a join on: its next step
              beq     0$
              jsr     .kbank D_NetJoinTick
0$:
#endif
              lda     .near maketic
              sta     .near netmaketic
              rtl
1$:           lda     .near netsent         ; the new tics out
              cmp     .near maketic
              beq     2$
              sta     .near txtic
              jsr     .kbank sendTic
              inc     .near netsent
              bne     1$
              inc     .near (netsent+2)
              bra     1$
2$:           jsr     .kbank pollRx         ; the other's in
#ifdef NETGAME
              lda     .near gapwait         ; records missing for a while
              beq     5$                    ;   (the request may have been
              jsr     .kbank reqDue         ;   lost the same way): ask again
              bcc     5$
              jsr     .kbank sendReq
5$:
#endif
              lda     .near peerhave        ; netmaketic = min(maketic, peerhave)
              sec
              sbc     .near maketic
              bmi     3$
              lda     .near maketic
              bra     4$
3$:           lda     .near peerhave
4$:           sta     .near netmaketic
              rtl

;;; sendTic: SEND the record of tic txtic: the tic, cmds[tic], and the
;;; consistency word of the console player at that tic. The record is
;;; built in its sentrecs slot (txSlot) and stays there for a REQ_TIC.
sendTic:      jsr     .kbank txSlot
              lda     .near txtic           ; the tic
              ldy     ##0
              sta     [dp:.tiny _Dp],y
              and     ##(CMDS - 1)          ; the command
              asl     a
              asl     a
              asl     a
              tax
              lda     .near cmds,x
              ldy     ##2
              sta     [dp:.tiny _Dp],y
              lda     .near (cmds+2),x
              ldy     ##4
              sta     [dp:.tiny _Dp],y
              lda     .near (cmds+4),x
              ldy     ##6
              sta     [dp:.tiny _Dp],y
              lda     .near txtic           ; the consistency word
              jsr     .kbank consIndex
              jsr     .kbank ownRing
              tax
              lda     long:cons,x
              ldy     ##7
              sta     [dp:.tiny _Dp],y
;;; pushTx: SEND the REC_SIZE bytes at [_Dp].
pushTx:       lda     ##OP_SEND
              jsr     .kbank push8
              lda     ##(1 + REC_SIZE)
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              lda     ##0                   ; sock 0
              jsr     .kbank push8
              ldy     ##0
1$:           lda     [dp:.tiny _Dp],y
              jsr     .kbank push8
              iny
              cpy     ##REC_SIZE
              bcc     1$
              rts

;;; txSlot: _Dp = the sentrecs slot of tic txtic.
txSlot:       lda     .near txtic
              and     ##(SENT - 1)
              asl     a
              asl     a
              asl     a
              asl     a
              clc
              adc     ##.word0 sentrecs
              sta     dp:.tiny _Dp
              lda     ##.word2 sentrecs
              sta     dp:.tiny (_Dp+2)
              rts

;;; sendReq: the other machine's records from tic peerhave are missing:
;;; SEND a REQ_TIC record asking for them again, and note the request
;;; (reqtic, reqtime, gapwait: D_NetUpdate repeats it after REQ_WAIT).
sendReq:      lda     .near peerhave
              sta     .near reqtic
              jsl     long:I_GetTime
              sta     .near reqtime
              lda     ##1
              sta     .near gapwait
              lda     ##REQ_TIC
              sta     .near reqrec
              lda     .near peerhave
              sta     .near (reqrec+2)
              stz     .near (reqrec+4)
              stz     .near (reqrec+6)
              stz     .near (reqrec+8)
              lda     ##.word0 reqrec
              sta     dp:.tiny _Dp
              lda     ##.word2 reqrec
              sta     dp:.tiny (_Dp+2)
              bra     pushTx

;;; reqDue: carry set when REQ_WAIT tics passed since the last request.
reqDue:       jsl     long:I_GetTime
              sec
              sbc     .near reqtime
              cmp     ##REQ_WAIT
              rts

;;; resend: a REQ_TIC came: the records from tic rec+2 to netsent - 1 go
;;; out again from sentrecs. A tic no longer there (more than SENT back,
;;; or the slot holds another tic): the machines lost each other (lostSync).
resend:       lda     .near (rec+2)
              sta     .near txtic
1$:           lda     .near netsent
              sec
              sbc     .near txtic
              beq     9$                    ; all out
              bmi     9$                    ; (tics not sent yet: nothing)
              cmp     ##(SENT + 1)
              bcs     lostSync
              jsr     .kbank txSlot
              ldy     ##0
              lda     [dp:.tiny _Dp],y
              cmp     .near txtic
              bne     lostSync
              jsr     .kbank pushTx
              inc     .near txtic
              bra     1$
9$:           rts

;;; lostSync: the other machine's records cannot be had: the game goes on
;;; as one player's under a message whose key takes the title (M_NetLost,
;;; m_menu65, as M_NetLeft), and the socket closes so the other machine
;;; sees the relay close (its "the other player left"). The stock build
;;; keeps the I_Error.
lostSync:
#ifdef NETGAME
              lda     ##OP_CLOSE
              jsr     .kbank push8
              lda     ##1
              jsr     .kbank push8
              lda     ##0
              jsr     .kbank push8
              lda     ##0                   ; sock 0
              jsr     .kbank push8
              stz     .near _g_netgame
              stz     .near (_g_playeringame+2)
              jsl     long:M_NetLost
              rts
#else
              pei     dp:.tiny _Dp
              lda     .near peerhave
              pha
              lda     .near rec
              pha
              lda     ##.word0 errTic
              ldx     ##.word2 errTic
              brl     error
#endif

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
#ifdef NETGAME
              jsr     .kbank sockFilter     ; (another socket's: unknown op)
#endif
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
failed:       sta     .near netfail         ; (the join tries again)
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

;;; ackByte: EV_SEND_ACK: sock, result. The records sent in the pass that
;;; then reads the relay's close are refused (8, the socket is gone): their
;;; acks come after the EV_CLOSED, when the game is one player's, and are
;;; dropped (seen in the bench: SEND FAILED (8) instead of the message).
ackByte:      ldx     .near rxidx
              cpx     ##2
              bne     done
              cmp     ##0
              beq     done
              ldx     .near _g_netgame
              beq     done
              pha
              lda     ##.word0 errSend
              ldx     ##.word2 errSend
              brl     error

;;; errByte: EV_ERROR: sock, code, ...   closedByte: EV_CLOSED: sock, reason.
;;; Before the game starts (the join: through the go and the setup
;;; record) either is a failed connect, which the join retries; in the
;;; game they end it.
errByte:      ldx     .near rxidx
              cpx     ##2
              bne     done
              ldx     .near _g_netgame
              beq     failed
              pha
              lda     ##.word0 errCard
              ldx     ##.word2 errCard
              brl     error
closedByte:   ldx     .near rxidx
              cpx     ##2
              bne     done
              ldx     .near _g_netgame
              beq     failed
;;; The relay closed during the game: the other player left. The game
;;; goes on as one player's (no more records out or in; the menu pauses
;;; it) under a message whose key takes the title (M_NetLeft, m_menu65),
;;; where NETWORK GAME is back. (Was I_Error, a screen with no way out.)
              stz     .near _g_netgame
              stz     .near (_g_playeringame+2)
#ifdef NETGAME
              jsl     long:M_NetLeft
#else
              brl     failed                ; (the stock build: no net game)
#endif
              brl     payloadDone
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

;;; recByte: a byte of a record: tic (2), command (5), consistency (2);
;;; tic SETUP_TIC: player 0's setup record (setupRec).
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
#ifdef NETGAME
              cmp     ##REQ_TIC             ; (or a special record)
              bcc     0$
              jsr     .kbank specialRec
              bra     done
0$:
#endif
              cmp     .near peerhave
              beq     1$
;;; Not the tic we wait for. Older: a record sent again (resend) that is
;;; in already, dropped. Newer: records went missing (the card's block
;;; driver empties the card's queue at every read, so a machine that
;;; reads the level from disk loses the tics that came while it loaded):
;;; dropped, and a REQ_TIC asks for them from peerhave, once per
;;; REQ_WAIT unless peerhave moved since the last request.
              sec
              sbc     .near peerhave
              bmi     3$
              lda     .near peerhave
              cmp     .near reqtic
              bne     4$
              lda     .near gapwait
              beq     4$
              jsr     .kbank reqDue
              bcc     3$
4$:           jsr     .kbank sendReq
3$:           brl     payloadDone
1$:           stz     .near gapwait         ; (the one we wait for: in)
              and     ##(CMDS - 1)
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
