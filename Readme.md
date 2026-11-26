# Super Mario Engine

**EL2003 – Computer Organization and Assembly Language | Semester Project (Fall 2026)**
A 16-bit side-scrolling platform game written in x86 Assembly (NASM), VGA mode 13h, running in DOSBox.

## 1. Team

| Group | Section | Instructor |
|---|---|---|
| Group #5 | SE 3rd Semester, Section __ | __________ |

| Name | Roll Number | Modules developed |
|---|---|---|
| Hiba | 25F-3016 | Modules 1, 3, 4, 6, 7, 8, 9, 10 and HUD / text drawing of Module 13 |
| Qaima | 25F-3017 | Modules 2, 5, 11, 12, 14, 15 and scoring / lives logic of Module 13 |

Repository: https://github.com/hiba22saeed-commits/COAL_Project_BSE_B_25F-3016_25F-3017.git

## 2. Build and Run

**Tools:** NASM and DOSBox v0.74-3 or later.                               

```
nasm -f bin src\mario.asm -o MARIO.COM
```

Or just run `build.bat`, which runs the command above.

**Run in DOSBox**

```
mount c C:\path\to\project
c:
MARIO.COM
```

For full speed set `cycles=max` in `dosbox.conf`. The game is timed by the timer interrupt (30 ticks per second), so speed does not depend on the PC.

## 3. Controls

| Key | Scan code | Action |
|---|---|---|
| Left / Right arrow | 4Bh / 4Dh | Move left / right |
| Left Shift | 2Ah | Run (higher speed limit) |
| Space | 39h | Jump (hold for a higher jump, ground only) |
| Up / Down arrow | 48h / 50h | Move menu highlight |
| Enter | 1Ch | Select in menu, continue on end screens |
| P | 19h | Pause / resume |
| Esc | 01h | Back to title (from play or pause); exit (from title) |

**Debug keys (only while playing):**

| Key | Effect |
|---|---|
| F1 | Sets the clock to 5 seconds |
| F2 | Sets coins to 99 (one more coin gives a life) |
| F3 | Mario becomes Super Mario |

## 4. Memory Choices

- The program is a single-segment `.COM` file (`org 100h`). `DS = CS = SS` for the whole program.
- **Frame buffer:** the 64,000-byte off-screen buffer lives in a second segment placed at `CS + 1000h`, the first paragraph after our own 64 KB segment. At start-up the program checks that the buffer ends below the video segment `0A000h`. If not, it prints "Not enough memory for the frame buffer." and exits to DOS. No DOS memory allocation call is used; a `.COM` program is given all free conventional memory, and we use the part just above our segment.
- **Level map:** 60 x 12 = 720 bytes, kept twice: `level_orig` (never changed) and `level_work` (changed by blocks and coins). `ResetMap` restores the working copy with one `REP MOVSW`.
- **Keyboard:** `key_down` (128 bytes, 1 = held) and `key_event` (128 bytes, set on a new press, cleared when read).
- **Entities:** `enemies` (8 records x 16 bytes), `items` (4 records x 16 bytes) and `fx_table` (12 records x 12 bytes: coin pops, score pop-ups, brick debris).
- **Fixed point:** positions and velocities use 8.8 format (whole pixels in the high byte). Horizontal and vertical positions are a word plus a separate fraction byte.
- **Score:** 32-bit, two words (`score_lo`, `score_hi`), added with `ADD`/`ADC` and clamped to 999,999.

## 5. Interrupts

- **Keyboard (INT 09h):** our own handler reads port 60h, ignores the `E0h` prefix (and the fake `2Ah` that comes with it), ignores typematic repeats, updates `key_down` / `key_event`, sends EOI and returns with `IRET`. The old vector is saved with INT 21h AH=35h and restored with AH=25h on exit.
- **Timer (INT 08h):** PIT channel 0 is programmed to 30 Hz (divisor 39773). The handler increments `tick_count` and chains to the original BIOS handler about 18.2 times per second so the DOS clock stays correct. On exit the PIT is set back to 18.2 Hz and the old vector is restored.
- `WaitTick` halts until `tick_count` changes. The one-second game clock is derived from the ticks (30 ticks = 1 second).

