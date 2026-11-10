# WWMI-DX12 백업/복원 스크립트
#   (인자 없음) : 상태를 보여주고 1/2/3/4/5 키로 선택 (3 = 명조 경로 변경, 4 = ReShade 설정·셰이더 포함 여부 전환, 5 = zip으로 업데이트)
#   Off    : Win64 폴더의 WWMI-DX12 파일을 백업 폴더로 옮김 (삭제하지 않음)
#   On     : 백업 폴더의 파일을 Win64 폴더로 되돌림
#   Status : 현재 상태만 표시
# 경로에 [ ] 가 있어도 안전하도록 .NET 경로 함수와 -LiteralPath 를 사용합니다.

param(
    [ValidateSet("Menu", "Off", "On", "Status")]
    [string]$Mode = "Menu"
)

# ===== 설정 =====
# 명조 경로와 ReShade 설정·셰이더 포함 여부는 wwmi_dx12_toggle.cfg 에 저장됩니다.
# 처음 실행할 때 경로를 자동 탐색/입력받고, 메뉴의 [3] 경로 변경 / [4] ReShade 설정·셰이더 포함 전환으로 언제든 바꿀 수 있어요.
# (cfg 파일을 지우면 경로를 다시 묻고 ReShade 설정·셰이더 포함 여부는 아래 기본값으로 돌아갑니다.)
# 백업 저장소 (기본: 이 스크립트가 있는 폴더 아래 backup)
$Backup = [IO.Path]::Combine($PSScriptRoot, "backup")
# dxgi.dll 은 WWMI-DX12 가 ReShade 를 불러오는 데 쓰는 파일이라 항상 WWMI-DX12 와 함께 옮깁니다.
#   (DX11 XXMI 런처는 dxgi.dll 없이 자체 경로의 ReShade 를 주입하므로, 남겨 두면 이중 로드될 수 있음)
$AlwaysNames = @("dxgi.dll")
# ReShade 설정·셰이더 파일도 같이 옮길지 여부 (기본값 -- 메뉴 [4] 로 바꾸면 cfg 에 저장되어 그 값이 우선합니다)
#   $true  : ReShade.ini, ReShadePreset.ini, ReShade.log, reshade-shaders 를 함께 옮김 (있는 것만)
#   $false : 이 파일들은 Win64에 그대로 둠 (DX11 쪽 ReShade 가 Win64의 ReShade.ini 를 읽는 경우 등)
$IncludeReShadeDefault = $true
$ReShadeNames = @("ReShade.ini", "ReShadePreset.ini", "ReShade.log", "reshade-shaders")
# ================

$ErrorActionPreference = "Stop"
$proc = "Client-Win64-Shipping"
$addonPathDir = [IO.Path]::Combine($Backup, "_addonpath")
$addonPathNote = [IO.Path]::Combine($Backup, "_addonpath.txt")
$cfgFile = [IO.Path]::Combine($PSScriptRoot, "wwmi_dx12_toggle.cfg")

function Wait-Key {
    Write-Host ""
    Write-Host "아무 키나 누르면 닫힙니다."
    try { [void][Console]::ReadKey($true) } catch { Start-Sleep -Seconds 10 }
}
# 콘솔 창을 키움 (기본 콘솔 창에서만 적용됨. Windows Terminal 은 창 크기를 프로그램이 바꿀 수 없어서 무시됨)
function Set-ConsoleSize([int]$cols, [int]$rows) {
    try {
        $raw = $Host.UI.RawUI
        $max = $raw.MaxPhysicalWindowSize
        $w = [Math]::Min($cols, $max.Width)
        $h = [Math]::Min($rows, $max.Height)
        if ($raw.WindowSize.Width -ge $w -and $raw.WindowSize.Height -ge $h) { return }
        $bw = [Math]::Max($raw.BufferSize.Width, $w)
        $bh = [Math]::Max($raw.BufferSize.Height, 3000)
        $raw.BufferSize = New-Object Management.Automation.Host.Size($bw, $bh)
        $raw.WindowSize = New-Object Management.Automation.Host.Size($w, $h)
    } catch {}
}
function Wait-Menu {
    Write-Host ""
    Write-Host "아무 키나 누르면 메뉴로 돌아갑니다."
    try { [void][Console]::ReadKey($true) } catch { Start-Sleep -Seconds 3 }
}
function Fail([string]$msg) {
    Write-Host ""
    Write-Host $msg -ForegroundColor Red
    Wait-Key
    exit 1
}
trap {
    Write-Host ""
    Write-Host "오류로 중단했습니다: $_" -ForegroundColor Red
    Wait-Key
    exit 2
}

