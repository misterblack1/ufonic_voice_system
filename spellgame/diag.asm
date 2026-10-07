; UFDIAG: bench tests for the Ufonic card. Port and DRAM byte test, test
; tone, ROM checksum, full DRAM pattern and retention tests, reset, and a raw
; trace of Port B after any command.

        * = $0800

        jmp main

TXTPAGE = $0400

!source "common.inc"

ROMSUM  = $F0               ; Sum of the dumped ROM, see COMMANDS.md
R_RES   = 15                ; Result row for test 1 is R_RES + 1
R_MSG   = 23
TRACE   = $6E00             ; Port B change log, 48 bytes

!zone vars
savesp  !byte 0
pat     !byte 0             ; RAM test fill byte
amask   !byte 0             ; $FF mixes the address into the fill
page    !byte 0
expect  !byte 0
errlo   !byte 0
errhi   !byte 0
badlo   !byte 0             ; First failing address
badhi   !byte 0
badrd   !byte 0
badwr   !byte 0
badbits !byte 0             ; OR of every bit that read back wrong
passno  !byte 0
nchar   !byte 0
chars   !fill 16, 0
cmd     !byte 0
parm    !byte 0
last    !byte 0
tcount  !byte 0
tlo     !byte 0
thi     !byte 0
t3      !byte 0
secs    !byte 0
tmp     !byte 0
hexv    !byte 0

; MAIN:
!zone main
main    tsx
        stx savesp
        jsr cls
        jsr prat
        !byte 0, 9
        !text "UFONIC CARD DIAGNOSTIC", 0
        jsr scan
        jsr menu
.loop   ldx #R_MSG
        ldy #0
        jsr gotoxy
        lda #40
        jsr clrto
        jsr getkey
        and #$DF
        cmp #'1'+$80-$20    ; Digits lose bit 5 to the AND above
        bcc +
        cmp #'7'+$80-$20+1
        bcs +
        sec
        sbc #'1'+$80-$20
        jsr runtest
        jmp .loop
+       cmp #'A'+$80
        bne +
        jsr runall
        jmp .loop
+       cmp #'S'+$80
        bne +
        jsr pickslot
        jmp .loop
+       cmp #'Q'+$80
        bne .loop
        jsr HOME
        jmp DOSWARM

; MENU: the test list and the keys.
!zone menu
menu    jsr prat
        !byte 5, 0
        !text "1 TALK: PORT AND DRAM BYTES", 0
        jsr prat
        !byte 6, 0
        !text "2 TEST TONE", 0
        jsr prat
        !byte 7, 0
        !text "3 ROM CHECKSUM", 0
        jsr prat
        !byte 8, 0
        !text "4 RAM TEST, 6 PATTERNS", 0
        jsr prat
        !byte 9, 0
        !text "5 RAM RETENTION, 20 SECONDS", 0
        jsr prat
        !byte 10, 0
        !text "6 RESET CARD", 0
        jsr prat
        !byte 11, 0
        !text "7 SEND ANY COMMAND, TRACE PORT B", 0
        jsr prat
        !byte 12, 0
        !text "A RUN 1-5", 0
        jsr prat
        !byte 13, 0
        !text "S SET SLOT", 0
        jsr prat
        !byte 14, 0
        !text "Q QUIT TO DOS", 0
        rts

; SCAN: show $Cn00 for each slot, pick the first that reads idle three times
; running, else the first that reads busy three times running.
!zone scan
scan    jsr prat
        !byte 2, 0
        !text "SLOTS ", 0
        lda #0
        sta slot
        sta tmp
        lda #1
        sta numhi
-       lda numhi
        ora #$30
        jsr putch
        lda #':'
        jsr putch
        lda numhi
        ora #$C0
        sta .rd+2
        sta .rd2+2
.rd     lda $C400
        sta t3
        jsr prhex
        lda #' '
        jsr putch
        ldx #2              ; An empty slot floats, so demand 2 more equal reads
.rd2    lda $C400
        cmp t3
        bne ++
        dex
        bne .rd2
        cmp #IDLE
        bne +
        ldx slot
        bne ++
        lda numhi
        sta slot
        bne ++
