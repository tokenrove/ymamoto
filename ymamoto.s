/*
 * YMamoto - a playback routine for the Atari ST
 * Julian Squires / 2004
 *
 * See the README file for the broad strokes.
 * 
 * TODO NEXT:
 * * check alignment of everything, make sure it's correct.
 * * make sure the way we're unpacking relative >>2 pointers works
 *   properly for large pointers.
 * * add hw-envelope envelopes/macros.
 * * portamento/slur/glissando.
 * * noise support.
 * * AM sample support.
 * 
 * NOTES FOR CODE READERS:
 *  
 * * The implementations of arpeggio effects and software volume
 *   envelopes are almost identical; so if you find a bug in one,
 *   please look for that bug in the other. ;-)
 */

|  CONSTANT SYMBOLS

number_of_channels = 3
/* This playback /was/ dependant on this value, but now all durations
 * are fixed cycles, so to change this, you should really just
 * recompile the songs with mumble.  I don't think there's any reason
 * this is here anymore, except to provide something to attach to
 * this historical note. */
playback_frequency = 50		| Hertz

	|| song data structure
song_data_arpeggio_pointer = 0
song_data_venv_pointer = 2
song_data_vibrato_pointer = 4
song_data_pad = 6
song_data_number_of_tracks = 7
song_data_track_ptrs = 8

	|| track data structure; repeats for each channel.
track_data_channel_ptr = 0

	|| arpeggio table structure
arpeggio_length = 0
arpeggio_loop = 1
arpeggio_data = 2

	|| volume envelope table structure
venv_length = 0
venv_loop = 1
venv_data = 2

	|| vibrato table structure
vibrato_length = 0		| not really necessary, but...
vibrato_delay = 1
vibrato_depth = 2
vibrato_speed = 3
vibrato_osc_mask = 4

	|| song status structure
song_current_track = 0
song_registers_to_write = 1
song_ym_shadow = 2  | to 15.. we don't touch the IO registers.
song_status_size = 16

	|| channel status structure
channel_counter = 0
channel_data_ptr = 2
channel_state = 6
channel_arpeggio = 7
channel_arp_position = 8
channel_current_note = 9
channel_current_volume = 10
channel_volume_envelope = 11
channel_venv_position = 12
channel_pitch_envelope = 13
channel_pitchenv_position = 14
channel_env_shift = 15
channel_vibrato_position = 16	| and 17
channel_vibrato = 18
channel_status_size = 20    | I'd prefer to keep this a multiple of 4,
                            | for easy wiping of the structure.

	|| channel state bits
channel_state_enabled = 0
channel_state_tone = 1		| tentative;
channel_state_noise = 2		| tentative;
channel_state_env_follow = 3	| will change;
channel_state_first_frame = 4	| tentative.


| FUNCTIONS

        .global ymamoto_init
        .global ymamoto_reset
        .global ymamoto_update
        .text

| ymamoto_init (a0 = song pointer, d0 = track to setup.)
ymamoto_init:
	MOVEM.L D0-D1/A0-A2, -(A7)

        JSR ymamoto_reset

	|| FIXME verify that the supplied track is not out of bounds.

	|| setup pointers: channels for this track, tables.
	LEA song_status, A1
	MOVE.B D0, song_current_track(A1)

	|| setup YM shadow registers.
	MOVEQ #0, D1
	MOVE.L D1, song_ym_shadow(A1)
	MOVE.L D1, song_ym_shadow+4(A1)
	MOVE.L D1, song_ym_shadow+8(A1)
	MOVE.W D1, song_ym_shadow+12(A1)
	MOVE.B #0xFF, song_ym_shadow+7(A1) | mixer.

	|| setup each channel
	MOVEQ #number_of_channels-1, D0
.reset_channels:
	BSR reset_channel
	DBF D0, .reset_channels

	MOVEM.L (A7)+, D0-D1/A0-A2
	RTS


/* Sets up the YM with some sane values so that when we leave,
 * we don't have horrible screaming chip noise. */
ymamoto_reset:
	|| Reset YM.
	MOVEA.L #0xFF8800, A1
	MOVE.B #7, 0xFF8800
	MOVE.B #0xFF, 0xFF8802
	MOVE.B #8, 0xFF8800
	MOVE.B #0, 0xFF8802
	MOVE.B #9, 0xFF8800
	MOVE.B #0, 0xFF8802
	MOVE.B #0xA, 0xFF8800
	MOVE.B #0, 0xFF8802
        RTS


