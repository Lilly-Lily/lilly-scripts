# ============================================================
#  명조(Wuthering Waves) Engine.ini 관리 도구
#  실행: 같은 폴더의 WuWaIniManager.bat 더블클릭
#  설정: setting.json / 백업: Backup 폴더 (스크립트와 같은 위치)
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

trap {
    [void][System.Windows.Forms.MessageBox]::Show("예기치 않은 오류가 발생했습니다.`n`n$($_.Exception.Message)", '명조 Engine.ini 관리 도구', 'OK', 'Error')
    break
}

try {
    Add-Type -Namespace Native -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop
    [void][Native.Dpi]::SetProcessDPIAware()
} catch { }

[System.Windows.Forms.Application]::EnableVisualStyles()

# DPI 배율 (125%, 150% 등) 만큼 컨트롤 위치·크기를 직접 키움
$script:Scale = 1.0
try {
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = $g.DpiX / 96.0
    $g.Dispose()
} catch { }
function S([double]$v) { return [int][Math]::Round($v * $script:Scale) }

# 탐색기 방식 폴더 선택 창 (Windows 기본 IFileOpenDialog + 폴더 선택 모드)
$script:HasExplorerPicker = $false
try {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WuWa {
    public static class FolderPicker {
        [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
        private class FileOpenDialogRCW { }

        [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileDialog {
            [PreserveSig] int Show(IntPtr hwnd);
            void SetFileTypes(uint c, IntPtr f);
            void SetFileTypeIndex(uint i);
            void GetFileTypeIndex(out uint i);
            void Advise(IntPtr p, out uint c);
            void Unadvise(uint c);
            void SetOptions(uint fos);
            void GetOptions(out uint fos);
            void SetDefaultFolder(IShellItem si);
            void SetFolder(IShellItem si);
            void GetFolder(out IShellItem si);
            void GetCurrentSelection(out IShellItem si);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string n);
            void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string n);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string t);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string t);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string t);
            void GetResult(out IShellItem si);
            void AddPlace(IShellItem si, int fdap);
            void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string e);
            void Close(int hr);
            void SetClientGuid(ref Guid g);
            void ClearClientData();
            void SetFilter(IntPtr f);
        }

        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem {
            void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
            void GetParent(out IShellItem ppsi);
            void GetDisplayName(uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name);
            void GetAttributes(uint mask, out uint attribs);
            void Compare(IShellItem psi, uint hint, out int order);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid, out IShellItem item);

        public static string Show(IntPtr owner, string title, string initial) {
            IFileDialog d = (IFileDialog)new FileOpenDialogRCW();
            uint o;
            d.GetOptions(out o);
            d.SetOptions(o | 0x20u | 0x40u);          // FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM
            if (!string.IsNullOrEmpty(title)) d.SetTitle(title);
            d.SetOkButtonLabel("폴더 선택");
            if (!string.IsNullOrEmpty(initial)) {
                try {
                    Guid g = typeof(IShellItem).GUID;
                    IShellItem si;
                    SHCreateItemFromParsingName(initial, IntPtr.Zero, ref g, out si);
                    d.SetFolder(si);
                } catch { }
            }
            if (d.Show(owner) != 0) return null;     // 취소
            IShellItem r;
            d.GetResult(out r);
            string p;
            r.GetDisplayName(0x80058000u, out p);   // SIGDN_FILESYSPATH
            return p;
        }
    }
}
'@
    $script:HasExplorerPicker = $true
} catch { }

