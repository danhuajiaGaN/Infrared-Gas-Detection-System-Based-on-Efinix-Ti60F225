# =============================================================================
#  build.ps1  —  final_cam_ir 工程：综合 / 接口 / 布局布线 / 生成位流
#
#  用法（在本目录下）：
#    powershell -ExecutionPolicy Bypass -File .\build.ps1
#    powershell -ExecutionPolicy Bypass -File .\build.ps1 -Clean     # 全清重来
#    powershell -ExecutionPolicy Bypass -File .\build.ps1 -Only map  # 只跑某一步
#
#  流程：
#    map       综合        -> work_syn\
#    interface peri.xml 转约束 -> outflow\final_cam_ir.pt.sdc（自动拷回根目录）
#    pnr       布局布线    -> work_pnr\
#    pgm       生成位流    -> outflow\final_cam_ir.bit / .hex
#
#  约束是两个文件：
#    final_cam_ir.pt.sdc  Interface 生成，每次 interface 都会重写（脚本自动同步）
#    final_cam_ir_io.sdc  手写：额外 false path 之类
# =============================================================================

[CmdletBinding()]
param(
    [string] $ProjectXml  = 'final_cam_ir.xml',
    [string] $EfinityHome = '',
    [string] $Only        = '',
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'efinity_env.ps1')

$home_ = Find-EfinityHome -Hint $EfinityHome
Assert-Efinity $home_
Write-Host ('[Efinity] ' + $home_) -ForegroundColor Cyan

if ($Clean) {
    foreach ($d in @('work_syn','work_pnr','work_dbg','outflow')) {
        $p = Join-Path $PSScriptRoot $d
        if (Test-Path $p) {
            Write-Host ('[clean] remove ' + $d) -ForegroundColor Yellow
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$base  = [IO.Path]::GetFileNameWithoutExtension($ProjectXml)
$steps = @(
    @{ name = 'map';       args = @('--flow','map') },
    @{ name = 'interface'; args = @('--flow','interface','--pt_opts',('peri_file=' + $base + '.peri.xml')) },
    @{ name = 'pnr';       args = @('--flow','pnr') },
    @{ name = 'pgm';       args = @('--flow','pgm') }
)

$log = Join-Path $PSScriptRoot 'build.log'
foreach ($step in $steps) {
    if ($Only -and $step.name -ne $Only) { continue }

    Write-Host ('[flow] ' + $step.name) -ForegroundColor Cyan
    $code = Invoke-EfxRun -EfinityHome $home_ -ProjectDir $PSScriptRoot `
                          -ProjectXml $ProjectXml -EfxArgs $step.args -LogFile $log

    if ($code -ne 0) {
        Write-Host ''
        Write-Host ('[FAIL] ' + $step.name + ' exit ' + $code + ' -- see ERROR lines in build.log') -ForegroundColor Red
        Select-String -Path $log -Pattern 'ERROR|error:' -ErrorAction SilentlyContinue |
            Select-Object -First 15 | ForEach-Object { Write-Host ('  ' + $_.Line) -ForegroundColor Red }
        exit $code
    }

    if ($step.name -eq 'interface') {
        $gen = Join-Path $PSScriptRoot ('outflow\' + $base + '.pt.sdc')
        $dst = Join-Path $PSScriptRoot ($base + '.sdc')
        if (Test-Path $gen) {
            for ($i = 0; $i -lt 5; $i++) {
                try { Copy-Item $gen $dst -Force -ErrorAction Stop; break }
                catch {
                    if ($i -eq 4) { throw }
                    Start-Sleep -Milliseconds 800
                }
            }
            Write-Host ('[sdc] ' + $base + '.sdc refreshed from interface output') -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
Show-Bitstream -ProjectDir $PSScriptRoot
Write-Host '[done]' -ForegroundColor Green
