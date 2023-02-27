; BSOD64 (C) Kroc Camen, 2019-2023
; licenced under BSD 2-clause
;===============================================================================
; BSOD64 is a "blue screen of death" for C64 programs. why would you want that?
;
; ...
;
; DESIGN GOALS:
;-------------------------------------------------------------------------------
; * completely self-contained:
; - no external dependencies
; - does not need to be compiled into your own program
;   (include as a binary blob, or load-in from disk)
; - can be loaded from and operated within BASIC
; - resides in "unused" memory ($C000..$E000)
;
; * small:
; - maximum limit of 4 KB code
; - favours small code over speed / memory usage
; - uses only official KERNAL calls / addresses, so should work with
;   alternative ROMs such as Jiffy DOS, Dolphin DOS, C128 &c.
;
; THEORY OF OPERATION:
;-------------------------------------------------------------------------------
; an interrupt is a way for external signals to stop the processor and get it
; to run some other code to deal with the signal immediately, before resuming
; where it was before. a handful of parts in the C64 can generate interrupts
; (the CIAs, VIC-II, SID) but the 6502 also has an instruction, BRK, that can
; interrupt the currently running code. its purpose is for debugging, as it
; provides a way to stop the program at any point and jump to a completely
; different program (a debugger, e.g. BSOD64)
;
; the Commodore 64, in particular, has its RESTORE key wired to the CPU rather
; than the keyboard matrix. no matter what state the user's program is in, even
; if it's not checking the keyboard, the RESTORE key will raise a "Non-Maskable
; Interrupt" (NMI), a special type of interrupt separate to BRK. likewise, this
; provides us another way to halt [and debug] a running program
;
; unfortunately, the C64/6502 hardware does not allow us
; to just instantly jump to BSOD64 upon an NMI or BRK:
;
; *     there is no hardware BRK vector; an IRQ is fired instead with
;       the BRK-bit set, so some decoding overhead is already required
;       to separate regular interrupts from a BRK
;
; *     the KERNAL ROM does its own NMI/IRQ/BRK handling before we are able
;       to take over. disabling the KERNAL ROM is possible but then the system
;       crashes if we don't provide our own replacements, and regardless, both
;       environments must be handled as we can't assume which state the user's
;       program will be in when a BRK occurs
;
; *     the KERNAL ROM's IRQ handler pushes the registers to the stack before
;       calling the user-handler, but the KERNAL's NMI handler does not! some
;       normalisation is required to handle both behaviours equally
;
; *     a normal JSR or interrupt subtracts one from the program counter before
;       pushing it to the stack, this is because the RTS & RTI instructions
;       always automatically add 1 to the program counter (an internal detail).
;       the BRK instruction, however *adds* 1 to the program counter before 
;       pushing it to the stack! returning from a BRK interrupt therefore skips
;       over a byte unless this is accounted for!
;
; if 1, does not include the debugger, only the BSOD screen
.ifndef BSOD64_BSODONLY
BSOD64_BSODONLY = 1
.endif

BSOD64_CODE_ADDR = $7c80        ;sys 31872
BSOD64_DATA_ADDR = $7000

; when BSOD64 is invoked, the areas of memory that BSOD64 needs to re-use are
; copied to the RAM under the I/O space. since this RAM is very difficult to
; use, it's the most likely "unused" RAM on the system and the last area
; a developer will want to utilise before any other
;
; base address where BSOD64 is assembled -- CANNOT be under a ROM shadow!
.ifndef BSOD64_CODE_ADDR
        BSOD64_CODE_ADDR = $c000        ; sys 49152
.endif
; where BSOD64 backs up data, can be under I/O but not KERNAL
.ifndef BSOD64_DATA_ADDR
        BSOD64_DATA_ADDR = $d000
.endif

; is the data under I/O?
.if BSOD64_DATA_ADDR-$d000
        BSOD64_UNDER_IO = 1
.endif

.include "system.s"

;===============================================================================
                        ; (base address of frozen data)
frzn                    = BSOD64_DATA_ADDR
                        ; backup of zero-page ($0000-$00FF)
frzn_zp                 = BSOD64_DATA_ADDR
                        ; backup of stack ($0100-$1FF)
frzn_stack              = BSOD64_DATA_ADDR + $100
                        ; backup of KERNAL work-RAM ($0200-$02FF)
frzn_work               = BSOD64_DATA_ADDR + $200
                        ; backup of KERNAL/BASIC vectors ($0300-$03FF)
frzn_vectors            = BSOD64_DATA_ADDR + $300
                        ; backup of text screen ($0400-$07FF)
frzn_screen             = BSOD64_DATA_ADDR + $400
                        ; backup of colour RAM ($D800-$DBFF)
frzn_color              = BSOD64_DATA_ADDR + $800
                        ; backup of VIC-II registers (46-bytes)
frzn_vic                = BSOD64_DATA_ADDR + $c00

;-------------------------------------------------------------------------------
;;; temporary stack pointer of the frozen stack i.e. a focus cursor, and not the
;;; origanl stack pointer at time of freeze nor the current system stack pointer
;;.zp_sp                  = $02

