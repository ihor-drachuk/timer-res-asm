; License:  MIT
; Source:   https://github.com/ihor-drachuk/timer-res-asm
; Contact:  ihor-drachuk-libs@pm.me

; backend.inc - common timer-resolution helpers shared by GUI and CLI.
;
; All helpers are `proc`/`endp` purely so FASM's prologue keeps the stack
; 16-aligned before every `invoke`/`call` (a hand-rolled prologue with the
; wrong sub-rsp amount misaligns RSP and can crash inside the callee). These
; procs declare NO named params: they read their register arguments (ecx/rdx)
; directly, since FASM's `proc` does NOT spill RCX/RDX/R8/R9 into param slots
; for a `call`-style entry — it would read uninitialized shadow space instead.
;
; Includer provides .data: pNtQuery, pNtSet, hNtdll, tMin, tMax, tCur, tActual,
; lastDesired, ntdll_name, qry_name, set_name, fmt_ms.

RES_MAX     = 5000
RES_DEFHI   = 10000
RES_RELEASE = 0

; --------------------------------------------------------------------------
; LoadNtdllApis - resolves NtQueryTimerResolution / NtSetTimerResolution into
; [pNtQuery] / [pNtSet]. On failure they stay 0 and the other helpers no-op.
proc LoadNtdllApis
        invoke  GetModuleHandle, ntdll_name
        test    rax, rax
        jz      .done
        mov     [hNtdll], rax
        invoke  GetProcAddress, [hNtdll], qry_name
        mov     [pNtQuery], rax
        invoke  GetProcAddress, [hNtdll], set_name
        mov     [pNtSet], rax
.done:
        ret
endp

; --------------------------------------------------------------------------
; DoQuery - NtQueryTimerResolution(&tMin, &tMax, &tCur). No-op if unresolved.
proc DoQuery
        cmp     qword [pNtQuery], 0
        je      .skip
        lea     rcx, [tMin]
        lea     rdx, [tMax]
        lea     r8,  [tCur]
        call    qword [pNtQuery]
.skip:
        ret
endp

; --------------------------------------------------------------------------
; DoSet: ecx = desired (100-ns units). Records lastDesired and invokes
; NtSetTimerResolution(desired, set?, &tActual). desired == 0 -> release.
proc DoSet
        mov     [lastDesired], ecx
        cmp     qword [pNtSet], 0
        je      .skip
        mov     ecx, [lastDesired]
        mov     edx, 1
        test    ecx, ecx
        jnz     .have_flag
        xor     edx, edx
.have_flag:
        lea     r8, [tActual]
        call    qword [pNtSet]
.skip:
        ret
endp

; --------------------------------------------------------------------------
; FormatRes: ecx = value (100-ns units), rdx = outBuf (>= 24 wchars/bytes).
; Writes "<u>.<u04> ms\0" into outBuf. Returns length-in-chars in EAX.
proc FormatRes
   local outBuf:QWORD, whole:DWORD, rem:DWORD
        mov     [outBuf], rdx
        ; div: eax=value, edx:eax / 10000
        mov     eax, ecx
        xor     edx, edx
        mov     ecx, 10000
        div     ecx
        mov     [whole], eax
        mov     [rem], edx
        invoke  wsprintf, [outBuf], fmt_ms, [whole], [rem]
        ret
endp
