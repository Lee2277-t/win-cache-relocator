@echo off
chcp 65001 >nul
setlocal EnableExtensions
cd /d "%~dp0"

set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0relocator.ps1""

if "%~1"=="" goto MENU
%PS% %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo [退出码 %RC%] 有步骤没有成功，上面的提示里写了该怎么处理。
)
exit /b %RC%

:MENU
:TOP
cls
echo.
echo   win-cache-relocator
echo   把 C 盘上会一直长回来的缓存搬到其他盘
echo   ------------------------------------------------
echo.
echo    1  看看哪些目录占地方（只读，不改任何东西）
echo    2  查某个目录被谁占着
echo    3  把某个目录搬到 D 盘（会先预演，再问你）
echo    4  看已经搬过哪些
echo    5  撤销某次搬移
echo    6  体检：断链、丢失、未完成的搬移
echo    7  设置工具链缓存环境变量
echo    0  退出
echo.
set "CHOICE="
set /p "CHOICE=   输入编号后回车: "
if "%CHOICE%"=="1" goto SCAN
if "%CHOICE%"=="2" goto LOCKS
if "%CHOICE%"=="3" goto MOVE
if "%CHOICE%"=="4" goto LIST
if "%CHOICE%"=="5" goto UNDO
if "%CHOICE%"=="6" goto DOCTOR
if "%CHOICE%"=="7" goto ENV
if "%CHOICE%"=="0" exit /b 0
goto TOP

:SCAN
cls
%PS% scan
echo.
pause
goto TOP

:LOCKS
cls
set "DIR="
set /p "DIR=   目录路径: "
if "%DIR%"=="" goto TOP
%PS% locks -Source "%DIR%"
echo.
pause
goto TOP

:MOVE
cls
%PS% scan
echo.
set "DIR="
set /p "DIR=   要搬的目录完整路径（回车返回）: "
if "%DIR%"=="" goto TOP
set "DEST="
set /p "DEST=   搬到哪个根目录（直接回车用 D:\Moved）: "
if "%DEST%"=="" set "DEST=D:\Moved"
echo.
echo   先预演一遍，不会动任何文件：
%PS% move -Source "%DIR%" -Target "%DEST%" -DryRun
echo.
set "GO="
set /p "GO=   预演没问题就输入 y 开始正式搬移: "
if /i not "%GO%"=="y" goto TOP
%PS% move -Source "%DIR%" -Target "%DEST%" -Yes
echo.
pause
goto TOP

:LIST
cls
%PS% list
echo.
pause
goto TOP

:UNDO
cls
%PS% list
echo.
set "N="
set /p "N=   要撤销哪一项（填名字，回车返回）: "
if "%N%"=="" goto TOP
%PS% undo -Name "%N%"
echo.
pause
goto TOP

:DOCTOR
cls
%PS% doctor
echo.
pause
goto TOP

:ENV
cls
set "E="
set /p "E=   缓存根目录（直接回车用 D:\Toolchains）: "
if "%E%"=="" set "E=D:\Toolchains"
echo.
%PS% env -Target "%E%" -DryRun
echo.
set "GO="
set /p "GO=   确认修改环境变量就输入 y: "
if /i not "%GO%"=="y" goto TOP
%PS% env -Target "%E%"
echo.
pause
goto TOP
