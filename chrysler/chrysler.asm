; Chrysler Electronic Voice Alert for the Apple II and the Ufonic speech card.
; Loads the merged eva11 and eva24 speech into the card, draws the car on
; HGR page 2, honks, then each key animates its part and speaks its phrase
; with a caption.

        * = $6000

        jmp main

TXTPAGE = $0800             ; Hidden, rows 0, 22 and 23 mirror to HGR

!source "../spellgame/common.inc"
!source "phrases.inc"

GET_IOB = $03E3
RWTS    = $03D9
SPKR    = $C030

trkbuf  = $2000             ; One track, 16 sectors, in unused HGR page 1

SPEECH1 = 18                ; First speech track

; Card status.
CS_NONE = 0
CS_OK   = 1
CS_STUCK = 2
CS_BAD  = 3

; Screen rows.
R_STAT  = 22
R_MSG   = 23

!zone vars
cardok  !byte 0             ; Nonzero when speech goes to the card
cstat   !byte 0
kpos    !fill NKEYS, 0      ; Next action per key
act     !byte 0
tmp     !byte 0
sumlo   !byte 0
sumhi   !byte 0
dsumlo  !byte 0
dsumhi  !byte 0
trk     !byte 0
sect    !byte 0
hcnt    !byte 0
kslot   !byte 0             ; KACTS slot of the press

; MAIN:
!zone main
main    lda #0
        sta cardok
        jsr HOME
        jsr cls
        jsr hclr
        jsr hshow           ; Shown first, so the car draws in view
        jsr iinit
        jsr hbase
        jsr hlabels
        lda #<hmirror
        sta hvec
        lda #>hmirror
        sta hvec+1
        lda #$80
        sta hgrq
        ldx #R_TOP
        ldy #TITCOL
        jsr gotoxy
        lda #<title
        sta P
        lda #>title
        sta P+1
        jsr prstr
        jsr findcard
        bcs +
        lda #CS_OK
        sta cstat
        lda #1
        sta cardok
        bne ++
+       lda #CS_NONE
        sta cstat
++      jsr status
        jsr load
        jsr horn
        jsr idle
.loop   jsr getkey
        cmp #$E0
        bcc +
        and #$DF            ; Lowercase to uppercase
+       cmp #$91            ; Ctrl-Q
        bne +
        jsr htext
        jsr HOME
        jmp DOSWARM
+       cmp #$A0            ; Space sounds the horn on the Apple speaker
        bne +
        jsr horn
        jmp .loop
+       ldx #NKEYS-1
-       cmp keychr,x
        beq .hit
        dex
        bpl -
        bmi .loop
.hit    txa                 ; Action for this press, then step the key
        pha
        lda keyfst,x
        clc
        adc kpos,x
        tay
        sty kslot
        lda kacts,y
        sta act
        pla
        tax
        inc kpos,x
        lda kpos,x
        cmp keycnt,x
        bcc +
        lda #0
        sta kpos,x
+       ldx kslot
        jsr effpre
        lda act
        jsr say
        ldx kslot
        jsr effpost
        jmp .loop

; STATUS: card status line.
!zone status
status  ldx cstat
        lda cstlo,x
        sta P
        lda csthi,x
        sta P+1
        ldx #R_STAT
        jmp center

cstlo   !byte <.s0, <.s1, <.s2, <.s3
csthi   !byte >.s0, >.s1, >.s2, >.s3
.s0     !text "NO CARD, TEXT ONLY", 0
.s1     !text "SPEECH CARD FOUND", 0
.s2     !text "CARD STUCK, TEXT ONLY", 0
.s3     !text "LOAD BAD, TEXT ONLY", 0

; MSG: print the 0-terminated string at P on the message line.
!zone msg
msg     ldx #R_MSG
        jmp center

; CENTER: print the 0-terminated string at P centered on row X, the rest of
; the row blank.
!zone center
center  ldy #0
-       lda (P),y
        beq +
        iny
        bne -
