; Speak & Spell for the Apple II and the Ufonic speech card.
; Loads the snspellua vocabulary into the card from tracks 18-33, then plays
; the toy's five modes. Runs in text only mode when no card answers.

        * = $0800

        jmp main

TXTPAGE = $6800             ; Off-screen text grid, see common.inc

!source "common.inc"
!source "words.inc"
!source "hgr.inc"

GET_IOB = $03E3
RWTS    = $03D9

deck    = $6D00             ; Shuffled word numbers
qbuf    = $6E00             ; Speech queue, high byte first
trkbuf  = $7000             ; One track, 16 sectors

MAXIN   = 12                ; Longest answer the player can type
MAXQ    = 16                ; Queue entries, the card takes 63

; Values GETCMD returns besides letters, Return and left arrow.
CMD_R   = $01
CMD_Z   = $02

; Modes.
M_SPELL = 0
M_LETTER = 1
M_MYST  = 2
M_CODE  = 3
M_SAYIT = 4

; Card status, also the footer text.
CS_NONE = 0
CS_OK   = 1
CS_STUCK = 2
CS_BAD  = 3

; Screen rows.
R_VFD   = 5
R_CAP   = 9
R_STAT  = 10
R_RES   = 11
R_FOOT  = 23
C_VFD   = 12
C_CAP   = 3

!zone vars
savesp  !byte 0
mode    !byte 0
cardok  !byte 0             ; Nonzero when speech goes to the card
cstat   !byte 0
round   !byte 0
score   !byte 0
deckpos !byte 0
wnum    !byte 0
wphlo   !byte 0
wphhi   !byte 0
wlen    !byte 0
wtext   !fill 16, 0
ilen    !byte 0
inp     !fill 16, 0
dlen    !byte 0
disp    !fill 20, 0
tries   !byte 0
helped  !byte 0
misses  !byte 0
lpos    !byte 0
qn      !byte 0
qflag   !byte 0
vstart  !byte 0
vcell   !byte 0
vcur    !byte 0             ; 1: VFD shows the _ cursor after the text
tmp     !byte 0
sumlo   !byte 0
sumhi   !byte 0
dsumlo  !byte 0
dsumhi  !byte 0
trk     !byte 0
sect    !byte 0

; MAIN:
!zone main
main    tsx
        stx savesp
        lda #0
        sta cardok
        sta mode
        lda #NWORDS
        sta deckpos         ; Forces a shuffle before the first word
        jsr HOME            ; Reset shows a clean text page
        jsr cls
        jsr hinit
        jsr frame
        jsr findcard
        bcs +
        lda #CS_OK
        sta cstat
        lda #1
        sta cardok
        bne ++
+       lda #CS_NONE
        sta cstat
++      jsr footer
        jsr load
        jsr prat
        !byte R_CAP, C_CAP
        !text "PRESS A KEY TO START", 0
        lda #38
        jsr clrto
        jsr getkey
        jmp start

; FRAME: the logo and the key legend on the HGR body.
!zone frame
frame   jsr prat
        !byte 22, 9
        !text "APPLE ][ SPEAK & SPELL", 0
        jsr prat
        !byte R_CAP-1, C_CAP
        !text "SPEAKS:", 0
        jsr prat
        !byte 13, 3
        !text "CONTROL-S SPELL   CONTROL-L LETTER", 0
        jsr prat
        !byte 14, 3
        !text "CONTROL-Y MYSTERY CONTROL-O CODE", 0
        jsr prat
        !byte 15, 3
        !text "CONTROL-I SAY IT  CONTROL-G GO", 0
        jsr prat
        !byte 17, 3
        !text "CONTROL-R REPEAT  CONTROL-C CLUE", 0
        jsr prat
        !byte 18, 3
        !text "CONTROL-Q QUIT TO DOS", 0
        jsr prat
        !byte 19, 3
        !text "LEFT ARROW ERASES A LETTER", 0
        jsr prat
        !byte 20, 3
        !text "RETURN TO SUBMIT ANSWER", 0
        lda #0
        sta dlen
        jmp vfd

