@echo off
chcp 936 >nul
rem Build then open programmer
setlocal
cd /d "%~dp0"
echo ============================================================
echo   final_cam_ir  --  一键到底（先编译，再开烧录器）
echo ============================================================
call "%~dp01-一键编译.bat" -nopause
if errorlevel 1 goto :fail
if not exist "%~dp0outflow\final_cam_ir.bit" goto :fail
echo.
echo 编译完成，正在打开烧录器 ...
start "" "%~dp03-烧录器.bat"
goto :eof
:fail
echo.
echo [中止] 编译没成功，没打开烧录器。
pause