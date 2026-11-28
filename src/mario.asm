
; =====================================================================
;  SUPER MARIO ENGINE  -  EL2003 Computer Organization & Assembly Language
;  16-bit real mode, VGA mode 13h, NASM  ->  MARIO.COM
;
;  Build : nasm -f bin mario.asm -o MARIO.COM
;  Run   : DOSBox  (set  cycles=max  in dosbox.conf for full speed)
;
;  Conventions used by every procedure
;    * parameters are pushed on the stack (left to right); the callee
;      removes them with RET n  (Pascal style)
;    * a result, if any, comes back in AX
;    * every register not returned is preserved (PUSHA / POPA, plus ES)
;    * DS = CS = SS for the whole program (.COM, one segment); the
;      off-screen frame buffer lives in a second segment (BUFSEG)
; =====================================================================
; GROUP #5
        cpu     186
        bits    16
        org     0x0100
        JUMPS
        section .text
        jmp near     start

; ---------- MEMBER 1 ----------
; ---------------------------------------------------------------------
;  Module 1 : constants (EQU), macros
; ---------------------------------------------------------------------
SCREEN_W        equ 320
SCREEN_H        equ 200
VIDEO_SEG       equ 0A000h
TILE            equ 16
MAP_W           equ 60
MAP_H           equ 12
MAP_SIZE        equ MAP_W*MAP_H
LEVEL_PIX_W     equ MAP_W*TILE          ; 960
MAP_PIX_H       equ MAP_H*TILE          ; 192
MAX_CAM         equ LEVEL_PIX_W-SCREEN_W ; 640
CAM_FOLLOW_X    equ 160
HERO_MAX_X      equ LEVEL_PIX_W-16      ; 944
START_X         equ 32
GROUND_Y        equ 160                 ; feet position on the ground
HB_LEFT         equ 2                   ; hit-box: first pixel inside sprite
HB_RIGHT        equ 13                  ; hit-box: last  pixel inside sprite
HB_W            equ 12
POLE_X          equ 55*TILE             ; world x of flag-pole column
BASE_TOP_Y      equ 9*TILE              ; top of the pole base block

; colours (indices into the palette, see palette_tab)
C_BLACK         equ 0
C_YELLOW        equ 14
C_WHITE         equ 15
C_SKY           equ 16
C_BRICK         equ 19
C_RED           equ 21
C_LTRED         equ 12
C_GREY          equ 8
C_LTGREEN       equ 10

; tile codes (Appendix A.2)
T_SKY           equ 0
T_GROUND        equ 1
T_BRICK         equ 2
T_QCOIN         equ 3
T_QMUSH         equ 4
T_EMPTY         equ 5
T_COIN          equ 11
T_POLE          equ 12

; keyboard scan codes (Appendix A.3)
SC_ESC          equ 01h
SC_P            equ 19h
SC_ENTER        equ 1Ch
SC_LSHIFT       equ 2Ah
SC_SPACE        equ 39h
SC_LEFT         equ 4Bh
SC_RIGHT        equ 4Dh
SC_UP           equ 48h
SC_DOWN         equ 50h
SC_F1           equ 3Bh
SC_F2           equ 3Ch
SC_F3           equ 3Dh

; game limits (Appendix A.4)
START_LIVES     equ 3
MAX_LIVES       equ 99
LEVEL_TIME      equ 300
INVULN_FRAMES   equ 60                  ; about 2 s
FLAT_FRAMES     equ 30                  ; about 1 s
KICK_GRACE      equ 8
DEATH_FRAMES    equ 50                  ; about 1.5 s
LIFELOST_FRAMES equ 60                  ; about 2 s
TICKS_PER_SEC   equ 30
PIT_DIVISOR     equ 39773               ; 1193182 / 39773 = 30 Hz

; physics, 8.8 fixed point (Appendix A.5)
ACCEL           equ 0020h
BRAKE           equ 0040h
FRICTION        equ 0010h
WALK_MAX        equ 0180h
RUN_MAX         equ 0280h
GRAVITY         equ 0040h
JUMP_V          equ 0FA80h              ; -5.5
JUMP_CUT        equ 0FE00h              ; -2.0
MAX_FALL        equ 0400h
STOMP_BOUNCE    equ 0FD00h              ; -3.0
STOMP_BOUNCE_HI equ 0FB80h              ; -4.5 (jump key held)
DEATH_HOP       equ 0FB1Ah              ; about -4.9  (48 pixel hop)
GOOMBA_SPD      equ 0080h
KOOPA_SPD       equ 00C0h
SHELL_SPD       equ 0300h
MUSH_SPD        equ 0100h

; sprite flags
FLAG_MIRROR     equ 1
FLAG_HALF       equ 2
FLAG_TALL       equ 4

; game states (jump table index)
ST_TITLE        equ 0
ST_PLAYING      equ 1
ST_PAUSED       equ 2
ST_DYING        equ 3
ST_LIFELOST     equ 4
ST_WIN          equ 5
ST_COMPLETE     equ 6
ST_GAMEOVER     equ 7
ST_EXIT         equ 8

; entity record (enemies and items share the layout), 16 bytes
E_TYPE          equ 0                   ; 0 = unused
E_STATE         equ 1
E_X             equ 2                   ; word, world pixel
E_XF            equ 4                   ; byte, fraction
E_DIR           equ 5                   ; 1 = right, 0FFh = left
E_Y             equ 6                   ; word, top pixel
E_YF            equ 8
E_VY            equ 10                  ; word, 8.8
E_TIMER         equ 12                  ; word
E_SIZE          equ 16
ENEMY_MAX       equ 8
ITEM_MAX        equ 4
T_GOOMBA        equ 1
T_KOOPA         equ 2
S_WAIT          equ 0
S_WALK          equ 1
S_FLAT          equ 2
S_SHELL         equ 3
S_SLIDE         equ 4

; effect record (coin pop, score pop-up, brick debris), 12 bytes
F_KIND          equ 0
F_TIMER         equ 1
F_X             equ 2
F_Y             equ 4                   ; 8.8
F_VY            equ 6                   ; 8.8
F_VX            equ 8                   ; pixels per frame
F_VAL           equ 10
FX_SIZE         equ 12
FX_MAX          equ 12
FX_COIN         equ 1
FX_POPUP        equ 2
FX_DEBRIS       equ 3

; ---- procedure frame macros -------------------------------------------
%macro PROLOG 0
        push    bp
        mov     bp, sp
        pusha
%endmacro
%macro EPILOG 1
        popa
        pop     bp
%if %1 > 0
        ret     %1
%else
        ret
%endif
%endmacro
%macro PROLOGE 0                        ; same, and preserves ES
        push    bp
        mov     bp, sp
        pusha
        push    es
%endmacro
%macro EPILOGE 1
        pop     es
        popa
        pop     bp
%if %1 > 0
        ret     %1
%else
        ret
%endif
%endmacro
%macro RESULT 1                         ; value restored into AX by POPA
        mov     [bp-2], %1
%endmacro
%macro DRAWTEXT 5                       ; x, y, string, colour, scale
        push    %1
        push    %2
        push    %3
        push    %4
        push    %5
        call    DrawText
%endmacro
%macro DRAWNUM 7                        ; x, y, lo, hi, digits, colour, scale
        push    %1
        push    %2
        push    %3
        push    %4
        push    %5
        push    %6
        push    %7
        call    DrawNumber
%endmacro
%macro LOOPN 1                          ; LOOP with a long range
        dec     cx
        jz      %%d
        jmp near     %1
%%d:
%endmacro
%macro SETSTATE 1
        push    %1
        call    SetState
%endmacro
%macro HEROBOX 0                        ; pushes x, y, w, h of hero hit-box
        mov     ax, [hero_x]
        add     ax, HB_LEFT
        push    ax
        mov     ax, [hero_y]
        sub     ax, [hero_h]
        push    ax
        push    HB_W
        push    word [hero_h]
%endmacro

; ---------- MEMBER 1 ----------
; ---------------------------------------------------------------------
;  Program entry, main loop, clean exit  (Modules 1, 14, 15)
; ---------------------------------------------------------------------
start:
        cld
        mov     ax, cs
        add     ax, 1000h               ; segment just after our 64 KB
        mov     [bufseg], ax
        add     ax, 0FA0h               ; + 64000 bytes (in paragraphs)
        cmp     ax, VIDEO_SEG
        jb      .memok
        mov     dx, msg_nomem
        mov     ah, 9
        int     21h
        mov     ax, 4C01h
        int     21h
.memok: call    InitFont
        call    DecodeGraphics
        call    BuildLevel
        mov     ax, 0013h               ; VGA mode 13h
        int     10h
        call    SetPalette
        call    InstallKeyboard
        call    InstallTimer
        call    NewGame
        SETSTATE ST_TITLE
        mov     ax, [tick_count]
        mov     [last_tick], ax

main_loop:
        call    WaitTick
        inc     word [frame_ctr]
        xor     bh, bh
        mov     bl, [state]
        shl     bx, 1
        call    [state_table+bx]
        cmp     byte [state], ST_EXIT
        jne     main_loop

ExitProgram:                            ; the only exit path
        call    RestoreTimer
        call    RestoreKeyboard
        mov     ax, 0003h               ; text mode
        int     10h
        mov     ax, 4C00h
        int     21h

; ---------------------------------------------------------------------
; Name:              SetState
; Purpose:           Switch to a new game state and clear pending key events.
; Inputs:            [bp+4] = new state ID
; Outputs:           Updates state, state_timer, and zeroes key_event
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
SetState:
        PROLOGE
        mov     al, [bp+4]
        mov     [state], al
        mov     word [state_timer], 0
        mov     ax, ds
        mov     es, ax
        mov     di, key_event
        mov     cx, 64
        xor     ax, ax
        cld
        rep     stosw
        EPILOGE 2

; ---------- MEMBER 2 ----------
; ---------------------------------------------------------------------
;  Module 2 : video mode, colours, PutPixel, FillRect
; ---------------------------------------------------------------------
; Name:              SetPalette
; Purpose:           Load custom VGA palette entries 16..36 via BIOS INT 10h.
; Inputs:            None (reads palette_tab)
; Outputs:           VGA DAC registers updated
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
SetPalette:
        PROLOGE
        mov     ax, ds
        mov     es, ax
        mov     ax, 1012h
        mov     bx, PAL_FIRST
        mov     cx, PAL_COUNT
        mov     dx, palette_tab
        int     10h  ;interrupts
        EPILOGE 0

