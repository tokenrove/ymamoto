;;;
;;; YMamoto - a playback routine for the Atari ST
;;; Julian Squires / 2004
;;;
;;; See the README file for the broad strokes.
;;;
;;; TODO NEXT:
;;; * check alignment of everything, make sure it's correct.
;;; * make sure the way we're unpacking relative >>2 pointers works
;;;   properly for large pointers.
;;; * add volume envelopes.
;;; * add envelope-follow mode.
;;; * pitch affecting operations, like portamento and vibrato.
;;;
;;; NOTES FOR CODE READERS:
;;; 
;;; * The implementations of arpeggio effects and software volume
;;;   envelopes are almost identical; so if you find a bug in one,
;;;   please look for that bug in the other. ;-)
;;;

;;; CONSTANT SYMBOLS

number_of_channels = 3
;;; This playback /was/ dependant on this value, but now all durations
;;; are fixed cycles, so to change this, you should really just
;;; recompile the songs with mumble.  I don't think there's any reason
;;; this is here anymore, except to provide something to attach to
;;; this historical note.
playback_frequency = 50		; Hertz

	;; song data structure
song_data_arpeggio_pointer = 0
song_data_venv_pointer = 2
song_data_vibrato_pointer = 4
song_data_pad = 6
song_data_number_of_tracks = 7
song_data_track_ptrs = 8

	;; track data structure; repeats for each channel.
track_data_channel_ptr = 0

	;; arpeggio table structure
arpeggio_length = 0
arpeggio_loop = 1
arpeggio_data = 2

	;; volume envelope table structure
venv_length = 0
venv_loop = 1
venv_data = 2

	;; vibrato table structure
vibrato_length = 0		; not really necessary, but...
vibrato_delay = 1
vibrato_depth = 2
vibrato_speed = 3
vibrato_osc_mask = 4

	;; song status structure
song_current_track = 0
song_pad = 1
song_status_size = 2

	;; channel status structure
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
channel_vibrato_position = 16	; and 17
channel_vibrato = 18
channel_status_size = 20    ; I'd prefer to keep this a multiple of 4,
                            ; for easy wiping of the structure.

	;; channel state bits
channel_state_enabled = 0
channel_state_tone = 1		; tentative;
channel_state_noise = 2		; tentative;
channel_state_env_follow = 3	; will change;
channel_state_first_frame = 4	; tentative.


;;; FUNCTIONS

	ORG $8000

;;; Vectors for sc68.
	JMP ymamoto_init
	RTS
	JMP ymamoto_update
	RTS

;;; ymamoto_init (a0 = song pointer, d0 = track to setup.)
ymamoto_init:
	MOVEM.L D0-D1/A0-A2, -(A7)

	;; Reset YM.
	MOVEA.L #$FF8800, A1
	MOVE.B #7, (A1)
	MOVE.B #$FF, 2(A1)
	MOVE.B #8, (A1)
	MOVE.B #0, 2(A1)
	MOVE.B #9, (A1)
	MOVE.B #0, 2(A1)
	MOVE.B #$A, (A1)
	MOVE.B #0, 2(A1)

	;; FIXME verify that the supplied track is not out of bounds.

	;; setup pointers: channels for this track, tables.
	LEA song_status, A1
	MOVE.B D0, song_current_track(A1)

	;; setup each channel
	MOVEQ #number_of_channels-1, D0
.reset_channels:
	BSR reset_channel
	DBF D0, .reset_channels

.end:	
	MOVEM.L (A7)+, D0-D1/A0-A2
	RTS


;;; ymamoto_update: call once per frame, a0 = song pointer.
ymamoto_update:
	MOVEQ #0, D0
	JSR update_channel
	MOVEQ #1, D0
	JSR update_channel
	MOVEQ #2, D0
	JSR update_channel
	RTS


;;; update_channel: expects the song data pointer in A0, and the channel
;;; index in D0.
update_channel:
	MOVEM.L D1-D4/A0-A4, -(A7) ; save registers

	MOVE.L #$FF8800, A3

	;; load channel status ptr into A1
	LEA channel_status, A1
	MOVE.B D0, D1
	BEQ .channel_status_loaded
	SUBQ.B #1, D1
.next_channel_status:
	ADD #channel_status_size, A1
	DBEQ D1, .next_channel_status
.channel_status_loaded:

	BTST.B #channel_state_enabled, channel_state(A1)
	BEQ .end

	BCLR.B #channel_state_first_frame, channel_state(A1)

	;; decrement and check counter
	SUBQ.W #1, channel_counter(A1)
	BPL .update_playing_note


