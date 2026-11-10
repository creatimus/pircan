@echo off
title PIRCAN setup
echo Starting the PIRCAN setup from https://pircan.creatimus.com ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://pircan.creatimus.com/install.ps1' | iex"
echo.
pause