|| ymamoto_update: call once per frame, a0 = song pointer.
ymamoto_update:
	MOVEM.L D0-D6/A0-A1, -(A7)
	LEA song_status, A1
	MOVE.B #13-1, song_registers_to_write(A1)

	MOVEQ #0, D0
	JSR update_channel
	MOVEQ #1, D0
	JSR update_channel
	MOVEQ #2, D0
	JSR update_channel

	MOVE.B song_registers_to_write(A1), D0
	MOVEQ #0, D1
	MOVEQ #0, D2
	LEA song_ym_shadow(A1), A1
	MOVEA.L #0xFF8800, A0
.write_ym_registers:
	MOVE.B 0(A1,D1), D2
	MOVE.B D1, (A0)
	MOVE.B D2, 2(A0)
	ADDQ #1, D1
	DBF D0, .write_ym_registers

	MOVEM.L (A7)+, D0-D6/A0-A1
	RTS


/* update_channel: expects the song data pointer in A0, and the channel
 * index in D0. */
update_channel:
	MOVEM.L A0-A4, -(A7)  | save registers... don't bother with Dx
			      | because they're saved in ymamoto_update. 

	LEA song_status, A1
	LEA song_ym_shadow(A1), A3

        MOVEQ #0, D1        | This is a workaround for uncaught bugs
        MOVEQ #0, D2        | below.
        MOVEQ #0, D3
        MOVEQ #0, D4

	|| load channel status ptr into A1
	LEA channel_status, A1
	MOVE.B D0, D1
	BEQ .channel_status_loaded
	SUBQ.B #1, D1
.next_channel_status:
	ADD #channel_status_size, A1
	DBEQ D1, .next_channel_status
.channel_status_loaded:

	BTST.B #channel_state_enabled, channel_state(A1)
	BEQ .update_end

	BCLR.B #channel_state_first_frame, channel_state(A1)

	|| decrement and check counter
	SUBQ.W #1, channel_counter(A1)
	BPL .update_playing_note


| Command processing.
	MOVEA.L channel_data_ptr(A1), A2
.load_new_command:
	MOVE.W (A2)+, D1
	BPL .process_new_note
	|| otherwise, this is a command.
	BTST #14, D1
	BEQ .global_command


	|| channel command
	MOVE.W D1, D2
	LSR.W #8, D2
	AND.B #0x3F, D2
	CMP.B #command_jump_table_len, D2
	BGE .unknown_channel_command | valid entries from 0 to c_j_t_len-1.
	LEA .command_jump_table, A4
	LSL.B #2, D2
	MOVEA.L (A4,D2), A4
	JMP (A4)
.command_jump_table:
	|| 0 -> reserved.
	DC.L .unknown_channel_command, .arpeggio_command
	|| 2 -> detune (reserved).
	DC.L .unknown_channel_command, .volume_command, .venv_command
	|| 6 -> AM sample playback (reserved)| 7 -> hard env (reserved).
	DC.L .noise_command, .unknown_channel_command, .unknown_channel_command
	DC.L .env_follow_command, .pitch_env_command, .slur_command
	DC.L .vibrato_command
command_jump_table_len = (. - .command_jump_table)/4

.arpeggio_command:
	|| if the arp value in D1 is 0, disable arpeggiation.
	|| otherwise, set the arp bit in channel status.
	MOVE.B D1, channel_arpeggio(A1)
	MOVE.B #0, channel_arp_position(A1)
	BRA .load_new_command

.volume_command:
	MOVE.B D1, channel_current_volume(A1)
	BRA .load_new_command

.venv_command:
	MOVE.B D1, channel_volume_envelope(A1)
	MOVE.B #0, channel_venv_position(A1)
	BRA .load_new_command

.noise_command:
	BRA .load_new_command

.env_follow_command:
	BTST.B #0, D1
	BEQ .disable_env_follow
	BSET.B #channel_state_env_follow, channel_state(A1)
	MOVE.B #4, channel_env_shift(A1) | should be /16 by default.
	BTST.B #1, D1
	BEQ .load_new_command
	SUB.B #1, channel_env_shift(A1)	| Follow one octave lower.
	BRA .load_new_command