# ---------- 상수 ----------
$script:AppDir       = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:SettingsPath = [IO.Path]::Combine($script:AppDir, 'setting.json')
$script:BackupDir    = [IO.Path]::Combine($script:AppDir, 'Backup')
$script:Clients      = @('Kuro', 'Google', 'Steam', 'Epic')
$script:IniRel       = 'Client\Saved\Config\WindowsNoEditor'
$script:ExeName      = 'Wuthering Waves.exe'
$script:GitHubUrl    = 'https://github.com/AlteriaX/WuWa-Configs'
$script:GameProcs    = @('Client-Win64-Shipping', 'Wuthering Waves')
$script:Title        = '명조 Engine.ini 관리 도구'
$script:FontMain     = New-Object System.Drawing.Font('Malgun Gothic', 9)
$script:FontMono     = New-Object System.Drawing.Font('Consolas', 9)
$script:FontDot      = New-Object System.Drawing.Font('Malgun Gothic', 14)
$script:UI           = @{ PathBox = @{}; Status = @{}; Target = @{} }
$script:R            = $null

# ============================================================
#  공통 함수
# ============================================================
function Show-Msg([string]$text, [string]$icon = 'Information', [string]$buttons = 'OK') {
    return [System.Windows.Forms.MessageBox]::Show($text, $script:Title, $buttons, $icon)
}

function Write-Log([string]$msg) {
    $script:UI.Log.AppendText(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg) + "`r`n")
}

function Test-FileSafe([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    try { return (Test-Path -LiteralPath $p -PathType Leaf) } catch { return $false }
}

function Test-DirSafe([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $false }
    try { return (Test-Path -LiteralPath $p -PathType Container) } catch { return $false }
}

function Get-BasePath([string]$c) {
    return $script:UI.PathBox[$c].Text.Trim().Trim('"')
}

function Get-CustomPath {
    return $script:UI.CustomBox.Text.Trim().Trim('"')
}

function Get-IniDir([string]$c) {
    $b = Get-BasePath $c
    if ([string]::IsNullOrWhiteSpace($b)) { return $null }
    try { return [IO.Path]::Combine($b, $script:IniRel) } catch { return $null }
}

function Get-IniFile([string]$c) {
    $d = Get-IniDir $c
    if (-not $d) { return $null }
    return [IO.Path]::Combine($d, 'Engine.ini')
}

# 지정 폴더에 Wuthering Waves.exe가 있는지
function Test-Client([string]$c) {
    $b = Get-BasePath $c
    if ([string]::IsNullOrWhiteSpace($b)) { return $false }
    try { return (Test-FileSafe ([IO.Path]::Combine($b, $script:ExeName))) } catch { return $false }
}

function Get-CheckedTargets($map) {
    foreach ($c in $script:Clients) {
        if ($map[$c].Enabled -and $map[$c].Checked) { $c }
    }
}

# ---------- 설정 ----------
function Read-Settings {
    $s = @{ Paths = @{}; CustomIni = '' }
    foreach ($c in $script:Clients) { $s.Paths[$c] = '' }
    if (Test-FileSafe $script:SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($c in $script:Clients) {
                if ($j.Paths -and $j.Paths.$c) { $s.Paths[$c] = [string]$j.Paths.$c }
            }
            if ($j.CustomIni) { $s.CustomIni = [string]$j.CustomIni }
        } catch { }
    }
    return $s
}

