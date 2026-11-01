@echo off
chcp 936 >nul
rem Open Efinity Programmer (JTAG / SPI flash)
setlocal
set "EFXDIR=%EFINITY_HOME%"
if not defined EFXDIR set "EFXDIR=C:\Efinity\2026.1"
if not exist "%EFXDIR%\bin\efinity_pgm.bat" (
    echo [错误] 找不到 Efinity 烧录器: "%EFXDIR%\bin\efinity_pgm.bat"
    echo        请设置环境变量 EFINITY_HOME，或改本文件里的 EFXDIR
    pause
    exit /b 1
)
echo ============================================================
echo   要烧的位流：
echo     %~dp0outflow\final_cam_ir.bit     ^(JTAG 下载, 掉电即丢^)
echo     %~dp0outflow\final_cam_ir.hex     ^(SPI Flash, 地址 0x000000, 掉电保留^)
echo.
echo   烧录器里操作：
echo     1^) Programmer Mode 选 JTAG 还是 SPI Active
echo     2^) Image 点右边 ... 选上面那个文件
echo     3^) 点 Start
echo ============================================================
echo.
start "" "%EFXDIR%\bin\efinity_pgm.bat"
endlocal