;-------------------------------------------------------------------------------
; address for string indexing
; ("pointer to memory allocated for current string variable")
zp_str                  = $35
zp_str_lo               = $35
zp_str_hi               = $36

;===============================================================================
; where a JMP instruction is overwritten,
; this is the placeholder address
null_addr               = $8888
; where an instruction operand is overwritten,
; this is the placeholder value
NULL_VALUE              = $88

; terminators used for the string-printing routines:
;
STR_END                 = $00   ; standard terminator
STR_POS                 = $01   ; change cursor pos; row & col bytes follow
STR_HEXB                = $0f   ; print the 8-bit value that follows in hex
STR_HEXW                = $10   ; print the 16-bit value that follows in hex
STR_FLAGS               = $06   ; print a binary value as a set of flags

; constants for memory-layout:
;
; (see <http://c64os.com/post/6510procport> for
;  a full understanding of the processor port bits)
;
MEM_ALL_RAM             = %00110100
MEM_IO_ONLY             = %00110101
MEM_KERNAL_IO           = %00110110
MEM_DEFAULT             = %00110111     ; KERNAL, I/O & BASIC


;===============================================================================
; 888888b.    .d8888b.   .d88888b.  8888888b.   .d8888b.      d8888
; 888  "88b  d88P  Y88b d88P" "Y88b 888  "Y88b d88P  Y88b    d8P888
; 888  .88P  Y88b.      888     888 888    888 888          d8P 888
; 8888888K.   "Y888b.   888     888 888    888 888d888b.   d8P  888
; 888  "Y88b     "Y88b. 888     888 888    888 888P "Y88b d88   888
; 888    888       "888 888     888 888    888 888    888 8888888888
; 888   d88P Y88b  d88P Y88b. .d88P 888  .d88P Y88b  d88P       888
; 8888888P"   "Y8888P"   "Y88888P"  8888888P"   "Y8888P"        888
;===============================================================================
* = BSOD64_CODE_ADDR


bsod_basic                                      ; (`SYS 49152` / `jsr $c000`)
;===============================================================================
; install BSOD64's launch hooks:
;
; this will alter the system interrupts to launch BSOD64 whenever the RESTORE
; key is pressed, or the BRK instruction is encountered in running code
; 
; if you are using your own interrupt code then you will need to include a
; small piece of code at the beginning of your IRQ / NMI routine to invoke
; BSOD64 -- see the comments for the `bsod_irq` routine below
;
;-------------------------------------------------------------------------------
        jmp bsod_hook


bsod_jsr                                        ; (`SYS 49155` / `jsr $c003`)
;===============================================================================
; invoke BSOD64 manually with a JSR;
; i.e. not using a NMI/IRQ/BRK handler
;
; THIS ASSUMES THE FOLLOWING STACK LAYOUT:
;
;       top  -> PC lo-byte              (pushed by JSR to here)
;               PC hi-byte              (pushed by JSR to here)
;
;-------------------------------------------------------------------------------
        ; push the processor status and registers to the stack
        ; to normalise the stack layout for BSOD64
        jmp bsod_push


bsod_irq                                        ; (`SYS 49158` / `jsr $c006`)
;===============================================================================
; invoke BSOD64 from an interrupt (IRQ/NMI/BRK) environment:
;
; THIS ASSUMES THE FOLLOWING STACK LAYOUT:
;
;       top  -> return-address, lo-byte (pushed by the JSR here)
;               return-address, hi-byte (pushed by the JSR here)
;               Y register              (pushed by the IRQ/NMI handler)
;               X register              (pushed by the IRQ/NMI handler)
;               A register              (pushed by the IRQ/NMI handler)
;               processor status        (pushed by hardware interrupt)
;               PC lo-byte              (pushed by hardware interrupt)
;               PC hi-byte              (pushed by hardware interrupt)
;
;-------------------------------------------------------------------------------
        ; disable interrupts first, we must stop any more host code from
        ; running! note that because the hardware interrupt pushed the
        ; processor state to the stack we can recover the original
        ; interrupt state from there 
        sei
        ; set the flag indicating how BSOD64 was launched
        ; in this case, by IRQ (the default), not manually;
        ; the BRK bit will be checked later
        lda # $00
        sta bsod_is_jsr

        ; fallthrough
        ; ...

