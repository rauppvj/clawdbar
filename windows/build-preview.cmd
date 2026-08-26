@echo off
setlocal enabledelayedexpansion

rem Builds the developer preview harness (tools\Preview.cs) against the same
rem sources as the app, minus src\Program.cs so there is only one entry point.

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe

set ROOT=%~dp0
set OUT=%ROOT%dist
if not exist "%OUT%" mkdir "%OUT%"

set SOURCES=
for %%F in ("%ROOT%src\*.cs") do (
    if /I not "%%~nxF"=="Program.cs" set SOURCES=!SOURCES! "%%F"
)

"%CSC%" ^
    /nologo /target:winexe /platform:anycpu /codepage:65001 ^
    /out:"%OUT%\Preview.exe" ^
    /resource:"%ROOT%res\PressStart2P-Regular.ttf",ClawdBar.PressStart2P-Regular.ttf ^
    /resource:"%ROOT%res\clawdbar.ico",ClawdBar.clawdbar.ico ^
    "%ROOT%tools\Preview.cs" !SOURCES!

if errorlevel 1 (
    echo PREVIEW BUILD FAILED
    exit /b 1
)
echo Built %OUT%\Preview.exe
endlocal
