# GDExtension 构建脚本（纯 MSVC，**不需要 Python / scons**）
#
# 为什么要有这个脚本：build.ps1 走 scons，而 scons 需要 Python。机器上可能只装了
# MSVC 没有 Python，那条路就走不通。本脚本只用 vcvars64.bat + cl.exe，
# 编译选项与宏都对齐 godot-cpp 的 tools/（target=template_debug），
# 因为要和已经编好的 libgodot-cpp.windows.template_debug.x86_64.lib 链接：
#   选项：/MT /EHsc /GR /std:c++17 /utf-8 /Zi /FS
#   宏  ：TYPED_METHOD_BIND NOMINMAX WINDOWS_ENABLED GDEXTENSION
#         THREADS_ENABLED NDEBUG DISABLE_DEPRECATED
#         (+ DEBUG_ENABLED HOT_RELOAD_ENABLED，仅 template_debug)
# 少一个宏或换一套 CRT 都可能撞 LNK2038，或者更糟：链上了但运行期行为不一致。
# ⚠ CRT 必须是 /MT：现成的 libgodot-cpp*.lib 是用 use_static_cpp=yes 编的
# （链接器报 MT_StaticRelease 不匹配），换 /MD 直接 LNK2038。
#
# 用法：
#   pwsh -File gdext/build_msvc.ps1
#   pwsh -File gdext/build_msvc.ps1 -Target template_release
#
# 产物：gdext/bin/windows/<target>/sw_expr_eval.dll

param(
    [string]$GodotCpp = "",
    [string]$VcVars = "",
    [ValidateSet("template_debug", "template_release")]
    [string]$Target = "template_debug"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- 1. 找 vcvars64.bat（VS2022 / VS2026 都可能，装的是哪个用哪个）----
if (-not $VcVars) {
    $VcVars = @(
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "I:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat",
        "I:\Program Files\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
        "C:\Program Files\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $VcVars -or -not (Test-Path $VcVars)) {
    throw "未找到 vcvars64.bat（需要 VS2022/VS2026 的 C++ 生成工具）"
}

# ---- 2. 找 godot-cpp（要同时有头文件目录和已编好的静态库）----
if (-not $GodotCpp) {
    $GodotCpp = @(
        "F:/godot/godot-cpp-47",
        "J:/godot/godot-cpp-47",
        "$(Split-Path -Parent $here)/godot-cpp-47",
        "$(Split-Path -Parent $here)/godot-cpp"
    ) | Where-Object { Test-Path (Join-Path $_ "SConstruct") } | Select-Object -First 1
}
if (-not $GodotCpp) {
    throw "未找到 godot-cpp（用 -GodotCpp 指定根目录）"
}
$GodotCpp = $GodotCpp -replace '\\', '/'

$lib = @(
    "$GodotCpp/bin/libgodot-cpp.windows.$Target.x86_64.lib",
    "$GodotCpp/build/bin/libgodot-cpp.windows.$Target.x86_64.lib"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $lib) {
    throw "未找到 libgodot-cpp.windows.$Target.x86_64.lib（先用 scons 编一次 godot-cpp）"
}

# ---- 3. 目录 ----
$objDir = Join-Path $here "build/$Target"
$outDir = Join-Path $here "bin/windows/$Target"
New-Item -ItemType Directory -Force -Path $objDir, $outDir | Out-Null
$srcDir = Join-Path $here "src"
$sources = Get-ChildItem (Join-Path $srcDir "*.cpp") | ForEach-Object { '"' + $_.FullName + '"' }

# ---- 4. 宏与选项（与 godot-cpp tools/ 对齐）----
$defs = @(
    "TYPED_METHOD_BIND", "NOMINMAX", "WINDOWS_ENABLED", "GDEXTENSION",
    "THREADS_ENABLED", "NDEBUG", "DISABLE_DEPRECATED"
)
if ($Target -eq "template_debug") {
    # DEBUG_ENABLED = 引擎调试特性代码；HOT_RELOAD_ENABLED = 生成的 .lib 里就是开着编的
    $defs += @("DEBUG_ENABLED", "HOT_RELOAD_ENABLED")
}
$defArgs = ($defs | ForEach-Object { "/D$_" }) -join " "

$cl = @(
    "cl /nologo /LD /utf-8 /MT /O2 /W3 /GR /EHsc /std:c++17 /Zi /FS",
    $defArgs,
    "/I`"$GodotCpp/include`" /I`"$GodotCpp/gen/include`" /I`"$srcDir`"",
    "/Fo`"$objDir\\`" /Fd`"$objDir/sw_expr_eval.pdb`"",
    # 先链到临时名：编辑器开着时旧的 sw_expr_eval.dll 是被锁住的（LNK1104）
    "/Fe`"$outDir/sw_expr_eval_new.dll`"",
    ($sources -join " "),
    "`"$lib`"",
    "/link /DEBUG:FULL /OPT:REF /INCREMENTAL:NO"
) -join " "

# 写成 .bat 再执行：vcvars64.bat 必须在同一个 cmd 进程里 call，路径里还有空格
$bat = Join-Path $objDir "_cl.bat"
@"
@echo off
call "$VcVars" >nul 2>&1
if errorlevel 1 (echo vcvars64 failed & exit /b 1)
cd /d "$here"
$cl
if errorlevel 1 exit /b 1
echo BUILD_OK
"@ | Set-Content -Path $bat -Encoding OEM

Write-Host "MSVC   : $VcVars"
Write-Host "godot-cpp: $GodotCpp"
Write-Host "lib    : $lib"
Write-Host "target : $Target"
Write-Host "out    : $outDir\sw_expr_eval.dll"
Write-Host ""

& cmd /c $bat
if ($LASTEXITCODE -ne 0) {
    throw "构建失败（exit $LASTEXITCODE）"
}

# 替换正式产物。正在运行的 Godot 会锁住旧 dll，这时保留 _new 并说清楚怎么办
$dll = Join-Path $outDir "sw_expr_eval.dll"
$new = Join-Path $outDir "sw_expr_eval_new.dll"
try {
    Move-Item -Force -Destination $dll -Path $new -ErrorAction Stop
    Write-Host ""
    Write-Host ("构建完成: " + (Get-Item $dll).Length + " 字节 -> " + $dll)
} catch {
    Write-Host ""
    Write-Host "已生成 sw_expr_eval_new.dll，但替换正式文件失败：旧的 sw_expr_eval.dll 正被"
    Write-Host "运行中的 Godot 占用。关掉 Godot（编辑器/游戏）后重跑本脚本即可。"
    exit 2
}
