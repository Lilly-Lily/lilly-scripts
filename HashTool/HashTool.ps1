<#
  해시 도구 (GUI)
  - 조회·저장 : 파일/폴더 해시 계산, JSON(검증용)·CSV(보기용) 저장
  - 비교      : 2개 이상 파일/폴더 동일성 비교 (첫 항목이 기준)
  - 검증      : 저장된 JSON 기록 또는 직접 입력한 해시 값과 대조

  폴더 해시 = 폴더 안 모든 파일의 (상대경로 + 해시) 목록으로 만든 대표값
  실행: HashTool.bat 더블클릭 (또는 bat에 파일·폴더를 끌어다 놓기)
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$InitialPaths
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ═════════════════════════ 해시 엔진 (백그라운드 실행) ═════════════════════════

$script:EngineCode = {
    param($Jobs, $sync)
    $ErrorActionPreference = 'Stop'

    function New-Hasher([string]$a) {
        switch ($a) {
            'MD5'    { return [Security.Cryptography.MD5]::Create() }
            'SHA1'   { return [Security.Cryptography.SHA1]::Create() }
            'SHA384' { return [Security.Cryptography.SHA384]::Create() }
            'SHA512' { return [Security.Cryptography.SHA512]::Create() }
            default  { return [Security.Cryptography.SHA256]::Create() }
        }
    }
    function ConvertTo-Hex([byte[]]$b) { ([BitConverter]::ToString($b)) -replace '-', '' }
    function Get-StringHash([string]$Text, [string]$Algo) {
        $h = New-Hasher $Algo
        try { ConvertTo-Hex ($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) }
        finally { $h.Dispose() }
    }
    function Get-StreamHash([string]$Path, [string]$Algo) {
        $h = New-Hasher $Algo
        $fs = New-Object IO.FileStream -ArgumentList $Path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::ReadWrite), 1048576
        try {
            $buf = New-Object byte[] 4194304
            while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                if ($sync.Cancel) { throw 'CANCELLED' }
                [void]$h.TransformBlock($buf, 0, $n, $null, 0)
                $sync.BytesDone += $n
            }
            [void]$h.TransformFinalBlock($buf, 0, 0)
            ConvertTo-Hex $h.Hash
        }
        finally { $fs.Dispose(); $h.Dispose() }
    }

    try {
        $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

        # 1) 파일 목록 확인
        $sync.Phase = 'scan'
        $plans = [System.Collections.Generic.List[object]]::new()
        foreach ($j in $Jobs) {
            if ($sync.Cancel) { throw 'CANCELLED' }
            $p = [string]$j.Path
            $sync.Current = $p
            $plan = @{ Job = $j; Item = $null; Files = $null; Error = $null }
            try {
                if (-not (Test-Path -LiteralPath $p)) { throw '경로를 찾을 수 없어요.' }
                $item = Get-Item -LiteralPath $p -Force
                $plan.Item = $item
                if ($item.PSIsContainer) {
                    $root = $item.FullName.TrimEnd('\', '/')
                    $list = [System.Collections.Generic.List[object]]::new()
                    $ex = @($j.Exclude | Where-Object { $_ })
                    Get-ChildItem -LiteralPath $item.FullName -File -Force -Recurse:([bool]$j.Recurse) -ErrorAction SilentlyContinue |
                        ForEach-Object {
                            if ($sync.Cancel) { throw 'CANCELLED' }
                            $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
                            $skip = $false
                            foreach ($pat in $ex) { if ($_.Name -like $pat -or $rel -like $pat) { $skip = $true; break } }
                            if (-not $skip) { $list.Add(@{ File = $_; Rel = $rel }); $sync.ScanCount++ }
                        }
                    $plan.Files = $list
                }
                else {
                    $plan.Files = @(@{ File = $item; Rel = $item.Name })
                    $sync.ScanCount++
                }
            }
            catch {
                if ($sync.Cancel) { throw }
                $plan.Error = $_.Exception.Message
            }
            $plans.Add($plan)
        }

        $ft = 0; $bt = [long]0
        foreach ($pl in $plans) { if ($pl.Files) { foreach ($x in $pl.Files) { $ft++; $bt += $x.File.Length } } }
        $sync.FilesTotal = $ft; $sync.BytesTotal = $bt

        # 2) 해시 계산
        $sync.Phase = 'hash'
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($pl in $plans) {
            $j = $pl.Job
            $r = [ordered]@{
                Type = ''; Path = [string]$j.Path; Algorithm = [string]$j.Algo; Hash = ''
                FileCount = 0; TotalBytes = [long]0; Errors = 0
                Recurse = [bool]$j.Recurse; Exclude = @($j.Exclude | Where-Object { $_ })
                CreatedAt = $now; Files = @(); Error = $null
            }
            if ($pl.Error) { $r.Type = 'Missing'; $r.Error = $pl.Error; $results.Add([pscustomobject]$r); continue }

            $entries = [System.Collections.Generic.List[object]]::new()
            $errs = 0; $bytes = [long]0; $lastErr = $null
            foreach ($x in $pl.Files) {
                if ($sync.Cancel) { throw 'CANCELLED' }
                $sync.Current = $x.Rel
                try { $h = Get-StreamHash $x.File.FullName $j.Algo }
                catch {
                    if ($sync.Cancel) { throw }
                    $h = 'ERROR'; $errs++; $lastErr = $_.Exception.Message
                }
                $sync.FilesDone++
                $bytes += $x.File.Length
                $entries.Add([pscustomobject]@{ RelPath = $x.Rel; Size = [long]$x.File.Length; Hash = $h })
            }

            $r.FileCount = $entries.Count; $r.TotalBytes = $bytes; $r.Errors = $errs
            if ($pl.Item.PSIsContainer) {
                $r.Type = 'Folder'
                $r.Path = $pl.Item.FullName
                $lines = [string[]]@($entries | ForEach-Object { "$($_.RelPath.ToLowerInvariant())|$($_.Hash)" })
                [Array]::Sort($lines, [StringComparer]::Ordinal)
                $r.Hash = Get-StringHash ($lines -join "`n") $j.Algo
                $r.Files = @($entries | Sort-Object RelPath)
            }
            else {
                $r.Type = 'File'
                $r.Path = $pl.Item.FullName
                $r.Hash = $entries[0].Hash
                $r.Files = $entries.ToArray()
                if ($errs -gt 0) { $r.Error = $lastErr }
            }
            $results.Add([pscustomobject]$r)
        }
        $sync.Results = $results.ToArray()
    }
    catch {
        if ($sync.Cancel) { $sync.Cancelled = $true }
        else { $sync.Error = $_.Exception.Message }
    }
}

# ═════════════════════════ 공통 유틸 ═════════════════════════

function Format-Size([double]$b) {
    if ($b -ge 1TB) { '{0:N2} TB' -f ($b / 1TB) }
    elseif ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N2} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N1} KB' -f ($b / 1KB) }
    else { "$b B" }
}

function Format-Duration([TimeSpan]$t) {
    if ($t.TotalHours -ge 1) { '{0}시간 {1}분 {2}초' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds }
    elseif ($t.TotalMinutes -ge 1) { '{0}분 {1}초' -f $t.Minutes, $t.Seconds }
    else { '{0:N1}초' -f $t.TotalSeconds }
}

function Get-TypeName([string]$t) {
    switch ($t) { 'File' { '파일' } 'Folder' { '폴더' } 'Missing' { '없음' } default { $t } }
}

# 붙여넣은 문자열에서 해시 값을 찾아 알고리즘까지 판별
function Find-HashValue([string]$s) {
    if (-not $s) { return $null }
    $map = @{ 32 = 'MD5'; 40 = 'SHA1'; 64 = 'SHA256'; 96 = 'SHA384'; 128 = 'SHA512' }
    foreach ($m in [regex]::Matches($s, '[0-9A-Fa-f]+')) {
        $algo = $map[$m.Value.Length]
        if ($algo) { return @{ Hash = $m.Value.ToUpperInvariant(); Algo = $algo } }
    }
    $null
}

# 두 결과 비교 → 차이 목록
function Get-Diff($A, $B, [string]$OnlyA, [string]$OnlyB) {
    $rows = [System.Collections.Generic.List[object]]::new()
    if ($A.Type -ne $B.Type) {
        $rows.Add([pscustomobject]@{ Status = '유형 다름'; RelPath = "$(Get-TypeName $A.Type) vs $(Get-TypeName $B.Type)"; HashA = $A.Hash; HashB = $B.Hash })
        return , $rows
    }
    if ($A.Type -eq 'File') {
        if ($A.Hash -ne $B.Hash) {
            $rows.Add([pscustomobject]@{ Status = '내용 다름'; RelPath = [IO.Path]::GetFileName([string]$B.Path); HashA = $A.Hash; HashB = $B.Hash })
        }
        return , $rows
    }
    $ma = @{}; foreach ($e in @($A.Files)) { if ($e) { $ma[[string]$e.RelPath] = $e } }
    $mb = @{}; foreach ($e in @($B.Files)) { if ($e) { $mb[[string]$e.RelPath] = $e } }
    foreach ($k in $ma.Keys) {
        if (-not $mb.ContainsKey($k)) {
            $rows.Add([pscustomobject]@{ Status = $OnlyA; RelPath = $k; HashA = $ma[$k].Hash; HashB = '' })
        }
        elseif ($ma[$k].Hash -eq 'ERROR' -or $mb[$k].Hash -eq 'ERROR') {
            $rows.Add([pscustomobject]@{ Status = '읽기 오류'; RelPath = $k; HashA = $ma[$k].Hash; HashB = $mb[$k].Hash })
        }
        elseif ($ma[$k].Hash -ne $mb[$k].Hash) {
            $rows.Add([pscustomobject]@{ Status = '내용 다름'; RelPath = $k; HashA = $ma[$k].Hash; HashB = $mb[$k].Hash })
        }
    }
    foreach ($k in $mb.Keys) {
        if (-not $ma.ContainsKey($k)) {
            $rows.Add([pscustomobject]@{ Status = $OnlyB; RelPath = $k; HashA = ''; HashB = $mb[$k].Hash })
        }
    }
    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($r in ($rows | Sort-Object Status, RelPath)) { $sorted.Add($r) }
    return , $sorted
}