;;; Command processing.
	MOVEA.L channel_data_ptr(A1), A2
.load_new_command:
	MOVE.W (A2)+, D1
	BPL .process_new_note
	;; otherwise, this is a command.
	BTST #14, D1
	BEQ .global_command


	;; channel command
	MOVE.W D1, D2
	LSR.W #8, D2
	AND.B #$3F, D2
	CMP.B #command_jump_table_len, D2
	BGE .unknown_channel_command ; valid entries from 0 to c_j_t_len-1.
	LEA..command_jump_table, A4
	LSL.B #2, D2
	MOVEA.L (A4,D2), A4
	JMP (A4)
.command_jump_table:
	;; 0 -> reserved.
	DC.L .unknown_channel_command, .arpeggio_command
	;; 2 -> detune (reserved).
	DC.L .unknown_channel_command, .volume_command, .venv_command
	;; 6 -> AM sample playback (reserved); 7 -> hard env (reserved).
	DC.L .noise_command, .unknown_channel_command, .unknown_channel_command
	DC.L .env_follow_command, .pitch_env_command, .slur_command
	DC.L .vibrato_command
command_jump_table_len = (*-.command_jump_table)/4

.arpeggio_command:
	;; if the arp value in D1 is 0, disable arpeggiation.
	;; otherwise, set the arp bit in channel status.
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
	MOVE.B #4, channel_env_shift(A1) ; should be /16 by default.
	BTST.B #1, D1
	BEQ .load_new_command
	SUB.B #1, channel_env_shift(A1)	; Follow one octave lower.
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
	;; Just ignore it.
	BRA .load_new_command


.global_command:
	MOVE.W D1, D2
	AND.B #$7F, D2
	BNE .track_loop_command
	;; This is a track end command ($8000).  Mute this channel, set
	;; channel disable bit, and then end immediately.
	MOVEQ #7, D2
	MOVE.B D2, (A3)
	MOVE.B (A3), D2
	BSET D0, D2
	MOVE.B D2, 2(A3)
	BCLR.B #channel_state_enabled, channel_state(A1)
	BRA .end

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
	;; XXX unimplemented; just have to setup a vector to call on
	;; this command, or similar.
	BRA .load_new_command

.unknown_global_command:
	;; Just ignore it.
	BRA .load_new_command


.process_new_note:
	MOVE.W D1, D2
	ANDI.W #$FF, D2
	CMPI.B #95, D2
	BGT .special_note
	;; otherwise, we need to start playing a tone.
	BSET.B #channel_state_first_frame, channel_state(A1)
	BSET.B #channel_state_tone, channel_state(A1)
	MOVE.B D2, channel_current_note(A1)
	MOVE.B #0, channel_arp_position(A1) ; reset arpeggio.
	MOVE.B #0, channel_venv_position(A1) ; reset volume envelope.
	MOVE.W #0, channel_vibrato_position(A1)
	;; unmute this channel
	MOVEQ #7, D3
	MOVE.B D3, (A3)
	MOVE.B (A3), D3
	BCLR D0, D3
	MOVE.B D3, 2(A3)
	BRA .calculate_duration

.special_note:
	CMPI.B #126, D2		; Is it a wait (as opposed to a rest)?
	BEQ .calculate_duration

	BCLR.B #channel_state_tone, channel_state(A1)
	MOVEQ #7, D2
	MOVE.B D2, (A3)
	MOVE.B (A3), D2
	BSET D0, D2		; Mute channel.
	MOVE.B D2, 2(A3)

.calculate_duration:
	LSR.W #8, D1
	MOVE.W D1, channel_counter(A1)

.update_channel_data_ptr:
	MOVE.L A2, channel_data_ptr(A1)


;;; Effects processing.
	;; The note value is loaded from channel status, and effects
	;; which have an effect at a chromatic tone level are
	;; processed, first (arpeggios).  Then the frequency is looked
	;; up, and effects which change the raw frequency (portamento)
	;; are processed.  Finally any other effects (venv, hard
	;; envelope) are processed.
.update_playing_note:
	BTST.B #channel_state_tone, channel_state(A1)
	BEQ .end
	MOVE.B channel_current_note(A1), D3
	MOVEQ #0, D1

	;;; Note value effects.