bsod_freeze
;===============================================================================
; freeze the state of the machine:
; (NEVER CALL THIS DIRECTLY -- *ALWAYS* use `bsod_jsr` or `bsod_irq` above)
;
;-------------------------------------------------------------------------------
        ; we do not know if decimal mode was in use, turn it off before
        ; we do any math (this is a hardware-flaw with the NMOS 6502)
        cld
        tsx                     ; get the stack pointer
        stx frzn_sp             ; keep an original copy
        ; backup the registers that were pushed on to the stack by the
        ; IRQ/NMI routine (or BSOD64 iteself in the case of `bsod_jsr`)
        lda stack+3, x          ; 1st register on stack
        sta frzn_y              ; keep an original copy of Y
        lda stack+4, x          ; 2nd register on stack
        sta frzn_x              ; keep an original copy of X
        lda stack+5, x          ; 3rd register on stack
        sta frzn_a              ; keep an original copy of A

        ; below the registers should be the processor status at the time of
        ; interrupt. we will need this to determine if BSOD64 was invoked by
        ; a BRK instruction
        ;
        lda stack+6, x          ; read processor flags from interrupt
        sta frzn_f              ; keep an original copy

        ; and lastly the program-counter
        lda stack+7, x          ; program counter lo-byte
        sta frzn_pc_lo          ; store as frozen PC, lo-byte
        lda stack+8, x          ; program counter hi-byte
        sta frzn_pc_hi          ; store as frozen PC, hi-byte

        ; during an IRQ or NMI, the PC on the stack is that of the next
        ; instruction to be executed. however, the 6502 processor always
        ; auto-increments the program counter during an RTS instruction,
        ; so the address pushed on the stack with JSR is one less than
        ; the next instruction in the code -- if BSOD64 is invoked by
        ; JSR then we need to correct for this!
        ;
        bit bsod_is_jsr         ; check for the JSR flag
        bpl _a                  ; skip over if NMI/IRQ/BRK
        inc frzn_pc_lo          ; add 1 to the PC, lo-byte
        bne _a                  ; if no overflow, finished
        inc frzn_pc_hi          ; lo overflow, add 1 to PC, hi-byte 
_a       
        ; freeze low-memory:
        ;-----------------------------------------------------------------------
        ; the area we will backup to is under I/O, so before we can write there
        ; we need to change the memory layout. first we backup the processor
        ; port, and then change memory layout to turn off I/O
        ;
        ; the "data direction register" determines what bits of the processor
        ; port can be written to. this is important to make use of because the
        ; Datasette control lines are part of the processor port and you don't
        ; want to play around with the tape when changing memory layout
        ;
        ; we actually want to stop the tape motor when freezing BSOD64,
        ; so we set the data-direction register to allow us to turn off bit 5
        ;
        lda zp+0                ; current CPU data-direction register
        sta frzn_cpu_ddir       ; save to frozen state
        lda # %00101111         ; reset the data-direction register,
        sta zp+0                ;  to its default value
        lda zp+1                ; current CPU port value
        sta frzn_cpu_port       ; save to frozen state

        lda # MEM_ALL_RAM       ; disable I/O & ROM!
        sta zp+1
        
        ; backup the low eight pages of memory:
        ;
        ldx # 0
        ; backup the zero-page: note that addresses 0/1 have been modified
        ; from the originals above, so we will want to insert the original
        ; values into the frozen zero-page after the backup
_b      lda zp, x
        sta frzn_zp, x
        ; backup the original stack: since BSOD64 will be using the stack
        ; too, we will want to take a copy of the stack at freeze-time
        lda stack, x
        sta frzn_stack, x
        ; backup the KERNAL/BASIC work RAM at $0200-$02FF:
        lda work, x
        sta frzn_work, x
        ; backup the KERNAL/BASIC vectors at $0300-$03FF:
        lda vector, x
        sta frzn_vectors, x
        ; backup the original text screen at $0400-$07FF:
        lda screen      + $000, x
        sta frzn_screen + $000, x
        lda screen      + $100, x
        sta frzn_screen + $100, x
        lda screen      + $200, x
        sta frzn_screen + $200, x
        lda screen      + $300, x
        sta frzn_screen + $300, x
        ; rinse and repeat
        dex
        bne _b

        lda frzn_cpu_ddir       ; take the original data-direction value
        sta frzn_zp+0           ; and put into the frozen zero-page
        lda frzn_cpu_port       ; and do the same with the CPU port value
        sta frzn_zp+1

        ; with KERNAL off, we can back up the hardware vectors underneath:
        ; the non-maskable interrupt, wired to the RESTORE key & CIA2
        lda cpu_nmi_lo
        sta frzn_nmi_lo
        lda cpu_nmi_hi
        sta frzn_nmi_hi
        ; whilst the reset vector is never used after power-on,
        ; the host program may have modified it for its own uses
        lda cpu_rst_lo
        sta frzn_rst_lo
        lda cpu_rst_hi
        sta frzn_rst_hi
        ; the interrupt request vector, wired to CIA1 and VIC-II
        lda cpu_irq_lo
        sta frzn_irq_lo
        lda cpu_irq_hi
        sta frzn_irq_hi

        ; freeze VIC-II:
        ;-----------------------------------------------------------------------
        ; backup CIA #2 port A which holds the VIC bank
        ;
        inc zp+1                ; enable the I/O shield to access CIA #2
        lda cia2+CIA_PORTA      ; read CIA #2 port A
        sta frzn_cia2           ; store locally, I/O doesn't need to be off

        ; if the frozen data is *not* stored under I/O then we can
        ; leave I/O on for the whole copy rather than each byte
        ;
.ifdef  BSOD64_UNDER_IO
        dec zp+1                ; disable I/O
