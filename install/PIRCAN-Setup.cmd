@echo off
title PIRCAN setup
echo Starting the PIRCAN setup from https://raw.githubusercontent.com/creatimus/pircan/main/install.ps1 ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/creatimus/pircan/main/install.ps1' | iex"
echo.
pause