+       sty tmp
        lda #40
        sec
        sbc tmp
        lsr
        sta tmp
        ldy #0
        jsr gotoxy
        lda tmp
        jsr clrto
        jsr prstr
        lda #40
        jmp clrto

; IDLE: the two bottom rows while waiting for a key. Row 22 is the key help
; with a working card, or the card status without one.
!zone idle
idle    lda cstat
        cmp #CS_OK
        bne +
        lda #<.help
        sta P
        lda #>.help
        sta P+1
        ldx #R_STAT
        jsr center
        jmp ++
+       jsr status
++      lda #<.act
        sta P
        lda #>.act
        sta P+1
        ldx #R_MSG
        jmp center
.help   !text "SPACE HORN    CTRL-Q QUIT", 0
.act    !text "KEY TO ACTIVATE", 0

; LOAD: stream the speech tracks into the card through RWTS, then read the
; card back. With no card it only checksums the disk.
!zone load
load    lda #0
        sta sumlo
        sta sumhi
        lda cardok
        beq +
        jsr waitidle
        bcc ++
        jmp stuck
++      jsr crew
+       jsr GET_IOB
        sty .iob+1
        sta .iob+2
        lda #SPEECH1
        sta trk
.trk    jsr prat
        !byte R_MSG, 12
        !text "LOADING TRACK ", 0
        lda trk
        jsr prdec2
        lda #40
        jsr clrto
        lda #15             ; DOS 3.3 skew favors descending order
        sta sect
.sec    ldy #3
        lda #0
        jsr .iob            ; Any volume
        ldy #4
        lda trk
        jsr .iob
        iny
        lda sect
        jsr .iob
        ldy #8
        lda #<trkbuf
        jsr .iob
        iny
        lda sect
        clc
        adc #>trkbuf
        jsr .iob
        ldy #$0B
        lda #0
        jsr .iob
        iny
        lda #1              ; Read
        jsr .iob
        lda .iob+2
        ldy .iob+1
        jsr RWTS
        bcc +
        lda #<.derr
        sta P
        lda #>.derr
        sta P+1
        jsr msg
        jmp .bad
+       dec sect
        bpl .sec
        lda #>trkbuf        ; Stream the track in ascending order
        sta .rd+2
        ldx #0
.rd     lda trkbuf,x
        ldy cardok
        beq +
        jsr cwr
+       clc
        adc sumlo
        sta sumlo
        bcc +
        inc sumhi
+       inx
        bne .rd
        inc .rd+2
        lda .rd+2
        cmp #(>trkbuf)+16
        bcc .rd
        inc trk
        lda trk
        cmp #SPEECH1+NTRACKS
        bcs +
        jmp .trk
+       lda sumlo
        sta dsumlo
        lda sumhi
        sta dsumhi
        lda cardok
        bne .verify
        jsr .cmpsum         ; No card: the disk sum alone proves the read path
        bne +
        lda #<.dok
        sta P
        lda #>.dok
        sta P+1
        jmp .show
+       lda #<.dbad
        sta P
        lda #>.dbad
        sta P+1
        jmp .show
.verify jsr prat
        !byte R_MSG, 12
        !text "VERIFYING SPEECH", 0
        lda #40
        jsr clrto
        jsr crew
        lda #0
        sta sumlo
        sta sumhi
        lda #NTRACKS*16     ; Pages to read back
        sta trk
        ldx #0
-       jsr crd
        clc
        adc sumlo
        sta sumlo
        bcc +
        inc sumhi
+       inx
        bne -
        dec trk
        bne -
        jsr crew
        jsr .cmpsum
        bne +
        lda dsumlo
        cmp #<CARDSUM
        bne +
        lda dsumhi
        cmp #>CARDSUM
        bne +
        lda #<.lok
        sta P
        lda #>.lok
        sta P+1
        jmp .show
