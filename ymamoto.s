;;;
;;; YMamoto - a playback routine for the Atari ST
;;; Julian Squires / 2004
;;;
;;; See the README file for the broad strokes.
;;;

;;; CONSTANT SYMBOLS

number_of_channels = 3
base_tempo = 140		; Beats Per Minute
playback_frequency = 50		; Hertz

	;; song data structure
song_data_number_of_tracks = 0
song_data_track_ptrs = 1

	;; track data structure
track_data_channel_ptrs = 0
track_data_tempo = 4*number_of_channels

	;; song status structure
song_current_track = 0
song_current_tempo = 1
song_whole_note_length = 3
song_status_size = 5

	;; channel status structure
channel_counter = 0
channel_data_ptr = 2
channel_status_size = 6

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
	MOVE.B #7, (A3)
	MOVE.B #$FF, 2(A3)
	MOVE.B #8, (A3)
	MOVE.B #0, 2(A3)
	MOVE.B #9, (A3)
	MOVE.B #0, 2(A3)
	MOVE.B #$A, (A3)
	MOVE.B #0, 2(A3)

	;; FIXME verify that the supplied track is not out of bounds.

	;; setup pointers: channels for this track, tables.
	LEA song_status, A1
	MOVE.B D0, song_current_track(A1)
	SUBQ.W #1, D0		; (track_no - 1)*4 = offset in
	LSL.W #2, D0		; pointer table.
	MOVEA.L A0, A2
	ADD.L song_data_track_ptrs(A0,D0), A2 ; ptr relative to song data.

	;; set initial tempo
	MOVE.B track_data_tempo(A2), D0
	JSR set_tempo

	;; setup each channel
	LEA channel_status, A1
	LEA.L track_data_channel_ptrs(A2), A2
	MOVEQ #number_of_channels-1, D1
	MOVE.L A0,D0
.reset_channel:
	CLR channel_counter(A1)
	MOVE.L (A2)+, channel_data_ptr(A1)
	ADD.L D0, channel_data_ptr(A1) ; Make relative ptr absolute.
	ADDQ #channel_status_size, A1
	DBEQ D1, .reset_channel

.end:	
	MOVEM.L (A7)+, D0-D1/A0-A2
	RTS


;;; ymamoto_update: call once per frame, a0 = song pointer.  Returns
;;; d0 = $ffff if the song has finished, 0 otherwise.
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
	MOVEM.L D0-D2/A0-A3, -(A7) ; save registers

	MOVE.L #$FF8800, A3

	;; load channel status ptr into A1
	LEA channel_status, A1
	MOVE.B D0, D1
	BEQ .channel_status_loaded
	SUBQ.B #1, D1
.next_channel_status:
	ADDQ #channel_status_size, A1
	DBEQ D1, .next_channel_status
.channel_status_loaded:

	;; decrement and check counter
	SUBQ.W #1, channel_counter(A1)
	BPL .update_playing_note

.load_new_command:
	MOVEA.L channel_data_ptr(A1), A2
	MOVE.W (A2)+, D1
	BPL .process_new_note
	;; otherwise, this is a command.
	;JSR handle_command
	BRA .end
	BRA .load_new_command

.process_new_note:
	MOVE.W D1, D2
	ANDI.W #$FF, D2
	CMPI.B #95, D2
	BGT .special_note
	;; otherwise, we need to start playing a tone.
	MOVEM.L D1/A1, -(A7)
	LEA note_to_ymval_xlate, A1
	LSL.B #1, D2
	MOVE.W (A1,D2), D2
	MOVEQ #0, D1
	ADD.B D0, D1
	ADD.B D0, D1
	MOVE.B D1, (A3)
	MOVE.B D2, 2(A3)

	LSR.L #8, D2
	MOVEQ #1, D1
	ADD.B D0, D1
	ADD.B D0, D1
	MOVE.B D1, (A3)
	MOVE.B D2, 2(A3)

	MOVEQ #8, D1
	ADD.B D0, D1
	MOVE.B D1, (A3)
	MOVE.B #$08, 2(A3)

	;; unmute this channel
	MOVEQ #7, D1
	MOVE.B D1, (A3)
	MOVE.B (A3), D1
	BCLR D0, D1
	MOVE.B D1, 2(A3)

	MOVEM.L (A7)+, D1/A1
	BRA .calculate_duration

