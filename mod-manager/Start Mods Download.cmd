@echo off
title Arma Reforger Mods Download
rem Set RFMM_HOME/RFMM_DATA only while the big data still lives outside this
rem folder; migrate-here.ps1 removes these two lines after moving it in.
set RFMM_HOME=C:\Users\Administrator\Documents\ArmaReforger-DL
set RFMM_DATA=C:\Users\Administrator\Documents\Default Project
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\Documents\Default Project\arma-reforger-ai-toolkit\mod-manager\download-web.ps1"