function Save-Settings {
    $paths = [ordered]@{}
    foreach ($c in $script:Clients) { $paths[$c] = Get-BasePath $c }
    $obj = [ordered]@{ Paths = $paths; CustomIni = (Get-CustomPath) }
    try {
        $obj | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch {
        Write-Log "설정 저장 실패: $($_.Exception.Message)"
    }
}

# ---------- 상태 표시 ----------
function Set-Dot($lbl, [string]$color, [string]$tip) {
    $lbl.ForeColor = [System.Drawing.Color]::FromName($color)
    $script:UI.Tip.SetToolTip($lbl, $tip)
}

function Update-Status {
    foreach ($c in $script:Clients) {
        $b  = Get-BasePath $c
        $cb = $script:UI.Target[$c]
        $ok = $false
        if ([string]::IsNullOrWhiteSpace($b)) {
            Set-Dot $script:UI.Status[$c] 'Gray' '경로 미설정'
        } elseif (-not (Test-Client $c)) {
            Set-Dot $script:UI.Status[$c] 'Red' "이 폴더에 $($script:ExeName)이(가) 없습니다"
        } elseif (Test-FileSafe (Get-IniFile $c)) {
            Set-Dot $script:UI.Status[$c] 'ForestGreen' '정상 (Engine.ini 있음)'
            $ok = $true
        } else {
            Set-Dot $script:UI.Status[$c] 'DarkOrange' '경로 정상 (Engine.ini 없음)'
            $ok = $true
        }
        $cb.Enabled = $ok
        if (-not $ok) { $cb.Checked = $false }
    }

    $cp = Get-CustomPath
    if ([string]::IsNullOrWhiteSpace($cp)) {
        Set-Dot $script:UI.CustomStatus 'Gray' '커스텀 ini 미설정'
    } elseif (Test-FileSafe $cp) {
        Set-Dot $script:UI.CustomStatus 'ForestGreen' '파일 확인됨'
    } else {
        Set-Dot $script:UI.CustomStatus 'Red' '파일을 찾을 수 없습니다'
    }
}

# ---------- 안전장치 ----------
function Confirm-GameClosed {
    $p = Get-Process -Name $script:GameProcs -ErrorAction SilentlyContinue
    if ($p) {
        $r = Show-Msg "명조가 실행 중입니다.`n실행 중에는 변경 사항이 반영되지 않거나 게임이 파일을 덮어쓸 수 있어, 종료 후 진행하는 것을 권장합니다.`n`n그래도 계속할까요?" 'Warning' 'YesNo'
        return ($r -eq 'Yes')
    }
    return $true
}

# 반환: 'Yes' / 'No' / 'Cancel'
function Request-Backup([string]$action, [string[]]$targets) {
    $msg = "대상: $($targets -join ', ')`n`n$action 전에 현재 Engine.ini를 백업할까요?`n`n예: 백업 후 $action`n아니요: 백업 없이 $action`n취소: 작업 취소"
    $r = Show-Msg $msg 'Question' 'YesNoCancel'
    return $r.ToString()
}

# ---------- 파일 작업 ----------
function New-Backup([string]$c, [string]$src) {
    [void][IO.Directory]::CreateDirectory($script:BackupDir)
    $ts   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dest = [IO.Path]::Combine($script:BackupDir, ('Engine_{0}_{1}.ini' -f $c, $ts))
    $n = 2
    while (Test-Path -LiteralPath $dest) {
        $dest = [IO.Path]::Combine($script:BackupDir, ('Engine_{0}_{1}_{2}.ini' -f $c, $ts, $n))
        $n++
    }
    [IO.File]::Copy($src, $dest, $false)
    return $dest
}

function Remove-ToRecycle([string]$path) {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
        $path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
}

# 이식/복원 공통: $src 파일을 대상 클라이언트들의 Engine.ini로 복사
function Install-Ini([string[]]$targets, [string]$src, [string]$label, [string]$detail) {
    $bk = Request-Backup $label $targets
    if ($bk -eq 'Cancel') { Write-Log "$label 취소"; return $false }

    foreach ($c in $targets) {
        if (-not (Test-Client $c)) { Write-Log "[$c] 경로 오류, 건너뜀"; continue }
        $dir = Get-IniDir $c
        $ini = Get-IniFile $c
        try {
            if ([IO.Path]::GetFullPath($src) -ieq [IO.Path]::GetFullPath($ini)) {
                Write-Log "[$c] 원본과 대상이 같은 파일이라 건너뜀"
                continue
            }
            if ($bk -eq 'Yes' -and (Test-FileSafe $ini)) {
                $b = New-Backup $c $ini
                Write-Log "[$c] 기존 파일 백업: $([IO.Path]::GetFileName($b))"
            }
            if (-not (Test-DirSafe $dir)) {
                [void][IO.Directory]::CreateDirectory($dir)
                Write-Log "[$c] Engine.ini 폴더 생성"
            }
            [IO.File]::Copy($src, $ini, $true)
            Write-Log "[$c] $label 완료 ($detail)"
        } catch {
            Write-Log "[$c] $label 실패: $($_.Exception.Message)"
        }
    }
    return $true
}

# ============================================================
#  메인 창 동작
# ============================================================
# 탐색기 방식 폴더 선택 (실패 시 기존 트리 방식으로 대체). 취소하면 $null 반환
function Select-Folder([string]$title, [string]$initial) {
    if ($script:HasExplorerPicker) {
        try {
            $init = ''
            if (Test-DirSafe $initial) { $init = $initial }
            return [WuWa.FolderPicker]::Show($script:Form.Handle, $title, $init)
        } catch { }
    }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $title
    if (Test-DirSafe $initial) { $dlg.SelectedPath = $initial }
    if ($dlg.ShowDialog($script:Form) -eq 'OK') { return $dlg.SelectedPath }
    return $null
}

function Select-ClientFolder([string]$c) {
    $sel = Select-Folder "[$c] '$($script:ExeName)'이(가) 있는 폴더를 선택하세요" (Get-BasePath $c)
    if ($sel) {
        $script:UI.PathBox[$c].Text = $sel
        Save-Settings
        if (Test-Client $c) {
            Write-Log "[$c] 경로 설정: $sel"
        } else {
            [void](Show-Msg "선택한 폴더에 '$($script:ExeName)'이(가) 없습니다.`n기준 폴더가 맞는지 확인하세요." 'Warning')
        }
    }
}

function Select-CustomIni {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = '커스텀 Engine.ini 선택'
    $dlg.Filter = 'INI 파일 (*.ini)|*.ini|모든 파일 (*.*)|*.*'
    $cur = Get-CustomPath
    if (Test-FileSafe $cur) { $dlg.InitialDirectory = [IO.Path]::GetDirectoryName($cur) }
    if ($dlg.ShowDialog($script:Form) -eq 'OK') {
        $script:UI.CustomBox.Text = $dlg.FileName
        Save-Settings
        Write-Log "커스텀 ini 설정: $($dlg.FileName)"
    }
}

function Open-IniFolder([string]$c) {
    if (-not (Test-Client $c)) {
        [void](Show-Msg "[$c] 경로가 설정되지 않았거나 '$($script:ExeName)'이(가) 없습니다." 'Warning')
        return
    }
    $d = Get-IniDir $c
    if (Test-DirSafe $d) {
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $d)
    } else {
        [void](Show-Msg "Engine.ini 폴더가 아직 없습니다.`n게임을 한 번 실행하면 생성되며, 이식/복원 시에는 자동으로 만들어집니다.`n`n$d")
    }
}

