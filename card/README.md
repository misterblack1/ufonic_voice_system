# The Ufonic card

How the Ufonic Voice System card works: the board, the R6500/1 mask ROM, the
Apple II side of the interface, and the speech format. `ufonic-r6500.bin` is
the ROM, `ufonic-r6500.asm` is its annotated disassembly, and `COMMANDS.md`
lists every command the ROM accepts.

The card plays back recorded human speech encoded as TMS5220 LPC. It is not
text to speech, so the vocabulary is fixed and comes off disk.

## The board

Research indicates this card was sold into US K-12 education from about 1983. Branding follows the company: Borg-Warner Educational Systems, then Prescription Learning Corp, then Jostens Learning. List price was $495. Two hardware revisions exist, and this appears to be the earliest revision.

Revision 1, "UFONIC / JOSTENS LEARNING SYSTEMS, INC.":

| Part | Qty | Role |
| --- | --- | --- |
| R6500/1, 40-pin DIP | 1 | Microcontroller holding this ROM |
| TMS5220NA | 1 | Speech synthesizer |
| 4164 64K x 1 DRAM, silkscreened D0 to D7 | 8 | The 64 KiB shared RAM |
| 74LS193 4-bit up/down counter, presettable | 2 | Address counter, see below |
| 74LS93 4-bit ripple counter, reset only | 4 | Address counter, see below |
| 74LS153 dual 4:1 mux | 4 | DRAM row and column address mux, 8 lines |
| 74LS541 octal buffer | 2 | Bus interface |
| 74LS374 octal latch | 1 | Bus interface |
| 74LS00 | 2 | Glue |
| 74LS04 | 2 | Glue |
| 74LS76, 74LS138, 74LS32, 74LS10, 7425 | 1 each | Glue and slot decode |
| RCA jack | 1 | Audio out |
| Trimmer marked POT | 1 | See below |

Revision 2, "UFONIC 21-9 / 28-9, PRESCRIPTION LEARNING CORP.", is a CMOS
redesign: a 60-R6570A PLCC silkscreened 65C10, a TMS5220CNL, two TMS4464
DRAMs in place of the eight 4164s, HC and HCT logic, an LM380 audio amp and an
LM3403 quad op-amp.

Both boards carry a trimmer in the TMS5220 oscillator network, marked POT on
revision 1 and PITCH on revision 2. The 5220 derives its sample rate from that
RC oscillator, so playback rate is adjustable per card and 8 kHz is only the
nominal value.