.update_arpeggio:		; Arpeggios.
	MOVE.B channel_arpeggio(A1), D1
	BEQ .lookup_frequency	; ... or next effect, if there is one.
	MOVE.W song_data_arpeggio_pointer(A0), D2
	BSR load_table_entry
	MOVE.B channel_arp_position(A1), D2
	;; load length; if arp position greater than length,
	;; reset to loop point.
	MOVE.B arpeggio_length(A2), D1
	CMP.B D2, D1
	BGT .arp_update_note
	MOVE.B arpeggio_loop(A2), D2
.arp_update_note:
	;; load arp delta, update playing note.
	MOVE.B arpeggio_data(A2,D2), D1
	ADD.B D1, D3
	MOVE.B D3, channel_current_note(A1)
	;; update arp position.
	ADDQ #1, D2
	MOVE.B D2, channel_arp_position(A1)


	;;; Frequency value effects.
.lookup_frequency:
	LEA note_to_ymval_xlate, A2
	ADD.W D3,D3
	MOVE.W (A2,D3), D3

.update_vibrato:
	MOVE.B channel_vibrato(A1), D1
	BEQ .update_hw_envelope
	MOVE.W song_data_vibrato_pointer(A0), D2
	BSR load_table_entry
	;; always update position
	ADD.W #1, channel_vibrato_position(A1)
	MOVE.W channel_vibrato_position(A1), D2

	MOVEQ #0, D4
	MOVE.B vibrato_delay(A2), D4
	SUB.W D4, D2
	BMI .update_hw_envelope ; Next effect.

	;; vibrato freq = ((frequency*2^1/12 - frequency)/2)/depth
	;; Note that 1/(2^1/12) is pretty close to 16.
	;; This can be approximated with (frequency>>4)/depth or so.
	MOVE.W D3, D1
	MOVEQ #8, D4
	CMP.B vibrato_depth(A2), D4
	BEQ .vibrato_oscillator
	SUB.B vibrato_depth(A2), D4 ; Could replace this division with
	LSL.B #2, D4		; something more clever -- note that the
	DIVU.W D4, D1		; divisor is (8-depth)*4.

	;; low n bits of position are our oscillator. (This classic trick
	;; stolen from Rob Hubbard!)
.vibrato_oscillator:
	MOVE.B vibrato_osc_mask(A2), D4
	SUBQ #1, D4
	AND.W D4, D2		; (2^speed)-1
	ADDQ #1, D4
	LSR.B #1, D4
	CMP.B D4, D2		; 2^(speed-1)
	BCC .vo_l1
	LSL.B #1, D4
	SUBQ #1, D4
	EOR.B D4, D2		; (2^speed)-1
.vo_l1:	CMP.W #0, D2
	BEQ .vo_l2
	MOVE.W D1, D4
	MULU.W D2, D4		; Add vibrato frequency <oscillator> times.
	LSR.L #4, D4		; Vibrato is a 12.4 fixed point fraction.
	SUB.W D4, D3
.vo_l2:	MOVE.B vibrato_speed(A2), D4
	SUB.B #1, D4
	LSL.L D4, D1
	LSR.L #4, D1		; Center the vibrato.  Might not be
	ADD.W D1, D3		; necessary.

.update_hw_envelope:
	BTST.B #channel_state_env_follow, channel_state(A1)
	BEQ .set_frequency	; ... or next effect.
	MOVE.W D3, D1		; D1 <- current frequency.
	MOVE.B channel_env_shift(A1), D2
	LSR.W D2, D1

	MOVE.B #$B, (A3)	; Env fine adjustment.
	MOVE.B D1, 2(A3)
	MOVE.B #$C, (A3)	; Env rough adjustment.
	LSR.W #8, D1
	MOVE.B D1, 2(A3)
	BTST.B #channel_state_first_frame, channel_state(A1)
	BEQ .set_frequency	; only update on first frame of note.
	MOVE.B #$D, (A3)	; Env shape.
	MOVE.B #$8, 2(A3)	; CONT

.set_frequency:
	MOVEQ #0, D1
	ADD.B D0, D1
	ADD.B D0, D1
	MOVE.B D1, (A3)
	MOVE.B D3, 2(A3)

	LSR.L #8, D3
	MOVEQ #1, D1
	ADD.B D0, D1
	ADD.B D0, D1
	MOVE.B D1, (A3)
	MOVE.B D3, 2(A3)


	;; Volume effects.
.lookup_volume:
	MOVE.B channel_current_volume(A1), D3