function Open-BackupFolder {
    [void][IO.Directory]::CreateDirectory($script:BackupDir)
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:BackupDir)
}

function Invoke-Backup {
    $t = @(Get-CheckedTargets $script:UI.Target)
    if ($t.Count -eq 0) { [void](Show-Msg '작업할 클라이언트를 선택하세요.' 'Warning'); return }
    foreach ($c in $t) {
        $ini = Get-IniFile $c
        if (-not (Test-FileSafe $ini)) { Write-Log "[$c] Engine.ini 없음, 건너뜀"; continue }
        try {
            $b = New-Backup $c $ini
            Write-Log "[$c] 백업 완료: $([IO.Path]::GetFileName($b))"
        } catch {
            Write-Log "[$c] 백업 실패: $($_.Exception.Message)"
        }
    }
}

function Invoke-Delete {
    $t = @(Get-CheckedTargets $script:UI.Target)
    if ($t.Count -eq 0) { [void](Show-Msg '작업할 클라이언트를 선택하세요.' 'Warning'); return }
    if (-not (Confirm-GameClosed)) { return }
    $bk = Request-Backup '삭제' $t
    if ($bk -eq 'Cancel') { Write-Log '삭제 취소'; return }

    foreach ($c in $t) {
        $ini = Get-IniFile $c
        if (-not (Test-FileSafe $ini)) { Write-Log "[$c] Engine.ini 없음, 건너뜀"; continue }
        try {
            if ($bk -eq 'Yes') {
                $b = New-Backup $c $ini
                Write-Log "[$c] 백업: $([IO.Path]::GetFileName($b))"
            }
            Remove-ToRecycle $ini
            Write-Log "[$c] Engine.ini 삭제 완료 (휴지통 이동)"
        } catch {
            Write-Log "[$c] 삭제 실패: $($_.Exception.Message)"
        }
    }
    Update-Status
}