# ===== 명조 경로 찾기 =====
# 입력한 폴더(Win64 / Wuthering Waves / Wuthering Waves Game 등)에서 Win64 폴더를 찾아 돌려줌. 못 찾으면 빈 문자열.
function Resolve-Win64([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $t = $text.Trim().Trim('"').Trim("'").Trim()
    if (-not $t) { return "" }
    try { $t = [IO.Path]::GetFullPath($t) } catch { return "" }
    if ([IO.File]::Exists($t)) { $t = [IO.Path]::GetDirectoryName($t) }   # exe 파일 경로를 붙여넣은 경우
    $cands = @(
        $t,
        [IO.Path]::Combine($t, "Client", "Binaries", "Win64"),
        [IO.Path]::Combine($t, "Wuthering Waves Game", "Client", "Binaries", "Win64"),
        [IO.Path]::Combine($t, "Binaries", "Win64"),
        [IO.Path]::Combine($t, "Win64")
    )
    foreach ($c in $cands) {
        if ([IO.File]::Exists([IO.Path]::Combine($c, "$proc.exe"))) {
            if ($c.Length -gt 3) { return $c.TrimEnd('\') }
            return $c
        }
    }
    return ""
}

# Steam 라이브러리와 흔한 설치 위치에서 명조 Win64 폴더를 자동 탐색
function Find-Win64Auto {
    $libs = New-Object System.Collections.ArrayList
    try {
        $sp = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath
        if ($sp) {
            $sp = $sp -replace '/', '\'
            [void]$libs.Add($sp)
            $vdf = [IO.Path]::Combine($sp, "steamapps", "libraryfolders.vdf")
            if ([IO.File]::Exists($vdf)) {
                foreach ($line in [IO.File]::ReadAllLines($vdf)) {
                    if ($line -match '"path"\s+"([^"]+)"') { [void]$libs.Add(($Matches[1] -replace '\\\\', '\')) }
                }
            }
        }
    } catch {}
    $roots = New-Object System.Collections.ArrayList
    foreach ($l in $libs) { [void]$roots.Add([IO.Path]::Combine($l, "steamapps", "common", "Wuthering Waves")) }
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne 'Fixed') { continue }
        [void]$roots.Add([IO.Path]::Combine($d.Name, "Wuthering Waves"))
        [void]$roots.Add([IO.Path]::Combine($d.Name, "Games", "Wuthering Waves"))
        [void]$roots.Add([IO.Path]::Combine($d.Name, "Program Files", "Wuthering Waves"))
        [void]$roots.Add([IO.Path]::Combine($d.Name, "SteamLibrary", "steamapps", "common", "Wuthering Waves"))
    }
    $found = New-Object System.Collections.ArrayList
    foreach ($r in $roots) {
        $w = Resolve-Win64 $r
        if ($w -and -not ($found -contains $w)) { [void]$found.Add($w) }
    }
    return @($found)
}

# 명조 Win64 폴더를 고르게 함. 취소하면 빈 문자열.
#   자동 탐색한 경로를 1, 2, 3 ... 으로 보여주고, 마지막 번호는 "직접 입력", 0 은 취소.
#   $current : 현재 설정된 경로 (목록에서 "(현재)" 로 표시, 없으면 빈 문자열)
function Select-Win64([string]$current) {
    $found = @(Find-Win64Auto)
    $manual = $found.Count + 1
    while ($true) {
        Write-Host "WWMI-DX12 가 설치된 명조 경로를 선택해 주세요." -ForegroundColor Cyan
        for ($i = 0; $i -lt $found.Count; $i++) {
            $mark = ""
            if ($current -and ($found[$i] -ieq $current)) { $mark = "  (현재)" }
            Write-Host "  [$($i + 1)] $($found[$i])$mark"
        }
        Write-Host "  [$manual] 직접 입력"
        Write-Host "  [0] 취소"
        $in = "$(Read-Host '번호')".Trim()
        if ($in -eq "0") { return "" }
        if ($in -match '^\d+$') {
            $n = [int]$in
            if ($n -ge 1 -and $n -le $found.Count) { return $found[$n - 1] }
            if ($n -eq $manual) {
                Write-Host ""
                Write-Host "  탐색기 주소창에서 복사한 경로를 붙여넣고 Enter 를 누르세요."
                Write-Host "  (Wuthering Waves 폴더, Wuthering Waves Game 폴더, Win64 폴더 어느 쪽이든 괜찮아요)"
                Write-Host "  (빈 입력 = 목록으로 돌아가기)"
                while ($true) {
                    $p = "$(Read-Host '경로')".Trim()
                    if (-not $p) { break }
                    $r = Resolve-Win64 $p
                    if ($r) { return $r }
                    Write-Host "  이 경로에서 Win64 폴더($proc.exe)를 찾지 못했어요. 다시 입력해 주세요." -ForegroundColor Yellow
                }
                Write-Host ""
                continue
            }
        }
        Write-Host "  목록에 있는 번호를 입력해 주세요." -ForegroundColor Yellow
        Write-Host ""
    }
}

# cfg 형식:  Win64=<경로>  /  IncludeReShade=1 또는 0   (예전의 경로 한 줄짜리 cfg 도 읽을 수 있음)
function Save-Cfg {
    $flag = 0
    if ($IncludeReShade) { $flag = 1 }
    $text = "Win64=$Win64`r`nIncludeReShade=$flag`r`n"
    [IO.File]::WriteAllText($cfgFile, $text, (New-Object Text.UTF8Encoding($false)))
}
function Load-Cfg {
    $r = @{ Win64 = ""; IncludeReShade = $null }
    if (-not [IO.File]::Exists($cfgFile)) { return $r }
    foreach ($line in [IO.File]::ReadAllLines($cfgFile)) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^Win64\s*=(.*)$') { $r.Win64 = $Matches[1].Trim() }
        elseif ($t -match '^IncludeReShade\s*=\s*(\S+)$') { $r.IncludeReShade = ($Matches[1] -match '^(1|true|yes|on)$') }
        elseif (-not $r.Win64 -and $t -notmatch '^\w+\s*=') { $r.Win64 = $t }
    }
    return $r
}

# 백업 폴더에 WWMI-DX12 / dxgi.dll / ReShade 항목이 하나라도 있는지 (Off 상태 여부)
function Test-BackupHasItems {
    if (-not [IO.Directory]::Exists($Backup)) { return $false }
    foreach ($e in (Get-ChildItem -LiteralPath $Backup -Force)) {
        if (($e.Name -like "wwmi_dx12*" -and $e.Name -notlike "wwmi_dx12_toggle*") -or ($AlwaysNames -contains $e.Name) -or ($ReShadeNames -contains $e.Name)) { return $true }
    }
    return $false
}

# Win64 폴더 안에서 옮길 대상 이름 목록 (이 도구 자신의 파일 wwmi_dx12_toggle* 는 제외)
function Get-TargetNames([string]$folder) {
    if (-not [IO.Directory]::Exists($folder)) { return @() }
    $names = @(Get-ChildItem -LiteralPath $folder -Force |
        Where-Object { $_.Name -like "wwmi_dx12*" -and $_.Name -notlike "wwmi_dx12_toggle*" } |
        ForEach-Object { $_.Name })
    foreach ($a in $AlwaysNames) {
        if ([IO.File]::Exists([IO.Path]::Combine($folder, $a))) { $names += $a }
    }
    if ($IncludeReShade) {
        foreach ($r in $ReShadeNames) {
            $rp = [IO.Path]::Combine($folder, $r)
            if ([IO.File]::Exists($rp) -or [IO.Directory]::Exists($rp)) { $names += $r }
        }
    }
    return $names
}

# ReShade.ini 의 [ADDON] AddonPath (없으면 빈 문자열)
function Get-AddonPath {
    $file = [IO.Path]::Combine($Win64, "ReShade.ini")
    if (-not [IO.File]::Exists($file)) { return "" }
    $inAddon = $false
    foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t.StartsWith("[")) { $inAddon = ($t -ieq "[ADDON]"); continue }
        if ($inAddon -and $t -match '^AddonPath\s*=(.*)$') {
            $p = $Matches[1].Trim()
            if (-not $p) { return "" }
            if ([IO.Path]::IsPathRooted($p)) { return $p }
            return [IO.Path]::GetFullPath([IO.Path]::Combine($Win64, $p))
        }
    }
    return ""
}

# 폴더/파일 이동. 같은 드라이브면 바로 이동하고, 다른 드라이브면 복사 -> 검증 -> 원본 삭제.
function Get-TreeSummary([string]$folder) {
    $files = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force)
    $size = 0
    foreach ($f in $files) { $size += $f.Length }
    return "$($files.Count)/$size"
}
function Move-Entry([string]$from, [string]$to) {
    $sameRoot = [IO.Path]::GetPathRoot($from) -ieq [IO.Path]::GetPathRoot($to)
    if ([IO.Directory]::Exists($from)) {
        if ($sameRoot) { [IO.Directory]::Move($from, $to); return }
        Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
        if ((Get-TreeSummary $from) -ne (Get-TreeSummary $to)) {
            throw "폴더 복사 결과가 원본과 달라 원본을 지우지 않았습니다: $from"
        }
        Remove-Item -LiteralPath $from -Recurse -Force
    }
    else { [IO.File]::Move($from, $to) }   # 파일은 드라이브가 달라도 이동 가능
}

