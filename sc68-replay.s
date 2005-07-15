
        extern ymamoto_init, ymamoto_update

        section text
        global _start
_start: jmp ymamoto_init
        rts
        jmp ymamoto_update
        rts


