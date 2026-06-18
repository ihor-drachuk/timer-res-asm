; License:  MIT
; Source:   https://github.com/ihor-drachuk/timer-res-asm
; Contact:  ihor-drachuk-libs@pm.me

; timer-res-test-tool.exe - console companion for timer-res.exe.
; Win64 / FASM 1.73+. Pure ASCII.
;
; Usage:
;   timer-res-test-tool                    same as `query`
;   timer-res-test-tool query              print Min / Max / Current
;   timer-res-test-tool set max|1ms|default|<int>
;                                    set timer resolution then print state
;   timer-res-test-tool hold max|1ms|<int> <seconds>
;                                    set, then loop printing Current once a
;                                    second for <seconds>, then release
;
; All ABI: Win64 fastcall, manual stack frames. No `proc` macros for our
; own helpers - Windows callbacks (none here) would need them.

format PE64 CONSOLE 5.0
entry start

include 'win64ax.inc'

; ---------------------------------------------------------------------------

section '.text' code readable executable

start:
        sub     rsp, 40                        ; main frame: 32 shadow + 8 pad

        call    LoadNtdllApis
        cmp     qword [pNtQuery], 0
        je      .bail_backend
        cmp     qword [pNtSet], 0
        je      .bail_backend

        invoke  GetCommandLineA
        mov     [rawCmd], rax
        ; Parse argv (mutates the string in place - that's documented behavior)
        mov     rcx, rax
        call    ParseArgs                      ; -> [argc], [argv0..argvN]

        ; Dispatch
        cmp     dword [argc], 2
        jl      .cmd_query
        mov     rcx, [argv + 8]                ; argv[1]
        mov     rdx, str_query
        call    StrEqI
        test    eax, eax
        jnz     .cmd_query
        mov     rcx, [argv + 8]
        mov     rdx, str_set
        call    StrEqI
        test    eax, eax
        jnz     .cmd_set
        mov     rcx, [argv + 8]
        mov     rdx, str_hold
        call    StrEqI
        test    eax, eax
        jnz     .cmd_hold
        mov     rcx, [argv + 8]
        mov     rdx, str_autostart
        call    StrEqI
        test    eax, eax
        jnz     .cmd_autostart
        jmp     .usage

.cmd_query:
        call    DoQuery
        call    PrintState
        invoke  ExitProcess, 0

.cmd_set:
        cmp     dword [argc], 3
        jl      .usage
        mov     rcx, [argv + 16]               ; argv[2]
        call    ParseValueArg
        cmp     eax, -1
        je      .usage
        mov     ecx, eax
        call    DoSet
        call    DoQuery
        call    PrintState
        invoke  ExitProcess, 0

.cmd_hold:
        cmp     dword [argc], 4
        jl      .usage
        mov     rcx, [argv + 16]
        call    ParseValueArg
        cmp     eax, -1
        je      .usage
        mov     [holdVal], eax
        mov     rcx, [argv + 24]
        call    ParseUInt
        cmp     eax, -1
        je      .usage
        mov     [holdSecs], eax
        mov     ecx, [holdVal]
        call    DoSet
        mov     dword [holdI], 0
.hold_loop:
        mov     eax, [holdI]
        cmp     eax, [holdSecs]
        jae     .hold_done
        call    DoQuery
        call    PrintState
        invoke  Sleep, 1000
        inc     dword [holdI]
        jmp     .hold_loop
.hold_done:
        mov     ecx, RES_RELEASE
        call    DoSet
        mov     rcx, msg_released
        call    PrintLineCStr
        invoke  ExitProcess, 0

.cmd_autostart:
        cmp     dword [argc], 3
        jl      .as_status
        mov     rcx, [argv + 16]               ; argv[2]
        mov     rdx, str_on
        call    StrEqI
        test    eax, eax
        jnz     .as_on
        mov     rcx, [argv + 16]
        mov     rdx, str_off
        call    StrEqI
        test    eax, eax
        jnz     .as_off
.as_status:
        call    IsAutostartEnabled
        test    eax, eax
        jz      .as_status_off
        mov     rcx, msg_as_on
        call    PrintLineCStr
        invoke  ExitProcess, 0
.as_status_off:
        mov     rcx, msg_as_off
        call    PrintLineCStr
        invoke  ExitProcess, 0
.as_on:
        call    SetAutostartOn
        mov     rcx, msg_as_set
        call    PrintLineCStr
        invoke  ExitProcess, 0
.as_off:
        call    SetAutostartOff
        mov     rcx, msg_as_cleared
        call    PrintLineCStr
        invoke  ExitProcess, 0

.bail_backend:
        mov     rcx, msg_no_backend
        call    PrintLineCStr
        invoke  ExitProcess, 2

.usage:
        mov     rcx, msg_usage
        call    PrintLineCStr
        invoke  ExitProcess, 1

; --------------------------------------------------------------------------
; PrintState - builds and prints "min=... max=... cur=... (lastDesired=...)"
PrintState:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 48                        ; 32 shadow + 2 outgoing qword slots; keeps RSP 16-aligned
        mov     ecx, [tMin]
        lea     rdx, [bufA]
        call    FormatRes
        mov     ecx, [tMax]
        lea     rdx, [bufB]
        call    FormatRes
        mov     ecx, [tCur]
        lea     rdx, [bufC]
        call    FormatRes
        ; wsprintfA(lineBuf, fmt_state, bufA, bufB, bufC, lastDesired)
        ; Args 1-4 -> RCX,RDX,R8,R9. Args 5-6 -> [rsp+32], [rsp+40].
        lea     rcx, [lineBuf]
        mov     rdx, fmt_state
        lea     r8,  [bufA]
        lea     r9,  [bufB]
        lea     rax, [bufC]
        mov     [rsp + 32], rax
        mov     eax, [lastDesired]
        mov     [rsp + 40], rax
        call    [wsprintf]
        mov     [lineLen], eax
        ; WriteFile(hOut, lineBuf, lineLen, &wrote, 0)
        invoke  GetStdHandle, -11
        mov     rcx, rax
        lea     rdx, [lineBuf]
        mov     r8d, [lineLen]
        lea     r9,  [wrote]
        mov     qword [rsp + 32], 0
        call    [WriteFile]
        ; trailing CRLF
        invoke  GetStdHandle, -11
        mov     rcx, rax
        mov     rdx, crlf_buf
        mov     r8d, 2
        lea     r9,  [wrote]
        mov     qword [rsp + 32], 0
        call    [WriteFile]
        leave
        ret

; --------------------------------------------------------------------------
; PrintLineCStr: rcx = zero-terminated C string. Writes it + CRLF to stdout.
PrintLineCStr:
        push    rbp
        mov     rbp, rsp
        push    rsi                            ; preserve nonvolatile RSI
        sub     rsp, 48                        ; 32 shadow + 2 stash slots; 2 pushes keep RSP 16-aligned
        mov     [rsp + 32], rcx                ; stash str
        ; strlen
        mov     rsi, rcx
        xor     ecx, ecx
.len:
        cmp     byte [rsi + rcx], 0
        je      .got
        inc     ecx
        jmp     .len
.got:
        mov     [rsp + 40], ecx                ; len
        invoke  GetStdHandle, -11
        mov     rcx, rax
        mov     rdx, [rsp + 32]
        mov     r8d, [rsp + 40]
        lea     r9,  [wrote]
        mov     qword [rsp + 32], 0
        call    [WriteFile]
        invoke  GetStdHandle, -11
        mov     rcx, rax
        mov     rdx, crlf_buf
        mov     r8d, 2
        lea     r9,  [wrote]
        mov     qword [rsp + 32], 0
        call    [WriteFile]
        add     rsp, 48
        pop     rsi
        leave
        ret

; --------------------------------------------------------------------------
; StrEqI: rcx = a, rdx = b. ASCII case-insensitive equality. EAX = 0 / 1.
; Preserves RSI/RDI (nonvolatile per the Win64 ABI).
StrEqI:
        push    rsi
        push    rdi
        mov     rsi, rcx
        mov     rdi, rdx
.next:
        movzx   eax, byte [rsi]
        movzx   ecx, byte [rdi]
        cmp     al, 'A'
        jb      .a_ok
        cmp     al, 'Z'
        ja      .a_ok
        add     al, 32
.a_ok:
        cmp     cl, 'A'
        jb      .b_ok
        cmp     cl, 'Z'
        ja      .b_ok
        add     cl, 32
.b_ok:
        cmp     al, cl
        jne     .neq
        test    al, al
        jz      .eq
        inc     rsi
        inc     rdi
        jmp     .next
.eq:
        mov     eax, 1
        pop     rdi
        pop     rsi
        ret
.neq:
        xor     eax, eax
        pop     rdi
        pop     rsi
        ret

; --------------------------------------------------------------------------
; ParseValueArg: rcx = C string. Returns 100-ns desired in EAX, or -1 on error.
; "max" -> 5000, "1ms" -> 10000, "default" -> 0, otherwise parse as uint.
ParseValueArg:
        push    rbp
        mov     rbp, rsp
        push    rbx                            ; preserve the caller's string ptr here
        sub     rsp, 32                        ; shadow space for the StrEqI/ParseUInt calls
        mov     rbx, rcx                       ; rbx (nonvolatile, restored below) holds the arg
        mov     rdx, str_max
        call    StrEqI
        test    eax, eax
        jz      .try_1ms
        mov     eax, RES_MAX
        jmp     .done
.try_1ms:
        mov     rcx, rbx
        mov     rdx, str_1ms
        call    StrEqI
        test    eax, eax
        jz      .try_def
        mov     eax, RES_DEFHI
        jmp     .done
.try_def:
        mov     rcx, rbx
        mov     rdx, str_default
        call    StrEqI
        test    eax, eax
        jz      .try_int
        xor     eax, eax
        jmp     .done
.try_int:
        mov     rcx, rbx
        call    ParseUInt
.done:
        add     rsp, 32
        pop     rbx
        leave
        ret

; --------------------------------------------------------------------------
; ParseUInt: rcx = C string. EAX = parsed value, -1 on non-digit / empty / overflow.
; Preserves RSI. Rejects values that overflow 32 bits.
ParseUInt:
        push    rsi
        mov     rsi, rcx
        cmp     byte [rsi], 0
        je      .bad
        xor     eax, eax
.next:
        movzx   edx, byte [rsi]
        test    dl, dl
        jz      .done
        sub     edx, '0'
        js      .bad
        cmp     edx, 9
        ja      .bad
        ; reject before it can overflow 32 bits: cap at 100_000_000, far above
        ; any sane timer-resolution value (in 100-ns units) yet leaves headroom.
        cmp     eax, 100000000
        jae     .bad
        lea     eax, [eax + eax*4]             ; eax *= 5
        add     eax, eax                       ; eax *= 2  -> *10 total
        add     eax, edx
        inc     rsi
        jmp     .next
.done:
        pop     rsi
        ret
.bad:
        mov     eax, -1
        pop     rsi
        ret

; --------------------------------------------------------------------------
; ParseArgs: rcx = cmdline (mutated in place). Populates argv[]/argc.
; Honors "double-quoted" runs as a single arg (quotes stripped).
ParseArgs:
        push    rbp
        mov     rbp, rsp
        push    rsi                            ; preserve nonvolatile RSI/RBX
        push    rbx
        sub     rsp, 32
        mov     rsi, rcx
        xor     ebx, ebx                       ; arg count
.scan_ws:
        movzx   eax, byte [rsi]
        cmp     al, ' '
        je      .ws
        cmp     al, 9
        je      .ws
        test    al, al
        jz      .done
        cmp     bl, 32
        jae     .done
        cmp     al, '"'
        je      .quoted
        mov     [argv + rbx*8], rsi
        inc     rbx
.word:
        movzx   eax, byte [rsi]
        test    al, al
        jz      .done
        cmp     al, ' '
        je      .term
        cmp     al, 9
        je      .term
        inc     rsi
        jmp     .word
.quoted:
        inc     rsi
        mov     [argv + rbx*8], rsi
        inc     rbx
.q_scan:
        movzx   eax, byte [rsi]
        test    al, al
        jz      .done
        cmp     al, '"'
        je      .term
        inc     rsi
        jmp     .q_scan
.term:
        mov     byte [rsi], 0
        inc     rsi
        jmp     .scan_ws
.ws:
        inc     rsi
        jmp     .scan_ws
.done:
        mov     [argc], ebx
        add     rsp, 32
        pop     rbx
        pop     rsi
        leave
        ret

; --------------------------------------------------------------------------

include 'autostart.inc'
include 'backend.inc'

; ---------------------------------------------------------------------------

section '.data' data readable writeable

  ntdll_name   db 'ntdll.dll', 0
  qry_name     db 'NtQueryTimerResolution', 0
  set_name     db 'NtSetTimerResolution', 0
  fmt_ms       db '%u.%04u ms', 0
  fmt_state    db 'min=%s  max=%s  cur=%s  (lastDesired=%u)', 0
  msg_no_backend db 'ntdll NtQuery/NtSetTimerResolution not resolvable', 0
  msg_usage    db 'usage: timer-res-test-tool [query | set <v> | hold <v> <secs> | autostart on|off|status]', 13, 10, \
                  '       v ::= max | 1ms | default | <100ns int>', 13, 10, \
                  'note: timer resolution is per-process; `set` only holds while this', 13, 10, \
                  '      process runs. Use `hold` or the GUI to keep it applied.', 0
  msg_released db '(released)', 0
  msg_as_on      db 'autostart: enabled', 0
  msg_as_off     db 'autostart: disabled', 0
  msg_as_set     db 'autostart: written', 0
  msg_as_cleared db 'autostart: removed', 0
  crlf_buf     db 13, 10

  str_query    db 'query', 0
  str_set      db 'set', 0
  str_hold     db 'hold', 0
  str_autostart db 'autostart', 0
  str_on       db 'on', 0
  str_off      db 'off', 0
  str_max      db 'max', 0
  str_1ms      db '1ms', 0
  str_default  db 'default', 0

  ; autostart.inc shared wide strings
  run_key      du 'Software\Microsoft\Windows\CurrentVersion\Run', 0
  run_val      du 'TimerRes', 0

  ; --- mutable state (qwords / OUT params / buffers) ---
  ; align so qword pointers/handles sit on their natural 8-byte boundary after
  ; the odd-length strings above (FASM does no auto-padding). 16 is harmless.
  align 16
  pNtQuery     dq 0
  pNtSet       dq 0
  hNtdll       dq 0
  hRegKey      dq 0
  rawCmd       dq 0
  tMin         dd 0
  tMax         dd 0
  tCur         dd 0
  tActual      dd 0
  lastDesired  dd 0
  lineLen      dd 0
  wrote        dd 0
  argc         dd 0
  holdVal      dd 0
  holdSecs     dd 0
  holdI        dd 0
  align 16
  exePath      rw MAX_PATH + 8
  align 16
  argv         dq 32 dup (0)
  bufA         rb 32
  bufB         rb 32
  bufC         rb 32
  lineBuf      rb 256

; ---------------------------------------------------------------------------

section '.idata' import data readable writeable

  library kernel32, 'KERNEL32.DLL', \
          user32,   'USER32.DLL', \
          advapi32, 'ADVAPI32.DLL'

  import kernel32, \
         GetModuleHandle,    'GetModuleHandleA', \
         GetModuleFileNameW, 'GetModuleFileNameW', \
         GetProcAddress,     'GetProcAddress', \
         GetCommandLineA,    'GetCommandLineA', \
         GetStdHandle,       'GetStdHandle', \
         WriteFile,          'WriteFile', \
         Sleep,              'Sleep', \
         ExitProcess,        'ExitProcess'

  import user32, \
         wsprintf,        'wsprintfA'

  import advapi32, \
         RegOpenKeyExW,   'RegOpenKeyExW', \
         RegQueryValueExW,'RegQueryValueExW', \
         RegCreateKeyExW, 'RegCreateKeyExW', \
         RegSetValueExW,  'RegSetValueExW', \
         RegDeleteValueW, 'RegDeleteValueW', \
         RegCloseKey,     'RegCloseKey'