# 이름 목록을 창 너비에 맞춰 여러 열로 나눠 출력 (이름이 중간에서 잘려 줄바꿈되지 않게 함)
function Write-NameColumns($names) {
    $list = @()
    foreach ($n in $names) { if ($n) { $list += [string]$n } }   # $null(빈 목록)이 들어와도 안전하게
    if ($list.Count -eq 0) { return }
    $maxLen = 0
    foreach ($n in $list) { if ($n.Length -gt $maxLen) { $maxLen = $n.Length } }
    $colWidth = $maxLen + 3
    $width = 100
    try { $width = $Host.UI.RawUI.WindowSize.Width } catch {}
    if ($width -lt 40) { $width = 100 }
    $cols = [Math]::Max(1, [int][Math]::Floor(($width - 6) / $colWidth))
    for ($i = 0; $i -lt $list.Count; $i += $cols) {
        $line = "   "
        $end = [Math]::Min($i + $cols, $list.Count)
        for ($j = $i; $j -lt $end; $j++) { $line += " " + $list[$j].PadRight($colWidth) }
        Write-Host $line.TrimEnd()
    }
}

function Show-Status {
    $inGame = Get-TargetNames $Win64
    $inBackup = Get-TargetNames $Backup
    Write-Host "  Win64   : $Win64"
    Write-Host "  백업    : $Backup"
    $rs = "제외"
    if ($IncludeReShade) { $rs = "포함" }
    Write-Host "  ReShade 설정·셰이더 : $rs (메뉴 [4] 로 전환)"
    Write-Host ""
    Write-Host "  Win64에 있는 항목 ($($inGame.Count))"
    Write-NameColumns $inGame
    Write-Host "  백업에 있는 항목 ($($inBackup.Count))"
    Write-NameColumns $inBackup
    if ([IO.File]::Exists($addonPathNote)) {
        Write-Host "  AddonPath 사본 백업: $([IO.File]::ReadAllText($addonPathNote).Trim())"
    }
    Write-Host ""
    if ($inGame.Count -gt 0 -and $inBackup.Count -eq 0) { Write-Host "  상태: 설치됨 (On)" -ForegroundColor Green }
    elseif ($inGame.Count -eq 0 -and $inBackup.Count -gt 0) { Write-Host "  상태: 백업됨 (Off)" -ForegroundColor Yellow }
    elseif ($inGame.Count -eq 0) { Write-Host "  상태: 양쪽 모두 없음" -ForegroundColor DarkGray }
    else { Write-Host "  상태: 양쪽에 모두 있음 -- [2] On 으로 버전을 비교해 정리할 수 있어요" -ForegroundColor Red }
}

