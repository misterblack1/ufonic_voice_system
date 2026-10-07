; Ufonic Voice System card, Rockwell R6500/1 internal mask ROM
; 2048 bytes at 0x0800 to 0x0fff, Borg-Warner Corporation 1983
; Hardware model behind these comments is in README.md

    .area CODE1 (ABS)
    .org 0x0800

; ON-CHIP RAM (0x0000 to 0x003f, page zero and the stack share it):
    cmd          = 0x00
    parm         = 0x01
    b_idle       = 0x02
    hex_tmp      = 0x07
    ptr_lo       = 0x08
    ptr_hi       = 0x09
    err_val      = 0x0a
    dump_lo      = 0x0b
    dump_hi      = 0x0c
    len_lo       = 0x0d
    len_hi       = 0x0e
    skip_n       = 0x10
    rep_n        = 0x11
    accum        = 0x12
    x_save       = 0x14
    char_dly     = 0x16
    tmp17        = 0x17

; R6500/1 I/O REGISTERS:
    PORT_A       = 0x80        ; DRAM data bus, bidirectional
    PORT_B       = 0x81        ; Host status and character output
    PORT_C       = 0x82        ; Strobes and handshakes, see below
    PORT_D       = 0x83        ; TMS5220 data bus, bidirectional
    CONTROL      = 0x8f        ; On-chip counter and interrupt control

; PORT_C BIT ASSIGNMENTS:
;   Bit 0  IN   Host attention or stop, active HIGH
;   Bit 1  OUT  DRAM address counter clock       mask 0xfd
;   Bit 2  OUT  /WS to the TMS5220               mask 0xfb
;   Bit 3  OUT  DRAM read strobe                 mask 0xf7
;   Bit 4  OUT  /RS to the TMS5220               mask 0xef
;   Bit 5  OUT  DRAM output enable and increment mask 0xdf
;   Bit 6  IN   /INT from the TMS5220, buffer low
;   Bit 7  IN   /READY from the TMS5220


; ==========================================================================
; RESET / power-on entry  (all three vectors point here)
; Brings up the 6500/1 ports, runs TI's mandated TMS5220 initialisation,
; wipes the 64 bytes of on-chip RAM, then falls into the command loop.
;
; The nine 0xff writes at 0x0817 are straight out of the datasheet (sec. 7,
; Power-Up Clear): "A 100-percent assurance can be given that the VSP is in
; a clear state by writing nine bytes of all ones to the VSP followed by a
; Reset command." 0xff satisfies both halves at once. It is all-ones and it
; also decodes as RESET, command field X111XXXX.
; ==========================================================================
reset:
    lda #0x00               ;0800  a9 00     disable on-chip counter/interrupts
    sta CONTROL             ;0802  85 8f
    ldx #0x3f               ;0804  a2 3f     stack lives in the top of the 64-byte RAM
    txs                     ;0806  9a
    lda #0xff               ;0807  a9 ff     float PORT_A (DRAM bus) and PORT_D (5220 bus)
    sta PORT_A              ;0809  85 80
    sta PORT_D              ;080b  85 83
    lda #0xff               ;080d  a9 ff     all strobes inactive high
    sta PORT_C              ;080f  85 82
    lda #0xdf               ;0811  a9 df     PORT_B: bit 5 low, rest high
    sta PORT_B              ;0813  85 81
    ldy #0x09               ;0815  a0 09     TI's mandated init: 9 bytes of all-ones
reset_tms_loop:
    lda #0xff               ;0817  a9 ff     0xff: all-ones, and also decodes as RESET
    jsr tms_write           ;0819  20 2b 0d
    ldx #0x3c               ;081c  a2 3c     60 x 5 cycles ~= 300 us between resets
    jsr delay_x             ;081e  20 c5 0d
    dey                     ;0821  88
    bne reset_tms_loop      ;0822  d0 f3
    ldx #0x3f               ;0824  a2 3f     fill RAM 0x01..0x3f (skip 0x00)
    lda #0x11               ;0826  a9 11     0x11, also the filler byte in the copyright block
clear_ram:
    sta cmd,x               ;0828  95 00
    dex                     ;082a  ca
    bne clear_ram           ;082b  d0 fb
    lda #0x13               ;082d  a9 13     default inter-character delay
    sta char_dly            ;082f  85 16
    lda #0x5f               ;0831  a9 5f     PORT_B idle pattern: 0b0101_1111
    sta b_idle              ;0833  85 02
    sta PORT_B              ;0835  85 81

; ==========================================================================
; MAIN COMMAND LOOP
; Pulses the DRAM address counter back to 0, tells the host "idle" on
; PORT_B, waits for the host's attention line (PC0), then fetches a
; 2-byte command packet from the head of the shared 64 KiB DRAM.
;
;   cmd (0x00)    parm (0x01)   meaning
;   ----------    -----------   -------------------------------------------
;   0x00 0x00     -             speak the ROM-resident test phrase
;   0x00..0x02    <0x5e         phrase index -> vocabulary table in DRAM
;   0x03..0x1f    varies        diagnostic command (see cmd_table)
;   0x20..0xbf    -             invalid -> restart
;   0x80          count         play <count & 0x3f> consecutive phrases
;   0xc0..0xff    units         timed pause, then restart
; ==========================================================================
main:
    lda #0xfd               ;0837  a9 fd     pulse PC1: rewind DRAM address counter
    sta PORT_C              ;0839  85 82
    lda #0xff               ;083b  a9 ff
    sta PORT_C              ;083d  85 82
arm_and_wait:
    lda b_idle              ;083f  a5 02     tell the host we are idle (bit 7 clear)
    sta PORT_B              ;0841  85 81
wait_host:
    lda PORT_C              ;0843  a5 82     poll PC0 for host attention
    and #0x01               ;0845  29 01
    beq wait_host           ;0847  f0 fa
    lda b_idle              ;0849  a5 02     set bit 7 = busy / command accepted
    ora #0x80               ;084b  09 80
    sta PORT_B              ;084d  85 81
    lda #0x00               ;084f  a9 00     no slots to skip
    sta skip_n              ;0851  85 10
    lda #0x01               ;0853  a9 01     play exactly one phrase
    sta rep_n               ;0855  85 11
    jsr ram_get_cmd         ;0857  20 6e 0d  fetch cmd/parm from DRAM 0x0000
    lda cmd                 ;085a  a5 00
    cmp #0x03               ;085c  c9 03     < 3 -> a phrase index
    bcc seq_loop            ;085e  90 22
    cmp #0x80               ;0860  c9 80     0x80 -> multi-phrase play
    bne chk_range           ;0862  d0 0d
    lda #0x01               ;0864  a9 01     start one slot in
    sta skip_n              ;0866  85 10
    lda parm                ;0868  a5 01     low 6 bits = how many phrases
    and #0x3f               ;086a  29 3f
    sta rep_n               ;086c  85 11
    jmp seq_loop            ;086e  4c 82 08
chk_range:
    cmp #0xc0               ;0871  c9 c0     0xc0..0xff -> timed pause
    bcs do_pause            ;0873  b0 07
    cmp #0x20               ;0875  c9 20     0x20..0xbf -> invalid
    bcs main                ;0877  b0 be
    jmp dispatch            ;0879  4c 60 09  0x03..0x1f -> diagnostic command
do_pause:
    jsr pause               ;087c  20 3a 0d
    jmp main                ;087f  4c 37 08

; ==========================================================================
; Phrase sequencer.
; skip_n phrase slots are stepped over by reading 2 bytes per slot out of
; the auto-incrementing DRAM, then the slot that lands under the pointer
; is decoded and spoken. Repeats rep_n times.
; ==========================================================================
seq_loop:
    lda skip_n              ;0882  a5 10     anything to skip?
    beq have_index          ;0884  f0 41
    jsr ram_get_cmd         ;0886  20 6e 0d  re-read cmd/parm (rewinds the counter)
    lda skip_n              ;0889  a5 10
    and #0x3f               ;088b  29 3f     skip count, max 63
    tax                     ;088d  aa
