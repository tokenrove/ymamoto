
        .extern ymamoto_init
        .extern ymamoto_update

        .text
        .global _start
_start: jmp ymamoto_init
        rts
        jmp ymamoto_update
        rts


