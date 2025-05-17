@echo off
if not exist build mkdir build
cd build
if "%1"=="release" odin run ../src -out:Darko.exe
if "%1"=="debug" odin run ../src -debug -out:Darko.exe
cd ..