/*
 * Simple ST application to playback YMamoto tunes.
 * This is based on some simple code that Michael Bricout gave me.
 * 
 * Also, this is tweaked to work with GNU as, which means that
 * it's not only my fault that the style is ugly.
 *
 * Julian Squires <tek@wiw.org> / 2004
 */

        .text
        .global _main
_main:	MOVE.L #super_main, -(SP)
	MOVE.W #38, -(SP)
	TRAP #14		| XBIOS Supexec
	ADDQ #6, SP

	MOVE.W #0, -(SP)
	TRAP #1
||| main end.


| Vector addresses.
vbl_vector = 0x70
timer_b_vector = 0x120

super_main:
        MOVEM.L D0-D7/A0-A1, -(SP)

        BSR init

0:      CMP.B #0x39, 0xFFFC02   | The ol' hit-space-to-continue bit.
	BNE 0b

        BSR shutdown

        MOVEM.L (SP)+, D0-D7/A0-A1
        RTS


init:   BTST #1, 0xFFFC00       | ACIA Tx buffer full?
        BEQ init
        MOVE.B #0x12, 0xFFFC02  | I *hate* mice.
        MOVE.B #0, 0xFFFC00

        | Setup music playback routine.
        LEA tune_data, A0
        MOVEQ #0, D0
        BSR ymamoto_init

        | Save system palette.
        MOVEM.L 0xFF8240, D0-D7
        MOVEM.L D0-D7, saved_system_palette
        | Save system res.
        MOVE.B 0xFF8260, D0
        LEA saved_system_res, A0
        MOVE.B D0, (A0)

        MOVE.W #0x2700, SR      | Mask interrupts.

        MOVE.B #0, 0xFF8260     | Shifter resolution -- low res.
        MOVEQ #0, D0
        MOVE.B 0xFF8201, D0     | Video RAM address.
        LSL.W #8, D0
        MOVE.B 0xFF8203, D0
        LSL.L #8, D0
        | XXX One more byte available on the STe.

        | Clear VRAM.
        MOVE.L D0, A0
        MOVE.W #0x8000/4, D1
        MOVEQ #0, D0
0:      MOVE.L D0, (A0)+
        DBF D1, 0b

        | Save TOS VBL, HBL vectors, interrupt settings.
        LEA old_vectors, A0
        MOVE.L vbl_vector, (A0)+
        MOVE.L timer_b_vector, (A0)+
        MOVE.B 0xFFFA07, (A0)+  | Timers.
        MOVE.B 0xFFFA09, (A0)+
        MOVE.B 0xFFFA15, (A0)+
        MOVE.B 0xFFFA17, (A0)+
        MOVE.B 0xFFFA19, (A0)+
        MOVE.B 0xFFFA1b, (A0)+
        MOVE.B 0xFFFA1f, (A0)+
        MOVE.B 0xFFFA21, (A0)+
        | Setup our own vectors.
        LEA vbl_vector, A0
        MOVE.L #copper_bars_vbl, D0
        MOVE.L D0, (A0)
        LEA timer_b_vector, A0
        MOVE.L #copper_bars_hbl, D0
        MOVE.L D0, (A0)

        | For the record, I hate interrupts.  I think the line below
        | should make all the interrupts auto-acknowledge.  I might
        | change that later.
        MOVE.B #0x40, 0xFFFA17

        MOVE.W #0x2300, SR      | Unmask interrupts.
        RTS


shutdown:
        MOVE.W #0x2700, SR      | Mask interrupts.

        MOVE.B saved_system_res, 0xFF8260   | Restore shifter res.
        MOVEM.L saved_system_palette, D0-D7 | Restore palette.
        MOVEM.L D0-D7, 0xFF8240

        | Restore TOS VBL, timer B vectors.
        LEA old_vectors, A0
        MOVE.L (A0)+, vbl_vector
        MOVE.L (A0)+, timer_b_vector
        MOVE.B (A0)+, 0xFFFA07  | Timers.
        MOVE.B (A0)+, 0xFFFA09
        MOVE.B (A0)+, 0xFFFA15
        MOVE.B (A0)+, 0xFFFA17
        MOVE.B (A0)+, 0xFFFA19
        MOVE.B (A0)+, 0xFFFA1b
        MOVE.B (A0)+, 0xFFFA1f
        MOVE.B (A0)+, 0xFFFA21

        MOVE.W #0x2300, SR      | Unmask interrupts.

        JSR ymamoto_reset       | Mute YM.

        MOVE.B #0b10010110, 0xFFFC00 | Interrupts on, 8N1, clock/64.
0:      BTST #1, 0xFFFC00       | ACIA Tx buffer full?
        BEQ 0b
        MOVE.B #8, 0xFFFC02     | I suppose we'd better restore the mouse.
        RTS


copper_bars_vbl:
        MOVEM.L D0/A0, -(SP)

        MOVE.B #0, 0xFF8240     | Black by default.
        MOVE.B #0, scanline

        | Setup hblank routine.
        CLR.B 0xFFFA1B          | Disable timer B.
        MOVE.B #1, 0xFFFA21     | one scanline?
        MOVE.B #8, 0xFFFA1B     | Enable timer B (event mode).
        BSET #0, 0xFFFA07       | intA enable timer B.
        BSET #0, 0xFFFA13       | intA mask, unmask timer B.

        | Update sine values.
        | Update positions of bars.
        | Update scrolly.

        | Update music.
        LEA tune_data, A0
        MOVEQ #0, D0
        JSR ymamoto_update

        MOVEM.L (SP)+, D0/A0
        RTE

copper_bars_hbl:
        MOVEM.L D0-D2/A0, -(SP)

        MOVE.B #4, 0xFFFA21     | One scanline?

        MOVE.B scanline, D0
        | Are we on bar A?
        | Find Z, color.
        | Are we on bar B?
        | Find Z.
        | If Z > A's Z, find color.
        | Set palette to color if we have it.
        MOVE.W D0, 0xFF8240   | Blue, as a test.
        BRA 1f
0:      MOVE.W #0x30, 0xFF8240  | Otherwise, set palette green.
1:      ADD.B #1, scanline      | Update scanline count.

        MOVEM.L (SP)+, D0-D2/A0
        RTE


	.data

tune_data: .incbin "demo-y.bin"

        .bss

        .align 4
old_vectors: .skip 16
saved_system_palette: .skip 32
saved_system_res: .skip 1
scanline: .skip 1

| vim:syn=gnuas68k