+       cmp #IDLE+$80
        bne ++
        ldx tmp
        bne ++
        lda numhi
        sta tmp
++      inc numhi
        lda numhi
        cmp #8
        bcc -
        lda slot
        bne +
        lda tmp
+       beq +
        jsr setslot
+       jmp shslot

; SHSLOT: the slot in use.
!zone shslot
shslot  jsr prat
        !byte 3, 0
        !text "USING SLOT ", 0
        lda slot
        bne +
        jsr prat
        !byte 3, 11
        !text "NONE, PRESS S", 0
        jmp ++
+       ora #$30
        jsr putch
++      lda #40
        jmp clrto

; PICKSLOT: S key. Takes 1-7.
!zone pickslot
pickslot jsr prat
        !byte R_MSG, 0
        !text "SLOT 1-7, NOT A DISK SLOT? ", 0
        lda #40
        jsr clrto
        jsr getkey
        cmp #$B1
        bcc +
        cmp #$B8
        bcs +
        and #$07
        jsr setslot
+       jmp shslot

; RUNALL: tests 1 to 5.
!zone runall
runall  lda #0
-       pha
        jsr runtest
        pla
        clc
        adc #1
        cmp #5
        bcc -
        rts

; RUNTEST: A = test 0-6. Clears its result row, labels it, runs it.
!zone runtest
runtest sta tmp
        tax
        inx
        txa
        clc
        adc #R_RES
        tax
        ldy #0
        jsr gotoxy
        lda #40
        jsr clrto
        ldy #0
        ldx crow
        jsr gotoxy
        lda tmp
        clc
        adc #'1'
        jsr putch
        lda #' '
        jsr putch
        lda slot
        bne +
        jsr .say
        !text "NO SLOT SET", 0
        rts
+       jsr prat
        !byte R_MSG, 0
        !text "RUNNING", 0
        lda #40
        jsr clrto
        ldx tmp
        lda .lo,x
        sta P
        lda .hi,x
        sta P+1
        ldx tmp
        inx
        txa
        clc
        adc #R_RES
        tax
        ldy #2
        jsr gotoxy
        jmp (P)
.say    jmp say
.lo     !byte <t_talk, <t_tone, <t_rom, <t_ram, <t_hold, <t_reset, <t_trace
.hi     !byte >t_talk, >t_tone, >t_rom, >t_ram, >t_hold, >t_reset, >t_trace

; SAY: print the inline string after the JSR at the cursor.
!zone say
say     pla
        sta P
        pla
        sta P+1
-       inc P
        bne +
        inc P+1
+       ldy #0
        lda (P),y
        beq +
        jsr putch
        jmp -
+       lda P+1
        pha
        lda P
        pha
        rts

; READY: wait up to 2 s for idle. C set, with a note printed, if it never
; came.
!zone ready
ready   lda #210
        sta tmlo
        lda #0
        sta tmhi
        jsr waitidlt
        bcc +
        jsr say
        !text "BUSY ", 0
        lda lastp
        jsr prhex
        jsr say
        !text ", NOT IDLE", 0
        sec
+       rts

; SEND: rewind, write CMD and PARM, GO.
!zone send
send    jsr crew
        lda cmd
        jsr cwr
        lda parm
        jsr cwr
        jmp cgo

; TEST 1: Port B value, then 256 DRAM bytes written and read back.
!zone t_talk
t_talk  jsr cport
        pha
        jsr say
        !text "PORT ", 0
        pla
        pha
        jsr prhex
        pla
        cmp #IDLE
        beq +
        jsr say
        !text " NOT IDLE, DRAM SKIPPED", 0
        rts
+       jsr crew
        ldx #0
-       txa
        eor #$A5
        jsr cwr
        inx
        bne -
        jsr crew
-       jsr crd
        sta tmp
        txa
        eor #$A5
        cmp tmp
        bne +
        inx
        bne -
        jsr crew
        jsr say
        !text " IDLE, DRAM 256 OK", 0
        rts
