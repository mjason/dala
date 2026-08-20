@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "DALA_ROOT=%~dp0"
set "DALA_CURRENT=%DALA_ROOT%current.txt"
set "DALA_LOG_DIR=%DALA_ROOT%logs"
set "DALA_STDOUT=%DALA_LOG_DIR%\dala.stdout.log"
set "DALA_STDERR=%DALA_LOG_DIR%\dala.stderr.log"

if not exist "%DALA_LOG_DIR%" mkdir "%DALA_LOG_DIR%"

set "DALA_VERSION=%~1"
if not defined DALA_VERSION (
  if not exist "%DALA_CURRENT%" (
    echo Dala current version file is missing: "%DALA_CURRENT%" 1>&2
    exit /b 2
  )
  set /p DALA_VERSION=<"%DALA_CURRENT%"
)

echo(%DALA_VERSION%| %SystemRoot%\System32\findstr.exe /r /x "v[0-9][0-9A-Za-z.-]*" >nul
if errorlevel 1 (
  echo Dala current version is invalid: "%DALA_VERSION%" 1>&2
  exit /b 2
)

set "DALA_RELEASE=%DALA_ROOT%versions\%DALA_VERSION%"
set "DALA_ENTRYPOINT=%DALA_RELEASE%\bin\dala.bat"
if not exist "%DALA_ENTRYPOINT%" (
  echo Dala release entrypoint is missing: "%DALA_ENTRYPOINT%" 1>&2
  exit /b 2
)

echo [%date% %time%] starting %DALA_VERSION%>>"%DALA_STDOUT%"
call "%DALA_ENTRYPOINT%" eval "Dala.Release.migrate" >>"%DALA_STDOUT%" 2>>"%DALA_STDERR%"
if errorlevel 1 exit /b %errorlevel%

call "%DALA_ENTRYPOINT%" start >>"%DALA_STDOUT%" 2>>"%DALA_STDERR%"
exit /b %errorlevel%
