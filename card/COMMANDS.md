# Ufonic card command reference

Every command the card's 6500/1 ROM accepts, taken from `ufonic-r6500.asm`. Commands $00 $00, $80 and $1C have been tested on a real card through UFDIAG and SPELL. The rest have not, so treat their timings and output formats as unproven.

## Host interface

`n` is the slot number. The I/O addresses use slot + 8, so slot 4 is $C0C0.

| Address | Access | Function |
| --- | --- | --- |
| $Cn00 | Read | Port B of the 6500/1. $5F means Idle. Bit 7 set ($DF) means Busy |
| $C0n0 | Read/Write | Card DRAM data, the address counter advances on each access |
| $C0n1 | Write | Rewind the DRAM address counter to $0000 |
| $C0n2 | Write | Reset the 6500/1 |
| $C0n3 | Write | GO, raises the attention line the ROM polls as PC0 |

## Sending a command

1. Wait until $Cn00 reads $5F.
2. Write any value to $C0n1 to rewind the counter.
3. Write the command byte to $C0n0. It lands at DRAM $0000.
4. Write the parameter byte to $C0n0. It lands at DRAM $0001.
5. For a queue command, keep writing the queue entries from DRAM $0002 on.
6. Write any value to $C0n3.

The ROM sets $Cn00 to $DF when it takes the command and puts $5F back when it
is idle again. It rewinds the address counter every time it goes idle.

## Card RAM layout

| Range | Contents |
| --- | --- |
| $0000 | Command byte |
| $0001 | Parameter byte |
| $0002-$007F | Queue, 63 entries of 2 bytes, high byte first. Idle filler is $81 $00 |
| $0080-$0081 | Slot for index 0, never read, since index 0 plays the test tone |
| $0082 on | Phrase pointer table, 2 bytes per phrase, low byte first |
| After the table | TMS5220 speech data |

The pointer for phrase index N sits at (N x 2) + $0080. It holds the card
address where that phrase's speech starts. The speech runs until the 5220
reaches its stop frame.

## Command summary

| Command | Parameter | Action |
| --- | --- | --- |
| $00 | $00 | Play the built-in test tone |
| $00-$02 | Index low byte | Speak one phrase. Command and parameter form a 16-bit index, $0001-$025D |
| $03-$0F | Varies | Aliases of the diagnostics below, picked by the low 4 bits |
| $10-$1F | Varies | Diagnostics, see below |
| $20-$7F | Any | Invalid, ignored, the ROM goes back to idle |
| $80 | Count | Speak the first `count AND $3F` queue entries |
| $81-$BF | Any | Invalid, ignored |
| $C0-$FF | Ticks | Timed pause, then idle |

## Speech commands

### $00 $00: Test tone

Plays 8 constant voiced frames stored in the ROM at $0CD4, energy 9 and
pitch code 15. That is a buzz near 276 Hz for about 0.2 s. It needs nothing
loaded in DRAM, so it checks the 5220, amplifier and speaker on their own.

### $00-$02 with an index: Speak one phrase

The command byte is the index high byte and the parameter is the low byte.
Indexes run from $0001 to $025D, which is 605 phrases. An index of $025E or
higher is skipped with no sound.

The ROM looks up the pointer at (index x 2) + $0080, sends Speak External
($60) to the 5220, primes its FIFO with 9 bytes, then refills it 8 bytes at
a time until the stop frame.

### $80 with a count: Speak a queue

Plays `count AND $3F` entries from the queue at $0002, in order. Each entry is
2 bytes, high byte first, and is handled like this:

| Entry | Action |
| --- | --- |
| $0000 | Test tone |
| $0001-$025D | Speak that phrase |
| High byte $C0-$FF | Timed pause, using the entry as command and parameter |
| Anything else | Skipped, such as the $8100 filler |

The ROM releases the Busy bit when the last entry is done.

### $C0-$FF: Timed pause

| Part | Unit |
| --- | --- |
| Parameter | Short ticks of about 12.9 ms each |
| Command AND $3F | Long units of about 3.3 s each |

The short ticks run first, then the long units. Both figures assume a 1 MHz
clock on the 6500/1.

## Diagnostic commands

The ROM masks a command from $03 to $1F with `AND $0F` and jumps through a
16 entry table at $0972. So $03 runs the same code as $13, $0A the same as
$1A, and so on. Some routines check the command byte and behave a little
differently when entered through an alias, noted below. $00-$02 never reach
this table, so $10-$12 have no alias.

