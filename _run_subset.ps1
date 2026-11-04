# 只跑指定的一组用例（禁止全量）：逐个 -gprefix 串行跑，每次单独写日志
param([string]$Prefixes)
$godot = "K:\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe"
$path = $PSScriptRoot
# 从 -File 传进来的数组会被当成一个字符串，用空格分隔再拆
foreach ($p in $Prefixes.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)) {
    $log = Join-Path $path "_r_$p.log"
    & $godot --headless --path $path -s addons/gut/gut_cmdln.gd "-gdir=res://test/circuit" "-gprefix=$p" -gexit 2>&1 |
        Out-File -Encoding utf8 $log
    Write-Host "=== $p ==="
    Get-Content $log -Encoding utf8 |
        Select-String -Pattern 'Tests |Passing|Failing|Asserts |\[Failed\]|SCRIPT ERROR|Parse Error|TIMEOUT'
}
