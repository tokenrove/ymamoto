 *
 * Simple ST application to playback YMamoto tunes.
 * This is based on some simple code that Michael Bricout gave me.
 * 
 * Also, this is tweaked to work with GNU as, which means that
 * it's not only my fault that the style is ugly.
 *
 * Julian Squires <tek@wiw.org> / 2004-2005
 *

        section text
        global _main
_main:	MOVE.L #super_main, -(SP)
	MOVE.W #38, -(SP)
	TRAP #14		; XBIOS Supexec
	ADDQ.L #6, SP

	MOVE.W #0, -(SP)
	TRAP #1
;;; main end.

	extern ymamoto_init, ymamoto_reset, ymamoto_update
        extern sine, cosine, step_sine_oscillator, reset_sine_oscillator


; Vector addresses.
hbl_vector = $68
vbl_vector = $70
timer_b_vector = $120

super_main:
        MOVEM.L D0-D7/A0-A1, -(SP)
        BSR init
.0:     CMPI.B #$39, $FFFC02	; The ol' hit-space-to-continue bit.
	BNE .0
        BSR shutdown
        MOVEM.L (SP)+, D0-D7/A0-A1
        RTS


init:   BTST #1, $FFFC00	; ACIA Tx buffer full?
        BEQ init
        MOVE.B #$12, $FFFC02	; I *hate* mice.
        MOVE.B #0, $FFFC00

        ; Setup music playback routine.
        LEA tune_data, A0
        MOVEQ #1, D0
        BSR ymamoto_init

        ; Save system palette.
        MOVEM.L $FF8240, D0-D7
        MOVEM.L D0-D7, saved_system_palette
        ; Save system res.
        MOVE.B $FF8260, D0
        LEA saved_system_res, A0
        MOVE.B D0, (A0)

        MOVE.W #$2700, SR      ; Mask interrupts.

        MOVE.B #0, $FF8260     ; Shifter resolution -- low res.
        MOVEQ #0, D0
        MOVE.B $FF8201, D0     ; Video RAM address.
        LSL.W #8, D0
        MOVE.B $FF8203, D0
        LSL.L #8, D0
        ; XXX One more byte available on the STe.

        ; Clear VRAM.
        MOVE.L D0, vram_address
        MOVE.L D0, A0
        MOVE.W #32000/4, D1
        MOVEQ #0, D0
.0:     MOVE.L D0, (A0)+
        DBF D1, .0

        ; Save TOS VBL, HBL vectors, interrupt settings.
        LEA old_vectors, A0
        MOVE.L hbl_vector, (A0)+
        MOVE.L vbl_vector, (A0)+
        MOVE.L timer_b_vector, (A0)+
        MOVE.B $FFFA07, (A0)+	; Timers.
        MOVE.B $FFFA09, (A0)+
        MOVE.B $FFFA15, (A0)+
        MOVE.B $FFFA17, (A0)+
        MOVE.B $FFFA19, (A0)+
        MOVE.B $FFFA1b, (A0)+
        MOVE.B $FFFA1f, (A0)+
        MOVE.B $FFFA21, (A0)+
        ; Setup our own vbl, hbl handlers (HBL not called by default).
        MOVE.L #raster_bars_vbl, vbl_vector
        MOVE.L #hbl_handler, hbl_vector

        BSR reset_sine_oscillator
        CLR.W scrolly_pos

        MOVE.W #$2300, SR      ; Unmask most interrupts.
        RTS