.endif
        ; backup the VIC-II state before we start changing the screen
        ;
        ldx # $2e               ; number of VIC-II registers
_c
.ifdef  BSOD64_UNDER_IO
        inc zp+1
.endif
        lda vic, x              ; read the VIC-II register
.ifdef  BSOD64_UNDER_IO
        dec zp+1
.endif
        sta frzn_vic, x         ; write to the frozen state
        dex
        bpl _c

        ; backup colour RAM:
        ;-----------------------------------------------------------------------
        ; this is done in four stripes to avoid using a nested loop. note that
        ; because BSOD64 stores the frozen machine state under I/O, we have to
        ; turn I/O on & off for each read + write. whilst this is not ideal,
        ; it is the most-likely-to-be-unused memory available to us
        ;
        ; TODO: use $0400 as swap space
        ; (avoid I/O on/off for every R/W)
        ;
        ldx # 0
_d       
.ifdef  BSOD64_UNDER_IO
        inc zp+1
.endif
        lda vic_color  + $000, x
.ifdef  BSOD64_UNDER_IO
        dec zp+1
.endif
        sta frzn_color + $000, x
.ifdef  BSOD64_UNDER_IO
        inc zp+1
.endif
        lda vic_color  + $100, x
.ifdef  BSOD64_UNDER_IO
        dec zp+1
.endif
        sta frzn_color + $100, x
.ifdef  BSOD64_UNDER_IO
        inc zp+1
.endif
        lda vic_color  + $200, x
.ifdef  BSOD64_UNDER_IO
        dec zp+1
.endif
        sta frzn_color + $200, x
.ifdef  BSOD64_UNDER_IO
        inc zp+1
.endif
        lda vic_color  + $300, x
.ifdef  BSOD64_UNDER_IO
        dec zp+1
.endif
        sta frzn_color + $300, x
        dex
        bne _d

.ifndef BSOD64_UNDER_IO
        dec zp+1                ; disable I/O shield
.endif
        ; reset machine state:
        ;-----------------------------------------------------------------------
        ; since the original stack is now backed-up, we can re-use the stack
        ; however we please. because the user's program could have the stack
        ; at any depth, even near to overflowing, we reset the stack pointer
        ldx # $ff
        txs

        ; TODO: do we need to reset the vectors ($0314-$0333)
        ;       before enabling the KERNAL?
        lda # MEM_KERNAL_IO     ; enable BASIC,
        sta zp+1                ; KERNAL & I/O

        lda # %00000000         ; turn screen off
        sta vic+VIC_SCREEN_VERT

        ; NOTE: we *must* create correct zero-page values for the KERNAL
        ;       to be enabled, in case the user's program fills zero-page
        ;       without concern for KERNAL!
        ;
        ; this KERNAL routine erases the zero page, pages 2 & 3, and runs
        ; a memory test before configuring BASIC limits. it sets the page
        ; number for screen memory to $04 just before it exits, but does
        ; not change the actual VIC bank
        ;
        jsr kernal_ramtas

        ; restore the default vector table at $0314-$0333:
        ; this will ensure that KERNAL-handled interrupts will point back
        ; to the KERNAL and not to code from the frozen program
        jsr kernal_restor

        ; re-initialise VIC-II
        jsr kernal_scinit

        ; a BSOD must be blue...
        lda # VIC_BLUE
        sta vic+VIC_SCREEN_BORDER
        sta vic+VIC_SCREEN_BKGRND
        ;;inc vic+VIC_SCREEN_BORDER

        ; re-initialise CIAs, get interrupts running again.
        ; also silences the SID chip
        jsr kernal_ioinit

        lda # %00011011         ; 25 rows, screen on
        sta vic+VIC_SCREEN_VERT

        ; configure working environment
        ;-----------------------------------------------------------------------
        ; put handlers in place for interrupts whenever we turn off the KERNAL
        ;
        sei                     ; first, disable interrupts

        ; install the NMI handler
        lda #< bsod_nmi_kernalon
        sta vectors+VECTOR_NMI+0
        lda #> bsod_nmi_kernalon
        sta vectors+VECTOR_NMI+1

        lda #< bsod_nmi_nokernal
        sta cpu_nmi_lo
        lda #> bsod_nmi_nokernal
        sta cpu_nmi_hi

        ; install the IRQ handler
        lda #< bsod_irq_kernalon
        sta vectors+VECTOR_IRQ+0
        sta vectors+VECTOR_BRK+0
        lda #> bsod_irq_kernalon
        sta vectors+VECTOR_IRQ+1
        sta vectors+VECTOR_BRK+1

        lda #< bsod_irq_nokernal
        sta cpu_irq_lo
        lda #> bsod_irq_nokernal
        sta cpu_irq_hi
        
        ; enable interrupts and hope
        ; the machine doesn't crash
        cli

        ;-----------------------------------------------------------------------
        ; make a note if BSOD64 was
        ; invoked by a BRK instruction
        ;
        lda frzn_f              ; processor state before interrupt
        and # %00010000         ; isolate the BRK bit
        beq _e                  ; use $00 for non-BRK
        lda # $ff               ; use $FF for BRK
