/*
 * Simple ST application to playback YMamoto tunes.
 * This is based on some simple code that Michael Bricout gave me.
 * 
 * Also, this is tweaked to work with GNU as, which means that
 * it's not only my fault that the style is ugly.
 *
 * Julian Squires <tek@wiw.org> / 2004-2005
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
hbl_vector = 0x68
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
        MOVE.L D0, vram_address
        MOVE.L D0, A0
        MOVE.W #32000/4, D1
        MOVEQ #0, D0
0:      MOVE.L D0, (A0)+
        DBF D1, 0b

        | Save TOS VBL, HBL vectors, interrupt settings.
        LEA old_vectors, A0
        MOVE.L hbl_vector, (A0)+
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
        | Setup our own vbl, hbl handlers (HBL not called by default).
        MOVE.L #raster_bars_vbl, vbl_vector
        MOVE.L #hbl_handler, hbl_vector

        BSR reset_sine_oscillator
        CLR.W scrolly_pos

        MOVE.W #0x2300, SR      | Unmask most interrupts.
        RTS


shutdown:
        MOVE.W #0x2700, SR      | Mask interrupts.

        MOVE.B saved_system_res, 0xFF8260   | Restore shifter res.
        MOVEM.L saved_system_palette, D0-D7 | Restore palette.
        MOVEM.L D0-D7, 0xFF8240

        | Restore TOS VBL, timer B vectors.
        LEA old_vectors, A0
        MOVE.L (A0)+, hbl_vector
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

        BSR ymamoto_reset       | Mute YM.

        MOVE.B #0b10010110, 0xFFFC00 | Interrupts on, 8N1, clock/64.
0:      BTST #1, 0xFFFC00       | ACIA Tx buffer full?
        BEQ 0b
        MOVE.B #8, 0xFFFC02     | I suppose we'd better restore the mouse.
        RTS


/* Called each vertical blank. */
raster_bars_vbl:
        MOVEM.L D0-D2/A0-A2, -(SP)

        MOVE.W #0, 0xFF8240     | Black by default.
        MOVE.W #0xFFFF, 0xFF8242 | White text.

        | Update sine values.
        BSR step_sine_oscillator

        | Update positions of bars.
        MOVE.W sine, D0         | Circular motion around X axis.
        ASR.W #2, D0
        MOVE.W D0, bar_a_z
        MOVE.W cosine, D0
        ASR.W #2, D0
        ADD.W #80, D0
        MOVE.W D0, bar_a_y

        MOVE.W sine, D0         | Circular motion around X axis.
        ASR.W #2, D0
        ADD.W #20, D0
        MOVE.W D0, bar_b_z
        MOVE.W cosine, D0
        ASR.W #3, D0
        ADD.W #40, D0
        MOVE.W D0, bar_b_y

        | Setup scanline/hblank routine.
        CLR.B 0xFFFA1B          | Disable timer B.
        MOVE.B bar_a_y+1, 0xFFFA21
        MOVE.L #scanline_bar_a, timer_b_vector
        MOVE.B #0x18, 0xFFFA1B     | Enable timer B (event mode).
        BSET #0, 0xFFFA07       | intA enable timer B.
        BSET #0, 0xFFFA13       | intA mask, unmask timer B.

        MOVE.W bar_a_y, scanline
        MOVE.W #0x310, next_palette_value

        | Update scrolly.
        BSR update_scrolly

        | Update music.
        LEA tune_data, A0
        BSR ymamoto_update

        MOVEM.L (SP)+, D0-D2/A0-A2
        RTE


hbl_handler:
        MOVE.W #0x2300, SR      | disable ourselves.
        RTE

scanline_bar_a:
        MOVE.W next_palette_value, 0xFF8240
        MOVEM.L D0-D2/A0, -(SP)
0:      | get delta of current scanline to initial y
        MOVE.W scanline, D0
        MOVE.W bar_a_y, D1
        SUB.W D1, D0            | D0 = scanline - y_a
        MOVE.W bar_b_y, D1
        SUB.W D0, D1
        BLE 2f

        CMP #40, D0
        BGE 1f
        | check Z, etc...
        BRA 2f

1:      |MOVE.L #scanline_bar_b, timer_b_vector
        |MOVE.B #0, 0xFFFA1B
        |MOVE.B D1, 0xFFFA21
        |MOVE.B #0x18, 0xFFFA1B
        |ADD.W D1, scanline
        |BRA 3f

2:      MOVE.B #0, 0xFFFA1B
        MOVE.B #4, 0xFFFA21
        MOVE.B #0x18, 0xFFFA1B
        ADD.W #4, scanline

3:      | get color according to delta
        LSR.B #1, D0
        ADDQ #2, D0
        CMP.B #20, D0
        BLS 0f
        MOVEQ #20, D0
0:      LEA 0f, A0
        MOVE.W (A0,D0), D1
        BRA 1f
