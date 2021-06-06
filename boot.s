; Register usage:
; SP = parameter stack pointer (grows downwards from 0x7c00 - just before the entrypoint)
; DI = return stack pointer (grows upwards from 0xc00)
; SI = execution pointer
; BX = top of stack
;
; Dictionary structure:
; link: dw
; name: counted string (with flags)
;
; The Forth is DTC, as this saves 2 bytes for each defcode, while costing 3 bytes
; for each defword.

F_IMMEDIATE equ 0x80
F_HIDDEN    equ 0x40
F_LENMASK   equ 0x1f

InputBuf equ 0x600
BlockBuf equ 0x700
BlockBuf.end equ 0xb00
InputPtr  equ 0xb04 ; dw
RS0 equ 0xc00

SPECIAL_BYTE equ 0xff

%assign savings 0

%macro compression_sentinel 0
%assign savings savings+4
    db SPECIAL_BYTE
    dd 0xdeadbeef
%endmacro

; defcode PLUS, "+"
; defcode SEMI, ";", F_IMMEDIATE
%macro defcode 2-3 0
    compression_sentinel
%strlen namelength %2
    db %3 | namelength, %2
%1:
%endmacro

    org 0x7c00

    jmp 0:start
stack:
    dw HERE
    dw BASE
    dw STATE
    dw LATEST
start:
    push cs
    push cs
    push cs
    pop ds
    pop es
    ; Little known fact: writing to SS disables interrupts for the next instruction,
    ; so this is safe without an explicit cli/sti.
    pop ss
    mov sp, stack
    cld

    mov si, CompressedData
    mov di, CompressedBegin
    mov cx, COMPRESSED_SIZE
.decompress:
    lodsb
    cmp al, SPECIAL_BYTE
    jnz short .not_special
    mov ax, 0xffad ; lodsw / jmp ax
    stosw
    mov al, 0xe0
    stosb
    call MakeLink
    db 0x3c ; skip the stosb below by comparing its opcode with AL
.not_special:
    stosb
    loop .decompress

    mov [DRIVE_NUMBER], dl
    push dx ; for FORTH code

REFILL:
    mov di, InputBuf
    mov [InputPtr], di
.loop:
    mov ah, 0
    int 0x16
    call PutChar
    cmp al, 0x0d
    je short .enter
    cmp al, 0x08
    jne short .write
    cmp di, InputBuf
    je short .loop
    dec di
    db 0x3c ; skip the stosb below by comparing its opcode with AL
.write:
    stosb
    jmp short .loop
.enter:
    mov al, 0x0a
    int 0x10
    xchg ax, bx
    stosb
INTERPRET:
    call _WORD
    jcxz short REFILL
; during FIND,
; SI = dictionary pointer
; DX = string pointer
; BX = string length
FIND:
LATEST equ $+1
    mov si, 0
.loop:
    lodsw
    push ax ; save pointer to next entry
    lodsb
    xor al, cl ; if the length matches, then AL contains only the flags
    test al, F_HIDDEN | F_LENMASK
    jnz short .next
    mov di, dx
    push cx
    repe cmpsb
    pop cx
    je short Found
.next:
    pop si
    or si, si
    jnz short .loop

    ; It's a number. Push its value - we'll pop it later if it turns out we need to compile
    ; it instead.
    push bx
    ; At this point, AH is zero, since it contains the higher half of the pointer
    ; to the next word, which we know is NULL at this point. We use this to branch
    ; based on the most-significant bit of STATE, which is either 0x75 or 0xeb.
    ; If it's 0xeb, we simply branch to INTERPRET, since the numeric value has already
    ; been pushed.
    cmp byte[STATE], ah
    js short INTERPRET
    ; Otherwise, compile the literal.
    mov ax, LIT
    call _COMMA
    pop ax
    jmp short Compile

; When we get here, SI points to the code of the word, and AL contains
; the F_IMMEDIATE flag
Found:
    pop bx ; discard pointer to next entry
    or al, al
    xchg ax, si
STATE equ $ ; 0xeb (jmp) -> interpret, 0x75 (jnz) -> compile
    jmp short EXECUTE
Compile:
    call _COMMA
    jmp short INTERPRET
EXECUTE:
RetSP equ $+1
    mov di, RS0
    pop bx
    mov si, .return
    jmp ax
.return:
    dw .executed
.executed:
    mov [RetSP], di
    push bx
    jmp short INTERPRET

_COMMA:
HERE equ $+1
    mov [CompressedEnd], ax
    add word[HERE], 2
Return:
    ret