function Invoke-Transplant {
    $src = Get-CustomPath
    if (-not (Test-FileSafe $src)) { [void](Show-Msg '커스텀 Engine.ini 파일을 먼저 지정하세요.' 'Warning'); return }
    $t = @(Get-CheckedTargets $script:UI.Target)
    if ($t.Count -eq 0) { [void](Show-Msg '작업할 클라이언트를 선택하세요.' 'Warning'); return }
    if (-not (Confirm-GameClosed)) { return }
    [void](Install-Ini $t $src '이식' ([IO.Path]::GetFileName($src)))
    Update-Status
}

# ============================================================
#  복원 창
# ============================================================
function Get-Backups {
    if (-not (Test-DirSafe $script:BackupDir)) { return @() }
    $list = foreach ($fi in (Get-ChildItem -LiteralPath $script:BackupDir -File -Filter 'Engine_*.ini')) {
        if ($fi.Name -cmatch '^Engine_(Kuro|Google|Steam|Epic)_(\d{8}_\d{6})(?:_\d+)?\.ini$') {
            $client = $Matches[1]
            try {
                $dt = [datetime]::ParseExact($Matches[2], 'yyyyMMdd_HHmmss', [Globalization.CultureInfo]::InvariantCulture)
                [pscustomobject]@{ Client = $client; Time = $dt; Name = $fi.Name; Path = $fi.FullName }
            } catch { }
        }
    }
    return @($list | Sort-Object Time, Name -Descending)
}

function Update-BackupList {
    $R = $script:R
    $flt = [string]$R.Filter.SelectedItem
    $R.List.BeginUpdate()
    $R.List.Items.Clear()
    foreach ($b in (Get-Backups)) {
        if ($flt -ne '전체' -and $b.Client -ne $flt) { continue }
        $it = New-Object System.Windows.Forms.ListViewItem([string]$b.Client)
        [void]$it.SubItems.Add($b.Time.ToString('yyyy-MM-dd HH:mm:ss'))
        [void]$it.SubItems.Add($b.Name)
        $it.Tag = $b
        [void]$R.List.Items.Add($it)
    }
    $R.List.EndUpdate()
    $R.Count.Text = "백업 $($R.List.Items.Count)개"
    foreach ($c in $script:Clients) { $R.Target[$c].Enabled = (Test-Client $c) }
    Update-RestorePreview
}

function Update-RestorePreview {
    $R = $script:R
    $sel = $R.List.SelectedItems
    if ($sel.Count -eq 1) {
        $b = $sel[0].Tag
        try {
            $R.Preview.Text = ([IO.File]::ReadAllText($b.Path)) -replace "(?<!`r)`n", "`r`n"
        } catch {
            $R.Preview.Text = "(읽기 실패) $($_.Exception.Message)"
        }
        # 백업의 원래 클라이언트를 자동 체크 (다른 클라이언트는 추가 선택 시 교차 복원)
        foreach ($c in $script:Clients) {
            $cb = $R.Target[$c]
            $cb.Checked = ($cb.Enabled -and $c -eq $b.Client)
        }
    } elseif ($sel.Count -gt 1) {
        $R.Preview.Text = "($($sel.Count)개 선택됨)`r`n복원은 1개만 선택해야 합니다. 삭제는 여러 개 가능합니다."
    } else {
        $R.Preview.Text = ''
    }
}