function Get-DiffSummary($rows) {
    (@($rows) | Group-Object Status | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ' · '
}

function Export-Rows($Rows, [string]$Path) {
    $enc = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    @($Rows) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding $enc
}

function Get-SafeName([string]$p) {
    $n = [IO.Path]::GetFileName(([string]$p).TrimEnd('\', '/'))
    if (-not $n) { $n = ([string]$p) -replace '[:\\/]', '' }
    if (-not $n) { $n = 'hash' }
    $n -replace '[\\/:*?"<>|]', '_'
}


# ── 묶음 비교 (비교 탭) ──

# 결과 목록 → 비교용 항목(Key=짝을 맞출 이름) 목록. 파일은 파일 이름, 폴더는 폴더 안 상대 경로
function Get-GroupEntries($Results) {
    $list = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($r in @($Results)) {
        if (-not $r -or $r.Type -eq 'Missing') { continue }
        foreach ($f in @($r.Files)) {
            if (-not $f) { continue }
            if ($r.Type -eq 'File') { $key = [IO.Path]::GetFileName([string]$r.Path); $full = [string]$r.Path }
            else { $key = [string]$f.RelPath; $full = Join-Path ([string]$r.Path) ([string]$f.RelPath) }
            $k = $key; $n = 2
            while ($seen.ContainsKey($k)) { $k = "$key [$n]"; $n++ }
            $seen[$k] = $true
            $list.Add([pscustomobject]@{ Key = $k; Hash = [string]$f.Hash; Size = $f.Size; Full = $full })
        }
    }
    , $list
}

$script:CompareRank = @{ '내용 다름' = 0; '읽기 오류' = 1; '원본에만' = 2; '대상에만' = 3; '일치' = 4 }

function New-CompareRow([string]$Status, $S, $D) {
    [pscustomobject]@{
        Status  = $Status
        SrcName = $(if ($S) { $S.Key } else { '' }); DstName = $(if ($D) { $D.Key } else { '' })
        SrcHash = $(if ($S) { $S.Hash } else { '' }); DstHash = $(if ($D) { $D.Hash } else { '' })
        SrcPath = $(if ($S) { $S.Full } else { '' }); DstPath = $(if ($D) { $D.Full } else { '' })
    }
}

function Sort-CompareRows($rows) {
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($r in (@($rows) | Sort-Object @{ e = { $script:CompareRank[$_.Status] } }, SrcName, DstName)) { $out.Add($r) }
    , $out
}

# 이름(상대 경로) 기준으로 짝을 지어 비교
function Compare-ByName($Src, $Dst) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $mb = @{}; foreach ($d in $Dst) { $mb[$d.Key] = $d }
    $ma = @{}
    foreach ($s in $Src) {
        $ma[$s.Key] = $s
        if (-not $mb.ContainsKey($s.Key)) { $rows.Add((New-CompareRow '원본에만' $s $null)); continue }
        $d = $mb[$s.Key]
        if ($s.Hash -eq 'ERROR' -or $d.Hash -eq 'ERROR') { $st = '읽기 오류' }
        elseif ($s.Hash -eq $d.Hash) { $st = '일치' }
        else { $st = '내용 다름' }
        $rows.Add((New-CompareRow $st $s $d))
    }
    foreach ($d in $Dst) { if (-not $ma.ContainsKey($d.Key)) { $rows.Add((New-CompareRow '대상에만' $null $d)) } }
    Sort-CompareRows $rows
}

# 이름은 무시하고 해시(내용)만으로 짝을 지어 비교 (같은 내용이 여러 개면 개수까지 맞춤)
function Compare-ByContent($Src, $Dst) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $pool = @{}
    foreach ($d in $Dst) {
        if ($d.Hash -eq 'ERROR') { $rows.Add((New-CompareRow '읽기 오류' $null $d)); continue }
        if (-not $pool.ContainsKey($d.Hash)) { $pool[$d.Hash] = [System.Collections.Generic.List[object]]::new() }
        $pool[$d.Hash].Add($d)
    }
    foreach ($s in $Src) {
        if ($s.Hash -eq 'ERROR') { $rows.Add((New-CompareRow '읽기 오류' $s $null)); continue }
        if ($pool.ContainsKey($s.Hash) -and $pool[$s.Hash].Count -gt 0) {
            $d = $pool[$s.Hash][0]; $pool[$s.Hash].RemoveAt(0)
            $rows.Add((New-CompareRow '일치' $s $d))
        }
        else { $rows.Add((New-CompareRow '원본에만' $s $null)) }
    }
    foreach ($k in $pool.Keys) { foreach ($d in $pool[$k]) { $rows.Add((New-CompareRow '대상에만' $null $d)) } }
    Sort-CompareRows $rows
}

# 대상 결과 → 비교군. Multi면 폴더는 각각, 파일은 같은 상위 폴더끼리 묶음
function Get-TargetGroups($Results, [bool]$Multi) {
    $groups = [System.Collections.Generic.List[object]]::new()
    $all = @($Results | Where-Object { $_ })
    if (-not $Multi) {
        $groups.Add(@{ Name = "대상 전체 ($($all.Count)개 항목)"; Results = $all })
        return , $groups
    }
    $map = [ordered]@{}
    foreach ($r in $all) {
        $name = if ($r.Type -eq 'File') { [IO.Path]::GetDirectoryName([string]$r.Path) } else { [string]$r.Path }
        if (-not $map.Contains($name)) { $map[$name] = [System.Collections.Generic.List[object]]::new() }
        $map[$name].Add($r)
    }
    foreach ($k in $map.Keys) { $groups.Add(@{ Name = $k; Results = $map[$k].ToArray() }) }
    , $groups
}

# ═════════════════════════ DPI · 공통 스타일 ═════════════════════════

try {
    Add-Type -Namespace HashToolNative -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop
    [void][HashToolNative.Win]::SetProcessDPIAware()
}
catch {}
[Windows.Forms.Application]::EnableVisualStyles()

$g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:Scale = $g.DpiX / 96.0
$g.Dispose()

function S([double]$v) { if ($v -lt 0) { return [int]$v }; [int][math]::Round($v * $script:Scale) }
function Pad($l, $t, $r, $b) { New-Object Windows.Forms.Padding -ArgumentList (S $l), (S $t), (S $r), (S $b) }
function Sz($w, $h) { New-Object Drawing.Size -ArgumentList (S $w), (S $h) }

$script:UiFont   = New-Object Drawing.Font -ArgumentList 'Malgun Gothic', 9
$script:BoldFont = New-Object Drawing.Font -ArgumentList 'Malgun Gothic', 9, ([Drawing.FontStyle]::Bold)
$script:MonoFont = New-Object Drawing.Font -ArgumentList 'Consolas', 9.5
$script:BigFont  = New-Object Drawing.Font -ArgumentList 'Malgun Gothic', 13, ([Drawing.FontStyle]::Bold)

# SHA256(64자리)이 잘리지 않는 열 폭을 실제 글꼴로 측정
$script:HashColW = [Windows.Forms.TextRenderer]::MeasureText('0539F26A3088AB580B6CA6C334DA3181D057CCCEABFC93ACEEA4CD63B4EFB7AC', $script:UiFont).Width + (S 18)

$script:Red    = [Drawing.Color]::FromArgb(196, 30, 30)
$script:Green  = [Drawing.Color]::FromArgb(20, 120, 50)
$script:Orange = [Drawing.Color]::FromArgb(190, 100, 0)
$script:Blue   = [Drawing.Color]::FromArgb(30, 90, 190)
$script:Gray   = [Drawing.Color]::FromArgb(110, 110, 110)
$script:StatusColors = @{
    '내용 다름' = $script:Red; '유형 다름' = $script:Red; '읽기 오류' = $script:Red; 'ERROR' = $script:Red
    '기준에만' = $script:Orange; '삭제됨' = $script:Orange
    '대상에만' = $script:Blue; '추가됨' = $script:Blue
    '다름' = $script:Red; '동일' = $script:Green; '경로 없음' = $script:Red
    '일치' = $script:Green; '원본에만' = $script:Orange
}

# ═════════════════════════ 컨트롤 생성 도우미 ═════════════════════════

function New-Ctl([string]$Type, [hashtable]$Props) {
    $c = New-Object "System.Windows.Forms.$Type"
    if ($Props) { foreach ($k in $Props.Keys) { $c.$k = $Props[$k] } }
    $c
}

function New-Btn([string]$Text, [int]$W = 90) {
    New-Ctl Button @{ Text = $Text; Width = (S $W); Height = (S 28); Margin = (Pad 0 2 6 2); UseVisualStyleBackColor = $true }
}

function New-Lbl([string]$Text) {
    New-Ctl Label @{ Text = $Text; AutoSize = $true; Margin = (Pad 0 8 4 0) }
}

function New-Flow([string]$Dock = 'Top') {
    New-Ctl FlowLayoutPanel @{ Dock = $Dock; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $true; Padding = (Pad 0 3 0 3) }
}

function New-List([object[]]$Cols) {
    $lv = New-Ctl ListView @{ View = 'Details'; FullRowSelect = $true; GridLines = $true; HideSelection = $false; Dock = 'Fill' }
    for ($i = 0; $i -lt $Cols.Count; $i += 2) {
        $w = if ([string]$Cols[$i + 1] -eq 'H') { $script:HashColW } else { S $Cols[$i + 1] }
        [void]$lv.Columns.Add([string]$Cols[$i], $w)
    }
    $lv
}

# 행이 많아도 빠른 가상 목록 (Rows: List[string[]], ColorCol: 색을 정할 열)
function New-VirtualList([object[]]$Cols, [int]$ColorCol = -1) {
    $lv = New-List $Cols
    $lv.VirtualMode = $true
    $lv.VirtualListSize = 0
    $lv.Tag = @{ Rows = ([System.Collections.Generic.List[object]]::new()); ColorCol = $ColorCol }
    $lv.Add_RetrieveVirtualItem({
            param($s, $e)
            $st = $s.Tag
            $row = $st.Rows[$e.ItemIndex]
            $it = [Windows.Forms.ListViewItem]::new([string]$row[0])
            for ($k = 1; $k -lt $row.Count; $k++) { [void]$it.SubItems.Add([string]$row[$k]) }
            if ($st.ColorCol -ge 0) {
                $c = $script:StatusColors[[string]$row[$st.ColorCol]]
                if ($c) { $it.ForeColor = $c }
            }
            $e.Item = $it
        })
    $lv
}

function Set-VirtualRows($lv, $Rows) {
    $lv.VirtualListSize = 0
    $list = [System.Collections.Generic.List[object]]::new()
    if ($Rows) { foreach ($r in $Rows) { $list.Add($r) } }
    $lv.Tag.Rows = $list
    $lv.VirtualListSize = $list.Count
    $lv.Invalidate()
}

function New-Grid([int]$Rows) {
    $t = New-Ctl TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 3; RowCount = $Rows }
    [void]$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle -ArgumentList ([Windows.Forms.SizeType]::AutoSize)))
    [void]$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle -ArgumentList ([Windows.Forms.SizeType]::Percent), 100))
    [void]$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle -ArgumentList ([Windows.Forms.SizeType]::AutoSize)))
    for ($i = 0; $i -lt $Rows; $i++) { [void]$t.RowStyles.Add((New-Object Windows.Forms.RowStyle -ArgumentList ([Windows.Forms.SizeType]::AutoSize))) }
    $t
}

