<#
  WW-ClientLink.ps1  -  명조 클라이언트 심볼릭 링크 도구 v1.0
  [링크 생성] 원본 클라이언트의 Paks / Resources(영상 포함) / (UHD·HD·SD) 폴더를 대상 클라이언트에 심볼릭 링크로 연결해 용량 중복을 없앱니다.
              대상의 기존 폴더는 삭제하지 않고 이름 뒤에 _backup 을 붙여 보관하며, 확인 후 [백업 삭제]로 정리합니다.
  [링크 관리] 클라이언트(최대 4개: 원본 1 + 링크 3)를 등록해 링크 현황을 확인하고, 연결·해제·깨진 링크 정리·백업 삭제·업데이트 후 동기화를 합니다.
  등록 정보는 이 도구가 있는 폴더의 WW-ClientLink.json, 로그는 logs 폴더에 저장됩니다.
  실행: WW-ClientLink.bat 더블클릭 (관리자 권한이 아니면 UAC 창을 띄워 자기 자신을 관리자 권한으로 다시 실행합니다)
#>
param([switch]$NoGui)

$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0'
$GameDirName = 'Wuthering Waves Game'

# ---------------------------------------------------------------- 관리자 권한 확인 / 자동 상승 (심볼릭 링크 생성에 필요)
if (-not $NoGui) {
    $elevId = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($elevId)

    if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
        try {
            Start-Process -FilePath 'powershell.exe' `
                -Verb RunAs `
                -ErrorAction Stop `
                -ArgumentList @(
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-STA',
                    '-WindowStyle', 'Hidden',
                    '-File', "`"$PSCommandPath`""
                )
        }
        catch {
            Add-Type -AssemblyName System.Windows.Forms

            [void][System.Windows.Forms.MessageBox]::Show(
                "관리자 권한 실행이 취소되었거나 실패했습니다.`n`n$($_.Exception.Message)",
                '명조 클라이언트 심볼릭 링크 도구',
                'OK',
                'Warning'
            )
        }

        exit
    }
}

# ---------------------------------------------------------------- 공용 함수