skip_loop:
    lda #0xdf               ;088e  a9 df     2-byte DRAM read, unrolled
    sta PORT_C              ;0890  85 82
    lda #0xf7               ;0892  a9 f7
    sta PORT_C              ;0894  85 82
    lda PORT_A              ;0896  a5 80     data appears on PORT_A
    pha                     ;0898  48
    lda #0xff               ;0899  a9 ff
    sta PORT_C              ;089b  85 82
    pla                     ;089d  68
    sta cmd                 ;089e  85 00
    lda #0xdf               ;08a0  a9 df
    sta PORT_C              ;08a2  85 82
    lda #0xf7               ;08a4  a9 f7
    sta PORT_C              ;08a6  85 82
    lda PORT_A              ;08a8  a5 80
    pha                     ;08aa  48
    lda #0xff               ;08ab  a9 ff
    sta PORT_C              ;08ad  85 82
    pla                     ;08af  68
    sta parm                ;08b0  85 01
    dex                     ;08b2  ca
    bne skip_loop           ;08b3  d0 d9
    inc skip_n              ;08b5  e6 10     advance to the next slot
    lda cmd                 ;08b7  a5 00     0xc0 in the high byte = end-of-list
    cmp #0xc0               ;08b9  c9 c0
    bcc have_index          ;08bb  90 0a
    jsr pause               ;08bd  20 3a 0d  treat the tail as a pause
    dec rep_n               ;08c0  c6 11
    bne seq_loop            ;08c2  d0 be
    jmp seq_done            ;08c4  4c 55 09
have_index:
    lda cmd                 ;08c7  a5 00     index == 0x0000 ?
    bne chk_hi              ;08c9  d0 0d
    lda parm                ;08cb  a5 01
    bne index_ok            ;08cd  d0 15
    jsr speak_builtin       ;08cf  20 8d 0c  yes -> emit the built-in test tone
    bcc next_rep            ;08d2  90 7a
    clc                     ;08d4  18
    jmp main                ;08d5  4c 37 08
chk_hi:
    cmp #0x02               ;08d8  c9 02     index high byte >= 2 ?
    bcc index_ok            ;08da  90 08
    bne next_rep            ;08dc  d0 70
    lda parm                ;08de  a5 01     0x02xx only valid below 0x025e
    cmp #0x5e               ;08e0  c9 5e
    bcs next_rep            ;08e2  b0 6a

; ==========================================================================
; Convert phrase index -> DRAM byte offset.
;   offset = (index << 1) + 0x80
; a table of 16-bit pointers based at DRAM 0x0080, holding up to
; ~0x2bf entries. The 16-bit result is left in ptr_lo/ptr_hi, the DRAM
; address counter is rewound, and ptr_lo bytes are skipped to reach the
; entry. The two bytes read there are the phrase's own start address.
; ==========================================================================
index_ok:
    asl parm                ;08e4  06 01     index * 2
    rol cmd                 ;08e6  26 00
    lda parm                ;08e8  a5 01
    cld                     ;08ea  d8        6500/1 does not clear D on reset
    clc                     ;08eb  18
    adc #0x80               ;08ec  69 80     + 0x0080 = base of the pointer table
    sta ptr_lo              ;08ee  85 08
    lda #0x00               ;08f0  a9 00
    adc cmd                 ;08f2  65 00
    sta ptr_hi              ;08f4  85 09
    jsr ram_set_addr        ;08f6  20 98 0d  load the pointer's high byte into the counter
    ldx ptr_lo              ;08f9  a6 08     skip ptr_lo bytes...
    beq read_addr           ;08fb  f0 0b
    lda #0xdf               ;08fd  a9 df
    ldy #0xff               ;08ff  a0 ff
skip_lo_loop:
    sta PORT_C              ;0901  85 82
    sty PORT_C              ;0903  84 82
    dex                     ;0905  ca
    bne skip_lo_loop        ;0906  d0 f9
read_addr:
    lda #0xdf               ;0908  a9 df     ...then read the 16-bit phrase address
    sta PORT_C              ;090a  85 82
    lda #0xf7               ;090c  a9 f7
    sta PORT_C              ;090e  85 82
    lda PORT_A              ;0910  a5 80
    pha                     ;0912  48
    lda #0xff               ;0913  a9 ff
    sta PORT_C              ;0915  85 82
    pla                     ;0917  68
    sta cmd                 ;0918  85 00
    lda #0xdf               ;091a  a9 df
    sta PORT_C              ;091c  85 82
    lda #0xf7               ;091e  a9 f7
    sta PORT_C              ;0920  85 82
    lda PORT_A              ;0922  a5 80
    pha                     ;0924  48
    lda #0xff               ;0925  a9 ff
    sta PORT_C              ;0927  85 82
    pla                     ;0929  68
    jsr ram_set_addr        ;092a  20 98 0d  load the counter with the high half
    lda cmd                 ;092d  a5 00
    ldx cmd                 ;092f  a6 00     and skip that many more
    beq speak_it            ;0931  f0 0b
    lda #0xdf               ;0933  a9 df
    ldy #0xff               ;0935  a0 ff
skip_hi_loop:
    sta PORT_C              ;0937  85 82
    sty PORT_C              ;0939  84 82
    dex                     ;093b  ca
    bne skip_hi_loop        ;093c  d0 f9
speak_it:
    nop                     ;093e  ea        (alignment)
    lda #0xff               ;093f  a9 ff     flush the 5220 before the new utterance
    jsr tms_write           ;0941  20 2b 0d
    ldx #0x3c               ;0944  a2 3c
    jsr delay_x             ;0946  20 c5 0d
    jsr speak_from_ram      ;0949  20 39 0c  stream the phrase out of DRAM
    bcs speak_abort         ;094c  b0 0e     abnormal status -> give up
next_rep:
    dec rep_n               ;094e  c6 11
    beq seq_done            ;0950  f0 03
    jmp seq_loop            ;0952  4c 82 08
seq_done:
    lda b_idle              ;0955  a5 02     release the busy flag
    sta PORT_B              ;0957  85 81
    jmp main                ;0959  4c 37 08
speak_abort:
    clc                     ;095c  18
    jmp main                ;095d  4c 37 08

; ==========================================================================
; Diagnostic command dispatch.
; A is 0x03..0x1f here. The low nibble indexes a 16-entry vector table.
; Unimplemented slots point back at `main`, so a bad command is a no-op.
; ==========================================================================
dispatch:
    and #0x0f               ;0960  29 0f     16 entries
    asl a                   ;0962  0a        x2 for a word table
    tay                     ;0963  a8
    lda cmd_table,y         ;0964  b9 72 09
    sta ptr_lo              ;0967  85 08
    iny                     ;0969  c8
    lda cmd_table,y         ;096a  b9 72 09
    sta ptr_hi              ;096d  85 09
    jmp [ptr_lo]            ;096f  6c 08 00  vector through zero page

; ==========================================================================
; Dispatch vector table, 16 x 16-bit little-endian addresses.
; Indexed by (cmd & 0x0f), so the nominal command numbers are 0x10..0x1f.
; ==========================================================================
cmd_table:
    .word 0x0992              ;0972  92 09     command 0x10             cmd10_ram_refresh
    .word 0x09bb              ;0974  bb 09     command 0x11             cmd11_verify_ramp
    .word 0x0a13              ;0976  13 0a     command 0x12             cmd12_ram_write
    .word 0x0a48              ;0978  48 0a     command 0x13             cmd13_test_lo
    .word 0x0a8c              ;097a  8c 0a     command 0x14             cmd14_test_hi
    .word 0x0837              ;097c  37 08     unimplemented -> restart main
    .word 0x0837              ;097e  37 08     unimplemented -> restart main
    .word 0x0837              ;0980  37 08     unimplemented -> restart main
    .word 0x0ad0              ;0982  d0 0a     command 0x18             cmd18_ram_stream
    .word 0x0837              ;0984  37 08     unimplemented -> restart main
    .word 0x0ae9              ;0986  e9 0a     command 0x1a             cmd1a_ram_sum
    .word 0x0837              ;0988  37 08     unimplemented -> restart main
    .word 0x0bc9              ;098a  c9 0b     command 0x1c             cmd1c_rom_sum
    .word 0x0bec              ;098c  ec 0b     command 0x1d             cmd1d_set_delay
    .word 0x0837              ;098e  37 08     unimplemented -> restart main
    .word 0x0bf3              ;0990  f3 0b     command 0x1f             cmd1f_ram_dump