; returns
; DX = pointer to string
; CX = string length
; BX = numeric value
; clobbers SI and BP
_WORD:
    mov si, [InputPtr]
    ; repe scasb would probably save some bytes if the registers worked out - scasb
    ; uses DI instead of SI :(
.skiploop:
    mov dx, si ; if we exit the loop in this iteration, dx will point to the first letter
               ; of the word
    lodsb
    cmp al, " "
    je short .skiploop
    xor cx, cx
    xor bx, bx
.takeloop:
    ; AL is already loaded by the end of the previous iteration, or the previous loop
    and al, ~0x20 ; to uppercase, but also integrate null check and space check
    jz short Return
    inc cx
    sub al, 0x10
    cmp al, 9
    jbe .digit_ok
    sub al, "A" - 0x10 - 10
.digit_ok
    cbw
    ; imul bx, bx, <BASE> but yasm insists on encoding the immediate in just one byte...
    db 0x69, 0xdb
BASE equ $
    dw 16
    add bx, ax
    mov [InputPtr], si
    lodsb
    jmp short .takeloop

; Creates a link of the dictionary linked list at DI.
MakeLink:
    mov ax, di
    xchg [LATEST], ax
    stosw
    ret

PutChar:
    xor bx, bx
    mov ah, 0x0e
    int 0x10
    ret

DiskPacket:
    db 0x10, 0
.count:
    dw 2
.buffer:
    ; rest is zeroed out at runtime, overwriting the compressed data, which is no longer
    ; necessary

CompressedData:
    times COMPRESSED_SIZE db 0xcc

; Invariant: due to the use of compression_sentinel without a dictionary header following it,
; the first byte of LIT and EXIT must have the 0x40 (F_HIDDEN) bit set.

CompressedBegin:

DOCOL:
    xchg ax, si
    stosw
    pop si ; grab the pointer pushed by `call`
    compression_sentinel

LIT:
    push bx
    lodsw
    xchg bx, ax
    compression_sentinel

EXIT:
    dec di
    dec di
    mov si, [di]

defcode PLUS, "+"
    pop ax
    add bx, ax

defcode STORE, "!"
    pop word [bx]
    pop bx

defcode LOAD, "@"
    mov bx, [bx]

defcode CSTORE, "c!"
    pop ax
    mov [bx], al
    pop bx

defcode CLOAD, "c@"
    movzx bx, byte[bx]

defcode DUP, "dup"
    push bx

defcode DROP, "drop"
    pop bx

defcode SWAP, "swap"
    pop ax
    push bx
    xchg ax, bx

defcode TO_R, ">r"
    xchg ax, bx
    stosw
    pop bx

defcode FROM_R, "r>"
    dec di
    dec di
    push bx
    mov bx, [di]

defcode EMIT, "emit"
    xchg bx, ax
    call PutChar
    pop bx

defcode UDOT, "u."
    xchg ax, bx
    push " " - "0"
.split:
    xor dx, dx
    div word[BASE]
    push dx
    or ax, ax
    jnz .split
.print:
    pop ax
    add al, "0"
    cmp al, "9"
    jbe .got_digit
    add al, "A" - "0" - 10
.got_digit:
    call PutChar
    cmp al, " "
    jne short .print
    pop bx

defcode DISKLOAD, "load"
    pusha
.retry:
    mov si, DiskPacket
    lea di, [si+4]
    mov ax, BlockBuf
    mov [InputPtr], ax
    stosw
    xor ax, ax
    stosw
    shl bx, 1
    xchg ax, bx
    stosw
    xchg ax, bx
    stosw
    stosw
    stosw
    mov [BlockBuf.end], al
DRIVE_NUMBER equ $+1
    mov dl, 0
    mov ah, 0x42
    int 0x13
    jc short .retry
    popa
    pop bx

;; Copies the rest of the line at buf.
defcode LINE, "s:" ; ( buf -- buf+len )
    xchg bx, di
    xchg si, [InputPtr]
.copy:
    lodsb
    stosb
    or al, al
    jnz short .copy
.done:
    dec di
    xchg bx, di
    xchg si, [InputPtr]

defcode LBRACK, "[", F_IMMEDIATE
    mov byte[STATE], 0xeb

defcode RBRACK, "]"
    mov byte[STATE], 0x75

defcode SEMI, ";", F_IMMEDIATE
    mov ax, EXIT
    call _COMMA
    jmp short LBRACK

defcode COLON, ":"
    push bx
    push si
    xchg di, [HERE]
    call MakeLink
    call _WORD
    mov ax, cx
    stosb
    mov si, dx
    rep movsb
    mov al, 0xe8 ; call
    stosb
    mov ax, DOCOL-2
    sub ax, di
    stosw
    pop si
    pop bx
    xchg [HERE], di
    jmp short RBRACK
; INVARIANT: last word in compressed block does not rely on having NEXT appended by
; decompressor
CompressedEnd:

COMPRESSED_SIZE equ CompressedEnd - CompressedBegin - savings