function New-GridLabel([string]$Text) {
    New-Ctl Label @{ Text = $Text; AutoSize = $true; Anchor = 'Left'; Margin = (Pad 0 0 8 0) }
}

# ═════════════════════════ 대화상자 · 상태 ═════════════════════════

function Show-Info([string]$m) { [void][Windows.Forms.MessageBox]::Show($script:Form, $m, '해시 도구', 'OK', 'Information') }
function Show-Warn([string]$m) { [void][Windows.Forms.MessageBox]::Show($script:Form, $m, '해시 도구', 'OK', 'Warning') }
function Set-Status([string]$t) { $script:Status.Text = $t }

function Set-ClipText([string]$t) {
    if (-not $t) { return }
    try { [Windows.Forms.Clipboard]::SetText($t); Set-Status '클립보드에 복사했어요.' }
    catch { Show-Warn "복사하지 못했어요: $($_.Exception.Message)" }
}

function Select-Folder([string]$Desc = '폴더를 선택하세요') {
    $d = New-Object Windows.Forms.FolderBrowserDialog
    $d.Description = $Desc; $d.ShowNewFolderButton = $false
    if ($d.ShowDialog($script:Form) -eq 'OK') { return $d.SelectedPath }
    $null
}

function Select-Files([bool]$Multi = $true, [string]$Filter = '모든 파일|*.*') {
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Multiselect = $Multi; $d.Filter = $Filter
    if ($d.ShowDialog($script:Form) -eq 'OK') { return , $d.FileNames }
    , @()
}

function Select-SavePath([string]$Filter, [string]$Name) {
    $d = New-Object Windows.Forms.SaveFileDialog
    $d.Filter = $Filter; $d.FileName = $Name; $d.OverwritePrompt = $true
    if ($d.ShowDialog($script:Form) -eq 'OK') { return $d.FileName }
    $null
}

$script:DropEnter = {
    param($s, $e)
    if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' } else { $e.Effect = 'None' }
}
$script:TextDrop = {
    param($s, $e)
    $f = @($e.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
    if ($f.Count -gt 0) { $s.Text = [string]$f[0] }
}

# ═════════════════════════ 백그라운드 작업 관리 ═════════════════════════

$script:Job = $null

function Set-Busy([bool]$b) {
    $script:Tabs.Enabled = -not $b
    $script:BtnCancel.Enabled = $b
    if ($b) { $script:Form.Cursor = [Windows.Forms.Cursors]::AppStarting } else { $script:Form.Cursor = [Windows.Forms.Cursors]::Default }
}

function Start-HashJob([object[]]$Jobs, [string]$OnDone) {
    if ($script:Job) { return }
    $script:Sync = [hashtable]::Synchronized(@{
            Cancel = $false; Cancelled = $false; Error = $null; Phase = 'scan'; Current = ''
            ScanCount = 0; FilesDone = 0; FilesTotal = 0; BytesDone = [long]0; BytesTotal = [long]0; Results = $null
        })
    $script:OnDone = $OnDone
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:EngineCode.ToString()).AddParameter('Jobs', $Jobs).AddParameter('sync', $script:Sync)
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Watch = [Diagnostics.Stopwatch]::StartNew() }
    $script:Progress.Value = 0
    Set-Busy $true
    $script:Timer.Start()
}

function Update-JobProgress {
    $j = $script:Job; $sy = $script:Sync
    if (-not $j) { return }
    $el = Format-Duration $j.Watch.Elapsed
    if ($sy.Phase -eq 'scan') {
        if ($script:Progress.Style -ne 'Marquee') { $script:Progress.Style = 'Marquee' }
        Set-Status ('파일 목록 확인 중… {0:N0}개 · {1}' -f $sy.ScanCount, $el)
    }
    else {
        if ($script:Progress.Style -ne 'Continuous') { $script:Progress.Style = 'Continuous' }
        $pct = 0
        if ($sy.BytesTotal -gt 0) { $pct = [int](100.0 * $sy.BytesDone / $sy.BytesTotal) }
        elseif ($sy.FilesTotal -gt 0) { $pct = [int](100.0 * $sy.FilesDone / $sy.FilesTotal) }
        $script:Progress.Value = [math]::Min(100, [math]::Max(0, $pct))
        Set-Status ('해시 계산 중 {0}% · 파일 {1:N0}/{2:N0} · {3}/{4} · {5} · {6}' -f $pct, $sy.FilesDone, $sy.FilesTotal,
            (Format-Size $sy.BytesDone), (Format-Size $sy.BytesTotal), $el, $sy.Current)
    }
    if ($j.Handle.IsCompleted) { Complete-HashJob }
}

function Complete-HashJob {
    $script:Timer.Stop()
    $j = $script:Job
    $script:Job = $null
    $sy = $script:Sync
    try { [void]$j.PS.EndInvoke($j.Handle) }
    catch { if (-not $sy.Error -and -not $sy.Cancel) { $sy.Error = $_.Exception.Message } }
    if (-not $sy.Error -and -not $sy.Results -and -not $sy.Cancel -and $j.PS.Streams.Error.Count -gt 0) {
        $sy.Error = $j.PS.Streams.Error[0].ToString()
    }
    $j.PS.Dispose(); $j.RS.Dispose()
    $elapsed = Format-Duration $j.Watch.Elapsed
    $script:Progress.Style = 'Continuous'
    Set-Busy $false

    if ($sy.Cancel -or $sy.Cancelled) { $script:Progress.Value = 0; Set-Status "취소했어요. ($elapsed)"; return }
    if ($sy.Error) {
        $script:Progress.Value = 0
        Set-Status '오류로 중단됐어요.'
        Show-Warn "작업 중 오류가 났어요.`n$($sy.Error)"
        return
    }
    $script:Progress.Value = 100
    $res = @($sy.Results)
    $summary = ''
    try { $summary = & $script:OnDone $res | Where-Object { $_ -is [string] } | Select-Object -Last 1 }
    catch { Show-Warn "결과를 표시하는 중 오류가 났어요.`n$($_.Exception.Message)" }
    if ($summary) { Set-Status "완료 · $summary · 소요 $elapsed" } else { Set-Status "완료 · 소요 $elapsed" }
}