.special_note:
	CMPI.B #126, D2		; Is it a wait (as opposed to a rest)?
	BEQ .calculate_duration
	;; Read current mixer setting and mute.
	MOVEQ #7, D1
	MOVE.B D1, (A3)
	MOVE.B (A3), D1
	BSET D0, D1
	MOVE.B D1, 2(A3)

.calculate_duration:
	JSR calculate_duration
	MOVE.W D1, channel_counter(A1)

.update_channel_data_ptr:
	MOVE.L A2, channel_data_ptr(A1)

.update_playing_note:
	;; update effects

.end:	
	MOVEM.L (A7)+, D0-D2/A0-A3 ; restore registers
	RTS


;;; handle_command
;;; D0 = channel number, D1 = command;
;;; A0 = song pointer, A1 = channel status, A2 = channel data stream.
handle_command:
	RTS


;;; calculate_duration
;;; D1 = unprocessed note data.
;;; Returns duration in D1.
calculate_duration:
	MOVEM.L D0/D2/A0, -(A7)

	LSR.W #8, D1		; Cut off tone info.
	MOVE.B D1, D0
	AND.B #7, D0
	LEA song_status, A0
	MOVE.W song_whole_note_length(A0), D2
	LSR.W D0, D2		; Divide whole note length.

.test_dot:			; This unused label is for clarity.
	BTST #3, D1
	BEQ .test_double_dot
	MOVE.W D2, D0
	LSR.W #1, D0
	ADD.W D0, D2

.test_double_dot:
	BTST #4, D1
	BEQ .test_triplet
	MOVE.W D2, D0
	LSR.W #1, D0
	ADD.W D0, D2
	LSR.W #1, D0
	ADD.W D0, D2

.test_triplet:
	BTST #5, D1
	BEQ .test_tie
	;;; XXX multiply by 2/3
	BRA .test_tie
	;; The following code is for duplets (3/2).
	MOVE.W D2, D0		; D2 = D2 * 3/2
	ADD.W D0, D2
	ADD.W D0, D2
	LSR.W #1, D2

.test_tie:
	BTST #6, D1
	BEQ .end
	;; XXX set special flag.

.end:	
	MOVE.W D2, D1		; Return duration.
	MOVEM.L (A7)+, D0/D2/A0
	RTS


;;; set_tempo
;;; D0 = (unprocessed) tempo value;
;;; A1 = song status pointer.
;;; Wipes out D0 and D1.
set_tempo:
	EXT.W D0
	ADDI.W #base_tempo, D0
	MOVE.W D0, song_current_tempo(A1)
	;; FIXME could be cool to not have to recompile to change this.
	MOVE.W #playback_frequency*60, D1 ; D1 = cycles per minute.
	LSR.W #2, D0		; D0 = BPM/4 = whole notes per minute.
	DIVU D0, D1		; D1 (low word) = ticks per whole note.
	MOVE.W D1, song_whole_note_length(A1)
	RTS


;;; CONSTANT TABLES

note_to_ymval_xlate:
	DC.W $EEE,$E18,$D4D,$C8E,$BDA,$B2F,$A8F,$9F7,$968,$8E1,$861,$7E9
	DC.W $777,$70C,$6A7,$647,$5ED,$598,$547,$4FC,$4B4,$470,$431,$3F4
	DC.W $3BC,$386,$353,$324,$2F6,$2CC,$2A4,$27E,$25A,$328,$218,$1FA
	DC.W $1DE,$1C3,$1AA,$192,$17B,$166,$152,$13F,$12D,$11C,$10C,$FD
	DC.W $EF,$E1,$D5,$C9,$BE,$B3,$A9,$9F,$96,$8E,$86,$7F
	DC.W $77,$71,$6A,$64,$5F,$59,$54,$50,$48,$47,$43,$3F
	DC.W $3C,$38,$35,$32,$2F,$2D,$2A,$28,$26,$24,$22,$20
	DC.W $1E,$1C,$1B,$19,$18,$16,$15,$14,$13,$11,$10,$0F


;;; GLOBAL VARIABLES
	BSS

song_status:	DS.L song_status_size
channel_status:	DS.L channel_status_size*number_of_channels

;;; EOF