; ==========================================================================
; CMD 0x10: walk all 64 KiB of DRAM.
; Reads every location once (256 x 256) with no checking. This is a
; refresh pass that exercises the array. It ends by driving PORT_B low and
; pausing about 100 ms.
; ==========================================================================
cmd10_ram_refresh:
    lda #0x00               ;0992  a9 00     page 0 -> rewind to DRAM 0x0000
    jsr ram_set_addr        ;0994  20 98 0d
    ldx #0x00               ;0997  a2 00     65536 iterations
    ldy #0x00               ;0999  a0 00
c10_loop:
    lda #0xdf               ;099b  a9 df
    sta PORT_C              ;099d  85 82
    lda #0xf7               ;099f  a9 f7
    sta PORT_C              ;09a1  85 82
    lda PORT_A              ;09a3  a5 80
    pha                     ;09a5  48
    lda #0xff               ;09a6  a9 ff
    sta PORT_C              ;09a8  85 82
    pla                     ;09aa  68
    inx                     ;09ab  e8
    bne c10_loop            ;09ac  d0 ed
    iny                     ;09ae  c8
    bne c10_loop            ;09af  d0 ea
    lda #0x00               ;09b1  a9 00     drive every PORT_B line low
    sta PORT_B              ;09b3  85 81
    jsr delay_60ms          ;09b5  20 c9 0d
    jmp main                ;09b8  4c 37 08

; ==========================================================================
; CMD 0x11: verify DRAM holds an incrementing ramp.
; Reads 64 KiB and compares each byte against a local counter. Every
; mismatch re-syncs the counter and emits one low pulse on PORT_B bit 0
; (an audible click / LED blink on the host end). Runs until the host
; raises PC0.
; ==========================================================================
cmd11_verify_ramp:
    jsr ram_get_cmd         ;09bb  20 6e 0d
    jsr delay_60ms          ;09be  20 c9 0d
    lda #0xff               ;09c1  a9 ff     release PORT_B
    sta PORT_B              ;09c3  85 81
    ldx #0x00               ;09c5  a2 00
    ldy #0x00               ;09c7  a0 00
    stx accum               ;09c9  86 12
    lda cmd                 ;09cb  a5 00     entered as cmd 0x11 or as an alias?
    cmp #0x11               ;09cd  c9 11
    beq c11_first           ;09cf  f0 08
    lda #0xfe               ;09d1  a9 fe     alias: emit one click first
    sta PORT_B              ;09d3  85 81
    lda #0xff               ;09d5  a9 ff
    sta PORT_B              ;09d7  85 81
c11_first:
    inx                     ;09d9  e8
    inc accum               ;09da  e6 12
    lda parm                ;09dc  a5 01
    jmp c11_test            ;09de  4c f1 09
c11_read:
    lda #0xdf               ;09e1  a9 df
    sta PORT_C              ;09e3  85 82
    lda #0xf7               ;09e5  a9 f7
    sta PORT_C              ;09e7  85 82
    lda PORT_A              ;09e9  a5 80
    pha                     ;09eb  48
    lda #0xff               ;09ec  a9 ff
    sta PORT_C              ;09ee  85 82
    pla                     ;09f0  68
c11_test:
    cmp accum               ;09f1  c5 12     does the byte match the expected ramp?
    beq c11_next            ;09f3  f0 0a
    sta accum               ;09f5  85 12     no, so resync and click
    lda #0xfe               ;09f7  a9 fe
    sta PORT_B              ;09f9  85 81
    lda #0xff               ;09fb  a9 ff
    sta PORT_B              ;09fd  85 81
c11_next:
    inc accum               ;09ff  e6 12
    inx                     ;0a01  e8
    bne c11_read            ;0a02  d0 dd
    iny                     ;0a04  c8
    bne c11_read            ;0a05  d0 da
    lda PORT_C              ;0a07  a5 82     host asked to stop?
    and #0x01               ;0a09  29 01
    beq cmd11_verify_ramp   ;0a0b  f0 ae
    jsr put_space           ;0a0d  20 44 0e  print a space and return
    jmp main                ;0a10  4c 37 08

; ==========================================================================
; CMD 0x12: write a byte into DRAM.
; parm is driven onto PORT_A, one DRAM cycle latches it, then the address
; counter is pulsed. The byte read back becomes a repeat count: the
; address is then advanced that many more times.
; ==========================================================================
cmd12_ram_write:
    lda parm                ;0a13  a5 01     drive the byte onto the DRAM bus
    sta PORT_A              ;0a15  85 80
    lda #0xdf               ;0a17  a9 df
    sta PORT_C              ;0a19  85 82
    lda #0xf7               ;0a1b  a9 f7
    sta PORT_C              ;0a1d  85 82
    lda PORT_A              ;0a1f  a5 80
    pha                     ;0a21  48
    lda #0xff               ;0a22  a9 ff
    sta PORT_C              ;0a24  85 82
    pla                     ;0a26  68
    ldx #0xfd               ;0a27  a2 fd     pulse PC1 to latch/advance
    stx PORT_C              ;0a29  86 82
    ldx #0xff               ;0a2b  a2 ff
    stx PORT_C              ;0a2d  86 82
    tax                     ;0a2f  aa        byte read back = extra advance count
    beq c12_done            ;0a30  f0 13
c12_adv:
    lda #0xdf               ;0a32  a9 df
    sta PORT_C              ;0a34  85 82
    lda #0xf7               ;0a36  a9 f7
    sta PORT_C              ;0a38  85 82
    lda PORT_A              ;0a3a  a5 80
    pha                     ;0a3c  48
    lda #0xff               ;0a3d  a9 ff
    sta PORT_C              ;0a3f  85 82
    pla                     ;0a41  68
    dex                     ;0a42  ca
    bne c12_adv             ;0a43  d0 ed
c12_done:
    jmp arm_and_wait        ;0a45  4c 3f 08

; ==========================================================================
; CMD 0x13: address-ramp test, low byte.
; Walks 64 KiB comparing each byte to the low half of the address.
; Mismatches are reported in hex through `report_err`. Loops forever
; until the operator answers "no" to the continue prompt.
; ==========================================================================
cmd13_test_lo:
    jsr ram_get_cmd         ;0a48  20 6e 0d
    jsr delay_60ms          ;0a4b  20 c9 0d
    ldx #0x00               ;0a4e  a2 00
    ldy #0x00               ;0a50  a0 00
    lda cmd                 ;0a52  a5 00     entered as cmd 0x13 or as an alias?
    cmp #0x13               ;0a54  c9 13
    beq c13_first           ;0a56  f0 03
    jsr report_err          ;0a58  20 ff 0d
c13_first:
    inx                     ;0a5b  e8
    lda parm                ;0a5c  a5 01
    jmp c13_test            ;0a5e  4c 71 0a
c13_read:
    lda #0xdf               ;0a61  a9 df
    sta PORT_C              ;0a63  85 82
    lda #0xf7               ;0a65  a9 f7
    sta PORT_C              ;0a67  85 82
    lda PORT_A              ;0a69  a5 80
    pha                     ;0a6b  48
    lda #0xff               ;0a6c  a9 ff
    sta PORT_C              ;0a6e  85 82
    pla                     ;0a70  68