# ═════════════════════════ 대상 목록 · 옵션 (조회·비교 탭 공용) ═════════════════════════

function Add-Targets($sec, [string[]]$Paths) {
    $skipped = 0
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        $p = $p.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $p)) { $skipped++; continue }
        $p = (Get-Item -LiteralPath $p -Force).FullName
        $dup = $false
        foreach ($it in $sec.List.Items) { if ($it.Tag -eq $p) { $dup = $true; break } }
        if ($dup) { continue }
        $type = if (Test-Path -LiteralPath $p -PathType Container) { '폴더' } else { '파일' }
        $it = [Windows.Forms.ListViewItem]::new($type)
        [void]$it.SubItems.Add($p)
        $it.Tag = $p
        [void]$sec.List.Items.Add($it)
    }
    if ($skipped -gt 0) { Set-Status "찾을 수 없는 경로 $skipped 개는 건너뛰었어요." }
}

function Remove-SelectedTargets($sec) {
    foreach ($it in @($sec.List.SelectedItems)) { $sec.List.Items.Remove($it) }
}

function Get-OptionValues($opt) {
    @{
        Algo    = [string]$opt.Algo.SelectedItem
        Recurse = [bool]$opt.Recurse.Checked
        Exclude = @($opt.Exclude.Text -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}

function Get-TargetJobs($sec, $opt) {
    $o = Get-OptionValues $opt
    , @(foreach ($it in $sec.List.Items) { @{ Path = [string]$it.Tag; Algo = $o.Algo; Recurse = $o.Recurse; Exclude = $o.Exclude } })
}

# 끌어다 놓기 + 추가/삭제 버튼이 있는 목록 상자
function New-TargetList([string]$Title, [int]$PathWidth = 700) {
    $sec = @{}
    $grp = New-Ctl GroupBox @{ Text = $Title; Dock = 'Fill'; Padding = (Pad 6 4 6 4) }
    $lv = New-List @('유형', 50, '경로', $PathWidth)
    $lv.AllowDrop = $true
    $lv.Tag = $sec
    $lv.Add_DragEnter($script:DropEnter)
    $lv.Add_DragDrop({ param($s, $e) Add-Targets $s.Tag ([string[]]@($e.Data.GetData([Windows.Forms.DataFormats]::FileDrop))) })
    $lv.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Delete') { Remove-SelectedTargets $s.Tag } })

    $cm = New-Object Windows.Forms.ContextMenuStrip
    $mi = $cm.Items.Add('경로 복사'); $mi.Tag = $sec
    $mi.Add_Click({ param($s, $e) Set-ClipText ((@($s.Tag.List.SelectedItems) | ForEach-Object { $_.Tag }) -join "`r`n") })
    $mi = $cm.Items.Add('삭제'); $mi.Tag = $sec
    $mi.Add_Click({ param($s, $e) Remove-SelectedTargets $s.Tag })
    $lv.ContextMenuStrip = $cm

    $bf = New-Flow 'Bottom'
    $bFile = New-Btn '+ 파일' 76; $bFile.Tag = $sec
    $bDir = New-Btn '+ 폴더' 76; $bDir.Tag = $sec
    $bDel = New-Btn '선택 삭제' 86; $bDel.Tag = $sec
    $bClr = New-Btn '비우기' 76; $bClr.Tag = $sec
    $bFile.Add_Click({ param($s, $e) $f = Select-Files $true; if ($f.Count) { Add-Targets $s.Tag $f } })
    $bDir.Add_Click({ param($s, $e) $d = Select-Folder; if ($d) { Add-Targets $s.Tag @($d) } })
    $bDel.Add_Click({ param($s, $e) Remove-SelectedTargets $s.Tag })
    $bClr.Add_Click({ param($s, $e) $s.Tag.List.Items.Clear() })
    $bf.Controls.AddRange(@($bFile, $bDir, $bDel, $bClr))

    $grp.Controls.Add($bf)
    $grp.Controls.Add($lv)
    $lv.BringToFront()
    $sec.Group = $grp; $sec.List = $lv
    $sec
}

# 알고리즘 · 하위 폴더 · 제외 패턴 줄
function New-OptionFlow {
    $flow = New-Flow
    $cbA = New-Ctl ComboBox @{ DropDownStyle = 'DropDownList'; Width = (S 90); Margin = (Pad 0 4 14 0) }
    [void]$cbA.Items.AddRange([object[]]@('SHA256', 'SHA1', 'SHA384', 'SHA512', 'MD5'))
    $cbA.SelectedIndex = 0
    $chkR = New-Ctl CheckBox @{ Text = '하위 폴더 포함'; Checked = $true; AutoSize = $true; Margin = (Pad 0 7 14 0) }
    $txtE = New-Ctl TextBox @{ Width = (S 220); Margin = (Pad 0 4 6 0) }
    $hintE = New-Lbl '예: *.log; cache\*'
    $hintE.ForeColor = $script:Gray
    $flow.Controls.AddRange(@((New-Lbl '알고리즘'), $cbA, $chkR, (New-Lbl '제외 패턴'), $txtE, $hintE))
    @{ Flow = $flow; Algo = $cbA; Recurse = $chkR; Exclude = $txtE }
}

function New-RunFlow([string]$Text) {
    $f = New-Flow
    $b = New-Btn $Text 120
    $b.Font = $script:BoldFont
    $f.Controls.Add($b)
    @{ Flow = $f; Button = $b }
}

# ═════════════════════════ 저장 · 파일별 목록 ═════════════════════════

function Save-ResultsJson($Results) {
    $valid = @($Results | Where-Object { $_ -and $_.Type -ne 'Missing' })
    if ($valid.Count -eq 0) { Show-Warn '저장할 결과가 없어요.'; return }
    $name = '{0}_{1}.json' -f $(if ($valid.Count -eq 1) { Get-SafeName $valid[0].Path } else { 'multi' }), (Get-Date -Format 'yyyyMMdd_HHmmss')
    $out = Select-SavePath 'JSON 기록 (검증용)|*.json' $name
    if (-not $out) { return }
    $targets = @($valid | Select-Object Type, Path, Algorithm, Hash, FileCount, TotalBytes, Errors, Recurse, Exclude, CreatedAt, Files)
    $doc = [ordered]@{
        Tool = 'HashTool'; Version = 1
        CreatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Computer = $env:COMPUTERNAME
        Targets = $targets
    }
    $json = $doc | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($out, $json, (New-Object Text.UTF8Encoding -ArgumentList $true))
    Set-Status "JSON 저장 완료: $out"
}

function Save-ResultsCsv($Results) {
    $valid = @($Results | Where-Object { $_ -and $_.Type -ne 'Missing' })
    if ($valid.Count -eq 0) { Show-Warn '저장할 결과가 없어요.'; return }
    $name = '{0}_{1}.csv' -f $(if ($valid.Count -eq 1) { Get-SafeName $valid[0].Path } else { 'multi' }), (Get-Date -Format 'yyyyMMdd_HHmmss')
    $out = Select-SavePath 'CSV (엑셀 보기용)|*.csv' $name
    if (-not $out) { return }
    $rows = foreach ($r in $valid) {
        foreach ($f in @($r.Files)) {
            [pscustomobject]@{
                Target = $r.Path; Type = $r.Type; TargetHash = $r.Hash
                RelPath = $f.RelPath; Size = $f.Size; Hash = $f.Hash
                Algorithm = $r.Algorithm; CreatedAt = $r.CreatedAt
            }
        }
    }
    Export-Rows $rows $out
    Set-Status "CSV 저장 완료: $out"
}

function Update-FileListFilter($frm) {
    $st = $frm.Tag
    $q = $st.Search.Text.Trim()
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $st.All) {
        if (-not $q -or $r[0].IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $rows.Add($r) }
    }
    Set-VirtualRows $st.List $rows
    $st.Count.Text = '{0:N0} / {1:N0}개' -f $rows.Count, $st.All.Count
}

function Show-FileList($r) {
    $frm = New-Ctl Form @{
        Text = "파일별 해시 — $($r.Path)"; Size = (Sz 1080 640); StartPosition = 'CenterParent'
        Font = $script:UiFont; AutoScaleMode = 'None'; MinimizeBox = $false; ShowIcon = $false
        Padding = (Pad 8 8 8 8)
    }
    $top = New-Flow
    $txtQ = New-Ctl TextBox @{ Width = (S 260); Margin = (Pad 0 4 10 0) }
    $lblC = New-Lbl ''
    $lblC.ForeColor = $script:Gray
    $top.Controls.AddRange(@((New-Lbl '검색'), $txtQ, $lblC))

    $lv = New-VirtualList @('상대 경로', 440, '크기', 90, $r.Algorithm, 'H') 2
    $bot = New-Flow 'Bottom'
    $bCopy = New-Btn '선택 해시 복사' 120
    $bCsv = New-Btn 'CSV 저장' 90
    $bClose = New-Btn '닫기' 80
    $bot.Controls.AddRange(@($bCopy, $bCsv, $bClose))

    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @($r.Files)) { $all.Add([string[]]@([string]$f.RelPath, (Format-Size $f.Size), [string]$f.Hash)) }
    $frm.Tag = @{ All = $all; List = $lv; Search = $txtQ; Count = $lblC; Result = $r }

    $txtQ.Add_TextChanged({ param($s, $e) Update-FileListFilter $s.FindForm() })
    $bCopy.Add_Click({ param($s, $e)
            $st = $s.FindForm().Tag
            $lines = foreach ($i in $st.List.SelectedIndices) { $row = $st.List.Tag.Rows[$i]; "$($row[2])  $($row[0])" }
            if (@($lines).Count -eq 1) { Set-ClipText $st.List.Tag.Rows[$st.List.SelectedIndices[0]][2] }
            elseif (@($lines).Count -gt 1) { Set-ClipText (@($lines) -join "`r`n") }
        })
    $bCsv.Add_Click({ param($s, $e) Save-ResultsCsv @($s.FindForm().Tag.Result) })
    $bClose.Add_Click({ param($s, $e) $s.FindForm().Close() })

    $frm.Controls.Add($top)
    $frm.Controls.Add($bot)
    $frm.Controls.Add($lv)
    $lv.BringToFront()
    Update-FileListFilter $frm
    [void]$frm.ShowDialog($script:Form)
    $frm.Dispose()
}

