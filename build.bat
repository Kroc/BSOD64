@ECHO OFF
TITLE Building BSOD64...
PUSHD %~dp0

SET ACME="bin\acme\acme.exe"

REM # VICE's c1541 tool is used to create disk images
SET C1541="bin\vice\c1541.exe"

REM # build default BSOD64 at $C000
%ACME% -v ^
    -o "build\bsod64.prg" ^
    -l "build\bsod64.sym" ^
    --format cbm ^
      "bsod64.acme"

REM # build a version for C64OS during boot
%ACME% -v ^
    -o "build\bsod64-c64os.prg" ^
    -l "build\bsod64-c64os.sym" ^
    --format cbm ^
     -DBSOD64_CODE_ADDR=$7000 ^
     -DBSOD64_DATA_ADDR=$8000 ^
     -DBSOD64_USE_BRK=0 ^
      "bsod64.acme"

REM # build a disk image:
%C1541% ^
    -format "bsod64","2a" d64 "build/bsod64.d64" ^
    -write  "build/bsod64.prg"        "bsod64" ^
    -write  "build/bsod64-c64os.prg"  "bsod64-c64os"

POPD