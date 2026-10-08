@echo off
title Instalar Pokimon compartido
echo Cierra Minecraft antes de continuar. Modrinth puede quedarse abierto.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Pokimon.ps1"
echo.
pause
