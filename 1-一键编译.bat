@echo off
chcp 936 >nul
rem One-click build: map -> interface -> pnr -> pgm
setlocal
cd /d "%~dp0"
echo ============================================================
echo   final_cam_ir  --  一键编译
echo   map -^> interface -^> pnr -^> pgm  (约 3 分钟)
echo ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
if errorlevel 1 (
    echo.
    echo [失败] 看上面的报错，或打开 build.log 搜 ERROR
) else (
    echo.
    echo [成功] 位流在：%~dp0outflow\final_cam_ir.bit
)
echo.
pause