+       sta badwr
        stx badlo
        jsr crew
        jsr say
        !text " DRAM BAD AT 00", 0
        lda badlo
        jsr prhex
        jsr say
        !text " RD ", 0
        lda tmp
        jsr prhex
        jsr say
        !text " WANT ", 0
        lda badwr
        jmp prhex

; TEST 2: test tone. Reports whether Busy showed and how long it lasted.
!zone t_tone
t_tone  jsr ready
        bcc +
        rts
+       lda #0
        sta cmd
        sta parm
        jsr send
        jsr waitbusy
        bcc +
        jsr say
        !text "NO BUSY SEEN, PORT ", 0
        lda lastp
        jmp prhex
+       lda #<526           ; 5 s
        sta tmlo
        lda #>526
        sta tmhi
        jsr waitidlt
        bcc +
        jsr say
        !text "BUSY OVER 5 S, PORT ", 0
        lda lastp
        jmp prhex
+       lda #<526           ; Elapsed batches N, about 9.5 ms each
        sec
        sbc tmlo
        sta tlo
        lda #>526
        sbc tmhi
        sta thi
        lda tlo             ; NUM = N
        sta numlo
        lda thi
        sta numhi
        ldx #3              ; N x 8
        jsr .shl
        jsr .addn           ; N x 9
        ldx #1              ; N x 18
        jsr .shl
        jsr .addn           ; N x 19
        lsr numhi           ; N x 9.5
        ror numlo
        jsr say
        !text "BUSY, IDLE AFTER ", 0
        jsr prdec16
        jsr say
        !text " MS", 0
++      rts
.shl    asl numlo
        rol numhi
        dex
        bne .shl
        rts
.addn   lda numlo
        clc
        adc tlo
        sta numlo
        lda numhi
        adc thi
        sta numhi
        rts

; TEST 3: ROM checksum through command $1C.
!zone t_rom
t_rom   jsr ready
        bcc +
        rts
+       lda #$1C
        sta cmd
        lda #0
        sta parm
        jsr send
        jsr getchars
        jsr say
        !text "GOT ", 0
        ldx #0
-       cpx nchar
        bcs +
        lda chars,x
        jsr prhex
        lda #' '
        jsr putch
        inx
        cpx #5
        bcc -
+       lda nchar
        cmp #3
        bne .bad
        lda chars+2
        cmp #$84
        bne .bad
        lda chars
        and #$7F
        jsr hexval
        bcs .bad
        asl
        asl
        asl
        asl
        sta hexv
        lda chars+1
        and #$7F
        jsr hexval
        bcs .bad
        ora hexv
        sta hexv
        jsr say
        !text "SUM ", 0
        lda hexv
        jsr prhex
        lda hexv
        cmp #ROMSUM
        bne +
        jsr say
        !text " OK", 0
        jmp .idle
+       jsr say
        !text " WANT F0", 0
        jmp .idle
.bad    lda nchar
        bne +
        jsr say
        !text "NO REPLY", 0
        jmp .idle
+       jsr say
        !text " BAD REPLY", 0
.idle   lda #210
        sta tmlo
        lda #0
        sta tmhi
        jmp waitidlt

; HEXVAL: ASCII hex digit in A to 0-15. C set when not a digit.
!zone hexval
hexval  cmp #'0'
        bcc .no
        cmp #'9'+1
        bcc +
        cmp #'A'
        bcc .no
        cmp #'F'+1
        bcs .no
        sbc #6              ; C clear here: 'A' - 7 = '9' + 1
+       sec
        sbc #'0'
        clc
        rts
.no     sec
        rts

; GETCHARS: read the card's printed characters from Port B. Each is a $00
; start marker, then the character with bit 7 set. Stops at $84 or $86, at
; 16 characters, or after about 5 s with no start marker.
!zone getchars
getchars lda slot
        ora #$C0
        sta .p1+2
        sta .p2+2
        lda #0
        sta nchar
.next   ldx #0
        ldy #0
        lda #8
        sta t3
