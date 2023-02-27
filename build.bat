@ECHO OFF
TITLE Building BSOD64...
PUSHD %~dp0

SET ACME="bin\acme\acme.exe"
SET TMPX="bin\tmpx\TMPx.exe"

REM %ACME% -v ^
REM     -l "bsod64.sym" ^
REM     --format cbm ^
REM      -Wtype-mismatch ^
REM       "bsod64.acme"

%TMPX% ^
    -i "bsod64.s" ^
    -o "bsod64.prg"

POPD