| Cmd | Entry | Name | What it does |
| --- | --- | --- | --- |
| $10 | $0992 | DRAM refresh pass | Reads all 64 KiB once with no checking, drives Port B low, waits about 100 ms |
| $11 | $09BB | DRAM ramp verify | Checks DRAM for an incrementing byte ramp. Pulses Port B bit 0 low once per bad byte. Runs until the host sends GO again |
| $12 | $0A13 | DRAM write | Writes the parameter into DRAM, reads it back and advances the counter |
| $13 | $0A48 | Address test, low | Ramp test keyed on the address low byte, starting from the parameter. Prints a report for each failure. Entered as $03, it prints one report first |
| $14 | $0A8C | Address test, high | The same, keyed on the address high byte. Entered as $04, it prints one report first |
| $15 | $0837 | None | Unimplemented, back to idle |
| $16 | $0837 | None | Unimplemented, back to idle |
| $17 | $0837 | None | Unimplemented, back to idle |
| $18 | $0AD0 | DRAM free run | Strobes DRAM reads nonstop from $0000 until the host sends GO again, then prints a space. Meant for a scope |
| $19 | $0837 | None | Unimplemented, back to idle |
| $1A | $0AE9 | DRAM checksum | Checksums a stored image, see below |
| $1B | $0837 | None | Unimplemented, back to idle |
| $1C | $0BC9 | ROM checksum | 8-bit sum of $0800-$0FFF, printed as 2 hex digits then $84 |
| $1D | $0BEC | Set character delay | Sets the output delay per character to the parameter, about 1 ms per count. Default $13 |
| $1E | $0837 | None | Unimplemented, back to idle |
| $1F | $0BF3 | Internal RAM dump | Hex dump of the 6500/1's 64 bytes of RAM, then $86 |

### $13 and $14 failure report

Each bad location prints as a new line in this form:

```
AAAA RR: EE
```

`AAAA` is the address, `RR` is what was read and `EE` is what was expected.
If the host has sent GO by the time a report finishes, the test stops.

### $1A: DRAM checksum

1. Reads a 16-bit length from DRAM $053C and echoes both bytes as hex.
2. Skips to DRAM $0080 and reads a stored 8-bit sum there.
3. Sums (length - $82) bytes from $0082 on, dropping carries.
4. Prints the computed sum, the stored sum, then the marker $84.

A match means the image in DRAM is intact. The layout it expects, with the
length at $053C and the sum at $0080, looks like a courseware image format.
None of the images built in this project set those fields.

### $1C: ROM checksum

The sum of every byte of `ufonic-r6500.bin` is $F0, so a card with the
same ROM should print `F0` then $84. A card that prints something else holds
a different ROM. This has not been checked on a card.

### $1F: Internal RAM dump

Reads through a zero page pointer starting at CPU address $0000. On the
6500/1 that is its own 64 bytes of RAM, not card DRAM, even though the
listing's comment says DRAM. It prints a carriage return, then 4 rows of 16
bytes, each row led by its address, with an extra space every 4 bytes. Then
a carriage return and the marker $86.

## Reading the card's text output

The diagnostic reports come back one character at a time on Port B, which the
host reads at $Cn00. For each character the ROM:

1. Drives Port B to $00 as a start marker for about 100 us.
2. Puts the character on Port B with bit 7 set, Apple II style.
3. Holds it for the character delay set by $1D.

| Byte | Meaning |
| --- | --- |
| $00 | Start of the next character |
| $A0 | Space |
| $8D | Carriage return |
| $B0-$B9, $C1-$C6 | Hex digits 0-9 and A-F |
| $BA | Colon |
| $84 | End of a $1A or $1C report |
| $86 | End of a $1F dump |

A host reader waits for $00, then for a value with bit 7 set, takes it as the
character, and repeats. The idle byte $5F has bit 7 clear, so it is never
mistaken for a character. A character byte also has bit 7 set, so it looks
like Busy. Wait for the end marker, not for $5F, to know a report is done.

## What the ROM cannot do

- It never sends a VSM command to the 5220, only Speak External and Reset.
- No command reads or writes ROM bytes, and no command jumps into RAM, so
  there is no way to dump the ROM or load code from the Apple II.