# ═════════════════════════ 탭 1: 조회·저장 ═════════════════════════

function Complete-T1($res) {
    $script:T1Results = @($res)
    $lv = $script:T1.Result
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($r in $script:T1Results) {
        $it = [Windows.Forms.ListViewItem]::new([string]$r.Path)
        if ($r.Type -eq 'Missing') {
            foreach ($v in @('없음', [string]$r.Error, '', '', '')) { [void]$it.SubItems.Add($v) }
            $it.ForeColor = $script:Red
        }
        else {
            $err = if ($r.Errors -gt 0) { "$($r.Errors)개" } else { '' }
            foreach ($v in @((Get-TypeName $r.Type), [string]$r.Hash, ('{0:N0}' -f $r.FileCount), (Format-Size $r.TotalBytes), $err)) { [void]$it.SubItems.Add($v) }
            if ($r.Errors -gt 0) { $it.ForeColor = $script:Orange }
        }
        $it.Tag = $r
        [void]$lv.Items.Add($it)
    }
    $lv.EndUpdate()
    if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true }
    "대상 $($script:T1Results.Count)개"
}

function Get-T1Selected {
    $sel = @($script:T1.Result.SelectedItems)
    if ($sel.Count -eq 0) { $sel = @($script:T1.Result.Items) }
    , @($sel | ForEach-Object { $_.Tag })
}

# ═════════════════════════ 탭 2: 비교 ═════════════════════════

function Complete-T2($res) {
    $res = @($res)
    $nSrc = $script:T2.SrcCount
    $srcRes = @($res[0..($nSrc - 1)])
    $dstRes = @($res[$nSrc..($res.Count - 1)])
    $missing = @($res | Where-Object { $_.Type -eq 'Missing' } | ForEach-Object { "$($_.Path) — $($_.Error)" })

    $srcEntries = Get-GroupEntries $srcRes
    $groups = Get-TargetGroups $dstRes $script:T2.Multi
    $lv = $script:T2.Summary
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $script:T2Rows = [System.Collections.Generic.List[object]]::new()
    $same = 0

    foreach ($g in $groups) {
        $dstEntries = Get-GroupEntries $g.Results
        $rows = if ($script:T2.ByContent) { Compare-ByContent $srcEntries $dstEntries } else { Compare-ByName $srcEntries $dstEntries }
        $c = @{ '일치' = 0; '내용 다름' = 0; '원본에만' = 0; '대상에만' = 0; '읽기 오류' = 0 }
        foreach ($r in $rows) { $c[$r.Status]++ }
        $ok = ($rows.Count -gt 0 -and $c['일치'] -eq $rows.Count)
        if ($ok) { $same++ }
        $verdict = if ($ok) { '동일' } else { '다름' }

        $it = [Windows.Forms.ListViewItem]::new([string]$g.Name)
        foreach ($v in @($verdict, $c['일치'], $c['내용 다름'], $c['원본에만'], $c['대상에만'], $c['읽기 오류'])) { [void]$it.SubItems.Add([string]$v) }
        $it.ForeColor = $script:StatusColors[$verdict]
        $it.Tag = @{ Rows = $rows; Name = $g.Name }
        [void]$lv.Items.Add($it)

        foreach ($r in $rows) {
            $script:T2Rows.Add([pscustomobject]@{
                    Group = $g.Name; Status = $r.Status; SourceItem = $r.SrcName; TargetItem = $r.DstName
                    SourceHash = $r.SrcHash; TargetHash = $r.DstHash; SourcePath = $r.SrcPath; TargetPath = $r.DstPath
                })
        }
    }
    $lv.EndUpdate()
    if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true }

    if ($missing.Count -gt 0) { Show-Warn ("찾을 수 없는 경로가 있어서 비교에서 빠졌어요.`n`n" + ($missing -join "`n")) }
    $mode = if ($script:T2.ByContent) { '내용 기준' } else { '이름 기준' }
    if ($groups.Count -eq 1) { "$mode · $(if ($same -eq 1) { '동일' } else { '다름' })" }
    else { "$mode · 비교군 $($groups.Count)개 중 동일 $same 개" }
}

function Show-T2Detail {
    $sel = @($script:T2.Summary.SelectedItems)
    $rows = [System.Collections.Generic.List[object]]::new()
    if ($sel.Count -gt 0) {
        foreach ($r in $sel[0].Tag.Rows) { $rows.Add([string[]]@($r.Status, $r.SrcName, $r.DstName, $r.SrcHash, $r.DstHash)) }
        $script:T2.DetailLabel.Text = "상세 — $($sel[0].Tag.Name)  ($($rows.Count)건)"
    }
    else { $script:T2.DetailLabel.Text = '상세' }
    Set-VirtualRows $script:T2.Detail $rows
}

# ═════════════════════════ 탭 3: 검증 ═════════════════════════

function Set-Verdict([string]$Kind, [string]$Text) {
    $l = $script:T3.Verdict
    $l.Text = $Text
    switch ($Kind) {
        'ok'   { $l.BackColor = [Drawing.Color]::FromArgb(230, 244, 234); $l.ForeColor = $script:Green }
        'fail' { $l.BackColor = [Drawing.Color]::FromArgb(252, 232, 230); $l.ForeColor = $script:Red }
        default { $l.BackColor = [Drawing.SystemColors]::Control; $l.ForeColor = [Drawing.SystemColors]::ControlText }
    }
}