_e      sta bsod_is_brk         ; we can easily refer to this in the future
        
;;        ; copy the original program counter to a working copy
;;        ; and add 1 to show the actual resume point in code
;;        ; (the 6502 auto-increments the PC upon RTS/RTI)
;;        ;
;;        clc
;;        lda .work_pc_lo
;;        adc # 1
;;        sta .frzn_pc_lo
;;        lda .work_pc_hi
;;        adc # 0
;;        sta .frzn_pc_hi
;;
;;        ; WARNING: the program counter on the stack will be 'off' by a
;;        ;          differing amount depending on how BSOD64 was invoked!
;;        ;
;;        ; the 6502 processor always auto-increments the program counter when
;;        ; executing an RTS or RTI instruction, so the address pushed on the
;;        ; stack is always one-less than the next instruction in the code
;;        ;
;;        ; however -- a hardware bug in the BRK instruction causes the 6502
;;        ; to always add 2 to the program counter pushed to the stack
;;        ;
;;        ; in order for BSOD64 to unfreeze the machine state and resume,
;;        ; it needs to normalise the program counter it works with
;;        ;
;;        ; note that when invoking BSOD64 by JSR the BRK-bit is always set
;;        ; due to the use of PHP to push the processor status to the stack
;;        ; which always sets the BRK-bit
;;        ;
;;        bit .bsod_is_jsr        ; invoked by JSR and not an interrupt?
;;        bmi .bsod_debug         ; if yes, skip over BRK-handling of PC
;;        bit .bsod_is_brk        ; check the BRK state
;;        bpl .bsod_debug         ; skip if not a BRK call
;;
;;        ; BRK call: fix the program
;;        ; counter by subtracting 2
;;        sec
;;        lda .frzn_pc_lo
;;        sbc # 2
;;        sta .frzn_pc_lo
;;        bcs +
;;        dec .frzn_pc_hi
;;      +

bsod_BSOD
;===============================================================================
;
;-------------------------------------------------------------------------------
        ; decode the frozen ROM/RAM bank state:
        ;-----------------------------------------------------------------------
        ; VIC bank is done first as other banking goes over this
        ;
        ldx # 12                ; VIC bank 3 starts on the 12th page
        lda frzn_cia2           ; frozen state of CIA#2 port A
        and # %00000011         ; we only care about the bottom two bits
        beq _f                  ; =%00? VIC bank 3 ($C000-$FFFF)
        ldx # 8                 ; VIC bank 2 starts on the 8th page
        cmp # %00000001         ; =%01?
        beq _f                  ; VIC bank 2 ($8000-$BFFF)
        ldx # 4                 ; VIC bank 1 starts on the 4th page
        cmp # %00000010         ; =%11?
        beq _f                  ; VIC bank 1 ($4000-$7FFF)

        ; otherwise, VIC bank 0 ($0000-$3FFFF)
        ldx # 0                 ; VIC bank 0 starts on the 0th page
_f      lda # "v"               ; use consumate "v"s for VIC bank
        sta bsod_str_banks_vic+0, x
        sta bsod_str_banks_vic+1, x
        sta bsod_str_banks_vic+2, x
        sta bsod_str_banks_vic+3, x

        ; ROM banks:
        lda frzn_cpu_port
        and # %00000011         ; we only care about the bottom bits
        beq _g                  ; %00 = all RAM, nothing else

        ; any non-zero value implies
        ; that the I/O shield is on
        ;
        ldy # "i"               ; use an "i" in bank $D to indicate I/O on
        sty bsod_str_banks_i

        sec
        sbc # 1
        beq _g

        ldy # "k"               ; use a "k" in banks $E & $F for KERNAL on
        sty bsod_str_banks_k+0
        sty bsod_str_banks_k+1

        sbc # 1
        beq _g

        ldy # "b"               ; use a "b" in banks $A & $B for BASIC on
        sty bsod_str_banks_b+0
        sty bsod_str_banks_b+1

        ; print frozen registers and banks:
_g      lda #< bsod_str_top
        ldx #> bsod_str_top
        jsr bsod_print

        ; print frozen zero-page & stack:
        ;-----------------------------------------------------------------------
        ; the stack index points to the next *unused* position
        ldy frzn_sp             ; top stack address
        ldx # 0                 ; starting zero-page address
        jsr bsod_bsod_zp_cr     ; print first line of zero-page values,
                                ; and the first stack value
_h      txa
        and # %00000001
        beq _i
        lda # PET_WHITE
        #skip2
_i      lda # PET_LTBLUE
        jsr kernal_chrout

.ifdef  BSOD64_UNDER_IO
        lda # MEM_ALL_RAM       ; turn *off* BASIC,
        sta zp+1                ;  KERNAL, and I/O
.endif
        ; read byte from frozen zero-page
        lda frzn_zp, x
        pha
.ifdef  BSOD64_UNDER_IO
        lda # MEM_DEFAULT       ; turn *on* KERNAL,
        sta zp+1                ;  BASIC, and I/O
