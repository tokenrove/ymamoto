 *
 * This is a resonant filter (with infinite? resonance),
 * cutoff/oscillation frequency of 50Hz, so that the step value
 * will equal 1/8 (IOW, >>3).  The step value is usually:
 * (* 2 (sin (* pi (/ 1 frequency)))) - see resonant-filter.lisp
 * in my snippets collection.
 *
 * Actually, this is >>4 now, to make things a bit smoother.
 *
        section text

        global reset_sine_oscillator
reset_sine_oscillator:
        MOVE.W #256, cosine ; Fairly arbitrary max amplitude.
        MOVE.W #0, sine
        RTS

        global step_sine_oscillator
step_sine_oscillator:
        MOVE.W sine, D0
        ASR.W #4, D0
        SUB.W D0, cosine
        MOVE.W cosine, D0
        ASR.W #4, D0
        ADD.W D0, sine
        RTS

        section data
        global sine, cosine
sine:	ds.w 1
cosine: ds.w 1

