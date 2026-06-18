; License:  MIT
; Source:   https://github.com/ihor-drachuk/timer-res-asm
; Contact:  ihor-drachuk-libs@pm.me

; autostart.inc - HKCU\...\Run helpers shared by GUI and CLI.
;
; All three are `proc`/`endp` so FASM's prologue keeps the stack 16-aligned
; (fill = 8*(counter and 1)) before the registry calls. They take no register
; arguments (everything is in shared .data: run_key, run_val, exePath, hRegKey).

; --------------------------------------------------------------------------
; IsAutostartEnabled - EAX = 1 if HKCU Run\TimerRes exists, else 0.
proc IsAutostartEnabled uses rbx
        invoke  RegOpenKeyExW, HKEY_CURRENT_USER, run_key, 0, KEY_READ, hRegKey
        test    eax, eax
        jnz     .no
        invoke  RegQueryValueExW, [hRegKey], run_val, 0, 0, 0, 0
        mov     ebx, eax
        invoke  RegCloseKey, [hRegKey]
        test    ebx, ebx
        jnz     .no
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret
endp

; --------------------------------------------------------------------------
; SetAutostartOn - writes `"<full exe path>" -min` (UTF-16) to HKCU Run.
proc SetAutostartOn uses rsi rbx
   local valLen:DWORD
        ; exePath layout: [0]=opening quote, [2..]=path from GetModuleFileNameW.
        ; The call returns the WCHAR count written (excluding NUL); it equals
        ; MAX_PATH on truncation, so bail then to avoid building a bad command
        ; and walking off the buffer.
        invoke  GetModuleFileNameW, 0, exePath + 2, MAX_PATH
        test    eax, eax
        jz      .done                           ; failed
        cmp     eax, MAX_PATH
        jae     .done                           ; truncated (path too long)
        mov     word [exePath], 0x22            ; leading L'"'
        ; rsi -> the terminating NUL: exePath + 2 + (count * 2)
        lea     rsi, [exePath + 2]
        lea     rsi, [rsi + rax*2]
        ; append: '"', ' ', '-', 'm', 'i', 'n', NUL   (all WCHARs)
        mov     word [rsi],      0x22
        mov     word [rsi + 2],  0x20
        mov     word [rsi + 4],  0x2D
        mov     word [rsi + 6],  0x6D
        mov     word [rsi + 8],  0x69
        mov     word [rsi + 10], 0x6E
        mov     word [rsi + 12], 0
        ; byte length incl. terminator = (rsi + 14) - exePath
        lea     rax, [rsi + 14]
        lea     rbx, [exePath]
        sub     rax, rbx
        mov     [valLen], eax
        invoke  RegOpenKeyExW, HKEY_CURRENT_USER, run_key, 0, KEY_SET_VALUE, hRegKey
        test    eax, eax
        jnz     .done
        invoke  RegSetValueExW, [hRegKey], run_val, 0, REG_SZ, exePath, [valLen]
        invoke  RegCloseKey, [hRegKey]
.done:
        ret
endp

; --------------------------------------------------------------------------
; SetAutostartOff - deletes the HKCU Run\TimerRes value.
proc SetAutostartOff
        invoke  RegOpenKeyExW, HKEY_CURRENT_USER, run_key, 0, KEY_SET_VALUE, hRegKey
        test    eax, eax
        jnz     .done
        invoke  RegDeleteValueW, [hRegKey], run_val
        invoke  RegCloseKey, [hRegKey]
.done:
        ret
endp
