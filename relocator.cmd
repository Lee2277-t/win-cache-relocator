@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem 直接传所有参数给 PowerShell 脚本，并绕过执行策略
rem 用法: relocator.cmd scan
rem       relocator.cmd move -Name Kingsoft -Target D:\Moved

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0relocator.ps1" %*
set EXITCODE=%ERRORLEVEL%

if "%~1"=="" (
    echo.
    echo 提示：直接双击只会显示帮助。要在命令行里带参数使用，例如：
    echo     relocator.cmd scan
)
exit /b %EXITCODE%
