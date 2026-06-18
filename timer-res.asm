; License:  MIT
; Source:   https://github.com/ihor-drachuk/timer-res-asm
; Contact:  ihor-drachuk-libs@pm.me

; timer-res.exe - minimal native TimerResolution clone with tray icon.
; Built for Win64 with FASM 1.73+.
; Shares the timer-resolution backend with timer-res-test-tool.exe via backend.inc.
;
; Build-time switch WITH_ICON (define via `fasm -d WITH_ICON=1`):
;   1 -> embed timer-res.ico and use it for the window/tray (default).
;   0 -> no embedded icon; smaller exe, stock IDI_APPLICATION in the tray.
; A single source produces both exes (see build.cmd).

; default: embed the icon unless the build overrides it
if ~ defined WITH_ICON
  WITH_ICON = 1
end if

format PE64 GUI 5.0
entry start

include 'win64ax.inc'

; ---- control IDs ----------------------------------------------------------

IDD_MAIN     = 100
IDI_APP      = 101

IDS_MIN      = 201
IDS_MAX      = 202
IDS_CURRENT  = 203

IDB_MAXIMUM  = 301
IDB_DEFHI    = 302
IDB_DEFAULT  = 303
IDC_AUTORUN  = 304
IDB_4MS      = 305

TID_REFRESH  = 1
IDM_SHOW     = 3001
IDM_EXIT     = 3002
WM_TRAY      = 0x8001                          ; WM_APP + 1
TRAY_UID     = 1
NIM_ADD      = 0
NIM_DELETE   = 2
NIF_MESSAGE  = 1
NIF_ICON     = 2
NIF_TIP      = 4

; ---------------------------------------------------------------------------

section '.text' code readable executable

start:
        sub     rsp, 40
        call    LoadNtdllApis
        cmp     qword [pNtQuery], 0
        je      .no_backend
        cmp     qword [pNtSet], 0
        je      .no_backend
        ; scan the command line for --min / --resume (sets wantMin/wantResume)
        call    ParseFlags
        ; --resume: re-apply the last persisted value before the UI comes up so
        ; the dialog's first refresh shows it and the timer keeps re-applying it.
        cmp     dword [wantResume], 0
        je      .no_resume
        call    LoadLastValue
        test    eax, eax
        jz      .no_resume
        mov     ecx, eax
        call    DoSet
.no_resume:
        invoke  GetModuleHandle, 0
        mov     [hInst], rax
        invoke  DialogBoxParam, rax, IDD_MAIN, 0, DialogProc, 0
        ; release timer on exit
        mov     ecx, RES_RELEASE
        call    DoSet
        invoke  ExitProcess, 0
.no_backend:
        invoke  MessageBox, 0, err_backend, _err_title, MB_ICONERROR + MB_OK
        invoke  ExitProcess, 2

