@ECHO OFF
TITLE Building BSOD64...
PUSHD %~dp0

SET ACME="bin\acme\acme.exe"

%ACME% -v ^
    -l "bsod64.sym" ^
    --format cbm ^
     -Wtype-mismatch ^
      "bsod64.acme"

POPD