.disable_env_follow:
	BCLR.B #channel_state_env_follow, channel_state(A1)
	BRA .load_new_command

.pitch_env_command:
	BRA .load_new_command

.slur_command:
	BRA .load_new_command

.vibrato_command:
	MOVE.B D1, channel_vibrato(A1)
	MOVE.W #0, channel_vibrato_position(A1)
	BRA .load_new_command

.unknown_channel_command:
	|| Just ignore it.
	BRA .load_new_command


.global_command:
	MOVE.W D1, D2
	AND.B #0x7F, D2
	BNE .track_loop_command
	|| This is a track end command (0x8000).  Mute this channel, set
	|| channel disable bit, and then end immediately.
	MOVE.B 7(A3), D2
	BSET D0, D2
	MOVE.B D2, 7(A3)
	BCLR.B #channel_state_enabled, channel_state(A1)
	BRA .update_end

.track_loop_command:
	CMP.B #1, D2
	BNE .trigger_command
	BSR reset_channel
	MOVEQ #0, D2
	MOVE.W (A2)+, D2
	ADD.W D2, D2
	ADD.L D2, channel_data_ptr(A1)
	MOVEA.L channel_data_ptr(A1), A2
	BRA .load_new_command

.trigger_command:
	CMP.B #2, D2
	BNE .unknown_global_command
	|| XXX unimplemented; just have to setup a vector to call on
	|| this command, or similar.
	BRA .load_new_command

.unknown_global_command:
	|| Just ignore it.
	BRA .load_new_command


.process_new_note:
	MOVE.W D1, D2
	ANDI.W #0xFF, D2
	CMPI.B #95, D2
	BGT .special_note
	|| otherwise, we need to start playing a tone.
	BSET.B #channel_state_first_frame, channel_state(A1)
	BSET.B #channel_state_tone, channel_state(A1)
	MOVE.B D2, channel_current_note(A1)
	MOVE.B #0, channel_arp_position(A1) | reset arpeggio.
	MOVE.B #0, channel_venv_position(A1) | reset volume envelope.
	MOVE.W #0, channel_vibrato_position(A1)
	|| unmute this channel
	MOVE.B 7(A3), D3
	BCLR D0, D3
	MOVE.B D3, 7(A3)
	BRA .calculate_duration

.special_note:
	CMPI.B #126, D2		| Is it a wait (as opposed to a rest)?
	BEQ .calculate_duration

	BCLR.B #channel_state_tone, channel_state(A1)
	MOVEQ #7, D2
	MOVE.B 7(A3), D2
	BSET D0, D2		| Mute channel.
	MOVE.B D2, 7(A3)

.calculate_duration:
	LSR.W #8, D1
	MOVE.W D1, channel_counter(A1)

.update_channel_data_ptr:
	MOVE.L A2, channel_data_ptr(A1)


        /* Effects processing.
         *
	 * The note value is loaded from channel status, and effects
	 * which have an effect at a chromatic tone level are
	 * processed, first (arpeggios).  Then the frequency is looked
	 * up, and effects which change the raw frequency (portamento)
	 * are processed.  Finally any other effects (venv, hard
	 * envelope) are processed.
         */
.update_playing_note:
	BTST.B #channel_state_tone, channel_state(A1)
	BEQ .update_end
	MOVE.B channel_current_note(A1), D3
	MOVEQ #0, D1

	| Note value effects.

.update_arpeggio:		| Arpeggios.
	MOVE.B channel_arpeggio(A1), D1
	BEQ .lookup_frequency	| ... or next effect, if there is one.
	MOVE.W song_data_arpeggio_pointer(A0), D2
	BSR load_table_entry
	MOVE.B channel_arp_position(A1), D2
	|| load length| if arp position greater than length,
	|| reset to loop point.
	MOVE.B arpeggio_length(A2), D1
	CMP.B D2, D1
	BGT .arp_update_note
	MOVE.B arpeggio_loop(A2), D2
.arp_update_note:
	|| load arp delta, update playing note.
	MOVE.B arpeggio_data(A2,D2), D1
	ADD.B D1, D3
	MOVE.B D3, channel_current_note(A1)
	|| update arp position.
	ADDQ #1, D2
	MOVE.B D2, channel_arp_position(A1)


	| Frequency value effects.
.lookup_frequency:
	LEA note_to_ymval_xlate, A2
	ADD.W D3,D3
	MOVE.W (A2,D3), D3

