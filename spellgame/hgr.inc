; HGR display for SPELL on page 2. Text still goes to the hidden text grid, and
; PUTRAW mirrors each character into a 40 by 24 grid of 7 by 8 cells here.
; Only the key legend and logo rows show. The VFD is 8 cells of 28 by 28.

H       = $FA               ; HGR row pointer
G       = $FC               ; Glyph pointer

TXTCLR  = $C050
TXTSET  = $C051
MIXCLR  = $C052
PAGE1   = $C054
PAGE2   = $C055
HIRES   = $C057

VY      = 52                ; Top row of the VFD glyphs
VX      = 4                 ; Byte column of the first VFD cell, 4 per cell, even

!zone hgr_vars
hgrsave !byte 0
hch     !byte 0
hinv    !byte 0
hsx     !byte 0
hy      !byte 0
hn      !byte 0
hx      !byte 0
hm0     !byte 0
hx0     !byte 0
hx1     !byte 0
hy0     !byte 0
hy1     !byte 0
hpe     !byte 0             ; Fill byte for even columns
hpo     !byte 0             ; Fill byte for odd columns

; HINIT: draw the toy body, then show HGR page 2 full screen and turn on
; the mirror.
!zone hinit
hinit   jsr hbox            ; Clear
        !byte 0, 40, 0, 192, $00, $00
        jsr hbox            ; Orange body
        !byte 0, 40, 0, 192, $AA, $D5
        jsr hcorner
        jsr hbox            ; Handle hole, ends stepped round
        !byte 4, 36, 9, 11, $00, $00
        jsr hbox
        !byte 3, 37, 11, 13, $00, $00
        jsr hbox
        !byte 2, 38, 13, 29, $00, $00
        jsr hbox
        !byte 3, 37, 29, 31, $00, $00
        jsr hbox
        !byte 4, 36, 31, 33, $00, $00
        jsr hbox            ; Display band
        !byte 0, 40, 42, 90, $00, $00
        jsr hbox            ; Key plate, blue edge
        !byte 1, 39, 96, 172, $D5, $AA
        jsr hbox            ; Right edge without its last pixel, no white seam
        !byte 38, 39, 96, 172, $95, $95
        jsr hbox
        !byte 2, 38, 98, 170, $00, $00
        jsr hbox            ; Line between the games and the commands
        !byte 3, 37, 131, 133, $D5, $AA
        bit TXTCLR
        bit MIXCLR
        bit PAGE2
        bit HIRES
        lda #<hput
        sta hvec
        lda #>hput
        sta hvec+1
        lda #$80
        sta hgrq
        rts

; HCORNER: round the four corners of the body. Row Y from the top and
; row 191-Y from the bottom take the same four edge bytes.
!zone hcorner
hcorner lda #0
        sta hy
        sta hn
.row    ldx hy
        jsr .edge
        lda #191
        sec
        sbc hy
        tax
        jsr .edge
        lda hn
        clc
        adc #4
        sta hn
        inc hy
        lda hy
        cmp #CRAD
        bcc .row
        rts
.edge   lda hrlo,x
        sta H
        lda hrhi,x
        sta H+1
        ldx hn
        ldy #0
        lda hcorn,x
        sta (H),y
        iny
        lda hcorn+1,x
        sta (H),y
        ldy #38
        lda hcorn+2,x
        sta (H),y
        iny
        lda hcorn+3,x
        sta (H),y
        rts

; HDONE: back to the text page 1.
!zone hdone
hdone   lda #0
        sta hgrq
        bit TXTSET
        bit PAGE1
        rts

; HBOX: fill a box. The JSR is followed by first byte column, end byte
; column, first row, end row, even fill and odd fill. Ends are exclusive.
!zone hbox
hbox    pla
        sta G
        pla
        sta G+1
        ldy #1
        lda (G),y
        sta hx0
        iny
        lda (G),y
        sta hx1
        iny
        lda (G),y
        sta hy0
        iny
        lda (G),y
        sta hy1
        iny
        lda (G),y
        sta hpe
        iny
        lda (G),y
        sta hpo
        lda G
        clc
        adc #6
        tay
        lda G+1
        adc #0
        pha
        tya
        pha
        ldx hy0
.row    lda hrlo,x
        sta H
        lda hrhi,x
        sta H+1
        ldy hx0
-       tya
        lsr
        lda hpe
        bcc +
        lda hpo
+       sta (H),y
        iny
        cpy hx1
        bcc -
        inx
        cpx hy1
        bcc .row
        rts

; HPUT: draw character A at the cursor cell. Bit 7 clear draws it inverse.
; Only the key legend rows 13-20 and the logo row 22 show. Keeps X.
!zone hput
hput    pha
        lda crow
        cmp #13
        bcc .skip
        cmp #21
        bcc +
        cmp #22
        beq +
.skip   pla
        rts
+       pla
        stx hsx
        sta hch
        and #$3F
        ldx #0
        stx G+1
        asl
        asl
        asl
        rol G+1
        adc #<tfont         ; Carry is clear, the ROL took it
        sta G
        lda G+1
        adc #>tfont
        sta G+1
        lda #0
        bit hch
        bmi +
        lda #$7F
+       sta hinv
        lda crow
        asl
        asl
        asl
        sta hy
        lda #0
        sta hn
-       ldx hy
        lda hrlo,x
        clc
        adc ccol
        sta H
        lda hrhi,x
        sta H+1
        ldy hn
        lda (G),y
        eor hinv
        ldy #0
        sta (H),y
        inc hy
        inc hn
        lda hn
        cmp #8
        bcc -
        ldx hsx
        rts

; HVCELL: draw character A in VFD cell X, 0-7. Bit 7 clear draws a block.
!zone hvcell
hvcell  pha
        txa
        asl
        asl
        adc #VX
        sta hx
        pla
        ldx #VBLOCK
        cmp #$80
        bcc +
        and #$3F
        tax
        lda vmap,x
        tax
+       lda vflo,x
        sta G
        lda vfhi,x
        sta G+1
        lda #VY
        sta hy
        lda #0
        sta hn
.row    ldx hy
        lda hrlo,x
        clc
        adc hx
        sta H
        lda hrhi,x
        sta H+1
        ldx #0
-       ldy hn
        lda (G),y
        inc hn
        stx hm0
        ldy hm0
        sta (H),y
        inx
        cpx #4
        bcc -
        inc hy
        lda hy
        cmp #VY+28
        bcc .row
        rts

!source "font.inc"
