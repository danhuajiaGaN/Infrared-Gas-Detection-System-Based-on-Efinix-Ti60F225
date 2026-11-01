# =============================================================================
#  efinity_env.ps1  —  Efinity 命令行环境（共用函数，被其它脚本 dot-source 引用）
#
#  作用：
#    1) 自动定位 Efinity 安装目录（含 bin\efx_run.bat）
#    2) 封装一次 efx_run.bat 调用（自动先执行 bin\setup.bat 设置 PATH）
#
#  查找顺序：
#    -Hint 参数  >  环境变量 EFINITY_HOME  >  C:\Efinity / D:\Efinity 等常见目录
# =============================================================================

function Find-EfinityHome {
    param([string]$Hint)

    $candidates = @()
    if ($Hint)            { $candidates += $Hint }
    if ($env:EFINITY_HOME){ $candidates += $env:EFINITY_HOME }
    # 当前进程环境可能是旧的（刚配完变量、未重开终端），再读注册表里的 User / Machine 值
    $u = [Environment]::GetEnvironmentVariable('EFINITY_HOME','User')
    if ($u) { $candidates += $u }
    $m = [Environment]::GetEnvironmentVariable('EFINITY_HOME','Machine')
    if ($m) { $candidates += $m }

    # 用户 PATH 里如果已经有 <home>\bin，反推 home
    $up = [Environment]::GetEnvironmentVariable('Path','User')
    if ($up) {
        ($up -split ';') | Where-Object { $_ -match 'efin' } | ForEach-Object {
            $candidates += (Split-Path $_ -Parent)
        }
    }

    $roots = @('C:\Efinity','D:\Efinity','E:\Efinity',
               'C:\Program Files\Efinity','D:\Program Files\Efinity',
               'C:\Program Files (x86)\Efinity')
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $candidates += $root
            # 常见布局：<root>\<版本号>\bin\efx_run.bat
            Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { $candidates += $_.FullName }
        }
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (Test-Path (Join-Path $c 'bin\efx_run.bat')) { return (Resolve-Path $c).Path }
    }

    # 兜底：扫描各盘根目录下一层，找名字含 efin/fpga 且带 bin\efx_run.bat 的目录
    #（应对自定义安装路径，例如 "D:\Efinity IDE"）
    foreach ($drv in (Get-PSDrive -PSProvider FileSystem).Root) {
        Get-ChildItem $drv -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'efin|fpga' } |
            ForEach-Object {
                if (Test-Path (Join-Path $_.FullName 'bin\efx_run.bat')) { $candidates += $_.FullName }
            }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'bin\efx_run.bat'))) { return (Resolve-Path $c).Path }
    }
    return $null
}

function Assert-Efinity {
    param([string]$EfinityHome)
    if (-not $EfinityHome) {
        Write-Host ''
        Write-Host '[错误] 没有找到 Efinity 安装目录（需要包含 bin\efx_run.bat）。' -ForegroundColor Red
        Write-Host '       请用 -EfinityHome "D:\Efinity\2025.2" 指定，或设置环境变量 EFINITY_HOME。' -ForegroundColor Yellow
        Write-Host '       例：$env:EFINITY_HOME = "D:\Efinity\2025.2"' -ForegroundColor Gray
        exit 2
    }
}

# 执行：生成一个临时 .bat，内容为
#     call "<home>\bin\setup.bat"
#     call efx_run.bat <xml> <args...>
#     exit /b %ERRORLEVEL%
# 说明：setup.bat 负责把 Efinity 的 bin 目录写进本次 cmd 会话的 PATH，
#       必须与 efx_run 在同一条 cmd 会话里执行；用临时 bat 也避开了多层引号转义问题。
function Invoke-EfxRun {
    param(
        [Parameter(Mandatory)] [string]   $EfinityHome,
        [Parameter(Mandatory)] [string]   $ProjectDir,
        [Parameter(Mandatory)] [string]   $ProjectXml,
        [string[]] $EfxArgs = @(),
        [string]   $LogFile = ''
    )

    $setup = Join-Path $EfinityHome 'bin\setup.bat'
    $bat   = Join-Path $ProjectDir ('_efx_run_' + $PID + '.bat')
    $lines = @(
        '@echo off',
        ('call "' + $setup + '"'),
        ('call efx_run.bat "' + $ProjectXml + '" ' + ($EfxArgs -join ' ')),
        'exit /b %ERRORLEVEL%'
    )
    [System.IO.File]::WriteAllText($bat, ($lines -join "`r`n") + "`r`n", [System.Text.Encoding]::Default)

    Push-Location $ProjectDir
    # efx_run 会把 Python / 工具的报错写到 stderr；若总开关是 Stop，PowerShell 会
    # 直接抛 NativeCommandError 并跳过下面的日志保存，所以这里临时放宽。
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Write-Host ('> efx_run.bat ' + $ProjectXml + ' ' + ($EfxArgs -join ' ')) -ForegroundColor DarkGray
        $output = & cmd.exe /d /c $bat 2>&1
        $code   = $LASTEXITCODE
        if ($LogFile) {
            $output | Out-File -FilePath $LogFile -Encoding utf8
            $output | ForEach-Object { Write-Host $_ }
            Write-Host ('[日志已保存] ' + $LogFile) -ForegroundColor DarkGray
        } else {
            $output | ForEach-Object { Write-Host $_ }
        }
        return $code
    }
    finally {
        $ErrorActionPreference = $eap
        Pop-Location
        Remove-Item $bat -Force -ErrorAction SilentlyContinue
    }
}

# 打印最近生成的 bit 文件（Efinity 默认放在工程目录的 outflow\ 下）
function Show-Bitstream {
    param([string]$ProjectDir)
    $out = Join-Path $ProjectDir 'outflow'
    if (-not (Test-Path $out)) {
        Write-Host '[提示] 未找到 outflow 目录，说明还没有生成 bitstream。' -ForegroundColor Yellow
        return
    }
    $bits = Get-ChildItem $out -Filter *.bit -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    if (-not $bits) {
        Write-Host '[提示] outflow 里没有 .bit 文件。' -ForegroundColor Yellow
        return
    }
    foreach ($b in $bits) {
        Write-Host ('[bitstream] ' + $b.Name + '  ' + [math]::Round($b.Length/1KB,1) + ' KB  ' + $b.LastWriteTime) -ForegroundColor Green
    }
}
