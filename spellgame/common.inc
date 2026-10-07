; Screen, keyboard, delay and Ufonic card routines shared by SPELL and UFDIAG.
; Stock 6502. Card I/O uses self-modified absolute addresses, because an
; indexed store does a dummy read first and that would step the DRAM counter.

; ZERO PAGE:
; $06-$07 P, general pointer. PRAT uses it, so callers must not hold it
; across a PRAT call. $08-$09 S, screen row pointer.
P       = $06
S       = $08

KBD     = $C000
KBDSTRB = $C010
HOME    = $FC58
DOSWARM = $03D0

IDLE    = $5F               ; Port B value when the card is idle

; KEYS:
K_RET   = $8D
K_LEFT  = $88
K_ESC   = $9B

!zone common_vars
ccol    !byte 0             ; Cursor column
crow    !byte 0             ; Cursor row
slot    !byte 0             ; Card slot 1-7, 0 when none
rndlo   !byte $A7           ; LFSR state, never zero
rndhi   !byte $1D
wmode   !byte 0             ; Bit 7 set: WAITP waits for not idle
tmlo    !byte 0             ; WAITP timeout in 9.5 ms batches
tmhi    !byte 0
lastp   !byte 0             ; Last Port B value WAITP read
numlo   !byte 0             ; Scratch for number printing
numhi   !byte 0
hgrq    !byte 0             ; Bit 7 set: PUTRAW also calls HVEC
hvec    !word putret        ; Mirror routine, gets A and the cursor

; Text grid rows. TXTPAGE is $0400 for the real text page, or a 1 KiB
; buffer the screen never shows.
!zone rows
rowlo   !byte $00,$80,$00,$80,$00,$80,$00,$80
        !byte $28,$A8,$28,$A8,$28,$A8,$28,$A8
        !byte $50,$D0,$50,$D0,$50,$D0,$50,$D0
rowhi   !byte (TXTPAGE>>8)+0, (TXTPAGE>>8)+0, (TXTPAGE>>8)+1, (TXTPAGE>>8)+1, (TXTPAGE>>8)+2, (TXTPAGE>>8)+2, (TXTPAGE>>8)+3, (TXTPAGE>>8)+3
        !byte (TXTPAGE>>8)+0, (TXTPAGE>>8)+0, (TXTPAGE>>8)+1, (TXTPAGE>>8)+1, (TXTPAGE>>8)+2, (TXTPAGE>>8)+2, (TXTPAGE>>8)+3, (TXTPAGE>>8)+3
        !byte (TXTPAGE>>8)+0, (TXTPAGE>>8)+0, (TXTPAGE>>8)+1, (TXTPAGE>>8)+1, (TXTPAGE>>8)+2, (TXTPAGE>>8)+2, (TXTPAGE>>8)+3, (TXTPAGE>>8)+3

; GOTOXY: X = row, Y = column.
!zone gotoxy
gotoxy  stx crow
        sty ccol
        lda rowlo,x
        sta S
        lda rowhi,x
        sta S+1
        rts

; PUTCH: A = character, written at the cursor with bit 7 forced on.
!zone putch
putch   ora #$80
putraw  ldy ccol
        sta (S),y
        bit hgrq
        bpl +
        jsr .vec
+       inc ccol
putret  rts
.vec    jmp (hvec)

; CLRTO: blank from the cursor up to column A, not including it.
!zone clrto
clrto   sta numlo
-       lda ccol
        cmp numlo
        bcs +
        lda #$A0
        jsr putraw
        jmp -
+       rts

; CLS: fill the text page with spaces.
!zone cls
cls     ldx #23
-       ldy #0
        jsr gotoxy
        lda #40
        jsr clrto
        dex
        bpl -
        rts

; PRAT: print an inline string. The JSR is followed by row, column, text, 0.
!zone prat
prat    pla
        sta P
        pla
        sta P+1
        jsr .next
        tax
        jsr .next
        tay
        jsr gotoxy
-       jsr .next
        beq +
        jsr putch
        jmp -
+       lda P+1
        pha
        lda P
        pha
        rts
.next   inc P
        bne +
        inc P+1
+       ldy #0
        lda (P),y
        rts

; PRSTR: print the 0-terminated string at P at the cursor.
!zone prstr
prstr   ldy #0
        lda (P),y
        beq +
        jsr putch
        inc P
        bne prstr
        inc P+1
        bne prstr
+       rts

; PRHEX: A as two hex digits.
!zone prhex
prhex   pha
        lsr
        lsr
        lsr
        lsr
        jsr .dig
        pla
        and #$0F
.dig    cmp #10
        bcc +
        adc #6
+       adc #$30
        jmp putch