Photographs of both revisions are in the Apple II Documentation Project mirror
under [Interface Cards / Audio / Jostens
Ufonic](http://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Interface%20Cards/Audio/Jostens%20Ufonic/),
filed under Audio rather than Speech.

## Pin map

| Port | Width | Connected to |
| --- | --- | --- |
| Port A (0x80) | 8 | DRAM data bus, bidirectional |
| Port B (0x81) | 8 | Host status flag and character output |
| Port C (0x82) | 8 | Strobes and handshakes |
| Port D (0x83) | 8 | TMS5220 data bus D0 to D7, bidirectional |

Port C:

| Bit | Dir | Mask | Function |
| --- | --- | --- | --- |
| 0 | IN | 0x01 | Host attention or operator stop, active HIGH |
| 1 | OUT | 0xfd | DRAM address counter clock |
| 2 | OUT | 0xfb | /WS, TMS5220 write select |
| 3 | OUT | 0xf7 | DRAM read strobe |
| 4 | OUT | 0xef | /RS, TMS5220 read select |
| 5 | OUT | 0xdf | DRAM output enable and increment |
| 6 | IN | 0x40 | /INT from the TMS5220, buffer low |
| 7 | IN | 0x80 | /READY from the TMS5220 |

A GPIO bit written as 1 on the 6500/1 only weakly pulls high, so the same
register bit doubles as an input. That is why Port A and Port D are set to
0xff before every read, and why Port C reads mix input bits 0, 6 and 7 with
the output bits the ROM itself just wrote.

## Driving the card

The Apple II and the 6500/1 share no command register. The host writes into
the shared DRAM through the card's other port, then raises an attention line.
The original software does it through a few small routines, named here for
what they do: `wait_idle` spins until $Cn00 reads $5F, `ram_rewind` writes
$C0n1, `ram_write` writes $C0n0, and `go` writes $C0n3.

| Address | Dir | Function |
| --- | --- | --- |
| $Cn00 | R | Port B of the 6500/1, read straight through. 0x5F means idle |
| $C0n0 | R/W | DRAM data, auto-incrementing |
| $C0n1 | W | Rewind the DRAM address counter to 0 |
| $C0n2 | W | Reset the 6500/1 |
| $C0n3 | W | GO, raises the attention line the ROM polls as PC0 |

`cmp #$5F` is the giveaway. 0x5F is the byte the ROM writes to Port B when it
is idle, and it sets bit 7 to 0xDF the moment it accepts a command. The host's
"wait until ready" reads the microcontroller's port register through the slot.

Sending a command:

```
jsr wait_idle          ; spin until Port B reads $5F
jsr ram_rewind         ; address counter -> 0
lda #$80 : jsr ram_write   ; DRAM[$0000] = cmd
lda count: jsr ram_write   ; DRAM[$0001] = parm
  ... count x 16-bit phrase indices -> DRAM[$0002...] ...
jsr go
```

| cmd | parm | Action |
| --- | --- | --- |
| $00 $00 | | Play the ROM test tone |
| $0000 to $025D | 16-bit index | Speak one vocabulary phrase |
| $03 to $1f | varies | Diagnostic command |
| $20 to $bf | | Invalid, restarts |
| $80 | count | Play `count & $3f` queued phrases |
| $c0 to $ff | units | Timed pause, then restart |

`ram_set_addr` in the ROM takes the address counter's high byte, not a byte
offset. Every call site passes the high half of a 16-bit pointer and then
walks the low half off with that many dummy reads. Seeking is "load the page,
then read the low byte's worth of times", which is why the phrase code spends
so much of its time in skip loops.

## Loading the vocabulary

The original software fills the card in 16 passes of 4 KiB. Each pass reads 16 sectors
of a track into a buffer at $6500, then writes all 4096 bytes to $C0n0. Track numbers run $12 to $21, which is 16 tracks x 16 sectors x
256 bytes, exactly 64 KiB.

## Card RAM layout

As loaded by Animal Survival, one of the original titles:

| Range | Contents |
| --- | --- |
| $0000 | cmd |
| $0001 | parm |
| $0002 to $007F | Phrase index queue, 63 x 16-bit, idle filler $0081 |
| $0080 | Vocabulary slot 0, never read, since the ROM special-cases index 0 |
| $0082 to $021F | Vocabulary table, 207 x 16-bit phrase pointers, ascending |
| $0220 to $0223 | $0081 terminator and padding |
| $0224 to $FFFF | LPC speech data |

The ROM computes a phrase's table entry as `(index << 1) + $0080`. Index 1
lands at $0082, whose stored value $0224 is the first byte of speech data,
immediately after the table. Unused slots and unused queue entries share the
$0081 filler.

This title holds 207 phrases, 3 to 4524 bytes each. Decoded they run to 4
minutes 53 seconds. The ROM's own bound allows up to 605 phrases.

The speech data ends at $F2F7, leaving 3,336 bytes free. LPC here averages
about 210 bytes per second of speech, so one 64 KiB load holds roughly five
minutes. That is the card's whole vocabulary until the host loads another
image.

## Packing speech for the card

This is the recipe for building a 64 KiB card image from any TMS5220 speech.
`../speech/mkcard.py` follows it for the Speak & Spell set, and
`../speech/ufonicfeed.py` checks a finished image against it.

### Image layout

1. Fill $0002 to $007F with the $0081 queue filler. $0000, $0001, $0080 and
   $0081 can be zero.
2. Put the phrase pointer table at $0082. Entry N, for phrase index N from 1
   up, is at `(N << 1) + $0080` and holds the phrase's 16-bit card address,
   low byte first.
3. Put the phrase data straight after the table, each phrase at the address
   its entry names, in ascending order.
4. Pad the image to exactly 65,536 bytes.

The Animal Survival image ends its table with a $0081 word. Nothing in the
ROM reads it, and the Speak & Spell image leaves it out.

Phrase indices are 16-bit, so a set is not held to 255 phrases. The table
takes two bytes a phrase, and at the ROM's bound of 605 phrases it ends at
$053B.

### Frame format

Each phrase is a stream of TMS5220 frames:

| Frame | Fields | Bits |
| --- | --- | --- |
| Silence | Energy 0000 | 4 |
| Stop | Energy 1111 | 4 |
| Repeat | Energy, repeat 1, pitch 6 | 11 |
| Unvoiced | Energy, repeat 0, pitch 0, K1 to K4 | 29 |
| Voiced | Energy, repeat 0, pitch, K1 to K10 | 50 |

K1 and K2 are 5 bits, K3 to K7 are 4 bits, K8 to K10 are 3 bits. Fields are
written MSB first, and bits fill each byte from bit 0 up. The coefficient
tables are the TMS5220 ones, not the TMS5100 or TMC0281 ones. Speech from
those chips must be requantized first, which is what `../speech/transcode.py`
does.

Every phrase must end in a stop frame. The ROM has no length for a phrase. It
keeps feeding bytes until the chip reports Talk Status off.

### How the ROM feeds a phrase

The ROM sends Speak External ($60), writes 9 bytes, then writes 8 more each
time the chip interrupts with status TS and BL (6). It reads on past the end
of the phrase into whatever follows. Status 0 ends the phrase.

That loop has a trap. BL comes up when the FIFO drops to 8 bytes, and TS stays
up for a few frames after the stop frame while the energy ramps down. If
reading the stop frame finishes the byte that drops the FIFO to 8, BL fires
with TS still up. The ROM writes 8 more bytes, and on a TMS5220 a write that
clears BL while speech is off starts Speak External again. The chip then
speaks whatever comes after the stop frame, which is the start of the next
phrase.

Whether a phrase hits this depends only on the bit offset of its stop frame.
Packed without padding, 23 phrases of the Speak & Spell set hit it, among
them the letters A and H, which then play garbage after the letter.

### Required padding

`ufonicfeed.safe_pack` packs each phrase so the trap cannot fire:

1. If the stop frame lands on a restart offset, insert silence frames before
   it until it does not. Each one adds 25 ms of silence and moves the stop 4
   bits.
2. Fill the rest of the byte holding the stop frame with 1 bits.
3. Add one $FF byte after it.

Steps 2 and 3 are what Animal Survival does. Every one of its 207 phrases
ends with 1 bits after the stop and one or two $FF bytes. Fifteen of its
phrases sit on a restart offset, and the padding is what keeps them silent,
since a restart reads only more stop frames. Step 1 removes the restart
altogether.

### Checking an image

```sh
python ../speech/ufonicfeed.py card.bin card.txt
```

`card.txt` is the phrase table `mkcard.py` writes beside each image, with one
line per phrase giving the index and card address in hex. The check parses
each phrase and prints the indices that would restart. It exits 1 if there
are any. `../spellgame/build.py` runs it and stops on a failure.

### Putting it on a disk

The image goes on tracks 18 to 33 of a DOS 3.3 disk, unlisted, with those
tracks marked used in the VTOC. Card byte B goes to track `18 + B / 4096`,
logical sector `(B / 256) & 15`, offset `B & 255` in the `.dsk` file.
`../spellgame/build.py` writes it that way and checks that no catalogued file
lands on those tracks.

A program sends `$80 count` and a queue of phrase indices, as in Driving the
card, then raises GO. `../spellgame/spell.asm` has a working queue in
`qclr`, `qph` and `say`.

## Diagnostic commands

The dispatcher masks the command with `and #$0f` after range-checking it to
$03 through $1f, so the nominal numbers are $10 through $1f.

| Cmd | Vector | Function |
| --- | --- | --- |
| $10 | $0992 | Read all 64 KiB once, a refresh pass |
| $11 | $09bb | Check DRAM holds an incrementing ramp, click Port B bit 0 per error |
| $12 | $0a13 | Write parm into DRAM, read back, advance |
| $13 | $0a48 | Address-ramp test against the address low byte |
| $14 | $0a8c | Address-ramp test against the address high byte |
| $15 to $17 | $0837 | Unimplemented, restarts |
| $18 | $0ad0 | Free-run DRAM reads until the host interrupts |
| $19 | $0837 | Unimplemented |
| $1a | $0ae9 | Checksum a DRAM range, print computed against stored |
| $1b | $0837 | Unimplemented |
| $1c | $0bc9 | Checksum the ROM, $0800 to $0fff |
| $1d | $0bec | Set the inter-character delay used by putc |
| $1e | $0837 | Unimplemented |
| $1f | $0bf3 | Hex dump 0x40 rows of 16 bytes |

Everything these print goes out through `putc` at $0dd5, which bit-bangs a
character on Port B: all lines low as a start marker, about 100 us, then the
character with bit 7 forced set, held for a programmable inter-character time.
Command $1d sets that time. All output is high-bit-set ASCII.

## ROM map

| Range | Size | Contents |
| --- | --- | --- |
| $0800 to $0971 | 370 | Reset, main loop, phrase sequencer, dispatcher |
| $0972 to $0991 | 32 | Dispatch vector table |
| $0992 to $0cd3 | 834 | Diagnostic commands, speech streaming |
| $0cd4 to $0d0e | 59 | LPC data for the test tone |
| $0d0f to $0e70 | 354 | TMS5220 driver, DRAM driver, delays, hex output |
| $0e71 to $0ece | 94 | Copyright text, high-bit-set ASCII |
| $0ecf to $0ff9 | 299 | 296 NOPs then `jmp main` |
| $0ffa to $0fff | 6 | Vectors, all three point at reset |

The copyright block reads `COPYRIGHT (C) 1983     BORG-WARNER CORPORATION
ALL RIGHTS RESERVED`, padded with 0x11, the same filler the reset code writes
over all 64 bytes of RAM. Nothing in the ROM reads it.

The NOP sled is a safety net. If the program counter is ever thrown into the
unused tail it slides to the bottom and restarts.

All three vectors point at reset because the on-chip counter and edge
interrupts are never enabled. CONTROL is zeroed as the first instruction, so
an NMI or IRQ can only mean something has gone wrong.

One 6500/1 quirk worth knowing: reset does not clear the decimal flag, so
every arithmetic routine in this ROM issues its own `cld` first. See $08ea,
$0bd2 and $0db6.

The disassembly decodes 804 instructions. All 192 control-flow targets and
all 16 dispatch vectors land on instruction boundaries, and the region map
covers all 2048 bytes. The ROM and the original Apple II driver agree on the
idle byte, the command packet and the vocabulary table base.

Fingerprints, so a second dump can be compared:

```
size   2048 bytes
CRC32  ed6c7444
MD5    67c8b0edde1ee6dde5a09d1cfff5f4e8
SHA1   03d4bab661ff7aece2d8ac8febb96e4e39ac0ae8
```

The ROM's own command $1c self-checksum, the 8-bit sum of $0800 to $0fff, is
$F0. That one is checkable on a real card without dumping anything. UFDIAG
test 3 runs it.

## Talking to the TMS5220

TI numbers the data bus D0 = MSB, so their D0, D1 and D2 are bits 7, 6 and 5
as a 6502 sees them.

`tms_status` at $0d0f floats Port D, drops PC4, spins on PC7, samples, then
rotates right five times and masks with 0x07. The status register is D0 = TS,
D1 = BL, D2 = BE, so the shift lands TS in bit 2, BL in bit 1 and BE in bit 0.

The command opcode sits in bits 6 to 4 with bit 7 a don't-care. The ROM sends
only two: 0x60 is Speak External and 0xFF is Reset.

Two details look arbitrary until you read the datasheet. The nine 0xFF
writes at boot are TI's own initialization recipe, and 0xFF satisfies both
halves at once because it is all-ones and it also decodes as Reset. The 1
then 8 FIFO prime is exactly nine bytes, the minimum before Talk Status comes
up, and the refill of 8 is exactly the space BL guarantees.

Each phrase's LPC data ends with an energy 1111 stop frame, which drops TS and
shows up in the ROM as status 0x00.

There is no TMS6100 voice synthesis memory on the board. The ROM never issues
Load Address, Read Byte or Read and Branch, the commands a VSM needs.

## Bit order

Bytes are consumed LSB first, which the datasheet states in section 5.2.
Within a field the first bit is the MSB. Neither choice is obvious, and both
are checkable against the Animal Survival vocabulary:

| Choice | Wrong way | Right way |
| --- | --- | --- |
| Byte order | 176 of 207 phrases parse, 33 fit their extent | 207 parse, 206 fit |
| Field order | Mean frame-to-frame pitch delta 17.68 | 2.36 |
| Unvoiced K count | K1 to K6: 167 parse, 74 fit | K1 to K4: 207 parse, 206 fit |

The coefficient tables match MAME's `TI_5110_5220_LPC` value for value, and
Nouspikel's published floats agree to 3 or 4 decimal places.

That vocabulary is 11,732 frames, 70 percent voiced, 22 percent unvoiced and
8 percent silence, with a median F0 of 138 Hz. The repeat bit is never used
anywhere in it.

## The test tone

The data at $0cd4, which the ROM plays for command $00 $00, is not speech. It
decodes to eight identical constant-parameter voiced frames at energy 9 and
pitch code 15, then a fade and silence: a 276 Hz buzz about 0.2 seconds long.

That explains the block's shape. A voiced frame is 50 bits, so four fill
exactly 25 bytes, which is why the raw dump looks like two near-identical
25-byte halves. The one byte that differs, at offset $12, is where the energy
drops to 1 in frame 7.

## Open questions

- Port B bits 0 to 4. Bit 7 is the busy flag and the whole byte doubles as
  character output. Whether the low bits drive anything physical needs
  continuity testing on a card.
- Port C bits 3 and 5 are both DRAM controls and are always pulsed 5 then 3.
  Which is output enable and which is the increment clock is an even bet.
- The 6500/1 clock rate. Every delay figure in the listing assumes 1 MHz. No
  crystal is identifiable in either photograph.
- Why `ram_set_addr` pulses PC1 twice rather than once.
- How the counters are wired.
- What refreshes the DRAM. A 4164 needs all 128 rows touched every 2 ms.
  Nothing in the ROM's idle loop does it, so refresh is likely in hardware,
  perhaps the spare pair of 74LS93s.

## References

- TMS5220 datasheet, for the command set, status register and FIFO behavior
- [Thierry Nouspikel, TI-99 speech
  synthesizer](https://www.unige.ch/medecine/nouspikel/ti99/speech.htm), for
  the published coefficient tables
- MAME `src/devices/sound/tms5110r.hxx` and `tms5220.cpp`, for the reference
  synthesizer
- [Applefritter thread on identifying the
  card](https://www.applefritter.com/content/help-needed-identify-strange-sound-card),
  which carries the 10-pin speaker connector pinout: pin 4 speaker hot, pin 7
  common, pin 8 headphone tip, pins 1 to 3 and 9 to 10 tone and volume pots
- Animal Survival for Ufonic Voice System, the courseware the driver and
  vocabulary layout were read from:
  [4am crack](https://archive.org/details/AnimalSurvivalUfonic4amCrack) and
  [flux capture of the original](https://archive.org/details/a2woz_Animal_Survival_for_Ufonic_Voice_System_1989_Hartley_Courseware_v06.29.89)
