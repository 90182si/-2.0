@echo off
cd /d "%~dp0"
"I:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path "%~dp0." --script addons/gut/gut_cmdln.gd -- -gtest=res://test/circuit/ir_parity_test.gd -gexit > "%~dp0_gut_irpar.log" 2>&1