c13_test:
    sta ptr_hi              ;0a71  85 09     compare against the address low byte
    cpx ptr_hi              ;0a73  e4 09
    beq c13_next            ;0a75  f0 07
    stx err_val             ;0a77  86 0a     stash the bad value for the report
    jsr report_err          ;0a79  20 ff 0d
    bcs c13_done            ;0a7c  b0 0b     operator said stop
c13_next:
    inx                     ;0a7e  e8
    bne c13_read            ;0a7f  d0 e0
    iny                     ;0a81  c8
    bne c13_read            ;0a82  d0 dd
    jsr ask_more            ;0a84  20 2b 0e  ask whether to run another pass
    bcc cmd13_test_lo       ;0a87  90 bf
c13_done:
    jmp main                ;0a89  4c 37 08

; ==========================================================================
; CMD 0x14: address-ramp test, high byte.
; As cmd 0x13 but compares against the high half of the address.
; ==========================================================================
cmd14_test_hi:
    jsr ram_get_cmd         ;0a8c  20 6e 0d
    jsr delay_60ms          ;0a8f  20 c9 0d
    ldx #0x00               ;0a92  a2 00
    ldy #0x00               ;0a94  a0 00
    lda cmd                 ;0a96  a5 00     entered as cmd 0x14 or as an alias?
    cmp #0x14               ;0a98  c9 14
    beq c14_first           ;0a9a  f0 03
    jsr report_err          ;0a9c  20 ff 0d
c14_first:
    inx                     ;0a9f  e8
    lda parm                ;0aa0  a5 01
    jmp c14_test            ;0aa2  4c b5 0a
c14_read:
    lda #0xdf               ;0aa5  a9 df
    sta PORT_C              ;0aa7  85 82
    lda #0xf7               ;0aa9  a9 f7
    sta PORT_C              ;0aab  85 82
    lda PORT_A              ;0aad  a5 80
    pha                     ;0aaf  48
    lda #0xff               ;0ab0  a9 ff
    sta PORT_C              ;0ab2  85 82
    pla                     ;0ab4  68
c14_test:
    sta ptr_hi              ;0ab5  85 09
    cpy ptr_hi              ;0ab7  c4 09     compare against the address high byte
    beq c14_next            ;0ab9  f0 07
    sty err_val             ;0abb  84 0a
    jsr report_err          ;0abd  20 ff 0d
    bcs c14_done            ;0ac0  b0 0b
c14_next:
    inx                     ;0ac2  e8
    bne c14_read            ;0ac3  d0 e0
    iny                     ;0ac5  c8
    bne c14_read            ;0ac6  d0 dd
    jsr ask_more            ;0ac8  20 2b 0e
    bcc cmd14_test_hi       ;0acb  90 bf
c14_done:
    jmp main                ;0acd  4c 37 08

; ==========================================================================
; CMD 0x18: free-run DRAM reads until the host interrupts.
; Tightest possible read loop, useful for scoping the DRAM strobes.
; ==========================================================================
cmd18_ram_stream:
    lda #0x00               ;0ad0  a9 00
    jsr ram_set_addr        ;0ad2  20 98 0d
    ldx #0xdf               ;0ad5  a2 df
    ldy #0xff               ;0ad7  a0 ff
c18_loop:
    stx PORT_C              ;0ad9  86 82     free-run the DRAM read strobes
    sty PORT_C              ;0adb  84 82
    lda PORT_C              ;0add  a5 82     until the host raises PC0
    and #0x01               ;0adf  29 01
    beq c18_loop            ;0ae1  f0 f6
    jsr put_space           ;0ae3  20 44 0e
    jmp main                ;0ae6  4c 37 08

; ==========================================================================
; CMD 0x1a: checksum a DRAM range.
; Points the address counter at page 0x05, steps 0x3c bytes in, picks up a
; 16-bit length from DRAM, sums that many bytes, and prints the computed
; 8-bit sum, the stored sum and a trailing marker byte.
; ==========================================================================
cmd1a_ram_sum:
    lda #0x05               ;0ae9  a9 05     address counter -> page 0x05 (DRAM 0x0500)
    jsr ram_set_addr        ;0aeb  20 98 0d
    ldx #0x3c               ;0aee  a2 3c     then step 0x3c bytes in
c1a_skip:
    lda #0xdf               ;0af0  a9 df
    sta PORT_C              ;0af2  85 82
    lda #0xf7               ;0af4  a9 f7
    sta PORT_C              ;0af6  85 82
    lda PORT_A              ;0af8  a5 80
    pha                     ;0afa  48
    lda #0xff               ;0afb  a9 ff
    sta PORT_C              ;0afd  85 82
    pla                     ;0aff  68
    dex                     ;0b00  ca
    bne c1a_skip            ;0b01  d0 ed
    lda #0xdf               ;0b03  a9 df
    sta PORT_C              ;0b05  85 82
    lda #0xf7               ;0b07  a9 f7
    sta PORT_C              ;0b09  85 82
    lda PORT_A              ;0b0b  a5 80
    pha                     ;0b0d  48
    lda #0xff               ;0b0e  a9 ff
    sta PORT_C              ;0b10  85 82
    pla                     ;0b12  68
    sta len_lo              ;0b13  85 0d     length low
    lda #0xdf               ;0b15  a9 df
    sta PORT_C              ;0b17  85 82
    lda #0xf7               ;0b19  a9 f7
    sta PORT_C              ;0b1b  85 82
    lda PORT_A              ;0b1d  a5 80
    pha                     ;0b1f  48
    lda #0xff               ;0b20  a9 ff
    sta PORT_C              ;0b22  85 82
    pla                     ;0b24  68
    sta len_hi              ;0b25  85 0e     length high
    lda #0xdf               ;0b27  a9 df
    sta PORT_C              ;0b29  85 82
    lda #0xf7               ;0b2b  a9 f7
    sta PORT_C              ;0b2d  85 82
    lda PORT_A              ;0b2f  a5 80
    pha                     ;0b31  48
    lda #0xff               ;0b32  a9 ff
    sta PORT_C              ;0b34  85 82
    pla                     ;0b36  68
    jsr put_hex             ;0b37  20 49 0e  echo both length bytes
    lda #0xdf               ;0b3a  a9 df
    sta PORT_C              ;0b3c  85 82
    lda #0xf7               ;0b3e  a9 f7
    sta PORT_C              ;0b40  85 82
    lda PORT_A              ;0b42  a5 80
    pha                     ;0b44  48
    lda #0xff               ;0b45  a9 ff
    sta PORT_C              ;0b47  85 82
    pla                     ;0b49  68
    jsr put_hex             ;0b4a  20 49 0e
    lda #0x00               ;0b4d  a9 00
    jsr ram_set_addr        ;0b4f  20 98 0d
    ldx #0x80               ;0b52  a2 80     step another 0x80 bytes in
c1a_skip2:
    lda #0xdf               ;0b54  a9 df
    sta PORT_C              ;0b56  85 82
    lda #0xf7               ;0b58  a9 f7
    sta PORT_C              ;0b5a  85 82
    lda PORT_A              ;0b5c  a5 80
    pha                     ;0b5e  48
    lda #0xff               ;0b5f  a9 ff
    sta PORT_C              ;0b61  85 82
    pla                     ;0b63  68
    dex                     ;0b64  ca
    bne c1a_skip2           ;0b65  d0 ed
    lda #0xdf               ;0b67  a9 df
    sta PORT_C              ;0b69  85 82
    lda #0xf7               ;0b6b  a9 f7
    sta PORT_C              ;0b6d  85 82
    lda PORT_A              ;0b6f  a5 80
    pha                     ;0b71  48
    lda #0xff               ;0b72  a9 ff
    sta PORT_C              ;0b74  85 82
    pla                     ;0b76  68
    sta tmp17               ;0b77  85 17     expected checksum from DRAM
    lda #0xdf               ;0b79  a9 df
    sta PORT_C              ;0b7b  85 82
    lda #0xf7               ;0b7d  a9 f7
    sta PORT_C              ;0b7f  85 82
    lda PORT_A              ;0b81  a5 80
    pha                     ;0b83  48
    lda #0xff               ;0b84  a9 ff
    sta PORT_C              ;0b86  85 82
    pla                     ;0b88  68
    lda len_lo              ;0b89  a5 0d     length -= 0x82 (header already consumed)
    sec                     ;0b8b  38
    sbc #0x82               ;0b8c  e9 82
    sta ptr_lo              ;0b8e  85 08
    lda len_hi              ;0b90  a5 0e
    sbc #0x00               ;0b92  e9 00
    sta ptr_hi              ;0b94  85 09
    lda #0x00               ;0b96  a9 00     running sum
    sta accum               ;0b98  85 12