0:      DC.W 0x310, 0x421, 0x421, 0x632, 0x632, 0x632, 0x632
        DC.W 0x421, 0x421, 0x310, 0
1:      | XXX modify by Z
        MOVE.W D1, next_palette_value

        MOVEM.L (SP)+, D0-D2/A0
        BCLR #0, 0xFFFA0F       | Ack interrupt?
        RTE


| stupid fucking one-pass assemblers!
scroll_text_len = 856

        | 1bpp scrolltext along middle of screen.
update_scrolly:
        | XXX Test
        MOVE.L vram_address, A0
        ADD.W #11520, A0

        MOVE.W scrolly_pos, D0
        CMP.W #(scroll_text_len<<3), D0
        BLS 0f
        CLR.W D0
        MOVE.W D0, scrolly_pos
0:      AND.B #0x07, D0
        BNE 1f

        MOVE.W scrolly_pos, D0
        LSR.W #3, D0
        LEA scroll_text, A1
        MOVEQ #0, D1
        MOVE.B (A1,D0), D1
        LEA one_bpp_font, A1
        LSL.W #3, D1
        ADD.W D1, A1
        MOVEQ #7, D0
        LEA scrolly_buffer, A2
0:      MOVE.B (A1)+, (A2)+
        ADDQ #1, A2
        DBF D0, 0b

1:      MOVEQ #7, D0
        LEA scrolly_buffer, A1
0:      LSL (A1)+
        ROXL.W 152(A0)
        ROXL.W 144(A0)
        ROXL.W 136(A0)
        ROXL.W 128(A0)
        ROXL.W 120(A0)
        ROXL.W 112(A0)
        ROXL.W 104(A0)
        ROXL.W 96(A0)
        ROXL.W 88(A0)
        ROXL.W 80(A0)
        ROXL.W 72(A0)
        ROXL.W 64(A0)
        ROXL.W 56(A0)
        ROXL.W 48(A0)
        ROXL.W 40(A0)
        ROXL.W 32(A0)
        ROXL.W 24(A0)
        ROXL.W 16(A0)
        ROXL.W 8(A0)
        ROXL.W (A0)
        ADD.W #160, A0
        DBF D0, 0b

        ADD.W #1, scrolly_pos
        RTS

        .global plot_debug_dword
plot_debug_dword:
        LEA debug_string_buf, A2

        LEA hex_xlat, A1
        MOVEQ #8-1, D1
0:      ROL.L #4, D0
        MOVE.B D0, D2
        AND.L #0xf, D2
        MOVE.B (A1,D2), (A2)+
        DBF D1, 0b
        MOVE.B #0, (A2)+
        LEA debug_string_buf, A2
        BSR plot_debug_string
        RTS


        | A2 = address of string, NUL terminated.
plot_debug_string:
        MOVE.L vram_address, A0
0:      MOVEQ #0, D0
        MOVE.B (A2)+, D0
        BEQ 1f
        LEA one_bpp_font, A1
        LSL.W #3, D0
        ADD.W D0, A1
        MOVEQ #7, D0
2:      MOVE.B (A1)+, (A0)
        ADD.W #160, A0
        DBF D0, 2b
        SUB.W #1280, A0
        MOVE.L A0, D0
        BTST #0, D0
        BNE 3f
        ADDQ #1, A0
        BRA 0b
3:      ADDQ #7, A0
        BRA 0b

1:      RTS

	.bss
        .align 4
vram_address: .skip 4
old_vectors: .skip 20
saved_system_palette: .skip 32
saved_system_res: .skip 1
        .align 2
scrolly_pos: .skip 2
scrolly_buffer: .skip 16
scanline: .skip 2
bar_a_y: .skip 2
bar_a_z: .skip 2
bar_b_y: .skip 2
bar_b_z: .skip 2
next_palette_value: .skip 2
debug_string_buf: .skip 10

        .data
        .align 4
tune_data: .incbin "demo-y.bin"
one_bpp_font: .incbin "readable.f08"
scroll_text: .ascii "The mandatory scrolltext...  tek speaking.  Yes, it's unbelievable that I'm so lazy that I didn't implement any cool effects in this scrolly.  I've been struggling with these damned MiNT cross-targetted binutils for the past two weeks -- I can never be sure whether the bugs are in my code or in the tools, because each available version of the binutils produces different eccentric behavior.  Next time, I'll have all this stuff fixed, and probably will have jettisoned these fucking binutils for a real assembler/linker.  Greets?  Of course.  Greets go out to the lonely St. John's scene, such as it is -- Retsyn, Michael (you need a new handle)...  uh, and how about all the people who were sceners in some sense but then disappeared...  off the top of my head I'm thinking of mr. nemo, jason, flyer, rubix...  Anyway.  Write more code!                 "
|scroll_text_len = (. - scroll_text)
hex_xlat: DC.B '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'
        DC.B 'a', 'b', 'c', 'd', 'e', 'f'

| vim:syn=gnuas68k
