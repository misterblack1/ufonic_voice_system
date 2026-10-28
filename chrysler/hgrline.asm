; HGR Bresenham line for the Chrysler car art, stock 6502.
; Lights exactly the pixels mkart.py's line() lights, both ends included.
; On return lx0 and ly0 hold lx1 and ly1, so a polyline stores only the
; next end point. Bit 7 of every screen byte is left as it was.

!zone hgrline

LP      = $FA               ; Zero page pointer to the current screen byte

; INPUTS:
lx0     !byte 0, 0          ; Start X, 0-279
ly0     !byte 0             ; Start Y, 0-191
lx1     !byte 0, 0          ; End X
ly1     !byte 0             ; End Y
lmode   !byte 0             ; 0 sets pixels, nonzero clears them
hpage   !byte $40           ; High byte of the HGR page base

; WORK:
cury    !byte 0             ; Current row
curcol  !byte 0             ; Byte column of the current pixel, 0-39
curmsk  !byte 0             ; One-bit mask of the current pixel
xneg    !byte 0             ; $80 when X steps down
yneg    !byte 0             ; $80 when Y steps down
dxv     !byte 0, 0          ; X travel
dyv     !byte 0, 0          ; Y travel, negated
dx2v    !byte 0, 0          ; Twice the X travel, the Y step addend
dy2v    !byte 0, 0          ; Twice the negated Y travel, the X step addend
errv    !byte 0, 0          ; Error term, carried doubled
cnt     !byte 0, 0          ; Steps left
ltmp    !byte 0             ; Setup Y travel, then loop X difference low
ldif    !byte 0             ; Loop X difference high, bit 7 gates the step

; Row byte offsets within the HGR page, split so the high byte can take
; HPAGE at run time. Row address = page + (Y AND 7) * $400
; + ((Y >> 3) AND 7) * $80 + (Y >> 6) * $28.
lrowlo  !for y, 0, 191 {
        !byte ((y & 7) * $400 + ((y >> 3) & 7) * $80 + (y >> 6) * $28) & $FF
        }
lrowhi  !for y, 0, 191 {
        !byte ((y & 7) * $400 + ((y >> 3) & 7) * $80 + (y >> 6) * $28) >> 8
        }

; X / 7 and X MOD 7 for X below 256. X from 256 to 279 reads the table
; at (X AND $FF) + 4 and adds 36 columns, because 256 = 252 + 4 and
; 252 = 36 * 7 leaves the same remainder.
ldiv7   !for x, 0, 255 {
        !byte x / 7
        }
lmask7  !for x, 0, 255 {
        !byte 1 << (x % 7)
        }

; LINE: draw from (lx0, ly0) to (lx1, ly1), then leave the end point in
; lx0 and ly0. A and X and Y are clobbered.
line    lda lx1+1           ; X travel and direction
        cmp lx0+1
        bne .xc
        lda lx1
        cmp lx0
.xc     bcc .xdown
        lda #0
        sta xneg
        sec
        lda lx1
        sbc lx0
        sta dxv
        lda lx1+1
        sbc lx0+1
        sta dxv+1
        jmp .ydo
.xdown  lda #$80
        sta xneg
        sec
        lda lx0
        sbc lx1
        sta dxv
        lda lx0+1
        sbc lx1+1
        sta dxv+1

.ydo    lda ly1             ; Y travel and direction, kept negated
        cmp ly0
        bcs .yup
        lda #$80
        sta yneg
        sec
        lda ly0
        sbc ly1
        jmp .ymk
.yup    lda #0
        sta yneg
        sec
        lda ly1
        sbc ly0
.ymk    sta ltmp
        lda #0
        sec
        sbc ltmp
        sta dyv
        lda #0
        sbc #0
        sta dyv+1

        lda dxv+1           ; Step count is the longer travel
        bne .cx
        lda ltmp
        cmp dxv
        bcs .cy
.cx     lda dxv
        sta cnt
        lda dxv+1
        sta cnt+1
        jmp .dbl
.cy     lda ltmp
        sta cnt
        lda #0
        sta cnt+1

.dbl    lda dxv             ; Doubled travels for the error steps
        asl
        sta dx2v
        lda dxv+1
        rol
        sta dx2v+1
        lda dyv
        asl
        sta dy2v
        lda dyv+1
        rol
        sta dy2v+1
        clc                 ; Doubled error starts at 2 * (dx + dy)
        lda dx2v
        adc dy2v
        sta errv
        lda dx2v+1
        adc dy2v+1
        sta errv+1

        lda ly0             ; Current pixel
        sta cury
        ldx lx0
        lda lx0+1
        beq .lk
        txa
        clc
        adc #4
        tax
        lda ldiv7,x
        clc
        adc #36
        jmp .lk2
.lk     lda ldiv7,x
.lk2    sta curcol
        lda lmask7,x
        sta curmsk
        ldx cury            ; Screen byte pointer, kept across pixels
        lda lrowlo,x
        clc
        adc curcol
        sta LP
        lda lrowhi,x
        clc
        adc hpage
        sta LP+1
        jmp .loop

.end    lda lx1             ; The end point becomes the next start
        sta lx0
        lda lx1+1
        sta lx0+1
        lda ly1
        sta ly0
        rts

.loop   lda curmsk          ; Plot the current pixel
        ldy #0
        ldx lmode
        beq .pset
        eor #$FF
        and (LP),y
        sta (LP),y
        jmp .next
.pset   ora (LP),y
        sta (LP),y

.next   lda cnt             ; The last pixel leaves nothing to step
        bne +
        lda cnt+1
        beq .end
        dec cnt+1
+       dec cnt

        ; Both tests read the error before either step adds to it, so the
        ; X decision waits on the saved difference.
        sec                 ; X steps while the doubled error >= dyv
        lda errv
        sbc dyv
        sta ltmp
        lda errv+1
        sbc dyv+1
        sta ldif

        sec                 ; Y steps while the doubled error <= dxv
        lda dxv
        sbc errv
        lda dxv+1
        sbc errv+1
        bmi .px
        clc                 ; errv += dx2v
        lda errv
        adc dx2v
        sta errv
        lda errv+1
        adc dx2v+1
        sta errv+1
        bit yneg
        bmi .pyd
        inc cury
        jmp .pyst
.pyd    dec cury

.pyst   ldx cury            ; Rebuild the row pointer for the new row
        lda lrowlo,x
        clc
        adc curcol
        sta LP
        lda lrowhi,x
        clc
        adc hpage
        sta LP+1

.px     lda ldif            ; The X step needs a nonnegative difference
        bmi .px0
        clc                 ; errv += dy2v
        lda errv
        adc dy2v
        sta errv
        lda errv+1
        adc dy2v+1
        sta errv+1
        bit xneg
        bmi .pxd
        asl curmsk          ; Right inside the byte, or into the next one
        bpl .px1
        lda #1
        sta curmsk
        inc curcol
        inc LP              ; A row never crosses a page boundary
.px1    jmp .loop
.pxd    lsr curmsk          ; Left inside the byte, or into the previous
        bcc .px1
        lda #$40
        sta curmsk
        dec curcol
        dec LP
        jmp .loop
.px0    jmp .loop