c1a_sum_loop:
    lda #0xdf               ;0b9a  a9 df
    sta PORT_C              ;0b9c  85 82
    lda #0xf7               ;0b9e  a9 f7
    sta PORT_C              ;0ba0  85 82
    lda PORT_A              ;0ba2  a5 80
    pha                     ;0ba4  48
    lda #0xff               ;0ba5  a9 ff
    sta PORT_C              ;0ba7  85 82
    pla                     ;0ba9  68
    clc                     ;0baa  18
    adc accum               ;0bab  65 12     8-bit sum, carry ignored
    sta accum               ;0bad  85 12
    dec ptr_lo              ;0baf  c6 08
    bne c1a_sum_loop        ;0bb1  d0 e7
    dec ptr_hi              ;0bb3  c6 09
    bne c1a_sum_loop        ;0bb5  d0 e3
    lda accum               ;0bb7  a5 12     computed sum
    jsr put_hex             ;0bb9  20 49 0e
    lda tmp17               ;0bbc  a5 17     stored sum
    jsr put_hex             ;0bbe  20 49 0e
    lda #0x84               ;0bc1  a9 84     0x84 = end-of-report marker
    jsr putc                ;0bc3  20 d5 0d
    jmp main                ;0bc6  4c 37 08

; ==========================================================================
; CMD 0x1c: checksum the ROM.
; Byte-wise sum of 0x0800-0x0fff, printed as two hex digits. Note the
; `cld` on entry: the 6500/1 does not clear the decimal flag on reset,
; so every arithmetic routine in this ROM clears it by hand.
; ==========================================================================
cmd1c_rom_sum:
    lda #0x00               ;0bc9  a9 00     pointer = 0x0800
    tay                     ;0bcb  a8
    sta ptr_lo              ;0bcc  85 08
    ldx #0x08               ;0bce  a2 08
    stx ptr_hi              ;0bd0  86 09
    cld                     ;0bd2  d8        binary, not BCD
c1c_loop:
    clc                     ;0bd3  18
    adc [ptr_lo],y          ;0bd4  71 08     sum one byte
    iny                     ;0bd6  c8
    bne c1c_loop            ;0bd7  d0 fa
    inc ptr_hi              ;0bd9  e6 09
    ldx ptr_hi              ;0bdb  a6 09
    cpx #0x10               ;0bdd  e0 10     stop after page 0x0f
    bcc c1c_loop            ;0bdf  90 f2
    jsr put_hex             ;0be1  20 49 0e
    lda #0x84               ;0be4  a9 84     end-of-report marker
    jsr putc                ;0be6  20 d5 0d
    jmp main                ;0be9  4c 37 08

; ==========================================================================
; CMD 0x1d: set the inter-character delay used by `putc`.
; This is the closest thing the ROM has to a baud-rate control.
; ==========================================================================
cmd1d_set_delay:
    lda parm                ;0bec  a5 01     parm becomes the new delay
    sta char_dly            ;0bee  85 16
    jmp main                ;0bf0  4c 37 08

; ==========================================================================
; CMD 0x1f: hex dump of DRAM.
; 0x40 rows of 16 bytes, each prefixed with its 16-bit address and broken
; into 4-byte groups by extra spaces.
; ==========================================================================
cmd1f_ram_dump:
    jsr put_cr              ;0bf3  20 3c 0e  start the dump with a CR
    lda #0x00               ;0bf6  a9 00     dump address = 0x0000
    sta ptr_lo              ;0bf8  85 08
    sta dump_lo             ;0bfa  85 0b
    sta ptr_hi              ;0bfc  85 09
    sta dump_hi             ;0bfe  85 0c
    ldy #0x00               ;0c00  a0 00
c1f_row:
    jsr dump_row_hdr        ;0c02  20 ab 0d  print "<addr> "
    jsr put_space           ;0c05  20 44 0e
c1f_byte:
    lda [ptr_lo],y          ;0c08  b1 08     read via the zero-page pointer
    jsr put_hex             ;0c0a  20 49 0e
    tya                     ;0c0d  98
    and #0x0f               ;0c0e  29 0f     column within the row
    cmp #0x03               ;0c10  c9 03     extra space after 4 bytes...
    bne c1f_t7              ;0c12  d0 03
    jsr put_space           ;0c14  20 44 0e
c1f_t7:
    cmp #0x07               ;0c17  c9 07     ...and after 8...
    bne c1f_tb              ;0c19  d0 03
    jsr put_space           ;0c1b  20 44 0e
c1f_tb:
    cmp #0x0b               ;0c1e  c9 0b     ...and after 12
    bne c1f_next            ;0c20  d0 03
    jsr put_space           ;0c22  20 44 0e
c1f_next:
    iny                     ;0c25  c8
    cpy dump_lo             ;0c26  c4 0b
    bne c1f_byte            ;0c28  d0 de
    cpy #0x40               ;0c2a  c0 40     0x40 rows
    bcc c1f_row             ;0c2c  90 d4
    jsr put_cr              ;0c2e  20 3c 0e
    lda #0x86               ;0c31  a9 86     0x86 = end-of-dump marker
    jsr putc                ;0c33  20 d5 0d
    jmp main                ;0c36  4c 37 08

; ==========================================================================
; Stream LPC speech out of DRAM into the TMS5220.
;
; Waits for any current utterance to finish, issues 0x60 = SPEAK EXTERNAL,
; then primes the 16-byte FIFO with 1 + 8 = exactly **nine** bytes, which is
; the datasheet's threshold for Talk Status to come up (sec. 6.5: "by the
; CPU loading a minimum of nine bytes to the FIFO"). After that it tops the
; FIFO up 8 bytes at a time, exactly the space BL guarantees, since BL
; asserts when eight locations are void, section 5.2.
;
; Each phrase ends with an energy=1111 stop frame, which drops TS and shows
; up here as status 0. Exits carry-clear on that clean stop, carry-set on
; any unexpected status.
; ==========================================================================
speak_from_ram:
    jsr tms_status          ;0c39  20 0f 0d  wait while TS (still talking)
    and #0x04               ;0c3c  29 04
    bne speak_from_ram      ;0c3e  d0 f9
    lda #0x60               ;0c40  a9 60     0x60 = SPEAK EXTERNAL
    jsr tms_write           ;0c42  20 2b 0d
    ldx #0x05               ;0c45  a2 05     let the chip settle
    jsr delay_x             ;0c47  20 c5 0d
    lda #0xdf               ;0c4a  a9 df     prime the FIFO: 1 byte here plus 8 below is 9
    sta PORT_C              ;0c4c  85 82
    lda #0xf7               ;0c4e  a9 f7
    sta PORT_C              ;0c50  85 82
    lda PORT_A              ;0c52  a5 80
    pha                     ;0c54  48
    lda #0xff               ;0c55  a9 ff
    sta PORT_C              ;0c57  85 82
    pla                     ;0c59  68
    jsr tms_write           ;0c5a  20 2b 0d
sfr_fill8:
    ldx #0x08               ;0c5d  a2 08     8 = exactly the space BL guarantees