; FOOTER: card status and mode name.
!zone footer
footer  ldx #R_FOOT
        ldy #2
        jsr gotoxy
        ldx cstat
        lda cstlo,x
        sta P
        lda csthi,x
        sta P+1
        jsr prstr
        lda cstat
        cmp #CS_OK
        bne +
        lda slot
        ora #$30
        jsr putch
+       lda #24
        jsr clrto
        jsr prat
        !byte R_FOOT, 24
        !text "MODE: ", 0
        ldx mode
        lda modlo,x
        sta P
        lda modhi,x
        sta P+1
        jsr prstr
        lda #38
        jmp clrto

cstlo   !byte <.s0, <.s1, <.s2, <.s3
csthi   !byte >.s0, >.s1, >.s2, >.s3
.s0     !text "NO CARD, TEXT ONLY", 0
.s1     !text "CARD IN SLOT ", 0
.s2     !text "CARD STUCK, TEXT", 0
.s3     !text "LOAD BAD, TEXT ONLY", 0
modlo   !byte <.m0, <.m1, <.m2, <.m3, <.m4
modhi   !byte >.m0, >.m1, >.m2, >.m3, >.m4
.m0     !text "SPELL", 0
.m1     !text "LETTER", 0
.m2     !text "MYSTERY", 0
.m3     !text "CODE", 0
.m4     !text "SAY IT", 0

; MSG: print the 0-terminated string at P on the caption line.
!zone msg
msg     ldx #R_CAP
        ldy #C_CAP
        jsr gotoxy
        jsr prstr
        lda #38
        jmp clrto

; LOAD: stream tracks 18-33 into the card through RWTS, then read the card
; back. With no card it only checksums the disk.
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
        lda #18
        sta trk
.trk    jsr prat
        !byte R_CAP, C_CAP
        !text "LOADING TRACK ", 0
        lda trk
        jsr prdec2
        lda #38
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
        cmp #34
        bcs +
        jmp .trk
+
        lda sumlo
        sta dsumlo
        lda sumhi
        sta dsumhi
        lda cardok
        bne .verify
        ; No card: the disk sum alone proves the read path.
        jsr .cmpsum
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
        !byte R_CAP, C_CAP
        !text "VERIFYING", 0
        lda #38
        jsr clrto
        jsr crew
        lda #0
        sta sumlo
        sta sumhi
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
        inc trk
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
        jsr footer
        jmp .wait
.show   jsr msg
.wait   lda #150
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
        jmp footer

; QUEUE:
; QCLR empties it. QPH adds phrase A, under 256. QADD adds X high, A low.
; QWORD adds the current word, QLET the letter in A ($C1-$DA).
!zone queue
qclr    lda #0
        sta qn
        rts
qph     ldx #0
qadd    pha
        lda qn
        cmp #MAXQ
        bcs +
        asl
        tay
        txa
        sta qbuf,y
        pla
        sta qbuf+1,y
        inc qn
        rts
+       pla
        rts
qword   ldx wphhi
        lda wphlo
        jmp qadd
qlet    and #$1F            ; $C1-$DA to 1-26
        clc
        adc #PH_A-1
        jmp qph

; SAY speaks the queue with its caption. SAYQ speaks it as a question, which
; shows only ? while a card is speaking it.
!zone say
sayq    lda #1
        bne +
say     lda #0
+       sta qflag
        jsr caption
        lda cardok
        bne .card
        lda qn              ; Text only: a pause per phrase
        beq ++
        sta tmp
-       lda #40
        jsr delay
        dec tmp
        bne -
++      rts
.card   lda qn
        beq ++
        jsr waitidle
        bcs .stuck
        jsr crew
        lda #$80
        jsr cwr
        lda qn
        jsr cwr
        asl
        sta tmp
        ldx #0
-       lda qbuf,x
        jsr cwr
        inx
        cpx tmp
        bcc -
        jsr cgo
        jsr waitbusy
        jsr waitidle
        bcs .stuck
++      rts
.stuck  jmp stuck