## 6. Game States

The game uses a state variable and a jump table (`state_table`).

| State | Description |
|---|---|
| TITLE | Menu with START GAME and EXIT. Up/Down move the highlight, Enter selects, Esc exits. |
| PLAYING | One frame of gameplay in the order of Section 5.13 of the manual. P pauses, Esc returns to the title. |
| PAUSED | Picture stays visible with a PAUSED box. Updates and clock are frozen. P resumes, Esc goes to the title. |
| DYING | Death animation of about 1.5 s (hop then fall). Then lives - 1, going to LIFE LOST or GAME OVER. |
| LIFE LOST | Shows WORLD 1-1 and lives left for about 2 s, then resets the level and returns to PLAYING. |
| WIN SEQUENCE | Mario slides down the pole, walks to the castle and disappears. Then goes to LEVEL COMPLETE. |
| LEVEL COMPLETE | Shows score, coins, time left x 50 bonus and final score. Enter returns to the title. |
| GAME OVER | Shows final score, coins and time. Enter returns to the title. |
| EXIT | Restores the timer and keyboard, switches to text mode and returns to DOS. |

## 7. Frame Order (PLAYING state)

1. Wait for the next timer tick. 2. Read the key-state table. 3. `UpdateMario` (horizontal move, then vertical move, with tile collision). 4. `UpdateEnemies`, `UpdateItems`, `UpdateFx`. 5. `ResolveEnemies`, `ResolveItems`, `CollectTiles`. 6. `UpdateClock` (clock and invulnerability timer). 7. `CheckEnd` (pit, enemy damage, time, flag pole). 8. `UpdateCamera`. 9. `DrawScene` into the frame buffer. 10. `PresentBuffer` copies it to video memory with `REP MOVSW`.

## 8. Level

60 x 12 tiles. Contents: 2 pits (3 tiles wide each), 2 pipes (2 and 3 tiles high), 3 coin "?" blocks, 2 mushroom blocks (one early, at column 9), 2 brick groups, 11 free coins, 4 Goombas and 2 Koopas, then four stair steps, a 7-tile flag pole with a base block and a castle.

## 9. Procedure Conventions

- Parameters are pushed on the stack (left to right) and removed by the callee with `RET n`.
- A result is returned in `AX`.
- Every register not returned is preserved (`PUSHA`/`POPA`, and `ES` where it is used).
- Every procedure has a comment block: name, purpose, inputs, outputs, registers changed.

## 10. Bonus Features

- Walking animation (Mario alternates stand/run sprites; Goomba mirrors while walking).
- Score pop-ups above the action (coins, stomps, kicks, bricks, mushroom, flag).
- "Hurry" blink: the time on the HUD blinks red when below 100.

## 11. Deviations from the Manual

- Text is drawn with the BIOS 8x8 ROM font, copied into `font_buf` at start-up through INT 10h (AX=1130h), instead of our own font bitmap.
- The VGA palette entries 16 to 36 are loaded with our own colours (INT 10h AX=1012h). Colours 0 to 15 use the default VGA palette.
- The code uses `cpu 186` instructions (`PUSHA`/`POPA`, `IMUL` with an immediate value, shifts by an immediate). It runs in DOSBox but not on a bare 8086.
- Debug keys F1, F2, F3 (listed in Section 3).
- The NASM `JUMPS` option is used so that short conditional jumps are extended automatically.

## 12. Known Limitations

- Only one level and no sound.
- High score is not saved.
- Mario's tile collision samples the head, middle and feet points only, so very thin gaps cannot be detected (not present in our level).
- Enemies are checked against tiles at two points on the leading edge and two points under the feet only.
- The 8-enemy and 4-item limits are fixed table sizes.

## 13. Repository Layout

```
README.md         
src/
├── mario.asm
└── build.bat
```
