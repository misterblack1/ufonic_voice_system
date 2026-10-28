# CHRYSLER

The talking dashboard of the 1983 Chrysler New Yorker, for the Ufonic card,
in 6502 assembly for ACME. The screen is hi-res line art of the car, a side
view over a top view. Each key animates a part and the card says what the
real car said about it, in the car's own recorded voice.

The speech comes from the two Electronic Voice Alert units. eva11 is the
1983 11 function unit, eva24 the 1984 24 function one. Both use a TMS5110A.

| File | Contents |
| --- | --- |
| `chrysler.asm` | The program: slot scan, speech load, key loop, captions |
| `screen.inc` | Full screen HGR page 2, the key labels, the text rows |
| `items.inc` | Showing, hiding and blinking the parts of the car |
| `hgrline.asm` | Bresenham line into an HGR page |
| `mkphrases.py` | Converts and merges both speech sets, writes `phrases.inc` |
| `mkart.py` | Turns `art/car.json` into `art.inc` |
| `art/` | The line art and a browser editor for it |
| `hello.bas` | The disk's greeting program |

It shares `common.inc`, the card driver, with SPELL, and uses SPELL's disk
master and disk tools.

## Building

The top-level `build.py` is the usual way in. This one is the second half of
it, for when the two speech ROMs are already extracted:

```sh
python build.py cm73002.vsm cm63002.vsm out.dsk
```

`cm73002` is the eva11 speech ROM and `cm63002` the eva24 one, both from
MAME's sets of the same names.

`mkphrases.py` finds every phrase in each ROM, requantizes the 36 it keeps
from the TMS5110A tables to the TMS5220 tables, and packs them into one card
image. `mkart.py` writes `art.inc`. The build then checks the card image with
`../speech/ufonicfeed.py`, assembles, tokenizes `hello.bas`, and writes both
onto a copy of `../spellgame/masters/dos33_blank.dsk`.

## Disk layout

The speech is about 16 KiB, so it fills only tracks 18 to 21. The card bytes
sit on those tracks in the same order SPELL uses, sector 15 at the lowest
address. See `../card/README.md`. The load reads the four tracks into the
card and reads the card back to check the sum. The load takes about 4 seconds.

## Running it

`BRUN CHRYSLER`. It needs a 48K Apple II and loads at $6000.

It looks for the card in slots 1 to 7, loads the speech, and sounds the horn
on the Apple II speaker. With no card, or a card that fails the check, it
runs in text only mode. Each caption stays up as long as the speech would
have taken. The status row says which mode it is in.

A key with more than one phrase steps through them on each press and wraps
around. The parts of one press blink three times together, then the card
speaks and the caption shows on the bottom rows. The hood starts closed.
While it is closed, the engine bay keys blink the hood instead of their part.

### Keys

| Key | Part | Speech, in press order |
| --- | --- | --- |
| 1 | Driver door | "A door is ajar. Please close your driver door." Then "Thank you." as it closes |
| 2 | Passenger door | "A door is ajar. Please close your passenger door." Then "Thank you." |
| 3 | Left rear door | "A door is ajar. Please close your left rear door." Then "Thank you." |
| 4 | Right rear door | "A door is ajar. Please close your right rear door." Then "Thank you." |
| A | All systems, the page inverts once | "All monitored systems are functioning." |
| B | Parking brake | "Your parking brake is on." |
| C | Coolant and radiator | "Please check your engine coolant level." "Your engine temperature is above normal." "Your engine is overheating. Prompt service is required." |
| D | Disc brake pads | "Please check your disc brake pads." |
| E | Brake lamps | "Please check your brake lamps." |
| F | Fuel tank, shown when the trunk is open | "Please check your fuel level." "Your fuel is low." |
| G | Battery | "Your charging system is malfunctioning. Prompt service is required." "Electrical system is malfunctioning." |
| H | Hood, opens on the engine bay | A ding, each way |
| K | Key in the ignition | "Your keys are in the ignition." "Don't forget your keys." |
| L | Headlamps | "Your headlamps are on." "Please check your headlamps." |
| O | Engine | "Please check your engine oil level." "Your engine oil pressure is low." A ding, then "Your engine oil pressure is critical. Engine damage may occur." |
| P | Transmission | "Please check your transmission fluid level." |
| R | Tail lamps | "Please check your tail lamps." |
| S | Seat belt | "Please fasten your seatbelt." Then "Thank you." as it buckles |
| T | Trunk lid | "Please close your trunk lid." Then "Thank you." |
| U | Brake fluid | "Please check your brake fluid level." |
| W | Washer bottle | "Your washer fluid is low." "Your rear washer fluid is low." "Your washer fluid is low." |
| Space | Horn | Beep beep on the Apple II speaker, no speech |
| CTRL-Q | Quit | Back to DOS |

The eva11 set has fragments rather than whole sentences for fuel, oil
pressure and washer fluid. The card plays a queue of phrases end to end, so
"your" + "fuel" + "is low" makes one sentence. The second F press, the
second O press and the third W press are built that way.

The car has no hatch, so eva24's "Please close your rear hatch" is on the
card but on no key. eva24's long beep and beep burst are left off the card.

### Talking to the card

The packet is SPELL's: wait for idle at $Cn00, rewind the DRAM counter,
write $80, the entry count and the phrase indices through $C0n0, then strobe
GO. SPELL's notes on how Port B behaves after GO apply here too, see
`../spellgame/README.md`. The program waits for each phrase to finish
before it takes the next key.

## The art

`art/car.json` is the source of the picture, in HGR pixels: polylines for
the base drawing, overlays for each moving part, the items each overlay
hides, and the key labels. Open `art/editor.html` in a browser, load
`car.json`, edit, and save it back. The build runs `mkart.py` to write
`art.inc`.

`mkart.py` works out, for every part that can be erased, which segments of
other parts share a pixel with it. Erasing a part redraws those segments and
any label it touched, so the page always matches a fresh draw of what is
shown.