.update_vibrato:
	MOVE.B channel_vibrato(A1), D1
	BEQ .update_hw_envelope
	MOVE.W song_data_vibrato_pointer(A0), D2
	BSR load_table_entry
	|| always update position
	ADD.W #1, channel_vibrato_position(A1)
	MOVE.W channel_vibrato_position(A1), D2

	MOVEQ #0, D4
	MOVE.B vibrato_delay(A2), D4
	SUB.W D4, D2
	BMI .update_hw_envelope | Next effect.

	|| vibrato freq = ((frequency*2^1/12 - frequency)/2)/depth
	|| Note that 1/((2^1/12)-1) is pretty close to 16, so this can be
	|| approximated with (frequency>>4)/depth or so.  Because this
	|| value can get quite small, we represent the vibrato frequency
	|| as a 12.4 fixed point fraction.
	MOVE.W D3, D1
	MOVEQ #8, D4
	CMP.B vibrato_depth(A2), D4
	BEQ .vibrato_oscillator
	SUB.B vibrato_depth(A2), D4 | Could replace this division with
	LSL.B #2, D4		| something more clever -- note that the
	DIVU.W D4, D1		| divisor is (8-depth)*4.

	|| low n bits of position are our oscillator. (This classic trick
	|| stolen from Rob Hubbard... except he used a fixed-frequency
	|| oscillator.)
.vibrato_oscillator:
	MOVE.B vibrato_osc_mask(A2), D4
	SUBQ #1, D4
	AND.W D4, D2		| AND (2^speed)-1
	ADDQ #1, D4
	LSR.B #1, D4
	CMP.B D4, D2		| CMP 2^(speed-1)
	BCC 0f
	LSL.B #1, D4
	SUBQ #1, D4
	EOR.B D4, D2		| XOR (2^speed)-1

0:	MOVE.W D1, D4
	MULU.W D2, D4		| Add vibrato frequency <oscillator> times.
	LSR.L #4, D4		| Fixup vibrato fraction.
	SUB.W D4, D3

	MOVE.B vibrato_speed(A2), D4
	LSL.L D4, D1		| (frq << (speed-1)) >> 4... it's safe for
	LSR.L #5, D1		| us to simplify this to (frq<<speed)>>5.
	ADD.W D1, D3		| Center the vibrato.

.update_hw_envelope:
	BTST.B #channel_state_env_follow, channel_state(A1)
	BEQ .set_frequency	| ... or next effect.
        BRA .set_frequency      | XXX QUICKFIX
	MOVE.W D3, D1		| D1 <- current frequency.
	MOVE.B channel_env_shift(A1), D2
	LSR.W D2, D1

	MOVE.B D1, 0xB(A3)	| Env fine adjustment.
	LSR.W #8, D1
	MOVE.B D1, 0xC(A3)	| Env rough adjustment.
	BTST.B #channel_state_first_frame, channel_state(A1)
	BEQ .set_frequency	| only update on first frame of note.
	MOVE.B #0xE, 0xD(A3)	| Env shape: CONT|ATT|ALT
	LEA song_status, A2
	MOVE.B #14-1, song_registers_to_write(A2)

.set_frequency:
	MOVEQ #0, D1
	ADD.B D0, D1
	ADD.B D0, D1
	MOVE.B D3, (A3,D1)

	LSR.L #8, D3
	MOVEQ #1, D1
	ADD.B D0, D1
	ADD.B D0, D1
	MOVE.B D3, (A3,D1)


	|| Volume effects.
.lookup_volume:
	MOVE.B channel_current_volume(A1), D3

.update_venv:			| Soft volume envelope.
	MOVE.B channel_volume_envelope(A1), D1
	BEQ .set_volume		| ... or next effect, if there is one.
	MOVE.W song_data_venv_pointer(A0), D2
	BSR load_table_entry
	MOVE.B channel_venv_position(A1), D2
	MOVE.B venv_length(A2), D1 | Load length.
	CMP.B D2, D1		   | If position greater than length,
	BGT .venv_update_note
	MOVE.B venv_loop(A2), D2   | ... reset to loop point.
.venv_update_note:
	MOVE.B venv_data(A2,D2), D3 | Note that this might become
	ADDQ #1, D2		    | relative someday soon.
	MOVE.B D2, channel_venv_position(A1)