; CAPTION: what the queue says, on the caption line.
!zone caption
caption ldx #R_CAP
        ldy #C_CAP
        jsr gotoxy
        lda qflag
        and cardok
        beq +
        lda #'?'
        jsr putch
        jmp .clr
+       lda #0
        sta vcell
.ent    lda vcell
        cmp qn
        bcs .clr
        asl
        tax
        lda qbuf+1,x
        asl
        sta P
        lda qbuf,x
        rol
        sta P+1
        lda P
        clc
        adc #<cap_tab
        sta P
        lda P+1
        adc #>cap_tab
        sta P+1
        ldy #0
        lda (P),y
        tax
        iny
        lda (P),y
        sta P+1
        stx P
        ldy #0
        lda (P),y
        beq .nxt
        lda ccol
        cmp #C_CAP
        beq .ch
        cmp #38
        bcs .nxt
        lda #' '
        jsr putch
.ch     lda ccol
        cmp #39
        bcs .nxt
        ldy #0
        lda (P),y
        beq .nxt
        jsr putch
        inc P
        bne .ch
        inc P+1
        bne .ch
.nxt    inc vcell
        jmp .ent
.clr    lda #38
        jmp clrto

; SAYPH: speak phrase A. SAYLET: speak and caption letter A.
!zone sayph
sayph   pha
        jsr qclr
        pla
        jsr qph
        jmp say
saylet  pha
        jsr qclr
        pla
        jsr qlet
        jmp say
sayword jsr qclr
        jsr qword
        jmp sayq

; PRAISE: one of the five praise phrases.
!zone praise
praise  jsr qclr
        jsr qpraise
        jmp say
qpraise lda #5
        jsr random
        tax
        lda .tab,x
        jmp qph
.tab    !byte PH_CORRECT, 45, 46, 47, PH_YOURIGHT

; VFD: draw DISP on the 8 cells, the last 8 when longer.
!zone vfd
vfd     lda hgrq        ; The text cells stay on the text page only
        sta hgrsave
        lda #0
        sta hgrq
        ldx #R_VFD
        ldy #C_VFD
        jsr gotoxy
        lda dlen
        clc
        adc vcur
        sec
        sbc #8
        bcs +
        lda #0
+       sta vstart
        lda #0
        sta vcell
-       lda vcell
        clc
        adc vstart
        cmp dlen
        bcs +
        tax
        lda disp,x
        jmp ++
+       bne .off            ; Past the cursor cell
        ldx vcur
        beq .off
        lda #'_'+$80
        bne ++
.off    lda #$A0
++      pha
        jsr putraw
        lda #$A0
        jsr putraw
        pla
        bit hgrsave
        bpl +
        ldx vcell
        jsr hvcell
+       inc vcell
        lda vcell
        cmp #8
        bcc -
        lda hgrsave
        sta hgrq
        rts

; SHOWINP: put the typed answer on the VFD.
!zone showinp
showinp ldx #0
-       cpx ilen
        bcs +
        lda inp,x
        sta disp,x
        inx
        bne -
+       stx dlen
        cpx #MAXIN          ; No cursor once full
        lda #0
        rol
        eor #1
        sta vcur
        jsr vfd
        lda #0
        sta vcur
        rts

; SHOWWORD: the whole word on the VFD.
!zone showword
showword ldx #0
-       cpx wlen
        bcs +
        lda wtext,x
        sta disp,x
        inx
        bne -
+       stx dlen
        jmp vfd

; RESULT: A = 0 blank, 1 CORRECT, 2 INCORRECT.
!zone result
result  pha
        ldx #R_RES
        ldy #4
        jsr gotoxy
        pla
        beq +
        cmp #1
        bne ++
        jsr prat
        !byte R_RES, 4
        !text "CORRECT", 0
        jmp +
++      jsr prat
        !byte R_RES, 4
        !text "INCORRECT", 0
+       lda #14
        jmp clrto