.p1     lda $C400           ; Wait for the $00 start marker
        beq .start
        dex
        bne .p1
        dey
        bne .p1
        dec t3
        bne .p1
        rts
.start  ldx #0
        ldy #40
.p2     lda $C400           ; Wait for the character
        bmi .got
        dex
        bne .p2
        dey
        bne .p2
        rts
.got    ldx nchar
        sta chars,x
        inc nchar
        cmp #$84
        beq +
        cmp #$86
        beq +
        cpx #15
        bcc .next
+       rts

; TEST 4: six full passes over 64 KiB, $00 $FF $55 $AA, then the address
; pattern and its inverse.
!zone t_ram
t_ram   jsr ready
        bcs +
        jsr ramclr
        lda #0
        sta passno
-       ldx passno
        lda .pat,x
        sta pat
        lda .msk,x
        sta amask
        jsr progress
        jsr ramfill
        jsr ramread
        inc passno
        lda passno
        cmp #6
        bcc -
        ldx #R_RES+4
        ldy #2
        jsr gotoxy
        jsr ramrep
+       rts
.pat    !byte $00, $FF, $55, $AA, $00, $FF
.msk    !byte $00, $00, $00, $00, $FF, $FF

; PROGRESS: pass number on the message row.
!zone progress
progress jsr prat
        !byte R_MSG, 0
        !text "RAM PASS ", 0
        lda passno
        clc
        adc #'1'
        jsr putch
        lda #40
        jmp clrto

; TEST 5: address pattern, 20 s wait, read back.
!zone t_hold
t_hold  jsr ready
        bcs +
        jsr ramclr
        lda #0
        sta pat
        lda #$FF
        sta amask
        jsr ramfill
        lda #20
        sta secs
-       jsr prat
        !byte R_MSG, 0
        !text "WAITING ", 0
        lda secs
        jsr prdec2
        lda #40
        jsr clrto
        lda #100
        jsr delay
        dec secs
        bne -
        jsr ramread
        ldx #R_RES+5
        ldy #2
        jsr gotoxy
        jsr ramrep
+       rts

; RAMCLR: zero the error tally.
!zone ramclr
ramclr  lda #0
        sta errlo
        sta errhi
        sta badbits
        rts

; RAMFILL: write 64 KiB of (address lo XOR hi) AND AMASK XOR PAT.
!zone ramfill
ramfill jsr crew
        lda #0
        sta page
        ldx #0
-       txa
        eor page
        and amask
        eor pat
        jsr cwr
        inx
        bne -
        inc page
        bne -
        rts

; RAMREAD: read 64 KiB back against the same pattern, tallying errors.
!zone ramread
ramread jsr crew
        lda #0
        sta page
        ldx #0
-       txa
        eor page
        and amask
        eor pat
        sta expect
        jsr crd
        cmp expect
        bne .bad
.cont   inx
        bne -
        inc page
        bne -
        jmp crew
.bad    sta tmp
        eor expect
        ora badbits
        sta badbits
        lda errlo
        ora errhi
        bne +
        stx badlo
        lda page
        sta badhi
        lda tmp
        sta badrd
        lda expect
        sta badwr
+       inc errlo
        bne +
        inc errhi
        bne +
        dec errlo           ; Saturate at $FFFF
        dec errhi
+       jmp .cont

; RAMREP: OK, or the count, first failure and bad bits.
!zone ramrep
ramrep  lda errlo
        ora errhi
        bne +
        jsr say
        !text "RAM OK, ALL 65536 BYTES", 0
        rts
+       lda errlo
        sta numlo
        lda errhi
        sta numhi
        jsr prdec16
        jsr say
        !text " BAD 1ST ", 0
        lda badhi
        jsr prhex
        lda badlo
        jsr prhex
        jsr say
        !text " RD ", 0
        lda badrd
        jsr prhex
        jsr say
        !text " WR ", 0
        lda badwr
        jsr prhex
        jsr say
        !text " BITS ", 0
        lda badbits
        jmp prhex

; TEST 6: pulse reset, then wait for idle.
!zone t_reset
t_reset jsr crst
        jsr waitbusy
        bcs +
        jsr say
        !text "BUSY SEEN. ", 0