# Windows PowerShell 5.1의 ConvertFrom-Json은 큰 파일에서 실패할 수 있어서 대체 경로를 둠
function Read-JsonFile([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    try { return ($text | ConvertFrom-Json) }
    catch {
        if ($PSVersionTable.PSVersion.Major -ge 6) { throw }
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $ser.RecursionLimit = 100
        return $ser.DeserializeObject($text)
    }
}

function Update-SplitOnce {
    if ($script:SplitDone) { return }
    $sp = $script:T2.Split
    if ($sp.Height -gt (S 200)) {
        try { $sp.SplitterDistance = [int]($sp.Height * 0.4); $script:SplitDone = $true } catch {}
    }
}

function Load-Manifest([string]$Path) {
    $T3 = $script:T3
    $T3.Manifest = $null
    $T3.JInfo.ForeColor = $script:Gray
    $Path = $Path.Trim().Trim('"')
    if (-not $Path) { $T3.JInfo.Text = '저장해 둔 JSON 기록을 선택하거나 끌어다 놓으세요.'; return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $T3.JInfo.Text = '파일을 찾을 수 없어요.'; return }
    try {
        $m = Read-JsonFile $Path
        $targets = @($m.Targets | Where-Object { $_ })
        if ($targets.Count -eq 0) { throw 'no targets' }
        $T3.Manifest = $m
        $first = $targets[0]
        $more = if ($targets.Count -gt 1) { " 외 $($targets.Count - 1)개" } else { '' }
        $T3.JInfo.Text = '대상 {0}개 · {1} 저장 · {2} · {3}{4}' -f $targets.Count, $m.CreatedAt, $first.Algorithm, $first.Path, $more
        $T3.JInfo.ForeColor = [Drawing.SystemColors]::ControlText
        $T3.AltCheck.Enabled = ($targets.Count -eq 1)
        if ($targets.Count -ne 1) { $T3.AltCheck.Checked = $false }
    }
    catch {
        $T3.JInfo.Text = '검증용 JSON 기록이 아니에요. (CSV는 보기용이라 검증에 쓸 수 없어요)'
        $T3.JInfo.ForeColor = $script:Red
    }
}

function Update-HashInfo {
    $T3 = $script:T3
    $txt = $T3.HashBox.Text
    if (-not $txt.Trim()) { $T3.HInfo.Text = '다운로드 페이지 등에 공개된 해시를 붙여 넣으세요. 알고리즘은 길이로 자동 판별해요.'; $T3.HInfo.ForeColor = $script:Gray; return }
    $h = Find-HashValue $txt
    if ($h) { $T3.HInfo.Text = "$($h.Algo) 해시로 인식했어요."; $T3.HInfo.ForeColor = $script:Green }
    else { $T3.HInfo.Text = '해시 형식을 알 수 없어요. (MD5 · SHA1 · SHA256 · SHA384 · SHA512 지원)'; $T3.HInfo.ForeColor = $script:Red }
}

function Start-Verify {
    $T3 = $script:T3
    Set-Verdict 'none' ''
    $T3.Info.Text = ''
    Set-VirtualRows $T3.Diff $null
    $script:T3Rows = [System.Collections.Generic.List[object]]::new()

    if ($T3.RbJson.Checked) {
        $m = $T3.Manifest
        if (-not $m) { Show-Warn '먼저 저장된 기록(JSON) 파일을 지정해 주세요.'; return }
        $saved = @($m.Targets | Where-Object { $_ })
        $alt = $T3.AltBox.Text.Trim().Trim('"')
        $useAlt = $T3.AltCheck.Checked
        if ($useAlt -and -not $alt) { Show-Warn '비교할 다른 위치를 지정해 주세요.'; return }
        $jobs = @(foreach ($s in $saved) {
                $p = if ($useAlt) { $alt } else { [string]$s.Path }
                $rec = if ($null -eq $s.Recurse) { $true } else { [bool]$s.Recurse }
                @{ Path = $p; Algo = [string]$s.Algorithm; Recurse = $rec; Exclude = @($s.Exclude | Where-Object { $_ }) }
            })
        $T3.Saved = $saved
        Start-HashJob $jobs 'Complete-T3Json'
    }
    else {
        $p = $T3.TargetBox.Text.Trim().Trim('"')
        if (-not $p) { Show-Warn '검증할 파일이나 폴더를 지정해 주세요.'; return }
        if (-not (Test-Path -LiteralPath $p)) { Show-Warn "경로를 찾을 수 없어요.`n$p"; return }
        $h = Find-HashValue $T3.HashBox.Text
        if (-not $h) { Show-Warn '기대 해시 값을 올바르게 입력해 주세요.'; return }
        $T3.Expected = $h
        Start-HashJob @(@{ Path = $p; Algo = $h.Algo; Recurse = $true; Exclude = @() }) 'Complete-T3Direct'
    }
}

function Complete-T3Json($res) {
    $T3 = $script:T3
    $res = @($res); $saved = @($T3.Saved)
    $lines = [System.Collections.Generic.List[string]]::new()
    $view = [System.Collections.Generic.List[object]]::new()
    $okCount = 0
    $lines.Add("기록: $($T3.JsonBox.Text.Trim().Trim('"'))  ($($T3.Manifest.CreatedAt) 저장)")
    for ($i = 0; $i -lt $saved.Count; $i++) {
        $s = $saved[$i]; $n = $res[$i]
        if ($n.Type -eq 'Missing') { $lines.Add("[오류] $($n.Path) — $($n.Error)"); continue }
        $d = Get-Diff $s $n '삭제됨' '추가됨'
        if ($d.Count -eq 0) {
            $okCount++
            $lines.Add(('[일치] {0}  (파일 {1:N0}개)' -f $n.Path, $n.FileCount))
        }
        else {
            $lines.Add("[다름] $($n.Path) — $(Get-DiffSummary $d)")
            foreach ($r in $d) {
                $view.Add([string[]]@([string]$n.Path, $r.Status, $r.RelPath, [string]$r.HashA, [string]$r.HashB))
                $script:T3Rows.Add([pscustomobject]@{ Target = $n.Path; Status = $r.Status; RelPath = $r.RelPath; SavedHash = $r.HashA; CurrentHash = $r.HashB })
            }
        }
    }
    if ($okCount -eq $saved.Count) { Set-Verdict 'ok' '일치해요 — 저장 당시와 같아요' }
    else { Set-Verdict 'fail' ('일치하지 않아요 — {0}개 중 {1}개 달라짐' -f $saved.Count, ($saved.Count - $okCount)) }
    $T3.Info.Text = $lines -join "`r`n"
    Set-VirtualRows $T3.Diff $view
    "대상 $($saved.Count)개 중 일치 $okCount 개"
}

function Complete-T3Direct($res) {
    $T3 = $script:T3
    $n = @($res)[0]; $exp = $T3.Expected
    if ($n.Type -eq 'Missing' -or $n.Hash -eq 'ERROR') {
        Set-Verdict 'fail' '확인할 수 없어요'
        $T3.Info.Text = "대상: $($n.Path)`r`n오류: $($n.Error)"
        return '오류'
    }
    $ok = ($n.Hash -eq $exp.Hash)
    if ($ok) { Set-Verdict 'ok' '일치해요' } else { Set-Verdict 'fail' '일치하지 않아요' }
    $lines = @(
        "대상     : $($n.Path)  ($(Get-TypeName $n.Type))"
        "알고리즘 : $($exp.Algo)"
        "기대값   : $($exp.Hash)"
        "계산값   : $($n.Hash)"
    )
    if ($n.Type -eq 'Folder') { $lines += '※ 폴더 해시는 이 도구로 계산한 값끼리만 비교할 수 있어요.' }
    $T3.Info.Text = $lines -join "`r`n"
    if ($ok) { '일치' } else { '불일치' }
}

# ═════════════════════════ 메인 창 구성 ═════════════════════════

try {
    $script:Form = New-Ctl Form @{
        Text = '해시 도구'; Size = (Sz 1240 800); MinimumSize = (Sz 900 640)
        StartPosition = 'CenterScreen'; Font = $script:UiFont; AutoScaleMode = 'None'
    }
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:Form.Size = New-Object Drawing.Size -ArgumentList ([math]::Min($script:Form.Width, $wa.Width - 40)), ([math]::Min($script:Form.Height, $wa.Height - 40))
    try { $script:Form.Icon = [Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path) } catch {}

    # ── 하단 상태 영역 ──
    $bottom = New-Ctl Panel @{ Dock = 'Bottom'; Height = (S 60); Padding = (Pad 10 6 10 6) }
    $pRow = New-Ctl Panel @{ Dock = 'Top'; Height = (S 26) }
    $script:Progress = New-Ctl ProgressBar @{ Dock = 'Fill'; Minimum = 0; Maximum = 100; MarqueeAnimationSpeed = 30 }
    $script:BtnCancel = New-Ctl Button @{ Text = '■ 취소'; Dock = 'Right'; Width = (S 80); Enabled = $false; UseVisualStyleBackColor = $true }
    $gap = New-Ctl Panel @{ Dock = 'Right'; Width = (S 8) }
    $pRow.Controls.Add($script:BtnCancel)
    $pRow.Controls.Add($gap)
    $pRow.Controls.Add($script:Progress)
    $script:Progress.BringToFront()
    $script:Status = New-Ctl Label @{ Dock = 'Fill'; AutoEllipsis = $true; TextAlign = 'MiddleLeft'; Text = '준비됐어요.' }
    $bottom.Controls.Add($pRow)
    $bottom.Controls.Add($script:Status)
    $script:Status.BringToFront()

    $script:BtnCancel.Add_Click({ if ($script:Sync) { $script:Sync.Cancel = $true; Set-Status '취소하는 중…' } })

    $script:Tabs = New-Ctl TabControl @{ Dock = 'Fill'; Padding = (New-Object Drawing.Point -ArgumentList (S 14), (S 5)) }
    $tab1 = New-Ctl TabPage @{ Text = '조회·저장'; Padding = (Pad 8 8 8 8); UseVisualStyleBackColor = $true }
    $tab2 = New-Ctl TabPage @{ Text = '비교'; Padding = (Pad 8 8 8 8); UseVisualStyleBackColor = $true }
    $tab3 = New-Ctl TabPage @{ Text = '검증'; Padding = (Pad 8 8 8 8); UseVisualStyleBackColor = $true }
    $script:Tabs.TabPages.AddRange(@($tab1, $tab2, $tab3))

    # ── 탭 1: 조회·저장 ──
    $script:T1 = New-TargetList '대상 목록 — 파일·폴더를 여기에 끌어다 놓으세요'
    $script:T1.Group.Dock = 'Top'
    $script:T1.Group.Height = (S 190)
    $script:T1Opt = New-OptionFlow
    $run1 = New-RunFlow '▶ 계산'
    $script:T1.Run = $run1.Button
    $grp1 = New-Ctl GroupBox @{ Text = '결과 — 더블클릭하면 파일별 해시를 볼 수 있어요'; Dock = 'Fill'; Padding = (Pad 6 4 6 4) }
    $lv1 = New-List @('대상', 320, '유형', 50, '해시', 'H', '파일 수', 70, '크기', 90, '읽기 오류', 70)
    $f1 = New-Flow 'Bottom'
    $b1Copy = New-Btn '해시 복사' 90
    $b1List = New-Btn '파일별 목록' 100
    $b1Json = New-Btn 'JSON 저장' 90
    $b1Csv = New-Btn 'CSV 저장' 90
    $h1 = New-Lbl 'JSON은 나중에 [검증] 탭에서 쓰는 기록, CSV는 엑셀 보기용이에요.'
    $h1.ForeColor = $script:Gray
    $f1.Controls.AddRange(@($b1Copy, $b1List, $b1Json, $b1Csv, $h1))
    $grp1.Controls.Add($f1)
    $grp1.Controls.Add($lv1)
    $lv1.BringToFront()
    # Dock=Top 은 나중에 추가한 컨트롤이 위로 가므로 역순으로 추가
    $tab1.Controls.Add($run1.Flow)
    $tab1.Controls.Add($script:T1Opt.Flow)
    $tab1.Controls.Add($script:T1.Group)
    $tab1.Controls.Add($grp1)
    $grp1.BringToFront()
    $script:T1.Result = $lv1
    $script:T1Results = @()

    $script:T1.Run.Add_Click({
            $jobs = Get-TargetJobs $script:T1 $script:T1Opt
            if ($jobs.Count -eq 0) { Show-Warn '대상 목록에 파일이나 폴더를 추가해 주세요.'; return }
            $script:T1.Result.Items.Clear()
            Start-HashJob $jobs 'Complete-T1'
        })
    $b1Copy.Add_Click({
            $sel = @(Get-T1Selected | Where-Object { $_.Type -ne 'Missing' })
            if ($sel.Count -eq 1) { Set-ClipText $sel[0].Hash }
            elseif ($sel.Count -gt 1) { Set-ClipText (($sel | ForEach-Object { "$($_.Hash)  $($_.Path)" }) -join "`r`n") }
        })
    $openList = {
        $sel = @($script:T1.Result.SelectedItems)
        if ($sel.Count -eq 0) { Show-Info '결과에서 항목을 선택해 주세요.'; return }
        $r = $sel[0].Tag
        if ($r.Type -eq 'Missing') { return }
        Show-FileList $r
    }
    $b1List.Add_Click($openList)
    $lv1.Add_DoubleClick($openList)
    $b1Json.Add_Click({ Save-ResultsJson $script:T1Results })
    $b1Csv.Add_Click({ Save-ResultsCsv $script:T1Results })

    # ── 탭 2: 비교 ──
    $script:T2 = @{}
    $script:T2Src = New-TargetList '원본 — 끌어다 놓으세요' 420
    $script:T2Dst = New-TargetList '대상 — 끌어다 놓으세요' 420
    $top2 = New-Ctl TableLayoutPanel @{ Dock = 'Top'; Height = (S 200); ColumnCount = 2; RowCount = 1 }
    [void]$top2.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle -ArgumentList ([Windows.Forms.SizeType]::Percent), 50))
    [void]$top2.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle -ArgumentList ([Windows.Forms.SizeType]::Percent), 50))
    [void]$top2.RowStyles.Add((New-Object Windows.Forms.RowStyle -ArgumentList ([Windows.Forms.SizeType]::Percent), 100))
    $top2.Controls.Add($script:T2Src.Group, 0, 0)
    $top2.Controls.Add($script:T2Dst.Group, 1, 0)

    $script:T2Opt = New-OptionFlow
    $modeFlow2 = New-Flow
    $chkContent = New-Ctl CheckBox @{ Text = '내용 기준 (이름 무시)'; AutoSize = $true; Margin = (Pad 0 4 24 0) }
    $chkMulti = New-Ctl CheckBox @{ Text = '여러 대상과 비교'; AutoSize = $true; Margin = (Pad 0 4 10 0) }
    $lblMode = New-Lbl ''
    $lblMode.ForeColor = $script:Gray
    $lblMode.Margin = (Pad 0 6 0 0)
    $modeFlow2.Controls.AddRange(@($chkContent, $chkMulti, $lblMode))
    $script:Tip = New-Object Windows.Forms.ToolTip
    $script:Tip.SetToolTip($chkContent, '파일 이름은 무시하고 해시(내용)가 같은 파일끼리 짝을 지어요.')
    $script:Tip.SetToolTip($chkMulti, '대상 목록의 폴더는 각각, 파일은 같은 상위 폴더끼리 묶어서 비교군을 만들어요.')
    $run2 = New-RunFlow '▶ 비교'

    $grp2 = New-Ctl GroupBox @{ Text = '비교 결과'; Dock = 'Fill'; Padding = (Pad 6 4 6 4) }
    $split = New-Ctl SplitContainer @{ Dock = 'Fill'; Orientation = 'Horizontal' }
    $lvSum = New-List @('비교군 (대상)', 420, '결과', 60, '일치', 60, '내용 다름', 70, '원본에만', 70, '대상에만', 70, '읽기 오류', 70)
    $split.Panel1.Controls.Add($lvSum)
    $lblDet = New-Ctl Label @{ Text = '상세'; Dock = 'Top'; Height = (S 22); TextAlign = 'BottomLeft' }
    $lvDet = New-VirtualList @('상태', 80, '원본 항목', 220, '대상 항목', 220, '원본 해시', 'H', '대상 해시', 'H') 0
    $f2 = New-Flow 'Bottom'
    $b2Csv = New-Btn '결과 CSV 저장' 120
    $b2Copy = New-Btn '선택 행 복사' 100
    $f2.Controls.AddRange(@($b2Csv, $b2Copy))
    $split.Panel2.Controls.Add($lblDet)
    $split.Panel2.Controls.Add($f2)
    $split.Panel2.Controls.Add($lvDet)
    $lvDet.BringToFront()
    $grp2.Controls.Add($split)

    $tab2.Controls.Add($run2.Flow)
    $tab2.Controls.Add($modeFlow2)
    $tab2.Controls.Add($script:T2Opt.Flow)
    $tab2.Controls.Add($top2)
    $tab2.Controls.Add($grp2)
    $grp2.BringToFront()

    $script:T2.Summary = $lvSum; $script:T2.Detail = $lvDet; $script:T2.DetailLabel = $lblDet; $script:T2.Split = $split
    $script:T2.ChkContent = $chkContent; $script:T2.ChkMulti = $chkMulti; $script:T2.ModeLabel = $lblMode
    $script:T2Rows = [System.Collections.Generic.List[object]]::new()

    $updateMode2 = {
        $t = if ($script:T2.ChkMulti.Checked) { '대상 목록을 폴더별 비교군으로 나눠서 각각 원본과 비교해요.' } else { '대상 목록 전체를 한 묶음으로 원본과 비교해요.' }
        if ($script:T2.ChkContent.Checked) { $t += ' (이름 무시, 내용으로 짝 맞춤)' } else { $t += ' (같은 이름끼리 짝 맞춤)' }
        $script:T2.ModeLabel.Text = $t
    }
    $chkContent.Add_CheckedChanged($updateMode2)
    $chkMulti.Add_CheckedChanged($updateMode2)
    & $updateMode2

    $run2.Button.Add_Click({
            $src = Get-TargetJobs $script:T2Src $script:T2Opt
            $dst = Get-TargetJobs $script:T2Dst $script:T2Opt
            if ($src.Count -eq 0 -or $dst.Count -eq 0) { Show-Warn '원본과 대상에 각각 파일이나 폴더를 1개 이상 추가해 주세요.'; return }
            $script:T2.SrcCount = $src.Count
            $script:T2.ByContent = $script:T2.ChkContent.Checked
            $script:T2.Multi = $script:T2.ChkMulti.Checked
            $script:T2.Summary.Items.Clear()
            Set-VirtualRows $script:T2.Detail $null
            Start-HashJob (@($src) + @($dst)) 'Complete-T2'
        })
    $lvSum.Add_SelectedIndexChanged({ Show-T2Detail })
    $b2Csv.Add_Click({
            if ($script:T2Rows.Count -eq 0) { Show-Info '저장할 결과가 없어요.'; return }
            $out = Select-SavePath 'CSV (엑셀 보기용)|*.csv' ('compare_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            if ($out) { Export-Rows $script:T2Rows $out; Set-Status "CSV 저장 완료: $out" }
        })
    $b2Copy.Add_Click({
            $lv = $script:T2.Detail
            $lines = foreach ($i in $lv.SelectedIndices) { ($lv.Tag.Rows[$i]) -join "`t" }
            if (@($lines).Count -gt 0) { Set-ClipText (@($lines) -join "`r`n") }
        })

    # ── 탭 3: 검증 ──
    $script:T3 = @{}
    $T3 = $script:T3

    $modeFlow = New-Flow
    $rbJson = New-Ctl RadioButton @{ Text = '저장된 기록(JSON)과 비교'; AutoSize = $true; Checked = $true; Margin = (Pad 0 4 24 0) }
    $rbDirect = New-Ctl RadioButton @{ Text = '해시 값 직접 입력'; AutoSize = $true; Margin = (Pad 0 4 0 0) }
    $modeFlow.Controls.AddRange(@($rbJson, $rbDirect))

    $grpJ = New-Ctl GroupBox @{ Text = '저장된 기록과 비교'; Dock = 'Top'; Height = (S 124); Padding = (Pad 8 6 8 4) }
    $gJ = New-Grid 3
    $txtJson = New-Ctl TextBox @{ Dock = 'Fill'; AllowDrop = $true; Margin = (Pad 3 5 3 5) }
    $bJson = New-Btn '찾기' 70
    $chkAlt = New-Ctl CheckBox @{ Text = '다른 위치와 비교'; AutoSize = $true; Anchor = 'Left'; Margin = (Pad 0 0 8 0) }
    $txtAlt = New-Ctl TextBox @{ Dock = 'Fill'; AllowDrop = $true; Enabled = $false; Margin = (Pad 3 5 3 5) }
    $fAlt = New-Ctl FlowLayoutPanel @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; Margin = (Pad 0 0 0 0) }
    $bAltFile = New-Btn '파일' 60; $bAltDir = New-Btn '폴더' 60
    $bAltFile.Enabled = $false; $bAltDir.Enabled = $false
    $fAlt.Controls.AddRange(@($bAltFile, $bAltDir))
    $lblJ = New-Ctl Label @{ AutoSize = $true; ForeColor = $script:Gray; Margin = (Pad 3 4 3 0); Text = '저장해 둔 JSON 기록을 선택하거나 끌어다 놓으세요.' }
    $gJ.Controls.Add((New-GridLabel '기록 파일'), 0, 0); $gJ.Controls.Add($txtJson, 1, 0); $gJ.Controls.Add($bJson, 2, 0)
    $gJ.Controls.Add($chkAlt, 0, 1); $gJ.Controls.Add($txtAlt, 1, 1); $gJ.Controls.Add($fAlt, 2, 1)
    $gJ.Controls.Add($lblJ, 0, 2); $gJ.SetColumnSpan($lblJ, 3)
    $grpJ.Controls.Add($gJ)

    $grpD = New-Ctl GroupBox @{ Text = '해시 값 직접 입력'; Dock = 'Top'; Height = (S 124); Padding = (Pad 8 6 8 4) }
    $gD = New-Grid 3
    $txtTarget = New-Ctl TextBox @{ Dock = 'Fill'; AllowDrop = $true; Margin = (Pad 3 5 3 5) }
    $fD = New-Ctl FlowLayoutPanel @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; Margin = (Pad 0 0 0 0) }
    $bDFile = New-Btn '파일' 60; $bDDir = New-Btn '폴더' 60
    $fD.Controls.AddRange(@($bDFile, $bDDir))
    $txtHash = New-Ctl TextBox @{ Dock = 'Fill'; Font = $script:MonoFont; Margin = (Pad 3 5 3 5) }
    $lblH = New-Ctl Label @{ AutoSize = $true; ForeColor = $script:Gray; Margin = (Pad 3 4 3 0) }
    $gD.Controls.Add((New-GridLabel '대상'), 0, 0); $gD.Controls.Add($txtTarget, 1, 0); $gD.Controls.Add($fD, 2, 0)
    $gD.Controls.Add((New-GridLabel '기대 해시'), 0, 1); $gD.Controls.Add($txtHash, 1, 1)
    $gD.Controls.Add($lblH, 0, 2); $gD.SetColumnSpan($lblH, 3)
    $grpD.Controls.Add($gD)

    $runFlow3 = New-Flow
    $bVerify = New-Btn '▶ 검증' 120
    $bVerify.Font = $script:BoldFont
    $runFlow3.Controls.Add($bVerify)

    $grp3 = New-Ctl GroupBox @{ Text = '검증 결과'; Dock = 'Fill'; Padding = (Pad 6 4 6 4) }
    $lblV = New-Ctl Label @{ Dock = 'Top'; Height = (S 40); Font = $script:BigFont; TextAlign = 'MiddleCenter' }
    $txtInfo = New-Ctl TextBox @{ Dock = 'Top'; Height = (S 84); Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Font = $script:MonoFont; WordWrap = $false }
    $txtInfo.BackColor = [Drawing.Color]::White
    $lvV = New-VirtualList @('대상', 200, '상태', 70, '상대 경로', 260, '저장된 해시', 'H', '현재 해시', 'H') 1
    $f3 = New-Flow 'Bottom'
    $b3Csv = New-Btn '차이 목록 CSV 저장' 140
    $b3Copy = New-Btn '결과 복사' 90
    $f3.Controls.AddRange(@($b3Csv, $b3Copy))
    $grp3.Controls.Add($txtInfo)
    $grp3.Controls.Add($lblV)
    $grp3.Controls.Add($f3)
    $grp3.Controls.Add($lvV)
    $lvV.BringToFront()

    $tab3.Controls.Add($runFlow3)
    $tab3.Controls.Add($grpD)
    $tab3.Controls.Add($grpJ)
    $tab3.Controls.Add($modeFlow)
    $tab3.Controls.Add($grp3)
    $grp3.BringToFront()

    $T3.RbJson = $rbJson; $T3.RbDirect = $rbDirect
    $T3.JsonBox = $txtJson; $T3.AltCheck = $chkAlt; $T3.AltBox = $txtAlt; $T3.AltFile = $bAltFile; $T3.AltDir = $bAltDir; $T3.JInfo = $lblJ
    $T3.TargetBox = $txtTarget; $T3.HashBox = $txtHash; $T3.HInfo = $lblH
    $T3.Verdict = $lblV; $T3.Info = $txtInfo; $T3.Diff = $lvV
    $T3.Manifest = $null
    $script:T3Rows = [System.Collections.Generic.List[object]]::new()

    foreach ($tb in @($txtJson, $txtAlt, $txtTarget)) {
        $tb.Add_DragEnter($script:DropEnter)
        $tb.Add_DragDrop($script:TextDrop)
    }
    $txtJson.Add_TextChanged({ $script:T3.RbJson.Checked = $true; Load-Manifest $script:T3.JsonBox.Text })
    $txtAlt.Add_TextChanged({ $script:T3.RbJson.Checked = $true })
    $txtTarget.Add_TextChanged({ $script:T3.RbDirect.Checked = $true })
    $txtHash.Add_TextChanged({ $script:T3.RbDirect.Checked = $true; Update-HashInfo })
    $chkAlt.Add_CheckedChanged({
            $on = $script:T3.AltCheck.Checked
            $script:T3.AltBox.Enabled = $on; $script:T3.AltFile.Enabled = $on; $script:T3.AltDir.Enabled = $on
        })
    $bJson.Add_Click({ $f = Select-Files $false 'JSON 기록|*.json|모든 파일|*.*'; if ($f.Count) { $script:T3.JsonBox.Text = $f[0] } })
    $bAltFile.Add_Click({ $f = Select-Files $false; if ($f.Count) { $script:T3.AltBox.Text = $f[0] } })
    $bAltDir.Add_Click({ $d = Select-Folder '비교할 다른 위치(폴더)를 선택하세요'; if ($d) { $script:T3.AltBox.Text = $d } })
    $bDFile.Add_Click({ $f = Select-Files $false; if ($f.Count) { $script:T3.TargetBox.Text = $f[0] } })
    $bDDir.Add_Click({ $d = Select-Folder; if ($d) { $script:T3.TargetBox.Text = $d } })
    $bVerify.Add_Click({ Start-Verify })
    $b3Csv.Add_Click({
            if ($script:T3Rows.Count -eq 0) { Show-Info '저장할 차이가 없어요.'; return }
            $out = Select-SavePath 'CSV (엑셀 보기용)|*.csv' ('verify_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            if ($out) { Export-Rows $script:T3Rows $out; Set-Status "CSV 저장 완료: $out" }
        })
    $b3Copy.Add_Click({
            $t = $script:T3.Verdict.Text
            if ($script:T3.Info.Text) { $t = "$t`r`n$($script:T3.Info.Text)" }
            Set-ClipText $t.Trim()
        })
    Update-HashInfo

    # ── 조립 ──
    $script:Form.Controls.Add($bottom)
    $script:Form.Controls.Add($script:Tabs)
    $script:Tabs.BringToFront()

    $script:Timer = New-Object Windows.Forms.Timer
    $script:Timer.Interval = 200
    $script:Timer.Add_Tick({ Update-JobProgress })

    $script:Form.Add_Shown({
            $init = @($InitialPaths | Where-Object { $_ })
            if ($init.Count -eq 1 -and $init[0] -like '*.json') {
                $script:Tabs.SelectedIndex = 2
                $script:T3.JsonBox.Text = $init[0].Trim('"')
            }
            elseif ($init.Count -eq 2) {
                $script:Tabs.SelectedIndex = 1
                Add-Targets $script:T2Src @($init[0])
                Add-Targets $script:T2Dst @($init[1])
            }
            elseif ($init.Count -ge 1) {
                Add-Targets $script:T1 $init
            }
        })
    $script:SplitDone = $false
    $script:Tabs.Add_SelectedIndexChanged({ if ($script:Tabs.SelectedIndex -eq 1) { Update-SplitOnce } })
    $script:Form.Add_FormClosing({
            if ($script:Job) {
                $script:Sync.Cancel = $true
                try { $script:Job.PS.Stop() } catch {}
            }
        })

    [void]$script:Form.ShowDialog()
}
catch {
    [void][Windows.Forms.MessageBox]::Show("프로그램을 시작하지 못했어요.`n`n$($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)", '해시 도구', 'OK', 'Error')
}
