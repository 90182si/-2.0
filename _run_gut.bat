@echo off
cd /d "%~dp0"
"I:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path "%~dp0." --script addons/gut/gut_cmdln.gd -- -gdir=res://test/circuit -ginclude_subdirs -gexit > "%~dp0_gut_circuit.log" 2>&1