# ===== 복원 시 Win64 와 백업에 같은 이름이 모두 있는 경우 =====
# 반환: "merge" (합치기) / "backup" (백업본으로 복원) / "cancel"
function Resolve-RestoreConflict($clash) {
    Write-Host "  Win64 와 백업에 같은 이름의 파일이 모두 있어요:" -ForegroundColor Yellow
    Write-NameColumns $clash
    $winAddon = [IO.Path]::Combine($Win64, "wwmi_dx12.addon64")
    $bakAddon = [IO.Path]::Combine($Backup, "wwmi_dx12.addon64")
    $rec = "merge"
    Write-Host ""
    if ([IO.File]::Exists($winAddon) -and [IO.File]::Exists($bakAddon)) {
        $w = Get-AddonInfo $winAddon
        $b = Get-AddonInfo $bakAddon
        Write-Host "  Win64 : $($w.Text)   ($($w.Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm')))"
        Write-Host "  백업  : $($b.Text)   ($($b.Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm')))"
        $c = Compare-AddonInfo $w $b
        if ($c -gt 0) { Write-Host "  -> Win64 쪽이 더 새 버전입니다." -ForegroundColor Green }
        elseif ($c -lt 0) { Write-Host "  -> 백업 쪽이 더 새 버전입니다." -ForegroundColor Yellow; $rec = "backup" }
        else { Write-Host "  -> 같은 버전입니다." }
    }
    else {
        Write-Host "  (wwmi_dx12.addon64 가 한쪽에만 있어 버전을 비교할 수 없어요.)"
    }
    Write-Host ""
    $l1 = "  [1] 합치기"
    $l2 = "  [2] 백업본으로 복원"
    if ($rec -eq "merge") { $l1 += " (권장)" } else { $l2 += " (권장)" }
    Write-Host $l1
    Write-Host "      겹치는 본체 파일은 Win64의 파일을 유지하고, 백업본의 같은 이름 파일은 backup\_old 에 보관"
    Write-Host "      내 설정(wwmi_dx12.ini, ReShade 설정·셰이더)은 백업본을 사용하고, 백업본에만 있는 파일은 Win64 로 복원"
    Write-Host $l2
    Write-Host "      겹치는 Win64 파일은 backup\_old 에 보관"
    Write-Host "  [0] 취소"
    while ($true) {
        $in = "$(Read-Host '번호')".Trim()
        if ($in -eq "1") { return "merge" }
        if ($in -eq "2") { return "backup" }
        if ($in -eq "0") { return "cancel" }
        Write-Host "  0, 1, 2 중에서 입력해 주세요." -ForegroundColor Yellow
    }
}

# 백업의 항목을 Win64 로 복원. 같은 이름이 Win64 에 있으면 plan 에 따라 한쪽을 backup\_old 에 보관.
#   plan "plain" : 겹치는 항목 없음 / "merge" : 본체는 Win64 유지, 설정은 백업본 / "backup" : 모두 백업본
function Restore-Items($names, [string]$plan) {
    $oldDir = [IO.Path]::Combine($Backup, "_old", (Get-Date -Format "yyyyMMdd-HHmmss"))
    $usedOld = $false
    foreach ($n in $names) {
        $from = [IO.Path]::Combine($Backup, $n)
        $to = [IO.Path]::Combine($Win64, $n)
        if (-not ([IO.File]::Exists($to) -or [IO.Directory]::Exists($to))) {
            Move-Entry $from $to
            Write-Host "  복원: $n"
            continue
        }
        $takeBackup = ($plan -eq "backup") -or ($n -ieq "wwmi_dx12.ini") -or ($ReShadeNames -contains $n)
        if (-not $takeBackup -and ($n -ieq "dxgi.dll")) {
            # ReShade 본체는 더 새 버전을 사용
            $takeBackup = ((Compare-AddonInfo (Get-AddonInfo $from) (Get-AddonInfo $to)) -gt 0)
        }
        [void][IO.Directory]::CreateDirectory($oldDir)
        $usedOld = $true
        if ($takeBackup) {
            Move-Entry $to ([IO.Path]::Combine($oldDir, $n))
            Move-Entry $from $to
            Write-Host "  복원: $n (Win64 의 같은 이름 항목은 _old 에 보관)"
        }
        else {
            Move-Entry $from ([IO.Path]::Combine($oldDir, $n))
            Write-Host "  유지: $n (백업본의 같은 이름 항목은 _old 에 보관)"
        }
    }
    if ($usedOld) { Write-Host "  보관 위치: $oldDir" }
}