function Invoke-Restore {
    $R = $script:R
    if ($R.List.SelectedItems.Count -ne 1) { [void](Show-Msg '복원할 백업을 1개 선택하세요.' 'Warning'); return }
    $b = $R.List.SelectedItems[0].Tag
    if (-not (Test-FileSafe $b.Path)) { [void](Show-Msg '선택한 백업 파일을 찾을 수 없습니다.' 'Warning'); Update-BackupList; return }
    $t = @(Get-CheckedTargets $R.Target)
    if ($t.Count -eq 0) { [void](Show-Msg '복원 대상 클라이언트를 선택하세요.' 'Warning'); return }
    if (-not (Confirm-GameClosed)) { return }

    if (-not (Install-Ini $t $b.Path '복원' $b.Name)) { return }
    Update-Status
    Update-BackupList
    [void](Show-Msg "복원 작업이 끝났습니다.`n결과는 메인 창 로그에서 확인할 수 있습니다.")
}

function Remove-SelectedBackups {
    $R = $script:R
    $items = @($R.List.SelectedItems | ForEach-Object { $_.Tag })
    if ($items.Count -eq 0) { [void](Show-Msg '삭제할 백업을 선택하세요.' 'Warning'); return }
    $r = Show-Msg "선택한 백업 $($items.Count)개를 휴지통으로 옮길까요?" 'Question' 'YesNo'
    if ($r -ne 'Yes') { return }
    foreach ($b in $items) {
        try {
            Remove-ToRecycle $b.Path
            Write-Log "백업 삭제: $($b.Name)"
        } catch {
            Write-Log "백업 삭제 실패 ($($b.Name)): $($_.Exception.Message)"
        }
    }
    Update-BackupList
}

function New-Ctl([string]$type, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text = '') {
    $o = New-Object ("System.Windows.Forms.$type")
    $o.Location = New-Object System.Drawing.Point((S $x), (S $y))
    $o.Size     = New-Object System.Drawing.Size((S $w), (S $h))
    if ($text) { $o.Text = $text }
    return $o
}

function New-Separator([int]$y, [int]$w) {
    $s = New-Ctl Label 12 $y $w 2
    $s.BorderStyle = 'Fixed3D'
    return $s
}

