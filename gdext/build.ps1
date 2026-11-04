# GDExtension 构建脚本（Windows / MSVC）
#
# 用法（在项目根目录或任意位置执行）：
#   pwsh -File gdext/build.ps1
#
# 依赖：
#   - Python 3（需已装 scons：python -m pip install scons）
#   - Visual Studio 2022（vcvars64.bat）
#   - godot-cpp（默认 J:/godot/godot-cpp-47，可用 -GodotCpp 覆盖）
#
# 产物：gdext/bin/windows/template_debug/sw_expr_eval.dll
#
# ⚠ 首次拉代码后**必须跑一次本脚本**：DLL 是构建产物，不入版本库（见 .gitignore）。
#   没构建时游戏不会崩 —— SWExprBuilder.attach_native() 检测不到扩展会自动回退到
#   GDScript 求值（功能一致，只是慢约 8.7 倍）。
#
# 想验证构建是否生效：在 Godot 里跑 test/circuit/test_gdext_smoke.gd，
# 日志里会打印 "ClassDB.class_exists(SWExprEval) = true"。

param(
    [string]$GodotCpp = "J:/godot/godot-cpp-47",
    [ValidateSet("template_debug", "template_release")]
    [string]$Target = "template_debug",
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
    $vs = @(
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $vs) {
        throw "未找到 vcvars64.bat（需要 Visual Studio 2022）"
    }
    Write-Host "使用 MSVC 环境: $vs"
    Write-Host "godot-cpp: $GodotCpp"
    Write-Host "target: $Target"

    $cmd = "`"$vs`" >nul 2>&1 && $Python -m SCons platform=windows target=$Target godot_cpp=$GodotCpp"
    cmd /c $cmd
    if ($LASTEXITCODE -ne 0) {
        throw "构建失败（exit $LASTEXITCODE）"
    }
    Write-Host "构建完成: $here\bin\windows\$Target\sw_expr_eval.dll"
} finally {
    Pop-Location
}