; --------------------------------------------------------------------------
; DialogProc(hdlg, uMsg, wParam, lParam)
; A `proc` so the message params live in per-call stack locals (re-entrant-safe:
; a nested dispatch like SendMessage(WM_DESTROY) gets its own frame) and the
; prologue keeps the stack 16-aligned for the API calls below.
;
; IMPORTANT: FASM's `proc` prologue does NOT spill the incoming register args
; into the named param slots — it assumes a stack-ABI caller. Windows invokes
; this callback with args in RCX/RDX/R8/R9, so we must store them ourselves
; before any use. (The param slots alias the caller's shadow space at rbp+16.)
proc DialogProc uses rbx, hdlg, umsg, wparam, lparam
        mov     [hdlg], rcx
        mov     [umsg], rdx
        mov     [wparam], r8
        mov     [lparam], r9
        mov     eax, dword [umsg]
        cmp     eax, WM_INITDIALOG
        je      .init
        cmp     eax, WM_WINDOWPOSCHANGING
        je      .pos_changing
        cmp     eax, WM_COMMAND
        je      .cmd
        cmp     eax, WM_TIMER
        je      .timer
        cmp     eax, WM_TRAY
        je      .tray
        cmp     eax, WM_DESTROY
        je      .destroy
        cmp     eax, WM_CLOSE
        je      .close
        xor     eax, eax
        jmp     .done
.pos_changing:
        ; A modal DialogBox forces the window visible right after WM_INITDIALOG,
        ; overriding the SW_HIDE we issue there. So while started with --min,
        ; strip SWP_SHOWWINDOW from the pending WINDOWPOS so it never appears.
        ; (One-shot: cleared on the first user-driven Show from the tray.)
        cmp     dword [wantMin], 0
        je      .done_zero
        mov     rax, [lparam]                  ; -> WINDOWPOS
        and     dword [rax + 32], not SWP_SHOWWINDOW  ; flags field (x64 offset 32)
        jmp     .done_zero
.init:
if WITH_ICON
        ; set the window's title-bar / taskbar icon from our resource
        invoke  LoadImage, [hInst], IDI_APP, IMAGE_ICON, 0, 0, LR_DEFAULTSIZE
        invoke  SendMessage, [hdlg], WM_SETICON, ICON_BIG, rax
        invoke  LoadImage, [hInst], IDI_APP, IMAGE_ICON, \
                16, 16, LR_DEFAULTCOLOR
        invoke  SendMessage, [hdlg], WM_SETICON, ICON_SMALL, rax
end if
        call    DoQuery
        ; format tMin into guiBuf and stuff it into IDS_MIN
        mov     ecx, [tMin]
        lea     rdx, [guiBuf]
        call    FormatRes
        invoke  SetDlgItemText, [hdlg], IDS_MIN, guiBuf
        ; same for tMax
        mov     ecx, [tMax]
        lea     rdx, [guiBuf]
        call    FormatRes
        invoke  SetDlgItemText, [hdlg], IDS_MAX, guiBuf
        ; same for tCur
        mov     ecx, [tCur]
        lea     rdx, [guiBuf]
        call    FormatRes
        invoke  SetDlgItemText, [hdlg], IDS_CURRENT, guiBuf
        ; check autostart state -> set checkbox
        call    IsAutostartEnabled
        test    eax, eax
        jz      .no_autorun_chk
        invoke  SendDlgItemMessage, [hdlg], IDC_AUTORUN, BM_SETCHECK, BST_CHECKED, 0
.no_autorun_chk:
        ; start 1-second refresh timer
        invoke  SetTimer, [hdlg], TID_REFRESH, 1000, 0
        ; add tray icon - fill NOTIFYICONDATAW fields
        mov     dword [nid.cbSize], sizeof.NOTIFYICONDATAW
        mov     rax, [hdlg]
        mov     [nid.hWnd], rax
        mov     dword [nid.uID], TRAY_UID
        mov     dword [nid.uFlags], NIF_MESSAGE + NIF_ICON + NIF_TIP
        mov     dword [nid.uCallbackMessage], WM_TRAY
if WITH_ICON
        ; small icon for the tray (standard 16x16) from our resource
        invoke  LoadImage, [hInst], IDI_APP, IMAGE_ICON, 16, 16, LR_DEFAULTCOLOR
        test    rax, rax
        jnz     .have_tray_icon
end if
        invoke  LoadIcon, 0, IDI_APPLICATION   ; stock fallback / no-icon build
.have_tray_icon:
        mov     [nid.hIcon], rax
        invoke  lstrcpynW, nid.szTip, tray_tip, 64
        invoke  Shell_NotifyIconW, NIM_ADD, nid
        ; launched with --min: start hidden (tray only). The modal dialog's own
        ; message pump keeps running while hidden, so the tray stays live.
        cmp     dword [wantMin], 0
        je      .shown
        invoke  ShowWindow, [hdlg], SW_HIDE
.shown:
        mov     eax, 1
        jmp     .done
.cmd:
        mov     rax, [wparam]
        movzx   eax, ax
        cmp     eax, IDCANCEL
        je      .close
        cmp     eax, IDB_MAXIMUM
        je      .on_max
        cmp     eax, IDB_DEFHI
        je      .on_defhi
        cmp     eax, IDB_4MS
        je      .on_4ms
        cmp     eax, IDB_DEFAULT
        je      .on_default
        cmp     eax, IDC_AUTORUN
        je      .on_autorun
        cmp     eax, IDM_SHOW
        je      .tray_show
        cmp     eax, IDM_EXIT
        je      .on_exit
        xor     eax, eax
        jmp     .done
.on_max:
        mov     ecx, RES_MAX
        call    DoSet
        jmp     .refresh_cur
.on_defhi:
        mov     ecx, RES_DEFHI
        call    DoSet
        jmp     .refresh_cur
.on_4ms:
        mov     ecx, RES_4MS
        call    DoSet
        jmp     .refresh_cur
.on_default:
        mov     ecx, RES_RELEASE
        call    DoSet
.refresh_cur:
        ; persist the just-applied value (DoSet stored it in lastDesired);
        ; RES_RELEASE (0) deletes the stored value -> --resume becomes a no-op.
        mov     ecx, [lastDesired]
        call    StoreLastValue
        call    DoQuery
        mov     ecx, [tCur]
        lea     rdx, [guiBuf]
        call    FormatRes
        invoke  SetDlgItemText, [hdlg], IDS_CURRENT, guiBuf
        mov     eax, 1
        jmp     .done
.timer:
        ; re-apply timer lock (per-process drift safeguard on Win11)
        mov     ecx, [lastDesired]
        test    ecx, ecx
        jz      .timer_query                   ; release mode - just refresh display
        call    DoSet
.timer_query:
        call    DoQuery
        mov     ecx, [tCur]
        lea     rdx, [guiBuf]
        call    FormatRes
        invoke  SetDlgItemText, [hdlg], IDS_CURRENT, guiBuf
        mov     eax, 1
        jmp     .done
.tray:
        mov     rax, [lparam]
        cmp     ax, WM_LBUTTONUP
        je      .tray_show
        cmp     ax, WM_RBUTTONUP
        jne     .done_zero
        ; right-click: popup menu Show / Exit
        invoke  CreatePopupMenu
        mov     [hCtxMenu], rax
        invoke  AppendMenuW, [hCtxMenu], MF_STRING, IDM_SHOW, menu_show
        invoke  AppendMenuW, [hCtxMenu], MF_STRING, IDM_EXIT, menu_exit
        invoke  GetCursorPos, cursorPt
        invoke  SetForegroundWindow, [hdlg]       ; required to dismiss menu on click-outside
        invoke  TrackPopupMenu, [hCtxMenu], TPM_RIGHTBUTTON, [cursorPt], [cursorPt+4], 0, [hdlg], 0
        invoke  DestroyMenu, [hCtxMenu]
        jmp     .done_zero
.tray_show:
        mov     dword [wantMin], 0             ; user wants it visible now; stop suppressing
        invoke  ShowWindow, [hdlg], SW_SHOW
        invoke  SetForegroundWindow, [hdlg]
        mov     eax, 1
        jmp     .done
.on_autorun:
        invoke  SendDlgItemMessage, [hdlg], IDC_AUTORUN, BM_GETCHECK, 0, 0
        test    eax, eax
        jz      .autorun_disable
        call    SetAutostartOn
        jmp     .done_zero
.autorun_disable:
        call    SetAutostartOff
        jmp     .done_zero
.on_exit:
        invoke  SendMessage, [hdlg], WM_DESTROY, 0, 0
        jmp     .done_zero
.destroy:
        invoke  KillTimer, [hdlg], TID_REFRESH
        invoke  Shell_NotifyIconW, NIM_DELETE, nid
        invoke  EndDialog, [hdlg], 0
        mov     eax, 1
        jmp     .done
.close:
        ; hide to tray instead of destroying
        invoke  ShowWindow, [hdlg], SW_HIDE
        mov     eax, 1
        jmp     .done
.done_zero:
        xor     eax, eax
.done:
        ret
endp

; --------------------------------------------------------------------------
; ParseFlags - tokenize our command line and set [wantMin] / [wantResume] if a
; whole argument equals "--min" / "--resume" (case-insensitive). Tokenized via
; CommandLineToArgvW, so "--min" won't match "--minimize" or a path that
; contains it. A `proc` for stack alignment; RBX/RSI/RDI preserved for the loop.
proc ParseFlags uses rbx rsi rdi
   local argcW:DWORD, pArgv:QWORD
        invoke  GetCommandLineW
        lea     rdx, [argcW]
        invoke  CommandLineToArgvW, rax, rdx
        test    rax, rax
        jz      .done
        mov     [pArgv], rax
        mov     esi, 1                          ; index, skip argv[0] (exe path)
.loop:
        cmp     esi, [argcW]
        jae     .free
        mov     rax, [pArgv]
        mov     rdi, [rax + rsi*8]              ; argv[esi]
        invoke  lstrcmpiW, rdi, flag_min
        test    eax, eax
        jnz     .not_min
        mov     dword [wantMin], 1
        jmp     .next
.not_min:
        invoke  lstrcmpiW, rdi, flag_resume
        test    eax, eax
        jnz     .next
        mov     dword [wantResume], 1
.next:
        inc     esi
        jmp     .loop
.free:
        invoke  LocalFree, [pArgv]
.done:
        ret
endp

; --------------------------------------------------------------------------

include 'autostart.inc'
include 'backend.inc'

; ---------------------------------------------------------------------------

section '.data' data readable writeable

  ; --- read-only-ish strings (any length) ---
  ntdll_name   db 'ntdll.dll', 0
  qry_name     db 'NtQueryTimerResolution', 0
  set_name     db 'NtSetTimerResolution', 0
  fmt_ms       db '%u.%04u ms', 0
  _err_title   db 'Timer Resolution', 0
  err_backend  db 'ntdll NtQuery/NtSetTimerResolution unavailable.', 0
  ; align 2: UTF-16 (du) strings MUST sit on an even address. RegCreateKeyExW
  ; faults with ERROR_NOACCESS (998) on a misaligned lpSubKey, and FASM packs
  ; data in source order with no padding - the odd-length db strings above would
  ; otherwise leave these on an odd offset.
  align 2
  menu_show    du 'Show', 0
  menu_exit    du 'Exit', 0
  run_key      du 'Software\Microsoft\Windows\CurrentVersion\Run', 0
  run_val      du 'TimerRes', 0
  app_key      du 'Software\timer-res', 0
  last_val     du 'LastValue', 0
  flag_min     du '--min', 0
  flag_resume  du '--resume', 0
  run_suffix   du '" --min --resume', 0          ; appended to the quoted exe path
  tray_tip     du 'Timer Resolution', 0

  ; --- mutable state (qwords / OUT params / buffers) ---
  ; align so qword pointers sit on their natural 8-byte boundary (HKEY/handle
  ; out-params, the ntdll fn pointers). FASM lays data out in source order with
  ; no auto-padding, so the odd-length strings above would otherwise leave these
  ; on an odd offset. 8-byte alignment is what the ABI needs; 16 is harmless.
  align 16
  hInst        dq 0
  pNtQuery     dq 0
  pNtSet       dq 0
  hNtdll       dq 0
  hRegKey      dq 0
  hCtxMenu     dq 0
  tMin         dd 0
  tMax         dd 0
  tCur         dd 0
  tActual      dd 0
  lastDesired  dd 0
  storeVal     dd 0                        ; StoreLastValue: REG_DWORD source
  loadBuf      dd 0                        ; LoadLastValue:  REG_DWORD dest
  loadLen      dd 4                        ; RegQueryValueExW lpcbData (in/out)
  regType      dd 0                        ; RegQueryValueExW lpType (out)
  wantMin      dd 0                        ; cmdline: --min seen
  wantResume   dd 0                        ; cmdline: --resume seen
  cursorPt     dd 0, 0                     ; POINT (x, y)
  align 16
  exePath      rw MAX_PATH + 20            ; +20 for quote + ' --min --resume' suffix
  align 16
  guiBuf       rb 64

  ; NOTIFYICONDATAW: use the include's struct so the layout/size are exact.
  align 16
  nid NOTIFYICONDATAW

; ---------------------------------------------------------------------------

section '.idata' import data readable writeable

  library kernel32,  'KERNEL32.DLL', \
          user32,    'USER32.DLL', \
          shell32,   'SHELL32.DLL', \
          advapi32,  'ADVAPI32.DLL'

  import kernel32, \
         GetModuleHandle,   'GetModuleHandleA', \
         GetModuleFileNameW,'GetModuleFileNameW', \
         GetProcAddress,    'GetProcAddress', \
         GetCommandLineW,   'GetCommandLineW', \
         lstrcpynW,         'lstrcpynW', \
         lstrcmpiW,         'lstrcmpiW', \
         LocalFree,         'LocalFree', \
         ExitProcess,       'ExitProcess'

  import user32, \
         DialogBoxParam,    'DialogBoxParamA', \
         EndDialog,         'EndDialog', \
         SetDlgItemText,    'SetDlgItemTextA', \
         SendDlgItemMessage,'SendDlgItemMessageW', \
         SendMessage,       'SendMessageW', \
         SetTimer,          'SetTimer', \
         KillTimer,         'KillTimer', \
         ShowWindow,        'ShowWindow', \
         SetForegroundWindow,'SetForegroundWindow', \
         LoadIcon,          'LoadIconA', \
         LoadImage,         'LoadImageW', \
         CreatePopupMenu,   'CreatePopupMenu', \
         AppendMenuW,       'AppendMenuW', \
         TrackPopupMenu,    'TrackPopupMenu', \
         DestroyMenu,       'DestroyMenu', \
         GetCursorPos,      'GetCursorPos', \
         MessageBox,        'MessageBoxA', \
         wsprintf,          'wsprintfA'

  import shell32, \
         Shell_NotifyIconW,  'Shell_NotifyIconW', \
         CommandLineToArgvW, 'CommandLineToArgvW'

  import advapi32, \
         RegOpenKeyExW,   'RegOpenKeyExW', \
         RegQueryValueExW,'RegQueryValueExW', \
         RegCreateKeyExW, 'RegCreateKeyExW', \
         RegSetValueExW,  'RegSetValueExW', \
         RegDeleteValueW, 'RegDeleteValueW', \
         RegCloseKey,     'RegCloseKey'

; ---------------------------------------------------------------------------

section '.rsrc' resource data readable

if WITH_ICON
  directory RT_DIALOG,     dialogs, \
            RT_ICON,       icons, \
            RT_GROUP_ICON, group_icons

  resource icons, \
           1, LANG_ENGLISH + SUBLANG_DEFAULT, icon_data

  resource group_icons, \
           IDI_APP, LANG_ENGLISH + SUBLANG_DEFAULT, main_icon

  icon main_icon, icon_data, 'timer-res.ico'
else
  directory RT_DIALOG, dialogs
end if

  resource dialogs, \
           IDD_MAIN, LANG_ENGLISH + SUBLANG_DEFAULT, main_dialog

  dialog main_dialog, 'Set Timer Resolution', 0, 0, 220, 130, \
         WS_CAPTION + WS_POPUP + WS_SYSMENU + WS_MINIMIZEBOX + DS_SETFONT, \
         0, 0, 'MS Shell Dlg', 8

    dialogitem 'BUTTON', 'Timer Resolution Range', -1, \
               7, 5, 206, 40, WS_VISIBLE + BS_GROUPBOX
    dialogitem 'STATIC', 'Minimum Resolution', -1, \
               14, 18, 80, 9, WS_VISIBLE
    dialogitem 'STATIC', '---', IDS_MIN, \
               100, 18, 50, 9, WS_VISIBLE
    dialogitem 'STATIC', 'Maximum Resolution', -1, \
               14, 30, 80, 9, WS_VISIBLE
    dialogitem 'STATIC', '---', IDS_MAX, \
               100, 30, 50, 9, WS_VISIBLE

    dialogitem 'BUTTON', 'Current Timer Information', -1, \
               7, 49, 206, 28, WS_VISIBLE + BS_GROUPBOX
    dialogitem 'STATIC', 'Current Resolution', -1, \
               14, 61, 80, 9, WS_VISIBLE
    dialogitem 'STATIC', '---', IDS_CURRENT, \
               100, 61, 90, 9, WS_VISIBLE

    dialogitem 'BUTTON', 'Maximum', IDB_MAXIMUM, \
               7, 84, 47, 14, WS_VISIBLE + WS_TABSTOP + BS_PUSHBUTTON
    dialogitem 'BUTTON', '1 ms', IDB_DEFHI, \
               60, 84, 47, 14, WS_VISIBLE + WS_TABSTOP + BS_PUSHBUTTON
    dialogitem 'BUTTON', '4 ms', IDB_4MS, \
               113, 84, 47, 14, WS_VISIBLE + WS_TABSTOP + BS_PUSHBUTTON
    dialogitem 'BUTTON', 'Default', IDB_DEFAULT, \
               166, 84, 47, 14, WS_VISIBLE + WS_TABSTOP + BS_PUSHBUTTON + BS_DEFPUSHBUTTON

    dialogitem 'BUTTON', 'Run at Windows startup', IDC_AUTORUN, \
               7, 108, 160, 12, WS_VISIBLE + WS_TABSTOP + BS_AUTOCHECKBOX

  enddialog
