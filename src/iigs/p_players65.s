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

              .rtmodel version, "1"
              .rtmodel core, "*"

#include "offsets.inc"

              .extern _Dp, _g_player, P_PlayerThink

              .section znear, bss
              .public _g_resident, _g_consoleplayer, _g_playeringame, _g_deathmatch
_g_resident:  .space  2               ; the player whose struct is _g_player
_g_consoleplayer: .space 2            ; the player at this machine
_g_playeringame: .space 4             ; player 0 is always in; a word for player 1
_g_deathmatch: .space 2

              .section zfar, bss
_g_psave:     .space  2 * SIZEOF_PL   ; a player's struct while he is not resident

              .section playerscode, text ; Code5a only: nothing else moves

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
9$:           rtl

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
