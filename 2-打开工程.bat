@echo off
chcp 936 >nul
rem Open the project in Efinity IDE
setlocal
set "HERE=%~dp0"
set "EFXDIR=%EFINITY_HOME%"
if not defined EFXDIR set "EFXDIR=C:\Efinity\2026.1"
if not exist "%EFXDIR%\bin\efinity.exe" (
    echo [错误] 找不到 Efinity: "%EFXDIR%\bin\efinity.exe"
    echo        请设置环境变量 EFINITY_HOME，或改本文件里的 EFXDIR
    pause
    exit /b 1
)
echo 正在打开 Efinity 工程 final_cam_ir.xml ...
call "%EFXDIR%\bin\setup.bat"
start "" "%EFXDIR%\bin\efinity.exe" --project "%HERE%final_cam_ir.xml"
endlocal