# ===== WWMI-DX12 zip 업데이트 =====
function Get-DownloadsDir {
    try {
        $p = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction Stop
        $v = $p.'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($v) { return [Environment]::ExpandEnvironmentVariables($v) }
    } catch {}
    if ($env:USERPROFILE) { return [IO.Path]::Combine($env:USERPROFILE, "Downloads") }
    return ""
}

# 도구 폴더와 다운로드 폴더에서 WWMI-DX12 zip 후보를 최신순으로 최대 8개
function Find-UpdateZips {
    $dirs = @($PSScriptRoot, (Get-DownloadsDir))
    $list = New-Object System.Collections.ArrayList
    foreach ($d in $dirs) {
        if (-not $d -or -not [IO.Directory]::Exists($d)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
            if ($f.Extension -ieq ".zip" -and $f.Name -like "wwmi*dx12*" -and $f.Name -notlike "*toggle*") { [void]$list.Add($f) }
        }
    }
    $seen = @{}
    $out = @()
    foreach ($f in @($list | Sort-Object LastWriteTime -Descending)) {
        if ($seen.ContainsKey($f.FullName)) { continue }
        $seen[$f.FullName] = $true
        $out += $f
        if ($out.Count -ge 8) { break }
    }
    return $out
}

# 붙여넣거나 끌어다 놓은 경로에서 따옴표와 공백을 지우고 zip 파일이면 전체 경로를 돌려줌. 아니면 빈 문자열.
function Resolve-ZipPath([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $t = $text.Trim().Trim('"').Trim("'").Trim()
    if (-not $t) { return "" }
    try {
        $full = [IO.Path]::GetFullPath($t)
        if ([IO.File]::Exists($full) -and ([IO.Path]::GetExtension($full) -ieq ".zip")) { return $full }
    } catch {}
    return ""
}

# 파일 선택 창으로 zip 고르기 (권한과 무관하게 동작). 취소하거나 열 수 없으면 빈 문자열.
function Select-ZipDialog {
    $owner = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        # 선택 창이 콘솔 뒤에 가려지지 않도록 보이지 않는 최상위 창을 소유자로 씀
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $owner.ShowInTaskbar = $false
        $owner.FormBorderStyle = 'None'
        $owner.Opacity = 0
        $owner.StartPosition = 'CenterScreen'
        $owner.Size = New-Object System.Drawing.Size(1, 1)
        $owner.Show()
        $owner.Activate()
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = "WWMI-DX12 zip 파일 선택"
        $dlg.Filter = "zip 파일 (*.zip)|*.zip|모든 파일 (*.*)|*.*"
        $dl = Get-DownloadsDir
        if ($dl -and [IO.Directory]::Exists($dl)) { $dlg.InitialDirectory = $dl }
        if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    }
    catch {
        Write-Host "  파일 선택 창을 열 수 없어요: $_" -ForegroundColor Yellow
        Write-Host "  zip 을 도구 폴더나 다운로드 폴더에 두면 목록에 자동으로 나와요." -ForegroundColor Yellow
    }
    finally {
        if ($owner) { $owner.Dispose() }
    }
    return ""
}

# zip 선택. 자동 탐색 목록 + 파일 선택 창, 0 은 취소. 취소하면 빈 문자열.
function Select-UpdateZip {
    $found = @(Find-UpdateZips)
    $dialogNo = $found.Count + 1
    while ($true) {
        Write-Host "업데이트할 WWMI-DX12 zip 파일을 선택해 주세요." -ForegroundColor Cyan
        for ($i = 0; $i -lt $found.Count; $i++) {
            Write-Host ("  [{0}] {1}  ({2:yyyy-MM-dd HH:mm})  {3}" -f ($i + 1), $found[$i].Name, $found[$i].LastWriteTime, $found[$i].DirectoryName)
        }
        Write-Host "  [$dialogNo] 파일 선택 창에서 고르기"
        Write-Host "  [0] 취소"
        $in = "$(Read-Host '번호')".Trim()
        if ($in -eq "0") { return "" }
        if ($in -match '^\d+$') {
            $n = [int]$in
            if ($n -ge 1 -and $n -le $found.Count) { return $found[$n - 1].FullName }
            if ($n -eq $dialogNo) {
                $z = Select-ZipDialog
                if ($z) {
                    $zr = Resolve-ZipPath $z
                    if ($zr) { return $zr }
                    Write-Host "  zip 파일이 아니에요. 다시 선택해 주세요." -ForegroundColor Yellow
                }
                Write-Host ""
                continue
            }
        }
        Write-Host "  목록에 있는 번호를 입력해 주세요." -ForegroundColor Yellow
        Write-Host ""
    }
}

# wwmi_dx12.addon64 파일 속성에서 버전 정보를 읽음 (런처가 쓰는 방식과 같음)
function Get-AddonInfo([string]$file) {
    $r = @{ Text = "버전 정보 없음"; Version = $null; Build = ""; Time = [IO.File]::GetLastWriteTimeUtc($file) }
    try {
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($file)
        $pv = "$($info.ProductVersion)".Trim()
        $b = "$($info.Comments)".Trim()
        $r.Build = $b
        if ($pv) {
            if ($b) { $r.Text = "$pv (build $b)" } else { $r.Text = $pv }
            if ($pv -match '^(\d+(\.\d+){0,3})') {
                $vs = $Matches[1]
                if ($vs -notmatch '\.') { $vs = "$vs.0" }
                try { $r.Version = [version]$vs } catch {}
            }
        }
    } catch {}
    return $r
}

