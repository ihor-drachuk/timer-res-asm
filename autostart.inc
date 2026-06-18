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
proc SetAutostartOn uses rsi rdi rbx
   local valLen:DWORD
        ; Build  "<exe path>" --min --resume  (UTF-16) in exePath:
        ;   exePath[0] = opening quote, [2..] = path, then run_suffix appended.
        ; GetModuleFileNameW returns the WCHAR count (excluding NUL); it equals
        ; MAX_PATH on truncation, so bail then to avoid a bad command / overrun.
        invoke  GetModuleFileNameW, 0, exePath + 2, MAX_PATH
        test    eax, eax
        jz      .done                           ; failed
        cmp     eax, MAX_PATH
        jae     .done                           ; truncated (path too long)
        mov     word [exePath], 0x22            ; leading L'"'
        ; rdi -> the path's terminating NUL: exePath + 2 + count*2
        lea     rdi, [exePath + 2]
        lea     rdi, [rdi + rax*2]
        ; append run_suffix (including its NUL) WCHAR by WCHAR via movsw
        lea     rsi, [run_suffix]
.copy:
        movsw                                   ; [rdi] <- [rsi]; both += 2
        cmp     word [rsi - 2], 0
        jne     .copy
        ; byte length incl. terminator = rdi - exePath
        mov     rax, rdi
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

; --------------------------------------------------------------------------
; StoreLastValue - ecx = value (100-ns units). Persists it as a REG_DWORD under
; HKCU\Software\timer-res\LastValue. ecx == 0 (release) deletes the value so a
; later --resume becomes a no-op. No named params (reads ecx directly).
proc StoreLastValue
        mov     [storeVal], ecx                ; spill before any volatile-RCX call
        cmp     dword [storeVal], 0
        jne     .write
        ; release: drop the stored value (key may not exist - that's fine)
        invoke  RegOpenKeyExW, HKEY_CURRENT_USER, app_key, 0, KEY_SET_VALUE, hRegKey
        test    eax, eax
        jnz     .done
        invoke  RegDeleteValueW, [hRegKey], last_val
        invoke  RegCloseKey, [hRegKey]
        jmp     .done
.write:
        ; open-or-create HKCU\Software\timer-res, then write the DWORD
        invoke  RegCreateKeyExW, HKEY_CURRENT_USER, app_key, 0, 0, \
                REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, 0, hRegKey, 0
        test    eax, eax
        jnz     .done
        invoke  RegSetValueExW, [hRegKey], last_val, 0, REG_DWORD, storeVal, 4
        invoke  RegCloseKey, [hRegKey]
.done:
        ret
endp

; --------------------------------------------------------------------------
; LoadLastValue - EAX = stored value (100-ns units), or 0 if key/value absent
; or not a 4-byte REG_DWORD.
proc LoadLastValue uses rbx
        mov     dword [loadBuf], 0
        mov     dword [loadLen], 4
        invoke  RegOpenKeyExW, HKEY_CURRENT_USER, app_key, 0, KEY_READ, hRegKey
        test    eax, eax
        jnz     .zero
        invoke  RegQueryValueExW, [hRegKey], last_val, 0, regType, loadBuf, loadLen
        mov     ebx, eax
        invoke  RegCloseKey, [hRegKey]
        test    ebx, ebx
        jnz     .zero
        cmp     dword [regType], REG_DWORD
        jne     .zero
        cmp     dword [loadLen], 4
        jne     .zero
        mov     eax, [loadBuf]
        ret
.zero:
        xor     eax, eax
        ret
endp
