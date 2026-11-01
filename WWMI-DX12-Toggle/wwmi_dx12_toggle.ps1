# WWMI-DX12 백업/복원 스크립트
#   (인자 없음) : 상태를 보여주고 1/2/3/4 키로 선택 (3 = 명조 경로 변경, 4 = ReShade 포함 여부 전환)
#   Off    : Win64 폴더의 WWMI-DX12 파일을 백업 폴더로 옮김 (삭제하지 않음)
#   On     : 백업 폴더의 파일을 Win64 폴더로 되돌림
#   Status : 현재 상태만 표시
# 경로에 [ ] 가 있어도 안전하도록 .NET 경로 함수와 -LiteralPath 를 사용합니다.

param(
    [ValidateSet("Menu", "Off", "On", "Status")]
    [string]$Mode = "Menu"
)

# ===== 설정 =====
# 명조 경로와 ReShade 포함 여부는 wwmi_dx12_toggle.cfg 에 저장됩니다.
# 처음 실행할 때 경로를 자동 탐색/입력받고, 메뉴의 [3] 경로 변경 / [4] ReShade 포함 전환으로 언제든 바꿀 수 있어요.
# (cfg 파일을 지우면 경로를 다시 묻고 ReShade 포함 여부는 아래 기본값으로 돌아갑니다.)
# 백업 저장소 (기본: 이 스크립트가 있는 폴더 아래 backup)
$Backup = [IO.Path]::Combine($PSScriptRoot, "backup")
# Win64의 ReShade(DX12용) 세트도 같이 옮길지 여부 (기본값 -- 메뉴 [4] 로 바꾸면 cfg 에 저장되어 그 값이 우선합니다)
#   $true  : dxgi.dll, ReShade.ini, ReShadePreset.ini, ReShade.log, reshade-shaders 를 함께 옮김 (있는 것만)
#            (DX11 런처가 자체 경로의 ReShade를 쓰는 경우 -- 이중 로드 방지)
#   $false : ReShade 세트는 Win64에 그대로 둠
$IncludeReShadeDefault = $true
$ReShadeNames = @("dxgi.dll", "ReShade.ini", "ReShadePreset.ini", "ReShade.log", "reshade-shaders")
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

# 백업 폴더에 WWMI-DX12 / ReShade 항목이 하나라도 있는지 (Off 상태 여부)
function Test-BackupHasItems {
    if (-not [IO.Directory]::Exists($Backup)) { return $false }
    foreach ($e in (Get-ChildItem -LiteralPath $Backup -Force)) {
        if ($e.Name -like "wwmi_dx12*" -or ($ReShadeNames -contains $e.Name)) { return $true }
    }
    return $false
}

# Win64 폴더 안에서 옮길 대상 이름 목록
function Get-TargetNames([string]$folder) {
    if (-not [IO.Directory]::Exists($folder)) { return @() }
    $names = @(Get-ChildItem -LiteralPath $folder -Force |
        Where-Object { $_.Name -like "wwmi_dx12*" } |
        ForEach-Object { $_.Name })
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

function Show-Status {
    $inGame = Get-TargetNames $Win64
    $inBackup = Get-TargetNames $Backup
    Write-Host "  Win64   : $Win64"
    Write-Host "  백업    : $Backup"
    $rs = "제외"
    if ($IncludeReShade) { $rs = "포함" }
    Write-Host "  ReShade : $rs (메뉴 [4] 로 전환)"
    Write-Host ""
    Write-Host "  Win64에 있는 항목 ($($inGame.Count))"
    foreach ($n in $inGame) { Write-Host "    $n" }
    Write-Host "  백업에 있는 항목 ($($inBackup.Count))"
    foreach ($n in $inBackup) { Write-Host "    $n" }
    if ([IO.File]::Exists($addonPathNote)) {
        Write-Host "  AddonPath 사본 백업: $([IO.File]::ReadAllText($addonPathNote).Trim())"
    }
    Write-Host ""
    if ($inGame.Count -gt 0 -and $inBackup.Count -eq 0) { Write-Host "  상태: 설치됨 (On)" -ForegroundColor Green }
    elseif ($inGame.Count -eq 0 -and $inBackup.Count -gt 0) { Write-Host "  상태: 백업됨 (Off)" -ForegroundColor Yellow }
    elseif ($inGame.Count -eq 0) { Write-Host "  상태: 양쪽 모두 없음" -ForegroundColor DarkGray }
    else { Write-Host "  상태: 양쪽에 모두 있음 -- 직접 정리가 필요합니다" -ForegroundColor Red }
}

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
    while ($true) {
        Show-Status
        Write-Host ""
        Write-Host "  [1] Off : WWMI-DX12를 백업으로 옮기기"
        Write-Host "  [2] On  : 백업에서 Win64로 되돌리기"
        Write-Host "  [3] 경로 : 명조 설치 경로 변경"
        $rsNow = "제외"; $rsNext = "포함"
        if ($IncludeReShade) { $rsNow = "포함"; $rsNext = "제외" }
        Write-Host "  [4] ReShade : 현재 $rsNow -> $rsNext 로 전환"
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
            Write-Host ""
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
                Write-Host "  ReShade 를 옮기는 대상에 $rs 하도록 바꿨어요." -ForegroundColor Green
            }
            Write-Host ""
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
        Fail "백업 폴더에 이미 파일이 있어 덮어쓰지 않고 중단합니다.`n백업 폴더를 확인해 주세요: $Backup"
    }
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
    if ($clash.Count -gt 0) {
        Fail "Win64에 같은 이름이 이미 있어 덮어쓰지 않고 중단합니다: $($clash -join ', ')"
    }
    foreach ($n in $names) {
        Move-Entry ([IO.Path]::Combine($Backup, $n)) ([IO.Path]::Combine($Win64, $n))
        Write-Host "  복원: $n"
    }
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
