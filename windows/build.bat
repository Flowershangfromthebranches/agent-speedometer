@echo off
chcp 65001 >nul
title AgentPulse Windows Packager

where pyinstaller >nul 2>nul
if %errorlevel% neq 0 (
    echo 正在安装 pyinstaller...
    pip install pyinstaller pystray pillow
)

echo 正在打包 AgentPulse 可执行程序 (dist\AgentPulse\AgentPulse.exe)...
pyinstaller --noconfirm --clean ^
    --onedir ^
    --windowed ^
    --name "AgentPulse" ^
    --distpath "%~dp0dist" ^
    --workpath "%~dp0build" ^
    --add-data "%~dp0agentpulse;agentpulse" ^
    "%~dp0agentpulse.py"

echo.
echo 打包完成！生成位置：%~dp0dist\AgentPulse\AgentPulse.exe
pause