sfr_byte:
    lda #0xdf               ;0c5f  a9 df     next LPC byte out of DRAM
    sta PORT_C              ;0c61  85 82
    lda #0xf7               ;0c63  a9 f7
    sta PORT_C              ;0c65  85 82
    lda PORT_A              ;0c67  a5 80
    pha                     ;0c69  48
    lda #0xff               ;0c6a  a9 ff
    sta PORT_C              ;0c6c  85 82
    pla                     ;0c6e  68
    jsr tms_write           ;0c6f  20 2b 0d
    dex                     ;0c72  ca
    bne sfr_byte            ;0c73  d0 ea
sfr_wait_int:
    lda PORT_C              ;0c75  a5 82     wait for /INT (PC6) low; reading status clears it
    asl a                   ;0c77  0a
    bmi sfr_wait_int        ;0c78  30 fb
    jsr tms_status          ;0c7a  20 0f 0d
    cmp #0x06               ;0c7d  c9 06     TS+BL -> feed 8 more
    beq sfr_fill8           ;0c7f  f0 dc
    cmp #0x00               ;0c81  c9 00     idle -> utterance finished
    beq sfr_ok              ;0c83  f0 06
    cmp #0x04               ;0c85  c9 04     TS only -> keep waiting
    beq sfr_wait_int        ;0c87  f0 ec
    sec                     ;0c89  38        anything else is a fault
    rts                     ;0c8a  60
sfr_ok:
    clc                     ;0c8b  18
    rts                     ;0c8c  60

; ==========================================================================
; Play the ROM-resident test tone (same protocol as above, but the LPC
; bytes come from `lpc_tone` instead of DRAM). This is what the card emits
; when the host sends the 0x00/0x00 command. Decoding it shows it is not
; speech at all: eight identical constant-parameter voiced frames, so it is
; a plain ~276 Hz buzz about 0.2 s long, then a fade and silence. A fixed
; tone is the right self-test. It exercises the 5220, the amplifier and the
; speaker without needing any vocabulary loaded.
; ==========================================================================
speak_builtin:
    lda #0xff               ;0c8d  a9 ff     flush the chip first
    jsr tms_write           ;0c8f  20 2b 0d
    ldx #0x3c               ;0c92  a2 3c
    jsr delay_x             ;0c94  20 c5 0d
sb_wait_idle:
    jsr tms_status          ;0c97  20 0f 0d  wait while TS
    and #0x04               ;0c9a  29 04
    bne sb_wait_idle        ;0c9c  d0 f9
    lda #0x60               ;0c9e  a9 60     0x60 = SPEAK EXTERNAL
    jsr tms_write           ;0ca0  20 2b 0d
    ldx #0x05               ;0ca3  a2 05
    jsr delay_x             ;0ca5  20 c5 0d
    ldy #0x00               ;0ca8  a0 00     first byte of the canned phrase
    lda lpc_tone,y          ;0caa  b9 d4 0c
    jsr tms_write           ;0cad  20 2b 0d
sb_fill8:
    ldx #0x08               ;0cb0  a2 08     8 = exactly the space BL guarantees
sb_byte:
    iny                     ;0cb2  c8
    lda lpc_tone,y          ;0cb3  b9 d4 0c
    jsr tms_write           ;0cb6  20 2b 0d
    dex                     ;0cb9  ca
    bne sb_byte             ;0cba  d0 f6
sb_wait_int:
    lda PORT_C              ;0cbc  a5 82     wait for /INT low
    asl a                   ;0cbe  0a
    bmi sb_wait_int         ;0cbf  30 fb
    jsr tms_status          ;0cc1  20 0f 0d
    cmp #0x06               ;0cc4  c9 06
    beq sb_fill8            ;0cc6  f0 e8
    cmp #0x00               ;0cc8  c9 00
    beq sb_ok               ;0cca  f0 06
    cmp #0x04               ;0ccc  c9 04
    beq sb_wait_int         ;0cce  f0 ec
    sec                     ;0cd0  38
    rts                     ;0cd1  60
sb_ok:
    clc                     ;0cd2  18
    rts                     ;0cd3  60

; ==========================================================================
; TMS5220 LPC-10 bitstream for the built-in test tone. Decodes as:
;
;   8 x  voiced frame, energy 9, pitch code 15 (~276 Hz), constant K1..K10
;   1 x  same frame at energy 1          (fade out)
;   4 x  zero-energy frame               (silence)
;   1 x  energy 1111                     (stop code)
;
; 420 bits is 53 of the 59 bytes. The rest is 0xff padding. A voiced frame is
; 50 bits, so four of them fill exactly 25 bytes, which is why the block
; looks like two near-identical 25-byte halves. The single differing byte
; at offset 0x12 is simply where the energy drops to 1 in frame 7.
; ==========================================================================
lpc_tone:
    .byte 0x89, 0x2f, 0xa2, 0x54, 0x85, 0x6a, 0x24, 0xbe ;0cd4
    .byte 0x88, 0x52, 0x15, 0xaa, 0x91, 0xf8, 0x22, 0x4a ;0cdc
    .byte 0x55, 0xa8, 0x46, 0xe2, 0x8b, 0x28, 0x55, 0xa1 ;0ce4
    .byte 0x1a, 0x89, 0x2f, 0xa2, 0x54, 0x85, 0x6a, 0x24 ;0cec
    .byte 0xbe, 0x88, 0x52, 0x15, 0xaa, 0x91, 0xf8, 0x22 ;0cf4
    .byte 0x4a, 0x55, 0xa8, 0x06, 0xe2, 0x8b, 0x28, 0x55 ;0cfc
    .byte 0xa1, 0x1a, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff ;0d04
    .byte 0xff, 0xff, 0xff                               ;0d0c

; ==========================================================================
; Read the TMS5220 status byte.
;   PORT_D -> all-ones (float the bus for input)
;   PC4 low = /RS asserted, wait for /READY (PC7) low, sample PORT_D
; Returns the three status flags right-justified in A:
;   bit 2 = TS  (talk status, 5220 bit 7)
;   bit 1 = BL  (buffer low,  5220 bit 6)
;   bit 0 = BE  (buffer empty,5220 bit 5)
; ==========================================================================
tms_status:
    nop                     ;0d0f  ea        (alignment)
    lda #0xff               ;0d10  a9 ff     float PORT_D so the 5220 can drive it
    sta PORT_D              ;0d12  85 83
    lda #0xef               ;0d14  a9 ef     PC4 low = /RS
    sta PORT_C              ;0d16  85 82
ts_wait_ready:
    lda PORT_C              ;0d18  a5 82     wait for /READY (PC7) low
    bmi ts_wait_ready       ;0d1a  30 fc
    ldx PORT_D              ;0d1c  a6 83     sample the status byte
    lda #0xff               ;0d1e  a9 ff     deassert /RS
    sta PORT_C              ;0d20  85 82
    txa                     ;0d22  8a
    ror a                   ;0d23  6a        right-justify bits 7..5
    ror a                   ;0d24  6a
    ror a                   ;0d25  6a
    ror a                   ;0d26  6a
    ror a                   ;0d27  6a
    and #0x07               ;0d28  29 07     -> TS/BL/BE
    rts                     ;0d2a  60

; ==========================================================================
; Write one byte to the TMS5220.
;   byte -> PORT_D, PC2 low = /WS asserted, wait for /READY (PC7) low.
; Used both for command bytes (0xff = RESET, 0x60 = SPEAK EXTERNAL) and
; for raw LPC data once the chip is in speak-external mode.
; ==========================================================================
tms_write:
    sta PORT_D              ;0d2b  85 83     data onto the 5220 bus
    lda #0xfb               ;0d2d  a9 fb     PC2 low = /WS
    sta PORT_C              ;0d2f  85 82
tw_wait_ready:
    lda PORT_C              ;0d31  a5 82     wait for /READY (PC7) low
    bmi tw_wait_ready       ;0d33  30 fc
    lda #0xff               ;0d35  a9 ff     deassert /WS
    sta PORT_C              ;0d37  85 82
    rts                     ;0d39  60