+       lda #<.lbad
        sta P
        lda #>.lbad
        sta P+1
        jsr msg
.bad    lda cardok
        beq .wait
        lda #0
        sta cardok
        lda #CS_BAD
        sta cstat
        jsr status
        jmp .wait
.show   jsr msg
.wait   lda #50
        jmp delay

.iob    sta $FFFF,y         ; Operand patched to DOS's IOB
        rts

; .CMPSUM: Z set when SUMLO/SUMHI equals CARDSUM.
.cmpsum lda sumlo
        cmp #<CARDSUM
        bne +
        lda sumhi
        cmp #>CARDSUM
+       rts

.derr   !text "DISK ERROR", 0
.dok    !text "DISK OK, NO CARD", 0
.dbad   !text "DISK BAD", 0
.lok    !text "LOAD OK", 0
.lbad   !text "LOAD BAD", 0

; STUCK: the card never went idle. Text only from here on.
!zone stuck
stuck   lda #0
        sta cardok
        lda #CS_STUCK
        sta cstat
        jmp status

; HORN: beep beep on the Apple II speaker.
!zone horn
horn    jsr .beep
        lda #10
        jsr delay
.beep   lda #80             ; Cycles of the tone, about 0.2 s
        sta hcnt
-       lda SPKR
        ldy #1              ; Half period, about 1.3 ms, near 390 Hz
--      ldx #0
.d      dex
        bne .d
        dey
        bne --
        lda SPKR
        ldy #1
--      ldx #0
.d2     dex
        bne .d2
        dey
        bne --
        dec hcnt
        bne -
        rts

; SAY: speak action A with its caption, then clear the caption.
!zone say
say     sta act
        jsr caption
        lda cardok
        bne .card
        ldx act             ; Text only: hold the caption as long as the speech
        lda actdur,x
        sta tmp
-       lda #5
        jsr delay
        dec tmp
        bne -
        jmp .done
.card   jsr waitidle
        bcs .stuck
        jsr crew
        lda #$80
        jsr cwr
        ldx act
        lda actn,x
        sta tmp
        jsr cwr
        lda actoff,x
        tax
-       lda #0              ; Entry high byte
        jsr cwr
        lda actq,x
        jsr cwr
        inx
        dec tmp
        bne -
        jsr cgo
        jsr waitbusy
        jsr waitidle
        bcs .stuck
.done   jmp sayend
.stuck  jsr stuck
sayend  jsr capclr
        jmp idle

; CAPTION: the caption of action ACT on rows R_CAP and R_CAP+1, word
; wrapped. CAPCLR blanks both rows.
!zone caption
caption jsr capclr
        ldx act
        lda actclo,x
        sta P
        lda actchi,x
        sta P+1
        ldx #R_CAP
        ldy #0
        jsr gotoxy
.word   ldy #0              ; Length of the next word
-       lda (P),y
        beq +
        cmp #' '
        beq +
        iny
        bne -
+       tya
        clc
        adc ccol
        cmp #41
        bcc +
        ldx #R_CAP+1        ; Wrap
        ldy #0
        jsr gotoxy
+
-       ldy #0              ; PUTCH leaves the column in Y
        lda (P),y
        beq .end
        cmp #' '
        beq .sp
        jsr putch
        inc P
        bne -
        inc P+1
        bne -
.sp     inc P
        bne +
        inc P+1
+       lda ccol
        beq .word
        cmp #40
        bcs .word
        lda #' '
        jsr putch
        jmp .word
.end    rts

capclr  ldx #R_CAP
        ldy #0
        jsr gotoxy
        lda #40
        jsr clrto
        ldx #R_CAP+1
        ldy #0
        jsr gotoxy
        lda #40
        jmp clrto

!source "hgrline.asm"
!source "screen.inc"
!source "art.inc"
!source "items.inc"            ; After art.inc, it sizes tables by NITEM
