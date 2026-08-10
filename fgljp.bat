@echo off
SETLOCAL
set FGLJPDIR=%~dp0
set THISDRIVE=%~dd0
FOR %%i IN ("%CD%") DO (
  set MYDRIVE=%%~di
)
pushd %CD%
%THISDRIVE%
cd %FGLJPDIR%
rem compile mygetopt first as it is used b fgljp
set LANG=.fglutf8
CALL myfglcomp mygetopt
IF %errorlevel% NEQ 0 GOTO myend
CALL myfglcomp URI
IF %errorlevel% NEQ 0 GOTO myend
CALL myfglcomp fgljp
IF %errorlevel% NEQ 0 GOTO myend
popd
%MYDRIVE%
fglrun %FGLJPDIR%\fgljp.42m %*
:myend
ENDLOCAL
