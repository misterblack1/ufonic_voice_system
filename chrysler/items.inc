; Items are the base groups, then the overlays. An item shows while its
; hidden count is 0. Erasing one redraws the visible segments it shared pixels
; with, then the labels it touched, so nothing else on the page changes.

BLINKS  = 3                 ; Flashes per FLASH or ON
BLINKT  = 12                ; Half a flash in 10 ms units

!zone ivars
ihid    !fill NITEM, 0      ; Hidden count per item
icur    !byte 0
iov     !byte 0
ihx     !byte 0
ilx     !byte 0
blinks  !byte 0
nblk    !byte 0
blk     !fill NBLINK, 0

; IINIT: the start state, every base group shown, every overlay hidden.
!zone iinit
iinit   ldx #NITEM-1
-       lda ihid0,x
        sta ihid,x
        dex
        bpl -
        rts

; IDRAW: draw item X, then redraw the labels it touches.
!zone idraw
idraw   stx icur
        lda #0
        sta lmode
        jsr hitem
        ldx icur
        jmp ilabs

; IERASE: clear item X, redraw the shown segments that shared its pixels,
; then the labels.
!zone ierase
ierase  stx icur
        lda #1
        sta lmode
        jsr hitem
        lda #0
        sta lmode
        ldx icur
        lda irlo,x
        sta AP
        lda irhi,x
        sta AP+1
.seg    ldy #0
        lda (AP),y
        cmp #$FF
        beq .labs
        tax
        lda ihid,x
        bne .skip
        iny
        lda (AP),y
        sta lx0
        iny
        lda (AP),y
        sta lx0+1
        iny
        lda (AP),y
        sta ly0
        iny
        lda (AP),y
        sta lx1
        iny
        lda (AP),y
        sta lx1+1
        iny
        lda (AP),y
        sta ly1
        jsr line
.skip   lda AP
        clc
        adc #7
        sta AP
        bcc .seg
        inc AP+1
        jmp .seg
.labs   ldx icur
        ; Falls through to ILABS

; ILABS: redraw the labels on the list of item X.
ilabs   lda illo,x
        sta AP
        lda ilhi,x
        sta AP+1
        ldy #0
-       lda (AP),y
        cmp #$FF
        beq +
        sty ilx
        tax
        jsr hlabel
        ldy ilx
        iny
        bne -
+       rts

; ITOG: show overlay X if hidden, else hide it.
!zone itog
itog    lda ihid,x
        beq ihide

; ISHOW: show overlay X. The items it hides go first.
ishow   stx iov
        dec ihid,x
        jsr .setl
        ldy #0
-       jsr .hl
        cmp #$FF
        beq +
        tax
        inc ihid,x
        iny
        bne -
+       ldy #0
-       jsr .hl
        cmp #$FF
        beq +
        sty ihx
        tax
        lda ihid,x
        cmp #1              ; Hidden by this overlay alone, so still drawn
        bne .nx
        jsr ierase
.nx     ldy ihx
        iny
        bne -
+       ldx iov
        jmp idraw

; IHIDE: hide overlay X, then bring back the items it hid.
ihide   stx iov
        inc ihid,x
        jsr ierase
        ldx iov
        jsr .setl
        ldy #0
-       jsr .hl
        cmp #$FF
        beq +
        tax
        dec ihid,x
        iny
        bne -
+       ldy #0
-       jsr .hl
        cmp #$FF
        beq +
        sty ihx
        tax
        lda ihid,x
        bne .nx2
        jsr idraw
.nx2    ldy ihx
        iny
        bne -
+       rts

.setl   lda ihlo,x          ; Point .HL at the hide list of item X
        sta .hl+1
        lda ihhi,x
        sta .hl+2
        rts
.hl     lda $FFFF,y
        rts

; BLINK: blink the NBLK items on BLK together, ending shown. Each is
; counted hidden while off, so no erase restores another.
!zone blink
blink   lda nblk
        beq .done
        lda #BLINKS
        sta blinks
.off    ldy #0
-       ldx blk,y
        inc ihid,x
        iny
        cpy nblk
        bcc -
        ldy #0
-       sty ihx
        ldx blk,y
        jsr ierase
        ldy ihx
        iny
        cpy nblk
        bcc -
        lda #BLINKT
        jsr delay
        ldy #0
-       ldx blk,y
        dec ihid,x
        iny
        cpy nblk
        bcc -
        ldy #0
-       sty ihx
        ldx blk,y
        jsr idraw
        ldy ihx
        iny
        cpy nblk
        bcc -
        lda #BLINKT
        jsr delay
        dec blinks
        bne .off
.done   rts

; HNEG: invert the whole page, hold, then invert it back.
!zone hneg
hneg    jsr .inv
        lda #4*BLINKT
        jsr delay
.inv    lda #0
        sta H
        tay
        lda hpage
        sta H+1
        ldx #$20
-       lda (H),y
        eor #$7F
        sta (H),y
        iny
        bne -
        inc H+1
        dex
        bne -
        rts

; EFFPRE: run the effects of key slot X before the speech, then blink its
; items together. EFFPOST hides the overlays an ON effect showed for it.
!zone effect
epost   !byte 0
eop     !byte 0
eidx    !byte 0
eitem   !byte 0

effpre  lda #0
        beq +
effpost lda #$80
+       sta epost
        lda #0
        sta nblk
        lda eflo,x
        sta .ld+1
        lda efhi,x
        sta .ld+2
        ldy #0
.next   jsr .ld
        beq .done
        sta eop
        iny
        jsr .ld
        tax
        iny
        sty eidx
        lda eop
        bit epost
        bmi .post
        cmp #OP_TOG
        bne +
        jsr itog
        jmp .cont
+       cmp #OP_INV
        bne +
        jsr hneg
        jmp .cont
+       cmp #OP_ON
        bne +
        stx eitem
        jsr ishow
        ldx eitem
+       lda ihid,x          ; ON or FLASH: blink it if it shows
        bne .cont
        txa
        ldy nblk
        sta blk,y
        inc nblk
        jmp .cont
.post   cmp #OP_ON
        bne .cont
        jsr ihide
.cont   ldy eidx
        jmp .next
.done   bit epost
        bmi +
        jmp blink
+       rts
.ld     lda $FFFF,y
        rts