; PRDEC3: A as three decimal digits. PRDEC2: A, 0-99, as two.
!zone prdec
prdec3  ldx #100
        jsr .digit
prdec2  ldx #10
        jsr .digit
        ora #$30
        jmp putch
.digit  stx numhi
        ldx #$2F
        sec
-       inx
        sbc numhi
        bcs -
        adc numhi
        pha
        txa
        jsr putch
        pla
        rts

; RND: step the 16-bit Galois LFSR, return its low byte in A.
!zone rnd
rnd     lsr rndhi
        ror rndlo
        bcc +
        lda rndhi
        eor #$B4
        sta rndhi
+       lda rndlo
        rts

; RANDOM: A = n, 1 to 255. Returns 0 to n-1 in A, unbiased by rejection.
!zone random
random  sta numhi
        lda #$FF
        sta numlo
-       lsr numlo           ; Smallest all-ones mask that covers n-1
        lda numlo
        cmp numhi
        bcs -
        sec
        rol numlo
-       jsr rnd
        and numlo
        cmp numhi
        bcs -
        rts

; GETKEY: wait for a key, churning the LFSR. Returns it in A.
!zone getkey
getkey  jsr rnd
        lda KBD
        bpl getkey
        sta KBDSTRB
        rts

; DLY10: about 10 ms. DELAY: A x 10 ms.
!zone delay
delay   tax
        beq +
-       jsr dly10
        dex
        bne -
+       rts
dly10   tya
        pha
        txa
        pha
        ldy #8
--      ldx #0
-       dex
        bne -
        dey
        bne --
        pla
        tax
        pla
        tay
        rts

; CARD I/O STUBS:
; SETSLOT patches the operands below for the slot in A.
!zone cardio
cwr     sta $C0C0
        rts
crd     lda $C0C0
        rts
crew    sta $C0C1
        rts
crst    sta $C0C2
        rts
cgo     sta $C0C3
        rts
cport   lda $C400
        rts

setslot sta slot
        ora #$C0
        sta cport+2
        lda slot
        asl
        asl
        asl
        asl
        ora #$80
        sta cwr+1
        sta crd+1
        ora #1
        sta crew+1
        ora #2
        sta cgo+1
        and #$FE
        sta crst+1
        rts

; PROBE: A = slot. Reads $Cn00 three times. Returns Z set when all three
; read IDLE, with the last value in A. Touches nothing but $Cn00.
!zone probe
probe   ora #$C0
        sta .rd+2
        ldx #3
.rd     lda $C400
        cmp #IDLE
        bne +
        dex
        bne .rd
+       rts

; RAMCHK: write $A5 $5A to DRAM $0000, read them back. C clear when both
; match. Leaves DRAM $0000-$0001 changed, which the next command overwrites.
!zone ramchk
ramchk  jsr crew
        lda #$A5
        jsr cwr
        lda #$5A
        jsr cwr
        jsr crew
        jsr crd
        cmp #$A5
        bne +
        jsr crd
        cmp #$5A
        bne +
        jsr crew
        clc
        rts
+       jsr crew
        sec
        rts

; FINDCARD: scan slots 1-7 for a card that answers IDLE and keeps two DRAM
; bytes. Sets the slot and returns C clear, or C set and slot 0.
!zone findcard
findcard lda #1
-       sta numlo
        jsr probe
        bne +
        lda numlo
        jsr setslot
        jsr ramchk
        bcc ++
+       lda numlo
        clc
        adc #1
        cmp #8
        bcc -
        lda #0
        sta slot
        sec
++      rts

; WAITP: wait on Port B. WMODE bit 7 clear waits for IDLE, set waits for any
; other value. TMLO/TMHI is the timeout in batches of about 9.5 ms. C clear
; on success, C set on timeout. The last value read is in LASTP.
!zone waitp
waitp   ldx #0
-       jsr cport
        sta lastp
        cmp #IDLE
        beq +
        bit wmode
        bmi .ok
        bpl ++
+       bit wmode
        bpl .ok
++      dex
        bne -
        lda tmlo
        bne +
        dec tmhi
+       dec tmlo
        lda tmlo
        ora tmhi
        bne waitp
        sec
        rts
.ok     clc
        rts

; WAITIDLE: wait up to about 35 s for IDLE. WAITIDLT takes the timeout in
; TMLO/TMHI. C set on timeout.
!zone waitidle
waitidle lda #<3750
        sta tmlo
        lda #>3750
        sta tmhi
waitidlt lda #0
        sta wmode
        jmp waitp

; WAITBUSY: wait up to about 57 ms for Port B to leave IDLE. C set on
; timeout, which also means the card may already have finished.
!zone waitbusy
waitbusy lda #$80
        sta wmode
        lda #6
        sta tmlo
        lda #0
        sta tmhi
        jmp waitp
