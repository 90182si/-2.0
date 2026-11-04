# Godot 测试运行器（带超时，卡住自动杀进程）
# 用法：
#   .\_run_test.ps1 -Headless -Log "j:\godot\无限地图\_gut_parity.log" -TimeoutSec 240
#   .\_run_test.ps1 -NoHeadless -Log "j:\godot\无限地图\_gut_real_gpu.log" -TimeoutSec 240
#   .\_run_test.ps1 -NoHeadless -Script "res://_probe_engine.gd" -Log "j:\godot\无限地图\_probe_engine.log" -TimeoutSec 90
param(
    [string]$Godot = "K:\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe",
    [string]$Path = "j:\godot\无限地图",
    [string]$Script = "addons/gut/gut_cmdln.gd",
    [string]$Log = "j:\godot\无限地图\_gut_parity.log",
    [int]$TimeoutSec = 240,
    [switch]$Headless,
    [switch]$NoHeadless
)
$ErrorActionPreference = "Stop"
# 兜底：同时接受 -Headless/-NoHeadless；默认 headless
$useHeadless = -not $NoHeadless

Get-Process | Where-Object { $_.Name -like "Godot*" } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Remove-Item -LiteralPath $Log -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$Log.err" -Force -ErrorAction SilentlyContinue

$argsList = @()
if ($useHeadless) { $argsList += "--headless" }
$argsList += @("--path", $Path, "-s", $Script, "-gdir=res://test", "-gexit")

$proc = Start-Process -FilePath $Godot -ArgumentList $argsList -PassThru `
    -RedirectStandardOutput $Log -RedirectStandardError "$Log.err" -WindowStyle Hidden

if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    # 卡住：杀掉进程树并报超时
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Get-Process | Where-Object { $_.Name -like "Godot*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "TIMEOUT_AFTER_${TimeoutSec}s_KILLED"
    exit 124
}
Write-Host "GODOT_EXIT=$($proc.ExitCode)"
exit $proc.ExitCode