; ==========================================================================
; Timed pause requested by a 0xc0..0xff command.
;   parm       ticks      (~12.9 ms each)
;   cmd & 0x3f long units (~3.3 s each)
; ==========================================================================
pause:
    lda parm                ;0d3a  a5 01     parm = short units
    beq pause_long          ;0d3c  f0 07
pause_short_loop:
    jsr delay_10ms          ;0d3e  20 55 0d
    dec parm                ;0d41  c6 01
    bne pause_short_loop    ;0d43  d0 f9
pause_long:
    lda cmd                 ;0d45  a5 00     cmd & 0x3f = long units
    and #0x3f               ;0d47  29 3f
    sta cmd                 ;0d49  85 00
    beq pause_done          ;0d4b  f0 07
pause_long_loop:
    jsr delay_1s            ;0d4d  20 60 0d
    dec cmd                 ;0d50  c6 00
    bne pause_long_loop     ;0d52  d0 f9
pause_done:
    rts                     ;0d54  60

; ==========================================================================
; One delay tick: 25 x 102 iterations of a 5-cycle loop.
; 12,925 cycles ~= 12.9 ms at 1 MHz.
; ==========================================================================
delay_10ms:
    ldy #0x19               ;0d55  a0 19     25 outer passes...
d10_outer:
    ldx #0x66               ;0d57  a2 66     ...of 102 x 5 cycles
d10_inner:
    dex                     ;0d59  ca
    bne d10_inner           ;0d5a  d0 fd
    dey                     ;0d5c  88
    bne d10_outer           ;0d5d  d0 f8
    rts                     ;0d5f  60

; ==========================================================================
; Long delay: 128 passes of two ticks ~= 3.3 s at 1 MHz.
; X is shuttled through A because delay_tick clobbers it.
; ==========================================================================
delay_1s:
    ldx #0x80               ;0d60  a2 80     128 x 2 ticks
d1s_loop:
    txa                     ;0d62  8a        delay_tick clobbers X, so park it in A
    jsr delay_10ms          ;0d63  20 55 0d
    jsr delay_10ms          ;0d66  20 55 0d
    tax                     ;0d69  aa
    dex                     ;0d6a  ca
    bne d1s_loop            ;0d6b  d0 f5
    rts                     ;0d6d  60

; ==========================================================================
; Rewind the DRAM address counter to 0 and fetch the 2-byte command
; packet into cmd/parm.
; ==========================================================================
ram_get_cmd:
    lda #0x00               ;0d6e  a9 00     rewind the address counter
    jsr ram_set_addr        ;0d70  20 98 0d
    lda #0xdf               ;0d73  a9 df     2-byte DRAM read, unrolled
    sta PORT_C              ;0d75  85 82
    lda #0xf7               ;0d77  a9 f7
    sta PORT_C              ;0d79  85 82
    lda PORT_A              ;0d7b  a5 80
    pha                     ;0d7d  48
    lda #0xff               ;0d7e  a9 ff
    sta PORT_C              ;0d80  85 82
    pla                     ;0d82  68
    sta cmd                 ;0d83  85 00
    lda #0xdf               ;0d85  a9 df
    sta PORT_C              ;0d87  85 82
    lda #0xf7               ;0d89  a9 f7
    sta PORT_C              ;0d8b  85 82
    lda PORT_A              ;0d8d  a5 80
    pha                     ;0d8f  48
    lda #0xff               ;0d90  a9 ff
    sta PORT_C              ;0d92  85 82
    pla                     ;0d94  68
    sta parm                ;0d95  85 01
    rts                     ;0d97  60

; ==========================================================================
; Load the DRAM address counter's HIGH byte from A. The low byte clears to
; zero.
;
; Drives A onto PORT_A, pulses PC1 twice, then releases PORT_A to all-ones
; so the DRAM can drive it on the next read. Every call site confirms the
; high-byte reading: at 0x08f6 and 0x092a the value passed is the high half
; of a 16-bit pointer and the low half is then walked off with that many
; dummy reads. Seeking to an arbitrary address is therefore
; "load page, then read (low byte) times".
;
; On the board the high byte is likely the two presettable 74LS193s and the
; low byte reset-only 74LS93s. Not traced, see README.md.
; Why PC1 is pulsed twice rather than once is not explained by the ROM.
; ==========================================================================
ram_set_addr:
    sta PORT_A              ;0d98  85 80     high byte onto the DRAM bus
    lda #0xfd               ;0d9a  a9 fd     PC1 = counter clock
    ldx #0xff               ;0d9c  a2 ff
    sta PORT_C              ;0d9e  85 82     pulsed twice (reason unknown)
    stx PORT_C              ;0da0  86 82
    sta PORT_C              ;0da2  85 82
    stx PORT_C              ;0da4  86 82
    ldx #0xff               ;0da6  a2 ff     release the bus for reads
    stx PORT_A              ;0da8  86 80
    rts                     ;0daa  60

; ==========================================================================
; Emit "<hi><lo> ", the address prefix of one hex-dump row, then
; advance the running dump address by 16.
; ==========================================================================
dump_row_hdr:
    nop                     ;0dab  ea        (alignment)
    lda dump_hi             ;0dac  a5 0c     address high byte
    jsr put_hex             ;0dae  20 49 0e
    lda dump_lo             ;0db1  a5 0b     address low byte
    jsr put_hex             ;0db3  20 49 0e
    cld                     ;0db6  d8        binary add
    clc                     ;0db7  18
    lda #0x10               ;0db8  a9 10     += 16 for the next row
    adc dump_lo             ;0dba  65 0b
    sta dump_lo             ;0dbc  85 0b
    lda #0x00               ;0dbe  a9 00
    adc dump_hi             ;0dc0  65 0c
    sta dump_hi             ;0dc2  85 0c
    rts                     ;0dc4  60

; ==========================================================================
; Spin X times (5 cycles per iteration).
; ==========================================================================
delay_x:
    dex                     ;0dc5  ca        5 cycles per iteration
    bne delay_x             ;0dc6  d0 fd
    rts                     ;0dc8  60

; ==========================================================================
; 100,100 cycles ~= 100 ms at 1 MHz.
; ==========================================================================
delay_60ms:
    ldy #0x64               ;0dc9  a0 64     100 x 143 x 7 cycles
d60_outer:
    ldx #0x8f               ;0dcb  a2 8f
d60_inner:
    nop                     ;0dcd  ea
    dex                     ;0dce  ca
    bne d60_inner           ;0dcf  d0 fc
    dey                     ;0dd1  88
    bne d60_outer           ;0dd2  d0 f7
    rts                     ;0dd4  60

; ==========================================================================
; Emit one character to the host over PORT_B.
; Sets bit 7 of the character (every string and every digit this ROM
; produces is high-bit-set ASCII, Apple II style), drops PORT_B to all
; zeroes as a start/strobe, waits ~100 us, presents the character, then
; holds it for the programmable inter-character time. X is preserved.
; ==========================================================================
putc:
    ora #0x80               ;0dd5  09 80     high-bit-set ASCII
    stx x_save              ;0dd7  86 14     putc must preserve X
    ldx #0x00               ;0dd9  a2 00     all lines low = start
    stx PORT_B              ;0ddb  86 81
    ldx #0x14               ;0ddd  a2 14     20 x 5 cycles ~= 100 us
    jsr delay_x             ;0ddf  20 c5 0d
    sta PORT_B              ;0de2  85 81     present the character
    jsr inter_char          ;0de4  20 ea 0d
    ldx x_save              ;0de7  a6 14
    rts                     ;0de9  60

; ==========================================================================
; Inter-character delay: char_dly x ~1 ms. Preserves X and Y.
; ==========================================================================
inter_char:
    txa                     ;0dea  8a        preserve X and Y
    pha                     ;0deb  48
    tya                     ;0dec  98
    pha                     ;0ded  48
    ldy char_dly            ;0dee  a4 16     char_dly x 200 x 5 cycles ~= 1 ms
    beq ic_done             ;0df0  f0 08