shutdown:
        MOVE.W #$2700, SR      ; Mask interrupts.

        MOVE.B saved_system_res, $FF8260   ; Restore shifter res.
        MOVEM.L saved_system_palette, D0-D7 ; Restore palette.
        MOVEM.L D0-D7, $FF8240

        ; Restore TOS VBL, timer B vectors.
        LEA old_vectors, A0
        MOVE.L (A0)+, hbl_vector
        MOVE.L (A0)+, vbl_vector
        MOVE.L (A0)+, timer_b_vector
        MOVE.B (A0)+, $FFFA07  ; Timers.
        MOVE.B (A0)+, $FFFA09
        MOVE.B (A0)+, $FFFA15
        MOVE.B (A0)+, $FFFA17
        MOVE.B (A0)+, $FFFA19
        MOVE.B (A0)+, $FFFA1b
        MOVE.B (A0)+, $FFFA1f
        MOVE.B (A0)+, $FFFA21

        MOVE.W #$2300, SR      ; Unmask interrupts.

        BSR ymamoto_reset       ; Mute YM.

        MOVE.B #%10010110, $FFFC00 ; Interrupts on, 8N1, clock/64.
.0:     BTST #1, $FFFC00       ; ACIA Tx buffer full?
        BEQ .0
        MOVE.B #8, $FFFC02     ; I suppose we'd better restore the mouse.
        RTS


 * Called each vertical blank.
raster_bars_vbl:
        MOVEM.L D0-D2/A0-A2, -(SP)

        MOVE.W #0, $FF8240     ; Black by default.
        MOVE.W #$FFFF, $FF8242 ; White text.

        ; Update sine values.
        BSR step_sine_oscillator

        ; Update positions of bars.
        MOVE.W sine, D0         ; Circular motion around X axis.
        ASR.W #2, D0
        MOVE.W D0, bar_a_z
        MOVE.W cosine, D0
        ASR.W #2, D0
        ADD.W #80, D0
        MOVE.W D0, bar_a_y

        MOVE.W sine, D0         ; Circular motion around X axis.
        ASR.W #2, D0
        ADD.W #20, D0
        MOVE.W D0, bar_b_z
        MOVE.W cosine, D0
        ASR.W #3, D0
        ADD.W #40, D0
        MOVE.W D0, bar_b_y

        ; Setup scanline/hblank routine.
        CLR.B $FFFA1B		; Disable timer B.
        MOVE.B bar_a_y+1, $FFFA21
        MOVE.L #scanline_bar_a, timer_b_vector
        MOVE.B #$18, $FFFA1B	; Enable timer B (event mode).
        BSET #0, $FFFA07	; intA enable timer B.
        BSET #0, $FFFA13	; intA mask, unmask timer B.

        MOVE.W bar_a_y, scanline
        MOVE.W #$310, next_palette_value

        ; Update scrolly.
        BSR update_scrolly

        ; Update music.
        LEA tune_data, A0
        BSR ymamoto_update

        MOVEM.L (SP)+, D0-D2/A0-A2
        RTE


hbl_handler:
        MOVE.W #$2300, SR      ; disable ourselves.
        RTE

scanline_bar_a:
        MOVE.W next_palette_value, $FF8240
        MOVEM.L D0-D2/A0, -(SP)
.0:     ; get delta of current scanline to initial y
        MOVE.W scanline, D0
        MOVE.W bar_a_y, D1
        SUB.W D1, D0            ; D0 = scanline - y_a
        MOVE.W bar_b_y, D1
        SUB.W D0, D1
        BLE .2

        CMP.W #40, D0
        BGE .1
        ; check Z, etc...
        BRA .2

.1:     ;MOVE.L #scanline_bar_b, timer_b_vector
        ;MOVE.B #0, $FFFA1B
        ;MOVE.B D1, $FFFA21
        ;MOVE.B #$18, $FFFA1B
        ;ADD.W D1, scanline
        ;BRA 3f

.2:     MOVE.B #0, $FFFA1B
        MOVE.B #4, $FFFA21
        MOVE.B #$18, $FFFA1B
        ADD.W #4, scanline

.3:     ; get color according to delta
        LSR.B #1, D0
        ADDQ.B #2, D0
        CMP.B #20, D0
        BLS .4
        MOVEQ #20, D0
.4:     LEA .5, A0
        MOVE.W (A0,D0), D1
        BRA .6