# a 가 b 보다 새 것이면 1, 같으면 0, 옛 것이면 -1. 버전 정보가 없으면 수정 날짜로 비교.
function Compare-AddonInfo($a, $b) {
    if ($null -ne $a.Version -and $null -ne $b.Version) {
        $c = $a.Version.CompareTo($b.Version)
        if ($c -ne 0) { return $c }
        [long]$na = 0
        [long]$nb = 0
        if ([long]::TryParse($a.Build, [ref]$na) -and [long]::TryParse($b.Build, [ref]$nb)) { return $na.CompareTo($nb) }
        if (-not $a.Build -or -not $b.Build -or ($a.Build -ceq $b.Build)) { return 0 }
    }
    $d = ($a.Time - $b.Time).TotalSeconds
    if ([math]::Abs($d) -lt 2) { return 0 }
    if ($d -gt 0) { return 1 }
    return -1
}

# 폴더 내용을 합쳐서 복사 (같은 이름의 파일은 덮어씀, 없는 파일은 그대로 둠)
function Copy-Tree([string]$src, [string]$dst) {
    [void][IO.Directory]::CreateDirectory($dst)
    foreach ($f in [IO.Directory]::GetFiles($src)) {
        [IO.File]::Copy($f, [IO.Path]::Combine($dst, [IO.Path]::GetFileName($f)), $true)
    }
    foreach ($d in [IO.Directory]::GetDirectories($src)) {
        Copy-Tree $d ([IO.Path]::Combine($dst, [IO.Path]::GetFileName($d)))
    }
}
function Copy-Entry([string]$from, [string]$to) {
    if ([IO.Directory]::Exists($from)) { Copy-Tree $from $to }
    else { [IO.File]::Copy($from, $to, $true) }
}