; ---------------------------------------------------------------------
; Name:              PutPixel
; Purpose:           Write one pixel into the off-screen frame buffer (clipped).
; Inputs:            [bp+8] = x, [bp+6] = y, [bp+4] = colour
; Outputs:           Pixel written to [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
PutPixel:
        PROLOGE
        mov     ax, [bp+8]              ; x
        mov     bx, [bp+6]              ; y
        cmp     ax, SCREEN_W            ; unsigned: negatives rejected too
        jae     .done
        cmp     bx, SCREEN_H
        jae     .done
        mov     es, [bufseg]
        mov     di, bx
        shl     di, 8                   ; y*256
        shl     bx, 6                   ; y*64
        add     di, bx                  ; y*320
        add     di, ax
        mov     al, [bp+4]
        mov     [es:di], al
.done:  EPILOGE 6

; ---------------------------------------------------------------------
; Name:              FillRect
; Purpose:           Draw a clipped filled rectangle into the frame buffer.
; Inputs:            [bp+12]=x, [bp+10]=y, [bp+8]=w, [bp+6]=h, [bp+4]=colour
; Outputs:           Rectangle written to [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
FillRect:
        PROLOGE
        mov     ax, [bp+12]             ; x
        mov     bx, [bp+10]             ; y
        mov     cx, [bp+8]              ; w
        mov     dx, [bp+6]              ; h
        test    ax, ax                  ; clip left
        jns     .xok
        add     cx, ax
        xor     ax, ax
.xok:   mov     si, ax                  ; clip right
        add     si, cx
        sub     si, SCREEN_W
        jle     .xr
        sub     cx, si
.xr:    test    bx, bx                  ; clip top
        jns     .yok
        add     dx, bx
        xor     bx, bx
.yok:   mov     si, bx                  ; clip bottom
        add     si, dx
        sub     si, SCREEN_H
        jle     .yr
        sub     dx, si
.yr:    cmp     cx, 0
        jle     .done
        cmp     dx, 0
        jle     .done
        mov     di, bx
        shl     di, 8
        shl     bx, 6
        add     di, bx
        add     di, ax
        mov     es, [bufseg]
        mov     al, [bp+4]
        cld
.row:   push    cx
        push    di
        rep     stosb
        pop     di
        pop     cx
        add     di, SCREEN_W
        dec     dx
        jnz     .row
.done:  EPILOGE 10

; ---------------------------------------------------------------------
; Name:              DrawBox
; Purpose:           Draw a filled rectangle with a 2-pixel border.
; Inputs:            [bp+14]=x, [bp+12]=y, [bp+10]=w, [bp+8]=h,
;                    [bp+6]=border colour, [bp+4]=fill colour
; Outputs:           Box written to [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawBox:
        PROLOG
        push    word [bp+14]
        push    word [bp+12]
        push    word [bp+10]
        push    word [bp+8]
        push    word [bp+6]
        call    FillRect
        mov     ax, [bp+14]
        add     ax, 2
        push    ax
        mov     ax, [bp+12]
        add     ax, 2
        push    ax
        mov     ax, [bp+10]
        sub     ax, 4
        push    ax
        mov     ax, [bp+8]
        sub     ax, 4
        push    ax
        push    word [bp+4]
        call    FillRect
        EPILOG  12

; ---------- MEMBER 1 ----------
; ---------------------------------------------------------------------
; Name:              InitFont
; Purpose:           Copy the BIOS 8x8 ROM font into font_buf.
; Inputs:            None
; Outputs:           Populates font_buf (1024 bytes)
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
InitFont:
        PROLOGE
        mov     ax, 1130h
        mov     bh, 3
        int     10h                     ; ES:BP -> 8x8 font (BP clobbered)
        mov     si, bp
        mov     ax, cs
        mov     bx, es
        mov     es, ax                  ; destination = our segment
        mov     ds, bx                  ; source      = ROM segment
        mov     di, font_buf
        mov     cx, 512
        cld
        rep     movsw
        mov     ds, ax                  ; DS back to our segment
        EPILOGE 0

; ---------------------------------------------------------------------
; Name:              DecodeGraphics
; Purpose:           Convert ASCII art characters in gfx_start..gfx_end
;                    into VGA palette indices.
; Inputs:            None (reads gfx_chars, gfx_cols, gfx_start..gfx_end)
; Outputs:           Replaces ASCII bytes in-place with palette indices
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DecodeGraphics:
        PROLOG
        mov     si, gfx_start
        mov     cx, gfx_end-gfx_start
.next:  mov     al, [si]
        mov     di, gfx_chars
        mov     dx, GFX_CHAR_COUNT
.find:  cmp     al, [di]
        je      .found
        inc     di
        dec     dx
        jnz     .find
        xor     al, al                  ; unknown letter = transparent
        jmp near     .store
.found: mov     al, [di+GFX_CHAR_COUNT]
.store: mov     [si], al
        inc     si
        loop    .next
        EPILOG  0

; ---------------------------------------------------------------------
;  Text: DrawGlyph, DrawChar, DrawText, DrawTextCentered, DrawNumber
; ---------------------------------------------------------------------
; Name:              DrawGlyph
; Purpose:           Render an 8x8 bit-mapped glyph at (x, y) with scaling.
; Inputs:            [bp+12]=x, [bp+10]=y, [bp+8]=glyph_offset,
;                    [bp+6]=colour, [bp+4]=scale
; Outputs:           Glyph drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawGlyph:
        PROLOGE
        mov     es, [bufseg]
        mov     si, [bp+8]
        mov     bx, [bp+10]             ; y of current row
        mov     word [gl_rows], 8
.row:   lodsb
        mov     dh, al                  ; bits, msb = leftmost
        mov     cx, [bp+12]             ; x of current column
        mov     dl, 8
.col:   shl     dh, 1
        jc      $+5
        jmp near     near .next
        cmp     word [bp+4], 1
        jne     .big
        cmp     cx, SCREEN_W   ;compare cx with constant
        jb      $+5
        jmp near     near .next
        cmp     bx, SCREEN_H
        jae     .next
        mov     di, bx
        shl     di, 8
        push    bx
        shl     bx, 6
        add     di, bx
        pop     bx
        add     di, cx
        mov     al, [bp+6]
        mov     [es:di], al
        jmp near     .next
.big:   push    cx
        push    bx
        push    word [bp+4]
        push    word [bp+4]
        push    word [bp+6]
        call    FillRect
.next:  add     cx, [bp+4]
        dec     dl
        jz      $+5
        jmp near     near .col
        add     bx, [bp+4]
        dec     word [gl_rows]
        jz      $+5
        jmp near     near .row
        EPILOGE 10

; ---------------------------------------------------------------------
; Name:              DrawChar
; Purpose:           Draw a single ASCII character from font_buf.
; Inputs:            [bp+12]=x, [bp+10]=y, [bp+8]=ascii,
;                    [bp+6]=colour, [bp+4]=scale
; Outputs:           Character drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawChar:
        PROLOG
        mov     ax, [bp+8]
        and     ax, 7Fh
        shl     ax, 3
        add     ax, font_buf
        push    word [bp+12]
        push    word [bp+10]
        push    ax
        push    word [bp+6]
        push    word [bp+4]
        call    DrawGlyph
        EPILOG  10

; ---------------------------------------------------------------------
; Name:              DrawText
; Purpose:           Draw a null-terminated ASCII string at (x, y).
; Inputs:            [bp+12]=x, [bp+10]=y, [bp+8]=string0,
;                    [bp+6]=colour, [bp+4]=scale
; Outputs:           Text drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawText:
        PROLOG
        mov     si, [bp+8]
        mov     bx, [bp+12]
.l:     mov     al, [si]
        test    al, al
        jz      .d
        xor     ah, ah
        push    bx
        push    word [bp+10]
        push    ax
        push    word [bp+6]
        push    word [bp+4]
        call    DrawChar
        mov     ax, [bp+4]
        shl     ax, 3
        add     bx, ax
        inc     si
        jmp near     .l
.d:     EPILOG  10

; ---------------------------------------------------------------------
; Name:              DrawTextCentered
; Purpose:           Draw a null-terminated string horizontally centered.
; Inputs:            [bp+10]=y, [bp+8]=string0, [bp+6]=colour, [bp+4]=scale
; Outputs:           Centered text drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawTextCentered:
        PROLOG
        mov     si, [bp+8]
        xor     cx, cx
.len:   cmp     byte [si], 0
        je      .got
        inc     si
        inc     cx
        jmp near     .len
.got:   mov     ax, cx
        mul     word [bp+4]
        shl     ax, 3
        mov     bx, SCREEN_W
        sub     bx, ax
        shr     bx, 1
        push    bx
        push    word [bp+10]
        push    word [bp+8]
        push    word [bp+6]
        push    word [bp+4]
        call    DrawText
        EPILOG  8

; ---------------------------------------------------------------------
; Name:              DrawNumber
; Purpose:           Convert a 32-bit unsigned number to zero-padded decimal
;                    digits via repeated division by 10 and stack push/pop.
; Inputs:            [bp+16]=x, [bp+14]=y, [bp+12]=lo, [bp+10]=hi,
;                    [bp+8]=digits, [bp+6]=colour, [bp+4]=scale
; Outputs:           Digits drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawNumber:
        PROLOG
        mov     di, [bp+8]              ; digit count
        mov     si, [bp+10]             ; hi
        mov     bx, [bp+12]             ; lo
.dv:    xor     dx, dx
        mov     ax, si
        mov     cx, 10
        div     cx                      ; hi / 10
        mov     si, ax
        mov     ax, bx
        div     cx                      ; (rem:lo) / 10
        mov     bx, ax
        push    dx                      ; remainder = digit
        dec     di
        jnz     .dv
        mov     di, [bp+8]
        mov     si, [bp+16]             ; x
.dr:    pop     ax
        add     ax, '0'
        push    si
        push    word [bp+14]
        push    ax
        push    word [bp+6]
        push    word [bp+4]
        call    DrawChar
        mov     ax, [bp+4]
        shl     ax, 3
        add     si, ax
        dec     di
        jnz     .dr
        EPILOG  14

; ---------------------------------------------------------------------
; ---------- MEMBER 1 ----------
;  Module 3 : level map, GetTile, DrawTile, DrawMap
; ---------------------------------------------------------------------
; Name:              BuildLevel
; Purpose:           Convert ASCII level_text into tile codes in level_orig
;                    and copy to level_work.
; Inputs:            None (reads level_text, tile_chars)
; Outputs:           Populates level_orig and level_work
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
BuildLevel:
        PROLOG
        mov     si, level_text
        mov     di, level_orig
        mov     cx, MAP_SIZE
.nx:    mov     al, [si]
        inc     si
        mov     bx, tile_chars
        xor     dx, dx
.f:     cmp     al, [bx]
        je      .got
        inc     bx
        inc     dx
        cmp     dx, 15
        jb      .f
        xor     dx, dx                  ; unknown character = sky
.got:   mov     [di], dl
        inc     di
        loop    .nx
        call    ResetMap
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              ResetMap
; Purpose:           Restore working map (level_work) from untouched
;                    level_orig using REP MOVSW.
; Inputs:            None
; Outputs:           Overwrites level_work with level_orig
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
ResetMap:
        PROLOGE
        mov     ax, ds
        mov     es, ax
        mov     si, level_orig
        mov     di, level_work
        mov     cx, MAP_SIZE/2
        cld
        rep     movsw
        EPILOGE 0

; ---------------------------------------------------------------------
; Name:              GetTile
; Purpose:           Return the tile code at world pixel (px, py).
;                    Outside left/right = solid ground; above/below = sky.
; Inputs:            [bp+6]=px, [bp+4]=py
; Outputs:           AX = tile code
; Registers changed: AX (all others preserved)
; ---------------------------------------------------------------------
GetTile:
        PROLOG
        mov     ax, [bp+6]              ; px
        mov     bx, [bp+4]              ; py
        mov     dx, 1
        cmp     ax, 0
        jl      .out
        cmp     ax, LEVEL_PIX_W
        jge     .out
        xor     dx, dx
        cmp     bx, 0
        jl      .out
        cmp     bx, MAP_PIX_H
        jge     .out
        shr     ax, 4                   ; column
        shr     bx, 4                   ; row
        imul    bx, bx, MAP_W
        add     bx, ax
        mov     dl, [level_work+bx]
        xor     dh, dh
.out:   RESULT  dx
        EPILOG  4

; ---------------------------------------------------------------------
; Name:              IsSolid
; Purpose:           Check whether the tile at world pixel (px, py) is solid.
; Inputs:            [bp+6]=px, [bp+4]=py
; Outputs:           AX = 1 if solid (codes 1..10), else 0
; Registers changed: AX (all others preserved)
; ---------------------------------------------------------------------
IsSolid:
        PROLOG
        push    word [bp+6]
        push    word [bp+4]
        call    GetTile
        xor     dx, dx
        cmp     ax, 1
        jb      .n
        cmp     ax, 10
        ja      .n
        mov     dx, 1
.n:     RESULT  dx
        EPILOG  4

; ---------------------------------------------------------------------
; Name:              SetTile
; Purpose:           Write a tile code into the working map (bounds checked).
; Inputs:            [bp+8]=col, [bp+6]=row, [bp+4]=code
; Outputs:           Updates level_work[row * MAP_W + col]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
SetTile:
        PROLOG
        mov     bx, [bp+6]
        cmp     bx, MAP_H
        jae     .d
        mov     ax, [bp+8]
        cmp     ax, MAP_W
        jae     .d
        imul    bx, bx, MAP_W
        add     bx, ax
        mov     al, [bp+4]
        mov     [level_work+bx], al
.d:     EPILOG  6

; ---------------------------------------------------------------------
; Name:              DrawTile
; Purpose:           Draw a 16x16 tile at screen (x, y); opaque tiles use
;                    REP MOVSW, transparent/clipped tiles use DrawSprite.
; Inputs:            [bp+8]=x, [bp+6]=y, [bp+4]=tile code
; Outputs:           Tile drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawTile:
        PROLOGE
        mov     bx, [bp+4]
        test    bx, bx
        jnz     $+5
        jmp near     near .done
        shl     bx, 1
        mov     si, [tile_ptr+bx]
        mov     ax, [bp+8]              ; x
        mov     dx, [bp+6]              ; y
        cmp     word [bp+4], T_COIN
        jne     $+5
        jmp near     near .slow
        cmp     word [bp+4], T_POLE
        jne     $+5
        jmp near     near .slow
        cmp     ax, 0
        jge     $+5
        jmp near     near .slow
        cmp     ax, SCREEN_W-16
        jle     $+5
        jmp near     near .slow
        cmp     dx, 0
        jl      .slow
        cmp     dx, SCREEN_H-16
        jg      .slow
        mov     es, [bufseg]
        mov     di, dx
        shl     di, 8
        shl     dx, 6
        add     di, dx
        add     di, ax
        mov     bx, 16
        cld
.r:     mov     cx, 8
        rep     movsw
        add     di, SCREEN_W-16
        dec     bx
        jnz     .r
        jmp near     .done
.slow:  push    ax
        push    dx
        push    si
        push    0
        call    DrawSprite
.done:  EPILOGE 6

; ---------------------------------------------------------------------
; Name:              DrawMap
; Purpose:           Draw the 20 visible (+1 partial) map columns using
;                    camera_x / 16 and pixel offset camera_x mod 16.
; Inputs:            None (reads camera_x, level_work)
; Outputs:           Visible map rows 1..11 drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawMap:
        PROLOG
        mov     ax, [camera_x]
        mov     bx, ax
        shr     ax, 4
        and     bx, 15
        mov     [dm_first], ax
        mov     [dm_off], bx
        xor     si, si                  ; screen column 0..20
.col:   mov     ax, [dm_first]
        add     ax, si
        cmp     ax, MAP_W
        jb      $+5
        jmp near     near .done
        mov     di, ax                  ; map column
        mov     bx, si
        shl     bx, 4
        sub     bx, [dm_off]            ; screen x
        mov     dx, 1                   ; rows 1..11 (row 0 = HUD)
.row:   imul    ax, dx, MAP_W
        add     ax, di
        push    bx
        mov     bx, ax
        mov     al, [level_work+bx]
        pop     bx
        xor     ah, ah
        test    al, al
        jz      .skip
        push    bx
        mov     cx, dx
        shl     cx, 4
        push    cx
        push    ax
        call    DrawTile
.skip:  inc     dx
        cmp     dx, MAP_H
        jb      .row
        inc     si
        cmp     si, 21
        jae     $+5
        jmp near     near .col
.done:  EPILOG  0

; ---------------------------------------------------------------------
;  Module 4 : sprites
; ---------------------------------------------------------------------
; Name:              DrawSprite
; Purpose:           Draw a 16x16 (or 16x32 with FLAG_TALL) sprite with
;                    transparency (0), optional mirroring, and 4-edge clipping.
; Inputs:            [bp+10]=x, [bp+8]=y, [bp+6]=bitmap addr, [bp+4]=flags
; Outputs:           Sprite drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawSprite:
        PROLOGE
        mov     es, [bufseg]
        mov     ax, [bp+10]             ; x
        xor     cx, cx                  ; first visible column
        mov     di, 16                  ; one past last visible column
        test    ax, ax
        jns     .l_ok
        mov     cx, ax
        neg     cx
.l_ok:  mov     bx, SCREEN_W
        sub     bx, ax                  ; 320 - x
        cmp     bx, di
        jge     .r_ok
        mov     di, bx
.r_ok:  cmp     cx, di
        jl      $+5
        jmp near     near .done
        mov     [spr_cs], cx
        mov     [spr_ce], di
        mov     word [spr_rows], 16
        test    byte [bp+4], FLAG_TALL
        jz      .go
        mov     word [spr_rows], 32
.go:    mov     si, [bp+6]
        mov     dx, [bp+8]              ; y
.rowloop:
        cmp     dx, 0
        jge     $+5
        jmp near     near .nextrow
        cmp     dx, SCREEN_H
        jl      $+5
        jmp near     near .nextrow
        mov     di, dx
        shl     di, 8
        mov     ax, dx
        shl     ax, 6
        add     di, ax
        add     di, [bp+10]
        add     di, [spr_cs]
        mov     cx, [spr_cs]
.pix:   mov     bx, si
        test    byte [bp+4], FLAG_MIRROR
        jz      .nm
        add     bx, 15
        sub     bx, cx
        jmp near     .rd
.nm:    add     bx, cx
.rd:    mov     al, [bx]
        test    al, al
        jz      .skp
        test    byte [bp+4], FLAG_HALF
        jz      .wr
        mov     ah, dl
        add     ah, cl
        test    ah, 1
        jz      .skp
.wr:    mov     [es:di], al
.skp:   inc     di
        inc     cx
        cmp     cx, [spr_ce]
        jae     $+5
        jmp near     near .pix
.nextrow:
        add     si, 16
        inc     dx
        dec     word [spr_rows]
        jz      $+5
        jmp near     near .rowloop
.done:  EPILOGE 8

; ---------------------------------------------------------------------
; ---------- MEMBER 2 ----------
;  Module 5 : frame buffer
; ---------------------------------------------------------------------
; Name:              ClearBuffer
; Purpose:           Fill the off-screen frame buffer (192 rows sky, 8 rows
;                    black) using REP STOSW.
; Inputs:            None
; Outputs:           Frame buffer [bufseg] cleared
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
ClearBuffer:
        PROLOGE
        mov     es, [bufseg]
        xor     di, di
        mov     ax, C_SKY*256+C_SKY
        mov     cx, MAP_PIX_H*SCREEN_W/2
        cld
        rep     stosw
        xor     ax, ax
        mov     cx, (SCREEN_H-MAP_PIX_H)*SCREEN_W/2
        rep     stosw
        EPILOGE 0

; ---------------------------------------------------------------------
; Name:              PresentBuffer
; Purpose:           Copy the 64,000-byte frame buffer to VGA video memory
;                    (0A000h) using REP MOVSW.
; Inputs:            None
; Outputs:           Frame displayed on screen
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
PresentBuffer:
        PROLOGE
        push    ds
        mov     ax, VIDEO_SEG
        mov     es, ax
        mov     ds, [bufseg]
        xor     si, si
        xor     di, di
        mov     cx, 32000
        cld
        rep     movsw
        pop     ds
        EPILOGE 0

; ---------------------------------------------------------------------
; ---------- MEMBER 1 ----------
;  Module 6 : camera (Section 5.3)
; ---------------------------------------------------------------------
; Name:              UpdateCamera
; Purpose:           Follow Mario past screen x = 160, clamp to MAX_CAM,
;                    never scroll left, and enforce left-edge invisible wall.
; Inputs:            None (reads/updates hero_x, camera_x)
; Outputs:           Updates camera_x and clamps hero_x if needed
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
UpdateCamera:
        PROLOG
        mov     ax, [hero_x]
        mov     bx, ax
        sub     bx, [camera_x]          ; screen_x
        cmp     bx, CAM_FOLLOW_X
        jle     .wall
        mov     bx, ax
        sub     bx, CAM_FOLLOW_X        ; new camera
        cmp     bx, MAX_CAM
        jle     .lim
        mov     bx, MAX_CAM
.lim:   cmp     bx, [camera_x]
        jle     .wall                   ; never decrease
        mov     [camera_x], bx
.wall:  mov     ax, [hero_x]            ; left wall
        cmp     ax, [camera_x]
        jge     .ok
        mov     ax, [camera_x]
        mov     [hero_x], ax
        mov     word [hero_vx], 0
        mov     byte [hero_xf], 0
.ok:    EPILOG  0

; ---------------------------------------------------------------------
;  Module 7 : keyboard interrupt handler (INT 09h)
; ---------------------------------------------------------------------
; Name:              KeyboardISR
; Purpose:           Custom INT 09h handler; reads port 60h, handles E0h
;                    extended codes, updates key_down/key_event, sends EOI.
; Inputs:            Hardware scan code from port 60h
; Outputs:           Updates kb_e0, key_down, key_event
; Registers changed: None (all saved/restored around IRET)
; ---------------------------------------------------------------------
KeyboardISR:
        push    ax
        push    bx
        push    ds
        mov     ax, cs
        mov     ds, ax
        in      al, 60h
        cmp     al, 0E0h                ; extended prefix: remember, ignore
        jne     .nE0
        mov     byte [kb_e0], 1
        jmp near     .eoi
.nE0:   mov     ah, [kb_e0]
        mov     byte [kb_e0], 0
        mov     bl, al
        and     bl, 7Fh
        test    ah, ah
        jz      .proc
        cmp     bl, 2Ah                 ; fake shift sent with arrows (NumLock)
        je      .eoi
.proc:  xor     bh, bh
        test    al, 80h
        jnz     .rel
        cmp     byte [key_down+bx], 0   ; ignore typematic repeats
        jne     .eoi
        mov     byte [key_down+bx], 1
        mov     byte [key_event+bx], 1
        jmp near     .eoi
.rel:   mov     byte [key_down+bx], 0
.eoi:   mov     al, 20h                 ; end of interrupt
        out     20h, al
        pop     ds
        pop     bx
        pop     ax
        iret

; ---------------------------------------------------------------------
; Name:              InstallKeyboard
; Purpose:           Save the original INT 09h vector and install KeyboardISR.
; Inputs:            None
; Outputs:           Updates old_int09 and IVT entry 09h
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
InstallKeyboard:
        PROLOGE
        mov     ax, 3509h
        int     21h
        mov     [old_int09], bx
        mov     [old_int09+2], es
        mov     dx, KeyboardISR
        mov     ax, 2509h
        int     21h
        EPILOGE 0

; ---------------------------------------------------------------------
; Name:              RestoreKeyboard
; Purpose:           Restore the original INT 09h interrupt vector.
; Inputs:            None (reads old_int09)
; Outputs:           IVT entry 09h restored
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
RestoreKeyboard:
        PROLOG
        push    ds
        lds     dx, [old_int09]
        mov     ax, 2509h
        int     21h
        pop     ds
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              KeyDown
; Purpose:           Check whether a key is currently held down.
; Inputs:            [bp+4] = scan code
; Outputs:           AX = 1 if held, else 0
; Registers changed: AX (all others preserved)
; ---------------------------------------------------------------------
KeyDown:
        PROLOG
        mov     bx, [bp+4]
        and     bx, 7Fh
        xor     ax, ax
        mov     al, [key_down+bx]
        RESULT  ax
        EPILOG  2

; ---------------------------------------------------------------------
; Name:              KeyPressed
; Purpose:           Consume and return a single key-press event.
; Inputs:            [bp+4] = scan code
; Outputs:           AX = 1 if newly pressed (cleared after read), else 0
; Registers changed: AX (all others preserved)
; ---------------------------------------------------------------------
KeyPressed:
        PROLOG
        mov     bx, [bp+4]
        and     bx, 7Fh
        xor     ax, ax
        mov     al, [key_event+bx]
        mov     byte [key_event+bx], 0
        RESULT  ax
        EPILOG  2

; ---------------------------------------------------------------------
;  Module 8 : timer interrupt and game clock (INT 08h, 30 Hz)
; ---------------------------------------------------------------------
; Name:              TimerISR
; Purpose:           Custom 30 Hz INT 08h handler; increments tick_count and
;                    chains to the BIOS handler at ~18.2 Hz.
; Inputs:            Hardware IRQ0
; Outputs:           Updates tick_count, bios_acc
; Registers changed: None (all saved/restored around IRET / far jump)
; ---------------------------------------------------------------------
TimerISR:
        push    ax
        push    ds
        mov     ax, cs
        mov     ds, ax
        inc     word [tick_count]
        add     word [bios_acc], 182
        cmp     word [bios_acc], 300
        jb      .own
        sub     word [bios_acc], 300
        pop     ds
        pop     ax
        jmp far [cs:old_int08]          ; old handler sends EOI and IRETs
.own:
        mov     al, 20h
        out     20h, al
        pop     ds
        pop     ax
        iret

; ---------------------------------------------------------------------
; Name:              InstallTimer
; Purpose:           Save original INT 08h vector, install TimerISR, and
;                    program PIT channel 0 to 30 Hz.
; Inputs:            None
; Outputs:           Updates old_int08, IVT entry 08h, and PIT divisor
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
InstallTimer:
        PROLOGE
        mov     ax, 3508h
        int     21h
        mov     [old_int08], bx
        mov     [old_int08+2], es
        mov     dx, TimerISR
        mov     ax, 2508h
        int     21h
        cli
        mov     al, 36h                 ; channel 0, mode 3
        out     43h, al
        mov     ax, PIT_DIVISOR
        out     40h, al
        mov     al, ah
        out     40h, al
        sti
        EPILOGE 0

; ---------------------------------------------------------------------
; Name:              RestoreTimer
; Purpose:           Restore PIT channel 0 to 18.2 Hz and restore INT 08h.
; Inputs:            None (reads old_int08)
; Outputs:           PIT and IVT entry 08h restored
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
RestoreTimer:
        PROLOG
        cli
        mov     al, 36h
        out     43h, al
        xor     al, al                  ; divisor 0 = 65536 = 18.2 Hz
        out     40h, al
        out     40h, al
        sti
        push    ds
        lds     dx, [old_int08]
        mov     ax, 2508h
        int     21h
        pop     ds
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              WaitTick
; Purpose:           Wait until tick_count advances and record tick_delta.
; Inputs:            None (reads tick_count, last_tick)
; Outputs:           Updates last_tick and tick_delta (clamped to 8)
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
WaitTick:
        PROLOG
.w:     mov     ax, [tick_count]
        cmp     ax, [last_tick]
        jne     .got
        hlt
        jmp near     .w
.got:   mov     bx, ax
        sub     bx, [last_tick]
        mov     [last_tick], ax
        cmp     bx, 8
        jbe     .ok
        mov     bx, 8
.ok:    mov     [tick_delta], bx
        EPILOG  0

; ---------------------------------------------------------------------
;  Module 9 : player movement and physics (Section 5.2)
; ---------------------------------------------------------------------
; Name:              SetForm
; Purpose:           Set Mario's form (0 = Small, 1 = Super), HP, and height
;                    while keeping feet position (hero_y) fixed.
; Inputs:            [bp+4] = form (0 or 1)
; Outputs:           Updates hero_form, hero_hp, hero_h
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
SetForm:
        PROLOG
        mov     ax, [bp+4]
        mov     [hero_form], al
        inc     ax
        mov     [hero_hp], al
        mov     word [hero_h], 16
        cmp     byte [hero_form], 0
        je      .d
        mov     word [hero_h], 32
.d:     EPILOG  2

; ---------------------------------------------------------------------
; Name:              SolidColumn
; Purpose:           Test top, middle, and bottom points of Mario's body at
;                    pixel column px for solid tiles.
; Inputs:            [bp+4] = world pixel x
; Outputs:           AX = 1 if any sample is solid, else 0
; Registers changed: AX (all others preserved)
; ---------------------------------------------------------------------
SolidColumn:
        PROLOG
        xor     dx, dx
        mov     ax, [hero_y]
        sub     ax, [hero_h]
        push    word [bp+4]
        push    ax
        call    IsSolid
        or      dx, ax
        mov     ax, [hero_y]
        mov     bx, [hero_h]
        shr     bx, 1
        sub     ax, bx
        push    word [bp+4]
        push    ax
        call    IsSolid
        or      dx, ax
        mov     ax, [hero_y]
        dec     ax
        push    word [bp+4]
        push    ax
        call    IsSolid
        or      dx, ax
        RESULT  dx
        EPILOG  2

; ---------------------------------------------------------------------
; Name:              UpdateMario
; Purpose:           Update Mario's velocity, jump, gravity, and move
;                    horizontally then vertically with tile collision.
; Inputs:            None
; Outputs:           Updates hero_x/y/vx/vy/ground/chain/anim and triggers blocks
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
UpdateMario:
        PROLOG
        mov     ax, [hero_y]
        mov     [hero_prev_y], ax       ; feet of the previous frame (stomp test)

        ; ---- ground probe: solid tile just below the feet? ----
        mov     byte [hero_ground], 0
        cmp     word [hero_vy], 0
        jge     $+5
        jmp near     near .noprobe
        mov     ax, [hero_x]
        add     ax, HB_LEFT
        push    ax
        push    word [hero_y]
        call    IsSolid
        test    ax, ax
        jnz     .grounded
        mov     ax, [hero_x]
        add     ax, HB_RIGHT
        push    ax
        push    word [hero_y]
        call    IsSolid
        test    ax, ax
        jz      .noprobe
.grounded:
        mov     byte [hero_ground], 1
        mov     word [hero_vy], 0
        mov     byte [hero_yf], 0
        mov     byte [hero_chain], 0
.noprobe:

        ; ---- horizontal input ----
        mov     bx, WALK_MAX
        push    SC_LSHIFT
        call    KeyDown
        test    ax, ax
        jz      .gotmax
        mov     bx, RUN_MAX
.gotmax:
        push    SC_RIGHT
        call    KeyDown
        mov     si, ax
        push    SC_LEFT
        call    KeyDown
        mov     di, ax
        test    si, si
        jz      .notr
        test    di, di
        jz      $+5
        jmp near     near .none
        mov     byte [hero_face], 0
        mov     ax, [hero_vx]
        cmp     ax, 0
        jge     .acc_r
        add     ax, BRAKE               ; braking (opposite direction)
        jmp near     .set
.acc_r: add     ax, ACCEL
        cmp     ax, bx
        jg      $+5
        jmp near     near .set
        mov     ax, bx
        jmp near     .set
.notr:  test    di, di
        jz      .none
        mov     byte [hero_face], 1
        mov     ax, [hero_vx]
        cmp     ax, 0
        jle     .acc_l
        sub     ax, BRAKE
        jmp near     .set
.acc_l: sub     ax, ACCEL
        neg     bx
        cmp     ax, bx
        jge     .set
        mov     ax, bx
        jmp near     .set
.none:  mov     ax, [hero_vx]           ; friction
        cmp     ax, 0
        jg      .fpos
        jl      .fneg
        jmp near     .set
.fpos:  sub     ax, FRICTION
        jge     .set
        xor     ax, ax
        jmp near     .set
.fneg:  add     ax, FRICTION
        jle     .set
        xor     ax, ax
.set:   mov     [hero_vx], ax

        ; ---- jump (ground only) and variable jump height ----
        push    SC_SPACE
        call    KeyDown
        test    ax, ax
        jnz     .space
        mov     byte [hero_latch], 0
        mov     ax, [hero_vy]
        cmp     ax, JUMP_CUT
        jl      $+5
        jmp near     near .jdone
        mov     word [hero_vy], JUMP_CUT
        jmp near     .jdone
.space: cmp     byte [hero_ground], 0
        je      .jdone
        cmp     byte [hero_latch], 0
        jne     .jdone
        mov     word [hero_vy], JUMP_V
        mov     byte [hero_ground], 0
        mov     byte [hero_yf], 0
        mov     byte [hero_latch], 1
.jdone:

        ; ---- gravity ----
        cmp     byte [hero_ground], 0
        jne     .nograv
        mov     ax, [hero_vy]
        add     ax, GRAVITY
        cmp     ax, MAX_FALL
        jle     .gs
        mov     ax, MAX_FALL
.gs:    mov     [hero_vy], ax
.nograv:

        ; ---- move horizontally (24-bit position: word + fraction byte) ----
        mov     ax, [hero_vx]
        mov     bx, ax
        sar     bx, 8
        add     [hero_xf], al
        adc     [hero_x], bx
        test    ax, ax
        jnz     $+5
        jmp near     near .xdone
        jg      .xr
        mov     ax, [hero_x]            ; moving left: test left edge
        add     ax, HB_LEFT
        push    ax
        call    SolidColumn
        test    ax, ax
        jnz     $+5
        jmp near     near .xdone
        mov     ax, [hero_x]
        add     ax, HB_LEFT
        and     ax, 0FFF0h
        add     ax, 16
        sub     ax, HB_LEFT
        mov     [hero_x], ax
        jmp near     .xstop
.xr:    mov     ax, [hero_x]            ; moving right: test right edge
        add     ax, HB_RIGHT
        push    ax
        call    SolidColumn
        test    ax, ax
        jz      .xdone
        mov     ax, [hero_x]
        add     ax, HB_RIGHT
        and     ax, 0FFF0h
        sub     ax, HB_RIGHT+1
        mov     [hero_x], ax
.xstop: mov     word [hero_vx], 0
        mov     byte [hero_xf], 0
.xdone: cmp     word [hero_x], HERO_MAX_X
        jle     .xend
        mov     word [hero_x], HERO_MAX_X
        mov     word [hero_vx], 0
.xend:

        ; ---- move vertically ----
        mov     ax, [hero_vy]
        mov     bx, ax
        sar     bx, 8
        add     [hero_yf], al
        adc     [hero_y], bx
        test    ax, ax
        jnz     $+5
        jmp near     near .ydone
        jle     $+5
        jmp near     near .down
        mov     di, [hero_y]            ; rising: test the head
        sub     di, [hero_h]
        mov     ax, [hero_x]
        add     ax, HB_LEFT
        push    ax
        push    di
        call    IsSolid
        mov     si, ax
        mov     ax, [hero_x]
        add     ax, HB_RIGHT
        push    ax
        push    di
        call    IsSolid
        or      si, ax
        test    si, si
        jnz     $+5
        jmp near     near .ydone
        mov     ax, di                  ; put the head just under the tile
        sar     ax, 4
        inc     ax
        shl     ax, 4
        add     ax, [hero_h]
        mov     [hero_y], ax
        mov     word [hero_vy], 0
        mov     byte [hero_yf], 0
        mov     ax, [hero_x]            ; block above the head centre
        add     ax, 8
        sar     ax, 4
        mov     bx, di
        sar     bx, 4
        push    ax
        push    bx
        call    HitBlock
        jmp near     .ydone
.down:  mov     di, [hero_y]            ; falling: test the feet
        dec     di
        mov     ax, [hero_x]
        add     ax, HB_LEFT
        push    ax
        push    di
        call    IsSolid
        mov     si, ax
        mov     ax, [hero_x]
        add     ax, HB_RIGHT
        push    ax
        push    di
        call    IsSolid
        or      si, ax
        test    si, si
        jz      .ydone
        mov     ax, di
        and     ax, 0FFF0h              ; top of that tile
        mov     [hero_y], ax
        mov     word [hero_vy], 0
        mov     byte [hero_yf], 0
        mov     byte [hero_ground], 1
        mov     byte [hero_chain], 0
.ydone:
        ; ---- running animation counter ----
        cmp     word [hero_vx], 0
        je      .end
        inc     word [hero_anim]
.end:   EPILOG  0

; ---------------------------------------------------------------------
;  Module 10 : collision helpers
; ---------------------------------------------------------------------
; Name:              RectOverlap
; Purpose:           Axis-aligned bounding-box overlap test.
; Inputs:            [bp+18]=x1, [bp+16]=y1, [bp+14]=w1, [bp+12]=h1,
;                    [bp+10]=x2, [bp+8]=y2,  [bp+6]=w2,  [bp+4]=h2
; Outputs:           AX = 1 if overlapping, else 0
; Registers changed: AX (all others preserved)
; ---------------------------------------------------------------------
RectOverlap:
        PROLOG
        xor     dx, dx
        mov     ax, [bp+10]
        add     ax, [bp+6]
        cmp     [bp+18], ax             ; x1 < x2+w2 ?
        jge     .no
        mov     ax, [bp+18]
        add     ax, [bp+14]
        cmp     [bp+10], ax             ; x2 < x1+w1 ?
        jge     .no
        mov     ax, [bp+8]
        add     ax, [bp+4]
        cmp     [bp+16], ax             ; y1 < y2+h2 ?
        jge     .no
        mov     ax, [bp+16]
        add     ax, [bp+12]
        cmp     [bp+8], ax              ; y2 < y1+h1 ?
        jge     .no
        mov     dx, 1
.no:    RESULT  dx
        EPILOG  16

; ---------------------------------------------------------------------
; Name:              StompTest
; Purpose:           Determine if Mario is stomping an enemy (falling and
;                    previous-frame feet above upper half of enemy).
; Inputs:            [bp+4] = enemy_top_y
; Outputs:           AX = 1 if stomp, else 0
; Registers changed: AX (all others preserved)
; ---------------------------------------------------------------------
StompTest:
        PROLOG
        xor     dx, dx
        cmp     word [hero_vy], 0
        jle     .n
        mov     ax, [bp+4]
        add     ax, 8
        cmp     [hero_prev_y], ax
        jg      .n
        mov     dx, 1
.n:     RESULT  dx
        EPILOG  2

; ---------------------------------------------------------------------
; Name:              Bounce
; Purpose:           Apply upward bounce velocity after stomping an enemy
;                    (higher if Space is held).
; Inputs:            None
; Outputs:           Updates hero_vy, hero_ground, hero_yf
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
Bounce:
        PROLOG
        mov     word [hero_vy], STOMP_BOUNCE
        push    SC_SPACE
        call    KeyDown
        test    ax, ax
        jz      .a
        mov     word [hero_vy], STOMP_BOUNCE_HI
.a:     mov     byte [hero_ground], 0
        mov     byte [hero_yf], 0
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              CollectTiles
; Purpose:           Sample 6 points of Mario's hitbox for map coins and
;                    flag-pole contact.
; Inputs:            None
; Outputs:           Removes collected coins, updates flag_hit and flag_row
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
CollectTiles:
        PROLOG
        xor     si, si
.xl:    mov     bx, [hero_x]
        add     bx, HB_LEFT
        test    si, si
        jz      .gx
        add     bx, HB_RIGHT-HB_LEFT
.gx:    xor     di, di
.yl:    mov     dx, [hero_y]
        cmp     di, 0
        jne     .m
        sub     dx, [hero_h]
        jmp near     .gy
.m:     cmp     di, 1
        jne     .b
        mov     ax, [hero_h]
        shr     ax, 1
        sub     dx, ax
        jmp near     .gy
.b:     dec     dx
.gy:    push    bx
        push    dx
        call    GetTile
        cmp     ax, T_COIN
        jne     .pole
        mov     ax, bx
        sar     ax, 4
        mov     cx, dx
        sar     cx, 4
        push    ax
        push    cx
        push    T_SKY
        call    SetTile
        call    AddCoin
        push    bx
        push    dx
        push    200
        call    SpawnPopup
        jmp near     .nxt
.pole:  cmp     ax, T_POLE
        jne     .nxt
        cmp     byte [flag_hit], 0
        jne     .nxt
        mov     byte [flag_hit], 1
        mov     ax, [hero_y]
        dec     ax
        sar     ax, 4
        mov     [flag_row], ax
.nxt:   inc     di
        cmp     di, 3
        jae     $+5
        jmp near     near .yl
        inc     si
        cmp     si, 2
        jae     $+5
        jmp near     near .xl
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              HurtHero
; Purpose:           Handle enemy damage: Super shrinks to Small (2 s
;                    invulnerability); Small sets dead_pending.
; Inputs:            None
; Outputs:           Updates hero_form/hp/invuln or dead_pending
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
HurtHero:
        PROLOG
        cmp     byte [hero_invuln], 0
        jne     .d
        cmp     byte [hero_form], 0
        je      .die
        push    0
        call    SetForm
        mov     byte [hero_invuln], INVULN_FRAMES
        jmp near     .d
.die:   mov     byte [dead_pending], 1
.d:     EPILOG  0

; ---------------------------------------------------------------------
; ---------- MEMBER 2 ----------
;  Module 11 : enemies, shells (Section 5.5, 5.6)
; ---------------------------------------------------------------------
; Name:              MoveEntity
; Purpose:           Move an enemy, shell, or mushroom horizontally (bounce
;                    at walls) and vertically with gravity.
; Inputs:            [bp+6] = entity record addr, [bp+4] = 8.8 horizontal speed
; Outputs:           AX = 1 if entity fell below the map, else 0
; Registers changed: AX (all others preserved)
; ---------------------------------------------------------------------
MoveEntity:
        PROLOG
        mov     si, [bp+6]
        mov     ax, [bp+4]
        test    ax, ax
        jnz     $+5
        jmp near     near .vert
        cmp     byte [si+E_DIR], 0
        jge     .dirok
        neg     ax
.dirok: mov     bx, ax
        sar     bx, 8
        add     [si+E_XF], al
        adc     [si+E_X], bx
        mov     dx, [si+E_X]
        cmp     byte [si+E_DIR], 0
        jl      .lead
        add     dx, 15                  ; leading edge = right side
.lead:  push    dx
        mov     ax, [si+E_Y]
        add     ax, 8
        push    ax
        call    IsSolid
        test    ax, ax
        jnz     .wall
        push    dx
        mov     ax, [si+E_Y]
        add     ax, 15
        push    ax
        call    IsSolid
        test    ax, ax
        jz      .vert
.wall:  mov     ax, [si+E_X]
        cmp     byte [si+E_DIR], 0
        jl      .wl
        add     ax, 15
        and     ax, 0FFF0h
        sub     ax, 16
        jmp near     .ws
.wl:    and     ax, 0FFF0h
        add     ax, 16
.ws:    mov     [si+E_X], ax
        mov     byte [si+E_XF], 0
        neg     byte [si+E_DIR]         ; turn around
.vert:  xor     bx, bx                  ; ground under the feet?
        mov     ax, [si+E_X]
        add     ax, 3
        push    ax
        mov     ax, [si+E_Y]
        add     ax, 16
        push    ax
        call    IsSolid
        or      bx, ax
        mov     ax, [si+E_X]
        add     ax, 12
        push    ax
        mov     ax, [si+E_Y]
        add     ax, 16
        push    ax
        call    IsSolid
        or      bx, ax
        test    bx, bx
        jz      .fall
        mov     word [si+E_VY], 0
        mov     byte [si+E_YF], 0
        jmp near     .chk
.fall:  mov     ax, [si+E_VY]
        add     ax, GRAVITY
        cmp     ax, MAX_FALL
        jle     .gs
        mov     ax, MAX_FALL
.gs:    mov     [si+E_VY], ax
        mov     bx, ax
        sar     bx, 8
        add     [si+E_YF], al
        adc     [si+E_Y], bx
        mov     ax, [si+E_X]            ; landed?
        add     ax, 3
        push    ax
        mov     ax, [si+E_Y]
        add     ax, 15
        push    ax
        call    IsSolid
        mov     bx, ax
        mov     ax, [si+E_X]
        add     ax, 12
        push    ax
        mov     ax, [si+E_Y]
        add     ax, 15
        push    ax
        call    IsSolid
        or      bx, ax
        test    bx, bx
        jz      .chk
        mov     ax, [si+E_Y]
        add     ax, 15
        and     ax, 0FFF0h
        sub     ax, 16
        mov     [si+E_Y], ax
        mov     word [si+E_VY], 0
        mov     byte [si+E_YF], 0
.chk:   xor     dx, dx
        cmp     word [si+E_Y], MAP_PIX_H
        jl      .out
        mov     dx, 1
.out:   RESULT  dx
        EPILOG  4

; ---------------------------------------------------------------------
; Name:              EnemyInteract
; Purpose:           Handle enemy-to-enemy collisions: sliding shells kill
;                    enemies (+500); walking enemies turn around.
; Inputs:            [bp+4] = enemy record addr
; Outputs:           Updates enemy records, score, and spawns pop-ups
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
EnemyInteract:
        PROLOG
        mov     si, [bp+4]
        mov     di, enemies
        mov     cx, ENEMY_MAX
.l:     cmp     di, si
        jne     $+5
        jmp near     near .n
        cmp     byte [di+E_TYPE], 0
        jne     $+5
        jmp near     near .n
        mov     al, [di+E_STATE]
        cmp     al, S_WALK
        jae     $+5
        jmp near     near .n
        cmp     al, S_FLAT
        jne     $+5
        jmp near     near .n
        mov     ax, [si+E_X]            ; |dx| < 16 ?
        sub     ax, [di+E_X]
        mov     bx, ax
        sar     bx, 15
        xor     ax, bx
        sub     ax, bx
        cmp     ax, 16
        jl      $+5
        jmp near     near .n
        mov     ax, [si+E_Y]            ; |dy| < 16 ?
        sub     ax, [di+E_Y]
        mov     bx, ax
        sar     bx, 15
        xor     ax, bx
        sub     ax, bx
        cmp     ax, 16
        jl      $+5
        jmp near     near .n
        cmp     byte [si+E_STATE], S_SLIDE
        jne     .turn
        mov     byte [di+E_TYPE], 0     ; shell kill
        push    500
        call    AddScore
        push    word [di+E_X]
        push    word [di+E_Y]
        push    500
        call    SpawnPopup
        jmp near     .n
.turn:  cmp     byte [si+E_STATE], S_WALK
        jne     .n
        cmp     byte [di+E_STATE], S_SLIDE
        je      .n
        mov     ax, [di+E_X]
        sub     ax, [si+E_X]
        cmp     byte [si+E_DIR], 0
        jl      .lft
        test    ax, ax                  ; heading right: other on the right?
        jle     .n
        jmp near     .flip
.lft:   test    ax, ax
        jge     .n
.flip:  neg     byte [si+E_DIR]
.n:     add     di, E_SIZE
        LOOPN   .l
        EPILOG  2

; ---------------------------------------------------------------------
; Name:              UpdateEnemy
; Purpose:           Update one active enemy (flat timer, grace timer,
;                    movement, Koopa platform-edge turning, interactions).
; Inputs:            [bp+4] = enemy record addr
; Outputs:           AX = 1 if enemy should be removed, else 0
; Registers changed: AX (all others preserved)
; ---------------------------------------------------------------------
UpdateEnemy:
        PROLOG
        mov     si, [bp+4]
        xor     dx, dx
        mov     al, [si+E_STATE]
        cmp     al, S_FLAT
        jne     .notflat
        dec     word [si+E_TIMER]       ; flattened Goomba, about 1 s
        jnz     .fp
        mov     dx, 1
        jmp near     .done
.fp:    push    si
        push    0
        call    MoveEntity
        jmp near     .done
.notflat:
        cmp     word [si+E_TIMER], 0    ; kick grace time
        je      .ng
        dec     word [si+E_TIMER]
.ng:    xor     bx, bx
        cmp     al, S_SHELL
        je      .go
        mov     bx, SHELL_SPD
        cmp     al, S_SLIDE
        je      .go
        mov     bx, GOOMBA_SPD
        cmp     byte [si+E_TYPE], T_GOOMBA
        je      .go
        mov     bx, KOOPA_SPD
.go:    push    si
        push    bx
        call    MoveEntity
        mov     dx, ax
        test    dx, dx
        jz      $+5
        jmp near     near .done
        cmp     byte [si+E_TYPE], T_KOOPA   ; Koopa turns at platform edges
        je      $+5
        jmp near     near .inter
        cmp     byte [si+E_STATE], S_WALK
        je      $+5
        jmp near     near .inter
        mov     ax, [si+E_X]
        add     ax, 8
        push    ax
        mov     ax, [si+E_Y]
        add     ax, 16
        push    ax
        call    IsSolid
        test    ax, ax
        jz      .inter                  ; in the air: no edge test
        mov     ax, [si+E_X]
        cmp     byte [si+E_DIR], 0
        jl      .ll
        add     ax, 15
.ll:    push    ax
        mov     ax, [si+E_Y]
        add     ax, 16
        push    ax
        call    IsSolid
        test    ax, ax
        jnz     .inter
        neg     byte [si+E_DIR]
        mov     al, [si+E_DIR]
        cbw
        add     [si+E_X], ax
.inter: push    si
        call    EnemyInteract
.done:  RESULT  dx
        EPILOG  2

; ---------------------------------------------------------------------
; Name:              UpdateEnemies
; Purpose:           Walk enemy table: activate within 1 tile of screen,
;                    update active enemies, and remove off-screen ones.
; Inputs:            None
; Outputs:           Updates enemies table
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
UpdateEnemies:
        PROLOG
        mov     si, enemies
        mov     cx, ENEMY_MAX
.l:     cmp     byte [si+E_TYPE], 0
        je      .n
        mov     ax, [si+E_X]
        sub     ax, [camera_x]          ; screen x
        cmp     ax, -32
        jl      .remove                 ; left behind
        cmp     byte [si+E_STATE], S_WAIT
        jne     .active
        cmp     ax, SCREEN_W+16         ; within one tile of the screen?
        jge     .n
        mov     byte [si+E_STATE], S_WALK
        jmp near     .n
.active:
        push    si
        call    UpdateEnemy
        test    ax, ax
        jz      .n
.remove:
        mov     byte [si+E_TYPE], 0
.n:     add     si, E_SIZE
        LOOPN   .l
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              StompScore
; Purpose:           Award stomp-chain points (or 1-UP on 11th+) and advance
;                    hero_chain.
; Inputs:            [bp+4] = enemy record addr (for pop-up position)
; Outputs:           Updates score/lives, hero_chain, and spawns pop-up
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
StompScore:
        PROLOG
        mov     si, [bp+4]
        xor     bh, bh
        mov     bl, [hero_chain]
        cmp     bx, 10
        jae     .oneup
        shl     bx, 1
        mov     dx, [stomp_table+bx]
        push    dx
        call    AddScore
        push    word [si+E_X]
        push    word [si+E_Y]
        push    dx
        call    SpawnPopup
        jmp near     .inc
.oneup: call    AddLife
.inc:   cmp     byte [hero_chain], 250
        jae     .d
        inc     byte [hero_chain]
.d:     EPILOG  2

; ---------------------------------------------------------------------
; Name:              ResolveEnemies
; Purpose:           Check Mario against active enemies for stomp, shell
;                    kick, or damage.
; Inputs:            None
; Outputs:           Updates enemy states, score, hero bounce/damage
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
ResolveEnemies:
        PROLOG
        mov     si, enemies
        mov     cx, ENEMY_MAX
.l:     cmp     byte [si+E_TYPE], 0
        jne     $+5
        jmp near     near .n
        mov     al, [si+E_STATE]
        cmp     al, S_WALK
        jae     $+5
        jmp near     near .n
        cmp     al, S_FLAT
        jne     $+5
        jmp near     near .n
        cmp     word [si+E_TIMER], 0    ; grace time: ignore Mario
        je      $+5
        jmp near     near .n
        HEROBOX
        push    word [si+E_X]
        push    word [si+E_Y]
        push    16
        push    16
        call    RectOverlap
        test    ax, ax
        jnz     $+5
        jmp near     near .n
        push    word [si+E_Y]
        call    StompTest
        mov     dx, ax                  ; dx = 1 for a stomp
        cmp     byte [si+E_STATE], S_SHELL
        jne     $+5
        jmp near     near .idle
        test    dx, dx
        jz      .hurt
        cmp     byte [si+E_TYPE], T_GOOMBA
        jne     .toshell
        mov     byte [si+E_STATE], S_FLAT
        mov     word [si+E_TIMER], FLAT_FRAMES
        jmp near     .score
.toshell:
        mov     byte [si+E_STATE], S_SHELL
        mov     word [si+E_TIMER], KICK_GRACE
.score: push    si
        call    StompScore
        call    Bounce
        jmp near     .n
.hurt:  call    HurtHero
        jmp near     .n
.idle:  push    400                     ; stationary shell: kick
        call    AddScore
        push    word [si+E_X]
        push    word [si+E_Y]
        push    400
        call    SpawnPopup
        mov     byte [si+E_STATE], S_SLIDE
        mov     word [si+E_TIMER], KICK_GRACE
        mov     ax, [hero_x]
        add     ax, 8
        mov     bx, [si+E_X]
        add     bx, 8
        mov     byte [si+E_DIR], 1      ; slide away from Mario
        cmp     bx, ax
        jge     .kd
        mov     byte [si+E_DIR], 0FFh
.kd:    test    dx, dx
        jz      .n
        call    Bounce
.n:     add     si, E_SIZE
        LOOPN   .l
        EPILOG  0

; ---------------------------------------------------------------------
;  Module 12 : blocks, coins, mushroom, effects
; ---------------------------------------------------------------------
; Name:              HitBlock
; Purpose:           Trigger brick (Super breaks +50), "?" coin (+200), or
;                    "?" mushroom block when hit from below.
; Inputs:            [bp+6]=col, [bp+4]=row
; Outputs:           Updates level_work, score, coins, and spawns items/fx
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
HitBlock:
        PROLOG
        mov     bx, [bp+4]              ; row
        cmp     bx, 1
        jae     $+5
        jmp near     near .d
        cmp     bx, MAP_H
        jb      $+5
        jmp near     near .d
        mov     ax, [bp+6]              ; col
        cmp     ax, MAP_W
        jb      $+5
        jmp near     near .d
        imul    si, bx, MAP_W
        add     si, ax
        mov     al, [level_work+si]
        cmp     al, T_BRICK
        je      .brick
        cmp     al, T_QCOIN
        jne     $+5
        jmp near     near .qcoin
        cmp     al, T_QMUSH
        jne     $+5
        jmp near     near .qmush
        jmp near     .d
.brick: cmp     byte [hero_form], 0     ; Small Mario: nothing happens
        jne     $+5
        jmp near     near .d
        mov     byte [level_work+si], T_SKY
        push    50
        call    AddScore
        mov     ax, [bp+6]
        shl     ax, 4
        mov     dx, [bp+4]
        shl     dx, 4
        push    ax
        push    dx
        call    SpawnDebris
        push    ax
        push    dx
        push    50
        call    SpawnPopup
        jmp near     .d
.qcoin: mov     byte [level_work+si], T_EMPTY
        call    AddCoin
        mov     ax, [bp+6]
        shl     ax, 4
        mov     dx, [bp+4]
        shl     dx, 4
        sub     dx, 16
        push    ax
        push    dx
        call    SpawnCoinFx
        push    ax
        push    dx
        push    200
        call    SpawnPopup
        jmp near     .d
.qmush: mov     byte [level_work+si], T_EMPTY
        mov     ax, [bp+6]
        shl     ax, 4
        mov     dx, [bp+4]
        shl     dx, 4
        push    ax
        push    dx
        call    SpawnMushroom
.d:     EPILOG  4

; ---------------------------------------------------------------------
; Name:              SpawnMushroom
; Purpose:           Allocate a mushroom item emerging from block at (x, y).
; Inputs:            [bp+6]=x, [bp+4]=y
; Outputs:           Initializes a free slot in items
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
SpawnMushroom:
        PROLOG
        mov     si, items
        mov     cx, ITEM_MAX
.l:     cmp     byte [si+E_TYPE], 0
        je      .free
        add     si, E_SIZE
        loop    .l
        jmp near     .d
.free:  mov     byte [si+E_TYPE], 1
        mov     byte [si+E_STATE], 0    ; emerging
        mov     ax, [bp+6]
        mov     [si+E_X], ax
        mov     ax, [bp+4]
        mov     [si+E_Y], ax
        mov     byte [si+E_XF], 0
        mov     byte [si+E_YF], 0
        mov     byte [si+E_DIR], 1
        mov     word [si+E_VY], 0
        mov     word [si+E_TIMER], 16
.d:     EPILOG  4

; ---------------------------------------------------------------------
; Name:              UpdateItems
; Purpose:           Update mushroom emergence, movement, gravity, and
;                    off-screen/pit removal.
; Inputs:            None
; Outputs:           Updates items table
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
UpdateItems:
        PROLOG
        mov     si, items
        mov     cx, ITEM_MAX
.l:     cmp     byte [si+E_TYPE], 0
        jne     $+5
        jmp near     near .n
        cmp     byte [si+E_STATE], 0
        jne     .move
        dec     word [si+E_Y]
        dec     word [si+E_TIMER]
        jnz     .n
        mov     byte [si+E_STATE], 1
        jmp near     .n
.move:  mov     ax, [si+E_X]
        sub     ax, [camera_x]
        cmp     ax, -32
        jl      .gone
        push    si
        push    MUSH_SPD
        call    MoveEntity
        test    ax, ax
        jz      .n
.gone:  mov     byte [si+E_TYPE], 0
.n:     add     si, E_SIZE
        LOOPN   .l
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              ResolveItems
; Purpose:           Check Mario overlap with mushrooms (+1000, Small->Super).
; Inputs:            None
; Outputs:           Removes collected mushroom, updates score and hero form
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
ResolveItems:
        PROLOG
        mov     si, items
        mov     cx, ITEM_MAX
.l:     cmp     byte [si+E_TYPE], 0
        jne     $+5
        jmp near     near .n
        HEROBOX
        push    word [si+E_X]
        push    word [si+E_Y]
        push    16
        push    16
        call    RectOverlap
        test    ax, ax
        jz      .n
        mov     byte [si+E_TYPE], 0
        push    1000
        call    AddScore
        push    word [si+E_X]
        push    word [si+E_Y]
        push    1000
        call    SpawnPopup
        cmp     byte [hero_form], 0
        jne     .n                      ; already Super: points only
        push    1
        call    SetForm
.n:     add     si, E_SIZE
        LOOPN   .l
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              AllocFx
; Purpose:           Find an unused slot in fx_table.
; Inputs:            None
; Outputs:           AX = address of free slot, or 0 if table is full
; Registers changed: AX (all others preserved)
; ---------------------------------------------------------------------
AllocFx:
        PROLOG
        mov     si, fx_table
        mov     cx, FX_MAX
        xor     dx, dx
.l:     cmp     byte [si+F_KIND], 0
        je      .free
        add     si, FX_SIZE
        loop    .l
        jmp near     .d
.free:  mov     dx, si
.d:     RESULT  dx
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              SpawnCoinFx
; Purpose:           Spawn a bouncing coin visual effect above a "?" block.
; Inputs:            [bp+6]=x, [bp+4]=y
; Outputs:           Populates one fx_table entry
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
SpawnCoinFx:
        PROLOG
        call    AllocFx
        test    ax, ax
        jz      .d
        mov     si, ax
        mov     byte [si+F_KIND], FX_COIN
        mov     byte [si+F_TIMER], 24
        mov     ax, [bp+6]
        mov     [si+F_X], ax
        mov     ax, [bp+4]
        shl     ax, 8
        mov     [si+F_Y], ax
        mov     word [si+F_VY], 0FC00h
        mov     word [si+F_VX], 0
.d:     EPILOG  4

; ---------------------------------------------------------------------
; Name:              SpawnPopup
; Purpose:           Spawn a floating score pop-up at (x, y).
; Inputs:            [bp+8]=x, [bp+6]=y, [bp+4]=point value
; Outputs:           Populates one fx_table entry
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
SpawnPopup:
        PROLOG
        call    AllocFx
        test    ax, ax
        jnz     $+5
        jmp near     near .d
        mov     si, ax
        mov     byte [si+F_KIND], FX_POPUP
        mov     byte [si+F_TIMER], 30
        mov     ax, [bp+8]
        mov     [si+F_X], ax
        mov     ax, [bp+6]
        sub     ax, 8
        shl     ax, 8
        mov     [si+F_Y], ax
        mov     word [si+F_VY], 0FF00h
        mov     word [si+F_VX], 0
        mov     ax, [bp+4]
        mov     [si+F_VAL], ax
.d:     EPILOG  6

; ---------------------------------------------------------------------
; Name:              SpawnDebris
; Purpose:           Spawn four flying brick debris pieces at (x, y).
; Inputs:            [bp+6]=x, [bp+4]=y
; Outputs:           Populates up to 4 fx_table entries
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
SpawnDebris:
        PROLOG
        xor     di, di
.l:     call    AllocFx
        test    ax, ax
        jnz     $+5
        jmp near     near .d
        mov     si, ax
        mov     byte [si+F_KIND], FX_DEBRIS
        mov     byte [si+F_TIMER], 40
        mov     ax, [bp+6]
        add     ax, 4
        mov     [si+F_X], ax
        mov     ax, [bp+4]
        add     ax, 4
        shl     ax, 8
        mov     [si+F_Y], ax
        mov     bx, di
        shl     bx, 1
        mov     ax, [debris_vx+bx]
        mov     [si+F_VX], ax
        mov     ax, [debris_vy+bx]
        mov     [si+F_VY], ax
        inc     di
        cmp     di, 4
        jae     $+5
        jmp near     near .l
.d:     EPILOG  4

; ---------------------------------------------------------------------
; Name:              UpdateFx
; Purpose:           Move and age active visual effects in fx_table.
; Inputs:            None
; Outputs:           Updates fx_table positions and timers
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
UpdateFx:
        PROLOG
        mov     si, fx_table
        mov     cx, FX_MAX
.l:     cmp     byte [si+F_KIND], 0
        je      .n
        dec     byte [si+F_TIMER]
        jnz     .mv
        mov     byte [si+F_KIND], 0
        jmp near     .n
.mv:    mov     ax, [si+F_VY]
        add     [si+F_Y], ax
        cmp     byte [si+F_KIND], FX_POPUP
        je      .nog
        add     word [si+F_VY], GRAVITY
.nog:   mov     ax, [si+F_VX]
        add     [si+F_X], ax
.n:     add     si, FX_SIZE
        LOOPN   .l
        EPILOG  0

; ---------------------------------------------------------------------
;  Module 13 : score, health, lives, HUD (Section 5.4, 5.14)
; ---------------------------------------------------------------------
; Name:              AddScore
; Purpose:           Add points to the 32-bit score (ADD/ADC), clamped to
;                    999,999 (000F423Fh).
; Inputs:            [bp+4] = points to add (unsigned word)
; Outputs:           Updates score_lo, score_hi
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
AddScore:
        PROLOG
        mov     ax, [bp+4]
        add     [score_lo], ax
        adc     word [score_hi], 0
        cmp     word [score_hi], 0Fh
        jb      .ok
        ja      .clamp
        cmp     word [score_lo], 423Fh
        jbe     .ok
.clamp: mov     word [score_hi], 0Fh
        mov     word [score_lo], 423Fh  ; 999999 = 000F423Fh
.ok:    EPILOG  2

; ---------------------------------------------------------------------
; Name:              AddLife
; Purpose:           Increment lives by 1, clamped to MAX_LIVES (99).
; Inputs:            None
; Outputs:           Updates lives
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
AddLife:
        PROLOG
        cmp     word [lives], MAX_LIVES
        jae     .d
        inc     word [lives]
.d:     EPILOG  0

; ---------------------------------------------------------------------
; Name:              AddCoin
; Purpose:           Award +200 points and +1 coin; every 100 coins grants
;                    an extra life and resets coins to 0.
; Inputs:            None
; Outputs:           Updates score, coins, lives
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
AddCoin:
        PROLOG
        push    200
        call    AddScore
        inc     word [coins]
        cmp     word [coins], 100
        jb      .d
        mov     word [coins], 0
        call    AddLife
.d:     EPILOG  0

; ---------------------------------------------------------------------
; Name:              UpdateClock
; Purpose:           Count down time_left at 1 unit per 30 timer ticks and
;                    decrement hero_invuln each frame.
; Inputs:            None
; Outputs:           Updates sec_acc, time_left, hero_invuln
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
UpdateClock:
        PROLOG
        mov     ax, [tick_delta]
        add     [sec_acc], ax
.l:     cmp     word [sec_acc], TICKS_PER_SEC
        jb      .inv
        sub     word [sec_acc], TICKS_PER_SEC
        cmp     word [time_left], 0
        je      .l
        dec     word [time_left]
        jmp near     .l
.inv:   cmp     byte [hero_invuln], 0
        je      .d
        dec     byte [hero_invuln]
.d:     EPILOG  0

; ---------------------------------------------------------------------
; Name:              DebugKeys
; Purpose:           Handle test/debug keys listed in README:
;                    F1 -> time=5, F2 -> coins=99, F3 -> become Super.
; Inputs:            None
; Outputs:           Updates time_left, coins, or hero form
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DebugKeys:
        PROLOG
        push    SC_F1
        call    KeyPressed
        test    ax, ax
        jz      .f2
        mov     word [time_left], 5
.f2:    push    SC_F2
        call    KeyPressed
        test    ax, ax
        jz      .f3
        mov     word [coins], 99
.f3:    push    SC_F3
        call    KeyPressed
        test    ax, ax
        jz      .d
        push    1
        call    SetForm
.d:     EPILOG  0

; ---------- MEMBER 1 ----------
; ---------------------------------------------------------------------
; Name:              DrawHUD
; Purpose:           Draw the top 16-pixel HUD strip (SCORE, COINS, WORLD,
;                    TIME with <100 hurry blink, LIVES, and HEALTH hearts).
; Inputs:            None
; Outputs:           HUD drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawHUD:
        PROLOG
        push    0
        push    0
        push    SCREEN_W
        push    16
        push    C_BLACK
        call    FillRect
        DRAWTEXT 4,   0, txt_score, C_YELLOW, 1
        DRAWTEXT 72,  0, txt_coins, C_YELLOW, 1
        DRAWTEXT 124, 0, txt_world, C_YELLOW, 1
        DRAWTEXT 180, 0, txt_time,  C_YELLOW, 1
        DRAWTEXT 224, 0, txt_lives, C_YELLOW, 1
        DRAWTEXT 272, 0, txt_health, C_YELLOW, 1
        DRAWNUM  4,   8, word [score_lo], word [score_hi], 6, C_WHITE, 1
        DRAWTEXT 72,  8, txt_x, C_WHITE, 1
        DRAWNUM  80,  8, word [coins], 0, 2, C_WHITE, 1
        DRAWTEXT 124, 8, txt_w11, C_WHITE, 1
        mov     ax, C_WHITE
        cmp     word [time_left], 100   ; "hurry" blink below 100
        jae     .tc
        test    byte [frame_ctr], 8
        jz      .tc
        mov     ax, C_LTRED
.tc:    DRAWNUM  180, 8, word [time_left], 0, 3, ax, 1
        DRAWTEXT 224, 8, txt_x, C_WHITE, 1
        DRAWNUM  232, 8, word [lives], 0, 2, C_WHITE, 1
        push    272                     ; heart 1: always filled
        push    8
        push    heart_bmp
        push    C_LTRED
        push    1
        call    DrawGlyph
        mov     ax, C_GREY              ; heart 2: filled only for Super
        cmp     byte [hero_hp], 2
        jb      .h2
        mov     ax, C_LTRED
.h2:    push    284
        push    8
        push    heart_bmp
        push    ax
        push    1
        call    DrawGlyph
        EPILOG  0

; ---------------------------------------------------------------------
;  Scene drawing (frame order step 9)
; ---------------------------------------------------------------------
; Name:              DrawHero
; Purpose:           Select Mario's sprite by form/pose/facing and draw it
;                    with invulnerability blinking.
; Inputs:            None
; Outputs:           Hero sprite drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawHero:
        PROLOG
        cmp     byte [hero_hidden], 0
        je      $+5
        jmp near     near .d
        cmp     byte [hero_invuln], 0
        je      .show
        test    byte [frame_ctr], 1     ; blink: every other frame
        jz      $+5
        jmp near     near .d
.show:  xor     bx, bx                  ; pose 0 stand
        cmp     byte [hero_pose_ovr], 0FFh
        je      .auto
        mov     bl, [hero_pose_ovr]
        jmp near     .pick
.auto:  cmp     byte [hero_ground], 0
        jne     .gnd
        mov     bx, 2                   ; jump
        jmp near     .pick
.gnd:   cmp     word [hero_vx], 0
        je      .pick
        test    byte [hero_anim], 4     ; alternate stand / run
        jz      .pick
        mov     bx, 1
.pick:  xor     ax, ax
        mov     al, [hero_form]
        mov     cx, ax
        shl     ax, 1
        add     ax, cx                  ; form*3
        add     bx, ax
        shl     bx, 1
        mov     si, [hero_spr_tab+bx]
        xor     dx, dx                  ; flags
        cmp     byte [hero_face], 0
        je      .nm
        or      dx, FLAG_MIRROR
.nm:    cmp     byte [hero_form], 0
        je      .nt
        or      dx, FLAG_TALL
.nt:    mov     ax, [hero_x]
        sub     ax, [camera_x]
        push    ax
        mov     ax, [hero_y]
        sub     ax, [hero_h]
        push    ax
        push    si
        push    dx
        call    DrawSprite
.d:     EPILOG  0

; ---------------------------------------------------------------------
; Name:              DrawEnemies
; Purpose:           Draw all visible Goombas, Koopas, and shells.
; Inputs:            None
; Outputs:           Enemy sprites drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawEnemies:
        PROLOG
        mov     si, enemies
        mov     cx, ENEMY_MAX
.l:     cmp     byte [si+E_TYPE], 0
        jne     $+5
        jmp near     near .n
        mov     ax, [si+E_X]
        sub     ax, [camera_x]
        cmp     ax, -16
        jg      $+5
        jmp near     near .n
        cmp     ax, SCREEN_W
        jl      $+5
        jmp near     near .n
        mov     bx, spr_goomba
        xor     dx, dx
        cmp     byte [si+E_TYPE], T_GOOMBA
        jne     .koopa
        cmp     byte [si+E_STATE], S_FLAT
        jne     .gw
        mov     bx, spr_goomba_flat
        jmp near     .draw
.gw:    test    byte [frame_ctr], 8     ; walking animation
        jz      .draw
        mov     dx, FLAG_MIRROR
        jmp near     .draw
.koopa: cmp     byte [si+E_STATE], S_SHELL
        jae     .shell
        mov     bx, spr_koopa
        cmp     byte [si+E_DIR], 0
        jl      .draw
        mov     dx, FLAG_MIRROR
        jmp near     .draw
.shell: mov     bx, spr_shell
.draw:  push    ax
        push    word [si+E_Y]
        push    bx
        push    dx
        call    DrawSprite
.n:     add     si, E_SIZE
        LOOPN   .l
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              DrawItems
; Purpose:           Draw active mushrooms in items table.
; Inputs:            None
; Outputs:           Item sprites drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawItems:
        PROLOG
        mov     si, items
        mov     cx, ITEM_MAX
.l:     cmp     byte [si+E_TYPE], 0
        je      .n
        mov     ax, [si+E_X]
        sub     ax, [camera_x]
        push    ax
        push    word [si+E_Y]
        push    spr_mushroom
        push    0
        call    DrawSprite
.n:     add     si, E_SIZE
        loop    .l
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              DrawFx
; Purpose:           Draw active coins, brick debris, and score pop-ups.
; Inputs:            None
; Outputs:           Effects drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawFx:
        PROLOG
        mov     si, fx_table
        mov     cx, FX_MAX
.l:     mov     al, [si+F_KIND]
        test    al, al
        jnz     $+5
        jmp near     near .n
        mov     bx, [si+F_X]
        sub     bx, [camera_x]
        xor     dx, dx
        mov     dl, [si+F_Y+1]          ; whole pixels of the 8.8 value
        cmp     al, FX_COIN
        jne     $+5
        jmp near     near .coin
        cmp     al, FX_DEBRIS
        jne     $+5
        jmp near     near .deb
        mov     ax, [si+F_VAL]          ; pop-up: number of digits
        mov     di, 1
        cmp     ax, 10
        jb      .dg
        inc     di
        cmp     ax, 100
        jb      .dg
        inc     di
        cmp     ax, 1000
        jb      .dg
        inc     di
        cmp     ax, 10000
        jb      .dg
        inc     di
.dg:    DRAWNUM bx, dx, word [si+F_VAL], 0, di, C_WHITE, 1
        jmp near     .n
.coin:  push    bx
        push    dx
        push    spr_coin
        push    0
        call    DrawSprite
        jmp near     .n
.deb:   push    bx
        push    dx
        push    5
        push    5
        push    C_BRICK
        call    FillRect
.n:     add     si, FX_SIZE
        LOOPN   .l
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              DrawFlag
; Purpose:           Draw the flag cloth at the top of the flag pole.
; Inputs:            None
; Outputs:           Flag sprite drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawFlag:
        PROLOG
        mov     ax, POLE_X+7-15
        sub     ax, [camera_x]
        push    ax
        push    40
        push    spr_flag
        push    0
        call    DrawSprite
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              DrawScene
; Purpose:           Clear buffer and render items, map, flag, enemies,
;                    hero, effects, and HUD.
; Inputs:            None
; Outputs:           Complete frame rendered into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawScene:
        PROLOG
        call    ClearBuffer
        call    DrawItems               ; behind the tiles (mushroom emerges)
        call    DrawMap
        call    DrawFlag
        call    DrawEnemies
        call    DrawHero
        call    DrawFx
        call    DrawHUD
        EPILOG  0

; ---------- MEMBER 2 ----------
; ---------------------------------------------------------------------
;  Module 15 : reset, new game, death, win
; ---------------------------------------------------------------------
; Name:              ResetLevel
; Purpose:           Restore working map, enemies, items, effects, clock,
;                    camera, and Mario to start of level (keeps score/coins/lives).
; Inputs:            None
; Outputs:           Level state reset
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
ResetLevel:
        PROLOGE
        mov     ax, ds
        mov     es, ax
        call    ResetMap
        cld
        mov     si, enemy_init
        mov     di, enemies
        mov     cx, ENEMY_MAX*E_SIZE
        rep     movsb
        mov     di, items
        mov     cx, ITEM_MAX*E_SIZE
        xor     al, al
        rep     stosb
        mov     di, fx_table
        mov     cx, FX_MAX*FX_SIZE
        rep     stosb
        mov     word [time_left], LEVEL_TIME
        mov     word [sec_acc], 0
        mov     word [camera_x], 0
        mov     word [hero_x], START_X
        mov     byte [hero_xf], 0
        mov     word [hero_y], GROUND_Y
        mov     byte [hero_yf], 0
        mov     word [hero_vx], 0
        mov     word [hero_vy], 0
        mov     byte [hero_face], 0
        mov     byte [hero_ground], 1
        mov     byte [hero_latch], 1    ; must release Space before jumping
        mov     byte [hero_invuln], 0
        mov     byte [hero_chain], 0
        mov     byte [hero_hidden], 0
        mov     byte [hero_pose_ovr], 0FFh
        mov     byte [dead_pending], 0
        mov     byte [flag_hit], 0
        mov     word [hero_anim], 0
        mov     word [hero_prev_y], GROUND_Y
        push    0
        call    SetForm
        EPILOGE 0

; ---------------------------------------------------------------------
; Name:              NewGame
; Purpose:           Reset score, coins, lives to 3, and reset the level.
; Inputs:            None
; Outputs:           Full new-game state initialized
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
NewGame:
        PROLOG
        mov     word [score_lo], 0
        mov     word [score_hi], 0
        mov     word [coins], 0
        mov     word [lives], START_LIVES
        call    ResetLevel
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              StartDeath
; Purpose:           Freeze gameplay and enter ST_DYING (skip upward hop
;                    when dying in a pit).
; Inputs:            [bp+4] = pit flag (1 = pit death, 0 = normal death)
; Outputs:           Updates hero velocity/pose and sets state to ST_DYING
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
StartDeath:
        PROLOG
        mov     word [hero_vy], 0
        cmp     word [bp+4], 0
        jne     .p
        mov     word [hero_vy], DEATH_HOP
.p:     mov     byte [hero_yf], 0
        mov     word [hero_vx], 0
        mov     byte [hero_pose_ovr], 2 ; jumping pose
        mov     byte [hero_invuln], 0
        SETSTATE ST_DYING
        EPILOG  2

; ---------------------------------------------------------------------
; Name:              StartWin
; Purpose:           Award flag-pole height points, snap Mario to the pole,
;                    and enter ST_WIN.
; Inputs:            None (reads flag_row)
; Outputs:           Updates score, hero position/pose, win_phase, state
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
StartWin:
        PROLOG
        mov     ax, [flag_row]
        mov     dx, 100
        cmp     ax, 8
        jge     .pts
        mov     dx, 400
        cmp     ax, 6
        jge     .pts
        mov     dx, 800
        cmp     ax, 5
        jge     .pts
        mov     dx, 2000
        cmp     ax, 4
        jge     .pts
        mov     dx, 5000
.pts:   push    dx
        call    AddScore
        push    POLE_X
        push    word [hero_y]
        push    dx
        call    SpawnPopup
        mov     word [hero_x], POLE_X-6
        mov     word [hero_vx], 0
        mov     word [hero_vy], 0
        mov     byte [hero_pose_ovr], 2
        mov     byte [win_phase], 0
        SETSTATE ST_WIN
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              CheckEnd
; Purpose:           Check win (flag_hit) and death conditions (pit,
;                    enemy damage, or time_left == 0).
; Inputs:            None
; Outputs:           Transitions to ST_WIN or ST_DYING if triggered
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
CheckEnd:
        PROLOG
        cmp     byte [flag_hit], 0
        jne     .win
        mov     ax, [hero_y]
        sub     ax, [hero_h]
        cmp     ax, MAP_PIX_H           ; top of Mario below the map = pit
        jge     .pit
        cmp     byte [dead_pending], 0
        jne     .die
        cmp     word [time_left], 0
        je      .die
        jmp near     .d
.win:   call    StartWin
        jmp near     .d
.pit:   push    1
        call    StartDeath
        jmp near     .d
.die:   push    0
        call    StartDeath
.d:     EPILOG  0

; ---------------------------------------------------------------------
;  Module 14 : state handlers (jump table state_table)
; ---------------------------------------------------------------------
; Name:              State_Playing
; Purpose:           Execute one frame of PLAYING state (Section 5.13).
; Inputs:            None
; Outputs:           Updates game world, renders scene, and presents frame
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
State_Playing:
        PROLOG
        push    SC_P
        call    KeyPressed
        test    ax, ax
        jz      .nop
        SETSTATE ST_PAUSED
        jmp near     .draw
.nop:   push    SC_ESC
        call    KeyPressed
        test    ax, ax
        jz      .play
        SETSTATE ST_TITLE
        jmp near     .out
.play:  call    DebugKeys
        call    UpdateMario             ; 3
        call    UpdateEnemies           ; 4
        call    UpdateItems
        call    UpdateFx
        call    ResolveEnemies          ; 5
        call    ResolveItems
        call    CollectTiles
        call    UpdateClock             ; 6
        call    CheckEnd                ; 7
        call    UpdateCamera            ; 8
.draw:  call    DrawScene               ; 9
        call    PresentBuffer           ; 10
.out:   EPILOG  0

; ---------------------------------------------------------------------
; Name:              State_Paused
; Purpose:           Handle PAUSED state: freeze updates/clock, show PAUSED
;                    overlay, resume on P, or return to Title on Esc.
; Inputs:            None
; Outputs:           Renders pause overlay or changes state
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
State_Paused:
        PROLOG
        push    SC_P
        call    KeyPressed
        test    ax, ax
        jz      .a
        SETSTATE ST_PLAYING
        jmp near     .draw
.a:     push    SC_ESC
        call    KeyPressed
        test    ax, ax
        jz      .draw
        SETSTATE ST_TITLE
        jmp near     .out
.draw:  call    DrawScene
        push    64
        push    72
        push    192
        push    56
        push    C_WHITE
        push    C_BLACK
        call    DrawBox
        push    88
        push    txt_paused
        push    C_YELLOW
        push    2
        call    DrawTextCentered
        push    110
        push    txt_resume
        push    C_WHITE
        push    1
        call    DrawTextCentered
        call    PresentBuffer
.out:   EPILOG  0

; ---------------------------------------------------------------------
; Name:              State_Dying
; Purpose:           Run death animation (~1.5 s), decrement lives, and
;                    transition to ST_LIFELOST or ST_GAMEOVER.
; Inputs:            None
; Outputs:           Updates hero_y/vy, lives, state
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
State_Dying:
        PROLOG
        mov     ax, [hero_vy]
        mov     bx, ax
        sar     bx, 8
        add     [hero_yf], al
        adc     [hero_y], bx
        add     ax, GRAVITY
        cmp     ax, MAX_FALL
        jle     .g
        mov     ax, MAX_FALL
.g:     mov     [hero_vy], ax
        call    DrawScene
        call    PresentBuffer
        inc     word [state_timer]
        cmp     word [state_timer], DEATH_FRAMES
        jb      .out
        dec     word [lives]
        jnz     .more
        SETSTATE ST_GAMEOVER
        jmp near     .out
.more:  SETSTATE ST_LIFELOST
.out:   EPILOG  0

; ---------------------------------------------------------------------
; Name:              State_LifeLost
; Purpose:           Display the Life-lost screen (~2 s), then reset level
;                    and resume ST_PLAYING.
; Inputs:            None
; Outputs:           Draws Life-lost screen; transitions to ST_PLAYING
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
State_LifeLost:
        PROLOG
        push    0
        push    0
        push    SCREEN_W
        push    SCREEN_H
        push    C_BLACK
        call    FillRect
        push    40
        push    txt_world_big
        push    C_WHITE
        push    3
        call    DrawTextCentered
        push    112
        push    88
        push    spr_small_stand
        push    0
        call    DrawSprite
        DRAWTEXT 148, 92, txt_x, C_WHITE, 3
        DRAWNUM  180, 92, word [lives], 0, 2, C_WHITE, 3
        push    140
        push    txt_liveslft
        push    C_YELLOW
        push    2
        call    DrawTextCentered
        call    PresentBuffer
        inc     word [state_timer]
        cmp     word [state_timer], LIFELOST_FRAMES
        jb      .out
        call    ResetLevel              ; coins and score are kept
        SETSTATE ST_PLAYING
.out:   EPILOG  0

; ---------------------------------------------------------------------
; Name:              State_Win
; Purpose:           Animate Mario sliding down the pole, walking to the
;                    castle, adding time bonus, and entering ST_COMPLETE.
; Inputs:            None
; Outputs:           Updates win_phase, hero position, score, state
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
State_Win:
        PROLOG
        cmp     byte [win_phase], 0
        jne     .p1
        add     word [hero_y], 3        ; slide
        cmp     word [hero_y], BASE_TOP_Y
        jge     $+5
        jmp near     near .draw
        mov     word [hero_y], BASE_TOP_Y
        mov     byte [win_phase], 1
        mov     word [state_timer], 0
        jmp near     .draw
.p1:    cmp     byte [win_phase], 1
        je      $+5
        jmp near     near .p2
        inc     word [state_timer]
        cmp     word [state_timer], 10
        jae     $+5
        jmp near     near .draw
        mov     word [hero_y], GROUND_Y ; step off the base and walk
        mov     word [hero_x], POLE_X+14
        mov     byte [hero_face], 0
        mov     byte [hero_pose_ovr], 0FFh
        mov     byte [hero_ground], 1
        mov     word [hero_vx], WALK_MAX
        mov     byte [win_phase], 2
        jmp near     .draw
.p2:    cmp     byte [win_phase], 2
        jne     .p3
        inc     word [hero_x]
        inc     word [hero_anim]
        cmp     word [hero_x], 58*TILE-8
        jae     $+5
        jmp near     near .draw
        mov     byte [hero_hidden], 1   ; enters the castle door
        mov     byte [win_phase], 3
        mov     word [state_timer], 0
        jmp near     .draw
.p3:    inc     word [state_timer]
        cmp     word [state_timer], 20
        jb      .draw
        mov     ax, [score_lo]          ; Level Complete figures
        mov     [lc_lo], ax
        mov     ax, [score_hi]
        mov     [lc_hi], ax
        mov     ax, [time_left]
        mov     [lc_time], ax
        mov     bx, 50
        mul     bx                      ; time * 50 (fits in 16 bits)
        mov     [lc_bonus], ax
        push    ax
        call    AddScore
        SETSTATE ST_COMPLETE
.draw:  call    DrawScene
        call    PresentBuffer
        EPILOG  0

; ---------------------------------------------------------------------
; Name:              State_Complete
; Purpose:           Display Level Complete screen with time bonus; return
;                    to ST_TITLE on Enter.
; Inputs:            None
; Outputs:           Draws Level Complete screen or transitions to ST_TITLE
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
State_Complete:
        PROLOG
        push    0
        push    0
        push    SCREEN_W
        push    SCREEN_H
        push    C_BLACK
        call    FillRect
        push    24
        push    16
        push    272
        push    168
        push    C_YELLOW
        push    C_BLACK
        call    DrawBox
        push    34
        push    txt_complete
        push    C_YELLOW
        push    2
        call    DrawTextCentered
        DRAWTEXT 48, 72,  txt_score, C_WHITE, 1
        DRAWNUM  176, 72, word [lc_lo], word [lc_hi], 6, C_WHITE, 1
        DRAWTEXT 48, 88,  txt_coinsl, C_WHITE, 1
        DRAWTEXT 176, 88, txt_x, C_WHITE, 1
        DRAWNUM  184, 88, word [coins], 0, 2, C_WHITE, 1
        DRAWTEXT 48, 104, txt_timeleft, C_WHITE, 1
        DRAWNUM  152, 104, word [lc_time], 0, 3, C_WHITE, 1
        DRAWTEXT 180, 104, txt_x50, C_WHITE, 1
        DRAWNUM  236, 104, word [lc_bonus], 0, 5, C_WHITE, 1
        DRAWTEXT 48, 120, txt_bonus, C_WHITE, 1
        DRAWTEXT 176, 120, txt_plus, C_WHITE, 1
        DRAWNUM  192, 120, word [lc_bonus], 0, 5, C_WHITE, 1
        DRAWTEXT 48, 140, txt_final, C_YELLOW, 1
        DRAWNUM  176, 140, word [score_lo], word [score_hi], 6, C_YELLOW, 1
        push    164
        push    txt_enter
        push    C_LTGREEN
        push    1
        call    DrawTextCentered
        call    PresentBuffer
        push    SC_ENTER
        call    KeyPressed
        test    ax, ax
        jz      .out
        SETSTATE ST_TITLE
.out:   EPILOG  0

; ---------------------------------------------------------------------
; Name:              State_GameOver
; Purpose:           Display Game Over screen with final score; return to
;                    ST_TITLE on Enter.
; Inputs:            None
; Outputs:           Draws Game Over screen or transitions to ST_TITLE
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
State_GameOver:
        PROLOG
        push    0
        push    0
        push    SCREEN_W
        push    SCREEN_H
        push    C_BLACK
        call    FillRect
        push    24
        push    16
        push    272
        push    168
        push    C_RED
        push    C_BLACK
        call    DrawBox
        push    50
        push    txt_gameover
        push    C_LTRED
        push    2
        call    DrawTextCentered
        DRAWTEXT 80, 92,  txt_finalsc, C_WHITE, 1
        DRAWNUM  184, 92, word [score_lo], word [score_hi], 6, C_WHITE, 1
        DRAWTEXT 80, 112, txt_coinsc, C_YELLOW, 1
        DRAWNUM  144, 112, word [coins], 0, 2, C_YELLOW, 1
        DRAWTEXT 176, 112, txt_timec, C_YELLOW, 1
        DRAWNUM  224, 112, word [time_left], 0, 3, C_YELLOW, 1
        push    146
        push    txt_enter_t
        push    C_LTGREEN
        push    1
        call    DrawTextCentered
        call    PresentBuffer
        push    SC_ENTER
        call    KeyPressed
        test    ax, ax
        jz      .out
        SETSTATE ST_TITLE
.out:   EPILOG  0

; ---------------------------------------------------------------------
; Name:              State_Title
; Purpose:           Handle Title screen input (Up/Down, Enter, Esc) and
;                    draw the title menu.
; Inputs:            None
; Outputs:           Updates menu_sel or transitions to PLAYING / EXIT
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
State_Title:
        PROLOG
        push    SC_UP
        call    KeyPressed
        test    ax, ax
        jz      .nu
        mov     byte [menu_sel], 0
.nu:    push    SC_DOWN
        call    KeyPressed
        test    ax, ax
        jz      .nd
        mov     byte [menu_sel], 1
.nd:    push    SC_ESC
        call    KeyPressed
        test    ax, ax
        jz      .ne
        SETSTATE ST_EXIT
        jmp near     .out
.ne:    push    SC_ENTER
        call    KeyPressed
        test    ax, ax
        jz      .draw
        cmp     byte [menu_sel], 0
        jne     .exit
        call    NewGame                 ; START GAME
        SETSTATE ST_PLAYING
        jmp near     .out
.exit:  SETSTATE ST_EXIT
        jmp near     .out
.draw:  call    DrawTitle
        call    PresentBuffer
.out:   EPILOG  0

; ---------- MEMBER 1 ----------
; ---------------------------------------------------------------------
; Name:              DrawTitle
; Purpose:           Draw the Title screen (brick border, ground, sprites,
;                    title text, menu box, and team details).
; Inputs:            None
; Outputs:           Title screen drawn into [bufseg]
; Registers changed: None (all preserved)
; ---------------------------------------------------------------------
DrawTitle:
        PROLOG
        call    ClearBuffer
        mov     si, 16
.g:     push    si                      ; ground strip
        push    160
        push    T_GROUND
        call    DrawTile
        add     si, 16
        cmp     si, 304
        jb      .g
        xor     si, si
.tb:    push    si                      ; top and bottom brick rows
        push    0
        push    T_BRICK
        call    DrawTile
        push    si
        push    176
        push    T_BRICK
        call    DrawTile
        add     si, 16
        cmp     si, SCREEN_W
        jb      .tb
        mov     si, 16
.lr:    push    0                       ; left and right columns
        push    si
        push    T_BRICK
        call    DrawTile
        push    304
        push    si
        push    T_BRICK
        call    DrawTile
        add     si, 16
        cmp     si, 176
        jb      .lr
        push    32
        push    144
        push    spr_small_stand
        push    0
        call    DrawSprite
        push    272
        push    144
        push    spr_goomba
        push    0
        call    DrawSprite
        DRAWTEXT 30, 42, txt_title, C_BLACK, 3
        DRAWTEXT 28, 40, txt_title, C_RED, 3
        push    78
        push    txt_engine
        push    C_WHITE
        push    2
        call    DrawTextCentered
        push    100
        push    100
        push    120
        push    48
        push    C_WHITE
        push    C_BLACK
        call    DrawBox
        mov     ax, C_WHITE
        cmp     byte [menu_sel], 0
        jne     .s1
        mov     ax, C_YELLOW
.s1:    DRAWTEXT 128, 110, txt_start, ax, 1
        mov     ax, C_WHITE
        cmp     byte [menu_sel], 1
        jne     .s2
        mov     ax, C_YELLOW
.s2:    DRAWTEXT 128, 128, txt_exit, ax, 1
        mov     bx, 110                 ; selection arrow
        cmp     byte [menu_sel], 0
        je      .ar
        mov     bx, 128
.ar:    push    112
        push    bx
        push    '>'
        push    C_YELLOW
        push    1
        call    DrawChar
        push    166
        push    txt_team
        push    C_WHITE
        push    1
        call    DrawTextCentered
        EPILOG  0

; ---------- MEMBER 2 ----------
; =====================================================================
;  DATA
; =====================================================================
        section .data

msg_nomem       db "Not enough memory for the frame buffer.", 13, 10, "$"

; ---- text ----
txt_score       db "SCORE", 0
txt_coins       db "COINS", 0
txt_world       db "WORLD", 0
txt_time        db "TIME", 0
txt_lives       db "LIVES", 0
txt_health      db "HEALTH", 0
txt_w11         db "1-1", 0
txt_x           db "x", 0
txt_title       db "SUPER MARIO", 0
txt_engine      db "E N G I N E", 0
txt_start       db "START GAME", 0
txt_exit        db "EXIT", 0
txt_team       db "Group #5 | Hiba, Qaima", 0
txt_paused      db "P A U S E D", 0
txt_resume      db "Press P to resume", 0
txt_world_big   db "WORLD 1-1", 0
txt_liveslft    db "LIVES LEFT", 0
txt_complete    db "LEVEL COMPLETE!", 0
txt_coinsl      db "COINS", 0
txt_timeleft    db "TIME LEFT", 0
txt_x50         db "x 50 =", 0
txt_bonus       db "TIME BONUS", 0
txt_plus        db "+", 0
txt_final       db "FINAL SCORE", 0
txt_enter       db "Press ENTER to continue", 0
txt_gameover    db "G A M E  O V E R", 0
txt_finalsc     db "Final Score:", 0
txt_coinsc      db "Coins:", 0
txt_timec       db "Time:", 0
txt_enter_t     db "Press ENTER for the title", 0

heart_bmp       db 01100110b, 11111111b, 11111111b, 11111111b
                db 01111110b, 00111100b, 00011000b, 00000000b

; stomp chain: 100 200 400 500 800 1000 2000 4000 5000 8000, then 1-UP
stomp_table     dw 100, 200, 400, 500, 800, 1000, 2000, 4000, 5000, 8000
debris_vx       dw -2, -1, 1, 2
debris_vy       dw 0FB00h, 0FC00h, 0FC00h, 0FB00h

state_table     dw State_Title, State_Playing, State_Paused, State_Dying
                dw State_LifeLost, State_Win, State_Complete, State_GameOver

; ---- level: one character per tile, translated by BuildLevel ----
;   . sky  G ground  B brick  ? coin-block  M mushroom-block  E empty block
;   < > pipe top    [ ] pipe body   S stair   o coin   F flag pole
;   C castle wall   D castle door
tile_chars      db ".GB?ME<>[]SoFCD"
level_text:
        db      "............................................................"   ; row 0
        db      "............................................................"   ; row 1
        db      ".......................................................F...."   ; row 2
        db      ".......................................................F...."   ; row 3
        db      "................................oo.....................F...."   ; row 4
        db      ".......................................................F...."   ; row 5
        db      "......?..M....B?B?B..oooo......BBMBB..ooo...........S..F...."   ; row 6
        db      "............................................<>.....SS..F...."   ; row 7
        db      "...........................<>...............[].oo.SSS..F.CCC"   ; row 8
        db      "...........................[]...............[]...SSSS..S.CDC"   ; row 9
        db      "GGGGGGGGGGGGGGGGGGGGGG...GGGGGGGGGGGGG...GGGGGGGGGGGGGGGGGGG"   ; row 10
        db      "GGGGGGGGGGGGGGGGGGGGGG...GGGGGGGGGGGGG...GGGGGGGGGGGGGGGGGGG"   ; row 11

; ---- enemy start table (restored by ResetLevel): type, x, y ----
%macro ENEMY 3
        db      %1, S_WAIT
        dw      %2
        db      0, 0FFh
        dw      %3
        db      0, 0
        dw      0, 0, 0
%endmacro
enemy_init:
        ENEMY   T_GOOMBA, 11*16, 144
        ENEMY   T_GOOMBA, 19*16, 144
        ENEMY   T_GOOMBA, 30*16, 144
        ENEMY   T_GOOMBA, 47*16, 144
        ENEMY   T_KOOPA,  36*16, 144
        ENEMY   T_KOOPA,  42*16, 144
        times   2*E_SIZE db 0

; ---------- MEMBER 1 ----------
; ---- palette (6-bit R,G,B) ----
PAL_FIRST        equ 16
PAL_COUNT        equ 21
palette_tab:
        db      23, 37, 63      ; colour 16
        db      47, 27,  9      ; colour 17
        db       0, 46,  0      ; colour 18
        db      50, 19,  3      ; colour 19
        db      15,  5,  0      ; colour 20
        db      54, 10,  0      ; colour 21
        db      63, 47, 35      ; colour 22
        db       6, 18, 54      ; colour 23
        db      63, 47,  0      ; colour 24
        db       0, 50,  0      ; colour 25
        db       0, 25,  0      ; colour 26
        db      34, 17,  0      ; colour 27
        db       5,  5,  5      ; colour 28
        db      63, 38, 14      ; colour 29
        db      50, 37, 20      ; colour 30
        db      30, 18,  4      ; colour 31
        db      45, 15,  2      ; colour 32
        db      30, 60, 30      ; colour 33
        db      20, 10,  0      ; colour 34
        db      63, 59, 40      ; colour 35
        db      40, 40, 40      ; colour 36

; ---- sprite art: letters are converted to colours by DecodeGraphics ----
gfx_chars       db ".wlpbmrsuygGnkotTcxehd"
GFX_CHAR_COUNT  equ $-gfx_chars
gfx_cols        db 0,15,18,17,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36

gfx_start:
spr_small_stand:
        db      "....rrrrr......."
        db      "...rrrrrrrrr...."
        db      "...nnnssnss....."
        db      "..nsnssssnsss..."
        db      "..nsnnssssnsss.."
        db      "..nnssssnnnn...."
        db      "....sssssss....."
        db      "...rrurrr......."
        db      "..rrrurrurrr...."
        db      ".rrrruuuuurrrr.."
        db      ".ssruyuuuyursss."
        db      ".sssuuuuuuussss."
        db      "..ssuuuuuuuss..."
        db      "...uuu...uuu...."
        db      "..nnn.....nnn..."
        db      ".nnnn.....nnnn.."
spr_small_run:
        db      "....rrrrr......."
        db      "...rrrrrrrrr...."
        db      "...nnnssnss....."
        db      "..nsnssssnsss..."
        db      "..nsnnssssnsss.."
        db      "..nnssssnnnn...."
        db      "....sssssss....."
        db      "..rrrurrr......."
        db      ".ssrrurrurrr...."
        db      ".sssruuuuurrr..."
        db      "..ssuuyuuyuu...."
        db      "...uuuuuuuuu...."
        db      "..uuuuuuuuuu...."
        db      "..uuuu...uuuu..."
        db      ".nnnn.....nnn..."
        db      "nnnn.......nnnn."
spr_small_jump:
        db      "....rrrrr...sss."
        db      "...rrrrrrrrr.sss"
        db      "...nnnssnss..ss."
        db      "..nsnssssnsss.r."
        db      "..nsnnssssnsssr."
        db      "..nnssssnnnn.rr."
        db      "....sssssss.rrr."
        db      "..rrrurrurrrrr.."
        db      ".rrrruuuuurrr..."
        db      ".ssruyuuuyur...."
        db      "sss.uuuuuuu....."
        db      "ss.uuuuuuuuu...."
        db      "...uuuuuuuuuu..."
        db      "..nnuuu..uuuu..."
        db      ".nnnn.....nnnnn."
        db      ".nnn........nnn."
spr_super_stand:
        db      "....rrrrr......."
        db      "...rrrrrrrrr...."
        db      "...nnnssnss....."
        db      "...nnnssnss....."
        db      "..nsnssssnsss..."
        db      "..nsnssssnsss..."
        db      "..nsnnssssnsss.."
        db      "..nsnnssssnsss.."
        db      "..nnssssnnnn...."
        db      "..nnssssnnnn...."
        db      "....sssssss....."
        db      "...rrurrr......."
        db      "...rrurrr......."
        db      "..rrrurrurrr...."
        db      "..rrrurrurrr...."
        db      ".rrrruuuuurrrr.."
        db      ".rrrruuuuurrrr.."
        db      ".ssruyuuuyursss."
        db      ".ssruyuuuyursss."
        db      ".sssuuuuuuussss."
        db      ".sssuuuuuuussss."
        db      "..ssuuuuuuuss..."
        db      "..ssuuuuuuuss..."
        db      "...uuu...uuu...."
        db      "...uuu...uuu...."
        db      "...uuu...uuu...."
        db      "..nnn.....nnn..."
        db      "..nnn.....nnn..."
        db      "..nnn.....nnn..."
        db      ".nnnn.....nnnn.."
        db      ".nnnn.....nnnn.."
        db      ".nnnn.....nnnn.."
spr_super_run:
        db      "....rrrrr......."
        db      "...rrrrrrrrr...."
        db      "...nnnssnss....."
        db      "...nnnssnss....."
        db      "..nsnssssnsss..."
        db      "..nsnssssnsss..."
        db      "..nsnnssssnsss.."
        db      "..nsnnssssnsss.."
        db      "..nnssssnnnn...."
        db      "..nnssssnnnn...."
        db      "....sssssss....."
        db      "..rrrurrr......."
        db      "..rrrurrr......."
        db      ".ssrrurrurrr...."
        db      ".ssrrurrurrr...."
        db      ".sssruuuuurrr..."
        db      ".sssruuuuurrr..."
        db      "..ssuuyuuyuu...."
        db      "..ssuuyuuyuu...."
        db      "...uuuuuuuuu...."
        db      "...uuuuuuuuu...."
        db      "..uuuuuuuuuu...."
        db      "..uuuuuuuuuu...."
        db      "..uuuu...uuuu..."
        db      "..uuuu...uuuu..."
        db      "..uuuu...uuuu..."
        db      ".nnnn.....nnn..."
        db      ".nnnn.....nnn..."
        db      ".nnnn.....nnn..."
        db      "nnnn.......nnnn."
        db      "nnnn.......nnnn."
        db      "nnnn.......nnnn."
spr_super_jump:
        db      "....rrrrr...sss."
        db      "...rrrrrrrrr.sss"
        db      "...nnnssnss..ss."
        db      "...nnnssnss..ss."
        db      "..nsnssssnsss.r."
        db      "..nsnssssnsss.r."
        db      "..nsnnssssnsssr."
        db      "..nsnnssssnsssr."
        db      "..nnssssnnnn.rr."
        db      "..nnssssnnnn.rr."
        db      "....sssssss.rrr."
        db      "..rrrurrurrrrr.."
        db      "..rrrurrurrrrr.."
        db      ".rrrruuuuurrr..."
        db      ".rrrruuuuurrr..."
        db      ".ssruyuuuyur...."
        db      ".ssruyuuuyur...."
        db      "sss.uuuuuuu....."
        db      "sss.uuuuuuu....."
        db      "ss.uuuuuuuuu...."
        db      "ss.uuuuuuuuu...."
        db      "...uuuuuuuuuu..."
        db      "...uuuuuuuuuu..."
        db      "..nnuuu..uuuu..."
        db      "..nnuuu..uuuu..."
        db      "..nnuuu..uuuu..."
        db      ".nnnn.....nnnnn."
        db      ".nnnn.....nnnnn."
        db      ".nnnn.....nnnnn."
        db      ".nnn........nnn."
        db      ".nnn........nnn."
        db      ".nnn........nnn."
; ---------- MEMBER 2 ----------
spr_goomba:
        db      "......nnnn......"
        db      "....nnnnnnnn...."
        db      "...nnnnnnnnnn..."
        db      "..nnnnnnnnnnnn.."
        db      "..nnwwnnnnwwnn.."
        db      ".nnnwkwnnwkwnnn."
        db      ".nnnwwwnnwwwnnn."
        db      ".nnnnnnnnnnnnnn."
        db      "..nnnnnnnnnnnn.."
        db      "...nnnnnnnnnn..."
        db      "....ssssssss...."
        db      "...sssssssssss.."
        db      "...ssssssssss..."
        db      "..kkkkk..kkkkk.."
        db      ".kkkkkk..kkkkkk."
        db      "..kkkk....kkkk.."
spr_goomba_flat:
        db      "................"
        db      "................"
        db      "................"
        db      "................"
        db      "................"
        db      "................"
        db      "................"
        db      "................"
        db      "................"
        db      "................"
        db      "................"
        db      "....nnnnnnnn...."
        db      "..nnnnnnnnnnnn.."
        db      ".nnwknnnnnnkwnn."
        db      ".nnnnnnnnnnnnnn."
        db      "..kkkk....kkkk.."
spr_koopa:
        db      ".....yyyy......."
        db      "....yyyyyy......"
        db      "....kyyyyy......"
        db      "....yyyyyyy....."
        db      ".....yyyyy......"
        db      "....GGGGGGG....."
        db      "...GgggggggG...."
        db      "..GgxgggxgggG..."
        db      "..GggggggggggG.."
        db      "..GgxgggxgggG..."
        db      "..GgggggggggG..."
        db      "...GGGGGGGGG...."
        db      "....yyyyyyy....."
        db      "...yyyy.yyyy...."
        db      "...yyy...yyy...."
        db      "..yyyy...yyyy..."
spr_shell:
        db      "................"
        db      "................"
        db      "................"
        db      ".....GGGGGG....."
        db      "...GGgggggGGG..."
        db      "..GgxxggggggGG.."
        db      "..GgxxgggggggG.."
        db      ".GggggggggggggG."
        db      ".GgggxxgggxxggG."
        db      ".GgggxxgggxxggG."
        db      ".GGGGGGGGGGGGGG."
        db      ".wwwwwwwwwwwwww."
        db      "..wwwwwwwwwwww.."
        db      "...wwwwwwwwww..."
        db      "................"
        db      "................"
spr_mushroom:
        db      "......rrrr......"
        db      "....rrrrrrrr...."
        db      "...rrwwrrrrrr..."
        db      "..rrwwwwrrwwrr.."
        db      ".rrrwwwwrrwwwrr."
        db      ".rrrrwwrrrrwwrrr"
        db      "rrrrrrrrrrrrrrrr"
        db      "rrwwrrrrrrrwwrrr"
        db      ".rwwwrrrrrrwwwr."
        db      "..rrrrrrrrrrrr.."
        db      "....wwwwwwww...."
        db      "...wwkwwwwkww..."
        db      "...wwwwwwwwww..."
        db      "...wwwwwwwwww..."
        db      "....wwwwwwww...."
        db      "................"
spr_flag:
        db      "...............G"
        db      "..............wG"
        db      "............wwwG"
        db      "..........wwwwwG"
        db      "........wwwwwwwG"
        db      "......wwwwwwwwwG"
        db      "....wwwwwwwwwwwG"
        db      "..wwwwwwwwwwwwwG"
        db      "....wwwwwwwwwwwG"
        db      "......wwwwwwwwwG"
        db      "........wwwwwwwG"
        db      "..........wwwwwG"
        db      "............wwwG"
        db      "..............wG"
        db      "...............G"
        db      "................"
spr_coin:
        db      ".......oo......."
        db      "......oooo......"
        db      ".....ohhyyo....."
        db      "....oohhyyoo...."
        db      "....oyhhyyyo...."
        db      "....oyhhyyyo...."
        db      "....oyhhyyyo...."
        db      "....oyhhyyyo...."
        db      "....oyhhyyyo...."
        db      "....oyhhyyyo...."
        db      "....oyhhyyyo...."
        db      "....oyhhyyyo...."
        db      "....oohhyyoo...."
        db      ".....ohhyyo....."
        db      "......oooo......"
        db      ".......oo......."
tile_ground:
        db      "llllllllllllllll"
        db      "llllllllllllllll"
        db      "llllllllllllllll"
        db      "nnnnnnnnnnnnnnnn"
        db      "pppppppppnpppppp"
        db      "pppnppppppppppnp"
        db      "ppppppppnppppppp"
        db      "ppnppppppppppnpp"
        db      "pppppppnpppppppp"
        db      "pnppppppppppnppp"
        db      "ppppppnppppppppp"
        db      "nppppppppppnpppp"
        db      "pppppnpppppppppp"
        db      "ppppppppppnppppp"
        db      "ppppnppppppppppn"
        db      "pppppppppnpppppp"
tile_brick:
        db      "bbbbbbbmbbbbbbbm"
        db      "bbbbbbbmbbbbbbbm"
        db      "bbbbbbbmbbbbbbbm"
        db      "mmmmmmmmmmmmmmmm"
        db      "bbbmbbbbbbbmbbbb"
        db      "bbbmbbbbbbbmbbbb"
        db      "bbbmbbbbbbbmbbbb"
        db      "mmmmmmmmmmmmmmmm"
        db      "bbbbbbbmbbbbbbbm"
        db      "bbbbbbbmbbbbbbbm"
        db      "bbbbbbbmbbbbbbbm"
        db      "mmmmmmmmmmmmmmmm"
        db      "bbbmbbbbbbbmbbbb"
        db      "bbbmbbbbbbbmbbbb"
        db      "bbbmbbbbbbbmbbbb"
        db      "mmmmmmmmmmmmmmmm"
tile_qblock:
        db      "eeeeeeeeeeeeeeee"
        db      "eooooooooooooooe"
        db      "eoeooooooooooeoe"
        db      "eooooohhhhoooooe"
        db      "eoooohhoohhooooe"
        db      "eoooohhoohhooooe"
        db      "eoooooooohhooooe"
        db      "eooooooohhoooooe"
        db      "eoooooohhooooooe"
        db      "eooooooooooooooe"
        db      "eoooooohhooooooe"
        db      "eooooooooooooooe"
        db      "eooooooooooooooe"
        db      "eoeooooooooooeoe"
        db      "eooooooooooooooe"
        db      "eeeeeeeeeeeeeeee"
tile_empty:
        db      "eeeeeeeeeeeeeeee"
        db      "ennnnnnnnnnnnnne"
        db      "enennnnnnnnnnene"
        db      "ennnnnnnnnnnnnne"
        db      "ennnnnnnnnnnnnne"
        db      "ennnnnnnnnnnnnne"
        db      "ennnnnnnnnnnnnne"
        db      "ennnnnnnnnnnnnne"
        db      "ennnnnnnnnnnnnne"
        db      "ennnnnnnnnnnnnne"
        db      "ennnnnnnnnnnnnne"
        db      "ennnnnnnnnnnnnne"
        db      "ennnnnnnnnnnnnne"
        db      "enennnnnnnnnnene"
        db      "ennnnnnnnnnnnnne"
        db      "eeeeeeeeeeeeeeee"
tile_ptl:
        db      "GGGGGGGGGGGGGGGG"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
tile_ptr_:
        db      "GGGGGGGGGGGGGGGG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
tile_pbl:
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
        db      "Ggxxgggggggggggg"
tile_pbr:
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
        db      "gggggggggggggGgG"
tile_stair:
        db      "TTTTTTTTTTTTTTTT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TttttttttttttttT"
        db      "TTTTTTTTTTTTTTTT"
tile_pole:
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
        db      ".......GG......."
tile_castle:
        db      "ccccccceccccccce"
        db      "ccccccceccccccce"
        db      "ccccccceccccccce"
        db      "eeeeeeeeeeeeeeee"
        db      "cccecccccccecccc"
        db      "cccecccccccecccc"
        db      "cccecccccccecccc"
        db      "eeeeeeeeeeeeeeee"
        db      "ccccccceccccccce"
        db      "ccccccceccccccce"
        db      "ccccccceccccccce"
        db      "eeeeeeeeeeeeeeee"
        db      "cccecccccccecccc"
        db      "cccecccccccecccc"
        db      "cccecccccccecccc"
        db      "eeeeeeeeeeeeeeee"
tile_door:
        db      "ccccccceccccccce"
        db      "ccccccceccccccce"
        db      "ccccccceccccccce"
        db      "eeeeeeeeeeeeeeee"
        db      "cccekkkkkkkkcccc"
        db      "ccckkkkkkkkkkccc"
        db      "ccckkkkkkkkkkccc"
        db      "eeekkkkkkkkkkeee"
        db      "ccckkkkkkkkkkcce"
        db      "ccckkkkkkkkkkcce"
        db      "ccckkkkkkkkkkcce"
        db      "eeekkkkkkkkkkeee"
        db      "ccckkkkkkkkkkccc"
        db      "ccckkkkkkkkkkccc"
        db      "ccckkkkkkkkkkccc"
        db      "eeekkkkkkkkkkeee"
gfx_end:

; ---------- MEMBER 2 ----------
tile_ptr        dw 0, tile_ground, tile_brick, tile_qblock, tile_qblock, tile_empty
                dw tile_ptl, tile_ptr_, tile_pbl, tile_pbr, tile_stair
                dw spr_coin, tile_pole, tile_castle, tile_door
hero_spr_tab    dw spr_small_stand, spr_small_run, spr_small_jump
                dw spr_super_stand, spr_super_run, spr_super_jump

; ---- variables (all initialised in code before use) ----
bufseg          dw 0
state           db 0
menu_sel        db 0
state_timer     dw 0
frame_ctr       dw 0
tick_count      dw 0
last_tick       dw 0
tick_delta      dw 1
bios_acc        dw 0
old_int08       dw 0, 0
old_int09       dw 0, 0
kb_e0           db 0
camera_x        dw 0
dm_first        dw 0
dm_off          dw 0
spr_cs          dw 0
spr_ce          dw 0
spr_rows        dw 0
gl_rows         dw 0
; hero
hero_x          dw 0
hero_xf         db 0
hero_y          dw 0                    ; FEET position
hero_yf         db 0
hero_vx         dw 0
hero_vy         dw 0
hero_h          dw 16
hero_prev_y     dw 0
hero_anim       dw 0
hero_form       db 0                    ; 0 Small, 1 Super
hero_hp         db 1
hero_face       db 0                    ; 0 right, 1 left
hero_ground     db 0
hero_latch      db 0
hero_invuln     db 0
hero_chain      db 0
hero_hidden     db 0
hero_pose_ovr   db 0FFh
dead_pending    db 0
flag_hit        db 0
flag_row        dw 0
win_phase       db 0
; score / clock
score_lo        dw 0
score_hi        dw 0
coins           dw 0
lives           dw 3
time_left       dw 300
sec_acc         dw 0
lc_lo           dw 0
lc_hi           dw 0
lc_time         dw 0
lc_bonus        dw 0

; =====================================================================
;  UNINITIALISED DATA
; =====================================================================
        section .bss
key_down        resb 128
key_event       resb 128
level_orig      resb MAP_SIZE
level_work      resb MAP_SIZE
enemies         resb ENEMY_MAX*E_SIZE
items           resb ITEM_MAX*E_SIZE  ;assembly diractive to save space i memory
fx_table        resb FX_MAX*FX_SIZE
font_buf        resb 1024
