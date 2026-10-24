;;; Two players in one player struct.
;;;
;;; The game addresses the player as _g_player, one struct at a fixed near
;;; address, in about 500 places. Rather than index them all off a pointer,
;;; the struct stays where it is and holds the player the code is acting
;;; for: P_SwapTo copies the resident player out to his save slot and the
;;; other player in. A player's mobj is read from whichever copy of his
;;; struct is current, so identity tests (is this mobj a player, and whose)
;;; work whatever struct is resident. In a single player game player 0 is
;;; always resident and no swap ever runs, so demos play as before.
;;;
;;; Placement: this file's code is in its own section (playerscode, Code5a
;;; of iigs.scm), and the edits in the other files are size neutral, so the
;;; packed coldcode/farcode fragments of the stock build do not move.
;;;
;;; Done here beyond the wrappers: the thrust of p_inter65.s (the chainsaw
;;; of the source, P_SourceChainsaw), the listener of s_sound65.s
;;; (_g_listenerMo, the console player's mobj whoever is resident) and
;;; P_SetupLevel's clearing of the mobjs (P_ClearPlayerMo, both slots).
;;; Correct under the wrappers as they are: lines and P_TeleportMove of
;;; p_map65.s, isPlayer of p_switch65.s and p_mobj65.s.
;;;
;;; Still one-player: lookForPlayers of p_enemy65.s, killMobj's frags and
;;; killcount (the source's player), doCompleted and the saves of g_game65.s.

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

              .extern _Dp, _g_player, P_PlayerThink
              .extern mobjThinker0, damageMobj0, touchSpecialThing0, evTeleport0
              .extern spawnPlayer, DM_SOURCE, SP_MT, P_Random, _Mod16
              .extern P_CheckPosition, P_SpawnMobj, S_StartSound, P_SpawnSpecials
              .extern _g_gameaction

GA_LOADLEVEL  .equ    1               ; (g_game65.s)
MAX_DMSTARTS  .equ    10              ; deathmatch starts kept, as Doom
OFS_MT_X      .equ    0               ; the packed map thing (p_spawn65.s)
OFS_MT_Y      .equ    2
OFS_MT_TYPE   .equ    4
OFS_MT_ANGLE  .equ    6               ; (options is the byte after)
START_SIZE    .equ    8

              .section znear, bss
              .public _g_resident, _g_consoleplayer, _g_playeringame, _g_deathmatch
_g_resident:  .space  2               ; the player whose struct is _g_player
_g_consoleplayer: .space 2            ; the player at this machine
_g_playeringame: .space 4             ; player 0 is always in; a word for player 1
_g_deathmatch: .space 2
              .public _g_netgame, _g_frags
_g_netgame:   .space  2
_g_frags:     .space  4               ; the frags of each player
              .public _g_listenerMo
_g_listenerMo: .space 4              ; the console player's mobj, whoever is resident
WR_T:         .space  2               ; a wrapper's word across a swap
WR_T2:        .space  2
dmcount:      .space  2               ; the deathmatch starts of the level
DM_N:         .space  2               ; G_DeathMatchSpawnPlayer: the player
DM_OFF:       .space  2               ;   the start tried

              .section zfar, bss
              .public _g_psave
_g_psave:     .space  2 * SIZEOF_PL   ; a player's struct while he is not resident
starts:       .space  (2 + MAX_DMSTARTS) * START_SIZE ; the starts of players
                                      ;   0 and 1, then the deathmatch starts


              .section playerscode, text ; Code5a only: nothing else moves
;;; The monsters of the shareware episode by doomed number: a deathmatch
;;; spawns none of them yet (lookForPlayers knows one player). (Data in
;;; this section: the packed rodata of the other files stays put.)
monsters:     .word   3004, 9, 3001, 3002, 3003, 58, 3005, 3006, 0

;;; ---------------------------------------------------------------------------
;;; void P_SwapTo(int16_t player)      In: C = the player, 0 or 1.
;;; Makes his struct the resident one. Nothing happens when it already is.
;;; A, X and Y are not kept; the data bank is.
;;; ---------------------------------------------------------------------------
              .public P_SwapTo
P_SwapTo:     cmp     .near _g_resident
              beq     9$
              pha
              lda     .near _g_resident     ; out: _g_player -> psave[resident]
              jsr     .kbank saveSlot
              tay
              ldx     ##.near _g_player
              lda     ##(SIZEOF_PL - 1)
              phb
              .byte   0x54, .byte2 _g_psave, .byte2 _g_player ; mvn
              plb
              pla                           ; in: psave[player] -> _g_player
              sta     .near _g_resident
              jsr     .kbank saveSlot
              tax
              ldy     ##.near _g_player
              lda     ##(SIZEOF_PL - 1)
              phb
              .byte   0x54, .byte2 _g_player, .byte2 _g_psave ; mvn
              plb
              jsr     .kbank refreshListener
9$:           rtl

;;; refreshListener: _g_listenerMo = the console player's mobj, from the
;;; resident struct or his save slot. After anything that moves a struct
;;; or sets a mobj.
refreshListener:
              lda     .near _g_consoleplayer
              cmp     .near _g_resident
              bne     1$
              lda     .near (_g_player+OFS_PL_MO)
              ldx     .near (_g_player+OFS_PL_MO+2)
              bra     2$
1$:           jsr     .kbank saveSlot
              lda     long:(_g_psave+OFS_PL_MO),x
              pha
              lda     long:(_g_psave+OFS_PL_MO+2),x
              tax
              pla
2$:           sta     .near _g_listenerMo
              stx     .near (_g_listenerMo+2)
              rts

;;; saveSlot: C = the player; out C = the address of his save slot in its
;;; bank (.byte2 _g_psave), X = its offset from _g_psave.
saveSlot:     ldx     ##0
              cmp     ##0
              beq     1$
              ldx     ##SIZEOF_PL
1$:           txa
              clc
              adc     ##.word0 _g_psave
              rts

;;; ---------------------------------------------------------------------------
;;; void P_PlayersThink(void)
;;; The P_PlayerThink of each player in the game, his struct resident, and
;;; the console player resident again after. Called by P_Ticker in a level.
;;; ---------------------------------------------------------------------------
              .public P_PlayersThink
P_PlayersThink:
              lda     ##0
              jsr     .kbank thinkOne
              lda     .near (_g_playeringame+2)
              beq     1$
              lda     ##1
              jsr     .kbank thinkOne
1$:           lda     .near _g_consoleplayer
              jmp     long:P_SwapTo

thinkOne:     jsl     long:P_SwapTo
              lda     ##.near _g_player
              sta     dp:.tiny _Dp
              lda     ##.word2 _g_player
              sta     dp:.tiny (_Dp+2)
              jsl     long:P_PlayerThink
              rts

;;; ---------------------------------------------------------------------------
;;; struct player_s* P_PlayerOfMobj(const mobj_t __far* mobj)
;;; In: _Dp[0-3] = the mobj. Out: X:A = his player struct, resident or
;;; saved, or 0. P_MobjIsPlayer of p_mobj65.s forwards here.
;;; ---------------------------------------------------------------------------
              .public P_PlayerOfMobj
P_PlayerOfMobj:
              lda     dp:.tiny _Dp
              ora     dp:.tiny (_Dp+2)
              beq     8$
              lda     dp:.tiny _Dp          ; the resident player's mobj
              cmp     .near (_g_player+OFS_PL_MO)
              bne     1$
              lda     dp:.tiny (_Dp+2)
              cmp     .near (_g_player+OFS_PL_MO+2)
              bne     1$
              ldx     ##.word2 _g_player
              lda     ##.near _g_player
              rtl
1$:           lda     .near (_g_playeringame+2) ; the other player's, if any,
              beq     8$                    ; from his save slot
              lda     .near _g_resident
              eor     ##1
              jsr     .kbank saveSlot
              pha
              lda     dp:.tiny _Dp
              cmp     long:(_g_psave+OFS_PL_MO),x
              bne     7$
              lda     dp:.tiny (_Dp+2)
              cmp     long:(_g_psave+OFS_PL_MO+2),x
              bne     7$
              pla
              ldx     ##.word2 _g_psave
              rtl
7$:           pla
8$:           lda     ##0
              tax
              rtl

;;; ---------------------------------------------------------------------------
;;; The wrappers. Code that acts on a mobj that may be a player's body runs
;;; with that player's struct resident: the routine is entered here, the
;;; swap happens around the real one, and the resident player before is
;;; put back after, so a caller in the middle of its own player's think
;;; (a shot that hits the other player) sees its struct again. Each real
;;; routine keeps its code and its place; only its public name moved here.
;;; ---------------------------------------------------------------------------

;;; swapForMobj: _Dp[0-3] = a mobj. If it is a player's, his struct becomes
;;; resident. Out: C = the player resident before (for P_SwapTo after).
;;; Keeps _Dp and the other direct page arguments.
swapForMobj:  lda     .near _g_resident
              pha
              jsl     long:P_PlayerOfMobj
              cmp     ##0
              bne     1$
              cpx     ##0
              beq     9$                    ; not a player's
1$:           cmp     ##.near _g_player     ; the resident one already
              bne     2$
              cpx     ##.word2 _g_player
              beq     9$
2$:           lda     .near _g_resident
              eor     ##1
              jsl     long:P_SwapTo
9$:           pla
              rts

;;; swapForMobj4: the same for the mobj in _Dp[4-7] (the second argument).
swapForMobj4: pha
              jsr     .kbank exchangeArgs
              pla
              jsr     .kbank swapForMobj
              pha
              jsr     .kbank exchangeArgs
              pla
              rts
exchangeArgs: ldx     dp:.tiny _Dp
              ldy     dp:.tiny (_Dp+4)
              sty     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+4)
              ldx     dp:.tiny (_Dp+2)
              ldy     dp:.tiny (_Dp+6)
              sty     dp:.tiny (_Dp+2)
              stx     dp:.tiny (_Dp+6)
              rts

;;; void P_MobjThinker(mobj_t __far* mobj)       In: _Dp[0-3].
;;; A player's body (type MT_PLAYER, 0) moves, picks up, crosses lines and
;;; teleports with his struct resident. Every other mobj goes straight on.
              .public P_MobjThinker
P_MobjThinker:
              ldy     ##OFS_MO_TYPE
              lda     [.tiny _Dp],y         ; CONST_MT_PLAYER is 0
              bne     1$
              jsr     .kbank swapForMobj
              pha
              jsl     long:mobjThinker0
              pla
              jsl     long:P_SwapTo
              rtl
1$:           jmp     long:mobjThinker0

;;; void P_DamageMobj(target, inflictor, source, damage)
;;; In: C = damage, _Dp[0-3] = target, _Dp[4-7] = inflictor, the source on
;;; the stack (4,s and 6,s; the caller pops it). The target's player, if it
;;; is one, takes the damage with his struct resident.
              .public P_DamageMobj
P_DamageMobj: sta     .near WR_T
              jsr     .kbank swapForMobj
              pha                           ; the player resident before
              lda     8,s                   ; the source again, for the real one
              pha
              lda     8,s
              pha
              lda     .near WR_T
              jsl     long:damageMobj0
              pla
              pla
              pla
              jsl     long:P_SwapTo
              rtl

;;; void P_TouchSpecialThing(special, toucher)   In: _Dp[0-3], _Dp[4-7].
;;; The toucher's player, if it is one, picks up with his struct resident.
              .public P_TouchSpecialThing
P_TouchSpecialThing:
              jsr     .kbank swapForMobj4
              pha
              jsl     long:touchSpecialThing0
              pla
              jsl     long:P_SwapTo
              rtl

;;; int16_t EV_Teleport(line, side, thing)  In: C = side, _Dp[0-3] = line,
;;; _Dp[4-7] = thing. Out: C as the real one returns it.
              .public EV_Teleport
EV_Teleport:  pha                           ; the side
              jsr     .kbank swapForMobj4
              pha
              lda     3,s
              jsl     long:evTeleport0
              sta     .near WR_T
              pla
              jsl     long:P_SwapTo
              pla
              lda     .near WR_T
              rtl

;;; P_SpawnPlayerN: In: C = the type of a map thing, _Dp[0-3] = the thing.
;;; The things the one-player game never saw: a net thing (MTF_NOTSINGLE)
;;; spawns only in a net game; the start of a player (types 1 and 2) is
;;; kept, and he spawns there with his struct resident unless he is not in
;;; the game or this is a deathmatch (then P_SpawnSpecialsDM puts the
;;; players at random deathmatch starts); players 3 and 4 have no struct; a
;;; deathmatch start (11) is kept; a deathmatch has no monsters.
;;; Out: carry set when the thing is done with.
              .public P_SpawnPlayerN
P_SpawnPlayerN:
              tax                           ; X = the type
              ldy     ##OFS_MT_ANGLE        ; the options byte is the high
              lda     [.tiny _Dp],y         ;   one: MTF_NOTSINGLE
              and     ##0x1000
              beq     1$
              lda     .near _g_netgame
              beq     6$
1$:           txa
              cmp     ##11                  ; a deathmatch start
              bne     2$
              lda     .near dmcount
              cmp     ##MAX_DMSTARTS
              bcs     6$
              inc     .near dmcount
              clc
              adc     ##2
              jsr     .kbank copyStart
              bra     6$
2$:           cmp     ##5                   ; a thing
              bcs     8$
              cmp     ##3                   ; players 3 and 4
              bcs     6$
              dec     a                     ; the player: his start
              pha
              jsr     .kbank copyStart
              lda     .near _g_deathmatch
              bne     7$
              lda     1,s
              cmp     ##1
              bne     3$
              ldx     .near (_g_playeringame+2)
              beq     7$
3$:           lda     1,s
              jsr     .kbank spawnAs
7$:           pla
6$:         sec
              rtl
8$:           lda     .near _g_deathmatch
              beq     9$
              txa
              jsr     .kbank isMonster
              bcs     6$
9$:           clc
              rtl

;;; isMonster: carry set when C is the doomed number of a monster.
isMonster:    ldx     ##0
1$:           cmp     long:monsters,x
              beq     2$
              inx
              inx
              pha
              lda     long:monsters,x
              beq     3$
              pla
              bra     1$
3$:           pla
              clc
              rts
2$:           sec
              rts

;;; copyStart: starts[C] = the thing at _Dp[0-3].
copyStart:    asl     a
              asl     a
              asl     a
              tax
              ldy     ##0
1$:           lda     [.tiny _Dp],y
              sta     long:starts,x
              inx
              inx
              iny
              iny
              cpy     ##START_SIZE
              bcc     1$
              rts

;;; spawnAs: the player C spawns at the thing SP_MT (spawnPlayer of
;;; p_spawn65.s) with his struct resident; the resident before comes back.
;;; In a deathmatch he gets every key.
spawnAs:      ldx     .near _g_resident
              phx
              jsl     long:P_SwapTo
              jsl     long:spawnPlayer
              lda     .near _g_deathmatch
              beq     2$
              ldx     ##0
              lda     ##1
1$:           sta     .near (_g_player+OFS_PL_CARDS),x
              inx
              inx
              cpx     ##(2 * CONST_NUMCARDS)
              bcc     1$
2$:           pla
              jsl     long:P_SwapTo         ; (refreshes the listener when it swaps)
              jsr     .kbank refreshListener ; and when it does not
              rts

;;; playerMo: X:C = the mobj of player C, from the resident struct or his
;;; save slot.
playerMo:     cmp     .near _g_resident
              bne     1$
              lda     .near (_g_player+OFS_PL_MO)
              ldx     .near (_g_player+OFS_PL_MO+2)
              rts
1$:           jsr     .kbank saveSlot
              lda     long:(_g_psave+OFS_PL_MO+2),x
              pha
              lda     long:(_g_psave+OFS_PL_MO),x
              plx
              rts

;;; playerState: C = the playerstate of player C.
playerState:  cmp     .near _g_resident
              bne     1$
              lda     .near (_g_player+OFS_PL_PLAYERSTATE)
              rts
1$:           jsr     .kbank saveSlot
              lda     long:(_g_psave+OFS_PL_PLAYERSTATE),x
              rts

;;; ---------------------------------------------------------------------------
;;; void G_DeathMatchSpawnPlayer(int16_t player)      In: C.
;;; Up to 20 random deathmatch starts are tried (G_CheckSpot); none free, or
;;; none in the level: his own start.
;;; ---------------------------------------------------------------------------
              .public G_DeathMatchSpawnPlayer
G_DeathMatchSpawnPlayer:
              sta     .near DM_N
              lda     .near dmcount
              beq     3$
              ldy     ##20
1$:           phy
              jsl     long:P_Random
              ldx     .near dmcount
              jsl     long:_Mod16
              clc
              adc     ##2
              sta     .near DM_OFF
              jsr     .kbank checkSpot
              ply
              bcs     2$
              dey
              bne     1$
              bra     3$
2$:           lda     .near DM_OFF
              bra     4$
3$:           lda     .near DM_N
4$:           asl     a                     ; SP_MT = &starts[C]
              asl     a
              asl     a
              clc
              adc     ##.word0 starts
              sta     .near SP_MT
              lda     ##.word2 starts
              sta     .near (SP_MT+2)
              lda     .near DM_N
              jsr     .kbank spawnAs
              rtl

;;; checkSpot: G_CheckSpot(DM_N, starts[DM_OFF]): carry set when the player
;;; can spawn there. Before his first spawn of the level the start is free
;;; unless the other player stands on it; after, P_CheckPosition with his
;;; old mobj, and the teleport fog at the start.
checkSpot:    lda     .near DM_OFF
              asl     a
              asl     a
              asl     a
              tax
              lda     long:(starts+OFS_MT_X),x
              sta     .near WR_T
              lda     long:(starts+OFS_MT_Y),x
              sta     .near WR_T2
              lda     .near DM_N
              jsr     .kbank playerMo
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ora     dp:.tiny (_Dp+2)
              bne     2$
              lda     .near DM_N            ; his first spawn
              eor     ##1
              jsr     .kbank playerMo
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              ora     dp:.tiny (_Dp+2)
              beq     9$
              ldy     ##(OFS_MO_X+2)
              lda     [.tiny _Dp],y
              cmp     .near WR_T
              bne     9$
              ldy     ##(OFS_MO_Y+2)
              lda     [.tiny _Dp],y
              cmp     .near WR_T2
              bne     9$
8$:           clc
              rts
2$:           stz     dp:.tiny (_Dp+4)      ; P_CheckPosition(mo, x << 16, y << 16)
              lda     .near WR_T2
              sta     dp:.tiny (_Dp+6)
              lda     ##0
              ldx     .near WR_T
              jsl     long:P_CheckPosition
              cmp     ##0
              beq     8$
              pea     #CONST_MT_TFOG        ; the fog: P_SpawnMobj(x, y, ONFLOORZ, MT_TFOG)
              stz     dp:.tiny _Dp
              lda     .near WR_T2
              sta     dp:.tiny (_Dp+2)
              lda     ##CONST_ONFLOORZ_LO
              sta     dp:.tiny (_Dp+4)
              lda     ##CONST_ONFLOORZ_HI
              sta     dp:.tiny (_Dp+6)
              lda     ##0
              ldx     .near WR_T
              jsl     long:P_SpawnMobj
              ply
              sta     dp:.tiny _Dp
              stx     dp:.tiny (_Dp+2)
              lda     ##CONST_SFX_TELEPT
              jsl     long:S_StartSound
9$:           sec
              rts

;;; ---------------------------------------------------------------------------
;;; void P_SpawnSpecialsDM(void): P_SetupLevel, after the things: in a
;;; deathmatch the players spawn at random starts; then P_SpawnSpecials.
;;; ---------------------------------------------------------------------------
              .public P_SpawnSpecialsDM
P_SpawnSpecialsDM:
              lda     .near _g_deathmatch
              beq     1$
              lda     ##0
              jsl     long:G_DeathMatchSpawnPlayer
              lda     .near (_g_playeringame+2)
              beq     1$
              lda     ##1
              jsl     long:G_DeathMatchSpawnPlayer
1$:           jmp     long:P_SpawnSpecials

;;; ---------------------------------------------------------------------------
;;; void P_PlayersReborn(void): G_Ticker: a player in PST_REBORN. The
;;; one-player game loads the level again (ga_loadlevel); a net game
;;; respawns him in place (G_DoReborn).
;;; ---------------------------------------------------------------------------
              .public P_PlayersReborn
P_PlayersReborn:
              lda     .near _g_netgame
              bne     1$
              lda     .near (_g_player+OFS_PL_PLAYERSTATE)
              cmp     ##CONST_PST_REBORN
              bne     9$
              lda     ##GA_LOADLEVEL
              sta     .near _g_gameaction
9$:           rtl
1$:           lda     ##0
              jsr     .kbank rebornOne
              lda     .near (_g_playeringame+2)
              beq     9$
              lda     ##1
              jsr     .kbank rebornOne
              rtl

rebornOne:    pha
              jsr     .kbank playerState
              cmp     ##CONST_PST_REBORN
              bne     1$
              lda     1,s
              jsl     long:G_DeathMatchSpawnPlayer
1$:           pla
              rts

;;; ---------------------------------------------------------------------------
;;; void P_PlayerDied(void): killMobj of p_inter65.s, the target a player,
;;; his struct resident: PST_DEAD, and in a deathmatch a frag for the
;;; source's player (himself too, as Doom). _Dp[0-3] is kept.
;;; ---------------------------------------------------------------------------
              .public P_PlayerDied
P_PlayerDied: lda     ##CONST_PST_DEAD
              sta     .near (_g_player+OFS_PL_PLAYERSTATE)
              lda     .near _g_deathmatch
              beq     9$
              pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              lda     .near DM_SOURCE
              sta     dp:.tiny _Dp
              lda     .near (DM_SOURCE+2)
              sta     dp:.tiny (_Dp+2)
              ora     dp:.tiny _Dp
              beq     8$
              jsl     long:P_PlayerOfMobj
              jsr     .kbank playerIndex
              bcc     8$
              txa                           ; himself: one less, as Doom
              lsr     a                     ;   counts them
              cmp     .near _g_resident
              bne     7$
              dec     .near _g_frags,x
              bra     8$
7$:           inc     .near _g_frags,x
8$:           pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
9$:           rtl

;;; playerIndex: X:C = a player struct (P_PlayerOfMobj) or 0. Out: carry
;;; set and X = 2 * his number.
playerIndex:  cmp     ##0
              bne     1$
              cpx     ##0
              beq     8$
1$:           cpx     ##.word2 _g_player
              bne     2$
              cmp     ##.near _g_player
              bne     2$
              lda     .near _g_resident
              bra     3$
2$:           cmp     ##.word0 _g_psave
              beq     21$
              lda     ##1
              bra     3$
21$:          lda     ##0
3$:           asl     a
              tax
              sec
              rts
8$:           clc
              rts

;;; ---------------------------------------------------------------------------
;;; void P_ClearPlayerMo(void)
;;; No player has a mobj: before the things of a level spawn (P_SetupLevel).
;;; Both save slots too, or a stale pointer there could match a new mobj at
;;; the same address.
;;; ---------------------------------------------------------------------------
              .public P_ClearPlayerMo
P_ClearPlayerMo:
              stz     .near (_g_player+OFS_PL_MO)
              stz     .near (_g_player+OFS_PL_MO+2)
              stz     .near dmcount
              ldx     ##0
              jsr     .kbank clearSlot
              ldx     ##SIZEOF_PL
              jsr     .kbank clearSlot
              jsr     .kbank refreshListener
              rtl

;;; clearSlot: the save slot at X: no mobj, the counts of the level 0,
;;; viewz 1 (as P_SetupLevel does for the resident struct).
clearSlot:    lda     ##0                   ; (stz has no long mode)
              sta     long:(_g_psave+OFS_PL_MO),x
              sta     long:(_g_psave+OFS_PL_MO+2),x
              sta     long:(_g_psave+OFS_PL_KILLCOUNT),x
              sta     long:(_g_psave+OFS_PL_ITEMCOUNT),x
              sta     long:(_g_psave+OFS_PL_SECRETCOUNT),x
              sta     long:(_g_psave+OFS_PL_VIEWZ+2),x
              inc     a
              sta     long:(_g_psave+OFS_PL_VIEWZ),x
              rts

;;; ---------------------------------------------------------------------------
;;; playerField: In: _Dp[0-3] = a mobj, Y = the offset of a player field.
;;; Out: carry set and C = that field of the mobj's player, from the
;;; resident struct or his save slot; carry clear if it is no player's.
;;; ---------------------------------------------------------------------------
playerField:  phy
              jsl     long:P_PlayerOfMobj
              ply
              cmp     ##0
              bne     1$
              cpx     ##0
              beq     8$
1$:           cmp     ##.near _g_player
              bne     2$
              cpx     ##.word2 _g_player
              bne     2$
              lda     abs:.near _g_player,y
              sec
              rts
2$:           sec                           ; his save slot: the offset in it
              sbc     ##.word0 _g_psave
              sty     .near WR_T
              clc
              adc     .near WR_T
              tax
              lda     long:_g_psave,x
              sec
              rts
8$:           clc
              rts

;;; ---------------------------------------------------------------------------
;;; P_SourceChainsaw: carry set if DM_SOURCE (p_inter65.s, the source of the
;;; damage) is a player holding the chainsaw. Keeps _Dp.
;;; ---------------------------------------------------------------------------
              .public P_SourceChainsaw
P_SourceChainsaw:
              pei     dp:.tiny (_Dp+2)
              pei     dp:.tiny _Dp
              lda     .near DM_SOURCE
              sta     dp:.tiny _Dp
              lda     .near (DM_SOURCE+2)
              sta     dp:.tiny (_Dp+2)
              ldy     ##OFS_PL_READYWEAPON
              jsr     .kbank playerField
              bcc     1$
              cmp     ##CONST_WP_CHAINSAW
              beq     2$
1$:           ldx     ##0                   ; no
              bra     3$
2$:           ldx     ##1                   ; yes
3$:           pla
              sta     dp:.tiny _Dp
              pla
              sta     dp:.tiny (_Dp+2)
              cpx     ##1                   ; carry = X
              rtl