; STATS: word and game counters, score, and miss marks.
!zone stats
stats   jsr prat
        !byte R_STAT, 4
        !text "WORD ", 0
        lda deckpos
        jsr prdec3
        jsr prat
        !byte R_STAT, 13
        !text "OF ", 0
        lda #NWORDS
        jsr prdec3
        lda mode
        cmp #M_SAYIT
        beq +
        jsr prat
        !byte R_STAT, 21
        !text "GAME ", 0
        ldx round
        inx
        txa
        jsr prdec2
        jsr prat
        !byte R_STAT, 28
        !text "/10", 0
+       lda #38
        jsr clrto
        ldx #R_RES
        ldy #14
        jsr gotoxy
        lda #38
        jsr clrto
        lda mode
        cmp #M_SAYIT
        beq ++
        jsr prat
        !byte R_RES, 15
        !text "SCORE ", 0
        lda score
        jsr prdec2
        lda misses
        beq ++
        jsr prat
        !byte R_RES, 25
        !text "MISS ", 0
        ldx misses
-       lda #'X'
        jsr putch
        dex
        bne -
++      rts

; SHUFFLE: fresh deck, Fisher-Yates.
!zone shuffle
shuffle ldx #0
-       txa
        sta deck,x
        inx
        cpx #NWORDS
        bcc -
        ldx #NWORDS-1
-       txa
        clc
        adc #1
        jsr random
        tay
        lda deck,x
        pha
        lda deck,y
        sta deck,x
        pla
        sta deck,y
        dex
        bne -
        stx deckpos
        rts

; NEWWORD: draw the next word into WTEXT, clear the round state.
!zone newword
newword lda deckpos
        cmp #NWORDS
        bcc +
        jsr shuffle
+       ldx deckpos
        lda deck,x
        sta wnum
        inc deckpos
        tax
        lda word_ph_lo,x
        sta wphlo
        asl
        sta P
        lda word_ph_hi,x
        sta wphhi
        rol
        sta P+1
        lda P
        clc
        adc #<cap_tab
        sta P
        lda P+1
        adc #>cap_tab
        sta P+1
        ldy #0
        lda (P),y
        tax
        iny
        lda (P),y
        sta P+1
        stx P
        ldy #0
-       lda (P),y
        beq +
        sta wtext,y
        iny
        bne -
+       sty wlen
        lda #0
        sta ilen
        sta dlen
        sta tries
        sta helped
        sta misses
        jsr vfd
        lda #0
        jsr result
        jmp stats

; GETCMD: wait for a key. Mode keys, Go and Quit act here and never return.
; Returns a letter $C1-$DA, K_RET, K_LEFT, CMD_R or CMD_Z.
!zone getcmd
getcmd  jsr getkey
        cmp #$E0
        bcc +
        and #$DF            ; Lowercase to uppercase
+       cmp #$C1
        bcc +
        cmp #$DB
        bcc .ret
+       cmp #K_RET
        beq .ret
        cmp #K_LEFT
        beq .ret
        cmp #$92            ; Ctrl-R
        bne +
        lda #CMD_R
.ret    rts
+       cmp #$83            ; Ctrl-C
        bne +
        lda #CMD_Z
        rts
+       ldx #M_SPELL
        cmp #$93            ; Ctrl-S
        beq .mode
        ldx #M_LETTER
        cmp #$8C            ; Ctrl-L
        beq .mode
        ldx #M_MYST
        cmp #$99            ; Ctrl-Y
        beq .mode
        ldx #M_CODE
        cmp #$8F            ; Ctrl-O
        beq .mode
        ldx #M_SAYIT
        cmp #$89            ; Ctrl-I
        beq .mode
        cmp #$87            ; Ctrl-G
        beq .go
        cmp #$91            ; Ctrl-Q
        bne getcmd
        jsr hdone
        jsr HOME
        jmp DOSWARM
.mode   stx mode
.go     jmp start

; START: begin a game in the current mode. Resets the stack, since a mode key
; can arrive from deep inside a round.
!zone start
start   ldx savesp
        txs
        jsr footer
        lda #0
        sta round
        sta score
        sta misses
        sta dlen
        jsr vfd
        lda #0
        jsr result
        ldx #R_CAP
        ldy #C_CAP
        jsr gotoxy
        lda #38
        jsr clrto
        lda mode
        cmp #M_SAYIT
        beq +
        lda #NWORDS-10
        cmp deckpos
        bcs +
        jsr shuffle
