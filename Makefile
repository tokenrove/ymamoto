
AS_OPTIONS = -m68000 --register-prefix-optional
LD_OPTIONS = 

.PSEUDO: all

all: ymamoto.bin playtest.prg

.s.o:
	m68k-atari-mint-as $(AS_OPTIONS) $^ -o $@

ymamoto.bin: sc68-replay.o ymamoto.o
	m68k-atari-mint-ld --oformat binary -Ttext 0x8000 $^ -o $@

playtest.prg: playtest.o ymamoto.o sine-oscillator.o
	m68k-atari-mint-ld $(LD_OPTIONS) $^ -o $@
