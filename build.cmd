@echo off
rem build.cmd - assemble timer-res.exe, timer-res-noicon.exe, timer-res-cli.exe.
rem
rem Finds FASM in this order:
rem   1) %FASM_DIR%\FASM.EXE   (set this to point at your FASM install)
rem   2) .\fasm\FASM.EXE       (drop the FASM distro in a 'fasm' subfolder)
rem   3) ..\tools\fasm, ..\..\tools\fasm  (local dev fallbacks)
rem Download FASM 1.73.35 from https://flatassembler.net/download.php
setlocal
set "ROOT=%~dp0"
set "FASM="
if defined FASM_DIR if exist "%FASM_DIR%\FASM.EXE" set "FASM=%FASM_DIR%"
if not defined FASM if exist "%ROOT%fasm\FASM.EXE"             set "FASM=%ROOT%fasm"
if not defined FASM if exist "%ROOT%..\tools\fasm\FASM.EXE"    set "FASM=%ROOT%..\tools\fasm"
if not defined FASM if exist "%ROOT%..\..\tools\fasm\FASM.EXE" set "FASM=%ROOT%..\..\tools\fasm"
if not defined FASM (
  echo [build] FASM.EXE not found. Set FASM_DIR, or drop the FASM distro in a
  echo         'fasm' subfolder. Get fasmw17335.zip from flatassembler.net.
  exit /b 1
)
set "INCLUDE=%FASM%\INCLUDE"

echo [build] timer-res.exe ^(with icon^)
"%FASM%\FASM.EXE" -d WITH_ICON=1 "%ROOT%timer-res.asm" "%ROOT%timer-res.exe"
if errorlevel 1 exit /b %errorlevel%

echo [build] timer-res-noicon.exe ^(no icon, smaller^)
"%FASM%\FASM.EXE" -d WITH_ICON=0 "%ROOT%timer-res.asm" "%ROOT%timer-res-noicon.exe"
if errorlevel 1 exit /b %errorlevel%

echo [build] timer-res-test-tool.exe
"%FASM%\FASM.EXE" "%ROOT%timer-res-test-tool.asm" "%ROOT%timer-res-test-tool.exe"
if errorlevel 1 exit /b %errorlevel%

for %%I in ("%ROOT%timer-res.exe")           do echo [build] OK: timer-res.exe           %%~zI bytes
for %%I in ("%ROOT%timer-res-noicon.exe")    do echo [build] OK: timer-res-noicon.exe    %%~zI bytes
for %%I in ("%ROOT%timer-res-test-tool.exe") do echo [build] OK: timer-res-test-tool.exe %%~zI bytes
endlocal