+       ldx mode
        lda .jlo,x
        sta P
        lda .jhi,x
        sta P+1
        jmp (P)
.jlo    !byte <m_spell, <m_letter, <m_myst, <m_code, <m_sayit
.jhi    !byte >m_spell, >m_letter, >m_myst, >m_code, >m_sayit

; NEXTROUND: count the round. Returns when the game goes on, and runs the
; score report and restarts the mode after the tenth.
!zone nextround
nextrnd inc round
        lda round
        cmp #10
        bcs +
        rts
+       jsr stats
        jsr qclr
        lda score
        cmp #10
        bne +
        jsr qpraise
        lda #PH_PERFECT
        jsr qph
        jmp ++
+       lda #PH_YOURSCORE
        jsr qph
        lda score
        clc
        adc #PH_ZERO
        jsr qph
++      jsr say
        lda #100
        jsr delay
        lda #0
        sta round
        sta score
        rts

; REVEAL: THAT IS INCORRECT, THE CORRECT SPELLING OF word IS, then each
; letter spoken as it appears.
!zone reveal
reveal  lda #2
        jsr result
        lda #PH_INCORRECT
        jsr sayph
        jsr qclr
        lda #PH_CORRECTSP
        jsr qph
        jsr qword
        lda #PH_IS
        jsr qph
        jsr say
        lda #0
        sta dlen
        jsr vfd
-       ldx dlen
        cpx wlen
        bcs +
        lda wtext,x
        sta disp,x
        inc dlen
        pha
        jsr vfd
        pla
        jsr saylet
        jmp -
+       rts

; SPELL MODE:
!zone spell
m_spell lda #PH_JINGLE1
        jsr sayph
.word   jsr newword
        jsr qclr
        lda round
        bne +
        lda #PH_SPELL
        bne ++
+       lda #2
        jsr random
        clc
        adc #PH_NOWSPELL
++      jsr qph
        jsr qword
        jsr sayq
        jsr showinp         ; Cursor: your turn to type
.in     jsr getcmd
        cmp #K_RET
        beq .enter
        cmp #K_LEFT
        beq .erase
        cmp #CMD_R
        beq .rep
        cmp #CMD_Z
        beq .clue
        ldx ilen
        cpx #MAXIN
        bcs .full
        sta inp,x
        inc ilen
        pha
        jsr showinp
        pla
        jsr saylet
        jmp .in
.full   lda #PH_TONE
        jsr sayph
        jmp .in
.erase  lda ilen
        beq .in
        dec ilen
        jsr showinp
        jmp .in
.rep    jsr sayword
        jmp .in
.clue   lda helped
        bne .in
        inc helped
        lda wtext
        sta inp
        lda #1
        sta ilen
        jsr showinp
        lda wtext
        jsr saylet
        jmp .in
.enter  lda ilen
        beq .in
        cmp wlen
        bne .wrong
        tax
-       dex
        bmi .right
        lda inp,x
        cmp wtext,x
        beq -
.wrong  lda tries
        bne .second
        inc tries
        lda #2
        jsr result
        lda #2
        jsr random
        tax
        lda .retry,x
        jsr sayph
        lda #0
        sta ilen
        jsr showinp
        jsr sayword
        jmp .in
.second jsr reveal
        jmp .next
.right  lda #1
        jsr result
        jsr praise
        lda helped
        bne .next
        inc score
.next   jsr nextrnd
        jmp .word
.retry  !byte PH_WRONG, PH_TRYAGAIN

; LETTER MODE:
!zone letter
m_letter lda #PH_JINGLE4
        jsr sayph
.word   jsr newword
        lda wlen
        jsr random
        sta lpos
        jsr showword
        ldx lpos
        lda #$20            ; Inverse space
        sta disp,x
        jsr vfd
        jsr sayword
