@echo off
title Tofu WoW
rem Windows players: double-click this to update Tofu Worldview and start WoW. Mac players use "Tofu WoW (Mac).command" instead.
cd /d "%~dp0"
if not exist "%~dp0Tofu\tofu-patcher.ps1" (
  echo The Tofu folder is missing. Unzip the whole client again, or ask Chris.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Tofu\tofu-patcher.ps1" -Launch
if errorlevel 1 pause