.endif
        pla
        jsr bsod_print_hex8
        
        inx
        beq _j

        txa
        and # %00001111
        bne _h

        ; print the stack value:
        jsr bsod_bsod_stack

        ; start the next zero-page line:
        jsr bsod_bsod_zp_cr
        jmp _h

        ; print the stack value:
_j      jsr bsod_bsod_stack

        jmp *
        rts

bsod_bsod_zp_cr
        ;-----------------------------------------------------------------------
        ; start the next line of the frozen zero-page dump
        ;
        lda # "$"
        jsr kernal_chrout
        txa
        jsr bsod_print_hex8
        lda # ":"
        jmp kernal_chrout

bsod_bsod_stack
        ;-----------------------------------------------------------------------
        ; print a value from the frozen stack
        ;
        iny
        beq _k

        lda # " "
        jsr kernal_chrout
        lda # " "
        jsr kernal_chrout
.ifdef  BSOD64_UNDER_IO
        lda # MEM_ALL_RAM       ; turn *off* BASIC,
        sta zp+1                ;  KERNAL, and I/O
.endif
        ; read byte from frozen stack
        lda frzn_stack, y
        pha
.ifdef  BSOD64_UNDER_IO
        lda # MEM_DEFAULT       ; turn *on* KERNAL,
        sta zp+1                ;  BASIC, and I/O
.endif
        pla
        jmp bsod_print_hex8

_k      dey
        lda # PET_RETURN
        jmp kernal_chrout


bsod_str_top
;-------------------------------------------------------------------------------
        .byte   PET_WHITE, PET_CLR, PET_LCASE, PET_CASEOFF
        .byte   PET_RVSON
        .text   "PC:   A: X: Y: NV-BDIZC 0123456789ABCDEF"
        .byte   PET_RVSOFF
        .text   "$"
        ; these values have to be stored within the code space because they
        ; have to be backed up early, before the I/O shield is turned off.
        ; if BSDO64 can run at all then, logically, these addresses are
        ; accessible
        .byte   STR_HEXW
frzn_pc
frzn_pc_lo
        .byte   $00
frzn_pc_hi
        .byte   $00
        .text   " "
        .byte   STR_HEXB
frzn_a  .byte   $00
        .text   " "
        .byte   STR_HEXB
frzn_x  .byte   $00
        .text   " "
        .byte   STR_HEXB
frzn_y  .byte   $00
        .text   " "
        .byte   STR_FLAGS
frzn_f  .byte   %00000000
        .text   " "

bsod_str_banks
        ;-----------------------------------------------------------------------
bsod_str_banks_vic
bsod_str_banks_vic0             ; VIC-bank 0 ($0000-$3FFF)
        .text   "...."          ; zeropage, stack, work RAM
bsod_str_banks_vic1             ; VIC-bank 1 ($4000-$7FFF)
        .text   "...."
bsod_str_banks_vic2             ; VIC-bank 2 ($8000-$BFFF)
        .text   ".."            ; cart ROM LO ($8000-$9FFF)
bsod_str_banks_b 
        .text   ".."            ; BASIC ROM ($A000-$BFFF)
bsod_str_banks_vic3             ; VIC-bank 3 ($C000-$FFFF)
        .text   "."             ; $C000 is always RAM
bsod_str_banks_i
        .text   "."             ; I/O ($D000-$DFFF)
bsod_str_banks_k
        .text   ".."            ; KERNAL ROM ($E000-$FFFF)

bsod_str_zp
        ;-----------------------------------------------------------------------
        .byte   STR_POS, 5, 0
        .byte   PET_RVSON
        .text   "zeropage:                      stack:$"
        .byte   STR_HEXB
frzn_sp .byte   $00
        .byte   PET_RVSOFF, PET_RETURN
        .byte   STR_END

_rts    rts

bsod_print
;===============================================================================
; in:   A       address of PETSCII string, lo-byte
;       X       address of PETSCII string, hi-byte
;-------------------------------------------------------------------------------
        sta zp_str_lo           ; store the PETSCII string
        stx zp_str_hi           ;  address in zero-page for indexing
        ldy # $ff               ; string index (start at -1 for pre-increment)
        bne _loop               ; jump into the loop

        ;-----------------------------------------------------------------------
_cc     jsr _pos                ; handle custom control code

_loop   iny                     ; move to next character
        lda (zp_str), y         ; read character from string
        beq _rts                ; = .STR_END? -- stop printing
        cmp # $20               ; values $00-$1F are control codes
        bcc _cc                 ; handle custom control code?

        ; not a control code:
        jsr kernal_chrout       ; print the character
        bne _loop               ; keep looping

        ; our custom control codes:
        ;
        ; STR_POS : set cursor location
        ;-----------------------------------------------------------------------
_pos    cmp # STR_POS           ; =STR_POS? -- set cursor position
        bne _hexw

        iny                     ; (move to next byte in string)
        lda (zp_str), y         ; read cursor row
        tax                     ; use X for KERNAL call
        iny                     ; (move to next byte in string)
        lda (zp_str), y         ; read cursor column
        sty _y+1                ; (backup Y before KERNAL call)
        tay                     ; move cursor col to Y-register
        clc                     ; = set cursor
        jsr kernal_plot         ; call KERNAL to position cursor