.set_volume:
	BTST.B #channel_state_env_follow, channel_state(A1)
	BEQ .store_volume
        BRA .store_volume       | XXX: QUICKFIX
	OR.B #0x10, D3		| Envelope on.
.store_volume:
	MOVE.B D3, 8(A3,D0)

.update_end:	
	MOVEM.L (A7)+, A0-A4 | restore registers
	RTS
/* End of main playroutine. */


	|| Takes D0 = channel number, A0 = song ptr.
reset_channel:
	MOVEM.L D0-D1/A0-A2, -(A7) | save registers

	|| load appropriate track address.
	LEA song_status, A1
	MOVEQ #0, D1
	MOVE.B song_current_track(A1), D1
	SUBQ.W #1, D1
	LSL.B #1, D1
	MOVE.W song_data_track_ptrs(A0,D1), D1
	ASL.W #2, D1		| XXX: should be .L?
	LEA.L track_data_channel_ptr(A0,D1), A2

	|| load appropriate channel status structure.
	LEA channel_status, A1
.l1:	CMP #0, D0
	BEQ .l2
	ADD #channel_status_size, A1 | next channel status.
	ADD #2, A2		| next channel pointer.
	DBF D0, .l1
.l2:

	|| wipe channel status structure first.
	MOVE.L D0, 0(A1)
	MOVE.L D0, 4(A1)
	MOVE.L D0, 8(A1)
	MOVE.L D0, 12(A1)
	MOVE.L D0, 16(A1)

	|| setup data pointer.
	MOVE.W (A2), D0
	ASL.W #2, D0
	ADD.L A0, D0
	MOVE.L D0, channel_data_ptr(A1)

	|| enable channel.
	BSET.B #channel_state_enabled, channel_state(A1)

	MOVEM.L (A7)+, D0-D1/A0-A2 | restore registers
	RTS


/* Generic routine for loading values from tables of form
 * num_entries:byte
 * entry_length:byte, entry_data:(length+1 bytes)
 * Takes D1 -> record idx, D2 -> packed pointer to table,
 *       A0 -> song data.
 * Returns pointer to record in A2.  Modifies D1,D2,A2. */
load_table_entry:
	ASL.W #2, D2
	MOVE.W D2, A2
	MOVE A0, D2
	ADD.L D2, A2
	MOVEQ #0, D2
	ADDQ #1, A2		| skip length of table.
	|| find our entry in the table.
	SUBQ #1, D1
	BEQ .lookup_finished
	SUBQ #1, D1
.next_entry:
	MOVE.B (A2), D2
	ADDQ #2, D2
	ADD D2, A2
	DBF D1, .next_entry
.lookup_finished:
	RTS

	.data

| CONSTANT TABLES
	ALIGN 2
note_to_ymval_xlate:
	DC.W 0xEEE,0xE18,0xD4D,0xC8E,0xBDA,0xB2F,0xA8F,0x9F7,0x968,0x8E1,0x861,0x7E9
	DC.W 0x777,0x70C,0x6A7,0x647,0x5ED,0x598,0x547,0x4FC,0x4B4,0x470,0x431,0x3F4
	DC.W 0x3BC,0x386,0x353,0x324,0x2F6,0x2CC,0x2A4,0x27E,0x25A,0x238,0x218,0x1FA
	DC.W 0x1DE,0x1C3,0x1AA,0x192,0x17B,0x166,0x152,0x13F,0x12D,0x11C,0x10C,0xFD
	DC.W 0xEF,0xE1,0xD5,0xC9,0xBE,0xB3,0xA9,0x9F,0x96,0x8E,0x86,0x7F
	DC.W 0x77,0x71,0x6A,0x64,0x5F,0x59,0x54,0x50,0x48,0x47,0x43,0x3F
	DC.W 0x3C,0x38,0x35,0x32,0x2F,0x2D,0x2A,0x28,0x26,0x24,0x22,0x20
	DC.W 0x1E,0x1C,0x1B,0x19,0x18,0x16,0x15,0x14,0x13,0x11,0x10,0x0F


| GLOBAL VARIABLES
|       Don't put these in BSS!  The sc68 replay will be broken.

	ALIGN 2
song_status:	DS.B song_status_size
	ALIGN 2
channel_status:	DS.B channel_status_size*number_of_channels
        DS.B channel_status_size

| vim:syn=gnuas68k