# zip 에서 wwmi_dx12* 항목만 임시 폴더로 풀기. 푼 파일 수를 돌려줌 (wwmi_dx12.addon64 가 없으면 0).
#   - wwmi_dx12.ini (사용자 설정) 는 건너뜀
#   - 경로에 .. 가 있거나 임시 폴더 밖으로 나가는 항목은 건너뜀
function Expand-UpdateZip([string]$zip, [string]$dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $destFull = [IO.Path]::GetFullPath($dest).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $base = $null   # wwmi_dx12.addon64 가 있는 위치 (zip 안에 폴더로 한 번 감싸져 있어도 처리)
        foreach ($e in $archive.Entries) {
            if ($e.Name -ieq "wwmi_dx12.addon64") {
                $full = $e.FullName.Replace('/', '\')
                $pre = $full.Substring(0, $full.Length - $e.Name.Length)
                if ($null -eq $base -or $pre.Length -lt $base.Length) { $base = $pre }
            }
        }
        if ($null -eq $base) { return 0 }
        $count = 0
        foreach ($e in $archive.Entries) {
            if (-not $e.Name) { continue }   # 폴더 항목
            $full = $e.FullName.Replace('/', '\')
            if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $rel = $full.Substring($base.Length)
            if ($rel -notlike "wwmi_dx12*") { continue }
            if ($rel -ieq "wwmi_dx12.ini") { continue }
            if (($rel.Split('\') -contains "..") -or $rel.Contains(":")) { continue }
            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($dest, $rel))
            if (-not $target.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            $count++
        }
        return $count
    }
    finally { $archive.Dispose() }
}

function Invoke-Update {
    if (Get-Process $proc -ErrorAction SilentlyContinue) {
        Write-Host "  게임이 실행 중입니다. 종료한 뒤 다시 시도해 주세요." -ForegroundColor Yellow
        return
    }
    $inWin = [IO.File]::Exists([IO.Path]::Combine($Win64, "wwmi_dx12.addon64"))
    $inBak = [IO.File]::Exists([IO.Path]::Combine($Backup, "wwmi_dx12.addon64"))
    if ($inWin -and $inBak) {
        Write-Host "  Win64 와 백업 양쪽에 WWMI-DX12 가 모두 있어서 업데이트할 수 없어요. 한쪽으로 먼저 정리해 주세요." -ForegroundColor Yellow
        return
    }
    if (-not $inWin -and -not $inBak) {
        Write-Host "  설치된 WWMI-DX12 가 없어서 업데이트할 수 없어요. (wwmi_dx12.addon64 없음)" -ForegroundColor Yellow
        return
    }
    $targetDir = $Backup
    $label = "백업 (Off 상태)"
    if ($inWin) { $targetDir = $Win64; $label = "Win64 (On 상태)" }

    $zip = Select-UpdateZip
    if (-not $zip) {
        Write-Host "  업데이트를 취소했어요."
        return
    }

    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "wwmi_dx12_update_" + [Guid]::NewGuid().ToString("N"))
    $oldDir = ""
    try {
        $count = Expand-UpdateZip $zip $tmp
        if ($count -eq 0) {
            Write-Host "  이 zip 에서 WWMI-DX12 파일을 찾지 못했어요. (wwmi_dx12.addon64 없음)" -ForegroundColor Yellow
            return
        }
        $cur = Get-AddonInfo ([IO.Path]::Combine($targetDir, "wwmi_dx12.addon64"))
        $new = Get-AddonInfo ([IO.Path]::Combine($tmp, "wwmi_dx12.addon64"))
        Write-Host ""
        Write-Host "  업데이트 대상 : $label"
        Write-Host "  설치됨 : $($cur.Text)   ($($cur.Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm')))"
        Write-Host "  새 zip : $($new.Text)   ($($new.Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm')))"
        $cmp = Compare-AddonInfo $new $cur
        if ($cmp -gt 0) {
            Write-Host "  -> 더 새 버전입니다." -ForegroundColor Green
        }
        else {
            $why = "같은 버전"
            if ($cmp -lt 0) { $why = "더 옛 버전" }
            Write-Host "  -> $why 입니다." -ForegroundColor Yellow
            $ans = "$(Read-Host '  그래도 덮어쓸까요? (y/n, Enter = 취소)')".Trim()
            if ($ans -notmatch '^(y|yes)$') {
                Write-Host "  업데이트를 취소했어요."
                return
            }
        }
        $items = @(Get-ChildItem -LiteralPath $tmp -Force | ForEach-Object { $_.Name })
        $oldDir = [IO.Path]::Combine($Backup, "_old", (Get-Date -Format "yyyyMMdd-HHmmss"))
        [void][IO.Directory]::CreateDirectory($oldDir)
        # 1) 기존 파일을 _old 에 보관
        foreach ($n in $items) {
            $cur1 = [IO.Path]::Combine($targetDir, $n)
            if ([IO.File]::Exists($cur1) -or [IO.Directory]::Exists($cur1)) { Copy-Entry $cur1 ([IO.Path]::Combine($oldDir, $n)) }
        }
        # 2) 새 파일로 덮어쓰기
        foreach ($n in $items) {
            Copy-Entry ([IO.Path]::Combine($tmp, $n)) ([IO.Path]::Combine($targetDir, $n))
            Write-Host "  갱신: $n"
        }
        Write-Host ""
        Write-Host "  완료: WWMI-DX12 를 업데이트했어요." -ForegroundColor Green
        Write-Host "  이전 파일은 보관해 뒀어요: $oldDir"
    }
    catch {
        Write-Host ""
        Write-Host "  업데이트 중 오류가 났어요: $_" -ForegroundColor Red
        if ($oldDir) { Write-Host "  이전 파일은 여기에 보관돼 있어요: $oldDir" -ForegroundColor Red }
    }
    finally {
        if ([IO.Directory]::Exists($tmp)) { try { [IO.Directory]::Delete($tmp, $true) } catch {} }
    }
}

Set-ConsoleSize 120 40

# 저장된 경로 사용. 없거나 더 이상 유효하지 않으면 자동 탐색/입력
$cfg = Load-Cfg
$IncludeReShade = $IncludeReShadeDefault
if ($null -ne $cfg.IncludeReShade) { $IncludeReShade = [bool]$cfg.IncludeReShade }
$Win64 = Resolve-Win64 $cfg.Win64
if (-not $Win64) {
    $Win64 = Select-Win64 ""
    if (-not $Win64) { Fail "경로가 지정되지 않아 종료합니다." }
    Save-Cfg
    Write-Host ""
    Write-Host "저장했어요: $Win64" -ForegroundColor Green
    Write-Host ""
}

Write-Host "WWMI-DX12 백업/복원 ($Mode)" -ForegroundColor Cyan
Write-Host ""

if (-not [IO.File]::Exists([IO.Path]::Combine($Win64, "$proc.exe"))) {
    Fail "Win64 폴더가 아닙니다 ($proc.exe 없음): $Win64`n메뉴의 [3] 으로 경로를 다시 지정하거나 $cfgFile 을 지워 주세요."
}

if ($Mode -eq "Status") { Show-Status; Wait-Key; exit 0 }

if ($Mode -eq "Menu") {
    $firstDraw = $true
    while ($true) {
        if (-not $firstDraw) {
            try { Clear-Host } catch {}
            Write-Host "WWMI-DX12 백업/복원 (Menu)" -ForegroundColor Cyan
            Write-Host ""
        }
        $firstDraw = $false
        Show-Status
        Write-Host ""
        Write-Host "  [1] Off : WWMI-DX12를 백업으로 옮기기"
        Write-Host "  [2] On  : 백업에서 Win64로 되돌리기"
        Write-Host "  [3] 경로 : 명조 설치 경로 변경"
        $rsNow = "제외"; $rsNext = "포함"
        if ($IncludeReShade) { $rsNow = "포함"; $rsNext = "제외" }
        Write-Host "  [4] ReShade 설정·셰이더 : 현재 $rsNow -> $rsNext 로 전환"
        Write-Host "  [5] 업데이트 : WWMI-DX12 zip 파일로 갱신"
        Write-Host "  그 외 키 : 아무것도 하지 않고 닫기"
        $k = $null
        try { $k = [Console]::ReadKey($true).KeyChar } catch {}
        if ($k -eq '3') {
            Write-Host ""
            Write-Host "  현재 경로: $Win64"
            $np = Select-Win64 $Win64
            if ($np) {
                $Win64 = $np
                Save-Cfg
                Write-Host ""
                Write-Host "  경로를 변경했어요: $Win64" -ForegroundColor Green
            }
            else {
                Write-Host "  변경하지 않았어요."
            }
            Wait-Menu
            continue
        }
        if ($k -eq '5') {
            Write-Host ""
            Invoke-Update
            Wait-Menu
            continue
        }
        if ($k -eq '4') {
            Write-Host ""
            if (Test-BackupHasItems) {
                Write-Host "  백업에 항목이 있는 상태(Off)에서는 바꿀 수 없어요. [2] On 으로 복원한 뒤 변경해 주세요." -ForegroundColor Yellow
            }
            else {
                $IncludeReShade = -not $IncludeReShade
                Save-Cfg
                $rs = "제외"
                if ($IncludeReShade) { $rs = "포함" }
                Write-Host "  ReShade 설정·셰이더를 옮기는 대상에 $rs 하도록 바꿨어요." -ForegroundColor Green
            }
            Wait-Menu
            continue
        }
        if ($k -eq '1') { $Mode = "Off" }
        elseif ($k -eq '2') { $Mode = "On" }
        else { exit 0 }
        break
    }
    Write-Host ""
    Write-Host "WWMI-DX12 백업/복원 ($Mode)" -ForegroundColor Cyan
    Write-Host ""
}

if (Get-Process $proc -ErrorAction SilentlyContinue) { Fail "게임이 실행 중입니다. 종료한 뒤 다시 실행해 주세요." }

if ($Mode -eq "Off") {
    $names = Get-TargetNames $Win64
    if ($names.Count -eq 0) { Fail "Win64에 옮길 WWMI-DX12 파일이 없습니다. (이미 백업 상태일 수 있어요)" }
    if ((Get-TargetNames $Backup).Count -gt 0) {
        Fail "백업 폴더에 이미 파일이 있어 덮어쓰지 않고 중단합니다.`n메뉴의 [2] On 으로 먼저 정리한 뒤 다시 Off 해 주세요. (백업 폴더: $Backup)"
    }
    $offAddon = [IO.Path]::Combine($Win64, "wwmi_dx12.addon64")
    if ([IO.File]::Exists($offAddon)) { Write-Host "  백업할 WWMI-DX12 : $((Get-AddonInfo $offAddon).Text)" }
    [void][IO.Directory]::CreateDirectory($Backup)
    $ap = Get-AddonPath   # ReShade.ini 를 옮기기 전에 읽어 둠
    foreach ($n in $names) {
        Move-Entry ([IO.Path]::Combine($Win64, $n)) ([IO.Path]::Combine($Backup, $n))
        Write-Host "  백업: $n"
    }
    # ReShade.ini 의 AddonPath 로 복사된 addon64 도 함께 백업
    if ($ap -and ([IO.Path]::GetFullPath($ap) -ine [IO.Path]::GetFullPath($Win64))) {
        $apFile = [IO.Path]::Combine($ap, "wwmi_dx12.addon64")
        if ([IO.File]::Exists($apFile)) {
            [void][IO.Directory]::CreateDirectory($addonPathDir)
            [IO.File]::Move($apFile, [IO.Path]::Combine($addonPathDir, "wwmi_dx12.addon64"))
            [IO.File]::WriteAllText($addonPathNote, $ap, [Text.Encoding]::UTF8)
            Write-Host "  백업: $apFile (AddonPath)"
        }
    }
    Write-Host ""
    Write-Host "완료: WWMI-DX12를 백업 폴더로 옮겼습니다." -ForegroundColor Green
}
else {
    $names = Get-TargetNames $Backup
    if ($names.Count -eq 0) { Fail "백업 폴더에 되돌릴 파일이 없습니다: $Backup" }
    $clash = @($names | Where-Object { [IO.File]::Exists([IO.Path]::Combine($Win64, $_)) -or [IO.Directory]::Exists([IO.Path]::Combine($Win64, $_)) })
    $plan = "plain"
    if ($clash.Count -gt 0) {
        $plan = Resolve-RestoreConflict $clash
        if ($plan -eq "cancel") {
            Write-Host ""
            Write-Host "복원을 취소했습니다." -ForegroundColor Yellow
            Wait-Key
            exit 0
        }
        Write-Host ""
    }
    else {
        $restoreAddon = [IO.Path]::Combine($Backup, "wwmi_dx12.addon64")
        if ([IO.File]::Exists($restoreAddon)) { Write-Host "  복원할 WWMI-DX12 : $((Get-AddonInfo $restoreAddon).Text)" }
    }
    Restore-Items $names $plan
    if ([IO.File]::Exists($addonPathNote)) {
        $ap = [IO.File]::ReadAllText($addonPathNote).Trim()
        $src = [IO.Path]::Combine($addonPathDir, "wwmi_dx12.addon64")
        $dst = [IO.Path]::Combine($ap, "wwmi_dx12.addon64")
        if ([IO.File]::Exists($src) -and -not [IO.File]::Exists($dst)) {
            [void][IO.Directory]::CreateDirectory($ap)
            [IO.File]::Move($src, $dst)
            Write-Host "  복원: $dst (AddonPath)"
        }
        if (-not [IO.File]::Exists($src)) {
            [IO.File]::Delete($addonPathNote)
            if ([IO.Directory]::Exists($addonPathDir) -and -not (Get-ChildItem -LiteralPath $addonPathDir -Force)) {
                [IO.Directory]::Delete($addonPathDir)
            }
        }
    }
    Write-Host ""
    Write-Host "완료: WWMI-DX12를 Win64 폴더로 되돌렸습니다." -ForegroundColor Green
}

Write-Host ""
Show-Status
Wait-Key