_y      ldy # NULL_VALUE        ; restore string index
        rts

        ; STR_HEXW : print 16-bit hexadecimal value
        ;-----------------------------------------------------------------------
_hexw   cmp # STR_HEXW          ; =STR_HEXW? -- print 16-bit hexadecimal value
        bne _hexb

        iny                     ; (move to next byte in string)
        lda (zp_str), y         ; read value to print, hi-byte
        tax                     ; put aside hi-byte
        iny                     ; (move to next byte in string)
        lda (zp_str), y         ; read value to print, lo-byte
        jmp bsod_print_hex16

        ; .STR_HEXB : print 8-bit hexadecimal value
        ;-----------------------------------------------------------------------
_hexb   cmp # STR_HEXB          ; =STR_HEXB? -- print 8-bit hexadecimal value
        bne _flags

        iny                     ; (move to next byte in string)
        lda (zp_str), y         ; read value to print
        jmp bsod_print_hex8     ; print two hexadecimal digits

        ; .STR_FLAGS : print 8-bit binary value as flags
        ;-----------------------------------------------------------------------
_flags  cmp # STR_FLAGS         ; =STR_FLAGS?
        bne _none

        iny                     ; (move to next byte in string)
        lda (zp_str), y         ; read value to print
        sec
        jmp bsod_print_bin8
        
        ;-----------------------------------------------------------------------
_none   jmp kernal_chrout       ; handle the PETSCII control code


bsod_hook
;===============================================================================
;
;-------------------------------------------------------------------------------
        sei                     ; disable interrupts whilst we alter them...
        
        lda #< bsod_hook_nmi
        sta vectors+VECTOR_NMI+lo
        lda #> bsod_hook_nmi
        sta vectors+VECTOR_NMI+hi

        cli                     ; re-enable interrupts
        rts

bsod_hook_nmi
        ;-----------------------------------------------------------------------
        pha
        txa
        pha
        tya
        pha

        jsr bsod_irq

        pla
        tay
        pla
        tax
        pla

        ; return from interrupt
        ; (restore processor flags, enable interrupts)
        rti


;===============================================================================
; interrupt handlers:
;
; when the KERNAL ROM is switched on, it controls the interrupt vectors at
; $FFFA-$FFFF. this means that there's some extra indirection that happens
; whenever an IRQ occurs. first, the KERNAL pushes A, X & Y onto the stack
; and then calls the vector at $0314; by default this is the routine that
; handles the BASIC interrupt, e.g. blinking the cursor. if the KERNAL is
; on but BASIC is off, the system will crash!
;
; unless you are writing a BASIC extension there is no reason to keep BASIC
; switched on (you can use the RAM underneath instead), therefore we must
; provide a routine to replace the BASIC interrupt. it doesn't have to do
; any actual work, just merely exit in the correct way, that is, restore
; the register from the stack and call `rti`. alternatively, one can jump
; to $EA81 which is the KERNAL's code to do the same, but I recommend
; against this because that assumes that the machine is a C64 with
; stock ROMs and this might not be the case!
;
;-------------------------------------------------------------------------------
bsod_irq_kernalon
        ; pull the registers from the stack
        ; (in reverse order)
        pla                     ; pull...
        tay                     ; ...Y
        pla                     ; pull...
        tax                     ; ...X
        pla                     ; pull A

bsod_irq_nokernal
        ;-----------------------------------------------------------------------
        ; acknowledge the interrupt
        asl cia1+CIA_IRQ
        
        ; return from interrupt
        ; (restore processor flags, enable interrupts)
        rti

; likewise, without the KERNAL, the RAM underneath
; will determine the NMI handler (the RESTORE key)
;
bsod_nmi_nokernal
        ;-----------------------------------------------------------------------
        ; acknowledge the interrupt (we must R/M/W the register)
        asl cia2+CIA_IRQ

bsod_nmi_kernalon
        ;-----------------------------------------------------------------------
        ; return from interrupt
        ; (restore processor flags, enable interrupts)
        rti


bsod_push
;===============================================================================
; normalise the stack to appear the same as the interrupt call would:
; this reduces the complexity of handling the different methods
; of invoking BSOD64
;
; this generates the following stack profile:
;
;       top  -> return-address, lo-byte (pushed by a JSR to `.bsod_freeze`)
;               return-address, hi-byte (pushed by a JSR to `.bsod_freeze`)
;               Y register              (pushed by this routine)
;               X register              (pushed by this routine)
;               A register              (pushed by this routine)
;               processor status        (pushed by this routine)
;               PC lo-byte              (pushed by the JSR to BSOD64)
;               PC hi-byte              (pushed by the JSR to BSOD64)
;
;-------------------------------------------------------------------------------
        ; push the processor status to the stack:
        ;
        ; even though an interrupt could occur between this instruction
        ; and the next, we need to capture the current interrupt flag state
        ; before changing it
        ;
        ; WARNING: the PHP instruction *always sets the BRK bit!*
        ; a flag is set (below) to indicate that BSOD64 was invoked by JSR
        ; instead of BRK to ensure that BSOD64 does not misinterpret the
        ; machine state -- BRK adds 2 to the program counter!
        ;
        php                     ; push processor flags
        sei                     ; disable interrupts
        ; push the registers
        pha                     ; A,
        txa                     ; X,
        pha
        tya                     ; Y
        pha
        ; set flag to indicate BSOD64 being invoked by JSR
        ; -- we will have to resume execution differently
        lda # $ff
        sta bsod_is_jsr

        ; now begin the freeze
        jsr bsod_freeze

        ; fallthrough
        ; ...

