@echo off
title Arma Reforger Mods Download
echo Starting the Mod Manager... a browser window will open at http://localhost:8123/
echo Keep this window open while it runs. Close it when you are done.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0download-web.ps1'"
echo.
echo The Mod Manager has stopped.
pause