.update_venv:			; Soft volume envelope.
	MOVE.B channel_volume_envelope(A1), D1
	BEQ .set_volume		; ... or next effect, if there is one.
	MOVE.W song_data_venv_pointer(A0), D2
	BSR load_table_entry
	MOVE.B channel_venv_position(A1), D2
	MOVE.B venv_length(A2), D1 ; Load length.
	CMP.B D2, D1		   ; If position greater than length,
	BGT .venv_update_note
	MOVE.B venv_loop(A2), D2   ; ... reset to loop point.
.venv_update_note:
	MOVE.B venv_data(A2,D2), D3 ; Note that this might become
	ADDQ #1, D2		    ; relative someday soon.
	MOVE.B D2, channel_venv_position(A1)

.set_volume:
	MOVEQ #8, D1
	ADD.B D0, D1
	MOVE.B D1, (A3)
	BTST.B #channel_state_env_follow, channel_state(A1)
	BEQ .store_volume
	OR.B #$10, D3		; Envelope on.
.store_volume:
	MOVE.B D3, 2(A3)


;;; End of main playroutine.
.end:	
	MOVEM.L (A7)+, D1-D4/A0-A4 ; restore registers
	RTS
;;;


	;; Takes D0 = channel number, A0 = song ptr.
reset_channel:
	MOVEM.L D0-D1/A0-A2, -(A7) ; save registers

	;; load appropriate track address.
	LEA song_status, A1
	MOVEQ #0, D1
	MOVE.B song_current_track(A1), D1
	SUBQ.W #1, D1
	LSL.B #1, D1
	MOVE.W song_data_track_ptrs(A0,D1), D1
	ASL.W #2, D1		; XXX: should be .L?
	LEA.L track_data_channel_ptr(A0,D1), A2

	;; load appropriate channel status structure.
	LEA channel_status, A1
.l1:	CMP #0, D0
	BEQ .l2
	ADD #channel_status_size, A1 ; next channel status.
	ADD #2, A2		; next channel pointer.
	DBF D0, .l1
.l2:

	;; wipe channel status structure first.
	MOVE.L D0, 0(A1)
	MOVE.L D0, 4(A1)
	MOVE.L D0, 8(A1)
	MOVE.L D0, 12(A1)
	MOVE.L D0, 16(A1)

	;; setup data pointer.
	MOVE.W (A2), D0
	ASL.W #2, D0
	ADD.L A0, D0
	MOVE.L D0, channel_data_ptr(A1)

	;; enable channel.
	BSET.B #channel_state_enabled, channel_state(A1)

	MOVEM.L (A7)+, D0-D1/A0-A2 ; restore registers
	RTS

;;; Generic routine for loading values from tables of form
;;; num_entries:byte
;;; entry_length:byte, entry_data:(length+1 bytes)
;;; Takes D1 -> record idx, D2 -> packed pointer to table,
;;;       A0 -> song data.
;;; Returns pointer to record in A2.  Modifies D1,D2,A2.
load_table_entry:
	ASL.W #2, D2
	MOVE.W D2, A2
	MOVE A0, D2
	ADD.L D2, A2
	MOVEQ #0, D2
	ADDQ #1, A2		; skip length of table.
	;; find our entry in the table.
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


;;; CONSTANT TABLES
	ALIGN 2
note_to_ymval_xlate:
	DC.W $EEE,$E18,$D4D,$C8E,$BDA,$B2F,$A8F,$9F7,$968,$8E1,$861,$7E9
	DC.W $777,$70C,$6A7,$647,$5ED,$598,$547,$4FC,$4B4,$470,$431,$3F4
	DC.W $3BC,$386,$353,$324,$2F6,$2CC,$2A4,$27E,$25A,$238,$218,$1FA
	DC.W $1DE,$1C3,$1AA,$192,$17B,$166,$152,$13F,$12D,$11C,$10C,$FD
	DC.W $EF,$E1,$D5,$C9,$BE,$B3,$A9,$9F,$96,$8E,$86,$7F
	DC.W $77,$71,$6A,$64,$5F,$59,$54,$50,$48,$47,$43,$3F
	DC.W $3C,$38,$35,$32,$2F,$2D,$2A,$28,$26,$24,$22,$20
	DC.W $1E,$1C,$1B,$19,$18,$16,$15,$14,$13,$11,$10,$0F


;;; GLOBAL VARIABLES
	BSS

	ALIGN 2
song_status:	DS.B song_status_size
	ALIGN 2
channel_status:	DS.B channel_status_size*number_of_channels

;;; EOF