.in     jsr getcmd
        cmp #CMD_R
        bne +
        jsr sayword
        jmp .in
+       cmp #$C1
        bcc .in
        ldx lpos
        cmp wtext,x
        beq .right
        lda tries
        bne .second
        inc tries
        lda #2
        jsr result
        lda #2
        jsr random
        tax
        lda .retry,x
        jsr sayph
        jsr sayword
        jmp .in
.second lda #2
        jsr result
        jsr qclr
        lda #PH_INCORRECT
        jsr qph
        ldx lpos
        lda wtext,x
        jsr qlet
        jsr say
        jsr showword
        jmp .next
.right  jsr showword
        lda #1
        jsr result
        jsr praise
        inc score
.next   jsr nextrnd
        jmp .word
.retry  !byte PH_TRY, PH_TRYAGAIN

; MYSTERY WORD MODE:
!zone mystery
m_myst  lda #PH_JINGLE2
        jsr sayph
.word   jsr newword
        ldx #0
-       lda #'-'+$80
        sta disp,x
        inx
        cpx wlen
        bcc -
        stx dlen
        jsr vfd
        jsr qclr
        lda #PH_NOWTRY
        jsr qph
        jsr qword
        jsr sayq
.in     jsr getcmd
        cmp #CMD_R
        bne +
        jsr sayword
        jmp .in
+       cmp #CMD_Z
        bne +
        ldx #0              ; Clue: the leftmost hidden letter
-       lda disp,x
        cmp #'-'+$80
        beq ++
        inx
        bne -
++      inc helped
        lda wtext,x
        jsr fill
        jsr vfd
        jmp .done
+       cmp #$C1
        bcc .in
        sta tmp
        jsr fill
        bne .hit
        lda #PH_TONE
        jsr sayph
        inc misses
        jsr stats
        lda misses
        cmp #5
        bcc .in
        jsr reveal
        jmp .next
.hit    jsr vfd
        lda tmp
        jsr saylet
.done   ldx #0
-       lda disp,x
        cmp #'-'+$80
        beq .in
        inx
        cpx wlen
        bcc -
        jsr qclr            ; Solved
        jsr qword
        jsr say
        lda misses
        ora helped
        bne +
        inc score
        lda #1
        jsr result
+       jsr stats
.next   jsr nextrnd
        jmp .word

; FILL: show letter A in every hidden cell that holds it. Returns the count
; filled in X, with Z set when none.
!zone fill
fill    sta tmp
        ldy #0
        ldx #0
-       cpx wlen
        bcs +
        lda wtext,x
        cmp tmp
        bne ++
        lda disp,x
        cmp #'-'+$80
        bne ++
        lda tmp
        sta disp,x
        iny
++      inx
        bne -
+       tya
        tax
        rts

; SECRET CODE MODE:
; Not a game, as on the toy. Each typed letter shows in code, and typing
; coded letters shows the message again, since the code is its own inverse.
; Return starts a new message.
!zone code
m_code  lda #PH_JINGLE3
        jsr sayph
.new    lda #0
        sta ilen
.show   jsr showinp
.in     jsr getcmd
        cmp #K_RET
        beq .new
        cmp #K_LEFT
        bne +
        lda ilen
        beq .in
        dec ilen
        jmp .show
+       cmp #$C1
        bcc .in
        ldx ilen
        cpx #MAXIN
        bcs .full
        jsr encode
        sta inp,x
        inc ilen
        jmp .show
.full   lda #PH_TONE
        jsr sayph
        jmp .in

; ENCODE: letter A, $C1-$DA, to its code letter. A becomes Z, B becomes Y.
!zone encode
encode  eor #$FF
        clc
        adc #$9C
        rts

; SAY IT MODE:
!zone sayit
m_sayit jsr shuffle
        lda #PH_SAYIT
        jsr sayph
.word   jsr newword
        jsr showword
.again  jsr qclr
        jsr qword
        jsr say
.in     jsr getcmd
        cmp #CMD_R
        beq .again
        cmp #$C1
        bcc .in
        jmp .word