.5:      DC.W $310, $421, $421, $632, $632, $632, $632
        DC.W $421, $421, $310, 0
.6:     ; XXX modify by Z
        MOVE.W D1, next_palette_value

        MOVEM.L (SP)+, D0-D2/A0
        BCLR #0, $FFFA0F       ; Ack interrupt?
        RTE


        ; 1bpp scrolltext along middle of screen.
update_scrolly:
        ; XXX Test
        MOVE.L vram_address, A0
        ADD.W #11520, A0

        MOVE.W scrolly_pos, D0
        CMP.W #(scroll_text_len<<3), D0
        BLS .0
        CLR.W D0
        MOVE.W D0, scrolly_pos
.0      AND.B #$07, D0
        BNE .2

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
.1      MOVE.B (A1)+, (A2)+
        ADDQ.L #1, A2
        DBF D0, .1

.2:     MOVEQ #7, D0
        LEA scrolly_buffer, A1
.3:     LSL (A1)+
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
        DBF D0, .3

        ADD.W #1, scrolly_pos
        RTS

        GLOBAL plot_debug_dword
plot_debug_dword:
	MOVEM.L D0-D2/A0-A2, -(SP)
        LEA debug_string_buf, A2

        LEA hex_xlat, A1
        MOVEQ #8-1, D1
.0:     ROL.L #4, D0
        MOVE.B D0, D2
        AND.L #$f, D2
        MOVE.B (A1,D2), (A2)+
        DBF D1, .0
        MOVE.B #0, (A2)+
        LEA debug_string_buf, A2
        BSR plot_debug_string
	MOVEM.L (SP)+, D0-D2/A0-A2
        RTS


        ; A2 = address of string, NUL terminated.
plot_debug_string:
        MOVE.L vram_address, A0
.0:     MOVEQ #0, D0
        MOVE.B (A2)+, D0
        BEQ .1
        LEA one_bpp_font, A1
        LSL.W #3, D0
        ADD.W D0, A1
        MOVEQ #7, D0
.2:     MOVE.B (A1)+, (A0)
        ADD.W #160, A0
        DBF D0, .2
        SUB.W #1280, A0
        MOVE.L A0, D0
        BTST #0, D0
        BNE .3
        ADDQ.L #1, A0
        BRA .0
.3:     ADDQ.L #7, A0
        BRA .0
.1:     RTS


	section bss
        align 4
vram_address: ds.b 4
old_vectors: ds.b 20
saved_system_palette: ds.b 32
saved_system_res: ds.b 1
        even
scrolly_pos: ds.b 2
scrolly_buffer: ds.b 16
scanline: ds.w 1
bar_a_y: ds.w 1
bar_a_z: ds.w 1
bar_b_y: ds.w 1
bar_b_z: ds.w 1
next_palette_value: ds.w 1
debug_string_buf: ds.b 10

        section data
        align 4
tune_data: incbin "ch-1.bin"
one_bpp_font: incbin "readable.f08"
scroll_text: DC.B "The mandatory scrolltext...  tek speaking.  Yes, it's unbelievable that I'm so lazy that I didn't implement any cool effects in this scrolly.  I've been struggling with these damned MiNT cross-targetted binutils for the past two weeks -- I can never be sure whether the bugs are in my code or in the tools, because each available version of the binutils produces different eccentric behavior.  Next time, I'll have all this stuff fixed, and probably will have jettisoned these fucking binutils for a real assembler/linker.  Greets?  Of course.  Greets go out to the lonely St. John's scene, such as it is -- Retsyn, Michael (you need a new handle)...  uh, and how about all the people who were sceners in some sense but then disappeared...  off the top of my head I'm thinking of mr. nemo, jason, flyer, rubix...  Anyway.  Write more code!                 "
scroll_text_len = (. - scroll_text)
hex_xlat: DC.B "0123456789abcdef"