function Show-RestoreDialog {
    $R = @{ Target = @{} }
    $script:R = $R

    $f = New-Object System.Windows.Forms.Form
    $f.Text = '백업 복원'
    $f.AutoScaleMode = 'None'
    $f.Font = $script:FontMain
    $f.ClientSize = New-Object System.Drawing.Size((S 820), (S 500))
    $f.FormBorderStyle = 'FixedSingle'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.StartPosition = 'CenterParent'

    # 상단: 필터 / 새로고침 / 폴더 열기
    $lf = New-Ctl Label 12 12 40 26 '필터'
    $lf.TextAlign = 'MiddleLeft'
    $cmb = New-Ctl ComboBox 55 13 110 24
    $cmb.DropDownStyle = 'DropDownList'
    [void]$cmb.Items.Add('전체')
    foreach ($c in $script:Clients) { [void]$cmb.Items.Add($c) }
    $cmb.SelectedIndex = 0
    $R.Filter = $cmb

    $btnRef  = New-Ctl Button 172 11 80 28 '새로고침'
    $btnOpen = New-Ctl Button 258 11 120 28 '백업 폴더 열기'
    $cnt = New-Ctl Label 386 12 120 26 ''
    $cnt.TextAlign = 'MiddleLeft'
    $cnt.ForeColor = [System.Drawing.Color]::DimGray
    $R.Count = $cnt

    $lp = New-Ctl Label 452 12 200 26 '미리보기'
    $lp.TextAlign = 'MiddleLeft'

    # 목록
    $lv = New-Ctl ListView 12 46 430 330
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $true
    $lv.HideSelection = $false
    $lv.GridLines = $true
    [void]$lv.Columns.Add('클라이언트', (S 80))
    [void]$lv.Columns.Add('백업 시각', (S 140))
    [void]$lv.Columns.Add('파일명', (S 205))
    $R.List = $lv

    # 미리보기
    $pv = New-Ctl TextBox 452 46 356 330
    $pv.Multiline = $true
    $pv.ReadOnly = $true
    $pv.ScrollBars = 'Both'
    $pv.WordWrap = $false
    $pv.Font = $script:FontMono
    $pv.BackColor = [System.Drawing.Color]::White
    $R.Preview = $pv

    # 복원 대상
    $lt = New-Ctl Label 12 386 75 26 '복원 대상'
    $lt.TextAlign = 'MiddleLeft'
    $f.Controls.Add($lt)
    $x = 92
    foreach ($c in $script:Clients) {
        $cb = New-Ctl CheckBox $x 388 80 24 $c
        $R.Target[$c] = $cb
        $f.Controls.Add($cb)
        $x += 82
    }
    $hint = New-Ctl Label 12 416 796 22 '※ 백업을 선택하면 원래 클라이언트가 자동 체크됩니다. 다른 클라이언트를 추가로 체크하면 교차 복원됩니다.'
    $hint.ForeColor = [System.Drawing.Color]::DimGray

    # 하단 버튼
    $btnRestore = New-Ctl Button 12 452 110 34 '복원'
    $btnDel     = New-Ctl Button 128 452 140 34 '선택 백업 삭제'
    $btnClose   = New-Ctl Button 708 452 100 34 '닫기'

    $cmb.add_SelectedIndexChanged({ Update-BackupList })
    $btnRef.add_Click({ Update-BackupList })
    $btnOpen.add_Click({ Open-BackupFolder })
    $lv.add_SelectedIndexChanged({ Update-RestorePreview })
    $btnRestore.add_Click({ Invoke-Restore })
    $btnDel.add_Click({ Remove-SelectedBackups })
    $btnClose.add_Click({ $script:R.Form.Close() })
    $f.add_Shown({ Update-BackupList })

    $f.Controls.AddRange(@($lf, $cmb, $btnRef, $btnOpen, $cnt, $lp, $lv, $pv, $hint, $btnRestore, $btnDel, $btnClose))
    $R.Form = $f
    [void]$f.ShowDialog($script:Form)
    $f.Dispose()
    $script:R = $null
}

# ============================================================
#  메인 창 구성
# ============================================================
$settings = Read-Settings

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:Title
$form.AutoScaleMode = 'None'
$form.Font = $script:FontMain
$form.ClientSize = New-Object System.Drawing.Size((S 740), (S 560))
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$script:Form = $form
$script:UI.Tip = New-Object System.Windows.Forms.ToolTip

# 안내문
$notice = New-Ctl Label 12 8 716 42 ("※ 경로는 '$($script:ExeName)'이(가) 있는 폴더를 지정하세요.`n    Engine.ini 위치: [지정 폴더]\$($script:IniRel)")
$notice.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($notice)

# 클라이언트 경로 4개
$y = 56
foreach ($c in $script:Clients) {
    $lbl = New-Ctl Label 12 ($y + 2) 60 26 $c
    $lbl.TextAlign = 'MiddleLeft'

    $tb = New-Ctl TextBox 75 ($y + 3) 425 24
    $tb.Text = $settings.Paths[$c]
    $tb.Tag = $c

    $bb = New-Ctl Button 508 $y 62 30 '찾기'
    $bb.Tag = $c
    $ob = New-Ctl Button 576 $y 112 30 'ini 폴더 열기'
    $ob.Tag = $c

    $st = New-Ctl Label 694 $y 34 30 '●'
    $st.Font = $script:FontDot
    $st.TextAlign = 'MiddleCenter'

    $script:UI.PathBox[$c] = $tb
    $script:UI.Status[$c]  = $st
    $form.Controls.AddRange(@($lbl, $tb, $bb, $ob, $st))
    $y += 34
}