ic_loop:
    ldx #0xc8               ;0df2  a2 c8
    jsr delay_x             ;0df4  20 c5 0d
    dey                     ;0df7  88
    bne ic_loop             ;0df8  d0 f8
ic_done:
    pla                     ;0dfa  68
    tay                     ;0dfb  a8
    pla                     ;0dfc  68
    tax                     ;0dfd  aa
    rts                     ;0dfe  60

; ==========================================================================
; Report a failed location: "<Y><X> <value>:" then re-read PC0 so the
; caller can tell whether the operator asked to stop. A is preserved
; across the call and echoed at the end.
; ==========================================================================
report_err:
    nop                     ;0dff  ea        (alignment)
    pha                     ;0e00  48        keep the offending value
    jsr put_cr              ;0e01  20 3c 0e  new line
    tya                     ;0e04  98        address high
    jsr put_hex             ;0e05  20 49 0e
    txa                     ;0e08  8a        address low
    jsr put_hex             ;0e09  20 49 0e
    jsr put_space           ;0e0c  20 44 0e
    lda err_val             ;0e0f  a5 0a     what we actually read
    jsr put_hex             ;0e11  20 49 0e
    lda #0xba               ;0e14  a9 ba     0xba = ':'
    jsr putc                ;0e16  20 d5 0d
    jsr put_space           ;0e19  20 44 0e
    pla                     ;0e1c  68        echo the expected value
    jsr put_hex             ;0e1d  20 49 0e
    lda PORT_C              ;0e20  a5 82     did the operator ask to stop?
    and #0x01               ;0e22  29 01
    sec                     ;0e24  38
    bne re_ret              ;0e25  d0 01
    clc                     ;0e27  18
re_ret:
    lda err_val             ;0e28  a5 0a     return the bad value in A
    rts                     ;0e2a  60

; ==========================================================================
; Prompt "." and sample PC0: carry set if the operator wants to stop.
; ==========================================================================
ask_more:
    lda #0xae               ;0e2b  a9 ae     0xae = '.'
    jsr putc                ;0e2d  20 d5 0d
    lda PORT_C              ;0e30  a5 82     sample the host line
    and #0x01               ;0e32  29 01
    clc                     ;0e34  18
    beq am_ret              ;0e35  f0 04
    jsr put_space           ;0e37  20 44 0e  acknowledge with a space
    sec                     ;0e3a  38
am_ret:
    rts                     ;0e3b  60

; ==========================================================================
; Emit CR (0x0d | 0x80). A is preserved.
; ==========================================================================
put_cr:
    pha                     ;0e3c  48
    lda #0x8d               ;0e3d  a9 8d     0x8d = CR
    jsr putc                ;0e3f  20 d5 0d
    pla                     ;0e42  68
    rts                     ;0e43  60

; ==========================================================================
; Emit space (0x20 | 0x80). Tail-calls putc.
; ==========================================================================
put_space:
    lda #0xa0               ;0e44  a9 a0     0xa0 = space
    jmp putc                ;0e46  4c d5 0d

; ==========================================================================
; Print A as two hex digits, MSD first. A is preserved.
; The `cmp #0x3a / bmi / adc #0x07` pair is the usual nibble-to-ASCII
; fixup for 'A'..'F'.
; ==========================================================================
put_hex:
    sta hex_tmp             ;0e49  85 07     stash the byte
    lsr a                   ;0e4b  4a        high nibble first
    lsr a                   ;0e4c  4a
    lsr a                   ;0e4d  4a
    lsr a                   ;0e4e  4a
    cld                     ;0e4f  d8        binary, not BCD
    clc                     ;0e50  18
    adc #0x30               ;0e51  69 30     + '0'
    cmp #0x3a               ;0e53  c9 3a     > '9' ?
    bmi ph_lo               ;0e55  30 03
    clc                     ;0e57  18
    adc #0x07               ;0e58  69 07     shift up to 'A'..'F'
ph_lo:
    jsr putc                ;0e5a  20 d5 0d
    lda hex_tmp             ;0e5d  a5 07
    and #0x0f               ;0e5f  29 0f     low nibble
    clc                     ;0e61  18
    adc #0x30               ;0e62  69 30
    cmp #0x3a               ;0e64  c9 3a
    bmi ph_done             ;0e66  30 03
    clc                     ;0e68  18
    adc #0x07               ;0e69  69 07
ph_done:
    jsr putc                ;0e6b  20 d5 0d
    lda hex_tmp             ;0e6e  a5 07     return the original byte
    rts                     ;0e70  60

; ==========================================================================
; Copyright block. High-bit-set ASCII, padded with 0x11, the same
; filler byte the reset code writes over all of RAM. Nothing in the ROM ever
; reads it. It is here for the ROM-mask paperwork.
;
;   "COPYRIGHT (C) 1983     BORG-WARNER CORPORATION     ALL RIGHTS RESERVED"
;
; The three bytes at 0x0e76 (0x83 0x05 0x04, or 0x03 0x05 0x04 with the high
; bit stripped) sit inside the filler and look like a date or part
; stamp. That reading is a guess.
; ==========================================================================
banner:
    .byte 0x11, 0x11, 0x11, 0x11, 0x11, 0x83, 0x05, 0x04, 0x11, 0x11, 0x11, 0x11, 0x11, 0xc3, 0xcf, 0xd0 ;0e71  |.............COP|
    .byte 0xd9, 0xd2, 0xc9, 0xc7, 0xc8, 0xd4, 0xa0, 0xa8, 0xc3, 0xa9, 0xa0, 0xb1, 0xb9, 0xb8, 0xb3, 0xa0 ;0e81  |YRIGHT (C) 1983 |
    .byte 0xa0, 0xa0, 0xa0, 0xa0, 0xc2, 0xcf, 0xd2, 0xc7, 0xad, 0xd7, 0xc1, 0xd2, 0xce, 0xc5, 0xd2, 0xa0 ;0e91  |    BORG-WARNER |
    .byte 0xc3, 0xcf, 0xd2, 0xd0, 0xcf, 0xd2, 0xc1, 0xd4, 0xc9, 0xcf, 0xce, 0xa0, 0xa0, 0xa0, 0xa0, 0xa0 ;0ea1  |CORPORATION     |
    .byte 0xc1, 0xcc, 0xcc, 0xa0, 0xd2, 0xc9, 0xc7, 0xc8, 0xd4, 0xd3, 0xa0, 0xd2, 0xc5, 0xd3, 0xc5, 0xd2 ;0eb1  |ALL RIGHTS RESER|
    .byte 0xd6, 0xc5, 0xc4, 0xa0, 0xa0, 0xa0, 0xa0, 0xa0, 0xa0, 0x11, 0x11, 0x11, 0x11, 0x11             ;0ec1  |VED      .....|

; ==========================================================================
; Unused ROM tail: 296 NOPs ending in `jmp main`.
; If the program counter is ever thrown into this region, by a glitch, a bad
; indirect jump or a runaway stack, it slides to the bottom and restarts
; cleanly.  299 bytes, 14.6% of the 2 KiB mask.
; ==========================================================================
nop_sled:
    .rept 296
    nop                     ;0ecf-0ff6  ea
    .endm
sled_exit:
    jmp main                ;0ff7  4c 37 08  jmp main (the sled's landing point)

; ==========================================================================
; 6502 hardware vectors. All three point at `reset`: the 6500/1's
; on-chip counter and edge interrupts are never enabled (CONTROL is
; zeroed at reset), so NMI and IRQ can only mean "something went wrong".
; ==========================================================================
VEC_NMI:
    .word reset              ;0ffa  00 08     non-maskable interrupt
VEC_RESET:
    .word reset              ;0ffc  00 08     reset
VEC_IRQ:
    .word reset              ;0ffe  00 08     maskable interrupt
