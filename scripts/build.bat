@echo off
REM Wrapper script to run build-and-deploy.ps1
REM This is called by the WMI trigger command
powershell -ExecutionPolicy Bypass -File C:\A\Scripts\build-and-deploy.ps1