$form.Controls.Add((New-Separator 196 716))

# 커스텀 ini
$lc = New-Ctl Label 12 208 70 26 '커스텀 ini'
$lc.TextAlign = 'MiddleLeft'
$cbx = New-Ctl TextBox 85 209 415 24
$cbx.Text = $settings.CustomIni
$script:UI.CustomBox = $cbx
$btnCustom = New-Ctl Button 508 206 62 30 '찾기'
$btnGit    = New-Ctl Button 576 206 112 30 'GitHub 열기'
$cst = New-Ctl Label 694 206 34 30 '●'
$cst.Font = $script:FontDot
$cst.TextAlign = 'MiddleCenter'
$script:UI.CustomStatus = $cst
$form.Controls.AddRange(@($lc, $cbx, $btnCustom, $btnGit, $cst))

$form.Controls.Add((New-Separator 246 716))

# 작업 대상
$lt = New-Ctl Label 12 256 40 26 '대상'
$lt.TextAlign = 'MiddleLeft'
$form.Controls.Add($lt)
$x = 60
foreach ($c in $script:Clients) {
    $cb = New-Ctl CheckBox $x 258 80 24 $c
    $script:UI.Target[$c] = $cb
    $form.Controls.Add($cb)
    $x += 82
}

# 작업 버튼
$btnBackup  = New-Ctl Button 12  292 100 34 '백업'
$btnDelete  = New-Ctl Button 118 292 100 34 '삭제'
$btnInstall = New-Ctl Button 224 292 100 34 '이식'
$btnRestore = New-Ctl Button 330 292 100 34 '복원...'
$btnBkDir   = New-Ctl Button 588 292 140 34 '백업 폴더 열기'
$form.Controls.AddRange(@($btnBackup, $btnDelete, $btnInstall, $btnRestore, $btnBkDir))

# 로그
$log = New-Ctl TextBox 12 336 716 212
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.BackColor = [System.Drawing.Color]::White
$script:UI.Log = $log
$form.Controls.Add($log)

# ---------- 이벤트 연결 (모든 컨트롤 생성 후) ----------
foreach ($c in $script:Clients) {
    $script:UI.PathBox[$c].add_TextChanged({ Update-Status })
    $script:UI.PathBox[$c].add_Leave({ Save-Settings })
}
foreach ($ctl in $form.Controls) {
    if ($ctl -is [System.Windows.Forms.Button] -and $ctl.Tag) {
        if ($ctl.Text -eq '찾기') { $ctl.add_Click({ Select-ClientFolder ([string]$this.Tag) }) }
        else                      { $ctl.add_Click({ Open-IniFolder ([string]$this.Tag) }) }
    }
}
$cbx.add_TextChanged({ Update-Status })
$cbx.add_Leave({ Save-Settings })
$btnCustom.add_Click({ Select-CustomIni })
$btnGit.add_Click({ Start-Process $script:GitHubUrl })
$btnBackup.add_Click({ Invoke-Backup })
$btnDelete.add_Click({ Invoke-Delete })
$btnInstall.add_Click({ Invoke-Transplant })
$btnRestore.add_Click({ Show-RestoreDialog })
$btnBkDir.add_Click({ Open-BackupFolder })
$form.add_Activated({ Update-Status })
$form.add_FormClosing({ Save-Settings })

Update-Status
Write-Log "준비 완료 (설정: setting.json / 백업: Backup 폴더)"
[void]$form.ShowDialog()
$form.Dispose()
