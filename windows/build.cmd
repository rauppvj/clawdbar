@echo off
setlocal

rem ClawdBar for Windows - build script.
rem Uses the C# compiler that ships with .NET Framework 4.x, present on every
rem Windows 10/11 install. No SDK, no NuGet, no internet required.

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
if not exist "%CSC%" (
    echo ERROR: could not find csc.exe under %WINDIR%\Microsoft.NET.
    echo        This machine seems to be missing the .NET Framework 4.x runtime.
    exit /b 1
)

set ROOT=%~dp0
set OUT=%ROOT%dist
if not exist "%OUT%" mkdir "%OUT%"

echo Compiling with %CSC%

"%CSC%" ^
    /nologo ^
    /target:winexe ^
    /platform:anycpu ^
    /optimize+ ^
    /codepage:65001 ^
    /warnaserror- ^
    /out:"%OUT%\ClawdBar.exe" ^
    /win32icon:"%ROOT%res\clawdbar.ico" ^
    /resource:"%ROOT%res\PressStart2P-Regular.ttf",ClawdBar.PressStart2P-Regular.ttf ^
    /resource:"%ROOT%res\clawdbar.ico",ClawdBar.clawdbar.ico ^
    "%ROOT%src\*.cs"

if errorlevel 1 (
    echo.
    echo BUILD FAILED
    exit /b 1
)

echo.
echo Built %OUT%\ClawdBar.exe
endlocal
