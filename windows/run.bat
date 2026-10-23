@echo off
chcp 65001 >nul
title AgentPulse Windows Launcher

where python >nul 2>nul
if %errorlevel% neq 0 (
    where py >nul 2>nul
    if %errorlevel% neq 0 (
        echo [错误] 未在系统 PATH 中找到 Python 3。
        echo 请访问 https://www.python.org/downloads/ 下载并安装 Python，并勾选 "Add Python to PATH"。
        pause
        exit /b 1
    ) else (
        set PY_CMD=py
    )
) else (
    set PY_CMD=python
)

echo 正在启动 AgentPulse...
start "" %PY_CMD% "%~dp0agentpulse.py" %*