bsod_defrost
;===============================================================================
        rts


; depending on how BSDO64 is invoked, different actions
; must be taken during the freeze and defrost
;
bsod_is_jsr     ; BSOD64 invoked by JSR? $00 = no, $FF = yes
        .byte   NULL_VALUE
bsod_is_brk     ; BRK interrupt flag: $00 = no, $FF = yes
        .byte   NULL_VALUE


bsod_print_hex16
;===============================================================================
; print a 16-bit value as PETSCII hexadecimal:
;
; in:   A       value, hi-byte
;       X       value, lo-byte
;-------------------------------------------------------------------------------
        jsr bsod_print_hex8     ; print hi-byte first, X will be preserved
        txa                     ; switch to value's lo-byte

        ; fallthrough
        ; ...

bsod_print_hex8
;===============================================================================
; print a byte as PETSCII hexadecimal:
;
; in:   A       byte value
;
; out:  X, Y    (preserved)
;-------------------------------------------------------------------------------
        sed                     ; enable decimal mode
        pha                     ; put original value aside

        lsr                     ; shift upper nybble down
        lsr                     ; ...
        lsr                     ; ...
        lsr                     ; ...
        cmp # 9+1
        adc # $30               ; rebase to PETSCII '0' and above
        jsr kernal_chrout       ; NOTE: no effect from decimal mode?

        pla                     ; retrieve original value
        and # %00001111         ; extract lower nybble
        cmp # 9+1
        adc # $30               ; rebase to PETSCII '0' and above
        
        cld                     ; disable decimal mode
        
        ; print the last digit
        ; (X & Y are preserved)
        jmp kernal_chrout


bsod_print_bin8
;===============================================================================
; print a byte as PETSCII binary:
;
; in:   A       value
;      -c       use 0/1 digits
;      +c       use -/* digits
; out:  Y       (preserved)
;       X       (clobbered)
;
; TODO: compact into one copy of the loop
;-------------------------------------------------------------------------------
        ; check the carry state. if carry is set binary
        ; digits will be printed as "-" = 0 and "*" = 1
        bcs _sym                ; carry set = use symbols

        ; print "0" & "1" digits
        ;-----------------------------------------------------------------------
_dig    asl                     ; pop a bit off the value
        tax                     ; remember remainder for next loop
        lda # $30               ; PETSCII '0'
        adc # 0                 ; PETSCII '1' if bit was 1
        jsr kernal_chrout       ; print digit

        txa                     ; retrieve remaining value before looping
        asl _count              ; shift counter along
        bne _dig                ; keep looping until the bit falls off
        
        rol _count              ; (put the bit back on the end)
        rts

        ; print "-" & "*" digits
        ;-----------------------------------------------------------------------
_sym    asl                     ; pop a bit off the value
        tax                     ; remember remainder for next loop

        bcc _l                  ; is bit 0 or 1?
        lda # $2a               ; PETSCII '*'
        ; (skip next 2-byte instruction)
        #skip2
_l      lda # $2d               ; PETSCII '-'
        jsr kernal_chrout
        
        txa                     ; retrieve remaining value before looping
        asl _count              ; shift counter along
        bne _sym                ; keep looping until the bit falls off
        
        rol _count              ; (put the bit back on the end)
        rts

_count  .byte   $00000001

;===============================================================================
; these values have to be stored within the code space because they have to be
; backed up early, before the I/O shield is turned if the BSDO64 code can run
; at all then, logically, these addresses are accessible
;
frzn_cpu_ddir   ; backup of the CPU data-direction port ($00)
        .byte   NULL_VALUE
                        
frzn_cpu_port   ; backup of the CPU port ($01)
        .byte   NULL_VALUE
                        
frzn_nmi        ; NMI vector
frzn_nmi_lo
        .byte   NULL_VALUE
frzn_nmi_hi
        .byte   NULL_VALUE
                        
frzn_rst        ; RESET vector
frzn_rst_lo
        .byte   NULL_VALUE
frzn_rst_hi
        .byte   NULL_VALUE
                        
frzn_irq        ; IRQ vector
frzn_irq_lo
        .byte   NULL_VALUE
frzn_irq_hi
        .byte   NULL_VALUE

frzn_cia2       ; CIA #2 port A (contains VIC bank)
        .byte   NULL_VALUE