function Get-NormPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $p = $p.Trim().Trim('"')
    try { $p = [IO.Path]::GetFullPath($p) } catch { return '' }
    $root = [IO.Path]::GetPathRoot($p)
    if ($p.Length -gt $root.Length) { $p = $p.TrimEnd('\', '/') }
    return $p
}

function Test-Nested([string]$a, [string]$b) {
    $x = $a.TrimEnd('\') + '\'
    $y = $b.TrimEnd('\') + '\'
    return ($x.StartsWith($y, [StringComparison]::OrdinalIgnoreCase) -or $y.StartsWith($x, [StringComparison]::OrdinalIgnoreCase))
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-RunningConflicts([string[]]$dirs) {
    $bases = @()
    foreach ($d in $dirs) {
        $parent = Split-Path $d -Parent
        $root = [IO.Path]::GetPathRoot($parent)
        if ($parent -and ($parent.TrimEnd('\') -ne $root.TrimEnd('\'))) { $bases += $parent } else { $bases += $d }
    }
    $hit = @()
    foreach ($pr in (Get-Process -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $pr.Path } catch { }
        if (-not $path) { continue }
        foreach ($b in $bases) {
            if ($path.StartsWith($b.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $hit += ('{0} (PID {1})' -f $pr.ProcessName, $pr.Id); break
            }
        }
    }
    return $hit
}

# 런처 폴더 상태: launcher.exe / Wuthering Waves Game 폴더 / Wuthering Waves.exe
function Get-State([string]$p) {
    $n = Get-NormPath $p
    if (-not $n) { return $null }
    if ((Split-Path $n -Leaf) -eq $GameDirName) { $root = Split-Path $n -Parent; $game = $n }
    else { $root = $n; $game = Join-Path $n $GameDirName }
    $ge = Test-Path -LiteralPath $game -PathType Container
    $ne = $false
    if ($ge) { $ne = [bool](Get-ChildItem -LiteralPath $game -Force -ErrorAction SilentlyContinue | Select-Object -First 1) }
    [pscustomobject]@{
        Root       = $root
        Game       = $game
        Launcher   = (Test-Path -LiteralPath (Join-Path $root 'launcher.exe') -PathType Leaf)
        GameExists = $ge
        Exe        = ($ge -and (Test-Path -LiteralPath (Join-Path $game 'Wuthering Waves.exe') -PathType Leaf))
        NonEmpty   = $ne
    }
}
function Get-Game([string]$p) { $st = Get-State $p; if ($st) { return $st.Game } else { return $null } }

# 링크 대상 폴더 목록 (Fixed = 항상 연결, 그 외 = 체크박스로 선택)
$Items = @(
    @{ Key = 'Paks';      Sub = 'Client\Content\Paks';       Label = 'Paks  (공통 리소스)';              Fixed = $true  },
    @{ Key = 'UHD';       Sub = 'Client\Content\UHD';        Label = 'UHD 리소스';                        Fixed = $false },
    @{ Key = 'HD';        Sub = 'Client\Content\HD';         Label = 'HD 리소스';                         Fixed = $false },
    @{ Key = 'SD';        Sub = 'Client\Content\SD';         Label = 'SD 리소스';                         Fixed = $false },
    @{ Key = 'Resources'; Sub = 'Client\Saved\Resources';    Label = 'Resources  (버전별 리소스 · 영상)'; Fixed = $true  }
)

# 항목의 백업 폴더 (이름_backup, 이름_backup_날짜시간) 목록
function Get-ItemBackups([string]$game, $it) {
    $full = Join-Path $game $it.Sub
    $parent = Split-Path $full -Parent; $leaf = Split-Path $full -Leaf
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return @() }
    $rx = '^' + [regex]::Escape($leaf) + '_backup(_\d{8}_\d{6})?$'
    return @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $rx -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
}

# 작업 계획: Kind = link / backup+link / relink / skip / error
function Build-Plan([string]$srcGame, [string]$dstGame, [string[]]$keys, $items = $Items) {
    $plan = @()
    foreach ($it in $items) {
        if ($keys -notcontains $it.Key) { continue }
        $src = Join-Path $srcGame $it.Sub; $dst = Join-Path $dstGame $it.Sub
        $li = Get-LinkInfo $dst
        $kind = 'error'
        switch ($li.Kind) {
            'none' { $kind = 'link' }
            'dir'  { $kind = 'backup+link' }
            'file' { $kind = 'error' }
            'link' { if ((Get-NormPath $li.Target) -ieq (Get-NormPath $src)) { $kind = 'skip' } else { $kind = 'relink' } }
        }
        $plan += [pscustomobject]@{ Key = $it.Key; Sub = $it.Sub; Src = $src; Dst = $dst; Kind = $kind }
    }
    return $plan
}


# ---------------------------------------------------------------- 설정 / 클라이언트 목록

$AppName    = 'WW-ClientLink'
# (버전 표시 없음: 완성 후 1.0으로 시작)
$MaxClients = 4
$ToolDir      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$SettingsFile = Join-Path $ToolDir 'WW-ClientLink.json'

$script:clients  = @()
$script:settings = $null
$script:sizeCache = @{}

function Get-DefaultSettings {
    return @{
        Clients         = @()
        Keywords        = @('wuthering', 'wuwa', 'kuro', '명조')
        Depth           = 5      # 탐색 정확도: 3(빠름) / 5(보통) / 7(정확)
        ClientsExpanded = $false
    }
}

function Read-Settings {
    $d = Get-DefaultSettings
    if (-not (Test-Path -LiteralPath $SettingsFile)) { return $d }
    try {
        $j = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $cl = @(); $hasSrc = $false
        foreach ($c in @($j.Clients)) {
            if ($c -and $c.Path -and $c.Name -and ($cl.Count -lt $MaxClients)) {
                $role = 'link'
                if ($c.Role -eq 'src' -and -not $hasSrc) { $role = 'src'; $hasSrc = $true }
                $cl += @{ Name = [string]$c.Name; Path = [string]$c.Path; Role = $role }
            }
        }
        $d.Clients = $cl
        $kw = @($j.Keywords | Where-Object { $_ })
        if ($kw.Count -gt 0) { $d.Keywords = $kw }
        $n = 0
        if ($null -ne $j.Depth -and [int]::TryParse([string]$j.Depth, [ref]$n) -and $n -ge 1 -and $n -le 8) { if ($n -le 3) { $d.Depth = 3 } elseif ($n -le 5) { $d.Depth = 5 } else { $d.Depth = 7 } }
        if ($null -ne $j.ClientsExpanded) { $d.ClientsExpanded = [bool]$j.ClientsExpanded }
    } catch { }
    return $d
}

function Save-AppSettings {
    $s = $script:settings
    if (-not $s) { return $false }
    $obj = [ordered]@{
        Clients         = @($script:clients | ForEach-Object { [ordered]@{ Name = $_.Name; Path = $_.Path; Role = $_.Role } })
        Keywords        = @($s.Keywords)
        Depth           = [int]$s.Depth
        ClientsExpanded = [bool]$s.ClientsExpanded
    }
    try {
        $tmpf = $SettingsFile + '.tmp'
        ($obj | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $tmpf -Encoding UTF8
        Move-Item -LiteralPath $tmpf -Destination $SettingsFile -Force -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

# 원본 클라이언트가 맨 앞에 오도록 정렬
function Sort-Clients($list) {
    $l = @($list)
    return @(@($l | Where-Object { $_.Role -eq 'src' }) + @($l | Where-Object { $_.Role -ne 'src' }))
}

# 기본 이름: 클라이언트 1, 2, ... (사용 중이 아닌 가장 작은 번호)
function Get-DefaultName([string[]]$taken) {
    for ($n = 1; $n -le 99; $n++) {
        $nm = '클라이언트 ' + $n
        if (-not ($taken | Where-Object { $_ -ieq $nm })) { return $nm }
    }
    return '클라이언트'
}

# ---------------------------------------------------------------- 링크 상태

# 경로 상태: none / dir / link / file (link 이면 Target, TargetExists)
function Get-LinkInfo([string]$path) {
    $attr = $null
    try { $attr = [IO.File]::GetAttributes($path) } catch { return @{ Kind = 'none' } }
    if ($attr -band [IO.FileAttributes]::ReparsePoint) {
        $tg = ''
        try { $tg = [string](@((Get-Item -LiteralPath $path -Force -ErrorAction Stop).Target) -join '') } catch { }
        if (-not $tg) {
            try {
                $parent = Split-Path $path -Parent; $leaf = Split-Path $path -Leaf
                $it = Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop | Where-Object { $_.Name -ieq $leaf } | Select-Object -First 1
                if ($it) { $tg = [string](@($it.Target) -join '') }
            } catch { }
        }
        $exists = $false
        try { if ($tg) { $exists = Test-Path -LiteralPath $tg -PathType Container } else { $exists = Test-Path -LiteralPath $path -PathType Container } } catch { }
        return @{ Kind = 'link'; Target = $tg; TargetExists = $exists }
    }
    if ($attr -band [IO.FileAttributes]::Directory) { return @{ Kind = 'dir' } }
    return @{ Kind = 'file' }
}

# 링크 대상 경로에서 그 클라이언트의 Game 폴더 경로를 추정 (모르면 $null)
function Get-GameFromTarget([string]$target, $it) {
    $t = Get-NormPath $target
    if (-not $t) { return $null }
    $suffix = '\' + $it.Sub
    if ($t.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) { return $t.Substring(0, $t.Length - $suffix.Length) }
    return $null
}


# ---------------------------------------------------------------- 버전 (Game\launcherDownloadConfig.json)
#  {"appId":"50004","version":"3.7.0","bundles":{"UHD":{"version":"3.7.2",...}}}
#  version = 기본(런처) 버전, bundles.*.version = 콘텐츠 버전. 비교에는 콘텐츠 버전(없으면 기본 버전)을 씁니다.

function Get-ClientVersion([string]$game) {
    if (-not $game) { return $null }
    $f = Join-Path $game 'launcherDownloadConfig.json'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
    try {
        $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        $base = [string]$j.version
        $best = $null
        if ($j.bundles) {
            foreach ($b in $j.bundles.PSObject.Properties) {
                $v = [string]$b.Value.version
                if ($v -match '^\d+\.\d+(\.\d+)?$') {
                    if (-not $best -or ([version]$v) -gt ([version]$best)) { $best = $v }
                }
            }
        }
        if (-not $best -and $base -match '^\d+\.\d+(\.\d+)?$') { $best = $base }
        if (-not $best) { return $null }
        $m = [regex]::Match($best, '^(\d+)\.(\d+)(?:\.(\d+))?')
        $patch = 0; if ($m.Groups[3].Success) { $patch = [int]$m.Groups[3].Value }
        return @{ Base = $base; Content = $best; Major = [int]$m.Groups[1].Value; Minor = [int]$m.Groups[2].Value; Patch = $patch }
    } catch { return $null }
}

# 원본 버전($sv)과 대상 버전($dv) 비교 (순수 함수)
#   Level: ok(완전 일치) / patch(3.7 단위는 같고 끝자리만 다름: 허용) / minor(3.7 단위가 다름: 링크 불가) / unknown(확인 불가)
function Compare-ClientVersion($sv, $dv) {
    if (-not $sv -or -not $dv) { return @{ Level = 'unknown'; Line = '–  버전 확인 불가'; Block = '' } }
    if ($sv.Major -ne $dv.Major -or $sv.Minor -ne $dv.Minor) {
        $lower = '대상'
        if (([version]$sv.Content) -lt ([version]$dv.Content)) { $lower = '원본' }
        $blk = ("버전이 달라 링크할 수 없습니다.`r`n원본 {0} / 대상 {1}  ({2}.{3} 단위가 일치해야 함)`r`n`r`n{4} 쪽 버전이 더 낮습니다. 해당 런처에서 최신 버전으로 업데이트한 뒤 다시 진행하세요.`r`n(링크가 이미 걸린 상태라면 링크 쪽 런처로는 업데이트하지 마세요. 원본을 먼저 업데이트한 뒤 [링크 관리]의 [업데이트 후 동기화]를 사용하세요.)" -f $sv.Content, $dv.Content, $sv.Major, $sv.Minor, $lower)
        return @{ Level = 'minor'; Line = ('✖  버전 불일치 (원본 {0} · 대상 {1})' -f $sv.Content, $dv.Content); Block = $blk }
    }
    if ($sv.Patch -ne $dv.Patch) {
        return @{ Level = 'patch'; Line = ('△  패치 차이 (원본 {0} · 대상 {1})' -f $sv.Content, $dv.Content); Block = '' }
    }
    return @{ Level = 'ok'; Line = ('✔  버전 일치 ({0})' -f $sv.Content); Block = '' }
}

# 링크 클라이언트의 동기화 상태: ok = 원본과 .1 단위(앞 두 자리)까지 같음 / need = 다름 / unknown = 확인 불가
#  끝자리(3.8.0 ↔ 3.8.1)만 다른 마이너 업데이트는 클라이언트가 실행 시 스스로 올리므로 일치로 봅니다.
function Get-SyncState($sv, $dv) {
    if (-not $sv -or -not $dv) { return 'unknown' }
    if ($sv.Major -ne $dv.Major -or $sv.Minor -ne $dv.Minor) { return 'need' }
    return 'ok'
}
# [업데이트 후 동기화] 버튼 활성 조건 (준비만 해 둠, 아직 버튼에 적용하지 않음): 동기화가 필요한 클라이언트가 하나라도 있는가
function Test-SyncNeeded {
    foreach ($k in @($script:csync.Keys)) { if ($script:csync[$k] -eq 'need') { return $true } }
    return $false
}

# 링크 가능 여부 판정: 버전(Major.Minor)만 비교합니다. (런처의 LocalGameResources.json 은 링크 클라이언트에서 갱신되지 않아 판정에 쓰지 않음)
#  Level: ok / patch(경고) / minor(링크 불가) / unknown.  Tag = 목록 표시용 짧은 문구
function Get-LinkCompat([string]$srcGame, [string]$dstGame, $keys) {
    $sv = Get-ClientVersion $srcGame; $dv = Get-ClientVersion $dstGame
    $vc = Compare-ClientVersion $sv $dv
    $tag = '확인 불가'
    if ($vc.Level -eq 'ok') { $tag = '버전 일치' } elseif ($vc.Level -eq 'patch') { $tag = '패치 차이' } elseif ($vc.Level -eq 'minor') { $tag = '버전 불일치' }
    return @{ Level = $vc.Level; Line = $vc.Line; Block = $vc.Block; Tag = $tag; Short = '버전 불일치' }
}

# 선택한 폴더가 모두 이미 원본으로 링크되어 있는가 (원본에 폴더가 있는 항목만 대상)
function Test-AlreadyLinked([string]$srcGame, [string]$dstGame, $keys) {
    $n = 0
    foreach ($k in @($keys)) {
        $it = $null
        foreach ($x in $Items) { if ($x.Key -eq $k) { $it = $x } }
        if (-not $it) { continue }
        $sp = Join-Path $srcGame $it.Sub
        if ((Get-LinkInfo $sp).Kind -ne 'dir') { continue }
        $di = Get-LinkInfo (Join-Path $dstGame $it.Sub)
        if ($di.Kind -ne 'link' -or -not $di.TargetExists -or ((Get-NormPath $di.Target) -ine (Get-NormPath $sp))) { return $false }
        $n++
    }
    return ($n -gt 0)
}

# 확인창에 덧붙일 안내 (문제 없으면 빈 문자열)
function Get-VersionNote($srcGame, $dstGame, [string]$name = '', $keys = $null) {
    if (-not $keys) { $keys = @('Paks', 'UHD') }
    $cv = Get-LinkCompat $srcGame $dstGame $keys
    $pre = ''; if ($name) { $pre = '[' + $name + '] ' }
    if ($cv.Level -eq 'patch') { return ($pre + $cv.Line + "`r`n    끝자리만 다른 경우는 허용하지만, 이후 업데이트는 원본 -> 링크 순서로 하세요.`r`n") }
    if ($cv.Level -eq 'unknown') { return ($pre + $cv.Line + "`r`n") }
    return ''
}

# 링크 현황의 칸 상태 (원본 열 제외)
#   $si = 원본 폴더의 Get-LinkInfo 결과 ($null = 원본 없음), $ci = 이 클라이언트 폴더의 Get-LinkInfo 결과
#   Act: ''(선택 불가) / conn(연결만) / disc(해제만) / both(둘 다)
function Get-CellKind($si, $ci, [string]$srcPath, [bool]$exeOk) {
    $srcReal = [bool]($si -and $si.Kind -eq 'dir')
    if (-not $exeOk) { return @{ Kind = 'noexe'; Act = '' } }
    switch ($ci.Kind) {
        'file' { return @{ Kind = 'bad'; Act = '' } }
        'link' {
            $act = 'disc'; if ($srcReal) { $act = 'both' }
            if (-not $ci.TargetExists) { return @{ Kind = 'broken'; Act = $act } }
            if ($srcReal -and ((Get-NormPath $ci.Target) -ieq (Get-NormPath $srcPath))) { return @{ Kind = 'ok'; Act = 'disc' } }
            return @{ Kind = 'other'; Act = $act }
        }
        'dir' {
            if ($srcReal) { return @{ Kind = 'real'; Act = 'conn' } }
            return @{ Kind = 'real0'; Act = '' }
        }
        default {
            if ($srcReal) { return @{ Kind = 'none'; Act = 'conn' } }
            return @{ Kind = 'na'; Act = '' }
        }
    }
}

# 원본 열의 칸 상태
function Get-SrcCellKind($ci, [bool]$exeOk) {
    if (-not $exeOk) { return 'noexe' }
    switch ($ci.Kind) { 'dir' { return 'src' } 'link' { return 'srclink' } default { return 'srcna' } }
}

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}

# 폴더 용량/파일 수 (링크 아닌 실제 폴더 전용, 결과는 캐시)
function Get-DirStat([string]$path) {
    $key = $path.ToLowerInvariant()
    if ($script:sizeCache.ContainsKey($key)) { return $script:sizeCache[$key] }
    $bytes = [long]0; $n = 0
    try {
        foreach ($f in [IO.Directory]::EnumerateFiles($path, '*', [IO.SearchOption]::AllDirectories)) {
            try { $bytes += (New-Object IO.FileInfo $f).Length; $n++ } catch { }
        }
    } catch { }
    $r = @{ Bytes = $bytes; Count = $n }
    $script:sizeCache[$key] = $r
    return $r
}

# ---------------------------------------------------------------- 업데이트 후 동기화 (JSON 버전 값 맞추기)
#  원본 클라이언트를 런처로 먼저 업데이트한 뒤, 링크 쪽은 업데이트·사전 다운로드를 돌리지 않습니다.
#  (링크 쪽 런처가 업데이트를 돌리면 링크된 원본 파일을 패치 재료로 옮겨 원본이 망가집니다.)
#  대신 링크 쪽 런처 JSON의 버전 값만 원본 기준으로 맞추고 [게임 복구]를 돌려, 링크되지 않은 부분만 각자 받게 합니다.
#  appId 등 클라이언트마다 다른 값은 건드리지 않으므로 파일을 통째로 덮어쓰지 않고 해당 필드만 바꿉니다.

$SyncMinPre = [long](1GB)        # launcherDownload 전체가 이 크기 이상이면 사전 다운로드(업데이트 패치)가 있다고 판단
$SyncMinDir = [long](100MB)      # 옮길 대상으로 삼는 버전 폴더의 최소 크기 (전체는 1 GB 이상인데 폴더별로는 흩어진 경우도 잡기 위해 더 작게)

function Read-JsonText([string]$f) {
    $bytes = [IO.File]::ReadAllBytes($f)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $start = 0; if ($bom) { $start = 3 }
    $enc = New-Object Text.UTF8Encoding($false)
    return @{ Text = $enc.GetString($bytes, $start, ($bytes.Length - $start)); Bom = $bom }
}
# 임시 파일에 쓰고 JSON으로 읽히는지 확인한 뒤 교체 (쓰기 도중 실패해도 원본이 반쯤 쓰인 상태로 남지 않게)
function Write-JsonText([string]$f, [string]$text, [bool]$bom) {
    $tmp = $f + '.tmp_sync'
    try {
        [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($bom)))
        [void]((Read-JsonText $tmp).Text | ConvertFrom-Json)
        $done = $false
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            try { [IO.File]::Replace($tmp, $f, $null); $done = $true } catch { }
        }
        if (-not $done) { Move-Item -LiteralPath $tmp -Destination $f -Force -ErrorAction Stop }
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

# 원본의 새 버전 값: Bundles = 번들 이름 → 버전, Packs = 팩 이름(common/uhd) → 버전
function Get-SyncSource([string]$srcGame) {
    $r = @{ Bundles = @{}; Packs = @{} }
    $f = Join-Path $srcGame 'launcherDownloadConfig.json'
    if (Test-Path -LiteralPath $f -PathType Leaf) {
        try {
            $j = (Read-JsonText $f).Text | ConvertFrom-Json
            if ($j.bundles) {
                foreach ($b in $j.bundles.PSObject.Properties) {
                    $v = [string]$b.Value.version
                    if ($v -match '^\d+\.\d+(\.\d+)?$') { $r.Bundles[$b.Name] = $v }
                }
            }
        } catch { }
    }
    foreach ($pk in 'common', 'uhd') {
        $pf = Join-Path $srcGame ('launcherDownloadConfig\' + $pk + '.json')
        if (Test-Path -LiteralPath $pf -PathType Leaf) {
            try {
                $v = [string]((Read-JsonText $pf).Text | ConvertFrom-Json).version
                if ($v -match '^\d+\.\d+(\.\d+)?$') { $r.Packs[$pk] = $v }
            } catch { }
        }
    }
    return $r
}

# 링크 대상 한 곳의 JSON 수정 목록. 반환: @{ Rel; Changes(문구 배열); NewText; Bom } 배열 (바꿀 것이 있는 파일만)
function Get-SyncEdits([string]$dstGame, $sv) {
    $edits = @()
    # 1) launcherDownloadConfig.json : bundles.<이름>.version
    $f1 = Join-Path $dstGame 'launcherDownloadConfig.json'
    if ((Test-Path -LiteralPath $f1 -PathType Leaf) -and $sv.Bundles.Count -gt 0) {
        $t = Read-JsonText $f1; $txt = $t.Text; $ch = @()
        foreach ($name in @($sv.Bundles.Keys)) {
            $rx = '("' + [regex]::Escape($name) + '"\s*:\s*\{[^{}]*?"version"\s*:\s*")([^"]*)(")'
            $m = [regex]::Match($txt, $rx)
            if ($m.Success -and $m.Groups[2].Value -ne $sv.Bundles[$name]) {
                $g = $m.Groups[2]
                $ch += ('bundles.{0}.version  {1} → {2}' -f $name, $g.Value, $sv.Bundles[$name])
                $txt = $txt.Substring(0, $g.Index) + $sv.Bundles[$name] + $txt.Substring($g.Index + $g.Length)
            }
        }
        if ($ch.Count -gt 0) { $edits += @{ Rel = 'launcherDownloadConfig.json'; Changes = $ch; NewText = $txt; Bom = $t.Bom } }
    }
    # 2) launcherDownloadConfig\common.json, uhd.json : version
    foreach ($pk in 'common', 'uhd') {
        $rel = 'launcherDownloadConfig\' + $pk + '.json'
        $pf = Join-Path $dstGame $rel
        if ($sv.Packs.ContainsKey($pk) -and (Test-Path -LiteralPath $pf -PathType Leaf)) {
            $t = Read-JsonText $pf
            $m = [regex]::Match($t.Text, '("version"\s*:\s*")([^"]*)(")')
            if ($m.Success -and $m.Groups[2].Value -ne $sv.Packs[$pk]) {
                $g = $m.Groups[2]
                $txt = $t.Text.Substring(0, $g.Index) + $sv.Packs[$pk] + $t.Text.Substring($g.Index + $g.Length)
                $edits += @{ Rel = $rel; Changes = @(('version  {0} → {1}' -f $g.Value, $sv.Packs[$pk])); NewText = $txt; Bom = $t.Bom }
            }
        }
    }
    # 3) launcherDownload\launcherDownloadConfig.json : isPreDownload / isPreDownloadComplete 를 false 로 (이미 false 여도 무해)
    $rel = 'launcherDownload\launcherDownloadConfig.json'
    $f3 = Join-Path $dstGame $rel
    if (Test-Path -LiteralPath $f3 -PathType Leaf) {
        $t = Read-JsonText $f3
        $rx = '("(?:isPreDownload|isPreDownloadComplete)"\s*:\s*)true'
        $n = [regex]::Matches($t.Text, $rx).Count
        if ($n -gt 0) {
            $txt = [regex]::Replace($t.Text, $rx, '${1}false')
            $edits += @{ Rel = $rel; Changes = @(('isPreDownload / isPreDownloadComplete  true → false  ({0}곳)' -f $n)); NewText = $txt; Bom = $t.Bom }
        }
    }
    return $edits
}

# 수정 결과 검증: edits(아직 쓰지 않은 수정본 포함)를 적용했다고 가정하고 JSON을 읽어 원본 버전과 맞는지 확인.
#  반환: 문제 설명 문자열 배열 (비어 있으면 정상). 정규식이 구조를 못 잡아 조용히 건너뛴 경우도 여기서 드러납니다.
function Test-SyncEdits([string]$dstGame, $sv, $edits = @()) {
    $probs = @()
    $txtOf = {
        param($rel)
        foreach ($e in $edits) { if ($e.Rel -eq $rel) { return $e.NewText } }
        $f = Join-Path $dstGame $rel
        if (Test-Path -LiteralPath $f -PathType Leaf) { return (Read-JsonText $f).Text }
        return $null
    }
    $t1 = & $txtOf 'launcherDownloadConfig.json'
    if ($t1 -and $sv.Bundles.Count -gt 0) {
        try {
            $j = $t1 | ConvertFrom-Json
            foreach ($name in @($sv.Bundles.Keys)) {
                $pr = $null; if ($j.bundles) { $pr = $j.bundles.PSObject.Properties[$name] }
                if ($pr -and ([string]$pr.Value.version) -ne $sv.Bundles[$name]) {
                    $probs += ('launcherDownloadConfig.json 의 bundles.{0}.version 을 {1} 로 맞추지 못했습니다 (현재 {2}).' -f $name, $sv.Bundles[$name], $pr.Value.version)
                }
            }
        } catch { $probs += 'launcherDownloadConfig.json 을 JSON으로 읽을 수 없습니다.' }
    }
    foreach ($pk in 'common', 'uhd') {
        $rel = 'launcherDownloadConfig\' + $pk + '.json'
        $t2 = & $txtOf $rel
        if ($t2 -and $sv.Packs.ContainsKey($pk)) {
            try {
                $v = [string]($t2 | ConvertFrom-Json).version
                if ($v -ne $sv.Packs[$pk]) { $probs += ('{0} 의 version 을 {1} 로 맞추지 못했습니다 (현재 {2}).' -f $rel, $sv.Packs[$pk], $v) }
            } catch { $probs += ($rel + ' 을 JSON으로 읽을 수 없습니다.') }
        }
    }
    $t3 = & $txtOf 'launcherDownload\launcherDownloadConfig.json'
    if ($t3) {
        try { [void]($t3 | ConvertFrom-Json) } catch { $probs += 'launcherDownload\launcherDownloadConfig.json 을 JSON으로 읽을 수 없습니다.' }
        if ([regex]::IsMatch($t3, '"isPreDownload(?:Complete)?"\s*:\s*true')) { $probs += 'launcherDownload\launcherDownloadConfig.json 의 사전 다운로드 플래그가 아직 true 입니다.' }
    }
    return $probs
}

function Get-FreshBytes([string]$path) {
    $b = [long]0
    try {
        foreach ($f in [IO.Directory]::EnumerateFiles($path, '*', [IO.SearchOption]::AllDirectories)) {
            try { $b += (New-Object IO.FileInfo $f).Length } catch { }
        }
    } catch { }
    return $b
}

# 사전 다운로드(업데이트 패치) 감지: launcherDownload 전체 크기가 기준($SyncMinPre) 이상이면 있음.
#  메타 파일은 KB~수 MB, 사전 다운로드는 GB 단위라 크기만으로 구분합니다. JSON의 isPreDownload 값은 참고 정보로만 씁니다.
function Get-PreDownloadInfo([string]$game) {
    $r = @{ Bytes = [long]0; Dirs = @(); Flag = $false; Detected = $false; Unresolved = $false }
    $root = Join-Path $game 'launcherDownload'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $r }
    $r.Bytes = Get-FreshBytes $root
    $r.Detected = ($r.Bytes -ge $SyncMinPre)
    if ($r.Detected) {
        # 옮길 대상: launcherDownload\<common|uhd>\<버전> 및 launcherDownload\<버전> 중 SyncMinDir 이상인 폴더
        $cands = @()
        foreach ($pk in 'common', 'uhd') {
            $pd = Join-Path $root $pk
            if (Test-Path -LiteralPath $pd -PathType Container) {
                foreach ($d in @(Get-ChildItem -LiteralPath $pd -Directory -Force -ErrorAction SilentlyContinue)) { $cands += [pscustomobject]@{ Pack = $pk; Dir = $d } }
            }
        }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($d.Name -in 'common', 'uhd') { continue }
            $cands += [pscustomobject]@{ Pack = 'root'; Dir = $d }
        }
        foreach ($c in $cands) {
            $b = Get-FreshBytes $c.Dir.FullName
            if ($b -ge $SyncMinDir) { $r.Dirs += [pscustomobject]@{ Pack = $c.Pack; Name = $c.Dir.Name; Path = $c.Dir.FullName; Bytes = $b } }
        }
        $r.Unresolved = ($r.Dirs.Count -eq 0)
    }
    $ff = Join-Path $root 'launcherDownloadConfig.json'
    if (Test-Path -LiteralPath $ff -PathType Leaf) {
        try { $r.Flag = [regex]::IsMatch((Read-JsonText $ff).Text, '"isPreDownload(?:Complete)?"\s*:\s*true') } catch { }
    }
    return $r
}

# 사전 다운로드 패치 파일을 삭제하지 않고 <백업 폴더>\predownload\<팩>\<이름>\ 로 옮김 (같은 드라이브라 즉시)
#  OriginResource.json 은 정상 설치에도 있는 메타 파일이므로 원래 자리에 남기고, 나머지 파일만 폴더 구조를 유지하며 옮깁니다.
$SyncKeepNames = @('OriginResource.json')
function Move-PreDownload([string]$bkRoot, $dirs) {
    $moved = @()
    $done = @()      # 이미 옮긴 파일 (원래 경로, 옮긴 경로) - 중간에 실패하면 되돌리기 위해 기록
    try {
        foreach ($d in $dirs) {
            $dp = Join-Path (Join-Path $bkRoot 'predownload') $d.Pack
            New-Item -ItemType Directory -Force -Path $dp | Out-Null
            $dest = Join-Path $dp $d.Name
            if (Test-Path -LiteralPath $dest) { $dest = $dest + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') }
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            $base = $d.Path.TrimEnd('\')
            foreach ($f in @([IO.Directory]::EnumerateFiles($d.Path, '*', [IO.SearchOption]::AllDirectories))) {
                if ($SyncKeepNames -contains [IO.Path]::GetFileName($f)) { continue }
                $rel = $f.Substring($base.Length).TrimStart('\')
                $to = Join-Path $dest $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
                Move-Item -LiteralPath $f -Destination $to -ErrorAction Stop
                $done += [pscustomobject]@{ From = $f; To = $to }
            }
            # 비게 된 하위 폴더 정리 (파일이 남은 폴더는 그대로 둠)
            foreach ($sd in @(Get-ChildItem -LiteralPath $d.Path -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
                if (@(Get-ChildItem -LiteralPath $sd.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $sd.FullName -Force -ErrorAction SilentlyContinue }
            }
            $moved += $dest
        }
    } catch {
        $err = $_
        # 이미 옮긴 파일을 원래 자리로 되돌려 중간 상태를 남기지 않음 (되돌리지 못한 파일은 백업 폴더에 그대로 있음)
        for ($i = $done.Count - 1; $i -ge 0; $i--) {
            try {
                New-Item -ItemType Directory -Force -Path (Split-Path $done[$i].From -Parent) | Out-Null
                Move-Item -LiteralPath $done[$i].To -Destination $done[$i].From -ErrorAction Stop
            } catch { }
        }
        throw $err
    }
    return $moved
}

# 이 클라이언트의 Paks / Resources 가 원본으로 링크되어 있는가
function Test-LinkedToSource([string]$srcGame, [string]$dstGame) {
    foreach ($key in 'Paks', 'Resources') {
        $it = $null
        foreach ($x in $Items) { if ($x.Key -eq $key) { $it = $x } }
        $li = Get-LinkInfo (Join-Path $dstGame $it.Sub)
        if ($li.Kind -ne 'link') { return $false }
        if ((Get-NormPath $li.Target) -ine (Get-NormPath (Join-Path $srcGame $it.Sub))) { return $false }
    }
    return $true
}

$SyncGuide = "참고 : 용량을 더욱 줄이려면 인게임 설정에서 [리소스 정리] 를 한번 돌려주세요. 지난 리소스가 수십 GB 단위로 쌓여 있을 수 있습니다. 링크가 완료된 클라이언트 간에는 한 곳에서만 정리하여도 모두 반영됩니다. 단, '로그인 시 자동 제거 허용' 옵션은 끄는 것을 권장합니다."

# ---------------------------------------------------------------- 링크 해제 (복원 / 복사 / 비워두기)

function Get-FreeSpace([string]$path) {
    try {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($path))
        if (-not $root) { return [long]-1 }
        return ([long](New-Object IO.DriveInfo($root)).AvailableFreeSpace)
    } catch { return [long]-1 }
}

# 해제 대상 목록($acts: Name, Game, It, Path, Bak)을 보고 선택지별 사용 가능 여부와 안내 문구를 만든다 (순수 함수)
function Get-UnlinkPlan($acts) {
    $acts = @($acts)
    $p = @{ Acts = @(); RestoreOk = $true; RestoreInfo = ''; CopyOk = $true; CopyInfo = ''; Bytes = [long]0 }
    $noBak = 0; $noSrc = 0
    $need = @{}
    foreach ($a in $acts) {
        $li = Get-LinkInfo $a.Path
        $src = ''; $srcOk = $false; $bytes = [long]0
        if ($li.Kind -eq 'link' -and $li.Target) {
            $src = [string]$li.Target
            if (Test-Path -LiteralPath $src -PathType Container) { $srcOk = $true; $bytes = [long](Get-DirStat $src).Bytes }
        }
        if (-not $srcOk) { $noSrc++ }
        if (-not $a.Bak) { $noBak++ }
        $root = ''; try { $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($a.Path)) } catch { }
        if (-not $need.ContainsKey($root)) { $need[$root] = [long]0 }
        $need[$root] += $bytes
        $p.Bytes += $bytes
        $p.Acts += @{ Act = $a; Src = $src; SrcOk = $srcOk; Bytes = $bytes }
    }
    # 백업 복원
    if ($noBak -gt 0) { $p.RestoreOk = $false; $p.RestoreInfo = ('백업 없음 ({0}/{1}칸에 없음)' -f $noBak, $acts.Count) }
    else { $p.RestoreInfo = ('백업 {0}/{0} 있음' -f $acts.Count) }
    # 원본에서 복사
    $margin = [long]1GB
    $short = $false; $freeMin = [long]-1
    foreach ($k in $need.Keys) {
        $free = Get-FreeSpace $k
        if ($free -ge 0 -and ($free - $margin) -lt $need[$k]) { $short = $true }
        if ($free -ge 0 -and ($freeMin -lt 0 -or $free -lt $freeMin)) { $freeMin = $free }
    }
    if ($noSrc -gt 0) { $p.CopyOk = $false; $p.CopyInfo = '원본 폴더를 찾을 수 없음 (깨진 링크)' }
    elseif ($short) { $p.CopyOk = $false; $p.CopyInfo = ('여유 공간 부족 (필요 {0} · 여유 {1})' -f (Format-Size $p.Bytes), (Format-Size $freeMin)) }
    else {
        $fr = ''; if ($freeMin -ge 0) { $fr = ' · 여유 공간 ' + (Format-Size $freeMin) }
        $p.CopyInfo = ('복사 {0}{1}' -f (Format-Size $p.Bytes), $fr)
    }
    return $p
}

# 폴더 통째 복사 (진행률/취소 지원, 끝나면 파일 수·크기로 검증). 반환: Ok / Cancelled / Files / Bytes / Err
function Copy-FolderTree([string]$src, [string]$dst, $OnProgress = $null, $IsCancelled = $null) {
    $r = @{ Ok = $false; Cancelled = $false; Files = 0; Bytes = [long]0; Err = '' }
    try {
        $srcFull = [IO.Path]::GetFullPath($src).TrimEnd('\', '/')
        $dstFull = [IO.Path]::GetFullPath($dst).TrimEnd('\', '/')
        $files = New-Object System.Collections.Generic.List[string]
        $total = [long]0
        foreach ($f in [IO.Directory]::EnumerateFiles($srcFull, '*', [IO.SearchOption]::AllDirectories)) {
            $files.Add($f); $total += (New-Object IO.FileInfo $f).Length
        }
        [void][IO.Directory]::CreateDirectory($dstFull)
        foreach ($d in [IO.Directory]::EnumerateDirectories($srcFull, '*', [IO.SearchOption]::AllDirectories)) {
            [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($dstFull, $d.Substring($srcFull.Length).TrimStart('\', '/')))
        }
        $buf = New-Object byte[] 4194304
        $done = [long]0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        foreach ($f in $files) {
            $rel = $f.Substring($srcFull.Length).TrimStart('\', '/')
            $to = [IO.Path]::Combine($dstFull, $rel)
            $in = $null; $out = $null
            try {
                $in = New-Object IO.FileStream($f, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, 1048576)
                $out = New-Object IO.FileStream($to, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 1048576)
                while ($true) {
                    $n = $in.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $out.Write($buf, 0, $n)
                    $done += $n
                    if ($sw.ElapsedMilliseconds -ge 150) {
                        $sw.Restart()
                        if ($OnProgress) { & $OnProgress $done $total $rel }
                        if ($IsCancelled -and (& $IsCancelled)) { $r.Cancelled = $true; return $r }
                    }
                }
            } finally {
                if ($out) { $out.Dispose() }
                if ($in) { $in.Dispose() }
            }
            try { [IO.File]::SetLastWriteTimeUtc($to, [IO.File]::GetLastWriteTimeUtc($f)) } catch { }
            if ($IsCancelled -and (& $IsCancelled)) { $r.Cancelled = $true; return $r }
        }
        if ($OnProgress) { & $OnProgress $done $total '' }
        # 검증: 파일 수와 전체 크기
        $cnt = 0; $sum = [long]0
        foreach ($f in [IO.Directory]::EnumerateFiles($dstFull, '*', [IO.SearchOption]::AllDirectories)) { $cnt++; $sum += (New-Object IO.FileInfo $f).Length }
        $r.Files = $cnt; $r.Bytes = $sum
        if ($cnt -ne $files.Count -or $sum -ne $total) { $r.Err = ('검증 실패: 파일 {0}/{1}개, 크기 {2}/{3}' -f $cnt, $files.Count, $sum, $total); return $r }
        $r.Ok = $true
    } catch { $r.Err = $_.Exception.Message }
    return $r
}

# 칸에 표시할 제목/설명 (순수 함수)
function Get-CellLabel([string]$kind, $li, $stat, [bool]$hasSrc) {
    $sz = ''; if ($stat) { $sz = Format-Size $stat.Bytes }
    switch ($kind) {
        'src'     { return @{ Title = '원본 폴더'; Sub = ('{0} · {1}개' -f $sz, $stat.Count) } }
        'srclink' { return @{ Title = '! 원본이 링크'; Sub = [string]$li.Target } }
        'srcna'   { return @{ Title = '없음'; Sub = '원본에 없는 폴더' } }
        'noexe'   { return @{ Title = '구성 파일 없음'; Sub = '' } }
        'ok'      { return @{ Title = '✔ 원본에 연결됨'; Sub = '링크' } }
        'real'    { return @{ Title = '실제 폴더'; Sub = ('연결 가능 · ' + $sz) } }
        'real0'   { if ($hasSrc) { return @{ Title = '실제 폴더'; Sub = '원본에 없음' } } else { return @{ Title = '실제 폴더'; Sub = '원본을 지정하세요' } } }
        'none'    { return @{ Title = '폴더 없음'; Sub = '링크 생성 가능' } }
        'other'   { if ($hasSrc) { return @{ Title = '! 다른 경로로 링크됨'; Sub = [string]$li.Target } } else { return @{ Title = '링크됨'; Sub = [string]$li.Target } } }
        'broken'  { return @{ Title = '✖ 깨진 링크'; Sub = '대상 경로를 찾을 수 없음' } }
        'bad'     { return @{ Title = '! 파일이 있음'; Sub = '링크 불가' } }
        default   { return @{ Title = '—'; Sub = '' } }
    }
}

# 선택한 칸들의 동작 가능 여부: none / conn / disc / either / mixed
function Get-SelMode([string[]]$acts) {
    $hasConn = ($acts -contains 'conn'); $hasDisc = ($acts -contains 'disc'); $hasBoth = ($acts -contains 'both')
    if ($hasConn -and $hasDisc) { return 'mixed' }
    if ($hasConn) { return 'conn' }
    if ($hasDisc) { return 'disc' }
    if ($hasBoth) { return 'either' }
    return 'none'
}

# ---------------------------------------------------------------- 클라이언트 탐색

function Test-ClientRoot([string]$p) {
    $st = Get-State $p
    return [bool]($st -and ($st.Launcher -or $st.Exe))
}

# 이 클라이언트의 Paks / Resources / UHD 상태 요약 (탐색 결과용)
# 필수 폴더(Paks/Resources) 중 링크 상태인 폴더의 키 목록. 비어 있으면 실제 파일을 가진 클라이언트(원본 가능)
function Get-LinkedFixed([string]$game) {
    $out = @()
    if (-not $game) { return $out }
    foreach ($it in $Items) {
        if ($it.Fixed -and (Get-LinkInfo (Join-Path $game $it.Sub)).Kind -eq 'link') { $out += $it.Key }
    }
    return $out
}

function Get-ClientAnalysis([string]$root) {
    $st = Get-State $root
    $r = @{ Root = $st.Root; Game = $st.Game; Launcher = $st.Launcher; Exe = $st.Exe; Text = '—'; Color = 'dim'
            LinkGames = @(); Bytes = [long]0; DirN = 0; LinkN = 0; M = 0; Ver = $null; Linked = $false }
    if (-not $st.Exe) { return $r }
    $r.Ver = Get-ClientVersion $st.Game
    $r.Linked = (@(Get-LinkedFixed $st.Game).Count -gt 0)
    foreach ($key in 'Paks', 'Resources', 'UHD') {
        $it = $null
        foreach ($x in $Items) { if ($x.Key -eq $key) { $it = $x } }
        $p = Join-Path $st.Game $it.Sub
        $li = Get-LinkInfo $p
        if ($li.Kind -eq 'dir') { $r.DirN++; $r.M++; $r.Bytes += (Get-DirStat $p).Bytes }
        elseif ($li.Kind -eq 'link') {
            $r.LinkN++; $r.M++
            $g = Get-GameFromTarget $li.Target $it
            if ($g -and ($r.LinkGames -notcontains $g)) { $r.LinkGames += $g }
        }
    }
    if ($r.M -eq 0) { $r.Text = '대상 폴더 없음' }
    elseif ($r.LinkN -eq $r.M) {
        $to = ''; if ($r.LinkGames.Count -gt 0) { $to = ' → ' + $r.LinkGames[0] }
        $r.Text = ('링크 {0}/{1}{2}' -f $r.LinkN, $r.M, $to); $r.Color = 'ok'
    }
    elseif ($r.DirN -eq $r.M) { $r.Text = ('실제 폴더 {0}/{1} · {2}' -f $r.DirN, $r.M, (Format-Size $r.Bytes)); $r.Color = 'normal' }
    else { $r.Text = ('링크 {0} · 실제 폴더 {1}' -f $r.LinkN, $r.DirN); $r.Color = 'warn' }
    return $r
}

# 탐색 결과 행(Already, An 사용)에 제안 역할을 채운다. 행: @{ Already; An; Role; Tag; Sub }
function Set-RoleSuggestions($rows, [bool]$hasSrc, [string]$srcGame) {
    $live = @($rows | Where-Object { -not $_.Already -and -not $_.Flat })
    foreach ($r in $rows) {
        if ($r.Flat) { $r.Role = ''; $r.Tag = '구조 다름'; $r.Sub = '3.7 Steam 구조 · 링크 불가'; continue }
        if ($r.Already) { $r.Role = ''; $r.Tag = '이미 등록됨'; $r.Sub = ''; continue }
        $r.Role = 'link'; $r.Tag = '링크 대상'; $r.Sub = ''
        if (-not $r.An.Exe) { $r.Sub = '구성 파일 없음 · 점검 필요' }
    }
    if ($hasSrc) {
        foreach ($r in $live) {
            if ($r.An.Exe) {
                if ($srcGame -and ($r.An.LinkGames -contains $srcGame)) { $r.Sub = '이미 원본에 연결됨' } else { $r.Sub = '원본에 연결 가능' }
            }
        }
        return
    }
    $srcRow = $null
    $refCount = 0
    foreach ($r in $live) {
        $c = 0
        foreach ($o in $live) { if ($o -ne $r -and ($o.An.LinkGames -contains $r.An.Game)) { $c++ } }
        if ($c -gt 0 -and $c -gt $refCount -and -not $r.An.Linked) { $srcRow = $r; $refCount = $c }
    }
    if ($srcRow) { $srcRow.Sub = ('{0}개 클라이언트가 이 폴더에 연결됨' -f $refCount) }
    else {
        $best = [long]-1
        foreach ($r in $live) {
            if ($r.An.Exe -and $r.An.M -gt 0 -and $r.An.DirN -eq $r.An.M -and $r.An.Bytes -gt $best) { $srcRow = $r; $best = $r.An.Bytes }
        }
        if ($srcRow) { $srcRow.Sub = '실제 폴더를 가진 클라이언트 중 가장 큼' }
    }
    if ($srcRow) { $srcRow.Role = 'src'; $srcRow.Tag = '원본 후보' }
    foreach ($r in $live) {
        if ($r -ne $srcRow -and $r.An.Exe -and $srcRow) {
            if ($r.An.LinkGames -contains $srcRow.An.Game) { $r.Sub = '이미 원본 후보에 연결됨' } else { $r.Sub = '원본 후보에 연결 가능' }
        }
    }
}

# 탐색 결과에서 "원본으로 보이는" 행을 고른다. 반환: @{ Row; Why } 또는 $null
#  1) 등록된 원본 클라이언트  2) 다른 클라이언트들이 링크로 가리키는 폴더  3) 실제 폴더를 모두 가진 것 중 가장 큰 것
function Find-SourceRow($rows, [string]$regSrcRoot) {
    $live = @($rows | Where-Object { -not $_.Flat -and $_.An -and -not $_.An.Linked })
    if ($regSrcRoot) {
        foreach ($r in $live) { if ((Get-NormPath $r.Root) -ieq (Get-NormPath $regSrcRoot)) { return @{ Row = $r; Why = '등록된 원본' } } }
    }
    $best = $null; $refCount = 0
    foreach ($r in $live) {
        $c = 0
        foreach ($o in $live) { if ($o -ne $r -and ($o.An.LinkGames -contains $r.An.Game)) { $c++ } }
        if ($c -gt $refCount) { $best = $r; $refCount = $c }
    }
    if ($best) { return @{ Row = $best; Why = ('{0}개가 이 폴더에 링크됨' -f $refCount) } }
    $bytes = [long]-1
    foreach ($r in $live) {
        if ($r.An.Exe -and $r.An.M -gt 0 -and $r.An.DirN -eq $r.An.M -and $r.An.Bytes -gt $bytes) { $best = $r; $bytes = $r.An.Bytes }
    }
    if ($best) { return @{ Row = $best; Why = '실제 폴더를 가진 것 중 가장 큼' } }
    return $null
}

# 1) 흔한 위치 (자동 감지)
function Find-ClientsQuick {
    $found = New-Object System.Collections.Generic.List[string]
    $drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })
    foreach ($d in $drives) {
        $r = $d.RootDirectory.FullName
        foreach ($sub in @('Wuthering Waves', 'Wuthering Waves Game', 'Program Files\Wuthering Waves', 'Program Files (x86)\Wuthering Waves',
                           'Games\Wuthering Waves', 'Game\Wuthering Waves', 'Games\Kuro Games\Wuthering Waves', '명조',
                           'Program Files\Epic Games\WutheringWavesj3oFh', 'Epic Games\WutheringWavesj3oFh', 'WutheringWavesj3oFh')) {
            $p = [IO.Path]::Combine($r, $sub)
            if (Test-ClientRoot $p) {
                $root = (Get-State $p).Root
                if (-not ($found | Where-Object { $_ -ieq $root })) { $found.Add($root) }
            }
        }
    }
    return $found.ToArray()
}

# 2) Steam 라이브러리
function Find-SteamLibraries {
    $found = New-Object System.Collections.Generic.List[string]
    $steam = $null
    try { $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { }
    if (-not $steam) { try { $steam = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch { } }
    if ($steam) {
        $steam = ($steam -replace '/', '\').TrimEnd('\')
        $vdf = [IO.Path]::Combine($steam, 'steamapps\libraryfolders.vdf')
        if (Test-Path -LiteralPath $vdf) {
            $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
            foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                $p = ($m.Groups[1].Value -replace '\\\\', '\').TrimEnd('\')
                if ($found -notcontains $p) { $found.Add($p) }
            }
        }
        if ($found.Count -eq 0) { $found.Add($steam) }
    }
    return $found.ToArray()
}

function Find-ClientsSteam {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($lib in @(Find-SteamLibraries)) {
        $apps = $lib
        if ([IO.Path]::GetFileName($lib.TrimEnd('\')) -ine 'steamapps') { $apps = [IO.Path]::Combine($lib, 'steamapps') }
        $names = New-Object System.Collections.Generic.List[string]
        $acf = [IO.Path]::Combine($apps, 'appmanifest_3513350.acf')
        if (Test-Path -LiteralPath $acf) {
            try {
                $m = [regex]::Match((Get-Content -LiteralPath $acf -Raw -Encoding UTF8), '"installdir"\s+"([^"]+)"')
                if ($m.Success -and $m.Groups[1].Value -and $m.Groups[1].Value -notmatch '[\\/]' -and $m.Groups[1].Value -ne '..') { $names.Add($m.Groups[1].Value) }
            } catch { }
        }
        if ($names -notcontains 'Wuthering Waves') { $names.Add('Wuthering Waves') }
        foreach ($n in $names) {
            $p = [IO.Path]::Combine($apps, 'common', $n)
            if (Test-ClientRoot $p) {
                $root = (Get-State $p).Root
                if (-not ($found | Where-Object { $_ -ieq $root })) { $found.Add($root) }
            }
        }
    }
    return $found.ToArray()
}

# Steam 3.7 구조(launcher.exe 없이 설치 폴더 바로 아래에 Client 폴더가 있는 형태)도 찾아서 "구조 다름"으로 표시
function Find-ClientsSteamFlat {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($lib in @(Find-SteamLibraries)) {
        $apps = $lib
        if ([IO.Path]::GetFileName($lib.TrimEnd('\')) -ine 'steamapps') { $apps = [IO.Path]::Combine($lib, 'steamapps') }
        $names = New-Object System.Collections.Generic.List[string]
        $acf = [IO.Path]::Combine($apps, 'appmanifest_3513350.acf')
        if (Test-Path -LiteralPath $acf) {
            try {
                $m = [regex]::Match((Get-Content -LiteralPath $acf -Raw -Encoding UTF8), '"installdir"\s+"([^"]+)"')
                if ($m.Success -and $m.Groups[1].Value -and $m.Groups[1].Value -notmatch '[\\/]' -and $m.Groups[1].Value -ne '..') { $names.Add($m.Groups[1].Value) }
            } catch { }
        }
        if ($names -notcontains 'Wuthering Waves') { $names.Add('Wuthering Waves') }
        foreach ($n in $names) {
            $p = [IO.Path]::Combine($apps, 'common', $n)
            if (Test-ClientRoot $p) { continue }
            if ((Test-Path -LiteralPath (Join-Path $p 'Client') -PathType Container) -or (Test-Path -LiteralPath (Join-Path $p 'Wuthering Waves.exe') -PathType Leaf)) {
                if (-not ($found | Where-Object { $_ -ieq $p })) { $found.Add($p) }
            }
        }
    }
    return $found.ToArray()
}

# 3) 정밀 탐색 (드라이브 루트부터 키워드가 들어간 폴더를 단계별로 확인, 읽기만 함)
$script:DeepSeen = 0
function Find-ClientsDeep {
    param([string[]]$Roots, [string[]]$Keywords, [int]$MaxDepth = 4, [scriptblock]$OnFound, [scriptblock]$OnTick, [scriptblock]$IsCancelled)
    $skipNames = @('Windows', '$Recycle.Bin', 'System Volume Information', 'ProgramData', 'Recovery', 'PerfLogs',
                   'Config.Msi', '$WinREAgent', 'Documents and Settings', 'AppData', 'node_modules', '.git')
    $found = New-Object System.Collections.Generic.List[string]
    $addHit = {
        param($p)
        $root = (Get-State $p).Root
        if (-not ($found | Where-Object { $_ -ieq $root })) {
            $found.Add($root)
            if ($OnFound) { & $OnFound $root }
        }
    }
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($r in $Roots) { if ($r) { $queue.Enqueue(@($r, 0)) } }
    $seen = 0
    while ($queue.Count -gt 0) {
        if ($IsCancelled -and (& $IsCancelled)) { break }
        $item = $queue.Dequeue()
        $dir = [string]$item[0]; $depth = [int]$item[1]
        $seen++
        if ($OnTick -and ($seen % 40 -eq 0)) { & $OnTick $dir $seen }
        $children = $null
        try { $children = [IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($c in $children) {
            $name = [IO.Path]::GetFileName($c)
            if ($skipNames -contains $name) { continue }
            $isLink = $false
            try { $isLink = (([IO.File]::GetAttributes($c) -band [IO.FileAttributes]::ReparsePoint) -ne 0) } catch { $isLink = $true }
            if ($isLink) { continue }
            $match = $false
            foreach ($k in $Keywords) {
                if ($k -and $name.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $match = $true; break }
            }
            if ($match) {
                if (Test-ClientRoot $c) { & $addHit $c; continue }
                $sub = $null
                try { $sub = [IO.Directory]::GetDirectories($c) } catch { }
                $got = $false
                if ($sub) { foreach ($s in $sub) { if (Test-ClientRoot $s) { & $addHit $s; $got = $true } } }
                if ($got) { continue }
            }
            if (($depth + 1) -lt $MaxDepth) { $queue.Enqueue(@($c, ($depth + 1))) }
        }
    }
    $script:DeepSeen = $seen
    return $found.ToArray()
}


if ($NoGui) { return }

# ---------------------------------------------------------------- STA 보장

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    exit
}

# ---------------------------------------------------------------- 네이티브 도우미 (폴더 선택 대화상자 / 관리자 권한 드래그 허용)

if (-not ('WWCLNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WWCLNative
{
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool ChangeWindowMessageFilterEx(IntPtr hWnd, uint msg, uint action, IntPtr pChangeFilterStruct);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    // 관리자 권한 창이 일반 권한 탐색기의 드롭을 받을 수 있게 메시지 필터를 연다 (UIPI)
    public static void AllowDropMessages(IntPtr h)
    {
        uint[] msgs = new uint[] { 0x233, 0x4A, 0x49 };
        foreach (uint m in msgs)
        {
            try { ChangeWindowMessageFilterEx(h, m, 1, IntPtr.Zero); } catch { }
        }
    }
}

public static class WWCLFolderPicker
{
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    class FileOpenDialogRCW { }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
        void GetResults(out IntPtr ppenum);
        void GetSelectedItems(out IntPtr ppsai);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid, out IShellItem item);

    // 탐색기 방식 폴더 선택. 취소하면 null
    public static string Pick(IntPtr owner, string title, string initialDir)
    {
        IFileOpenDialog dlg = (IFileOpenDialog)new FileOpenDialogRCW();
        uint opts;
        dlg.GetOptions(out opts);
        dlg.SetOptions(opts | 0x20 | 0x40 | 0x800);   // PICKFOLDERS | FORCEFILESYSTEM | PATHMUSTEXIST
        dlg.SetTitle(title);
        if (!string.IsNullOrEmpty(initialDir) && System.IO.Directory.Exists(initialDir))
        {
            try
            {
                Guid iid = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
                IShellItem si;
                SHCreateItemFromParsingName(initialDir, IntPtr.Zero, ref iid, out si);
                dlg.SetFolder(si);
            }
            catch { }
        }
        int hr = dlg.Show(owner);
        if (hr != 0) return null;
        IShellItem res;
        dlg.GetResult(out res);
        string path;
        res.GetDisplayName(0x80058000, out path);     // SIGDN_FILESYSPATH
        return path;
    }
}
'@
}
try { [void][WWCLNative]::SetProcessDPIAware() } catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- 디자인 도우미

$cBg      = [Drawing.Color]::FromArgb(243, 243, 243)
$cCard    = [Drawing.Color]::White
$cBorder  = [Drawing.Color]::FromArgb(228, 228, 228)
$cText    = [Drawing.Color]::FromArgb(32, 32, 32)
$cSub     = [Drawing.Color]::FromArgb(96, 96, 96)
$cAccent  = [Drawing.Color]::FromArgb(0, 103, 192)
$cDash    = [Drawing.Color]::FromArgb(154, 160, 166)
$cDanger  = [Drawing.Color]::FromArgb(196, 43, 28)
$cOk      = [Drawing.Color]::FromArgb(16, 124, 16)
$fontBase = New-Object Drawing.Font('Malgun Gothic', 9.5)
$fontBold = New-Object Drawing.Font('Malgun Gothic', 10, [Drawing.FontStyle]::Bold)
$fontNum = New-Object Drawing.Font('Malgun Gothic', 9, [Drawing.FontStyle]::Bold)
$fontTitle = New-Object Drawing.Font('Malgun Gothic', 11.5, [Drawing.FontStyle]::Bold)
$fontBig  = New-Object Drawing.Font('Malgun Gothic', 13)
$fontPath = New-Object Drawing.Font('Malgun Gothic', 10.5)
$fontSmall = New-Object Drawing.Font('Malgun Gothic', 9)

function Set-DoubleBuffered($c) {
    try {
        [Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($c, $true, $null)
    } catch { }
}

function Get-RoundPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $gp = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $gp.AddArc($x, $y, $d, $d, 180, 90)
    $gp.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $gp.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $gp.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    return $gp
}

function New-Card {
    $p = New-Object Windows.Forms.Panel
    $p.BackColor = $cBg
    Set-DoubleBuffered $p
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'
        $gp = Get-RoundPath 0.5 0.5 ($s.Width - 2) ($s.Height - 2) (S 8)
        $br = New-Object Drawing.SolidBrush($cCard)
        $pen = New-Object Drawing.Pen($cBorder, 1)
        $g.FillPath($br, $gp); $g.DrawPath($pen, $gp)
        $br.Dispose(); $pen.Dispose(); $gp.Dispose()
    })
    $form.Controls.Add($p)
    return $p
}

function New-Text([string]$text, $font, $color, $parent) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = $cCard; $l.AutoSize = $false
    $parent.Controls.Add($l)
    return $l
}

function Get-TextHeight($label, [int]$width) {
    $sz = $label.GetPreferredSize((New-Object Drawing.Size($width, 0)))
    return [Math]::Max($sz.Height, 20)
}

# 안내 박스 (흰 배경 + 왼쪽 색 포인트 + 아이콘 줄별 표시)
function New-NoteBox($parent, [string[]]$lines, [string]$icon, $accent, $unused1, $unused2) {
    $p = New-Object Windows.Forms.Panel
    $p.BackColor = $cCard
    Set-DoubleBuffered $p
    $isWarn = ($icon -eq '⚠')
    $tc = [Drawing.Color]::FromArgb(52, 68, 92); $bc = [Drawing.Color]::FromArgb(213, 220, 230)
    if ($isWarn) { $tc = [Drawing.Color]::FromArgb(90, 42, 42); $bc = [Drawing.Color]::FromArgb(230, 211, 211) }
    $p.Tag = @{ Lines = $lines; Icon = $icon; Accent = $accent; Text = $tc; Border = $bc }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $t = $s.Tag
        $g.Clear($s.Parent.BackColor)
        $gp = Get-RoundPath 0.5 0.5 ($s.Width - 2) ($s.Height - 2) (S 8)
        $g.SetClip($gp)
        $ab = New-Object Drawing.SolidBrush($t.Accent); $g.FillRectangle($ab, 0, 0, (S 5), $s.Height); $ab.Dispose()
        $wb = New-Object Drawing.SolidBrush([Drawing.Color]::White); $g.FillRectangle($wb, (S 5), 0, ($s.Width - (S 5)), $s.Height); $wb.Dispose()
        $g.ResetClip()
        $pen = New-Object Drawing.Pen($t.Border, 1); $g.DrawPath($pen, $gp); $pen.Dispose(); $gp.Dispose()
        $y = S 8
        foreach ($ln in $t.Lines) {
            [Windows.Forms.TextRenderer]::DrawText($g, $t.Icon, $s.Font, (New-Object Drawing.Rectangle((S 16), $y, (S 24), (S 26))), $t.Accent, [Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter,SingleLine')
            [Windows.Forms.TextRenderer]::DrawText($g, $ln, $s.Font, (New-Object Drawing.Rectangle((S 44), $y, ($s.Width - (S 56)), (S 26))), $t.Text, [Windows.Forms.TextFormatFlags]'Left,VerticalCenter,SingleLine,EndEllipsis')
            $y += S 26
        }
    })
    $p.Add_Resize({ param($s, $e) $s.Invalidate() })
    $parent.Controls.Add($p)
    return $p
}

# 켜기/끄기 스위치 (Tag = @{On; Cb})
function New-Toggle([string]$text, [bool]$on, [scriptblock]$cb, $parent) {
    $t = New-Object Windows.Forms.Panel
    $t.Cursor = 'Hand'; $t.BackColor = $cCard
    Set-DoubleBuffered $t
    $t.Tag = @{ On = $on; Cb = $cb; Text = $text }
    $t.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $k = $script:sc
        $on = $s.Tag.On
        $g.ScaleTransform($k, $k)
        $pill = Get-RoundPath 1 4 40 22 11
        if ($on) {
            $br = New-Object Drawing.SolidBrush($cAccent); $g.FillPath($br, $pill); $br.Dispose()
            $kb = New-Object Drawing.SolidBrush([Drawing.Color]::White); $g.FillEllipse($kb, 22, 7, 16, 16); $kb.Dispose()
        } else {
            $pen = New-Object Drawing.Pen($cSub, 1.5); $g.DrawPath($pen, $pill); $pen.Dispose()
            $kb = New-Object Drawing.SolidBrush($cSub); $g.FillEllipse($kb, 5, 9, 12, 12); $kb.Dispose()
        }
        $pill.Dispose()
        $g.ResetTransform()
        $x0 = [int](52 * $k)
        $r = New-Object Drawing.Rectangle($x0, 0, ($s.Width - $x0), $s.Height)
        [Windows.Forms.TextRenderer]::DrawText($g, $s.Tag.Text, $fontBase, $r, $cText, [Windows.Forms.TextFormatFlags]'VerticalCenter,Left,SingleLine')
    })
    $t.Add_Click({
        param($s, $e)
        if (-not $s.Enabled) { return }
        $s.Tag.On = -not $s.Tag.On
        $s.Invalidate()
        if ($s.Tag.Cb) { & $s.Tag.Cb }
    })
    $parent.Controls.Add($t)
    return $t
}

function New-Pill([string]$text, $color, $parent) {
    $p = New-Object Windows.Forms.Panel
    $p.BackColor = $parent.BackColor
    Set-DoubleBuffered $p
    $p.Tag = @{ Text = $text; Color = $color }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $t = $s.Tag
        $g.Clear($s.Parent.BackColor)
        $gp = Get-RoundPath 0.5 0.5 ($s.Width - 1) ($s.Height - 1) ([float]($s.Height / 2))
        $br = New-Object Drawing.SolidBrush($t.Color); $g.FillPath($br, $gp); $br.Dispose(); $gp.Dispose()
        [Windows.Forms.TextRenderer]::DrawText($g, $t.Text, $fontSmall, (New-Object Drawing.Rectangle(0, 0, $s.Width, $s.Height)), [Drawing.Color]::White, [Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter,SingleLine')
    })
    $parent.Controls.Add($p)
    return $p
}

function New-FlowArrow($parent) {
    $p = New-Object Windows.Forms.Panel
    $p.BackColor = $cBg
    Set-DoubleBuffered $p
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $g.Clear($s.Parent.BackColor)
        $cx = [float]($s.Width / 2); $cy = [float]($s.Height / 2); $u = [float]$script:sc
        $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(127, 169, 220), [float](2.4 * $u)); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
        $g.DrawLines($pen, [Drawing.PointF[]]@((New-Object Drawing.PointF(($cx - 5 * $u), ($cy - 8 * $u))), (New-Object Drawing.PointF(($cx + 5 * $u), $cy)), (New-Object Drawing.PointF(($cx - 5 * $u), ($cy + 8 * $u)))))
        $pen.Dispose()
    })
    $p.Add_Resize({ param($s, $e) $s.Invalidate() })
    $parent.Controls.Add($p)
    return $p
}

function New-Button([string]$text, [bool]$primary, $parent) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Font = $fontBase; $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'
    $b.FlatAppearance.BorderSize = 0
    $b.FlatAppearance.MouseOverBackColor = $b.BackColor; $b.FlatAppearance.MouseDownBackColor = $b.BackColor
    $bgc = if ($parent -is [Windows.Forms.Form]) { $cBg } else { $cCard }
    $b.BackColor = $bgc
    $b.Tag = @{ Primary = $primary; Hover = $false; Bg = $bgc; Style = ''; Num = ''; Icon = '' }
    $b.Add_MouseEnter({ param($s, $e) $s.Tag.Hover = $true; $s.Invalidate() })
    $b.Add_MouseLeave({ param($s, $e) $s.Tag.Hover = $false; $s.Invalidate() })
    $b.Add_EnabledChanged({ param($s, $e) $s.Invalidate() })
    $b.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $t = $s.Tag
        $g.Clear($t.Bg)
        if (-not $s.Enabled) { $fill = [Drawing.Color]::FromArgb(233, 233, 233); $line = $fill; $fore = [Drawing.Color]::FromArgb(150, 150, 150) }
        elseif ($t.Style -eq 'soft') {
            $fill = if ($t.Hover) { [Drawing.Color]::FromArgb(214, 230, 249) } else { [Drawing.Color]::FromArgb(232, 241, 252) }
            $line = $cAccent; $fore = $cAccent
        }
        elseif ($t.Style -eq 'mid') {
            $fill = if ($t.Hover) { [Drawing.Color]::FromArgb(0, 90, 170) } else { $cAccent }
            $line = $fill; $fore = [Drawing.Color]::White
        }
        elseif ($t.Style -eq 'deep') {
            $fill = if ($t.Hover) { [Drawing.Color]::FromArgb(0, 58, 120) } else { [Drawing.Color]::FromArgb(0, 74, 148) }
            $line = $fill; $fore = [Drawing.Color]::White
        }
        elseif ($t.Style -eq 'danger') {
            $fill = if ($t.Hover) { [Drawing.Color]::FromArgb(168, 30, 30) } else { [Drawing.Color]::FromArgb(198, 40, 40) }
            $line = $fill; $fore = [Drawing.Color]::White
        }
        elseif ($t.Primary) {
            $fill = if ($t.Hover) { [Drawing.Color]::FromArgb(0, 90, 170) } else { $cAccent }
            $line = $fill; $fore = [Drawing.Color]::White
        } else {
            $fill = if ($t.Hover) { [Drawing.Color]::FromArgb(243, 247, 252) } else { $cCard }
            $line = if ($t.Hover) { $cAccent } else { $cDash }; $fore = $cText
        }
        $gp = Get-RoundPath 0.5 0.5 ($s.Width - 2) ($s.Height - 2) (S 8)
        $br = New-Object Drawing.SolidBrush($fill); $pen = New-Object Drawing.Pen($line, 1)
        $g.FillPath($br, $gp); $g.DrawPath($pen, $gp)
        $br.Dispose(); $pen.Dispose(); $gp.Dispose()
        $r = New-Object Drawing.Rectangle(0, 0, $s.Width, $s.Height)
        if ($t.Num -or $t.Icon) {
            $u = [float]$script:sc; $d = [int](24 * $u); $gap = [int](10 * $u)
            $tw = [Windows.Forms.TextRenderer]::MeasureText($s.Text, $s.Font).Width
            $x0 = [int](($s.Width - ($d + $gap + $tw)) / 2); $y0 = [int](($s.Height - $d) / 2)
            if ($t.Num) {
                $cf = [Drawing.Color]::White; $cn = $fill
                if (-not $s.Enabled) { $cf = [Drawing.Color]::FromArgb(205, 205, 205); $cn = [Drawing.Color]::White }
                elseif ($t.Style -eq 'soft') { $cf = $cAccent; $cn = [Drawing.Color]::White }
                $cb = New-Object Drawing.SolidBrush($cf); $g.FillEllipse($cb, $x0, $y0, $d, $d); $cb.Dispose()
                [Windows.Forms.TextRenderer]::DrawText($g, [string]$t.Num, $fontNum, (New-Object Drawing.Rectangle($x0, $y0, $d, $d)), $cn, [Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter,SingleLine,NoPadding')
            } else {
                $ip = New-Object Drawing.Pen($fore, [float](2.2 * $u)); $ip.StartCap = 'Round'; $ip.EndCap = 'Round'; $ip.LineJoin = 'Round'
                $ic = New-Object Drawing.PointF(($x0 + $d / 2), ($y0 + $d / 2)); $rad = 8.5 * $u
                $g.DrawArc($ip, ($ic.X - $rad), ($ic.Y - $rad), (2 * $rad), (2 * $rad), 90, -250)
                $ang = 200 * [Math]::PI / 180
                $tx = $ic.X + $rad * [Math]::Cos($ang); $ty = $ic.Y + $rad * [Math]::Sin($ang)
                $dx = [Math]::Sin($ang) * -1 * -1; $dy = -[Math]::Cos($ang)
                $dx = [Math]::Sin($ang); $dy = -[Math]::Cos($ang)
                $px = -$dy; $py = $dx
                $h = 5 * $u
                $g.DrawLines($ip, [Drawing.PointF[]]@((New-Object Drawing.PointF(($tx - $dx * $h + $px * $h), ($ty - $dy * $h + $py * $h))), (New-Object Drawing.PointF($tx, $ty)), (New-Object Drawing.PointF(($tx - $dx * $h - $px * $h), ($ty - $dy * $h - $py * $h)))))
                $ip.Dispose()
            }
            $r = New-Object Drawing.Rectangle(($x0 + $d + $gap), 0, ($s.Width - ($x0 + $d + $gap)), $s.Height)
            [Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, $r, $fore, [Windows.Forms.TextFormatFlags]'Left,VerticalCenter,SingleLine')
        } else {
            [Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, $r, $fore, [Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter,SingleLine')
        }
    })
    $parent.Controls.Add($b)
    return $b
}

# ---------------------------------------------------------------- 상태

$script:paths = @{ src = ''; dst = '' }
$script:info  = @{ src = $null; dst = $null }
$script:ok2 = $false     # [링크 생성] ②(런처 [게임 복구]·실행 확인)를 눌렀는가
$script:busy = $false
$script:undoStack = @()
$script:runRec = @()
$script:lastLog = $null
$script:logFile = $null
$script:autoSize = $true
$script:resetChecks = $true
$script:shownDone = $false

$form = New-Object Windows.Forms.Form
$form.Text = "명조 클라이언트 심볼릭 링크 도구 v$ToolVersion"
$form.Font = $fontBase
$form.BackColor = $cBg
$form.AutoScaleMode = 'None'
$gtmp = $form.CreateGraphics(); $script:sc = $gtmp.DpiX / 96.0; $gtmp.Dispose()
function S([double]$n) { return [int]($n * $script:sc) }
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.ClientSize = New-Object Drawing.Size((S 940), (S 900))
$form.MinimumSize = New-Object Drawing.Size((S 900), (S 600))
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
Set-DoubleBuffered $form

# ---- 상단 바
$cardTop = New-Card
$tglTop = New-Toggle '항상 위' $true { $form.TopMost = $tglTop.Tag.On } $cardTop
$btnLog = New-Button '최근 로그 열기' $false $cardTop

# ---- 원본 / 대상 카드
$cardSrc = New-Card
$cardDst = New-Card
$lblArrow = New-Object Windows.Forms.Label
$lblArrow.Text = '→'; $lblArrow.Font = New-Object Drawing.Font('Malgun Gothic', 16); $lblArrow.ForeColor = $cSub
$lblArrow.BackColor = $cBg; $lblArrow.TextAlign = 'MiddleCenter'
$form.Controls.Add($lblArrow)

$sides = @{}
foreach ($pair in @(@('src', '원본', $cardSrc, '링크가 가리킬 실제 파일이 있는 런처의 경로'), @('dst', '대상', $cardDst, '링크를 걸 대상 런처의 경로'))) {
    $side = $pair[0]; $card = $pair[2]
    $title = New-Pill $(if ($side -eq 'src') { '원본' } else { '링크' }) $(if ($side -eq 'src') { $cAccent } else { $cOk }) $card
    $subt = New-Text $pair[3] $fontBase $cSub $card
    $btn = New-Button '찾아보기' $false $card
    $box = New-Object Windows.Forms.Panel
    $box.BackColor = $cCard; $box.Cursor = 'Hand'
    Set-DoubleBuffered $box
    $box.Tag = @{ Side = $side; Drag = $false; Label = $pair[1] }
    $card.Controls.Add($box)
    $sides[$side] = @{ Title = $title; Sub = $subt; Btn = $btn; Box = $box; Card = $card }
}

# 드롭 박스 그리기
foreach ($side in 'src', 'dst') {
    $sides[$side].Box.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $tag = $s.Tag
        $fill = if ($tag.Drag) { [Drawing.Color]::FromArgb(236, 245, 255) } else { $cCard }
        $line = if ($tag.Drag) { $cAccent } else { $cDash }
        $gp = Get-RoundPath 2 2 ($s.Width - 5) ($s.Height - 5) (S 12)
        $br = New-Object Drawing.SolidBrush($fill)
        $pen = New-Object Drawing.Pen($line, 2)
        $pen.DashStyle = [Drawing.Drawing2D.DashStyle]::Dash
        $g.FillPath($br, $gp); $g.DrawPath($pen, $gp)
        $br.Dispose(); $pen.Dispose(); $gp.Dispose()
        $inf = $script:info[$tag.Side]
        $flags = [Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter,WordBreak'
        if (-not $inf) {
            $r = New-Object Drawing.Rectangle((S 12), (S 10), ($s.Width - (S 24)), ($s.Height - (S 52)))
            [Windows.Forms.TextRenderer]::DrawText($g, '폴더를 여기에 드롭하세요', $fontBig, $r, $cText, $flags)
            $r2 = New-Object Drawing.Rectangle((S 12), ($s.Height - (S 44)), ($s.Width - (S 24)), (S 30))
            [Windows.Forms.TextRenderer]::DrawText($g, '또는 클릭해서 폴더 선택  (' + $tag.Label + ' 런처의 설치 폴더)', $fontSmall, $r2, $cSub, [Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter,SingleLine')
        } else {
            $y0 = S 12; $lh = S 28
            foreach ($ln in $inf.Lines) {
                $rr = New-Object Drawing.Rectangle((S 14), $y0, ($s.Width - (S 28)), $lh)
                [Windows.Forms.TextRenderer]::DrawText($g, $ln.Text, $fontBold, $rr, $ln.Color, [Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter,SingleLine')
                $y0 += $lh
            }
            $r2 = New-Object Drawing.Rectangle((S 14), ($y0 + (S 8)), ($s.Width - (S 28)), [Math]::Max((S 24), $s.Height - $y0 - (S 20)))
            [Windows.Forms.TextRenderer]::DrawText($g, $inf.Text, $fontPath, $r2, $cText, [Windows.Forms.TextFormatFlags]'HorizontalCenter,Top,WordBreak')
        }
    })
}


# ---------------------------------------------------------------- 체크박스 (Tag = @{On; Cb; Text})

function New-Check([string]$text, [bool]$on, [scriptblock]$cb, $parent) {
    $t = New-Object Windows.Forms.Panel
    $t.Cursor = 'Hand'; $t.BackColor = $cCard
    Set-DoubleBuffered $t
    $t.Tag = @{ On = $on; Cb = $cb; Text = $text }
    $t.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $k = $script:sc
        $en = $s.Enabled; $on = $s.Tag.On
        $g.ScaleTransform($k, $k)
        $bx = Get-RoundPath 1 6 18 18 4
        if ($on) {
            $col = if ($en) { $cAccent } else { [Drawing.Color]::FromArgb(150, 190, 225) }
            $br = New-Object Drawing.SolidBrush($col); $g.FillPath($br, $bx); $br.Dispose()
            $pen = New-Object Drawing.Pen([Drawing.Color]::White, 2)
            $pts = [Drawing.PointF[]]@((New-Object Drawing.PointF(5, 15)), (New-Object Drawing.PointF(9, 19)), (New-Object Drawing.PointF(16, 11)))
            $g.DrawLines($pen, $pts)
            $pen.Dispose()
        } else {
            $col = if ($en) { $cSub } else { [Drawing.Color]::FromArgb(190, 190, 190) }
            $pen = New-Object Drawing.Pen($col, 1.5); $g.DrawPath($pen, $bx); $pen.Dispose()
        }
        $bx.Dispose(); $g.ResetTransform()
        $x0 = [int](30 * $k)
        $fc = if ($en) { $cText } else { $cSub }
        $r = New-Object Drawing.Rectangle($x0, 0, ($s.Width - $x0), $s.Height)
        [Windows.Forms.TextRenderer]::DrawText($g, $s.Tag.Text, $fontBase, $r, $fc, [Windows.Forms.TextFormatFlags]'VerticalCenter,Left,SingleLine')
    })
    $t.Add_Click({
        param($s, $e)
        if (-not $s.Enabled) { return }
        $s.Tag.On = -not $s.Tag.On
        $s.Invalidate()
        if ($s.Tag.Cb) { & $s.Tag.Cb }
    })
    $t.Add_EnabledChanged({ param($s, $e) $s.Invalidate() })
    $parent.Controls.Add($t)
    return $t
}

# ---------------------------------------------------------------- 상태 표시 (원본/대상 박스)

function Update-Info([string]$side) {
    $p = $script:paths[$side]
    if (-not $p) { $script:info[$side] = $null; return }
    $st = Get-State $p
    if (-not $st) { $script:info[$side] = @{ Text = $p; Lines = @(@{ Text = '!  올바른 경로가 아닙니다'; Color = $cDanger }) }; return }
    $lines = @()
    if ($st.Launcher) { $lines += @{ Text = '✔  런처 확인됨'; Color = $cOk } }
    elseif ($side -eq 'dst') { $lines += @{ Text = '!  런처 없음 (launcher.exe 없음)'; Color = $cDanger } }
    else { $lines += @{ Text = '–  런처 없음 (launcher.exe 없음)'; Color = $cSub } }
    if ($side -eq 'src') {
        $lk = @(Get-LinkedFixed $st.Game)
        if ($st.Exe -and $lk.Count -gt 0) { $lines += @{ Text = '✖  구성 파일 없음 (링크 상태)'; Color = $cDanger } }
        elseif ($st.Exe) { $lines += @{ Text = '✔  구성 파일 확인됨 · 링크 원본 가능'; Color = $cOk } }
        else { $lines += @{ Text = '!  구성 파일 없음'; Color = $cDanger } }
    } else {
        $lk = @(Get-LinkedFixed $st.Game)
        if ($st.Exe -and $lk.Count -gt 0) { $lines += @{ Text = '✖  구성 파일 없음 · 링크 상태'; Color = $cDanger } }
        elseif ($st.Exe) { $lines += @{ Text = '✔  구성 파일 있음 · 링크 가능'; Color = $cOk } }
        else { $lines += @{ Text = '!  구성 파일 없음 · 링크 불가'; Color = $cDanger } }
    }
    $script:info[$side] = @{ Text = $st.Root; Lines = $lines }
}

# ---------------------------------------------------------------- 옵션 카드 (연결할 폴더)

$cardOpt = New-Card
$lblOptTitle = New-Text '연결할 폴더' $fontBold $cText $cardOpt
$lblQ = New-Text '품질 리소스 선택 : 원본에 있는 리소스만 선택이 가능합니다.' $fontSmall $cSub $cardOpt
$rowCtl = @{}
foreach ($it in $Items) {
    $c = New-Check $it.Label $it.Fixed { Reset-Preview } $cardOpt
    if ($it.Fixed) { $c.Enabled = $false }
    $st = New-Text '' $fontSmall $cSub $cardOpt
    $st.TextAlign = 'MiddleLeft'
    $rowCtl[$it.Key] = @{ Check = $c; Status = $st }
}
$divider = New-Object Windows.Forms.Panel
$divider.BackColor = $cBorder
$cardOpt.Controls.Add($divider)
$boxInfo = New-NoteBox $cardOpt @('런처 실행 후 [게임 복구]까지 추가로 다운받는 항목이 없으면 정상적으로 링크가 진행된 것입니다.', '대상에서 정상적으로 클라이언트 실행 및 게임 진행이 되는 것을 확인 후 [백업 삭제]로 정리하세요.') 'ⓘ' $cAccent (New-Object Drawing.Color) $null
$boxWarn = New-NoteBox $cardOpt @('원본의 연결 폴더를 지우거나 옮기면 링크가 깨집니다.', '연결 폴더는 모든 원본, 링크에서 공유됩니다. 임의로 수정하지 마세요.') '⚠' $cDanger (New-Object Drawing.Color) $null

# ---------------------------------------------------------------- 실행 영역

$btnPrev  = New-Button '런처 실행 › 게임 복구 › 게임 실행' $false $form
$btnRun   = New-Button '링크 실행' $true $form
$btnUndo  = New-Button '되돌리기' $false $form
$btnClean = New-Button '백업 삭제' $false $form
$btnRun.Tag.Num = '1'; $btnPrev.Tag.Num = '2'; $btnClean.Tag.Num = '3'; $btnUndo.Tag.Icon = 'undo'
$btnRun.Tag.Style = 'soft'; $btnPrev.Tag.Style = 'mid'; $btnClean.Tag.Style = 'deep'; $btnUndo.Tag.Style = 'danger'
$lblCap2 = New-Object Windows.Forms.Label
$lblCap2.Text = ''; $lblCap2.Font = $fontSmall; $lblCap2.ForeColor = $cSub; $lblCap2.BackColor = $cBg
$lblCap2.TextAlign = 'MiddleCenter'
$form.Controls.Add($lblCap2)
$flowA1 = New-FlowArrow $form
$flowA2 = New-FlowArrow $form
$btnRun.Enabled = $false; $btnPrev.Enabled = $false; $btnUndo.Enabled = $false; $btnClean.Enabled = $false
$lblStatus = New-Object Windows.Forms.Label
$lblStatus.AutoSize = $false; $lblStatus.ForeColor = $cSub; $lblStatus.BackColor = $cBg; $lblStatus.TextAlign = 'MiddleLeft'
$lblStatus.Text = ''; $lblStatus.ForeColor = [Drawing.Color]::FromArgb(0, 74, 148)
$lblStatus.Add_TextChanged({ param($s, $e) $t = [string]$s.Text; if ($t -match '오류|실패') { $s.ForeColor = $cDanger } elseif ($t -match '완료') { $s.ForeColor = $cOk } else { $s.ForeColor = [Drawing.Color]::FromArgb(0, 74, 148) } })
$form.Controls.Add($lblStatus)

$cardLog = New-Card
$lblLogTitle = New-Text '진행 로그' $fontBold $cText $cardLog
$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
$txtLog.BorderStyle = 'None'; $txtLog.BackColor = $cCard; $txtLog.ForeColor = $cText; $txtLog.Font = $fontPath
$txtLog.Text = '준비 완료.' + "`r`n" + '링크 생성, 또는 링크 관리 탭에서 작업을 수행해 주세요.' + "`r`n"
$cardLog.Controls.Add($txtLog)

function Log([string]$m) {
    $txtLog.AppendText($m + "`r`n")
    if ($script:logFile) { try { Add-Content -LiteralPath $script:logFile -Value $m -Encoding UTF8 } catch { } }
}
# 로그 폴더: 이 도구가 있는 폴더의 logs (만들 수 없으면 바탕 화면)
function Get-LogDir {
    $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $d = Join-Path $base 'logs'
    try { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null; return $d }
    catch { return [Environment]::GetFolderPath('Desktop') }
}
function Start-LogFile([string]$tag) {
    $script:logFile = Join-Path (Get-LogDir) ('WW-ClientLink_{0}_{1}.log' -f $tag, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $script:lastLog = $script:logFile
}

# ---------------------------------------------------------------- 레이아웃

function Do-Layout {
    $FW = $form.ClientSize.Width; $FH = $form.ClientSize.Height
    $m = S 16; $gap = S 30
    $y = $m
    $cw = $FW - 2 * $m

    $topH = S 52
    $cardTop.SetBounds($m, $y, $cw, $topH)
    $tabBar.SetBounds((S 12), (S 8), (S 232), (S 36))
    $tglTop.SetBounds((S 262), (S 11), (S 170), (S 30))
    $btnLog.SetBounds(($cw - (S 16) - (S 160)), (S 8), (S 160), (S 36))
    $y += $topH + (S 12)

    if ($script:tab -eq 'create') {
        $colW = [int](($cw - $gap) / 2)
        $colH = S 216
        $cardSrc.SetBounds($m, $y, $colW, $colH)
        $cardDst.SetBounds(($m + $colW + $gap), $y, $colW, $colH)
        $lblArrow.SetBounds(($m + $colW), ($y + [int]($colH / 2) - (S 20)), $gap, (S 40))
        foreach ($side in 'src', 'dst') {
            $s = $sides[$side]
            $s.Btn.SetBounds(($colW - (S 16) - (S 100)), (S 12), (S 100), (S 34))
            if ($s.Scan) { $s.Scan.SetBounds(($colW - (S 16) - (S 100) - (S 8) - (S 110)), (S 12), (S 110), (S 34)) }
            $s.Title.SetBounds((S 16), (S 17), (S 54), (S 26))
            $s.Sub.SetBounds((S 16), (S 54), ($colW - (S 32)), (S 24))
            $s.Box.SetBounds((S 16), (S 84), ($colW - (S 32)), ($colH - (S 84) - (S 14)))
        }
        $y += $colH + (S 12)

        $iw = $cw - (S 32); $rowH = S 30
        $lblOptTitle.SetBounds((S 16), (S 12), $iw, (S 26))
        $yy = S 46
        foreach ($key in 'Paks', 'Resources') {
            $rowCtl[$key].Check.SetBounds((S 16), $yy, (S 300), $rowH)
            $rowCtl[$key].Status.SetBounds((S 330), $yy, ($cw - (S 346)), $rowH)
            $yy += $rowH
        }
        $yy += (S 8)
        $lblQ.SetBounds((S 16), $yy, $iw, (S 24)); $yy += (S 30)
        foreach ($key in 'UHD', 'HD', 'SD') {
            $rowCtl[$key].Check.SetBounds((S 16), $yy, (S 300), $rowH)
            $rowCtl[$key].Status.SetBounds((S 330), $yy, ($cw - (S 346)), $rowH)
            $yy += $rowH
        }
        $yy += (S 10)
        $divider.SetBounds((S 16), $yy, $iw, 1)
        $yy += (S 14)
        $nbH = S 68
        $boxInfo.SetBounds((S 16), $yy, $iw, $nbH); $yy += $nbH + (S 10)
        $boxWarn.SetBounds((S 16), $yy, $iw, $nbH); $yy += $nbH
        $yy += (S 12)
        $cardOpt.SetBounds($m, $y, $cw, $yy)
        $y += $yy + (S 12)

        $bh = S 52
        $w1 = S 170; $w2 = S 310; $w3 = S 150; $wu = S 150; $fa = S 36
        $btnRun.SetBounds($m, $y, $w1, $bh)
        $flowA1.SetBounds(($m + $w1), $y, $fa, $bh)
        $btnPrev.SetBounds(($m + $w1 + $fa), $y, $w2, (S 36))
        $lblCap2.SetBounds(($m + $w1 + $fa), ($y + (S 38)), $w2, (S 18))
        $flowA2.SetBounds(($m + $w1 + $fa + $w2), $y, $fa, $bh)
        $btnClean.SetBounds(($m + $w1 + 2 * $fa + $w2), $y, $w3, $bh)
        $btnUndo.SetBounds([Math]::Max(($m + $w1 + 2 * $fa + $w2 + $w3 + (S 16)), ($m + $cw - $wu)), $y, $wu, $bh)
        $y += $bh + (S 10)
        $lblStatus.SetBounds($m, $y, $cw, (S 28))
        $y += (S 28) + (S 8)
        $logAuto = S 300
        $script:createTotal = $y + $logAuto + (S 16)
    } else {
        # 등록된 클라이언트
        $ch = S 52
        if (Test-SlotsExpanded) { $ch = (S 46) + (S 196) + (S 14) }
        $cardClients.SetBounds($m, $y, $cw, $ch)
        $slotPanel.SetBounds(0, 0, $cw, $ch)
        $y += $ch + (S 12)
        # 링크 현황
        $gh = (S 78) + 5 * (S 56)
        $lblGridTitle.SetBounds((S 16), (S 12), (S 300), (S 26))
        $sh = Get-TextHeight $lblGridSub ($cw - (S 32))
        $lblGridSub.SetBounds((S 16), (S 38), ($cw - (S 32)), $sh)
        $gy = (S 38) + $sh + (S 10)
        $gridPanel.SetBounds((S 16), $gy, ($cw - (S 32)), $gh)
        $cardGrid.SetBounds($m, $y, $cw, ($gy + $gh + (S 14)))
        $y += $cardGrid.Height + (S 10)
        $lblSelInfo.SetBounds($m, $y, $cw, (S 34))
        $y += (S 34) + (S 10)
        $bh = S 42
        $mBtnConn.SetBounds($m, $y, (S 150), $bh)
        $mBtnDisc.SetBounds(($m + (S 162)), $y, (S 150), $bh)
        $mBtnRef.SetBounds(($m + (S 324)), $y, (S 110), $bh)
        $mBtnBroken.SetBounds(($m + (S 446)), $y, (S 140), $bh)
        $mBtnClean.SetBounds(($m + (S 598)), $y, (S 120), $bh)
        $mBtnSync.SetBounds(($m + $cw - (S 180)), $y, (S 180), $bh)
        $y += $bh + (S 6)
        $lblSum.SetBounds($m, $y, $cw, (S 28))
        $y += (S 28) + (S 8)
        $logAuto = [Math]::Max((S 150), ([int]$script:createTotal - $y - (S 16)))
    }

    $script:logTop = $y
    if ($script:autoSize) { $logH = $logAuto } else { $logH = [Math]::Max((S 90), $FH - $y - $m) }
    $cardLog.SetBounds($m, $y, $cw, $logH)
    $lblLogTitle.SetBounds((S 16), (S 12), (S 200), (S 26))
    $txtLog.SetBounds((S 16), (S 44), ($cw - (S 32)), [Math]::Max((S 40), ($logH - (S 44) - (S 14))))
}

# ---------------------------------------------------------------- 상태 갱신

function Update-Rows {
    $ss = $null; $ds = $null
    if ($script:paths.src) { $ss = Get-State $script:paths.src }
    if ($script:paths.dst) { $ds = Get-State $script:paths.dst }
    $anyBak = $false; $anyLink = $false
    foreach ($it in $Items) {
        $r = $rowCtl[$it.Key]
        $srcInfo = $null
        if ($ss) { $srcInfo = Get-LinkInfo (Join-Path $ss.Game $it.Sub) }
        $srcOk = ($srcInfo -and $srcInfo.Kind -eq 'dir')
        if (-not $it.Fixed) {
            $r.Check.Enabled = [bool]$srcOk
            if ($script:resetChecks) { $r.Check.Tag.On = ($srcOk -and $it.Key -eq 'UHD') }
            elseif (-not $srcOk) { $r.Check.Tag.On = $false }
            $r.Check.Invalidate()
        }
        $txt = ''; $col = $cSub
        if (-not $ss) { $txt = '원본 경로를 지정하세요' }
        elseif (-not $srcOk) {
            if ($srcInfo.Kind -eq 'link') { $txt = '원본이 이미 링크입니다 (원본으로 쓸 수 없음)' } else { $txt = '원본에 없음' }
            if ($it.Fixed) { $col = $cDanger }
        } else {
            $txt = '원본: 있음'; $col = $cOk
            try { $gs = Get-DirStat (Join-Path $ss.Game $it.Sub); $txt += ' (' + (Format-Size $gs.Bytes) + ')' } catch { }
        }
        if ($ds) {
            $di = Get-LinkInfo (Join-Path $ds.Game $it.Sub)
            switch ($di.Kind) {
                'none' { $txt += '  ·  대상: 없음 → 링크 생성' }
                'dir'  { $txt += '  ·  대상: 실제 폴더 → 백업 후 링크' }
                'file' { $txt += '  ·  대상: 파일이 있음 (링크 불가)'; $col = $cDanger }
                'link' {
                    $anyLink = $true
                    if ($srcOk -and ((Get-NormPath $di.Target) -ieq (Get-NormPath (Join-Path $ss.Game $it.Sub)))) { $txt += '  ·  대상: 이미 연결됨' }
                    else { $txt += '  ·  대상: 다른 경로로 링크됨 (재연결)' }
                }
            }
            $nb = (Get-ItemBackups $ds.Game $it).Count
            if ($nb -gt 0) { $txt += "  ·  백업 $nb 개"; $anyBak = $true }
        }
        $r.Status.Text = $txt; $r.Status.ForeColor = $col
    }
    $script:resetChecks = $false
    if (-not $anyBak) { $script:ok2 = $false }
    if (-not $script:busy) {
        $btnRun.Enabled = [bool]($script:paths.src -and $script:paths.dst)
        $btnPrev.Enabled = ($anyBak -and -not $script:ok2)
        if ($script:ok2) { $btnPrev.Text = '확인 완료' } else { $btnPrev.Text = '런처 실행 › 게임 복구 › 게임 실행' }
        $btnPrev.Invalidate()
        if ($btnPrev.Enabled) { $lblCap2.Text = '( 직접 진행 후 정상이면 눌러주세요 )' } else { $lblCap2.Text = '' }
        $btnClean.Enabled = ($anyBak -and $script:ok2)
        $btnUndo.Enabled = (@($script:undoStack).Count -gt 0)
    }
}

function Reset-Preview { }   # (이전 [미리보기] 단계의 잔재: 지금은 할 일 없음)

function Set-Side([string]$side, [string]$p) {
    if ($script:busy -or [string]::IsNullOrWhiteSpace($p)) { return }
    $p = $p.Trim().Trim('"')
    if (Test-Path -LiteralPath $p -PathType Leaf) { $p = Split-Path $p -Parent }
    $script:paths[$side] = $p
    if ($side -eq 'src') { $script:resetChecks = $true }
    Update-Info $side
    $sides[$side].Box.Invalidate()
    Update-Rows
    Reset-Preview
    $lblStatus.Text = '준비되면 [링크 실행]을 눌러 주세요.'
}

function Set-Busy([bool]$b) {
    $script:busy = $b
    foreach ($c in @($btnPrev, $btnRun, $btnUndo, $btnClean)) { $c.Enabled = -not $b }
    foreach ($side in 'src', 'dst') { $sides[$side].Btn.Enabled = -not $b }
    foreach ($it in $Items) { if (-not $it.Fixed) { if ($b) { $rowCtl[$it.Key].Check.Enabled = $false } } }
    if (-not $b) { Update-Rows }
    foreach ($c in @($mBtnConn, $mBtnDisc, $mBtnRef, $mBtnBroken, $mBtnClean, $mBtnSync)) { if ($b) { $c.Enabled = $false } }
    if (-not $b) { $mBtnRef.Enabled = $true; $mBtnSync.Enabled = $true; if ($script:grid) { Update-ManageUi } }
}

function Get-SelectedKeys { @($Items | Where-Object { $rowCtl[$_.Key].Check.Tag.On } | ForEach-Object { $_.Key }) }
function Get-Sig { '{0}|{1}|{2}' -f (Get-Game $script:paths.src), (Get-Game $script:paths.dst), ((Get-SelectedKeys) -join ',') }

function Test-SymlinkAbility {
    $base = Join-Path $env:TEMP ('wuwa_symtest_' + [guid]::NewGuid().ToString('N'))
    $d = $base + '_dir'; $l = $base + '_lnk'
    $ok = $false
    try {
        New-Item -ItemType Directory -Path $d -ErrorAction Stop | Out-Null
        New-Item -ItemType SymbolicLink -Path $l -Target $d -ErrorAction Stop | Out-Null
        $ok = $true
    } catch { $ok = $false }
    finally {
        try { if (Test-Path -LiteralPath $l) { [IO.Directory]::Delete($l) } } catch { }
        try { if (Test-Path -LiteralPath $d) { [IO.Directory]::Delete($d) } } catch { }
    }
    return $ok
}

# ---------------------------------------------------------------- 드롭 / 찾아보기 연결 (이식 도구와 동일)

foreach ($side in 'src', 'dst') {
    $box = $sides[$side].Box
    $card = $sides[$side].Card
    foreach ($c in $box, $card) {
        $c.AllowDrop = $true
        $c.Add_HandleCreated({ param($s, $e) [WWCLNative]::AllowDropMessages($s.Handle) })
    }
    $box.Add_DragEnter({
        param($s, $e)
        if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop) -and -not $script:busy) {
            $e.Effect = [Windows.Forms.DragDropEffects]::Copy
            $s.Tag.Drag = $true; $s.Invalidate()
        }
    })
    $box.Add_DragLeave({ param($s, $e) $s.Tag.Drag = $false; $s.Invalidate() })
    $box.Add_DragDrop({
        param($s, $e)
        $s.Tag.Drag = $false; $s.Invalidate()
        $f = $e.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
        if ($f) { Set-Side $s.Tag.Side ([string]$f[0]) }
    })
    # 박스 밖(카드 영역)에 떨어뜨려도 받기
    $card.Tag = $side
    $card.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop) -and -not $script:busy) { $e.Effect = [Windows.Forms.DragDropEffects]::Copy } })
    $card.Add_DragDrop({ param($s, $e) $f = $e.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if ($f) { Set-Side $s.Tag ([string]$f[0]) } })
    # 클릭하면 폴더 선택
    $box.Add_Click({ param($s, $e) Invoke-Browse $s.Tag.Side })
    $sides[$side].Btn.Name = $side
    $sides[$side].Btn.Add_Click({ param($s, $e) Invoke-Browse $s.Name })
}

function Invoke-Browse([string]$side) {
    if ($script:busy) { return }
    $label = if ($side -eq 'src') { '원본' } else { '대상' }
    $init = $script:paths[$side]
    if ($init -and -not (Test-Path -LiteralPath $init -PathType Container)) { $init = Split-Path $init -Parent }
    try { $r = [WWCLFolderPicker]::Pick($form.Handle, "$label 폴더 선택 (명조 설치 폴더 또는 Wuthering Waves Game)", $init) }
    catch { $r = $null; Log ('폴더 선택 창 오류: ' + $_.Exception.Message) }
    if ($r) { Set-Side $side $r }
}

$btnLog.Add_Click({
    if ($script:lastLog -and (Test-Path -LiteralPath $script:lastLog)) { Start-Process explorer.exe -ArgumentList ('/select,"' + $script:lastLog + '"') }
    else { Start-Process explorer.exe -ArgumentList ('"' + (Get-LogDir) + '"') }
})


# ---------------------------------------------------------------- 안전 검사

function Test-Safety([bool]$needSymlink) {
    $ss = Get-State $script:paths.src; $ds = Get-State $script:paths.dst
    if (-not $ss -or -not $ds) { return '원본과 대상 경로를 모두 지정해 주세요.' }
    $keys = @(Get-SelectedKeys)
    if ($keys.Count -eq 0) { return '연결할 폴더를 하나 이상 선택해 주세요.' }
    return (Test-LinkSafety $ss @(@{ Name = ''; Path = $ds.Root; Ds = $ds; Keys = $keys; Plan = $null }) $needSymlink)
}

# 링크 전 공통 안전 검사 ([링크 생성] 탭과 [링크 관리] 탭이 함께 사용). 문제가 있으면 안내 문구, 없으면 $null
#  $targets = @(@{ Name; Path; Ds; Keys; Plan })  Name 이 비어 있으면 안내 문구 앞에 [이름]을 붙이지 않음, Plan 이 없으면 여기서 만듦
function Test-LinkSafety($ss, $targets, [bool]$needSymlink) {
    if (-not $ss -or -not $ss.Exe) {
        $g = ''; if ($ss) { $g = "`r`n" + $ss.Game }
        return ("원본에 구성 파일이 없습니다 (Wuthering Waves Game\Wuthering Waves.exe 확인 불가):" + $g)
    }
    $games = @($ss.Game)
    foreach ($t in $targets) {
        $ds = $t.Ds
        $pre = ''; if ($t.Name) { $pre = '[' + $t.Name + '] ' }
        if (-not $ds) { return ($pre + "대상 폴더를 확인할 수 없습니다:`r`n" + $t.Path) }
        if (-not $ds.Launcher) { return ($pre + "대상 경로에 launcher.exe가 없습니다. 대상 런처의 설치 폴더를 지정하세요:`r`n" + $ds.Root) }
        if (-not $ds.Exe) { return ($pre + "대상에 구성 파일이 없어 링크할 수 없습니다. 먼저 클라이언트를 설치(또는 이식)하세요:`r`n" + $ds.Game) }
        if ($ss.Game -ieq $ds.Game) { return ($pre + '원본과 대상이 같습니다.') }
        if (Test-Nested $ss.Game $ds.Game) { return ($pre + '원본과 대상이 서로 포함 관계입니다.') }
        foreach ($g in $games) { if ($g -ine $ss.Game -and (($g -ieq $ds.Game) -or (Test-Nested $g $ds.Game))) { return ($pre + '다른 대상과 같거나 서로 포함 관계입니다.') } }
        $cv = Get-LinkCompat $ss.Game $ds.Game $t.Keys
        if ($cv.Level -eq 'minor') { return ($pre + $cv.Block) }
        foreach ($k in $t.Keys) {
            $it = Get-ItemByKey $k
            $p = Join-Path $ss.Game $it.Sub
            if ((Get-LinkInfo $p).Kind -ne 'dir') { return ("원본에 실제 폴더가 없습니다 (링크이거나 없음):`r`n" + $p) }
        }
        $plan = $t.Plan; if ($null -eq $plan) { $plan = Build-Plan $ss.Game $ds.Game $t.Keys }
        $bad = @($plan | Where-Object { $_.Kind -eq 'error' })
        if ($bad.Count -gt 0) { return ($pre + "대상에 폴더가 아닌 파일이 있어 링크할 수 없습니다:`r`n" + $bad[0].Dst) }
        $games += $ds.Game
    }
    $run = Get-RunningConflicts $games
    if ($run.Count -gt 0) { return ("관련 프로세스가 실행 중입니다. 런처(트레이 포함)와 게임을 완전히 종료한 뒤 다시 시도하세요:`r`n" + ($run -join ', ')) }
    if ($needSymlink -and -not (Test-SymlinkAbility)) { return '심볼릭 링크를 만들 권한이 없습니다. 관리자 권한으로 실행해 주세요.' }
    return $null
}

function Get-PlanText($a) {
    $leaf = Split-Path $a.Sub -Leaf
    switch ($a.Kind) {
        'skip'        { return ('{0}: 이미 연결됨 (건너뜀)' -f $a.Sub) }
        'link'        { return ('{0}: 링크 생성' -f $a.Sub) }
        'backup+link' { return ('{0}: 기존 폴더를 {1}_backup 으로 이름 변경(백업) → 링크 생성' -f $a.Sub, $leaf) }
        'relink'      { return ('{0}: 다른 경로 링크 해제 → 재연결' -f $a.Sub) }
        default       { return ('{0}: 처리 불가' -f $a.Sub) }
    }
}

function Show-Warn([string]$msg, [string]$title = '중단') { [void][Windows.Forms.MessageBox]::Show($msg, $title, 'OK', 'Warning') }

# ---------------------------------------------------------------- ② 런처 [게임 복구] · 게임 실행 확인 (도구가 대신하지 않는 사용자 확인 단계)

$btnPrev.Add_Click({
    if ($script:busy) { return }
    $ans = [Windows.Forms.MessageBox]::Show("대상 런처에서 [게임 복구]를 마쳤고 게임 실행이 정상적으로 되는 것을 확인했습니까?`r`n`r`n[예]를 누르면 [백업 삭제]를 진행할 수 있습니다.", '확인', 'YesNo', 'Question', 'Button2')
    if ($ans -ne 'Yes') { return }
    $script:ok2 = $true
    Update-Rows
    $lblStatus.Text = '확인 완료 · [백업 삭제]를 진행할 수 있습니다.'
})

# ---------------------------------------------------------------- 링크 실행: 백업(이름 변경) → 링크

function Invoke-PlanItem($a, [string]$stamp) {
    $leaf = Split-Path $a.Sub -Leaf
    $bak = $null; $old = $null
    try {
        if ($a.Kind -eq 'skip') { Log ('  [건너뜀] ' + $a.Sub); return $true }
        if ((Get-LinkInfo $a.Src).Kind -ne 'dir') { throw '원본 폴더가 실제 폴더가 아니어서 링크를 만들 수 없습니다 (그 사이 상태가 바뀜).' }
        if ($a.Kind -eq 'relink') {
            $old = (Get-LinkInfo $a.Dst).Target
            [IO.Directory]::Delete($a.Dst)
            if (Test-Path -LiteralPath $a.Dst) { throw '기존 링크를 해제하지 못했습니다.' }
            Log ('  [링크 해제] ' + $a.Dst)
        }
        if ($a.Kind -eq 'backup+link') {
            $parent = Split-Path $a.Dst -Parent
            $bn = $leaf + '_backup'
            if (Test-Path -LiteralPath (Join-Path $parent $bn)) { $bn = $bn + '_' + $stamp }
            $bak = Join-Path $parent $bn
            Move-Item -LiteralPath $a.Dst -Destination $bak -ErrorAction Stop
            Log ("  [백업] {0} → {1}" -f $a.Dst, $bn)
        }
        if ($a.Kind -eq 'link') {
            New-Item -ItemType Directory -Force -Path (Split-Path $a.Dst -Parent) | Out-Null
        }
        New-Item -ItemType SymbolicLink -Path $a.Dst -Target $a.Src -ErrorAction Stop | Out-Null
        $li = Get-LinkInfo $a.Dst
        if ($li.Kind -ne 'link' -or ((Get-NormPath $li.Target) -ine (Get-NormPath $a.Src))) { throw '링크를 만들었지만 대상 경로가 일치하지 않습니다.' }
        Log ("  [링크 생성] {0} → {1}" -f $a.Dst, $a.Src)
        $script:runRec += [pscustomobject]@{ Sub = $a.Sub; Dst = $a.Dst; Src = $a.Src; Kind = $a.Kind; OldTarget = $old; Bak = $bak }
        return $true
    } catch {
        Log ("  [실패] {0}: {1}" -f $a.Sub, $_.Exception.Message)
        if ($old -and -not (Test-Path -LiteralPath $a.Dst) -and ((Get-LinkInfo $a.Dst).Kind -eq 'none') -and (Test-Path -LiteralPath $old)) {
            try { New-Item -ItemType SymbolicLink -Path $a.Dst -Target $old -ErrorAction Stop | Out-Null; Log '  [복구] 기존 링크를 다시 만들었습니다.' }
            catch { Log ('  [경고] 기존 링크를 복구하지 못했습니다. 직접 확인하세요: ' + $a.Dst) }
        }
        if ($bak -and (Test-Path -LiteralPath $bak) -and -not (Test-Path -LiteralPath $a.Dst)) {
            try { Move-Item -LiteralPath $bak -Destination $a.Dst -ErrorAction Stop; Log '  [복구] 백업을 원래 이름으로 되돌렸습니다.' }
            catch { Log ('  [경고] 백업을 되돌리지 못했습니다. 직접 이름을 확인하세요: ' + $bak) }
        }
        return $false
    }
}

$btnRun.Add_Click({
    if ($script:busy) { return }
    $err = Test-Safety $true
    if ($err) { Show-Warn $err; return }
    $ss = Get-State $script:paths.src; $ds = Get-State $script:paths.dst
    $keys = @(Get-SelectedKeys)
    $plan = @(Build-Plan $ss.Game $ds.Game $keys)
    $todo = @($plan | Where-Object { $_.Kind -ne 'skip' })
    if ($todo.Count -eq 0) { Show-Warn '할 일이 없습니다 (선택한 폴더가 모두 이미 연결되어 있음).' '알림'; $lblStatus.Text = '할 일 없음'; return }
    $oldCur = [Windows.Forms.Cursor]::Current; [Windows.Forms.Cursor]::Current = [Windows.Forms.Cursors]::WaitCursor
    $sv = [long]0
    try { foreach ($a in $todo) { try { $sv += (Get-DirStat $a.Src).Bytes } catch { } } } finally { [Windows.Forms.Cursor]::Current = $oldCur }
    $lines = @(('원본: ' + $ss.Game), ('대상: ' + $ds.Game), (Get-LinkCompat $ss.Game $ds.Game $keys).Line)
    foreach ($a in $plan) { $lines += ('  - ' + (Get-PlanText $a)) }
    if ($sv -gt 0) { $lines += ('연결되는 폴더 합계 약 ' + (Format-Size $sv) + ' (중복 저장이 없어지는 용량)') }
    $note = Get-VersionNote $ss.Game $ds.Game '' $keys
    if ($note) { $lines += ''; $lines += $note.TrimEnd() }
    $ans = [Windows.Forms.MessageBox]::Show((($lines -join "`r`n") + "`r`n`r`n위의 설정으로 링크를 진행할까요?"), '링크 확인', 'YesNo', 'Question', 'Button2')
    if ($ans -ne 'Yes') { return }
    $offer = $false
    $offSrc = $ss.Root; $offDst = $ds.Root
    Set-Busy $true
    try {
        $txtLog.Clear(); Start-LogFile 'run'
        Log ''; Log '[링크] 시작'
        foreach ($l in $lines) { Log $l }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $okAll = $true
        $script:runRec = @()
        foreach ($a in $plan) {
            $lblStatus.Text = '처리 중: ' + $a.Sub
            [Windows.Forms.Application]::DoEvents()
            if (-not (Invoke-PlanItem $a $stamp)) { $okAll = $false; break }
        }
        if ($script:runRec.Count -gt 0 -and $ds) { $script:undoStack = @($script:undoStack) + [pscustomobject]@{ Time = (Get-Date); Game = $ds.Game; Recs = @($script:runRec) } }
        if ($okAll) {
            $offer = $true
            $script:ok2 = $false
            Log '완료: 링크 구성이 끝났습니다. 대상 런처에서 런처 실행과 [게임 복구]를 확인한 뒤 ②를 눌러 주세요.'
            Log $SyncGuide
            $lblStatus.Text = '완료 · 런처 실행/[게임 복구] 확인 후 ②를 눌러 주세요'
        } else {
            Log '중단: 일부 항목에서 실패했습니다. 이미 연결된 항목은 [되돌리기]로 취소할 수 있습니다.'
            $lblStatus.Text = '일부 실패'
        }
    } catch { Log ('오류: ' + $_.Exception.Message); $lblStatus.Text = '오류' }
    finally { Set-Busy $false }
    if ($offer) { Offer-Register $offSrc $offDst }
})

# ---------------------------------------------------------------- 되돌리기: 마지막 [링크 실행] 취소 (Ctrl+Z 방식)

$btnUndo.Add_Click({
    if ($script:busy) { return }
    $st = @($script:undoStack)
    if ($st.Count -eq 0) { Show-Warn '되돌릴 링크 실행 기록이 없습니다.' '알림'; return }
    $entry = $st[$st.Count - 1]
    $run = Get-RunningConflicts @($entry.Game)
    if ($run.Count -gt 0) { Show-Warn ("관련 프로세스가 실행 중입니다. 모두 종료한 뒤 다시 시도하세요:`r`n" + ($run -join ', ')); return }
    $recs = @($entry.Recs); [array]::Reverse($recs)
    $acts = @()
    foreach ($r in $recs) {
        $li = Get-LinkInfo $r.Dst
        $a = [pscustomobject]@{ Rec = $r; Ok = $true; Why = ''; Text = '' }
        if ($li.Kind -ne 'link' -or ((Get-NormPath $li.Target) -ine (Get-NormPath $r.Src))) { $a.Ok = $false; $a.Why = '링크가 이미 바뀌어 있어 건너뜀' }
        elseif ($r.Kind -eq 'backup+link' -and (-not $r.Bak -or -not (Test-Path -LiteralPath $r.Bak))) { $a.Ok = $false; $a.Why = '백업 폴더가 없어 건너뜀' }
        elseif ($r.Kind -eq 'relink' -and (-not $r.OldTarget -or -not (Test-Path -LiteralPath $r.OldTarget))) { $a.Ok = $false; $a.Why = '이전 링크 대상이 없어 건너뜀' }
        if ($a.Ok) {
            switch ($r.Kind) {
                'backup+link' { $a.Text = '링크 해제 → 백업 복원 (' + (Split-Path $r.Bak -Leaf) + ')' }
                'relink'      { $a.Text = '링크 해제 → 이전 링크 복원 (' + $r.OldTarget + ')' }
                default       { $a.Text = '링크 해제 (폴더는 비워짐 · 런처에서 새로 받아야 함)' }
            }
        } else { $a.Text = $a.Why }
        $acts += $a
    }
    $okActs = @($acts | Where-Object { $_.Ok })
    if ($okActs.Count -eq 0) {
        Show-Warn ("되돌릴 수 있는 항목이 없습니다.`r`n" + (($acts | ForEach-Object { '- ' + $_.Rec.Sub + ': ' + $_.Text }) -join "`r`n")) '알림'
        $script:undoStack = @($st | Select-Object -First ($st.Count - 1)); Update-Rows; return
    }
    $txt = ($acts | ForEach-Object { '- ' + $_.Rec.Sub + ': ' + $_.Text }) -join "`r`n"
    $ans = [Windows.Forms.MessageBox]::Show(("마지막 [링크 실행]을 취소합니다.`r`n`r`n" + $txt + "`r`n`r`n계속할까요?"), '되돌리기 확인', 'YesNo', 'Warning', 'Button2')
    if ($ans -ne 'Yes') { return }
    Set-Busy $true
    try {
        Start-LogFile 'undo'
        Log ''; Log '[되돌리기] 시작'
        foreach ($a in $acts) {
            $r = $a.Rec
            if (-not $a.Ok) { Log ('  [건너뜀] ' + $r.Sub + ' · ' + $a.Why); continue }
            try {
                [IO.Directory]::Delete($r.Dst); Log ('  [링크 해제] ' + $r.Dst)
                if ($r.Kind -eq 'backup+link') {
                    Move-Item -LiteralPath $r.Bak -Destination $r.Dst -ErrorAction Stop
                    Log ('  [백업 복원] ' + $r.Dst)
                } elseif ($r.Kind -eq 'relink') {
                    New-Item -ItemType SymbolicLink -Path $r.Dst -Target $r.OldTarget -ErrorAction Stop | Out-Null
                    Log ('  [이전 링크 복원] ' + $r.Dst + ' → ' + $r.OldTarget)
                }
            } catch { Log ('  [실패] ' + $r.Sub + ': ' + $_.Exception.Message) }
        }
        Log '[되돌리기] 끝'
        $script:undoStack = @($st | Select-Object -First ($st.Count - 1))
        $lblStatus.Text = '되돌리기 완료'
    } catch { Log ('오류: ' + $_.Exception.Message); $lblStatus.Text = '오류' }
    finally { Set-Busy $false }
})

# ---------------------------------------------------------------- 백업 삭제 (링크 상태인 항목의 백업만)

function Remove-DirAsync([string]$path) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'; $psi.Arguments = '/c rd /s /q "' + $path + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    while (-not $p.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150 }
    return (-not (Test-Path -LiteralPath $path))
}

$btnClean.Add_Click({
    $ds = if ($script:paths.dst) { Get-State $script:paths.dst } else { $null }
    if (-not $ds) { Show-Warn '대상 경로를 지정해 주세요.'; return }
    $cands = @(); $skipped = @()
    foreach ($it in $Items) {
        $orig = Join-Path $ds.Game $it.Sub
        $li = Get-LinkInfo $orig
        foreach ($b in (Get-ItemBackups $ds.Game $it)) {
            if ($li.Kind -eq 'link') {
                $sz = (Get-ChildItem -LiteralPath $b.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                $cands += [pscustomobject]@{ Path = $b.FullName; Name = $b.Name; GB = ([double]$sz / 1GB); Orig = $orig }
            } else { $skipped += $b.FullName }
        }
    }
    if ($cands.Count -eq 0) {
        $m = '삭제할 수 있는 백업이 없습니다.'
        if ($skipped.Count -gt 0) { $m += "`r`n(원래 폴더가 링크 상태가 아닌 백업은 보호를 위해 제외됨)" }
        Show-Warn $m '알림'; return
    }
    $txt = ($cands | ForEach-Object { '- {0}  ({1:N1} GB)' -f $_.Path, $_.GB }) -join "`r`n"
    $msg = "다음 백업 폴더를 영구 삭제합니다 (휴지통으로 가지 않음).`r`n런처 실행과 [게임 복구]를 확인한 뒤에만 진행하세요.`r`n`r`n$txt"
    if ($skipped.Count -gt 0) { $msg += "`r`n`r`n제외(원래 폴더가 링크 상태가 아님):`r`n" + ($skipped -join "`r`n") }
    $ans = [Windows.Forms.MessageBox]::Show(($msg + "`r`n`r`n계속할까요?"), '백업 삭제 확인', 'YesNo', 'Warning', 'Button2')
    if ($ans -ne 'Yes') { return }
    Set-Busy $true
    try {
        Start-LogFile 'clean'
        Log ''; Log '[백업 삭제] 시작'
        foreach ($c in $cands) {
            if (-not $c.Path.StartsWith($ds.Game + '\', [StringComparison]::OrdinalIgnoreCase)) { Log ('  [건너뜀] 대상 폴더 밖: ' + $c.Path); continue }
            if ((Get-LinkInfo $c.Orig).Kind -ne 'link') { Log ('  [건너뜀] 원래 폴더가 더 이상 링크 상태가 아님: ' + $c.Path); continue }
            $lblStatus.Text = '삭제 중: ' + $c.Name
            if (Remove-DirAsync $c.Path) { Log ('  [삭제] ' + $c.Path) } else { Log ('  [실패] ' + $c.Path) }
        }
        $gone = @($cands | Where-Object { -not (Test-Path -LiteralPath $_.Path) } | ForEach-Object { $_.Path })
        $ns = @()
        foreach ($en in @($script:undoStack)) {
            $keep = @($en.Recs | Where-Object { -not ($_.Bak -and ($gone -contains $_.Bak)) })
            if ($keep.Count -gt 0) { $ns += [pscustomobject]@{ Time = $en.Time; Game = $en.Game; Recs = $keep } }
        }
        $script:undoStack = $ns
        Log '[백업 삭제] 끝'
        $lblStatus.Text = '백업 삭제 완료'
    } catch { Log ('오류: ' + $_.Exception.Message); $lblStatus.Text = '오류' }
    finally { Set-Busy $false }
})


# ================================================================ 링크 관리 탭

$script:tab = 'create'
$script:sel = @{}
$script:grid = $null
$script:slotHits = @()
$script:gridHits = @()
$script:cstate = @{}; $script:clinked = @{}
$script:cver = @{}; $script:csync = @{}
$script:fitting = $false
$script:manageShown = $false

$fontCell = New-Object Drawing.Font('Malgun Gothic', 9.5, [Drawing.FontStyle]::Bold)

function RGB([int]$r, [int]$g, [int]$b) { return [Drawing.Color]::FromArgb($r, $g, $b) }
function Rc($x, $y, $w, $h) { return (New-Object Drawing.Rectangle([int]$x, [int]$y, [int]$w, [int]$h)) }
function Draw-Txt($g, [string]$t, $font, $rect, $color, [string]$flags = 'Left,VerticalCenter,SingleLine,EndEllipsis') {
    [Windows.Forms.TextRenderer]::DrawText($g, $t, $font, $rect, $color, [Windows.Forms.TextFormatFlags]$flags)
}
function Draw-Round($g, $r, $fill, $line, [float]$lw, [bool]$dash, [float]$rad) {
    $gp = Get-RoundPath ($r.X + 0.5) ($r.Y + 0.5) ($r.Width - 1) ($r.Height - 1) $rad
    if ($fill) { $br = New-Object Drawing.SolidBrush($fill); $g.FillPath($br, $gp); $br.Dispose() }
    if ($line) {
        $pen = New-Object Drawing.Pen($line, $lw)
        if ($dash) { $pen.DashStyle = [Drawing.Drawing2D.DashStyle]::Dash }
        $g.DrawPath($pen, $gp); $pen.Dispose()
    }
    $gp.Dispose()
}
function Draw-Radio($g, $r, [bool]$on, [bool]$off = $false) {
    $rc = New-Object Drawing.RectangleF(([float]($r.X + 1.5)), ([float]($r.Y + 1.5)), ([float]($r.Width - 3)), ([float]($r.Height - 3)))
    $fill = New-Object Drawing.SolidBrush([Drawing.Color]::White)
    $g.FillEllipse($fill, $rc); $fill.Dispose()
    $col = (RGB 80 80 80); $lw = 2.2
    if ($off) { $col = (RGB 200 200 200); $lw = 1.5 }
    elseif ($on) { $col = $cAccent; $lw = 2.6 }
    $pen = New-Object Drawing.Pen($col, $lw); $g.DrawEllipse($pen, $rc); $pen.Dispose()
    if ($on -and -not $off) {
        $d = $r.Width * 0.28
        $dot = New-Object Drawing.SolidBrush($cAccent)
        $g.FillEllipse($dot, ([float]($r.X + $d)), ([float]($r.Y + $d)), ([float]($r.Width - 2 * $d)), ([float]($r.Height - 2 * $d))); $dot.Dispose()
    }
}
function Draw-Check($g, $r, [bool]$on) {
    if ($on) {
        Draw-Round $g $r $cAccent $cAccent 1 $false (S 4)
        $pen = New-Object Drawing.Pen([Drawing.Color]::White, 2)
        $pts = [Drawing.PointF[]]@((New-Object Drawing.PointF(($r.X + $r.Width * 0.25), ($r.Y + $r.Height * 0.55))),
                                   (New-Object Drawing.PointF(($r.X + $r.Width * 0.43), ($r.Y + $r.Height * 0.74))),
                                   (New-Object Drawing.PointF(($r.X + $r.Width * 0.77), ($r.Y + $r.Height * 0.30))))
        $g.DrawLines($pen, $pts); $pen.Dispose()
    } else {
        Draw-Round $g $r (RGB 247 247 247) (RGB 105 105 105) 2 $false (S 4)
    }
}
function Draw-MiniBtn($g, $r, [string]$text, $fore, $line) {
    Draw-Round $g $r $cCard $line 1 $false (S 6)
    Draw-Txt $g $text $fontSmall $r $fore 'HorizontalCenter,VerticalCenter,SingleLine'
}

# 알약 모양 배지. 반환: 배지 너비(px)
function Draw-Badge($g, [int]$x, [int]$y, [string]$text, $color, [int]$minW = 0) {
    $tw = [Windows.Forms.TextRenderer]::MeasureText($text, $fontSmall).Width
    $w = [Math]::Max([int]($tw + (S 22)), $minW)
    $r = Rc $x $y $w (S 22)
    Draw-Round $g $r $color $null 1 $false (S 11)
    # 한글 글리프는 오른쪽 여백이 있어 글자 잉크가 왼쪽으로 치우쳐 보임 -> 글자 영역만 1px 오른쪽으로 보정
    $tr = Rc ($x + (S 1)) $y $w (S 22)
    Draw-Txt $g $text $fontSmall $tr ([Drawing.Color]::White) 'HorizontalCenter,VerticalCenter,SingleLine,NoPadding'
    return $w
}
# 동기화 배지 글자: 필요하면 '동기화 필요', 그 외 '동기화'
function Get-SyncText([string]$state) { if ($state -eq 'need') { return '동기화 필요' } else { return '동기화' } }
# 동기화가 필요한 클라이언트 카드 / 링크 현황 열의 배경색
$cNeedFill = [Drawing.Color]::FromArgb(255, 244, 243)
$cNeedLine = [Drawing.Color]::FromArgb(233, 180, 174)
$cNeedBand = [Drawing.Color]::FromArgb(240, 201, 196)
# 긴 경로를 \ 기준으로 최대 $maxLines 줄로 나눔 (공백이 없는 경로가 잘리지 않게). 넘치면 마지막 줄 끝에 …
function Get-WrappedPath([string]$text, $font, [int]$width, [int]$maxLines = 3) {
    $parts = @([regex]::Matches($text, '[^\\]+\\?|\\') | ForEach-Object { $_.Value })
    $lines = @(); $cur = ''
    foreach ($p in $parts) {
        $try = $cur + $p
        if ($cur -ne '' -and [Windows.Forms.TextRenderer]::MeasureText($try, $font).Width -gt $width) { $lines += $cur; $cur = $p } else { $cur = $try }
    }
    if ($cur -ne '') { $lines += $cur }
    if ($lines.Count -gt $maxLines) { $lines = @($lines[0..($maxLines - 2)]) + @(($lines[($maxLines - 1)..($lines.Count - 1)] -join '')) }
    return ($lines -join "`n")
}
function Get-SyncColor([string]$state) {
    if ($state -eq 'ok') { return $cOk }
    if ($state -eq 'need') { return $cDanger }
    return (RGB 138 138 138)
}

# ---------------------------------------------------------------- 탭 막대 (상단 카드 안)

$tabBar = New-Object Windows.Forms.Panel
$tabBar.BackColor = $cCard; $tabBar.Cursor = 'Hand'
Set-DoubleBuffered $tabBar
$cardTop.Controls.Add($tabBar)
$tabBar.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $g.Clear($cCard)
    Draw-Round $g (Rc 0 0 $s.Width $s.Height) (RGB 240 240 240) $null 1 $false (S 8)
    $half = [int]($s.Width / 2)
    $names = @('링크 생성', '링크 관리'); $keys = @('create', 'manage')
    for ($i = 0; $i -lt 2; $i++) {
        $r = Rc (($i * $half) + (S 3)) (S 3) ($half - (S 6)) ($s.Height - (S 6))
        $on = ($script:tab -eq $keys[$i])
        if ($on) { Draw-Round $g $r $cCard $cBorder 1 $false (S 6) }
        $fc = $cSub; $f = $fontBase
        if ($on) { $fc = $cAccent; $f = $fontBold }
        Draw-Txt $g $names[$i] $f $r $fc 'HorizontalCenter,VerticalCenter,SingleLine'
    }
})
$tabBar.Add_MouseClick({
    param($s, $e)
    if ($script:busy) { return }
    if ($e.X -lt ($s.Width / 2)) { Switch-Tab 'create' } else { Switch-Tab 'manage' }
})

# ---------------------------------------------------------------- 등록된 클라이언트 카드

$cardClients = New-Card
$slotPanel = New-Object Windows.Forms.Panel
$slotPanel.BackColor = $cCard
Set-DoubleBuffered $slotPanel
$slotPanel.AllowDrop = $true
$cardClients.Controls.Add($slotPanel)

function Test-SlotsExpanded { return $true }
function Add-Hit([string]$list, $rect, [string]$act, [int]$idx = -1) {
    $h = @{ R = $rect; A = $act; I = $idx }
    if ($list -eq 'slot') { $script:slotHits += $h } else { $script:gridHits += $h }
}

$slotPanel.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $g.Clear($cCard)
    $script:slotHits = @()
    $w = $s.Width; $hdrH = S 46
    $cl = @($script:clients); $cnt = $cl.Count
    Draw-Txt $g ('등록된 클라이언트 {0}/{1}' -f $cnt, $MaxClients) $fontBold (Rc (S 16) 0 (S 190) $hdrH) $cText
    # 오른쪽 버튼: 추가 / 접기·펼치기
    $expanded = Test-SlotsExpanded
    $aw = (S 130)
    $rA = Rc ($w - (S 16) - $aw) (S 10) $aw (S 26)
    $addFore = $cAccent; if ($cnt -ge $MaxClients) { $addFore = $cDash }
    Draw-MiniBtn $g $rA '＋ 클라이언트 추가' $addFore $cDash
    Add-Hit 'slot' $rA 'add'
    $rG = Rc ($rA.X - (S 8) - (S 140)) (S 10) (S 140) (S 26)
    $gFore = $cAccent; if (Test-SyncNeeded) { $gFore = $cDanger }
    Draw-MiniBtn $g $rG '동기화 순서 안내' $gFore $cDash
    Add-Hit 'slot' $rG 'guide'
    $gap = S 10; $slotH = S 196
    $slotW = [int](($w - 2 * (S 16) - 3 * $gap) / 4)
    for ($i = 0; $i -lt 4; $i++) {
        $x = (S 16) + $i * ($slotW + $gap)
        $r = Rc $x $hdrH $slotW $slotH
        if ($i -lt $cnt) {
            $c = $cl[$i]
            $isSrc = ($c.Role -eq 'src')
            $syncSt = ''
            if (-not $isSrc) { $syncSt = [string]$script:csync[$c.Path] }
            if ($isSrc) { Draw-Round $g $r (RGB 244 249 255) $cAccent 1.5 $false (S 10) }
            elseif ($syncSt -eq 'need') { Draw-Round $g $r $cNeedFill $cNeedLine 1.5 $false (S 10) }
            else { Draw-Round $g $r $cCard $cBorder 1 $false (S 10) }
            # 배지
            $bc = $cOk; $bt = '링크'; if ($isSrc) { $bc = $cAccent; $bt = '원본' }
            $bw1 = Draw-Badge $g ($x + (S 12)) ($hdrH + (S 10)) $bt $bc (S 46)
            $bx2 = $x + (S 12) + $bw1 + (S 6)
            if ($isSrc) {
                $sver = $script:cver[$c.Path]
                if ($sver) { [void](Draw-Badge $g $bx2 ($hdrH + (S 10)) $sver.Content $cAccent (S 46)) }
            } else {
                [void](Draw-Badge $g $bx2 ($hdrH + (S 10)) (Get-SyncText $syncSt) (Get-SyncColor $syncSt) (S 46))
            }
            # 이름 + 수정
            $nmW = [Windows.Forms.TextRenderer]::MeasureText($c.Name, $fontTitle).Width
            $maxNm = $slotW - (S 24) - (S 70)
            if ($nmW -gt $maxNm) { $nmW = $maxNm }
            Draw-Txt $g $c.Name $fontTitle (Rc ($x + (S 12)) ($hdrH + (S 38)) $nmW (S 26)) $cText
            $rE = Rc ($x + (S 12) + $nmW + (S 8)) ($hdrH + (S 41)) (S 56) (S 22)
            Draw-MiniBtn $g $rE '✎ 수정' $cAccent (RGB 201 214 230)
            Add-Hit 'slot' $rE 'edit' $i
            # 경로
            $wp = Get-WrappedPath ([string]$c.Path) $fontSmall ($slotW - (S 24)) 3
            Draw-Txt $g $wp $fontSmall (Rc ($x + (S 12)) ($hdrH + (S 70)) ($slotW - (S 24)) (S 56)) $cSub 'Left,Top,WordBreak,EndEllipsis'
            # 상태
            $st = $script:cstate[$c.Path]
            if (-not $st) { $st = Get-State $c.Path; $script:cstate[$c.Path] = $st }
            if (-not $script:clinked.ContainsKey($c.Path)) { $script:clinked[$c.Path] = [bool]($st -and $st.Exe -and (@(Get-LinkedFixed $st.Game).Count -gt 0)) }
            $isLinkSt = [bool]$script:clinked[$c.Path]
            $lOk = [bool]($st -and $st.Launcher)
            $eOk = [bool]($st -and $st.Exe -and -not $isLinkSt)
            $t1 = '✖ 런처'; $k1 = $cDanger; if ($lOk) { $t1 = '✔ 런처'; $k1 = $cOk }
            $t2 = '✖ 구성 파일'; $k2 = $cDanger; if ($eOk) { $t2 = '✔ 구성 파일'; $k2 = $cOk }
            $w1s = [Windows.Forms.TextRenderer]::MeasureText($t1 + '      ', $fontSmall).Width
            Draw-Txt $g $t1 $fontSmall (Rc ($x + (S 12)) ($hdrH + (S 130)) $w1s (S 18)) $k1 'Left,VerticalCenter,SingleLine'
            Draw-Txt $g $t2 $fontSmall (Rc ($x + (S 12) + $w1s) ($hdrH + (S 130)) ($slotW - (S 24) - $w1s) (S 18)) $k2 'Left,VerticalCenter,SingleLine'
            # 동작 (버튼)
            $ax = $x + (S 12); $ay = $hdrH + $slotH - (S 40); $bh = S 28
            $t2 = '목록에서 제거'
            $r2 = Rc $ax $ay ($slotW - (S 24)) $bh
            Draw-MiniBtn $g $r2 $t2 $cDanger (RGB 236 196 196)
            Add-Hit 'slot' $r2 'remove' $i
        } elseif ($i -eq $cnt) {
            Draw-Round $g $r $cCard $cDash 2 $true (S 10)
            Draw-Txt $g '＋' $fontBig (Rc $x ($hdrH + (S 34)) $slotW (S 30)) $cSub 'HorizontalCenter,VerticalCenter,SingleLine'
            Draw-Txt $g '클라이언트 추가' $fontBase (Rc $x ($hdrH + (S 66)) $slotW (S 22)) $cText 'HorizontalCenter,VerticalCenter,SingleLine'
            Draw-Txt $g '폴더를 드롭하거나 클릭' $fontSmall (Rc $x ($hdrH + (S 90)) $slotW (S 20)) $cSub 'HorizontalCenter,VerticalCenter,SingleLine'
            Add-Hit 'slot' $r 'add'
        } else {
            Draw-Round $g $r $cCard (RGB 220 220 220) 1 $true (S 10)
            Draw-Txt $g '비어 있음' $fontSmall $r (RGB 190 190 190) 'HorizontalCenter,VerticalCenter,SingleLine'
        }
    }
})

# ---------------------------------------------------------------- 링크 현황 카드

$cardGrid = New-Card
$lblGridTitle = New-Text '링크 현황' $fontBold $cText $cardGrid
$lblGridSub = New-Text '링크 상태를 변경하려면 항목을 체크 후 아래에서 작업을 선택하세요.' $fontSmall $cSub $cardGrid
$gridPanel = New-Object Windows.Forms.Panel
$gridPanel.BackColor = $cCard
Set-DoubleBuffered $gridPanel
$cardGrid.Controls.Add($gridPanel)

function Get-CellStyle([string]$kind) {
    switch ($kind) {
        'src'     { return @{ Fill = (RGB 238 245 253); Line = (RGB 188 215 243); Fore = $cText; Dash = $false } }
        'ok'      { return @{ Fill = (RGB 238 248 238); Line = (RGB 185 224 185); Fore = $cOk; Dash = $false } }
        'real'    { return @{ Fill = (RGB 250 250 250); Line = (RGB 205 205 205); Fore = (RGB 68 68 68); Dash = $false } }
        'real0'   { return @{ Fill = (RGB 250 250 250); Line = (RGB 205 205 205); Fore = (RGB 120 120 120); Dash = $false } }
        'none'    { return @{ Fill = (RGB 250 250 250); Line = (RGB 205 205 205); Fore = (RGB 68 68 68); Dash = $false } }
        'other'   { return @{ Fill = (RGB 255 246 232); Line = (RGB 242 209 155); Fore = (RGB 180 95 0); Dash = $false } }
        'broken'  { return @{ Fill = (RGB 253 240 238); Line = (RGB 240 185 178); Fore = $cDanger; Dash = $false } }
        'srclink' { return @{ Fill = (RGB 253 240 238); Line = (RGB 240 185 178); Fore = $cDanger; Dash = $false } }
        'bad'     { return @{ Fill = (RGB 253 240 238); Line = (RGB 240 185 178); Fore = $cDanger; Dash = $false } }
        'noexe'   { return @{ Fill = (RGB 253 240 238); Line = (RGB 240 185 178); Fore = $cDanger; Dash = $false } }
        default   { return @{ Fill = $cCard; Line = (RGB 200 200 200); Fore = (RGB 170 170 170); Dash = $true } }
    }
}

function Test-CellSelected($ci, [string]$key) { return $script:sel.ContainsKey("$ci|$key") }

# 열/행 전체 선택 대상 칸 (연결할 칸이 있으면 그 칸들, 없으면 해제할 칸들)
function Get-GroupPick($cells) {
    $sel = @()
    foreach ($c in @($cells)) { if ($c -and $c.Act -ne '') { $sel += $c } }
    $hasConn = $false
    foreach ($c in $sel) { if ($c.Act -eq 'conn') { $hasConn = $true } }
    $pick = @()
    foreach ($c in $sel) {
        if ($hasConn) { if ($c.Act -eq 'conn' -or $c.Act -eq 'both') { $pick += $c } }
        else { if ($c.Act -eq 'disc' -or $c.Act -eq 'both') { $pick += $c } }
    }
    return $pick
}
function Get-ColCells($ci) {
    $out = @()
    foreach ($it in $Items) {
        $cell = $script:grid.Cols[$ci].Cells[$it.Key]
        if ($cell.Act -ne '') { $out += [pscustomobject]@{ Ci = $ci; Key = $it.Key; Act = $cell.Act } }
    }
    return $out
}
function Get-RowCells([string]$key) {
    $out = @()
    for ($ci = 0; $ci -lt $script:grid.Cols.Count; $ci++) {
        $cell = $script:grid.Cols[$ci].Cells[$key]
        if ($cell.Act -ne '') { $out += [pscustomobject]@{ Ci = $ci; Key = $key; Act = $cell.Act } }
    }
    return $out
}
function Test-AllSelected($pick) {
    if (@($pick).Count -eq 0) { return $false }
    foreach ($p in @($pick)) { if (-not (Test-CellSelected $p.Ci $p.Key)) { return $false } }
    return $true
}

$gridPanel.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $g.Clear($cCard)
    $script:gridHits = @()
    $gd = $script:grid
    $w = $s.Width
    if (-not $gd -or $gd.Cols.Count -eq 0) {
        Draw-Txt $g '등록된 클라이언트가 없습니다. 위의 [＋ 클라이언트 추가]로 클라이언트를 찾아 등록하세요.' $fontBase (Rc 0 0 $w $s.Height) $cSub 'HorizontalCenter,VerticalCenter,SingleLine'
        return
    }
    $labW = S 200; $headH = S 78; $rowH = S 56
    $n = $gd.Cols.Count
    $colW = [int](($w - $labW) / $n)
    Draw-Txt $g '폴더' $fontBase (Rc (S 8) (S 4) ($labW - (S 8)) (S 30)) $cSub 'Left,VerticalCenter,SingleLine'
    # 동기화가 필요한 클라이언트 열: 머리부터 마지막 칸까지 연한 빨강 배경 (칸 색은 그대로)
    for ($ci = 0; $ci -lt $n; $ci++) {
        $col = $gd.Cols[$ci]
        if ($col.Role -ne 'src' -and [string]$script:csync[$col.Path] -eq 'need') {
            Draw-Round $g (Rc ($labW + $ci * $colW + (S 1)) 0 ($colW - (S 2)) ($headH + @($Items).Count * $rowH)) $cNeedFill $cNeedBand 1 $false (S 10)
        }
    }
    for ($ci = 0; $ci -lt $n; $ci++) {
        $col = $gd.Cols[$ci]
        $x = $labW + $ci * $colW
        $nameW = $colW - (S 40) - (S 70)
        if ($col.Role -eq 'src') {
            Draw-Txt $g $col.Name $fontBold (Rc ($x + (S 8)) (S 4) ($colW - (S 16)) (S 30)) $cText
        } else {
            $pick = @(Get-GroupPick (Get-ColCells $ci))
            $all = Test-AllSelected $pick
            $rb = Rc ($x + (S 8)) (S 10) (S 18) (S 18)
            if ($pick.Count -gt 0) { Draw-Check $g $rb $all } else { Draw-Round $g $rb (RGB 242 242 242) (RGB 205 205 205) 1.5 $false (S 4) }
            Draw-Txt $g $col.Name $fontBold (Rc ($x + (S 32)) (S 4) $nameW (S 30)) $cText
            if ($pick.Count -gt 0) {
                $t = '전체 선택'; if ($all) { $t = '전체 선택됨' }
                Draw-Txt $g $t $fontSmall (Rc ($x + $colW - (S 12) - (S 70)) (S 4) (S 70) (S 30)) $cAccent 'Right,VerticalCenter,SingleLine'
                Add-Hit 'grid' (Rc $x 0 $colW (S 36)) 'col' $ci
            }
        }
    }
    for ($ci = 0; $ci -lt $n; $ci++) {
        $x = $labW + $ci * $colW
        $col = $gd.Cols[$ci]
        $isS = ($col.Role -eq 'src')
        $bc = $cOk; $bt = '링크'; if ($isS) { $bc = $cAccent; $bt = '원본' }
        $by = S 42
        $bw1 = Draw-Badge $g ($x + (S 8)) $by $bt $bc (S 46)
        $bx2 = $x + (S 8) + $bw1 + (S 6)
        if ($isS) {
            $sver = $script:cver[$col.Path]
            if ($sver) { [void](Draw-Badge $g $bx2 $by $sver.Content $cAccent (S 46)) }
        } else {
            [void](Draw-Badge $g $bx2 $by (Get-SyncText ([string]$script:csync[$col.Path])) (Get-SyncColor ([string]$script:csync[$col.Path])) (S 46))
        }
    }
    $ri = 0
    foreach ($it in $Items) {
        $y = $headH + $ri * $rowH
        $pick = @(Get-GroupPick (Get-RowCells $it.Key))
        $all = Test-AllSelected $pick
        $rb = Rc (S 8) ($y + (S 10)) (S 18) (S 18)
        if ($pick.Count -gt 0) { Draw-Check $g $rb $all } else { Draw-Round $g $rb (RGB 242 242 242) (RGB 205 205 205) 1.5 $false (S 4) }
        Draw-Txt $g $it.Key $fontBold (Rc (S 32) ($y + (S 6)) ($labW - (S 40)) (S 26)) $cText
        $subp = $it.Sub -replace '^Client\\', ''
        Draw-Txt $g $subp $fontSmall (Rc (S 32) ($y + (S 32)) ($labW - (S 40)) (S 20)) $cSub
        if ($pick.Count -gt 0) { Add-Hit 'grid' (Rc 0 $y $labW $rowH) 'row' -1; $script:gridHits[$script:gridHits.Count - 1].K = $it.Key }
        for ($ci = 0; $ci -lt $n; $ci++) {
            $cell = $gd.Cols[$ci].Cells[$it.Key]
            $x = $labW + $ci * $colW
            $r = Rc ($x + (S 4)) ($y + (S 3)) ($colW - (S 8)) ($rowH - (S 6))
            $sty = Get-CellStyle $cell.Kind
            $selected = Test-CellSelected $ci $it.Key
            Draw-Round $g $r $sty.Fill $sty.Line 1 $sty.Dash (S 8)
            if ($selected) { Draw-Round $g (Rc ($r.X - 1) ($r.Y - 1) ($r.Width + 2) ($r.Height + 2)) $null $cAccent 2.5 $false (S 8) }
            $tw = $r.Width - (S 20); if ($cell.Act -ne '') { $tw = $r.Width - (S 44) }
            Draw-Txt $g $cell.Title $fontCell (Rc ($r.X + (S 10)) ($r.Y + (S 6)) $tw (S 22)) $sty.Fore
            $fl = 'Left,VerticalCenter,SingleLine,EndEllipsis'
            if ($cell.Kind -eq 'other' -or $cell.Kind -eq 'srclink') { $fl = 'Left,VerticalCenter,SingleLine,PathEllipsis' }
            if ($cell.Sub) { Draw-Txt $g $cell.Sub $fontSmall (Rc ($r.X + (S 10)) ($r.Y + (S 28)) ($r.Width - (S 20)) (S 20)) $cSub $fl }
            if ($cell.Act -ne '') {
                Draw-Check $g (Rc ($r.Right - (S 28)) ($r.Y + (S 8)) (S 16) (S 16)) $selected
                Add-Hit 'grid' $r 'cell' $ci
                $script:gridHits[$script:gridHits.Count - 1].K = $it.Key
            }
        }
        $ri++
    }
})

# ---------------------------------------------------------------- 선택 정보 / 버튼 / 요약

$lblSelInfo = New-Object Windows.Forms.Label
$lblSelInfo.AutoSize = $false; $lblSelInfo.BackColor = (RGB 238 245 253); $lblSelInfo.ForeColor = (RGB 18 74 133)
$lblSelInfo.TextAlign = 'MiddleLeft'; $lblSelInfo.Padding = New-Object Windows.Forms.Padding((S 12), 0, (S 8), 0)
$lblSelInfo.Text = ''
$form.Controls.Add($lblSelInfo)

$mBtnConn  = New-Button '링크 연결' $true $form
$mBtnDisc  = New-Button '링크 해제' $false $form
$mBtnRef   = New-Button '새로 고침' $false $form
$mBtnBroken = New-Button '깨진 링크 정리' $false $form
$mBtnClean = New-Button '백업 삭제' $false $form
$mBtnSync  = New-Button '업데이트 후 동기화' $false $form
$mBtnSync.Tag.Style = 'danger'     # 빨간 버튼 (활성 조건은 Test-SyncNeeded 로 준비만 해 둠, 아직 적용하지 않음)
$lblSum = New-Object Windows.Forms.Label
$lblSum.AutoSize = $false; $lblSum.ForeColor = $cSub; $lblSum.BackColor = $cBg; $lblSum.TextAlign = 'MiddleLeft'
$form.Controls.Add($lblSum)

$createCtls = @($cardSrc, $cardDst, $lblArrow, $cardOpt, $btnPrev, $lblCap2, $btnRun, $btnUndo, $btnClean, $flowA1, $flowA2, $lblStatus)
$manageCtls = @($cardClients, $cardGrid, $lblSelInfo, $mBtnConn, $mBtnDisc, $mBtnRef, $mBtnBroken, $mBtnClean, $mBtnSync, $lblSum)
foreach ($c in $manageCtls) { $c.Visible = $false }

# ---------------------------------------------------------------- 현황 계산

function Build-Grid {
    $script:cstate = @{}; $script:clinked = @{}
    $script:cver = @{}; $script:csync = @{}
    $cols = @()
    $srcCl = $null
    foreach ($c in $script:clients) { if ($c.Role -eq 'src' -and -not $srcCl) { $srcCl = $c } }
    $ss = $null; $srcOk = $false
    if ($srcCl) { $ss = Get-State $srcCl.Path; $srcOk = [bool]($ss -and $ss.Exe) }
    $srcVer = $null
    if ($srcOk) { $srcVer = Get-ClientVersion $ss.Game }
    $srcInfo = @{}; $srcStat = @{}
    if ($srcOk) {
        foreach ($it in $Items) {
            $p = Join-Path $ss.Game $it.Sub
            $li = Get-LinkInfo $p
            $srcInfo[$it.Key] = $li
            if ($li.Kind -eq 'dir') { $srcStat[$it.Key] = Get-DirStat $p }
        }
    }
    $saved = [long]0; $backups = 0; $check = 0; $broken = 0
    $idx = 0
    foreach ($c in $script:clients) {
        $st = Get-State $c.Path
        $script:cstate[$c.Path] = $st
        $exeOk = [bool]($st -and $st.Exe)
        $ver = $null
        if ($exeOk) { $ver = Get-ClientVersion $st.Game }
        $script:cver[$c.Path] = $ver
        if ($c.Role -ne 'src') {
            $lk = [bool]($srcOk -and $exeOk -and (Test-LinkedToSource $ss.Game $st.Game))
            $script:csync[$c.Path] = $(if ($lk) { Get-SyncState $srcVer $ver } else { 'unknown' })
        }
        $cells = @{}
        foreach ($it in $Items) {
            $li = @{ Kind = 'none' }
            if ($exeOk) { $li = Get-LinkInfo (Join-Path $st.Game $it.Sub) }
            $kind = ''; $act = ''; $stat = $null
            if ($c.Role -eq 'src') {
                $kind = Get-SrcCellKind $li $exeOk
                if ($kind -eq 'src') { $stat = $srcStat[$it.Key] }
            } else {
                $sp = ''; $si = $null
                if ($srcOk) { $sp = Join-Path $ss.Game $it.Sub; $si = $srcInfo[$it.Key] }
                $ck = Get-CellKind $si $li $sp $exeOk
                $kind = $ck.Kind; $act = $ck.Act
                if ($kind -eq 'real') { $stat = Get-DirStat (Join-Path $st.Game $it.Sub) }
                if ($kind -eq 'ok' -and $srcStat[$it.Key]) { $saved += $srcStat[$it.Key].Bytes }
            }
            if ($kind -in @('broken', 'other', 'srclink', 'bad')) { $check++ }
            if ($kind -eq 'broken') { $broken++ }
            $lab = Get-CellLabel $kind $li $stat $srcOk
            $cells[$it.Key] = @{ Kind = $kind; Act = $act; Title = $lab.Title; Sub = $lab.Sub; Bytes = $(if ($stat) { $stat.Bytes } else { [long]0 }) }
            if ($exeOk) { $backups += @(Get-ItemBackups $st.Game $it).Count }
        }
        $cols += @{ Idx = $idx; Name = $c.Name; Role = $c.Role; Path = $c.Path; ExeOk = $exeOk; Cells = $cells }
        $idx++
    }
    $script:grid = @{ Cols = $cols; Saved = $saved; Backups = $backups; Check = $check; Broken = $broken; HasSrc = $srcOk }
}

function Get-SelCells {
    $out = @()
    if (-not $script:grid) { return $out }
    for ($ci = 0; $ci -lt $script:grid.Cols.Count; $ci++) {
        foreach ($it in $Items) {
            if (Test-CellSelected $ci $it.Key) { $out += [pscustomobject]@{ Ci = $ci; Key = $it.Key } }
        }
    }
    return $out
}

function Update-ManageUi {
    $gd = $script:grid
    $cells = @(Get-SelCells)
    $acts = @(); $realBytes = [long]0
    foreach ($c in $cells) {
        $cell = $gd.Cols[$c.Ci].Cells[$c.Key]
        $acts += $cell.Act
        if ($cell.Kind -eq 'real') { $realBytes += $cell.Bytes }
    }
    $mode = Get-SelMode $acts
    if (-not $script:busy) {
        $mBtnConn.Enabled = ($gd -and $gd.HasSrc -and ($mode -eq 'conn' -or $mode -eq 'either'))
        $mBtnDisc.Enabled = ($mode -eq 'disc' -or $mode -eq 'either')
        $mBtnBroken.Enabled = [bool]($gd -and $gd.Broken -gt 0)
        $mBtnClean.Enabled = ($gd -and $gd.Backups -gt 0)
    }
    if ($cells.Count -eq 0) {
        $lblSelInfo.Text = '원하는 작업을 선택하세요.'
    } else {
        $parts = @()
        for ($ci = 0; $ci -lt $gd.Cols.Count; $ci++) {
            $ks = @($cells | Where-Object { $_.Ci -eq $ci } | ForEach-Object { $_.Key })
            if ($ks.Count -gt 0) { $parts += ('{0}: {1}' -f $gd.Cols[$ci].Name, ($ks -join ', ')) }
        }
        $t = ('선택 {0}칸  ·  {1}' -f $cells.Count, ($parts -join '  /  '))
        switch ($mode) {
            'conn'   { $t += ('  →  연결 시 약 {0} 절약 예상' -f (Format-Size $realBytes)) }
            'disc'   { $t += '  →  링크 해제 (백업 복원 · 원본에서 복사 · 비워두기 중 선택)' }
            'either' { $t += '  →  링크 연결 또는 링크 해제할 수 있습니다' }
            'mixed'  { $t += '  (연결할 칸과 해제할 칸은 한 번에 함께 선택할 수 없습니다)' }
        }
        $lblSelInfo.Text = $t
    }
    if ($gd) {
        $lblSum.Text = ('절약 중인 용량 약 {0}   ·   남은 백업 {1}개   ·   점검 필요 {2}건' -f (Format-Size $gd.Saved), $gd.Backups, $gd.Check)
        if ($gd.Check -gt 0) { $lblSum.ForeColor = $cDanger } else { $lblSum.ForeColor = $cSub }
    }
    $slotPanel.Invalidate(); $gridPanel.Invalidate()
}

function Refresh-Manage([bool]$clearCache = $false) {
    if ($clearCache) { $script:sizeCache = @{} }
    $form.UseWaitCursor = $true
    [Windows.Forms.Application]::DoEvents()
    try { Build-Grid } finally { $form.UseWaitCursor = $false }
    # 더 이상 선택할 수 없는 칸은 선택 해제
    foreach ($k in @($script:sel.Keys)) {
        $p = $k -split '\|'
        $ci = [int]$p[0]
        $ok = $false
        if ($ci -lt $script:grid.Cols.Count) { $cell = $script:grid.Cols[$ci].Cells[$p[1]]; if ($cell -and $cell.Act -ne '') { $ok = $true } }
        if (-not $ok) { $script:sel.Remove($k) }
    }
    Update-ManageUi
    Update-GuideAuto
}

# ---------------------------------------------------------------- 창 크기 / 탭 전환

function Fit-Window {
    if ($form.WindowState -ne 'Normal') { Do-Layout; return }
    $script:fitting = $true
    try {
        $script:autoSize = $true
        Do-Layout
        $want = $cardLog.Bottom + (S 16)
        $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
        $frame = $form.Height - $form.ClientSize.Height
        $max = $wa.Height - $frame
        if ($want -gt $max) { $want = $max; $script:autoSize = $false }
        $script:autoH = $want
        $form.ClientSize = New-Object Drawing.Size($form.ClientSize.Width, $want)
        Do-Layout
        if ($form.Bottom -gt $wa.Bottom) { $form.Top = [Math]::Max($wa.Top, $wa.Bottom - $form.Height) }
        $form.Invalidate($true)
    } finally { $script:fitting = $false }
}

function Switch-Tab([string]$name) {
    if ($script:tab -eq $name) { return }
    $script:tab = $name
    foreach ($c in $createCtls) { $c.Visible = ($name -eq 'create') }
    foreach ($c in $manageCtls) { $c.Visible = ($name -eq 'manage') }
    $tabBar.Invalidate()
    if ($name -eq 'manage') {
        Refresh-Manage $true
        $script:manageShown = $true
    }
    Fit-Window
}

# ---------------------------------------------------------------- 공용 대화상자

function New-DialogForm([string]$title, [int]$w, [int]$h) {
    $dg = New-Object Windows.Forms.Form
    $dg.Text = $title; $dg.Font = $fontBase; $dg.BackColor = $cBg; $dg.AutoScaleMode = 'None'
    $dg.FormBorderStyle = 'FixedDialog'; $dg.MaximizeBox = $false; $dg.MinimizeBox = $false
    $dg.ShowInTaskbar = $false; $dg.StartPosition = 'CenterParent'
    $dg.ClientSize = New-Object Drawing.Size((S $w), (S $h))
    return $dg
}
function Add-DlgControl($dg, $ctl, $x, $y, $w, $h) {
    $ctl.Location = New-Object Drawing.Point((S $x), (S $y))
    $ctl.Size = New-Object Drawing.Size((S $w), (S $h))
    $dg.Controls.Add($ctl)
    return $ctl
}
function New-DlgLabel([string]$text, $color = $null) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.BackColor = [Drawing.Color]::Transparent
    if ($color) { $l.ForeColor = $color } else { $l.ForeColor = $cText }
    return $l
}

# 이름 입력 (취소하면 $null). $taken = 이미 사용 중인 이름
function Show-NameDialog([string]$title, [string]$prompt, [string]$default, [string[]]$taken) {
    $dg = New-DialogForm $title 420 170
    $script:nd = @{ Result = $null; Taken = $taken; Form = $dg }
    [void](Add-DlgControl $dg (New-DlgLabel $prompt) 16 16 388 22)
    $script:nd.Txt = New-Object Windows.Forms.TextBox
    $script:nd.Txt.Text = $default; $script:nd.Txt.MaxLength = 20
    [void](Add-DlgControl $dg $script:nd.Txt 16 46 388 26)
    $btnOk = New-Object Windows.Forms.Button; $btnOk.Text = '확인'
    $btnCancel = New-Object Windows.Forms.Button; $btnCancel.Text = '취소'
    [void](Add-DlgControl $dg $btnOk 188 108 100 34)
    [void](Add-DlgControl $dg $btnCancel 304 108 100 34)
    $dg.AcceptButton = $btnOk; $dg.CancelButton = $btnCancel
    $btnOk.Add_Click({
        $n = $script:nd.Txt.Text.Trim()
        if (-not $n) { [void][Windows.Forms.MessageBox]::Show($script:nd.Form, '이름을 입력해 주세요.', '이름', 'OK', 'Information'); return }
        if ($script:nd.Taken | Where-Object { $_ -ieq $n }) { [void][Windows.Forms.MessageBox]::Show($script:nd.Form, '이미 사용 중인 이름입니다.', '이름', 'OK', 'Information'); return }
        $script:nd.Result = $n
        $script:nd.Form.DialogResult = [Windows.Forms.DialogResult]::OK
    })
    $dg.Add_Shown({ $script:nd.Txt.Focus(); $script:nd.Txt.SelectAll() })
    [void]$dg.ShowDialog($form)
    $dg.Dispose()
    return $script:nd.Result
}

# 등록 대화상자: 이름과 역할을 정한다. $entries = @(@{ Path; Suggest = 'src'|'link' })
# 반환: @(@{ Path; Name; Role }) 또는 $null
function Show-RegisterDialog($entries) {
    $entries = @($entries)
    $hasSrc = (@($script:clients | Where-Object { $_.Role -eq 'src' }).Count -gt 0)
    $rowH = 116
    $dg = New-DialogForm '클라이언트 이름 정하기' 580 (60 + $rowH * $entries.Count + 64)
    $script:rd = @{ Result = $null; Form = $dg; Rows = @(); HasSrc = $hasSrc }
    $lbl = New-DlgLabel '이름은 직접 정합니다. 등록 후 [✎ 수정]으로 바꿀 수 있습니다.' $cSub
    [void](Add-DlgControl $dg $lbl 16 12 548 22)
    $taken = @($script:clients | ForEach-Object { $_.Name })
    $y = 40
    foreach ($en in $entries) {
        $box = New-Object Windows.Forms.GroupBox
        $box.Text = ''
        [void](Add-DlgControl $dg $box 16 $y 548 ($rowH - 8))
        $lp = New-DlgLabel $en.Path $cText; $lp.Font = $fontBold; $lp.AutoEllipsis = $true
        [void](Add-DlgControl $box $lp 12 12 524 22)
        [void](Add-DlgControl $box (New-DlgLabel '이름') 12 46 50 22)
        $nm = Get-DefaultName $taken
        $taken += $nm
        $txt = New-Object Windows.Forms.TextBox; $txt.Text = $nm; $txt.MaxLength = 20
        [void](Add-DlgControl $box $txt 66 42 220 26)
        $pn = New-Object Windows.Forms.Panel
        [void](Add-DlgControl $box $pn 300 38 236 34)
        $rbL = New-Object Windows.Forms.RadioButton; $rbL.Text = '링크 대상'
        $rbS = New-Object Windows.Forms.RadioButton; $rbS.Text = '원본'
        [void](Add-DlgControl $pn $rbL 0 4 100 26)
        [void](Add-DlgControl $pn $rbS 108 4 120 26)
        $stx = Get-State $en.Path
        $canSrc = [bool]($stx -and $stx.Launcher -and $stx.Exe -and (@(Get-LinkedFixed $stx.Game).Count -eq 0))
        if ($hasSrc -or -not $canSrc) { $rbS.Enabled = $false; $rbL.Checked = $true }
        elseif ($en.Suggest -eq 'src') { $rbS.Checked = $true } else { $rbL.Checked = $true }
        $hint = New-DlgLabel '' $cSub; $hint.Font = $fontSmall
        if ($hasSrc) { $hint.Text = '원본은 이미 등록되어 있습니다. 바꾸려면 기존 원본을 [제거]한 뒤 등록하세요.' }
        elseif (-not $canSrc) { $hint.Text = '런처와 구성 파일이 모두 있고 실제 폴더를 가진 클라이언트만 원본이 될 수 있습니다.' }
        else { $hint.Text = '원본은 1개만 지정할 수 있습니다. 링크가 가리킬 실제 파일이 있는 클라이언트입니다.' }
        [void](Add-DlgControl $box $hint 12 80 524 20)
        $script:rd.Rows += @{ Path = $en.Path; Txt = $txt; RbSrc = $rbS }
        $y += $rowH
    }
    $btnOk = New-Object Windows.Forms.Button; $btnOk.Text = '등록'
    $btnCancel = New-Object Windows.Forms.Button; $btnCancel.Text = '취소'
    [void](Add-DlgControl $dg $btnOk 348 ($y + 8) 100 34)
    [void](Add-DlgControl $dg $btnCancel 464 ($y + 8) 100 34)
    $dg.AcceptButton = $btnOk; $dg.CancelButton = $btnCancel
    $btnOk.Add_Click({
        $res = @(); $names = @(); $srcCnt = 0
        foreach ($r in $script:rd.Rows) {
            $n = $r.Txt.Text.Trim()
            if (-not $n) { [void][Windows.Forms.MessageBox]::Show($script:rd.Form, '이름을 입력해 주세요.', '등록', 'OK', 'Information'); return }
            if ($names | Where-Object { $_ -ieq $n }) { [void][Windows.Forms.MessageBox]::Show($script:rd.Form, ('같은 이름이 있습니다: ' + $n), '등록', 'OK', 'Information'); return }
            if ($script:clients | Where-Object { $_.Name -ieq $n }) { [void][Windows.Forms.MessageBox]::Show($script:rd.Form, ('이미 사용 중인 이름입니다: ' + $n), '등록', 'OK', 'Information'); return }
            $names += $n
            $role = 'link'; if ($r.RbSrc.Checked) { $role = 'src'; $srcCnt++ }
            $res += @{ Path = $r.Path; Name = $n; Role = $role }
        }
        if ($srcCnt -gt 1) { [void][Windows.Forms.MessageBox]::Show($script:rd.Form, '원본은 1개만 지정할 수 있습니다.', '등록', 'OK', 'Information'); return }
        $script:rd.Result = $res
        $script:rd.Form.DialogResult = [Windows.Forms.DialogResult]::OK
    })
    [void]$dg.ShowDialog($form)
    $dg.Dispose()
    return $script:rd.Result
}

# 등록 처리 (슬롯 수 확인 → 이름/역할 정하기 → 저장)
function Start-Register($paths, $suggest) {
    $left = $MaxClients - $script:clients.Count
    if ($left -le 0) { Show-Warn ('클라이언트는 최대 {0}개까지 등록할 수 있습니다. 먼저 [제거]로 자리를 비워 주세요.' -f $MaxClients) '알림'; return $false }
    $entries = @()
    foreach ($p in $paths) {
        $st = Get-State $p
        if (-not $st -or -not ($st.Launcher -or $st.Exe)) { Show-Warn ("명조 클라이언트(launcher.exe 또는 구성 파일)를 찾을 수 없습니다:`r`n" + $p) '알림'; continue }
        if ($script:clients | Where-Object { (Get-NormPath $_.Path) -ieq (Get-NormPath $st.Root) }) { Show-Warn ("이미 등록된 클라이언트입니다:`r`n" + $st.Root) '알림'; continue }
        if ($entries | Where-Object { $_.Path -ieq $st.Root }) { continue }
        $sg = 'link'
        if ($suggest -and $suggest[$st.Root]) { $sg = $suggest[$st.Root] }
        $entries += @{ Path = $st.Root; Suggest = $sg }
    }
    if ($entries.Count -eq 0) { return $false }
    if ($entries.Count -gt $left) {
        Show-Warn ('등록 가능한 자리는 {0}개입니다. 앞에서부터 {0}개만 등록합니다.' -f $left) '알림'
        $entries = @($entries | Select-Object -First $left)
    }
    $res = Show-RegisterDialog $entries
    if (-not $res) { return $false }
    foreach ($r in $res) { $script:clients += @{ Name = $r.Name; Path = $r.Path; Role = $r.Role } }
    $script:clients = @(Sort-Clients $script:clients)
    [void](Save-AppSettings)
    foreach ($r in $res) { Log ('[등록] {0}  ({1})  {2}' -f $r.Name, $(if ($r.Role -eq 'src') { '원본' } else { '링크 대상' }), $r.Path) }
    $script:sel = @{}
    if ($script:tab -eq 'manage') { Refresh-Manage }
    return $true
}

# [링크 생성] 탭에서 링크를 만든 뒤, 아직 등록되지 않은 원본/대상을 [링크 관리] 목록에 등록할지 묻습니다.
function Offer-Register([string]$srcRoot, [string]$dstRoot) {
    $list = @(); $sug = @{}; $lines = @()
    foreach ($e in @(@{ P = $srcRoot; S = 'src'; L = '원본' }, @{ P = $dstRoot; S = 'link'; L = '대상' })) {
        if (-not $e.P) { continue }
        if ($script:clients | Where-Object { (Get-NormPath $_.Path) -ieq (Get-NormPath $e.P) }) { continue }
        $list += $e.P; $sug[$e.P] = $e.S; $lines += ('- {0}: {1}' -f $e.L, $e.P)
    }
    if ($list.Count -eq 0) { return }
    $ans = [Windows.Forms.MessageBox]::Show(("링크 관리 목록에 등록할까요?`r`n`r`n" + ($lines -join "`r`n")), '링크 관리에 등록', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    [void](Start-Register $list $sug)
}

# ---------------------------------------------------------------- 탐색 대화상자

function Show-ScanDialog([string]$Mode = 'register', [string]$BaseGame = '', [bool]$NeedReal = $false) {
    $ttl = '클라이언트 탐색'
    $dg = New-DialogForm $ttl 880 624
    $sd = @{ Mode = $Mode; BaseGame = $BaseGame; NeedReal = $NeedReal; Picked = $null; Form = $dg; Rows = @(); Seen = @{}; Scroll = 0; Scanning = $false; Cancel = $false; CloseAfter = $false; Registered = $false }
    $script:sd = $sd

    $sd.Notice = New-Object Windows.Forms.Label
    $sd.Notice.BackColor = (RGB 238 245 253); $sd.Notice.ForeColor = (RGB 18 74 133); $sd.Notice.TextAlign = 'MiddleLeft'
    $sd.Notice.Padding = New-Object Windows.Forms.Padding((S 12), 0, 0, 0)
    [void](Add-DlgControl $dg $sd.Notice 16 12 848 34)
    $nt = '버전 오차가 있을 수 있습니다. 런처가 최신 버전인지 먼저 확인해 주세요.'
    if ($NeedReal) { $nt += "`r`n가능하면 최신 버전을 원본으로 지정해 주세요." }
    $sd.NoticeText = $nt
    $sd.NoticeR = New-Object Windows.Forms.Panel
    $sd.NoticeR.BackColor = $dg.BackColor
    Set-DoubleBuffered $sd.NoticeR
    $sd.NoticeR.Visible = ($Mode -eq 'pick')
    [void](Add-DlgControl $dg $sd.NoticeR 360 136 400 52)
    $nw = 0
    foreach ($ln in @($nt -split "`r`n")) { $lw = [Windows.Forms.TextRenderer]::MeasureText($ln, $fontSmall).Width; if ($lw -gt $nw) { $nw = $lw } }
    $nw = $nw + (S 36)
    $sd.NoticeR.Width = $nw; $sd.NoticeR.Left = (S 864) - $nw
    $sd.NoticeR.Add_Paint({
        param($p, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $g.Clear($p.Parent.BackColor)
        $gp = Get-RoundPath 0.5 0.5 ($p.Width - 2) ($p.Height - 2) (S 8)
        $br = New-Object Drawing.SolidBrush([Drawing.Color]::White); $pen = New-Object Drawing.Pen((RGB 190 198 210), 1)
        $g.FillPath($br, $gp); $g.DrawPath($pen, $gp)
        $br.Dispose(); $pen.Dispose(); $gp.Dispose()
        $r = New-Object Drawing.Rectangle((S 8), (S 4), ($p.Width - (S 26)), ($p.Height - (S 8)))
        [Windows.Forms.TextRenderer]::DrawText($g, $script:sd.NoticeText, $fontSmall, $r, (RGB 52 68 92), [Windows.Forms.TextFormatFlags]'Right,VerticalCenter')
    })

    $ky = 62
    $lbDp = New-DlgLabel '탐색 정확도'; $lbDp.TextAlign = 'MiddleLeft'
    [void](Add-DlgControl $dg $lbDp 16 $ky 84 26)
    $sd.CmbAcc = New-Object Windows.Forms.ComboBox
    $sd.CmbAcc.DropDownStyle = 'DropDownList'
    [void]$sd.CmbAcc.Items.AddRange(@('빠름', '보통', '정확'))
    $sd.CmbAcc.SelectedIndex = @{ 3 = 0; 5 = 1; 7 = 2 }[[int]$script:settings.Depth]
    [void](Add-DlgControl $dg $sd.CmbAcc 104 $ky 84 26)
    $lbDr = New-DlgLabel '드라이브'; $lbDr.TextAlign = 'MiddleLeft'
    [void](Add-DlgControl $dg $lbDr 216 $ky 76 26)
    $sd.Drives = @()
    $dx = 294
    foreach ($d in @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
        $cb = New-Object Windows.Forms.CheckBox; $cb.Text = $d.Name.TrimEnd('\'); $cb.AutoSize = $false; $cb.Checked = $true
        $cb.TextAlign = 'MiddleLeft'; $cb.CheckAlign = 'MiddleLeft'
        [void](Add-DlgControl $dg $cb $dx $ky 48 26); $dx += 48
        $sd.Drives += $cb
    }

    $sd.BtnStart = New-Object Windows.Forms.Button; $sd.BtnStart.Text = '탐색 시작'
    $sd.BtnStop = New-Object Windows.Forms.Button; $sd.BtnStop.Text = '중지'; $sd.BtnStop.Enabled = $false
    # [탐색 시작] 은 파란 버튼, 오른쪽 위에 [중지] 와 나란히 배치
    $sd.BtnStart.FlatStyle = 'Flat'; $sd.BtnStart.FlatAppearance.BorderSize = 0; $sd.BtnStart.Cursor = 'Hand'
    $sd.BtnStart.Font = $fontBold; $sd.BtnStart.BackColor = $cAccent; $sd.BtnStart.ForeColor = [Drawing.Color]::White
    $sd.BtnStart.Add_SizeChanged({ param($b, $e)
        if ($b.Width -gt 0 -and $b.Height -gt 0) { $gp = Get-RoundPath 0 0 $b.Width $b.Height (S 8); $b.Region = New-Object Drawing.Region($gp); $gp.Dispose() } })
    $sd.BtnStart.Add_EnabledChanged({ param($b, $e) if ($b.Enabled) { $b.BackColor = $cAccent; $b.ForeColor = [Drawing.Color]::White } else { $b.BackColor = (RGB 160 196 240); $b.ForeColor = [Drawing.Color]::White } })
    [void](Add-DlgControl $dg $sd.BtnStart 666 ($ky - 4) 110 34)
    [void](Add-DlgControl $dg $sd.BtnStop 784 ($ky - 4) 80 34)
    # 상태 줄: 처음(안내)에는 [탐색 시작] 버튼 그림이 들어간 문장, 탐색 중/후에는 일반 문장
    $sd.LblStatus = New-Object Windows.Forms.Panel
    Set-DoubleBuffered $sd.LblStatus
    $sd.LblStatus.BackColor = $dg.BackColor
    $sd.Idle = $true
    $sd.LblStatus.Add_TextChanged({ param($p, $e) $script:sd.Idle = $false; $p.Invalidate() })
    $sd.LblStatus.Add_Paint({
        param($p, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $g.Clear($p.BackColor)
        if ($script:sd.Idle) {
            $segs = @(@{ T = '탐색 시작'; K = 'btn'; C = $cAccent }, @{ T = '으로 저장소 전체를 스캔합니다. 결과가 없으면 [찾아보기] 또는 폴더 드롭으로 수동 추가해주세요.'; A = $true })
            Draw-Segs $g $segs 0 ([int](($p.Height - (S 24)) / 2)) $cSub
        } else {
            $r = New-Object Drawing.Rectangle(0, 0, $p.Width, $p.Height)
            [Windows.Forms.TextRenderer]::DrawText($g, $p.Text, $fontBase, $r, $cSub, [Windows.Forms.TextFormatFlags]'Left,VerticalCenter,EndEllipsis,WordBreak')
        }
    })
    [void](Add-DlgControl $dg $sd.LblStatus 16 100 848 36)
    $sd.Prog = New-Object Windows.Forms.ProgressBar; $sd.Prog.Style = 'Marquee'; $sd.Prog.MarqueeAnimationSpeed = 30; $sd.Prog.Visible = $false
    [void](Add-DlgControl $dg $sd.Prog 16 142 848 6)

    $sd.LblList = New-DlgLabel '' $cText; $sd.LblList.Font = $fontBold
    [void](Add-DlgControl $dg $sd.LblList 16 154 848 22)

    $sd.List = New-Object Windows.Forms.Panel
    $sd.List.BackColor = $cCard; $sd.List.BorderStyle = 'FixedSingle'
    Set-DoubleBuffered $sd.List
    [void](Add-DlgControl $dg $sd.List 16 180 848 370)

    $sd.BtnReg = New-Object Windows.Forms.Button; $sd.BtnReg.Text = '선택 항목 등록'; if ($Mode -eq 'pick') { $sd.BtnReg.Text = '이 폴더 선택' }
    $btnClose = New-Object Windows.Forms.Button; $btnClose.Text = '닫기'
    $sd.BtnReg.FlatStyle = 'Flat'; $sd.BtnReg.FlatAppearance.BorderSize = 0; $sd.BtnReg.Cursor = 'Hand'
    $sd.BtnReg.Font = $fontBold; $sd.BtnReg.BackColor = $cAccent; $sd.BtnReg.ForeColor = [Drawing.Color]::White
    $sd.BtnReg.Add_SizeChanged({ param($b, $e)
        if ($b.Width -gt 0 -and $b.Height -gt 0) { $gp = Get-RoundPath 0 0 $b.Width $b.Height (S 8); $b.Region = New-Object Drawing.Region($gp); $gp.Dispose() } })
    $sd.BtnReg.Add_EnabledChanged({ param($b, $e) if ($b.Enabled) { $b.BackColor = $cAccent; $b.ForeColor = [Drawing.Color]::White } else { $b.BackColor = (RGB 160 196 240); $b.ForeColor = [Drawing.Color]::White } })
    [void](Add-DlgControl $dg $sd.BtnReg 16 564 150 38)
    [void](Add-DlgControl $dg $btnClose 748 564 116 38)
    $sd.LblMsg = New-DlgLabel '' $cSub; $sd.LblMsg.AutoEllipsis = $true
    [void](Add-DlgControl $dg $sd.LblMsg 182 573 556 22)

    if ($Mode -eq 'pick') {
        $sd.Notice.Visible = $false
        $shift = S 46
        $limit = $sd.BtnReg.Top - 1
        foreach ($c in @($dg.Controls)) {
            if ($c -eq $sd.Notice) { continue }
            if ($c.Top -lt $limit) { $c.Top = $c.Top - $shift }
        }
        $sd.List.Height = $sd.List.Height + $shift
        $gap = S 14
        $sd.LblList.Top = $sd.LblList.Top + $gap; $sd.List.Top = $sd.List.Top + $gap; $sd.List.Height = $sd.List.Height - $gap
        $sd.LblList.Width = (S 340)
        $sd.Prog.Width = (S 396)
    }

    # ---- 보조 함수 (스크립트 범위 변수 $script:sd 사용)
    $script:sdSlotsLeft = { $MaxClients - $script:clients.Count }
    $script:sdUpdateTexts = {
        $left = & $script:sdSlotsLeft
        if ($script:sd.Mode -eq 'pick') {
            $script:sd.LblList.Text = ('찾은 클라이언트 {0}개' -f $script:sd.Rows.Count)
            $script:sd.List.Invalidate()
            return
        }
        $script:sd.Notice.Text = ('ⓘ  클라이언트는 최대 {0}개(원본 1개 + 링크 {1}개)까지 등록·관리할 수 있습니다.     현재 등록 {2}개 · 추가 가능 {3}개' -f $MaxClients, ($MaxClients - 1), $script:clients.Count, $left)
        $cnt = @($script:sd.Rows | Where-Object { $_.Checked }).Count
        $script:sd.LblList.Text = ('찾은 클라이언트 {0}개   (체크한 항목을 등록 · 선택 {1}/{2})' -f $script:sd.Rows.Count, $cnt, $left)
        $script:sd.List.Invalidate()
    }
    $script:sdRefreshRoles = {
        if ($script:sd.Mode -eq 'pick') {
            # 원본 후보 순위: 1) 버전이 높은 쪽  2) 다른 클라이언트가 이미 연결해 쓰는 쪽(연결 수 많은 쪽)  3) 용량이 큰 쪽
            #  셋 다 같은 후보가 둘 이상이면 자동 추천 대신 '원본 후보'로 표시하고 직접 선택하게 함
            $rec = $null; $tied = @()
            $linkedBy = @{}
            if ($script:sd.NeedReal) {
                foreach ($c in $script:sd.Rows) {
                    if ($c.Flat -or -not $c.An -or -not $c.An.Exe -or $c.An.Linked -or -not $c.An.Ver) { continue }
                    $n = 0
                    foreach ($o in $script:sd.Rows) {
                        if ($o -eq $c -or $o.Flat -or -not $o.An) { continue }
                        foreach ($lg in @($o.An.LinkGames)) { if ((Get-NormPath $lg) -ieq (Get-NormPath $c.An.Game)) { $n++; break } }
                    }
                    $linkedBy[$c.Root] = $n
                    if (-not $rec) { $rec = $c; continue }
                    $va = [version]$c.An.Ver.Content; $vb = [version]$rec.An.Ver.Content
                    $nb = [int]$linkedBy[$rec.Root]
                    if ($va -gt $vb -or ($va -eq $vb -and ($n -gt $nb -or ($n -eq $nb -and $c.An.Bytes -gt $rec.An.Bytes)))) { $rec = $c }
                }
                if ($rec) {
                    foreach ($c in $script:sd.Rows) {
                        if (-not $linkedBy.ContainsKey($c.Root)) { continue }
                        if (([version]$c.An.Ver.Content) -eq ([version]$rec.An.Ver.Content) -and [int]$linkedBy[$c.Root] -eq [int]$linkedBy[$rec.Root] -and $c.An.Bytes -eq $rec.An.Bytes) { $tied += $c }
                    }
                }
            }
            foreach ($r in $script:sd.Rows) {
                $r.Role = ''; $r.Tag = ''; $r.Sub = ''; $r.Lvl = ''; $r.NoPick = $false
                $r.NoPickMsg = ''
                if ($script:sd.NeedReal -and $r.An -and $r.An.Linked) { $r.NoPick = $true; $r.NoPickMsg = '링크 상태라 실제 파일이 없어 원본으로 선택할 수 없습니다.'; $r.Tag = '링크 상태'; $r.Sub = '구성 파일 없음 · 원본으로 선택 불가'; $r.Lvl = 'bad'; continue }
                if ($script:sd.BaseGame -and $r.An -and $r.An.Game -and ((Get-NormPath $r.An.Game) -ieq (Get-NormPath $script:sd.BaseGame))) { $r.NoPick = $true; $r.NoPickMsg = '원본과 같은 클라이언트는 대상으로 선택할 수 없습니다.'; $r.Tag = '원본과 동일'; $r.Lvl = 'bad'; continue }
                if ($r.Flat) { $r.Tag = '구조 다름'; $r.Sub = '3.7 Steam 구조 · 선택 불가'; $r.Lvl = 'bad'; continue }
                if ($tied.Count -gt 1 -and ($tied -contains $r)) { $r.Tag = '원본 후보'; $r.Lvl = 'src'; $r.Sub = '최신 버전·용량 동일 (직접 선택)'; if ([int]$linkedBy[$r.Root] -gt 0) { $r.Sub = ('최신 버전·연결 {0}개 동일 (직접 선택)' -f [int]$linkedBy[$r.Root]) }; continue }
                if ($rec -and $r -eq $rec) { $r.Role = 'src'; $r.Tag = '원본 추천'; $r.Lvl = 'src'; $r.Sub = '최신 버전'; if ([int]$linkedBy[$r.Root] -gt 0) { $r.Sub = ('최신 버전 · {0}개 클라이언트가 연결 중' -f [int]$linkedBy[$r.Root]) }; continue }
                if ($script:sd.BaseGame -and $r.An -and $r.An.Game -and (Test-AlreadyLinked $script:sd.BaseGame $r.An.Game @(Get-SelectedKeys))) {
                    $r.Tag = '링크 구성됨'; $r.Sub = '이미 링크된 상태로 진행 불필요'; $r.Lvl = 'done'; continue
                }
                if ($script:sd.BaseGame) {
                    $cv = Get-LinkCompat $script:sd.BaseGame $r.An.Game @('Paks', 'UHD')
                    $r.Lvl = $cv.Level
                    if ($cv.Level -eq 'ok' -or $cv.Level -eq 'patch') { $r.Tag = '링크 가능'; $r.Sub = '' }
                    elseif ($cv.Level -eq 'minor') { $r.Tag = '링크 불가'; $r.Sub = $cv.Short }
                    else { $r.Tag = '확인 불가'; $r.Sub = '' }
                } elseif ($r.An -and $r.An.Ver) { $r.Tag = '버전 ' + $r.An.Ver.Content; $r.Lvl = 'ok' }
            }
            return
        }
        $src = $null
        foreach ($c in $script:clients) { if ($c.Role -eq 'src') { $src = $c } }
        $sg = ''; if ($src) { $st = Get-State $src.Path; if ($st) { $sg = $st.Game } }
        Set-RoleSuggestions $script:sd.Rows ([bool]$src) $sg
    }
    $script:sdAddRow = {
        param([string]$root, [bool]$flat = $false)
        if ($flat) {
            $fk = $root.ToLowerInvariant()
            if ($script:sd.Seen.ContainsKey($fk)) { return $false }
            $script:sd.Seen[$fk] = $true
            $script:sd.Rows += @{ Root = $root; An = $null; Already = $false; Flat = $true; NoPick = $false; Checked = $false; Role = ''; Tag = ''; Sub = ''; Lvl = '' }
            & $script:sdRefreshRoles
            & $script:sdUpdateTexts
            return $true
        }
        $st = Get-State $root
        if (-not $st) { return $false }
        $key = $st.Root.ToLowerInvariant()
        if ($script:sd.Seen.ContainsKey($key)) { return $false }
        $script:sd.Seen[$key] = $true
        $already = [bool]($script:clients | Where-Object { (Get-NormPath $_.Path) -ieq (Get-NormPath $st.Root) })
        $an = Get-ClientAnalysis $st.Root
        $row = @{ Root = $st.Root; An = $an; Already = $already; Flat = $false; NoPick = $false; Checked = $false; Role = ''; Tag = ''; Sub = ''; Lvl = '' }
        $left = & $script:sdSlotsLeft
        $cnt = @($script:sd.Rows | Where-Object { $_.Checked }).Count
        if ($script:sd.Mode -ne 'pick' -and -not $already -and $cnt -lt $left) { $row.Checked = $true }
        $script:sd.Rows += $row
        & $script:sdRefreshRoles
        & $script:sdUpdateTexts
        return $true
    }

    # ---- 목록 그리기
    $script:sdRowH = (S 78); $script:sdHeadH = (S 28)
    $sd.List.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $w = $s.ClientSize.Width
        $x0 = @((S 8), (S 40), (S 400), (S 530), (S 706))
        $heads = @('', '경로', '확인', '링크 대상 폴더 상태', '제안')
        for ($i = 1; $i -lt 5; $i++) { Draw-Txt $g $heads[$i] $fontSmall (Rc $x0[$i] 0 ($w - $x0[$i]) $script:sdHeadH) $cSub }
        $pen = New-Object Drawing.Pen($cBorder, 1); $g.DrawLine($pen, 0, $script:sdHeadH, $w, $script:sdHeadH); $pen.Dispose()
        $rows = @($script:sd.Rows)
        if ($rows.Count -eq 0) {
            Draw-Txt $g '[탐색 시작]을 누르면 찾은 클라이언트가 여기에 표시됩니다.' $fontBase (Rc 0 $script:sdHeadH $w ($s.ClientSize.Height - $script:sdHeadH)) $cSub 'HorizontalCenter,VerticalCenter,SingleLine'
            return
        }
        $g.SetClip((Rc 0 $script:sdHeadH $w ($s.ClientSize.Height - $script:sdHeadH)))
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $y = $script:sdHeadH + $i * $script:sdRowH - $script:sd.Scroll
            if ($y + $script:sdRowH -lt $script:sdHeadH -or $y -gt $s.ClientSize.Height) { continue }
            $dim = ($r.Already -and $script:sd.Mode -ne 'pick')
            $isFlat = [bool]$r.Flat
            $tc = $cText; if ($dim) { $tc = (RGB 170 170 170) }
            if ($script:sd.Mode -eq 'pick') { Draw-Radio $g (Rc $x0[0] ($y + (S 29)) (S 20) (S 20)) ([bool]$r.Checked) ([bool]($isFlat -or $r.NoPick)) }
            elseif ($dim -or $isFlat) { Draw-Round $g (Rc $x0[0] ($y + (S 29)) (S 18) (S 18)) (RGB 242 242 242) (RGB 205 205 205) 1.5 $false (S 4) }
            else { Draw-Check $g (Rc $x0[0] ($y + (S 29)) (S 18) (S 18)) ([bool]$r.Checked) }
            Draw-Txt $g $r.Root $fontPath (Rc $x0[1] ($y + (S 6)) ($x0[2] - $x0[1] - (S 10)) ($script:sdRowH - (S 12))) $tc 'Left,Top,WordBreak,EndEllipsis'
            $an = $r.An
            if ($isFlat) {
                Draw-Txt $g '3.7 Steam 구조 (launcher.exe 없음)' $fontBase (Rc $x0[2] ($y + (S 6)) ($x0[4] - $x0[2] - (S 10)) ($script:sdRowH - (S 12))) $cSub 'Left,Top,WordBreak,EndEllipsis'
            } elseif (-not $dim) {
                $l1 = '✖ 런처'; $c1 = $cDanger; if ($an.Launcher) { $l1 = '✔ 런처'; $c1 = $cOk }
                $l2 = '✖ 구성 파일'; $c2 = $cDanger; if ($an.Exe) { $l2 = '✔ 구성 파일'; $c2 = $cOk }
                if ($an.Exe -and $an.Linked) { $l2 = '✖ 구성 파일'; $c2 = $cDanger }
                Draw-Txt $g $l1 $fontBase (Rc $x0[2] ($y + (S 6)) ($x0[3] - $x0[2] - (S 10)) (S 22)) $c1
                Draw-Txt $g $l2 $fontBase (Rc $x0[2] ($y + (S 28)) ($x0[3] - $x0[2] - (S 10)) (S 22)) $c2
                $vt = '버전  –'; if ($an.Ver) { $vt = '버전  ' + $an.Ver.Content }
                Draw-Txt $g $vt $fontBase (Rc $x0[2] ($y + (S 50)) ($x0[3] - $x0[2] - (S 10)) (S 22)) $cText
                $sc = $cText
                if ($an.Color -eq 'ok') { $sc = $cOk } elseif ($an.Color -eq 'warn') { $sc = (RGB 180 95 0) } elseif ($an.Color -eq 'dim') { $sc = $cSub }
                Draw-Txt $g $an.Text $fontBase (Rc $x0[3] ($y + (S 6)) ($x0[4] - $x0[3] - (S 10)) ($script:sdRowH - (S 12))) $sc 'Left,Top,WordBreak,EndEllipsis'
            }
            # 제안
            $rt = Rc $x0[4] ($y + (S 10)) (S 100) (S 22)
            if ($r.Lvl) {
                $pc = (RGB 150 150 150)
                if ($r.Lvl -eq 'src') { $pc = $cAccent } elseif ($r.Lvl -eq 'ok') { $pc = $cOk } elseif ($r.Lvl -eq 'patch') { $pc = (RGB 200 120 0) } elseif ($r.Lvl -eq 'minor') { $pc = $cDanger } elseif ($r.Lvl -eq 'done') { $pc = (RGB 0 122 140) }
                Draw-Round $g $rt $pc $null 1 $false (S 11)
            }
            elseif ($r.Already) { Draw-Round $g $rt (RGB 150 150 150) $null 1 $false (S 11) }
            elseif ($r.Role -eq 'src') { Draw-Round $g $rt $cAccent $null 1 $false (S 11) }
            else { Draw-Round $g $rt $cOk $null 1 $false (S 11) }
            Draw-Txt $g $r.Tag $fontSmall $rt ([Drawing.Color]::White) 'HorizontalCenter,VerticalCenter,SingleLine'
            if ($r.Sub) { Draw-Txt $g $r.Sub $fontSmall (Rc $x0[4] ($y + (S 36)) ($w - $x0[4] - (S 4)) (S 40)) $cSub 'Left,Top,WordBreak,EndEllipsis' }
            $pen = New-Object Drawing.Pen((RGB 240 240 240), 1); $g.DrawLine($pen, 0, ($y + $script:sdRowH - 1), $w, ($y + $script:sdRowH - 1)); $pen.Dispose()
        }
        $g.ResetClip()
    })
    $sd.List.Add_MouseEnter({ param($s, $e) $s.Focus() })
    $sd.List.Add_MouseWheel({
        param($s, $e)
        $total = $script:sd.Rows.Count * $script:sdRowH
        $view = $s.ClientSize.Height - $script:sdHeadH
        $max = [Math]::Max(0, $total - $view)
        $v = $script:sd.Scroll - [int]([Math]::Sign($e.Delta) * $script:sdRowH)
        $script:sd.Scroll = [Math]::Min($max, [Math]::Max(0, $v))
        $s.Invalidate()
    })
    $sd.List.Add_MouseClick({
        param($s, $e)
        if ($e.Y -lt $script:sdHeadH) { return }
        $i = [int][Math]::Floor(($e.Y - $script:sdHeadH + $script:sd.Scroll) / $script:sdRowH)
        if ($i -lt 0 -or $i -ge $script:sd.Rows.Count) { return }
        $r = $script:sd.Rows[$i]
        if ($r.Flat) { $script:sd.LblMsg.Text = '3.7 Steam 구조는 링크할 수 없어 선택할 수 없습니다.'; return }
        if ($r.NoPick) { $script:sd.LblMsg.Text = [string]$r.NoPickMsg; return }
        if ($script:sd.Mode -eq 'pick') {
            foreach ($o in $script:sd.Rows) { $o.Checked = $false }
            $r.Checked = $true; $script:sd.LblMsg.Text = ''; $script:sd.List.Invalidate(); return
        }
        if ($r.Already) { $script:sd.LblMsg.Text = '이미 등록된 클라이언트입니다.'; return }
        if (-not $r.Checked) {
            $left = & $script:sdSlotsLeft
            $cnt = @($script:sd.Rows | Where-Object { $_.Checked }).Count
            if ($cnt -ge $left) { $script:sd.LblMsg.Text = ('최대 {0}개까지만 등록할 수 있어 더 선택할 수 없습니다.' -f $MaxClients); return }
        }
        $r.Checked = -not $r.Checked
        $script:sd.LblMsg.Text = ''
        & $script:sdUpdateTexts
    })

    # ---- 버튼 동작
    $sd.BtnStop.Add_Click({ $script:sd.Cancel = $true })
    $btnClose.Add_Click({ $script:sd.Form.Close() })
    $dg.Add_FormClosing({
        if ($script:sd.Scanning) { $_.Cancel = $true; $script:sd.Cancel = $true; $script:sd.CloseAfter = $true }
    })

    $sd.BtnReg.Add_Click({
        if ($script:sd.Mode -eq 'pick') {
            $pk = @($script:sd.Rows | Where-Object { $_.Checked -and -not $_.Flat -and -not $_.NoPick })
            if ($pk.Count -eq 0) { $script:sd.LblMsg.Text = '목록에서 하나를 선택해 주세요.'; return }
            $script:sd.Picked = $pk[0].Root; $script:sd.Form.Close(); return
        }
        $sel = @($script:sd.Rows | Where-Object { $_.Checked -and -not $_.Already })
        if ($sel.Count -eq 0) { $script:sd.LblMsg.Text = '등록할 항목을 체크해 주세요.'; return }
        $sug = @{}
        foreach ($r in $sel) { $sug[$r.Root] = $r.Role }
        $ok = Start-Register @($sel | ForEach-Object { $_.Root }) $sug
        if ($ok) { $script:sd.Registered = $true; $script:sd.Form.Close() }
    })

    $sd.BtnStart.Add_Click({
        $kws = @($script:settings.Keywords | Where-Object { $_ })
        $depthSel = @(3, 5, 7)[[Math]::Max(0, $script:sd.CmbAcc.SelectedIndex)]
        $roots = @($script:sd.Drives | Where-Object { $_.Checked } | ForEach-Object { $_.Text + '\' })
        $doD = ($kws.Count -gt 0 -and $roots.Count -gt 0)
        $script:settings.Depth = $depthSel
        [void](Save-AppSettings)
        $script:sd.Rows = @(); $script:sd.Seen = @{}; $script:sd.Scroll = 0
        & $script:sdUpdateTexts
        $script:sd.Cancel = $false; $script:sd.Scanning = $true
        $script:sd.BtnStart.Enabled = $false; $script:sd.BtnReg.Enabled = $false;
        $script:sd.BtnStop.Enabled = $true; $script:sd.Prog.Visible = $true; $script:sd.LblMsg.Text = ''
        $err = $null
        try {
            if (-not $script:sd.Cancel) {
                $script:sd.LblStatus.Text = '흔한 위치 확인 중...'; [Windows.Forms.Application]::DoEvents()
                foreach ($p in @(Find-ClientsQuick)) { [void](& $script:sdAddRow $p) }
            }
            if (-not $script:sd.Cancel) {
                $script:sd.LblStatus.Text = 'Steam 라이브러리 확인 중...'; [Windows.Forms.Application]::DoEvents()
                foreach ($p in @(Find-ClientsSteam)) { [void](& $script:sdAddRow $p) }
                foreach ($p in @(Find-ClientsSteamFlat)) { [void](& $script:sdAddRow $p $true) }
            }
            if ($doD -and -not $script:sd.Cancel) {
                [void](Find-ClientsDeep -Roots $roots -Keywords $kws -MaxDepth $depthSel `
                    -OnFound { param($p) [void](& $script:sdAddRow $p); [Windows.Forms.Application]::DoEvents() } `
                    -OnTick { param($dir, $n) $script:sd.LblStatus.Text = "정밀 탐색 중... $n 폴더 확인 · $dir"; [Windows.Forms.Application]::DoEvents() } `
                    -IsCancelled { [Windows.Forms.Application]::DoEvents(); $script:sd.Cancel })
            }
        } catch { $err = $_.Exception.Message }
        $cancelled = $script:sd.Cancel
        $script:sd.Scanning = $false
        if ($script:sd.CloseAfter) { $script:sd.Form.Close(); return }
        $script:sd.Prog.Visible = $false
        $script:sd.BtnStart.Enabled = $true; $script:sd.BtnReg.Enabled = $true;; $script:sd.BtnStop.Enabled = $false
        $head = '완료'; if ($err) { $head = '오류: ' + $err } elseif ($cancelled) { $head = '중지됨' }
        $nt = ''; if (-not $doD) { $nt = ' (드라이브가 선택되지 않아 정밀 탐색은 생략)' }
        $script:sd.LblStatus.Text = ('{0} · {1}개 발견{2}' -f $head, $script:sd.Rows.Count, $nt)
        & $script:sdUpdateTexts
    })

    & $script:sdUpdateTexts
    [void]$dg.ShowDialog($form)
    $dg.Dispose()
    if ($script:sd.Mode -eq 'pick') { return $script:sd.Picked }
    return $script:sd.Registered
}

# ---------------------------------------------------------------- 링크 생성 탭: 탐색 (1개 선택)

foreach ($side in 'src', 'dst') {
    $sb = New-Button '자동 탐색' $false $sides[$side].Card
    $sb.Name = $side
    $sides[$side].Scan = $sb
    $sb.Add_Click({ param($s, $e) Invoke-ScanPick $s.Name })
}

function Invoke-ScanPick([string]$side) {
    if ($script:busy) { return }
    $bv = ''
    if ($side -eq 'dst') { $ss = Get-State $script:paths.src; if ($ss) { $bv = $ss.Game } }
    $r = Show-ScanDialog 'pick' $bv ($side -eq 'src')
    if ($r) { Set-Side $side ([string]$r) }
}

# ---------------------------------------------------------------- 클라이언트 카드 동작

function Handle-SlotHit($h) {
    switch ($h.A) {
        'guide' { Show-GuideWindow $false }
        'add' {
            if ($script:clients.Count -ge $MaxClients) { Show-Warn ('클라이언트는 최대 {0}개까지 등록할 수 있습니다. 먼저 [제거]로 자리를 비워 주세요.' -f $MaxClients) '알림'; return }
            [void](Show-ScanDialog)
        }
        'edit' {
            $c = $script:clients[$h.I]
            $taken = @($script:clients | Where-Object { $_.Path -ne $c.Path } | ForEach-Object { $_.Name })
            $n = Show-NameDialog '이름 수정' ('[{0}] 의 새 이름' -f $c.Name) $c.Name $taken
            if ($n) { $old = $c.Name; $c.Name = $n; [void](Save-AppSettings); Log ('[이름 변경] {0} → {1}' -f $old, $n); Refresh-Manage }
        }
        'remove' {
            $c = $script:clients[$h.I]
            $ans = [Windows.Forms.MessageBox]::Show(("[{0}] 을(를) 목록에서 제거합니다.`r`n폴더나 링크는 변경되지 않고, 이 도구의 관리 목록에서만 빠집니다.`r`n`r`n계속할까요?" -f $c.Name), '제거 확인', 'YesNo', 'Question', 'Button2')
            if ($ans -ne 'Yes') { return }
            $script:clients = @(Sort-Clients @($script:clients | Where-Object { $_.Path -ne $c.Path }))
            $script:sel = @{}
            [void](Save-AppSettings); Log ('[제거] ' + $c.Name); Refresh-Manage
        }
    }
}
$slotPanel.Add_MouseClick({
    param($s, $e)
    if ($script:busy) { return }
    foreach ($h in @($script:slotHits)) { if ($h.R.Contains($e.Location)) { Handle-SlotHit $h; break } }
})
$slotPanel.Add_HandleCreated({ param($s, $e) [WWCLNative]::AllowDropMessages($s.Handle) })
$slotPanel.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop) -and -not $script:busy) { $e.Effect = [Windows.Forms.DragDropEffects]::Copy } })
$slotPanel.Add_DragDrop({
    param($s, $e)
    if ($script:busy) { return }
    $f = $e.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    if (-not $f) { return }
    $paths = @()
    foreach ($x in $f) { $p = [string]$x; if (Test-Path -LiteralPath $p -PathType Leaf) { $p = Split-Path $p -Parent }; $paths += $p }
    [void](Start-Register $paths @{})
})
$cardClients.AllowDrop = $true
$cardClients.Add_HandleCreated({ param($s, $e) [WWCLNative]::AllowDropMessages($s.Handle) })
$cardClients.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop) -and -not $script:busy) { $e.Effect = [Windows.Forms.DragDropEffects]::Copy } })
$cardClients.Add_DragDrop({
    param($s, $e)
    if ($script:busy) { return }
    $f = $e.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    if (-not $f) { return }
    $paths = @()
    foreach ($x in $f) { $p = [string]$x; if (Test-Path -LiteralPath $p -PathType Leaf) { $p = Split-Path $p -Parent }; $paths += $p }
    [void](Start-Register $paths @{})
})

# ---------------------------------------------------------------- 링크 현황 칸 선택

function Handle-GridHit($h) {
    $keep = $null
    switch ($h.A) {
        'cell' {
            $k = "$($h.I)|$($h.K)"
            if ($script:sel.ContainsKey($k)) { $script:sel.Remove($k) } else { $script:sel[$k] = $true; $keep = @($k) }
        }
        'col' {
            $pick = @(Get-GroupPick (Get-ColCells $h.I))
            if (Test-AllSelected $pick) { foreach ($p in $pick) { $script:sel.Remove("$($p.Ci)|$($p.Key)") } }
            else { foreach ($p in $pick) { $script:sel["$($p.Ci)|$($p.Key)"] = $true }; $keep = @($pick | ForEach-Object { "$($_.Ci)|$($_.Key)" }) }
        }
        'row' {
            $pick = @(Get-GroupPick (Get-RowCells $h.K))
            if (Test-AllSelected $pick) { foreach ($p in $pick) { $script:sel.Remove("$($p.Ci)|$($p.Key)") } }
            else { foreach ($p in $pick) { $script:sel["$($p.Ci)|$($p.Key)"] = $true }; $keep = @($pick | ForEach-Object { "$($_.Ci)|$($_.Key)" }) }
        }
    }
    # 연결할 칸과 해제할 칸이 섞이면 방금 고른 칸만 남긴다
    $acts = @()
    foreach ($c in @(Get-SelCells)) { $acts += $script:grid.Cols[$c.Ci].Cells[$c.Key].Act }
    if ((Get-SelMode $acts) -eq 'mixed' -and $keep) {
        $script:sel = @{}
        foreach ($k in $keep) { $script:sel[$k] = $true }
    }
    Update-ManageUi
}
$gridPanel.Add_MouseClick({
    param($s, $e)
    if ($script:busy) { return }
    foreach ($h in @($script:gridHits)) { if ($h.R.Contains($e.Location)) { Handle-GridHit $h; break } }
})

# ---------------------------------------------------------------- 연결 / 해제 / 정리

function Get-ItemByKey([string]$key) {
    foreach ($it in $Items) { if ($it.Key -eq $key) { return $it } }
    return $null
}

function Test-ManageSafety($ss, $targets, [bool]$needSymlink) {
    if (-not $ss) { return '원본 클라이언트의 구성 파일을 찾을 수 없습니다.' }
    return (Test-LinkSafety $ss $targets $needSymlink)
}

function Invoke-ManageConnect {
    $cells = @(Get-SelCells)
    if ($cells.Count -eq 0) { return }
    $srcCl = $null
    foreach ($c in $script:clients) { if ($c.Role -eq 'src') { $srcCl = $c } }
    if (-not $srcCl) { Show-Warn '원본 클라이언트가 지정되어 있지 않습니다.'; return }
    $ss = Get-State $srcCl.Path
    $targets = @()
    foreach ($ci in ($cells | ForEach-Object { $_.Ci } | Sort-Object -Unique)) {
        $cl = $script:clients[$ci]
        $keys = @($cells | Where-Object { $_.Ci -eq $ci } | ForEach-Object { $_.Key })
        $ds = Get-State $cl.Path
        $plan = @()
        if ($ds -and $ss) { $plan = @(Build-Plan $ss.Game $ds.Game $keys) }
        $targets += @{ Name = $cl.Name; Path = $cl.Path; Ds = $ds; Keys = $keys; Plan = $plan }
    }
    $err = Test-ManageSafety $ss $targets $true
    if ($err) { Show-Warn $err; return }
    $lines = @(); $todo = 0
    foreach ($t in $targets) {
        $lines += ('[{0}]' -f $t.Name)
        foreach ($a in $t.Plan) { $lines += ('- ' + (Get-PlanText $a)); if ($a.Kind -ne 'skip') { $todo++ } }
        $lines += ''
    }
    $vnotes = ''
    foreach ($t in $targets) { $vnotes += (Get-VersionNote $ss.Game $t.Ds.Game $t.Name $t.Keys) }
    if ($vnotes) { $lines += $vnotes }
    if ($todo -eq 0) { Show-Warn '할 일이 없습니다 (선택한 칸이 모두 이미 연결되어 있음).' '알림'; return }
    $msg = ("원본 [{0}] 기준으로 다음 링크를 구성합니다.`r`n`r`n{1}`r`n기존 폴더는 삭제하지 않고 _backup 으로 보관합니다.`r`n계속할까요?" -f $srcCl.Name, ($lines -join "`r`n"))
    $ans = [Windows.Forms.MessageBox]::Show($msg, '링크 확인', 'YesNo', 'Warning', 'Button2')
    if ($ans -ne 'Yes') { return }
    Set-Busy $true
    try {
        Start-LogFile 'connect'
        Log ''; Log ('[링크] 시작 (원본: {0})' -f $srcCl.Name)
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $okAll = $true
        $script:runRec = @()
        $sumLines = @()
        foreach ($t in $targets) {
            Log ('[{0}]' -f $t.Name)
            $nOk = 0; $nBad = 0; $nTotal = @($t.Plan | Where-Object { $_.Kind -ne 'skip' }).Count
            foreach ($a in $t.Plan) {
                $lblSum.Text = ('처리 중: {0} · {1}' -f $t.Name, $a.Sub)
                [Windows.Forms.Application]::DoEvents()
                if (Invoke-PlanItem $a $stamp) { if ($a.Kind -ne 'skip') { $nOk++ } } else { $okAll = $false; $nBad++; break }
            }
            $mark = '✔'; if ($nBad -gt 0) { $mark = '✖' }
            $sumLines += ('  {0} {1}: 성공 {2} / 전체 {3}{4}' -f $mark, $t.Name, $nOk, $nTotal, $(if ($nBad -gt 0) { ' (실패로 중단)' } else { '' }))
        }
        $script:runRec = @()
        Log '[결과 요약]'
        foreach ($sl in $sumLines) { Log $sl }
        if ($okAll) {
            Log '완료: 링크 구성이 끝났습니다. 각 런처에서 런처 실행과 [게임 복구]를 확인한 뒤 [백업 삭제]를 눌러 주세요.'
            Log $SyncGuide
        }
        else { Log '일부 항목에서 실패했습니다. 로그를 확인하세요.' }
    } catch { Log ('오류: ' + $_.Exception.Message) }
    finally { $script:sel = @{}; Set-Busy $false; Refresh-Manage $true }
}

# 링크 해제 방법 선택 창. 반환: 'restore' / 'copy' / 'empty' / $null(닫기)
function Show-UnlinkDialog($plan, [string]$title, [string]$summary) {
    $dg = New-DialogForm $title 600 430
    $ud = @{ Form = $dg; Plan = $plan; Sel = ''; Result = $null; Hits = @() }
    $script:ud = $ud
    $lb = New-DlgLabel $summary $cText; $lb.AutoEllipsis = $false
    [void](Add-DlgControl $dg $lb 16 12 568 44)
    $ud.Opts = @(
        @{ Key = 'restore'; Title = '백업 복원'; Desc = '백업으로부터 복원합니다.'; Ok = [bool]$plan.RestoreOk; Info = [string]$plan.RestoreInfo },
        @{ Key = 'copy';    Title = '원본에서 복사'; Desc = '원본으로부터 복사합니다.'; Ok = [bool]$plan.CopyOk; Info = [string]$plan.CopyInfo },
        @{ Key = 'empty';   Title = '비워두기'; Desc = '런처에서 새로 받아야 합니다.'; Ok = $true; Info = '링크만 삭제하고 빈 폴더로 둡니다' }
    )
    if ($plan.RestoreOk) { $ud.Sel = 'restore' }
    $pn = New-Object Windows.Forms.Panel
    $pn.BackColor = $cBg; Set-DoubleBuffered $pn
    [void](Add-DlgControl $dg $pn 16 64 568 300)
    $ud.Panel = $pn
    $pn.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $g.Clear($cBg)
        $script:ud.Hits = @()
        $bh = S 90; $gap = S 10
        for ($i = 0; $i -lt $script:ud.Opts.Count; $i++) {
            $o = $script:ud.Opts[$i]
            $r = Rc 0 ($i * ($bh + $gap)) ($s.Width - 1) $bh
            $sel = ($o.Ok -and $script:ud.Sel -eq $o.Key)
            if ($sel) { Draw-Round $g $r (RGB 244 249 255) $cAccent 2 $false (S 10) } else { Draw-Round $g $r $cCard $cBorder 1 $false (S 10) }
            Draw-Radio $g (Rc ($r.X + (S 16)) ($r.Y + (S 14)) (S 20) (S 20)) $sel (-not $o.Ok)
            $tc = $cText; $dc = $cText; $ic = $cSub
            if (-not $o.Ok) { $tc = (RGB 160 160 160); $dc = (RGB 170 170 170); $ic = $cDanger }
            Draw-Txt $g $o.Title $fontBold (Rc ($r.X + (S 48)) ($r.Y + (S 10)) ($r.Width - (S 64)) (S 26)) $tc
            Draw-Txt $g $o.Desc $fontBase (Rc ($r.X + (S 48)) ($r.Y + (S 38)) ($r.Width - (S 64)) (S 22)) $dc
            Draw-Txt $g $o.Info $fontSmall (Rc ($r.X + (S 48)) ($r.Y + (S 62)) ($r.Width - (S 64)) (S 20)) $ic
            $script:ud.Hits += @{ R = $r; Key = $o.Key; Ok = $o.Ok }
        }
    })
    $pn.Add_MouseClick({
        param($s, $e)
        foreach ($h in $script:ud.Hits) {
            if ($h.R.Contains($e.X, $e.Y) -and $h.Ok) { $script:ud.Sel = $h.Key; $script:ud.BtnRun.Enabled = $true; $s.Invalidate(); return }
        }
    })
    $ud.BtnRun = New-Object Windows.Forms.Button; $ud.BtnRun.Text = '진행'
    $ud.BtnRun.Enabled = [bool]$ud.Sel
    $btnX = New-Object Windows.Forms.Button; $btnX.Text = '닫기'
    [void](Add-DlgControl $dg $ud.BtnRun 364 376 108 38)
    [void](Add-DlgControl $dg $btnX 484 376 100 38)
    $dg.CancelButton = $btnX
    $ud.BtnRun.Add_Click({ $script:ud.Result = $script:ud.Sel; $script:ud.Form.DialogResult = [Windows.Forms.DialogResult]::OK })
    [void]$dg.ShowDialog($form)
    $dg.Dispose()
    return $script:ud.Result
}

# 복사 진행 창 (모달 아님). 반환: @{ Form; Label; Bar; Cancel(스크립트 변수 $script:cpCancel) }
function New-CopyProgress {
    $pf = New-DialogForm '복사 중' 540 170
    $pf.ControlBox = $false
    $script:cpCancel = $false
    $ps = @{ Form = $pf }
    $ps.L1 = New-DlgLabel '준비 중...' $cText; $ps.L1.AutoEllipsis = $true
    [void](Add-DlgControl $pf $ps.L1 16 14 508 24)
    $ps.Bar = New-Object Windows.Forms.ProgressBar; $ps.Bar.Minimum = 0; $ps.Bar.Maximum = 1000
    [void](Add-DlgControl $pf $ps.Bar 16 44 508 20)
    $ps.L2 = New-DlgLabel '' $cSub; $ps.L2.AutoEllipsis = $true; $ps.L2.Font = $fontSmall
    [void](Add-DlgControl $pf $ps.L2 16 72 508 22)
    $bc = New-Object Windows.Forms.Button; $bc.Text = '취소'
    [void](Add-DlgControl $pf $bc 424 108 100 36)
    $bc.Add_Click({ $script:cpCancel = $true; $this.Enabled = $false; $this.Text = '취소 중...' })
    $pf.Show($form)
    [Windows.Forms.Application]::DoEvents()
    return $ps
}

function Remove-TempDir([string]$p) {
    try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop } } catch { Log ('  [정리 실패] 임시 폴더를 직접 삭제해 주세요: ' + $p) }
}

# 링크 해제. $cells = @(@{ Ci; Key })
function Invoke-UnlinkCells($cells, [string]$tag, [string]$title) {
    $acts = @()
    foreach ($c in $cells) {
        $cl = $script:clients[$c.Ci]
        $st = Get-State $cl.Path
        if (-not $st) { continue }
        $it = Get-ItemByKey $c.Key
        $p = Join-Path $st.Game $it.Sub
        if ((Get-LinkInfo $p).Kind -ne 'link') { continue }
        $bk = @(Get-ItemBackups $st.Game $it | Sort-Object LastWriteTime -Descending)
        $bak = $null; if ($bk.Count -gt 0) { $bak = $bk[0].FullName }
        $acts += [pscustomobject]@{ Name = $cl.Name; Game = $st.Game; It = $it; Path = $p; Bak = $bak }
    }
    if ($acts.Count -eq 0) { Show-Warn '해제할 링크가 없습니다.' '알림'; return }
    $run = Get-RunningConflicts @($acts | ForEach-Object { $_.Game } | Select-Object -Unique)
    if ($run.Count -gt 0) { Show-Warn ("관련 프로세스가 실행 중입니다. 모두 종료한 뒤 다시 시도하세요:`r`n" + ($run -join ', ')); return }

    $plan = Get-UnlinkPlan $acts
    $sum = @()
    foreach ($nm in ($acts | ForEach-Object { $_.Name } | Select-Object -Unique)) {
        $ks = @($acts | Where-Object { $_.Name -eq $nm } | ForEach-Object { $_.It.Key })
        $sum += ('{0} · {1}' -f $nm, ($ks -join ', '))
    }
    $summary = ('해제할 링크 {0}칸   ' -f $acts.Count) + ($sum -join '   /   ')
    $mode = Show-UnlinkDialog $plan $title $summary
    if (-not $mode) { return }

    $lines = @()
    foreach ($pa in $plan.Acts) {
        $a = $pa.Act
        $s = ('- [{0}] {1}: ' -f $a.Name, $a.It.Sub)
        switch ($mode) {
            'restore' { $s += ('링크 해제 → 백업 복원 (' + (Split-Path $a.Bak -Leaf) + ')') }
            'copy'    { $s += ('링크 해제 → 원본에서 복사 ({0})' -f (Format-Size $pa.Bytes)) }
            'empty'   { $s += '링크 해제 → 빈 폴더' }
        }
        $lines += $s
    }
    $note = ''
    if ($mode -eq 'copy') { $note = "`r`n`r`n복사는 시간이 걸릴 수 있습니다 (총 {0}). 복사가 끝나고 확인한 뒤에 링크를 바꾸며, 도중에 취소하면 링크는 그대로 유지됩니다." -f (Format-Size $plan.Bytes) }
    if ($mode -eq 'empty') { $note = "`r`n`r`n해당 폴더는 비어 있게 되므로 런처에서 [게임 복구] 등으로 새로 받아야 합니다 (Paks·UHD는 용량이 커서 오래 걸립니다)." }
    $ans = [Windows.Forms.MessageBox]::Show(("다음 항목을 처리합니다.`r`n`r`n" + ($lines -join "`r`n") + $note + "`r`n`r`n계속할까요?"), $title, 'YesNo', 'Warning', 'Button2')
    if ($ans -ne 'Yes') { return }

    Set-Busy $true
    $ps = $null
    try {
        Start-LogFile $tag
        Log ''; Log ('[{0}] 시작 (방법: {1})' -f $title, $mode)
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        if ($mode -eq 'copy') { $ps = New-CopyProgress }
        $idx = 0; $stop = $false
        foreach ($pa in $plan.Acts) {
            if ($stop) { break }
            $a = $pa.Act; $idx++
            try {
                switch ($mode) {
                    'restore' {
                        [IO.Directory]::Delete($a.Path); Log ('  [링크 해제] [{0}] {1}' -f $a.Name, $a.Path)
                        Move-Item -LiteralPath $a.Bak -Destination $a.Path -ErrorAction Stop
                        Log ('  [백업 복원] ' + $a.Path)
                    }
                    'empty' {
                        [IO.Directory]::Delete($a.Path); Log ('  [링크 해제] [{0}] {1}' -f $a.Name, $a.Path)
                        [void][IO.Directory]::CreateDirectory($a.Path)
                        Log ('  [빈 폴더 생성] ' + $a.Path)
                    }
                    'copy' {
                        $tmp = $a.Path + '_copying_' + $stamp
                        $script:cpLabel = ('[{0}/{1}] {2} · {3}' -f $idx, $plan.Acts.Count, $a.Name, $a.It.Sub)
                        $ps.L1.Text = $script:cpLabel
                        Log ('  [복사 시작] {0} → {1}' -f $pa.Src, $tmp)
                        $script:cpPs = $ps
                        $res = Copy-FolderTree $pa.Src $tmp {
                            param($done, $total, $rel)
                            $pct = 0; if ($total -gt 0) { $pct = [int](1000 * $done / $total) }
                            $script:cpPs.Bar.Value = [Math]::Min(1000, [Math]::Max(0, $pct))
                            $script:cpPs.L2.Text = ('{0} / {1}   {2}' -f (Format-Size $done), (Format-Size $total), $rel)
                            [Windows.Forms.Application]::DoEvents()
                        } { [Windows.Forms.Application]::DoEvents(); $script:cpCancel }
                        if ($res.Cancelled) { Remove-TempDir $tmp; Log '  [취소] 복사를 취소했습니다. 링크는 그대로 유지됩니다.'; $stop = $true }
                        elseif (-not $res.Ok) { Remove-TempDir $tmp; Log ('  [실패] 복사 오류: ' + $res.Err + ' (링크는 그대로 유지됨)'); $stop = $true }
                        else {
                            Log ('  [복사 완료] 파일 {0}개 · {1}' -f $res.Files, (Format-Size $res.Bytes))
                            [IO.Directory]::Delete($a.Path); Log ('  [링크 해제] [{0}] {1}' -f $a.Name, $a.Path)
                            try { [IO.Directory]::Move($tmp, $a.Path); Log ('  [적용] ' + $a.Path) }
                            catch { Log ('  [실패] 이름 변경 오류: ' + $_.Exception.Message + ' / 복사본은 ' + $tmp + ' 에 남아 있습니다. 직접 이름을 바꿔 주세요.'); $stop = $true }
                        }
                    }
                }
            } catch { Log ('  [실패] {0}: {1}' -f $a.It.Sub, $_.Exception.Message); $stop = $true }
        }
        Log ('[{0}] 끝' -f $title)
    } catch { Log ('오류: ' + $_.Exception.Message) }
    finally {
        if ($ps) { try { $ps.Form.Close(); $ps.Form.Dispose() } catch { } }
        $script:sel = @{}; Set-Busy $false; Refresh-Manage $true
    }
}

function Invoke-ManageClean {
    $cands = @(); $skipped = @()
    foreach ($cl in $script:clients) {
        $st = Get-State $cl.Path
        if (-not $st) { continue }
        foreach ($it in $Items) {
            $li = Get-LinkInfo (Join-Path $st.Game $it.Sub)
            foreach ($b in (Get-ItemBackups $st.Game $it)) {
                if ($li.Kind -eq 'link') {
                    $sz = 0; try { $sz = (Get-DirStat $b.FullName).Bytes } catch { }
                    $cands += [pscustomobject]@{ Path = $b.FullName; Game = $st.Game; Name = $cl.Name; Bytes = $sz; Orig = (Join-Path $st.Game $it.Sub) }
                } else { $skipped += $b.FullName }
            }
        }
    }
    if ($cands.Count -eq 0) {
        $m = '삭제할 수 있는 백업이 없습니다.'
        if ($skipped.Count -gt 0) { $m += "`r`n(원래 폴더가 링크 상태가 아닌 백업은 보호를 위해 제외됨)" }
        Show-Warn $m '알림'; return
    }
    $txt = ($cands | ForEach-Object { '- [{0}] {1}  ({2})' -f $_.Name, $_.Path, (Format-Size $_.Bytes) }) -join "`r`n"
    $msg = "다음 백업 폴더를 영구 삭제합니다 (휴지통으로 가지 않음).`r`n런처 실행과 [게임 복구]를 확인한 뒤에만 진행하세요.`r`n`r`n$txt"
    if ($skipped.Count -gt 0) { $msg += "`r`n`r`n제외(원래 폴더가 링크 상태가 아님):`r`n" + ($skipped -join "`r`n") }
    $ans = [Windows.Forms.MessageBox]::Show(($msg + "`r`n`r`n계속할까요?"), '백업 삭제 확인', 'YesNo', 'Warning', 'Button2')
    if ($ans -ne 'Yes') { return }
    Set-Busy $true
    try {
        Start-LogFile 'clean'
        Log ''; Log '[백업 삭제] 시작'
        foreach ($c in $cands) {
            if (-not $c.Path.StartsWith($c.Game + '\', [StringComparison]::OrdinalIgnoreCase)) { Log ('  [건너뜀] 클라이언트 폴더 밖: ' + $c.Path); continue }
            if ((Get-LinkInfo $c.Orig).Kind -ne 'link') { Log ('  [건너뜀] 원래 폴더가 더 이상 링크 상태가 아님: ' + $c.Path); continue }
            $lblSum.Text = '삭제 중: ' + (Split-Path $c.Path -Leaf)
            if (Remove-DirAsync $c.Path) { Log ('  [삭제] ' + $c.Path) } else { Log ('  [실패] ' + $c.Path) }
        }
        Log '[백업 삭제] 끝'
    } catch { Log ('오류: ' + $_.Exception.Message) }
    finally { Set-Busy $false; Refresh-Manage $true }
}

# ---------------------------------------------------------------- 업데이트 후 동기화 (화면)

$SyncMsgRunning = '실행 중인 런처/클라이언트를 모두 종료 후 진행해주세요.'

# 사전 다운로드 백업 정보: <Game>\backup_sync_*\predownload 폴더들
function Get-HoldInfo([string]$game) {
    $r = @{ Exists = $false; Bytes = [long]0; Paths = @(); Dirs = @() }
    if (-not (Test-Path -LiteralPath $game -PathType Container)) { return $r }
    foreach ($d in @(Get-ChildItem -LiteralPath $game -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'backup_sync_*' })) {
        if ((Get-LinkInfo $d.FullName).Kind -eq 'dir') { $r.Dirs += $d.FullName }
        $pd = Join-Path $d.FullName 'predownload'
        if ((Test-Path -LiteralPath $pd -PathType Container) -and ((Get-LinkInfo $pd).Kind -eq 'dir')) {
            $r.Paths += $pd
            $r.Bytes += (Get-FreshBytes $pd)
        }
    }
    $r.Exists = ($r.Paths.Count -gt 0)
    return $r
}

# 동기화 대상 수집. 반환: @{ Ok; Msg; Ss; Sv; SrcVer; Work; Notes; Dirs }
function Get-SyncWork($srcCl) {
    $o = @{ Ok = $false; Msg = ''; Ss = $null; Sv = $null; SrcVer = $null; Work = @(); Notes = @(); Dirs = @() }
    if (-not $srcCl) { $o.Msg = '원본 클라이언트가 지정되어 있지 않습니다.'; return $o }
    $ss = Get-State $srcCl.Path
    if (-not $ss -or -not $ss.Exe) { $o.Msg = ("원본에 구성 파일이 없습니다:`r`n" + $srcCl.Path); return $o }
    $sv = Get-SyncSource $ss.Game
    $srcVer = Get-ClientVersion $ss.Game
    if ($sv.Bundles.Count -eq 0 -or -not $srcVer) { $o.Msg = '원본의 버전을 읽을 수 없습니다 (Wuthering Waves Game\launcherDownloadConfig.json).'; return $o }
    $o.Ss = $ss; $o.Sv = $sv; $o.SrcVer = $srcVer; $o.Dirs = @($ss.Game)
    foreach ($cl in $script:clients) {
        if ($cl.Role -eq 'src') { continue }
        $ds = Get-State $cl.Path
        if (-not $ds -or -not $ds.Exe) { $o.Notes += ('[{0}] 구성 파일이 없어 건너뜀' -f $cl.Name); continue }
        if (-not (Test-LinkedToSource $ss.Game $ds.Game)) {
            $o.Notes += ('[{0}] Paks / Resources가 원본에 링크되어 있지 않아 건너뜀 (링크가 아니면 런처에서 직접 업데이트)' -f $cl.Name)
            continue
        }
        $dv = Get-ClientVersion $ds.Game
        if ($dv -and ([version]$dv.Content) -gt ([version]$srcVer.Content)) {
            $o.Notes += ('[{0}] 대상 버전({1})이 원본({2})보다 높아 건너뜀. 원본을 먼저 업데이트하세요.' -f $cl.Name, $dv.Content, $srcVer.Content)
            continue
        }
        $o.Dirs += $ds.Game
        $ed = @(Get-SyncEdits $ds.Game $sv)
        $pb = @(Test-SyncEdits $ds.Game $sv $ed)
        if (-not $dv) { $pb += 'launcherDownloadConfig.json 에서 버전을 읽을 수 없습니다.' }
        elseif ($ed.Count -eq 0 -and (Get-SyncState $srcVer $dv) -eq 'need') { $pb += ('버전({0})이 원본({1})과 다른데 수정할 항목을 찾지 못했습니다. JSON 구조가 달라졌을 수 있습니다.' -f $dv.Content, $srcVer.Content) }
        $o.Work += @{ Cl = $cl; Ds = $ds; Dv = $dv; Edits = $ed; Problems = $pb; Pre = (Get-PreDownloadInfo $ds.Game); Hold = (Get-HoldInfo $ds.Game) }
    }
    $o.Ok = $true
    return $o
}

function Draw-Chip($g, [int]$x, [int]$y, [string]$text, [string]$kind) {
    $fill = RGB 250 250 250; $line = RGB 220 220 220; $fore = $cSub
    if ($kind -eq 'r') { $fill = RGB 253 241 240; $line = RGB 239 194 189; $fore = $cDanger }
    elseif ($kind -eq 'g') { $fill = RGB 238 248 238; $line = RGB 185 224 185; $fore = $cOk }
    elseif ($kind -eq 'y') { $fill = RGB 255 247 230; $line = RGB 240 214 160; $fore = (RGB 150 100 0) }
    $w = [Windows.Forms.TextRenderer]::MeasureText($text, $fontSmall).Width + (S 18)
    $r = Rc $x $y $w (S 24)
    Draw-Round $g $r $fill $line 1 $false (S 6)
    Draw-Txt $g $text $fontSmall $r $fore 'HorizontalCenter,VerticalCenter,SingleLine,NoPadding'
    return $w
}

# 동기화 창 안의 상태 갱신 (대상 다시 읽기, 버튼 활성 조건)
function Update-SyncDialog {
    $sd = $script:sd
    $sd.Data = Get-SyncWork $sd.Src
    $todo = 0; $holds = 0; $probs = 0
    foreach ($w in $sd.Data.Work) {
        if ($w.Problems.Count -gt 0 -or $w.Pre.Unresolved) { $probs++ }
        elseif ($w.Edits.Count -gt 0 -or $w.Pre.Dirs.Count -gt 0) { $todo++ }
        if ($w.Hold.Dirs.Count -gt 0) { $holds++ }
    }
    if ($holds -eq 0 -or $todo -gt 0 -or $probs -gt 0) { $sd.Ok2 = $false }
    $sd.B1.Enabled = ($todo -gt 0)
    $sd.B2.Enabled = ($holds -gt 0 -and $todo -eq 0 -and $probs -eq 0 -and -not $sd.Ok2)
    $sd.B3.Enabled = ($holds -gt 0 -and $sd.Ok2)
    if ($sd.Ok2) { $sd.B2.Text = '확인 완료' } else { $sd.B2.Text = '런처 실행 › 게임 복구 › 게임 실행' }
    $sd.B2.Invalidate()
    if ($sd.Cap) { $sd.Cap.Visible = $sd.B2.Enabled }
    # '다음 할 일' 안내 줄
    $names = @(); $unres = @(); $firstProb = ''
    foreach ($w in $sd.Data.Work) {
        if ($w.Problems.Count -gt 0) { $names += $w.Cl.Name; if (-not $firstProb) { $firstProb = $w.Problems[0] } }
        if ($w.Pre.Unresolved) { $unres += $w.Cl.Name }
    }
    $gd = @{ Kind = 'b'; Lines = @() }
    if ($names.Count -gt 0) {
        $gd.Kind = 'r'; $gd.Lines = @(('{0}: 자동으로 동기화할 수 없습니다. 아무것도 바꾸지 않았습니다.' -f ($names -join ', ')), $firstProb)
    } elseif ($unres.Count -gt 0) {
        $gd.Kind = 'r'; $gd.Lines = @(('{0}의 사전 다운로드로 보이는 데이터를 옮길 폴더를 찾지 못했습니다.' -f ($unres -join ', ')), '게임 폴더의 launcherDownload 폴더를 직접 확인하세요.')
    } elseif ($todo -gt 0) {
        $gd.Lines = @('다음 할 일  ·  모든 런처/게임을 종료한 뒤 ① 동기화 진행을 누르세요.')
    } elseif ($holds -gt 0 -and -not $sd.Ok2) {
        $gd.Lines = @('다음 할 일  ·  링크 런처에서 [게임 복구]를 실행하고 게임 실행을 확인하세요 (클라이언트별로 하나씩).', '모두 정상이면 ② 를 누르세요.')
    } elseif ($holds -gt 0) {
        $gd.Lines = @('다음 할 일  ·  확인이 끝났습니다. ③ 삭제로 백업을 지우면 마무리됩니다.')
    } elseif ($sd.Data.Work.Count -eq 0) {
        $gd.Lines = @('동기화할 링크 클라이언트가 없습니다. 링크를 연결한 뒤 사용하세요.')
    } else {
        $gd.Kind = 'g'; $gd.Lines = @('모든 클라이언트가 동기화되어 있습니다.', '마이너 업데이트로 인한 버전 차이는 게임 실행 시 자동 업데이트로 해결됩니다.')
    }
    $sd.Guide = $gd
    if ($sd.Bar) { $sd.Bar.Invalidate() }
    $sd.Panel.Invalidate()
}

# ① 동기화 진행: JSON 버전 값 수정 + 사전 다운로드 비활성화(보관 폴더로 이동)
function Invoke-SyncStep1 {
    $sd = $script:sd; $d = $sd.Data
    $run = Get-RunningConflicts $d.Dirs
    if ($run.Count -gt 0) { Show-Warn ($SyncMsgRunning + "`r`n`r`n" + ($run -join ', ')); return }
    $msg = "링크 클라이언트의 설정을 수정하여 강제 업데이트를 막습니다.`r`n사전 다운로드가 있을 경우 임시 폴더로 옮겨 비활성화합니다.`r`n수정 전의 설정값 파일과 사전 다운로드 파일은 각 게임 폴더의 \backup_sync_* 에 백업합니다.`r`n`r`n계속할까요?"
    $ans = [Windows.Forms.MessageBox]::Show($msg, '동기화 진행', 'YesNo', 'Warning', 'Button2')
    if ($ans -ne 'Yes') { return }
    $form.UseWaitCursor = $true
    try {
        Start-LogFile 'sync'
        Log ''; Log ('[업데이트 후 동기화] 시작 (원본 버전 {0})' -f $d.SrcVer.Content)
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $okAll = $true
        foreach ($w in $d.Work) {
            Log ('[{0}]' -f $w.Cl.Name)
            if ($w.Problems.Count -gt 0) {
                $okAll = $false
                Log '  [건너뜀] 자동으로 수정할 수 없는 상태입니다. 아무것도 바꾸지 않았습니다.'
                foreach ($pm in $w.Problems) { Log ('      ' + $pm) }
                continue
            }
            $bkRoot = Join-Path $w.Ds.Game ('backup_sync_' + $stamp)
            try {
                foreach ($e in $w.Edits) {
                    $f = Join-Path $w.Ds.Game $e.Rel
                    $bk = Join-Path (Join-Path $bkRoot 'settings') $e.Rel
                    New-Item -ItemType Directory -Force -Path (Split-Path $bk -Parent) | Out-Null
                    Copy-Item -LiteralPath $f -Destination $bk -Force
                    Write-JsonText $f $e.NewText $e.Bom
                    Log ('  [수정] {0}' -f $e.Rel)
                    foreach ($c in $e.Changes) { Log ('      ' + $c) }
                }
                if ($w.Pre.Dirs.Count -gt 0) {
                    foreach ($m in @(Move-PreDownload $bkRoot $w.Pre.Dirs)) { Log ('  [백업] 사전 다운로드 패치 → ' + $m) }
                }
                if ($w.Pre.Unresolved) {
                    Log '  [참고] 사전 다운로드로 보이는 데이터가 있으나 옮길 폴더를 찾지 못했습니다. launcherDownload 폴더를 직접 확인하세요.'
                }
                $chk = @(Test-SyncEdits $w.Ds.Game $d.Sv)
                if ($chk.Count -gt 0) { $okAll = $false; foreach ($pm in $chk) { Log ('  [검증 실패] ' + $pm) } }
            } catch { $okAll = $false; Log ('  [오류] ' + $_.Exception.Message) }
        }
        Log ('백업 위치: 각 게임 폴더의 backup_sync_{0}  (settings = 수정 전 설정값, predownload = 사전 다운로드)' -f $stamp)
        Log '[업데이트 후 동기화] 끝'
        if ($okAll) { Log '다음: 각 링크 런처에서 [게임 복구] → 게임 실행을 한 클라이언트씩 확인한 뒤, 동기화 창의 [사전 다운로드 삭제]를 누르세요.' }
        else { Show-Warn '일부 항목은 처리하지 못했습니다. 로그를 확인하세요. (수정한 파일의 원본은 각 게임 폴더의 backup_sync_* 에 있습니다)' '알림' }
    } catch { Log ('오류: ' + $_.Exception.Message) }
    finally { $form.UseWaitCursor = $false; Update-SyncDialog }
}

# ② 직접 진행 확인 (더미): 런처 게임 복구 + 게임 실행이 정상임을 사용자가 확인했다는 표시. ③을 연다.
function Invoke-SyncStep2 {
    $msg = "각 링크 런처에서 [게임 복구]를 마치고`r`n게임 실행이 정상인 것을 확인하셨나요?`r`n`r`n확인하면 [사전 다운로드 삭제]가 활성화됩니다."
    $ans = [Windows.Forms.MessageBox]::Show($msg, '직접 진행 확인', 'YesNo', 'Question', 'Button2')
    if ($ans -ne 'Yes') { return }
    $script:sd.Ok2 = $true
    Update-SyncDialog
}

# ③ 사전 다운로드 삭제: 보관해 둔 폴더를 영구 삭제
function Invoke-SyncStep3 {
    $sd = $script:sd; $d = $sd.Data
    $run = Get-RunningConflicts $d.Dirs
    if ($run.Count -gt 0) { Show-Warn ($SyncMsgRunning + "`r`n`r`n" + ($run -join ', ')); return }
    $cands = @()
    foreach ($w in $d.Work) {
        foreach ($hp in $w.Hold.Dirs) {
            if ($hp.StartsWith($w.Ds.Game + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $cands += [pscustomobject]@{ Name = $w.Cl.Name; Path = $hp; Bytes = (Get-FreshBytes $hp) }
            }
        }
    }
    if ($cands.Count -eq 0) { Show-Warn '삭제할 백업이 없습니다.' '알림'; return }
    $txt = ($cands | ForEach-Object { '{0}  ({1})' -f $_.Path, (Format-Size $_.Bytes) }) -join "`r`n"
    $msg = "동기화 진행 처음 단계에서 백업한 설정값과 사전 다운로드 파일을 영구 삭제합니다.`r`n모든 링크 클라이언트에서 [게임 복구]를 마쳤고 게임 실행이 정상적으로 되는 것을 확인 후 진행하세요.`r`n`r`n$txt"
    $ans = [Windows.Forms.MessageBox]::Show($msg, '사전 다운로드 삭제', 'YesNo', 'Warning', 'Button2')
    if ($ans -ne 'Yes') { return }
    $form.UseWaitCursor = $true
    try {
        Start-LogFile 'syncdel'
        Log ''; Log '[사전 다운로드 삭제] 시작'
        foreach ($c in $cands) {
            if (Remove-DirAsync $c.Path) { Log ('  [삭제] ' + $c.Path) } else { Log ('  [실패] ' + $c.Path) }
        }
        Log '[사전 다운로드 삭제] 끝'
        Log $SyncGuide
    } catch { Log ('오류: ' + $_.Exception.Message) }
    finally { $form.UseWaitCursor = $false; Update-SyncDialog }
    [void][Windows.Forms.MessageBox]::Show(("정리를 마쳤습니다.`r`n`r`n" + $SyncGuide), '업데이트 후 동기화', 'OK', 'Information')
}

function Show-SyncDialog($srcCl) {
    $data = Get-SyncWork $srcCl
    if (-not $data.Ok) { Show-Warn $data.Msg; return }
    $rows = $data.Work.Count + $data.Notes.Count
    $dw = 900
    $cardH = 46 + 46 * [Math]::Max(1, $rows) + 8
    $y0 = 14; $nbH = 68
    $yCard = $y0 + 2 * ($nbH + 10)
    $yBar = $yCard + $cardH + 12; $barH = 60
    $yStep = $yBar + $barH + 12
    $dh = $yStep + 52 + 32
    $dg = New-DialogForm '업데이트 후 동기화' $dw $dh
    $script:sd = @{ Form = $dg; Src = $srcCl; Data = $data; Ok2 = $false }
    $sd = $script:sd

    $n1 = New-NoteBox $dg @('원본 런처/클라이언트 업데이트가 모두 완료된 후 사용하세요.', '올바른 작동을 위해 사전 업데이트는 원본 런처에서만 해주세요.') 'ⓘ' $cAccent (New-Object Drawing.Color) $null
    $n1.SetBounds((S 16), (S $y0), (S ($dw - 32)), (S $nbH))
    $n2 = New-NoteBox $dg @('링크 런처/클라이언트를 먼저 업데이트 시 원본이 손상될 수 있습니다.', '올바른 작동을 위해 링크의 사전 다운로드는 우선 비활성화 후 게임 실행 확인 후 삭제합니다.') '⚠' $cDanger (New-Object Drawing.Color) $null
    $n2.SetBounds((S 16), (S ($y0 + $nbH + 10)), (S ($dw - 32)), (S $nbH))

    $pn = New-Object Windows.Forms.Panel
    $pn.BackColor = $cBg; Set-DoubleBuffered $pn
    $pn.SetBounds((S 16), (S $yCard), (S ($dw - 32)), (S $cardH))
    $dg.Controls.Add($pn)
    $sd.Panel = $pn
    $pn.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $g.Clear($cBg)
        $d = $script:sd.Data
        Draw-Round $g (Rc 0 0 ($s.Width - 1) ($s.Height - 1)) $cCard $cBorder 1 $false (S 8)
        Draw-Txt $g '동기화 대상' $fontBold (Rc (S 16) (S 8) (S 110) (S 30)) $cText
        Draw-Txt $g ('원본 버전 {0}' -f $d.SrcVer.Content) $fontSmall (Rc (S 126) (S 8) (S 300) (S 30)) $cSub
        $y = S 46
        foreach ($w in $d.Work) {
            $g.DrawLine((New-Object Drawing.Pen((RGB 238 238 238), 1)), (S 16), $y, ($s.Width - (S 16)), $y)
            $cy = $y + (S 11)
            [void](Draw-Badge $g (S 16) ($cy + (S 2)) '링크' $cOk (S 46))
            Draw-Txt $g $w.Cl.Name $fontBold (Rc (S 74) $y (S 120) (S 46)) $cText
            $vt = '버전 확인 불가'; if ($w.Dv) { $vt = $w.Dv.Content }
            $need = ($w.Edits.Count -gt 0)
            if ($need) { $vt = $vt + '  →  ' + $d.SrcVer.Content }
            Draw-Txt $g $vt $fontBold (Rc (S 196) $y (S 170) (S 46)) $cText
            $x = S 372
            if ($w.Problems.Count -gt 0) { $cw = Draw-Chip $g $x $cy '확인 필요' 'r' }
            elseif ($need) { $cw = Draw-Chip $g $x $cy '동기화 필요' 'r' } else { $cw = Draw-Chip $g $x $cy '동기화 완료' 'g' }
            $x += $cw + (S 8)
            if ($w.Pre.Dirs.Count -gt 0) { [void](Draw-Chip $g $x $cy ('사전 다운로드 ' + (Format-Size $w.Pre.Bytes)) 'r') }
            elseif ($w.Pre.Unresolved) { [void](Draw-Chip $g $x $cy ('사전 다운로드 ' + (Format-Size $w.Pre.Bytes) + ' · 직접 확인') 'r') }
            elseif ($w.Hold.Exists) { [void](Draw-Chip $g $x $cy ('사전 다운로드 백업 중 ' + (Format-Size $w.Hold.Bytes)) 'y') }
            else { [void](Draw-Chip $g $x $cy '사전 다운로드 없음' 'g') }
            $y += S 46
        }
        foreach ($t in $d.Notes) {
            $g.DrawLine((New-Object Drawing.Pen((RGB 238 238 238), 1)), (S 16), $y, ($s.Width - (S 16)), $y)
            Draw-Txt $g $t $fontSmall (Rc (S 16) $y ($s.Width - (S 32)) (S 46)) $cSub 'Left,VerticalCenter,SingleLine,EndEllipsis'
            $y += S 46
        }
        if ($d.Work.Count -eq 0 -and $d.Notes.Count -eq 0) {
            Draw-Txt $g '동기화할 링크 클라이언트가 없습니다.' $fontBase (Rc (S 16) $y ($s.Width - (S 32)) (S 46)) $cSub
        }
    })

    # 단계 버튼 줄: ① 동기화 진행 > ② 런처 실행 > 게임 복구 > 게임 실행 (직접) > ③ 사전 다운로드 삭제        [닫기]
    $bar = New-Object Windows.Forms.Panel
    $bar.BackColor = $cBg; Set-DoubleBuffered $bar
    $bar.SetBounds((S 16), (S $yBar), (S ($dw - 32)), (S $barH))
    $dg.Controls.Add($bar)
    $sd.Bar = $bar
    $bar.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $g.Clear($cBg)
        $gd = $script:sd.Guide
        if (-not $gd) { return }
        $fill = RGB 234 243 253; $line = RGB 185 214 245; $fore = (RGB 11 74 148); $mark = '▶'
        if ($gd.Kind -eq 'g') { $fill = RGB 238 248 238; $line = RGB 185 224 185; $fore = $cOk; $mark = '✓' }
        elseif ($gd.Kind -eq 'r') { $fill = RGB 253 241 240; $line = RGB 239 194 189; $fore = $cDanger; $mark = '⚠' }
        Draw-Round $g (Rc 0 0 ($s.Width - 1) ($s.Height - 1)) $fill $line 1 $false (S 8)
        Draw-Txt $g $mark $fontBase (Rc (S 14) 0 (S 24) $s.Height) $fore 'HorizontalCenter,VerticalCenter,SingleLine'
        Draw-Txt $g ($gd.Lines -join "`n") $fontBase (Rc (S 48) 0 ($s.Width - (S 62)) $s.Height) $fore 'Left,VerticalCenter,WordBreak'
    })

    $sd.B1 = New-Button '동기화 진행' $false $dg
    $sd.B1.Tag.Num = '1'; $sd.B1.Tag.Style = 'soft'
    $sd.B1.SetBounds((S 16), (S $yStep), (S 170), (S 52))
    $a1 = New-FlowArrow $dg; $a1.SetBounds((S 186), (S $yStep), (S 36), (S 52))
    $sd.B2 = New-Button '런처 실행 › 게임 복구 › 게임 실행' $false $dg
    $sd.B2.Tag.Num = '2'; $sd.B2.Tag.Style = 'mid'
    $sd.B2.SetBounds((S 222), (S $yStep), (S 310), (S 36))
    $cap = New-Object Windows.Forms.Label
    $cap.Text = '( 직접 진행 후 정상이면 눌러주세요 )'; $cap.Font = $fontSmall; $cap.ForeColor = $cSub; $cap.BackColor = $cBg
    $cap.TextAlign = 'MiddleCenter'
    $cap.SetBounds((S 222), (S ($yStep + 38)), (S 310), (S 22))
    $dg.Controls.Add($cap)
    $sd.Cap = $cap
    $a2 = New-FlowArrow $dg; $a2.SetBounds((S 532), (S $yStep), (S 36), (S 52))
    $sd.B3 = New-Button '사전 다운로드 삭제' $false $dg
    $sd.B3.Tag.Num = '3'; $sd.B3.Tag.Style = 'deep'
    $sd.B3.SetBounds((S 568), (S $yStep), (S 190), (S 52))
    $sdClose = New-Button '닫기' $false $dg
    $sdClose.SetBounds((S ($dw - 16 - 110)), (S $yStep), (S 110), (S 52))
    $dg.CancelButton = $sdClose
    $sd.B1.Add_Click({ Invoke-SyncStep1 })
    $sd.B2.Add_Click({ Invoke-SyncStep2 })
    $sd.B3.Add_Click({ Invoke-SyncStep3 })
    $sdClose.Add_Click({ $script:sd.Form.DialogResult = [Windows.Forms.DialogResult]::Cancel })

    Update-SyncDialog
    [void]$dg.ShowDialog($form)
    $dg.Dispose()
}

function Invoke-ManageSync {
    $srcCl = $null
    foreach ($c in $script:clients) { if ($c.Role -eq 'src') { $srcCl = $c } }
    if (-not $srcCl) { Show-Warn '원본 클라이언트가 지정되어 있지 않습니다.'; return }
    Show-SyncDialog $srcCl
    Refresh-Manage $true
}

$mBtnConn.Add_Click({ Invoke-ManageConnect })
$mBtnDisc.Add_Click({ Invoke-UnlinkCells @(Get-SelCells) 'disconnect' '링크 해제' })
$mBtnRef.Add_Click({ $script:sel = @{}; Refresh-Manage $true; Log '[새로 고침] 링크 현황을 다시 확인했습니다.' })
$mBtnBroken.Add_Click({
    $cells = @()
    for ($ci = 0; $ci -lt $script:grid.Cols.Count; $ci++) {
        foreach ($it in $Items) {
            $cell = $script:grid.Cols[$ci].Cells[$it.Key]
            if ($cell.Kind -eq 'broken') { $cells += [pscustomobject]@{ Ci = $ci; Key = $it.Key } }
        }
    }
    if ($cells.Count -eq 0) { Show-Warn '깨진 링크가 없습니다.' '알림'; return }
    Invoke-UnlinkCells $cells 'broken' '깨진 링크 정리'
})
$mBtnClean.Add_Click({ Invoke-ManageClean })
$mBtnSync.Add_Click({ Invoke-ManageSync })


# ---------------------------------------------------------------- 동기화 순서 안내 (닫지 않아도 되는 별도 창)
#  동기화가 필요한 클라이언트가 있으면 링크 관리 탭을 열 때 한 번 자동으로 뜹니다. 닫으면 [동기화 순서 안내] 버튼으로 다시 엽니다.

$script:gw = $null
$script:gwSeen = $false

# 한 줄 그리기: 글자 / 굵은 글자 / 배지를 이어 붙임. 조각 = @{T; F(굵게); K(배지 색 'r'|'g')}
function Draw-Segs($g, $segs, [int]$x, [int]$y, $color) {
    $cx = $x
    foreach ($sg in $segs) {
        if ($sg.A) { $cx -= (S 4) }
        if ($sg.K -eq 'btn') {
            # 실제 [업데이트 후 동기화] 버튼과 같은 모양(빨간 버튼, 흰 글자)
            $tw = [Windows.Forms.TextRenderer]::MeasureText($g, $sg.T, $fontBase, (New-Object Drawing.Size(2000, 100)), [Windows.Forms.TextFormatFlags]'NoPadding,SingleLine').Width
            $bw = $tw + (S 24)
            $br = Rc $cx $y $bw (S 24)
            $bfill = [Drawing.Color]::FromArgb(198, 40, 40); if ($sg.C) { $bfill = $sg.C }
            Draw-Round $g $br $bfill $null 1 $false (S 8)
            Draw-Txt $g $sg.T $fontBase (Rc $cx ($y + (S 1)) $bw (S 24)) ([Drawing.Color]::White) 'HorizontalCenter,VerticalCenter,SingleLine,NoPadding'
            $cx += $bw + (S 5)
        } elseif ($sg.K) {
            $bc = $cOk; if ($sg.K -eq 'r') { $bc = $cDanger }
            $bw = Draw-Badge $g $cx ($y + (S 1)) $sg.T $bc
            $cx += $bw + (S 5)
        } else {
            $f = $fontBase; if ($sg.F) { $f = $fontBold }
            $sz = [Windows.Forms.TextRenderer]::MeasureText($g, $sg.T, $f, (New-Object Drawing.Size(2000, 100)), [Windows.Forms.TextFormatFlags]'NoPadding,SingleLine')
            Draw-Txt $g $sg.T $f (Rc $cx $y ($sz.Width + (S 2)) (S 24)) $color 'Left,VerticalCenter,SingleLine,NoPadding'
            $cx += $sz.Width + (S 5)
        }
    }
}

function Show-GuideWindow([bool]$auto = $false) {
    if ($script:gw -and -not $script:gw.IsDisposed) { $script:gw.Activate(); return }
    $gw = New-Object Windows.Forms.Form
    $gw.Text = '업데이트 후 동기화 순서 안내'; $gw.Font = $fontBase; $gw.BackColor = $cBg; $gw.AutoScaleMode = 'None'
    $gw.FormBorderStyle = 'FixedSingle'; $gw.MaximizeBox = $false; $gw.MinimizeBox = $false
    $gw.ShowInTaskbar = $false; $gw.StartPosition = 'Manual'
    $cardY = 70; $cardH = 340
    $gw.ClientSize = New-Object Drawing.Size((S 620), (S ($cardY + $cardH + 12 + 40 + 16)))

    $nb = New-NoteBox $gw @('모든 업데이트는 원본을 우선 진행, 완료합니다.') '⚠' $cDanger (New-Object Drawing.Color) $null
    $nb.SetBounds((S 16), (S 14), (S 588), (S 44))

    $pn = New-Object Windows.Forms.Panel
    $pn.BackColor = $cBg; Set-DoubleBuffered $pn
    $pn.SetBounds((S 16), (S $cardY), (S 588), (S $cardH))
    $gw.Controls.Add($pn)
    $pn.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $g.Clear($cBg)
        Draw-Round $g (Rc 0 0 ($s.Width - 1) ($s.Height - 1)) $cCard $cBorder 1 $false (S 8)
        $line = New-Object Drawing.Pen((RGB 238 238 238), 1)
        $rowH = S 46
        $y = S 6
        $steps = @(
            @(@{ T = '원본의 사전 다운로드, 클라이언트 업데이트를 완료합니다.' }),
            @(@{ T = '동기화 필요'; K = 'r' }, @{ T = '가 떠 있는 경우 동기화가 필요합니다.'; A = $true }),
            @(@{ T = '모든 런처와 게임을 종료합니다.' }),
            @(@{ T = '업데이트 후 동기화'; K = 'btn' }, @{ T = '를 열고 안내에 따라 진행합니다.'; A = $true }),
            @(@{ T = '동기화 필요'; K = 'r' }, @{ T = '가 모두'; A = $true }, @{ T = '동기화'; K = 'g' }, @{ T = '가 된 것을 확인합니다.'; A = $true })
        )
        $subs = @(
            @(@{ T = '각 링크(서브) 런처에서는 일반 업데이트가 아닌' }, @{ T = '[게임 복구]'; F = $true }, @{ T = '를 진행합니다.' }),
            @(@{ T = '[게임 복구]'; F = $true }, @{ T = '후 클라이언트를 실행하여 잔여 파일을 자동 업데이트합니다.' }),
            @(@{ T = '게임 실행이 모두 확인된 후 기존의 설정 및 백업 데이터를 정리합니다.' })
        )
        for ($i = 0; $i -lt 5; $i++) {
            $h = $rowH
            if ($i -eq 3) { $h = S 40 }
            if ($i -gt 0 -and $i -ne 4) { $g.DrawLine($line, (S 16), $y, ($s.Width - (S 16)), $y) }
            if ($i -eq 4) { $g.DrawLine($line, (S 16), $y, ($s.Width - (S 16)), $y) }
            Draw-Round $g (Rc (S 16) ($y + (S 10)) (S 26) (S 26)) $cAccent $null 1 $false (S 13)
            Draw-Txt $g ([string]($i + 1)) $fontSmall (Rc (S 16) ($y + (S 10)) (S 26) (S 26)) ([Drawing.Color]::White) 'HorizontalCenter,VerticalCenter,SingleLine'
            Draw-Segs $g $steps[$i] (S 54) ($y + (S 11)) $cText
            $y += $h
            if ($i -eq 3) {
                $bh = S 94
                Draw-Round $g (Rc (S 16) ($y + (S 2)) ($s.Width - (S 32)) $bh) (RGB 246 248 251) (RGB 227 233 241) 1 $false (S 8)
                for ($k = 0; $k -lt 3; $k++) {
                    $by = $y + (S 2) + (S 9) + $k * (S 26)
                    Draw-Txt $g '•' $fontBase (Rc (S 30) $by (S 14) (S 24)) $cAccent 'Left,VerticalCenter,SingleLine,NoPadding'
                    Draw-Segs $g $subs[$k] (S 46) $by $cText
                }
                $y += (S 2) + $bh + (S 8)
            }
        }
        $line.Dispose()
    })

    $bc = New-Button '닫기' $false $gw
    $bc.SetBounds((S (620 - 16 - 110)), (S ($cardY + $cardH + 12)), (S 110), (S 40))
    $bc.Add_Click({ $script:gw.Close() })
    $gw.CancelButton = $bc

    # 메인 창 왼쪽에 붙이고, 자리가 없으면 오른쪽에 붙임
    $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    $gap = S 8
    $x = $form.Left - $gw.Width - $gap
    if ($x -lt $wa.Left) { $x = $form.Right + $gap }
    if (($x + $gw.Width) -gt $wa.Right) { $x = [Math]::Max($wa.Left, $wa.Right - $gw.Width) }
    $y = [Math]::Max($wa.Top, [Math]::Min($form.Top, $wa.Bottom - $gw.Height))
    $gw.Location = New-Object Drawing.Point($x, $y)

    $gw.Add_FormClosed({ $script:gw = $null })
    $script:gw = $gw
    $gw.Show($form)
}

# 링크 관리 탭을 열 때(또는 새로 고칠 때) 동기화가 필요한 클라이언트가 있으면 안내 창을 한 번 띄움. 닫은 뒤에는 필요 항목이 사라졌다가 다시 생길 때까지 자동으로 띄우지 않음.
function Update-GuideAuto {
    if (Test-SyncNeeded) {
        if (-not $script:gwSeen) { $script:gwSeen = $true; Show-GuideWindow $true }
    } else { $script:gwSeen = $false }
}

# ---------------------------------------------------------------- 시작

$script:settings = Read-Settings
$script:clients = @(Sort-Clients $script:settings.Clients)

$form.Add_HandleCreated({ param($s, $e) [WWCLNative]::AllowDropMessages($s.Handle) })
$form.Add_SizeChanged({
    if ($script:shownDone -and -not $script:fitting -and ($form.WindowState -ne 'Normal' -or $form.ClientSize.Height -ne $script:autoH)) { $script:autoSize = $false }
    Do-Layout
})
$form.Add_ResizeEnd({ $form.Invalidate($true) })
$form.Add_Shown({
    Fit-Window
    $script:shownDone = $true
    if (-not (Test-SymlinkAbility)) { Log '※ 심볼릭 링크를 만들 권한이 없습니다. 관리자 권한으로 실행해 주세요.' }
})
Do-Layout
Update-Rows
[void]$form.ShowDialog()