+       lda #210
        sta tmlo
        lda #0
        sta tmhi
        jsr waitidlt
        bcs +
        jsr say
        !text "RESET, IDLE AGAIN", 0
        rts
+       jsr say
        !text "RESET, STILL ", 0
        lda lastp
        jmp prhex

; TEST 7: send any command, then log every change on Port B for about 10 s,
; up to 48 values, 12 to a row on rows 15 to 18.
!zone t_trace
t_trace jsr prat
        !byte R_MSG, 0
        !text "COMMAND HEX? ", 0
        lda #40
        jsr clrto
        jsr gethex
        bcc +
        jmp .out
+
        sta cmd
        jsr prat
        !byte R_MSG, 17
        !text "PARAMETER HEX? ", 0
        jsr gethex
        bcc +
        jmp .out
+
        sta parm
        ldx #R_RES+7
        ldy #2
        jsr gotoxy
        jsr ready
        bcc +
        jmp .out
+
        jsr send
        lda slot
        ora #$C0
        sta .p1+2
        lda #IDLE
        sta last
        lda #0
        sta tcount
        lda #12
        sta t3
        ldx #0
        ldy #0
.p1     lda $C400
        cmp last
        bne .chg
.tick   dex
        bne .p1
        dey
        bne .p1
        dec t3
        bne .p1
        beq .done
.chg    sta last
        stx tlo
        ldx tcount
        sta TRACE,x
        inc tcount
        ldx tlo
        lda tcount
        cmp #48
        bcc .tick
.done   lda #R_RES
        sta tlo
        lda #0
        sta thi
        sta t3
-       lda thi
        cmp tcount
        bcs +
        lda t3
        bne ++
        lda #12
        sta t3
        inc tlo
        ldx tlo
        ldy #0
        jsr gotoxy
        lda #40
        jsr clrto
        ldx tlo
        ldy #0
        jsr gotoxy
++      dec t3
        ldx thi
        lda TRACE,x
        jsr prhex
        lda #' '
        jsr putch
        inc thi
        jmp -
+       ldx #R_RES+7
        ldy #2
        jsr gotoxy
        lda tcount
        jsr prdec2
        jsr say
        !text " CHANGES, NOW ", 0
        jsr cport
        pha
        jsr prhex
        pla
        cmp #IDLE
        beq .out
        jsr prat
        !byte R_MSG, 0
        !text "STILL BUSY. G SENDS GO, ELSE LEAVE IT", 0
        lda #40
        jsr clrto
        jsr getkey
        and #$DF
        cmp #'G'+$80
        bne .out
        jsr cgo
.out    lda #40
        jmp clrto

; GETHEX: two hex digits from the keyboard, echoed. ESC gives C set.
!zone gethex
gethex  jsr .one
        bcs +
        asl
        asl
        asl
        asl
        sta hexv
        jsr .one
        bcs +
        ora hexv
        clc
+       rts
.one    jsr getkey
        cmp #K_ESC
        beq .esc
        and #$7F
        cmp #'a'
        bcc +
        and #$DF
+       pha
        jsr hexval
        bcc +
        pla
        jmp .one
+       sta tmp
        pla
        jsr putch
        lda tmp
        clc
        rts
.esc    sec
        rts

; PRDEC16: NUMLO/NUMHI in decimal, no leading zeros.
!zone prdec16
prdec16 lda #0
        sta tmp             ; Set once a digit has printed
        ldx #0
.dig    ldy #0
-       lda numlo
        sec
        sbc .lo,x
        sta t3
        lda numhi
        sbc .hi,x
        bcc +
        sta numhi
        lda t3
        sta numlo
        iny
        bne -
+       tya
        bne +
        ldy tmp
        bne +
        cpx #4
        bne ++
+       ora #$30
        jsr putch
        inc tmp
++      inx
        cpx #5
        bcc .dig
        rts
.lo     !byte <10000, <1000, <100, <10, <1
.hi     !byte >10000, >1000, >100, >10, >1
