; Full screen HGR page 2: the car line art, the boxed key labels, and text
; rows 0, 22 and 23 mirrored from the hidden text page in the Apple font.

H       = $FA               ; HGR row pointer, shared with LINE
G       = $FC               ; Glyph pointer, shared with LINE
AP      = $EB               ; Art data pointer

TXTCLR  = $C050
TXTSET  = $C051
MIXCLR  = $C052
PAGE1   = $C054
PAGE2   = $C055
HIRES   = $C057

R_TOP   = 0                 ; Text rows drawn on the HGR page
R_CAP   = 22
Y_CAP   = 176

!zone hvars
hsx     !byte 0
hsy     !byte 0
hch     !byte 0
hinv    !byte 0
hn      !byte 0
hy      !byte 0
hcol    !byte 0
hlab    !byte 0
hlast   !byte 0

; HROW: point H at row X of the page in HPAGE, column hcol.
!zone hrow
hrow    lda lrowlo,x
        clc
        adc hcol
        sta H
        lda lrowhi,x
        adc hpage
        sta H+1
        rts

; HCLR: clear the whole page.
!zone hclr
hclr    lda #0
        sta H
        tay
        lda hpage
        sta H+1
        ldx #$20
        lda #0
-       sta (H),y
        iny
        bne -
        inc H+1
        dex
        bne -
        rts

; HSHOW: show HGR page 2 full screen. HTEXT goes back to text page 1.
!zone hshow
hshow   bit HIRES
        bit MIXCLR
        bit PAGE2
        bit TXTCLR
        rts

htext   bit TXTSET
        bit PAGE1
        rts

; HBASE: draw every item that shows at the start.
!zone hbase
hbase   lda #0
        sta lmode
        ldx #0
-       stx hlast
        lda ihid,x
        bne +
        jsr hitem
+       ldx hlast
        inx
        cpx #NITEM
        bcc -
        rts

; HITEM: draw the runs of item X in LMODE.
!zone hitem
hitem   lda itlo,x
        sta AP
        lda ithi,x
        sta AP+1
.run    ldy #0
        lda (AP),y
        beq .done
        sta hn
        iny
        lda (AP),y
        sta lx0
        iny
        lda (AP),y
        sta lx0+1
        iny
        lda (AP),y
        sta ly0
        dec hn
-       jsr .next
        ldy #1
        lda (AP),y
        sta lx1
        iny
        lda (AP),y
        sta lx1+1
        iny
        lda (AP),y
        sta ly1
        jsr line
        dec hn
        bne -
        jsr .next           ; Past the last point to the next count
        inc AP
        bne .run
        inc AP+1
        jmp .run
.done   rts
.next   lda AP              ; Step past the count or a point
        clc
        adc #3
        sta AP
        bcc +
        inc AP+1
+       rts

; HLABELS: every key letter in its box. The box is pixels -2 to 8 across
; and -2 to 9 down from the glyph, cleared inside, outlined.
!zone hlabels
hlabels ldx #0
-       stx hlab
        jsr hlabel
        ldx hlab
        inx
        cpx #NLAB
        bcc -
        rts

hlabel  lda labkey,x
        jsr hglyph
        lda labcol,x
        sec
        sbc #1
        sta hcol
        lda laby,x
        sec
        sbc #2
        sta hy
        lda #0
        sta hn              ; Box row 0-11
.row    ldx hy
        jsr hrow
        ldy #0              ; Left byte: pixel -2 is bit 5, -1 is bit 6
        lda (H),y
        and #$9F
        ora #$20
        ldx hn
        beq .lend
        cpx #11
        bne +
.lend   ora #$40
+       sta (H),y
        iny                 ; Glyph byte
        lda (H),y
        and #$80
        ldx hn
        beq .full
        cpx #11
        beq .full
        cpx #2
        bcc +
        cpx #10
        bcs +
        sty hsy
        ldy hn
        dey
        dey
        ora (G),y           ; Glyph rows sit at box rows 2-9
        ldy hsy
        jmp +
.full   ora #$7F
+       sta (H),y
        iny                 ; Right byte: pixel 7 is bit 0, 8 is bit 1
        lda (H),y
        and #$FC
        ora #$02
        ldx hn
        beq .rend
        cpx #11
        bne +
.rend   ora #$01
+       sta (H),y
        inc hy
        inc hn
        lda hn
        cmp #12
        bcc .row
        rts

; HGLYPH: point G at the font rows of character A.
!zone hglyph
hglyph  and #$3F
        ldy #0
        sty G+1
        asl
        asl
        asl
        rol G+1
        adc #<tfont         ; Carry is clear, the ROL took it
        sta G
        lda G+1
        adc #>tfont
        sta G+1
        rts

; HMIRROR: the PUTRAW hook. Draws character A at the cursor cell when the
; cursor is on row 0, 22 or 23. Bit 7 clear draws it inverse. Keeps X and Y.
!zone hmirror
hmirror stx hsx
        sty hsy
        sta hch
        ldx crow
        beq +
        cpx #R_CAP
        bcc .out
        cpx #R_CAP+2
        bcs .out
+       txa
        asl
        asl
        asl
        sta hy
        lda ccol
        sta hcol
        lda hch
        jsr hglyph
        lda #0
        bit hch
        bmi +
        lda #$7F
+       sta hinv
        lda #0
        sta hn
-       ldx hy
        jsr hrow
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
.out    ldx hsx
        ldy hsy
        lda hch
        rts
