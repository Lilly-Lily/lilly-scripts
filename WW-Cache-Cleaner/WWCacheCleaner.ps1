# =====================================================
#  명조 셰이더 캐시 정리 v1.3 (Wuthering Waves Shader Cache Cleaner)
#  - 명조 다중 클라이언트 PSO 캐시 + DirectX 셰이더 캐시(Windows/GPU 드라이버)
#  - (선택) 추가 정리 항목: OpenGL / Vulkan / CUDA / Steam 셰이더 캐시
#  - 설정은 같은 폴더의 settings.json 에 자동 저장
# =====================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$AppTitle   = '명조 셰이더 캐시 정리'
$AppVersion = '1.3'

# ---------- 관리자 권한 확인 / 자동 상승 ----------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ErrorAction Stop -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`""
        )
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            '관리자 권한이 필요합니다. UAC 창에서 [예]를 눌러 주세요.',
            $AppTitle, 'OK', 'Warning')
    }
    exit
}

# ---------- DPI / 비주얼 스타일 ----------
try {
    Add-Type -Namespace WWCC -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][WWCC.Native]::SetProcessDPIAware()
} catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()

$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$Scale = $g.DpiX / 96.0
$g.Dispose()
function S([double]$n) { [int][Math]::Round($n * $Scale) }

# ---------- 탐색기 방식 폴더 선택 창 (IFileOpenDialog) ----------
$FolderPickerSource = @'
using System;
using System.Runtime.InteropServices;

namespace WWCC
{
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogCoClass { }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr hwndOwner);
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
    }

    public static class FolderPicker
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid, out IShellItem ppv);

        private const uint FOS_PICKFOLDERS     = 0x00000020;
        private const uint FOS_FORCEFILESYSTEM = 0x00000040;
        private const uint FOS_PATHMUSTEXIST   = 0x00000800;
        private const uint SIGDN_FILESYSPATH   = 0x80058000;

        // 선택한 폴더 경로를 반환, 취소 시 null
        public static string Show(IntPtr owner, string title, string initialPath)
        {
            IFileDialog dlg = (IFileDialog)new FileOpenDialogCoClass();
            try
            {
                uint opts;
                dlg.GetOptions(out opts);
                dlg.SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
                if (!String.IsNullOrEmpty(title)) dlg.SetTitle(title);
                dlg.SetOkButtonLabel("폴더 선택");

                if (!String.IsNullOrEmpty(initialPath) && System.IO.Directory.Exists(initialPath))
                {
                    try
                    {
                        Guid iid = typeof(IShellItem).GUID;
                        IShellItem folder;
                        SHCreateItemFromParsingName(initialPath, IntPtr.Zero, ref iid, out folder);
                        dlg.SetFolder(folder);
                    }
                    catch { }
                }

                if (dlg.Show(owner) != 0) return null;   // 취소

                IShellItem result;
                dlg.GetResult(out result);
                IntPtr psz;
                result.GetDisplayName(SIGDN_FILESYSPATH, out psz);
                try { return Marshal.PtrToStringUni(psz); }
                finally { Marshal.FreeCoTaskMem(psz); }
            }
            finally
            {
                Marshal.ReleaseComObject(dlg);
            }
        }
    }
}
'@
$UseModernPicker = $true
try { Add-Type -TypeDefinition $FolderPickerSource -Language CSharp } catch { $UseModernPicker = $false }

# ---------- 경로 / 상수 ----------
$ScriptDir    = Split-Path -Parent $PSCommandPath
$SettingsFile = Join-Path $ScriptDir 'settings.json'
$LogFile      = Join-Path $ScriptDir 'ShaderCacheCleanup.log'
$WWProcess    = 'Client-Win64-Shipping'

$LocalLow = "$env:USERPROFILE\AppData\LocalLow"
# 기본 정리 대상: 명조(DirectX)에 관련된 캐시
$GpuCaches = @(
    @{ Name = 'Windows DirectX 셰이더 캐시'; Path = "$env:LOCALAPPDATA\D3DSCache" }
    @{ Name = 'NVIDIA DXCache';              Path = "$env:LOCALAPPDATA\NVIDIA\DXCache" }
    # NV_Cache: 최상위 파일만 삭제, 하위 폴더(NGX 등)는 보존
    @{ Name = 'NVIDIA NV_Cache (시스템)';    Path = "$env:ProgramData\NVIDIA Corporation\NV_Cache"; FilesOnly = $true }
    @{ Name = 'NVIDIA NV_Cache (사용자)';    Path = "$env:LOCALAPPDATA\NVIDIA Corporation\NV_Cache"; FilesOnly = $true }
    @{ Name = 'NVIDIA LocalLow PerDriverVersion\DXCache'; Path = "$LocalLow\NVIDIA\PerDriverVersion\DXCache" }
    @{ Name = 'NVIDIA LocalLow\DXCache'; Path = "$LocalLow\NVIDIA\DXCache" }
    @{ Name = 'AMD DxCache';                 Path = "$env:LOCALAPPDATA\AMD\DxCache" }
    @{ Name = 'AMD DxcCache';                Path = "$env:LOCALAPPDATA\AMD\DxcCache" }
    @{ Name = 'AMD LocalLow DxCache';        Path = "$LocalLow\AMD\DxCache" }
    @{ Name = 'Intel ShaderCache';           Path = "$env:LOCALAPPDATA\Intel\ShaderCache" }
    @{ Name = 'Intel LocalLow ShaderCache';  Path = "$LocalLow\Intel\ShaderCache" }
)

# 추가 정리 항목 (선택, 기본값 꺼짐) - 명조와는 무관한 캐시
$ExtraCaches = [ordered]@{
    OpenGL = @{
        Short = 'OpenGL 캐시'
        Label = 'OpenGL 셰이더 캐시  (NVIDIA·AMD GLCache · OpenGL 게임·프로그램에서 사용함)'
        Items = @(
            @{ Name = 'NVIDIA GLCache';          Path = "$env:LOCALAPPDATA\NVIDIA\GLCache" }
            @{ Name = 'NVIDIA LocalLow GLCache'; Path = "$LocalLow\NVIDIA\PerDriverVersion\GLCache" }
            @{ Name = 'AMD GLCache';             Path = "$env:LOCALAPPDATA\AMD\GLCache" }
            @{ Name = 'AMD OglpCache';           Path = "$env:LOCALAPPDATA\AMD\OglpCache" }
        )
    }
    Vulkan = @{
        Short = 'Vulkan 캐시'
        Label = 'Vulkan 셰이더 캐시  (NVIDIA·AMD VkCache · Vulkan 게임·프로그램에서 사용함)'
        Items = @(
            @{ Name = 'NVIDIA VkCache'; Path = "$env:LOCALAPPDATA\NVIDIA\VkCache" }
            @{ Name = 'AMD VkCache';    Path = "$env:LOCALAPPDATA\AMD\VkCache" }
        )
    }
    CUDA = @{
        Short = 'CUDA 캐시'
        Label = 'CUDA 캐시  (NVIDIA ComputeCache · 주로 GPU 가속 프로그램에서 사용함)'
        Items = @(
            @{ Name = 'NVIDIA ComputeCache'; Path = "$env:APPDATA\NVIDIA\ComputeCache" }
        )
    }
}

$ColorOk  = [System.Drawing.Color]::FromArgb(0, 135, 60)
$ColorBad = [System.Drawing.Color]::FromArgb(200, 40, 40)
$ColorDim = [System.Drawing.Color]::Gray

# ---------- 설정 ----------
function Get-DefaultSettings {
    [pscustomobject]@{
        WWPaths        = @('C:\Wuthering Waves')
        CleanSteam     = $false
        SteamLibraries = @('C:\Program Files (x86)\Steam')
        Extras         = @{ OpenGL = $false; Vulkan = $false; CUDA = $false }
        DeepKeywords   = @('wuthering', 'wuwa', 'kuro', '명조')
        DeepDepth      = 4
    }
}

function Read-Settings {
    $d = Get-DefaultSettings
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $j.WWPaths)        { $d.WWPaths        = @($j.WWPaths | Where-Object { $_ }) }
            if ($null -ne $j.CleanSteam)     { $d.CleanSteam     = [bool]$j.CleanSteam }
            if ($null -ne $j.SteamLibraries) { $d.SteamLibraries = @($j.SteamLibraries | Where-Object { $_ }) }
            if ($null -ne $j.DeepKeywords) {
                $kw = @($j.DeepKeywords | Where-Object { $_ })
                if ($kw.Count -gt 0) { $d.DeepKeywords = $kw }
            }
            if ($null -ne $j.DeepDepth) {
                $n = 0
                if ([int]::TryParse([string]$j.DeepDepth, [ref]$n) -and $n -ge 1 -and $n -le 8) { $d.DeepDepth = $n }
            }
            if ($null -ne $j.Extras) {
                foreach ($k in @($d.Extras.Keys)) {
                    if ($null -ne $j.Extras.$k) { $d.Extras[$k] = [bool]$j.Extras.$k }
                }
            }
        } catch { }
    }
    return $d
}

function Get-ListPaths($lv) {
    foreach ($it in $lv.Items) { $it.SubItems[1].Text }
}

function Save-Settings {
    $obj = [ordered]@{
        WWPaths        = @(Get-ListPaths $lvWW)
        CleanSteam     = [bool]$chkSteam.Checked
        SteamLibraries = @(Get-ListPaths $lvSteam)
        Extras         = [ordered]@{
            OpenGL = [bool]$ExtraChecks['OpenGL'].Checked
            Vulkan = [bool]$ExtraChecks['Vulkan'].Checked
            CUDA   = [bool]$ExtraChecks['CUDA'].Checked
        }
        DeepKeywords   = @($script:DeepKeywords)
        DeepDepth      = [int]$script:DeepDepth
    }
    try { $obj | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $SettingsFile -Encoding UTF8 } catch { }
}

# ---------- 경로 판별 ----------
function Resolve-WWSaved([string]$root) {
    $candidates = @(
        [IO.Path]::Combine($root, 'Wuthering Waves Game\Client\Saved'),
        [IO.Path]::Combine($root, 'Client\Saved')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Container) { return $c }
    }
    return $null
}

function Get-SteamAppsDir([string]$lib) {
    if ([IO.Path]::GetFileName($lib.TrimEnd('\')) -ieq 'steamapps') { return $lib }
    return [IO.Path]::Combine($lib, 'steamapps')
}

function Find-SteamLibraries {
    $found = New-Object System.Collections.Generic.List[string]
    $steam = $null
    try { $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { }
    if (-not $steam) {
        try { $steam = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch { }
    }
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

# Steam appmanifest(appmanifest_3513350.acf)의 installdir 읽기 (없으면 기본 폴더명만 사용)
function Get-WWSteamDirNames([string]$apps) {
    $names = New-Object System.Collections.Generic.List[string]
    $acf = [IO.Path]::Combine($apps, 'appmanifest_3513350.acf')
    if (Test-Path -LiteralPath $acf) {
        try {
            $txt = Get-Content -LiteralPath $acf -Raw -Encoding UTF8
            $m = [regex]::Match($txt, '"installdir"\s+"([^"]+)"')
            if ($m.Success) {
                $n = $m.Groups[1].Value
                if ($n -and $n -notmatch '[\\/]' -and $n -ne '..') { $names.Add($n) }
            }
        } catch { }
    }
    if ($names -notcontains 'Wuthering Waves') { $names.Add('Wuthering Waves') }
    return $names.ToArray()
}

# 명조 설치 루트 자동 탐색 (얕은 탐색: Steam 라이브러리 + 각 드라이브의 흔한 위치만 확인)
function Find-WWInstalls([string[]]$extraSteamLibs = @()) {
    $found = New-Object System.Collections.Generic.List[string]
    $add = {
        param($root)
        if ((Resolve-WWSaved $root) -and -not ($found | Where-Object { $_ -ieq $root })) { $found.Add($root) }
    }

    # 1) Steam판: 모든 라이브러리의 steamapps\common\Wuthering Waves
    $libs = New-Object System.Collections.Generic.List[string]
    foreach ($l in @(Find-SteamLibraries) + $extraSteamLibs) {
        if ($l -and -not ($libs | Where-Object { $_ -ieq $l })) { $libs.Add($l) }
    }
    foreach ($l in $libs) {
        $apps = Get-SteamAppsDir $l
        foreach ($n in @(Get-WWSteamDirNames $apps)) {
            & $add ([IO.Path]::Combine($apps, 'common', $n))
        }
    }

    # 2) Kuro·Google·Epic판: 고정 드라이브마다 흔한 위치 확인
    $drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })
    foreach ($d in $drives) {
        $r = $d.RootDirectory.FullName
        foreach ($sub in @('Wuthering Waves', 'Wuthering Waves Game', 'Program Files\Wuthering Waves', 'Program Files (x86)\Wuthering Waves',
                           'Games\Wuthering Waves', 'Game\Wuthering Waves', 'Games\Kuro Games\Wuthering Waves', '명조',
                           'Program Files\Epic Games\WutheringWavesj3oFh', 'Epic Games\WutheringWavesj3oFh', 'WutheringWavesj3oFh')) {
            & $add ([IO.Path]::Combine($r, $sub))
        }
    }
    return $found.ToArray()
}

# ---------- 정밀 탐색 (느림: 드라이브 루트부터 폴더 이름을 단계별로 확인, 읽기만 함) ----------
$script:DeepSeen = 0
function Find-WWDeep {
    param(
        [string[]]$Roots,
        [string[]]$Keywords,
        [int]$MaxDepth = 4,
        [scriptblock]$OnFound,
        [scriptblock]$OnTick,
        [scriptblock]$IsCancelled
    )
    $skipNames = @('Windows', '$Recycle.Bin', 'System Volume Information', 'ProgramData', 'Recovery', 'PerfLogs',
                   'Config.Msi', '$WinREAgent', 'Documents and Settings', 'AppData', 'node_modules', '.git')
    $found = New-Object System.Collections.Generic.List[string]
    $addHit = {
        param($p)
        if (-not ($found | Where-Object { $_ -ieq $p })) {
            $found.Add($p)
            if ($OnFound) { & $OnFound $p }
        }
    }
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($r in $Roots) { if ($r) { $queue.Enqueue(@($r, 0)) } }
    $seen = 0
    while ($queue.Count -gt 0) {
        if ($IsCancelled -and (& $IsCancelled)) { break }
        $item  = $queue.Dequeue()
        $dir   = [string]$item[0]
        $depth = [int]$item[1]
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
                if (Resolve-WWSaved $c) { & $addHit $c; continue }   # 찾으면 그 아래로는 더 내려가지 않음
                # 키워드 폴더 바로 아래 한 단계도 확인 (예: Kuro Games\Wuthering Waves)
                $sub = $null
                try { $sub = [IO.Directory]::GetDirectories($c) } catch { }
                $got = $false
                if ($sub) {
                    foreach ($s in $sub) {
                        if (Resolve-WWSaved $s) { & $addHit $s; $got = $true }
                    }
                }
                if ($got) { continue }
            }
            if (($depth + 1) -lt $MaxDepth) { $queue.Enqueue(@($c, ($depth + 1))) }
        }
    }
    $script:DeepSeen = $seen
    return $found.ToArray()
}

# ---------- 로그 / 정리 ----------
function Write-Log([string]$msg) {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg
    $txtLog.AppendText($line + "`r`n")
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    [System.Windows.Forms.Application]::DoEvents()
}

function Clear-CacheDir([string]$Path, [string]$Name, [bool]$FilesOnly = $false) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Log "[SKIP] $Name - 폴더 없음"
        $script:Count.Skip++
        return
    }
    Write-Log "정리 중: $Name"
    Get-ChildItem -LiteralPath $Path -Force -File:$FilesOnly -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        [System.Windows.Forms.Application]::DoEvents()
    }
    $left = @(Get-ChildItem -LiteralPath $Path -Recurse:(-not $FilesOnly) -Force -File -ErrorAction SilentlyContinue).Count
    if ($left -gt 0) {
        Write-Log "[WARN] $Name - 사용 중인 파일 ${left}개 건너뜀"
        $script:Count.Warn++
    } else {
        if ($FilesOnly) { Write-Log "[OK] $Name (하위 폴더 보존)" } else { Write-Log "[OK] $Name" }
        $script:Count.Ok++
    }
}

function Invoke-Cleanup {
    $script:Count = @{ Ok = 0; Warn = 0; Skip = 0 }
    $txtLog.Clear()
    $header = @(
        '==========================================',
        "셰이더 캐시 정리 로그 (v$AppVersion)",
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
        '=========================================='
    )
    try { Set-Content -LiteralPath $LogFile -Value $header -Encoding UTF8 } catch { }

    Write-Log '--- DirectX 셰이더 캐시 (Windows / GPU 드라이버) ---'
    foreach ($c in $GpuCaches) { Clear-CacheDir $c.Path $c.Name ([bool]$c.FilesOnly) }

    Write-Log '--- 추가 정리 항목 ---'
    foreach ($k in $ExtraCaches.Keys) {
        $cat = $ExtraCaches[$k]
        if ($ExtraChecks[$k].Checked) {
            foreach ($c in $cat.Items) { Clear-CacheDir $c.Path $c.Name }
        } else {
            Write-Log "[SKIP] $($cat.Short) 정리 꺼짐"
        }
    }
    # Steam 셰이더 캐시 전체도 추가 정리 항목에 포함
    if ($chkSteam.Checked) {
        $libs = @(Get-ListPaths $lvSteam)
        if ($libs.Count -eq 0) { Write-Log '[SKIP] 등록된 Steam 라이브러리 없음' }
        foreach ($lib in $libs) {
            $sc = [IO.Path]::Combine((Get-SteamAppsDir $lib), 'shadercache')
            Clear-CacheDir $sc "Steam 셰이더 캐시 - $lib"
        }
    } else {
        Write-Log '[SKIP] Steam 캐시 정리 꺼짐'
    }

    Write-Log '--- 명조 PSO 캐시 ---'
    $roots = @(Get-ListPaths $lvWW)
    if ($roots.Count -eq 0) { Write-Log '[SKIP] 등록된 명조 경로 없음' }
    $i = 0
    foreach ($root in $roots) {
        $i++
        $label = "명조 #$i"
        $saved = Resolve-WWSaved $root
        if (-not $saved) {
            Write-Log "[SKIP] $label - Client\Saved 폴더를 찾을 수 없음: $root"
            $script:Count.Skip++
            continue
        }
        Write-Log "$label : $saved"
        Clear-CacheDir ([IO.Path]::Combine($saved, 'PSO'))       "$label PSO"
        Clear-CacheDir ([IO.Path]::Combine($saved, 'PSOReport')) "$label PSOReport"
    }

    Write-Log ('완료 - OK {0} / WARN {1} / SKIP {2}' -f $script:Count.Ok, $script:Count.Warn, $script:Count.Skip)
}

# ---------- UI 헬퍼 ----------
function New-Button([string]$text, [int]$w = 100) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Size = New-Object System.Drawing.Size((S $w), (S 28))
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (S 6))
    return $b
}

function New-PathList {
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.HideSelection = $false
    $lv.MultiSelect = $false
    $lv.HeaderStyle = 'Nonclickable'
    $lv.Dock = 'Fill'
    [void]$lv.Columns.Add('상태', (S 95))
    [void]$lv.Columns.Add('경로', (S 400))
    $lv.Add_Resize({
        $w = $this.ClientSize.Width - $this.Columns[0].Width - 4
        if ($w -gt 50) { $this.Columns[1].Width = $w }
    })
    return $lv
}

function Add-PathItem($lv, [string]$path) {
    $it = New-Object System.Windows.Forms.ListViewItem('')
    $it.UseItemStyleForSubItems = $false
    [void]$it.SubItems.Add($path)
    [void]$lv.Items.Add($it)
}

function Set-ItemStatus($it, [string]$text, $color) {
    $it.Text = $text
    $it.SubItems[0].ForeColor = $color
}

function Update-Status {
    foreach ($it in $lvWW.Items) {
        if (Resolve-WWSaved $it.SubItems[1].Text) { Set-ItemStatus $it '감지됨' $ColorOk }
        else { Set-ItemStatus $it '찾을 수 없음' $ColorBad }
    }
    foreach ($it in $lvSteam.Items) {
        $apps = Get-SteamAppsDir $it.SubItems[1].Text
        if (Test-Path -LiteralPath ([IO.Path]::Combine($apps, 'shadercache'))) { Set-ItemStatus $it '캐시 있음' $ColorOk }
        elseif (Test-Path -LiteralPath $apps) { Set-ItemStatus $it '캐시 없음' $ColorDim }
        else { Set-ItemStatus $it '찾을 수 없음' $ColorBad }
    }
}

function Select-Folder([string]$desc, [string]$initial) {
    $p = $null
    $done = $false
    if ($UseModernPicker) {
        try {
            $p = [WWCC.FolderPicker]::Show($form.Handle, $desc, $initial)
            $done = $true
        } catch { $done = $false }
    }
    if (-not $done) {
        # 예비: 기존 트리형 폴더 선택 창
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $desc
        $dlg.ShowNewFolderButton = $false
        if ($initial -and (Test-Path -LiteralPath $initial)) { $dlg.SelectedPath = $initial }
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $p = $dlg.SelectedPath }
    }
    if (-not $p) { return $null }
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    return $p
}

function Show-Info([string]$text, [string]$icon = 'Information') {
    [void][System.Windows.Forms.MessageBox]::Show($form, $text, $AppTitle, 'OK', $icon)
}

function New-ListGroup([string]$title, $topControl, $listView, [object[]]$buttons) {
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = $title
    $grp.Dock = 'Fill'
    $grp.Padding = New-Object System.Windows.Forms.Padding((S 8))

    $tbl = New-Object System.Windows.Forms.TableLayoutPanel
    $tbl.Dock = 'Fill'
    $tbl.ColumnCount = 2
    $tbl.RowCount = 2
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    if ($topControl) {
        $tbl.Controls.Add($topControl, 0, 0)
        $tbl.SetColumnSpan($topControl, 2)
    }
    $tbl.Controls.Add($listView, 0, 1)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents = $false
    $flow.AutoSize = $true
    $flow.Dock = 'Fill'
    $flow.Margin = New-Object System.Windows.Forms.Padding((S 8), 0, 0, 0)
    foreach ($b in $buttons) { $flow.Controls.Add($b) }
    $tbl.Controls.Add($flow, 1, 1)

    $grp.Controls.Add($tbl)
    return $grp
}

# ---------- 정밀 탐색 대화상자 ----------
function Show-DeepScanDialog {
    $dg = New-Object System.Windows.Forms.Form
    $script:dgForm = $dg
    $dg.Text = '정밀 탐색'
    $dg.Font = $form.Font
    $dg.AutoScaleMode = 'None'
    $dg.FormBorderStyle = 'FixedDialog'
    $dg.MaximizeBox = $false
    $dg.MinimizeBox = $false
    $dg.ShowInTaskbar = $false
    $dg.StartPosition = 'CenterParent'
    $dg.ClientSize = New-Object System.Drawing.Size((S 560), (S 470))

    $mk = {
        param($ctl, $x, $y, $w, $h)
        $ctl.Location = New-Object System.Drawing.Point((S $x), (S $y))
        $ctl.Size = New-Object System.Drawing.Size((S $w), (S $h))
        $dg.Controls.Add($ctl)
        $ctl
    }
    $newLabel = { param($text) $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l }

    $lblDesc = & $newLabel '지정한 키워드가 이름에 들어간 폴더를 드라이브 루트부터 단계별로 찾고, 그 안에 Client\Saved가 있으면 명조 설치로 판단함. 읽기만 하며 아무것도 지우거나 바꾸지 않음.'
    $lblDesc.ForeColor = $ColorDim
    [void](& $mk $lblDesc 12 10 536 40)

    [void](& $mk (& $newLabel '키워드') 12 62 66 20)
    $script:dgTxtKw = New-Object System.Windows.Forms.TextBox
    $script:dgTxtKw.Text = (@($script:DeepKeywords) -join ', ')
    [void](& $mk $script:dgTxtKw 80 59 370 24)
    $lblKwHint = & $newLabel '쉼표로 구분'
    $lblKwHint.ForeColor = $ColorDim
    [void](& $mk $lblKwHint 458 62 90 20)

    [void](& $mk (& $newLabel '깊이') 12 94 66 20)
    $script:dgNumDepth = New-Object System.Windows.Forms.NumericUpDown
    $script:dgNumDepth.Minimum = 1
    $script:dgNumDepth.Maximum = 8
    $script:dgNumDepth.Value = [Math]::Min(8, [Math]::Max(1, [int]$script:DeepDepth))
    [void](& $mk $script:dgNumDepth 80 91 60 24)
    $lblDepth = & $newLabel '루트 = 0단계 · 깊을수록 오래 걸림 (기본 4)'
    $lblDepth.ForeColor = $ColorDim
    [void](& $mk $lblDepth 150 94 400 20)

    [void](& $mk (& $newLabel '드라이브') 12 126 66 20)
    $flowDrv = New-Object System.Windows.Forms.FlowLayoutPanel
    $flowDrv.WrapContents = $true
    [void](& $mk $flowDrv 80 122 468 28)
    $script:dgDrives = @()
    foreach ($d in @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $d.Name
        $cb.AutoSize = $true
        $cb.Checked = $true
        $flowDrv.Controls.Add($cb)
        $script:dgDrives += $cb
    }

    $script:dgBtnStart = New-Object System.Windows.Forms.Button
    $script:dgBtnStart.Text = '탐색 시작'
    [void](& $mk $script:dgBtnStart 12 156 100 28)
    $script:dgBtnStop = New-Object System.Windows.Forms.Button
    $script:dgBtnStop.Text = '중지'
    $script:dgBtnStop.Enabled = $false
    [void](& $mk $script:dgBtnStop 118 156 80 28)
    $script:dgLblStatus = & $newLabel '키워드와 깊이를 확인한 뒤 [탐색 시작]을 눌러 주세요.'
    $script:dgLblStatus.AutoEllipsis = $true
    [void](& $mk $script:dgLblStatus 208 162 340 20)

    $script:dgProg = New-Object System.Windows.Forms.ProgressBar
    $script:dgProg.Style = 'Marquee'
    $script:dgProg.MarqueeAnimationSpeed = 30
    $script:dgProg.Visible = $false
    [void](& $mk $script:dgProg 12 192 536 8)

    [void](& $mk (& $newLabel '찾은 위치 (체크한 항목을 목록에 추가)') 12 210 536 20)
    $script:dgList = New-Object System.Windows.Forms.ListView
    $script:dgList.View = 'Details'
    $script:dgList.CheckBoxes = $true
    $script:dgList.FullRowSelect = $true
    $script:dgList.HideSelection = $false
    $script:dgList.MultiSelect = $false
    $script:dgList.HeaderStyle = 'None'
    [void]$script:dgList.Columns.Add('경로', (S 400))
    [void]$script:dgList.Columns.Add('상태', (S 110))
    [void](& $mk $script:dgList 12 232 536 188)

    $script:dgBtnAdd = New-Object System.Windows.Forms.Button
    $script:dgBtnAdd.Text = '선택 항목 추가'
    [void](& $mk $script:dgBtnAdd 12 430 130 30)
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = '닫기'
    [void](& $mk $btnClose 448 430 100 30)

    $script:dgScanning = $false
    $script:dgCancel = $false
    $script:dgCloseAfter = $false
    $script:dgResult = @()
    $script:dgSkipped = 0
    $script:dgExisting = @()

    $script:dgBtnStop.Add_Click({ $script:dgCancel = $true })
    $btnClose.Add_Click({ $script:dgForm.Close() })

    $dg.Add_FormClosing({
        if ($script:dgScanning) {
            # 탐색 중에는 먼저 중지시키고, 끝난 뒤 닫음
            $_.Cancel = $true
            $script:dgCancel = $true
            $script:dgCloseAfter = $true
        }
    })

    $script:dgBtnAdd.Add_Click({
        $sel = @()
        foreach ($it in $script:dgList.CheckedItems) {
            if ($it.Tag) { $sel += [string]$it.Tag }
        }
        if ($sel.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show($script:dgForm, '추가할 항목을 체크해 주세요.', $AppTitle, 'OK', 'Information')
            return
        }
        $script:dgResult = $sel
        $script:dgForm.Close()
    })

    $script:dgBtnStart.Add_Click({
        $kws = @(($script:dgTxtKw.Text -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $roots = @($script:dgDrives | Where-Object { $_.Checked } | ForEach-Object { $_.Text })
        if ($kws.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show($script:dgForm, '키워드를 한 개 이상 입력해 주세요.', $AppTitle, 'OK', 'Warning')
            return
        }
        if ($roots.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show($script:dgForm, '탐색할 드라이브를 한 개 이상 선택해 주세요.', $AppTitle, 'OK', 'Warning')
            return
        }
        $script:DeepKeywords = $kws
        $script:DeepDepth = [int]$script:dgNumDepth.Value
        Save-Settings

        $script:dgExisting = @(Get-ListPaths $lvWW)
        $script:dgSkipped = 0
        $script:dgList.Items.Clear()
        $script:dgCancel = $false
        $script:dgScanning = $true
        $script:dgBtnStart.Enabled = $false
        $script:dgBtnAdd.Enabled = $false
        $script:dgBtnStop.Enabled = $true
        $script:dgProg.Visible = $true
        $script:dgLblStatus.Text = '탐색 중...'
        [System.Windows.Forms.Application]::DoEvents()

        $err = $null
        try {
            [void](Find-WWDeep -Roots $roots -Keywords $kws -MaxDepth $script:DeepDepth `
                -OnFound {
                    param($p)
                    if ($script:dgExisting | Where-Object { $_ -ieq $p }) {
                        # 이미 등록된 경로: 찾았다는 표시만 하고 체크는 해제
                        $script:dgSkipped++
                        $lvi = New-Object System.Windows.Forms.ListViewItem($p)
                        $lvi.UseItemStyleForSubItems = $false
                        $lvi.Tag = ''
                        [void]$lvi.SubItems.Add('이미 등록됨')
                        $lvi.SubItems[1].ForeColor = $ColorDim
                        [void]$script:dgList.Items.Add($lvi)
                    } else {
                        $lvi = New-Object System.Windows.Forms.ListViewItem($p)
                        $lvi.UseItemStyleForSubItems = $false
                        $lvi.Tag = $p
                        $lvi.Checked = $true
                        [void]$lvi.SubItems.Add('추가 가능')
                        $lvi.SubItems[1].ForeColor = [System.Drawing.Color]::FromArgb(0, 102, 204)
                        [void]$script:dgList.Items.Add($lvi)
                    }
                    [System.Windows.Forms.Application]::DoEvents()
                } `
                -OnTick {
                    param($dir, $n)
                    $script:dgLblStatus.Text = "탐색 중... $n 폴더 확인 · $dir"
                    [System.Windows.Forms.Application]::DoEvents()
                } `
                -IsCancelled { [System.Windows.Forms.Application]::DoEvents(); $script:dgCancel })
        } catch {
            $err = $_.Exception.Message
        }

        $cancelled = $script:dgCancel
        $script:dgScanning = $false
        if ($script:dgCloseAfter) { $script:dgForm.Close(); return }
        $script:dgProg.Visible = $false
        $script:dgBtnStart.Enabled = $true
        $script:dgBtnAdd.Enabled = $true
        $script:dgBtnStop.Enabled = $false
        $head = if ($err) { "오류: $err" } elseif ($cancelled) { '중지됨' } else { '완료' }
        $msg = "$head · $($script:dgList.Items.Count)개 발견 (폴더 $($script:DeepSeen)개 확인"
        if ($script:dgSkipped -gt 0) { $msg += ", 이미 등록된 $($script:dgSkipped)개 포함" }
        $script:dgLblStatus.Text = $msg + ')'
    })

    [void]$dg.ShowDialog($form)
    $dg.Dispose()
    return $script:dgResult
}

# ---------- 폼 구성 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "$AppTitle v$AppVersion"
$form.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
$form.AutoScaleMode = 'None'
$form.StartPosition = 'CenterScreen'
$form.ClientSize  = New-Object System.Drawing.Size((S 720), (S 878))
$form.MinimumSize = New-Object System.Drawing.Size((S 600), (S 788))
$form.Padding = New-Object System.Windows.Forms.Padding((S 10))

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 5
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (S 236))))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (S 167))))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, (S 165))))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$form.Controls.Add($root)

# 명조 경로 그룹
$lblWW = New-Object System.Windows.Forms.Label
$lblWW.Text = '설치 루트 폴더를 지정하세요. 예) D:\Wuthering Waves   (더블클릭으로 경로 변경)'
$lblWW.AutoSize = $true
$lblWW.ForeColor = $ColorDim
$lblWW.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (S 6))

$lvWW = New-PathList
$btnWWAdd  = New-Button '추가'
$btnWWEdit = New-Button '변경'
$btnWWDel  = New-Button '삭제'
$btnWWAuto = New-Button '자동 감지'
$btnWWDeep = New-Button '정밀 탐색'
$grpWW = New-ListGroup '명조 클라이언트 경로' $lblWW $lvWW @($btnWWAdd, $btnWWEdit, $btnWWDel, $btnWWAuto, $btnWWDeep)
$root.Controls.Add($grpWW, 0, 0)

# 추가 정리 항목 그룹 (체크리스트)
function New-ExtraCheck([string]$text) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.AutoSize = $true
    $c.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (S 4))
    return $c
}

$grpExtra = New-Object System.Windows.Forms.GroupBox
$grpExtra.Text = '추가 정리 항목 (선택)'
$grpExtra.Dock = 'Fill'
$grpExtra.Padding = New-Object System.Windows.Forms.Padding((S 8))

$flowExtra = New-Object System.Windows.Forms.FlowLayoutPanel
$flowExtra.FlowDirection = 'TopDown'
$flowExtra.WrapContents = $false
$flowExtra.Dock = 'Fill'
$flowExtra.AutoScroll = $true

$lblExtra = New-Object System.Windows.Forms.Label
$lblExtra.Text = '명조에는 필요 없는 항목(명조 PSO는 위에서 정리). 다른 게임이나 프로그램의 캐시까지 비우고 싶을 때 선택.'
$lblExtra.AutoSize = $true
$lblExtra.ForeColor = $ColorDim
$lblExtra.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (S 6))
$flowExtra.Controls.Add($lblExtra)

$ExtraChecks = @{}
foreach ($k in $ExtraCaches.Keys) {
    $c = New-ExtraCheck $ExtraCaches[$k].Label
    $ExtraChecks[$k] = $c
    $flowExtra.Controls.Add($c)
}
$chkSteam = New-ExtraCheck 'Steam 셰이더 캐시 전체  (Steam이 따로 관리하는 모든 게임의 캐시 · 명조 PSO와는 별개)'
$flowExtra.Controls.Add($chkSteam)

$grpExtra.Controls.Add($flowExtra)
$root.Controls.Add($grpExtra, 0, 1)

# Steam 그룹
$lblSteam = New-Object System.Windows.Forms.Label
$lblSteam.Text = '위에서 Steam 셰이더 캐시를 선택하면 아래 라이브러리의 shadercache를 정리함.'
$lblSteam.AutoSize = $true
$lblSteam.ForeColor = $ColorDim
$lblSteam.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (S 6))

$lvSteam = New-PathList
$btnSteamAdd  = New-Button '추가'
$btnSteamDel  = New-Button '삭제'
$btnSteamAuto = New-Button '자동 감지'
$grpSteam = New-ListGroup 'Steam 라이브러리' $lblSteam $lvSteam @($btnSteamAdd, $btnSteamDel, $btnSteamAuto)
$root.Controls.Add($grpSteam, 0, 2)

# 실행 줄
$runRow = New-Object System.Windows.Forms.FlowLayoutPanel
$runRow.AutoSize = $true
$runRow.Dock = 'Fill'
$runRow.WrapContents = $false
$runRow.Margin = New-Object System.Windows.Forms.Padding(0, (S 6), 0, (S 6))

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = '캐시 정리 실행'
$btnRun.Font = New-Object System.Drawing.Font('Malgun Gothic', 10, [System.Drawing.FontStyle]::Bold)
$btnRun.Size = New-Object System.Drawing.Size((S 170), (S 38))
$btnRun.Margin = New-Object System.Windows.Forms.Padding(0)

$btnOpenLog = New-Button '로그 파일 열기' 120
$btnOpenLog.Size = New-Object System.Drawing.Size((S 120), (S 38))
$btnOpenLog.Margin = New-Object System.Windows.Forms.Padding((S 8), 0, 0, 0)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '설정은 settings.json에 자동 저장됩니다.'
$lblHint.AutoSize = $true
$lblHint.ForeColor = $ColorDim
$lblHint.Margin = New-Object System.Windows.Forms.Padding((S 12), (S 12), 0, 0)

$runRow.Controls.Add($btnRun)
$runRow.Controls.Add($btnOpenLog)
$runRow.Controls.Add($lblHint)
$root.Controls.Add($runRow, 0, 3)

# 로그 그룹
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = '진행 로그'
$grpLog.Dock = 'Fill'
$grpLog.Padding = New-Object System.Windows.Forms.Padding((S 8))
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.WordWrap = $false
$txtLog.Dock = 'Fill'
$txtLog.BackColor = [System.Drawing.SystemColors]::Window
$grpLog.Controls.Add($txtLog)
$root.Controls.Add($grpLog, 0, 4)

# ---------- 동작 ----------
function Update-SteamEnabled {
    $on = $chkSteam.Checked
    foreach ($c in @($lvSteam, $btnSteamAdd, $btnSteamDel, $btnSteamAuto)) { $c.Enabled = $on }
}

function Set-UiBusy([bool]$busy) {
    foreach ($c in @($grpWW, $grpExtra, $grpSteam, $btnRun, $btnOpenLog)) { $c.Enabled = -not $busy }
    $form.UseWaitCursor = $busy
    [System.Windows.Forms.Application]::DoEvents()
}

$btnWWAdd.Add_Click({
    $p = Select-Folder '명조 설치 폴더를 선택하세요. (예: D:\Wuthering Waves)' ''
    if (-not $p) { return }
    if (@(Get-ListPaths $lvWW) -contains $p) { Show-Info '이미 등록된 경로입니다.'; return }
    Add-PathItem $lvWW $p
    Update-Status
    Save-Settings
    if (-not (Resolve-WWSaved $p)) {
        Show-Info "선택한 폴더에서 Client\Saved 폴더를 찾지 못했습니다.`n명조 설치 루트 폴더가 맞는지 확인해 주세요.`n`n(게임을 한 번도 실행하지 않았다면 아직 없을 수 있습니다.)" 'Warning'
    }
})

$editWW = {
    if ($lvWW.SelectedItems.Count -eq 0) { return }
    $it = $lvWW.SelectedItems[0]
    $p = Select-Folder '명조 설치 폴더를 선택하세요.' $it.SubItems[1].Text
    if (-not $p) { return }
    $it.SubItems[1].Text = $p
    Update-Status
    Save-Settings
}
$btnWWEdit.Add_Click($editWW)
$lvWW.Add_DoubleClick($editWW)

$btnWWDel.Add_Click({
    if ($lvWW.SelectedItems.Count -eq 0) { return }
    $lvWW.Items.Remove($lvWW.SelectedItems[0])
    Save-Settings
})

$btnWWAuto.Add_Click({
    Set-UiBusy $true
    try {
        $hits = @(Find-WWInstalls @(Get-ListPaths $lvSteam))
    } finally {
        Set-UiBusy $false
    }
    if ($hits.Count -eq 0) {
        Show-Info "명조 설치를 찾지 못했습니다.`n흔한 위치(드라이브 최상위, Program Files, Games, Steam 라이브러리)만 확인합니다.`n그 밖의 위치는 [정밀 탐색] 또는 [추가]로 등록해 주세요." 'Warning'
        return
    }
    $existing = @(Get-ListPaths $lvWW)
    $added = 0
    foreach ($h in $hits) {
        if (-not ($existing | Where-Object { $_ -ieq $h })) { Add-PathItem $lvWW $h; $added++ }
    }
    Update-Status
    Save-Settings
    Show-Info "명조 설치 $($hits.Count)개를 감지했고, 새로 $($added)개를 추가했습니다."
})

$btnWWDeep.Add_Click({
    $picked = @(Show-DeepScanDialog)
    if ($picked.Count -eq 0) { return }
    $existing = @(Get-ListPaths $lvWW)
    $added = 0
    foreach ($p in $picked) {
        if ($p -and -not ($existing | Where-Object { $_ -ieq $p })) { Add-PathItem $lvWW $p; $added++ }
    }
    Update-Status
    Save-Settings
    if ($added -gt 0) { Show-Info "정밀 탐색 결과 $($added)개를 목록에 추가했습니다." }
})

$btnSteamAdd.Add_Click({
    $p = Select-Folder 'Steam 라이브러리 폴더를 선택하세요. (예: D:\SteamLibrary)' ''
    if (-not $p) { return }
    if (@(Get-ListPaths $lvSteam) -contains $p) { Show-Info '이미 등록된 경로입니다.'; return }
    Add-PathItem $lvSteam $p
    Update-Status
    Save-Settings
})

$btnSteamDel.Add_Click({
    if ($lvSteam.SelectedItems.Count -eq 0) { return }
    $lvSteam.Items.Remove($lvSteam.SelectedItems[0])
    Save-Settings
})

$btnSteamAuto.Add_Click({
    $libs = @(Find-SteamLibraries)
    if ($libs.Count -eq 0) { Show-Info 'Steam 설치를 찾지 못했습니다.' 'Warning'; return }
    $existing = @(Get-ListPaths $lvSteam)
    $added = 0
    foreach ($l in $libs) {
        if ($existing -notcontains $l) { Add-PathItem $lvSteam $l; $added++ }
    }
    Update-Status
    Save-Settings
    Show-Info "Steam 라이브러리 $($libs.Count)개를 감지했고, 새로 $($added)개를 추가했습니다."
})

$chkSteam.Add_CheckedChanged({
    Update-SteamEnabled
    Save-Settings
})

foreach ($c in $ExtraChecks.Values) {
    $c.Add_CheckedChanged({ Save-Settings })
}

$btnOpenLog.Add_Click({
    if (Test-Path -LiteralPath $LogFile) { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$LogFile`"" }
    else { Show-Info '아직 로그 파일이 없습니다.' }
})

$btnRun.Add_Click({
    if (Get-Process -Name $WWProcess -ErrorAction SilentlyContinue) {
        $r = [System.Windows.Forms.MessageBox]::Show($form,
            "명조가 실행 중입니다.`n실행 중인 클라이언트의 캐시는 정리되지 않을 수 있습니다.`n`n그래도 계속할까요?",
            $AppTitle, 'YesNo', 'Warning')
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    Save-Settings
    Set-UiBusy $true
    try {
        Invoke-Cleanup
    } catch {
        Write-Log "[ERROR] $($_.Exception.Message)"
    } finally {
        Set-UiBusy $false
        Update-Status
    }
})

$form.Add_FormClosing({ Save-Settings })

# ---------- 초기화 ----------
$firstRun = -not (Test-Path -LiteralPath $SettingsFile)
$settings = Read-Settings
if ($firstRun) {
    # 처음 실행: 기본값 대신 자동 감지 결과로 채움 (못 찾으면 빈 목록)
    $libs = @(Find-SteamLibraries)
    if ($libs.Count -gt 0) { $settings.SteamLibraries = $libs }
    $settings.WWPaths = @(Find-WWInstalls $libs)
}
$script:DeepKeywords = @($settings.DeepKeywords)
$script:DeepDepth    = [int]$settings.DeepDepth
foreach ($p in $settings.WWPaths)        { Add-PathItem $lvWW $p }
foreach ($p in $settings.SteamLibraries) { Add-PathItem $lvSteam $p }
$chkSteam.Checked = $settings.CleanSteam
foreach ($k in $ExtraCaches.Keys) { $ExtraChecks[$k].Checked = [bool]$settings.Extras[$k] }
Update-SteamEnabled
Update-Status
if (-not (Test-Path -LiteralPath $SettingsFile)) { Save-Settings }

$txtLog.Text = "준비됨 (관리자 권한).`r`n게임과 런처를 모두 종료한 뒤 [캐시 정리 실행]을 눌러 주세요.`r`n"
if ($firstRun) {
    if ($lvWW.Items.Count -gt 0) {
        $txtLog.AppendText("처음 실행: 명조 설치 $($lvWW.Items.Count)개를 자동 감지해 등록했습니다.`r`n")
    } else {
        $txtLog.AppendText("처음 실행: 명조 설치를 자동으로 찾지 못했습니다. [자동 감지], [정밀 탐색] 또는 [추가]로 등록해 주세요.`r`n")
    }
}

# 화면이 작으면 창 높이를 작업 영역에 맞춤
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$extraH = $form.Height - $form.ClientSize.Height
$maxClientH = $wa.Height - $extraH
if ($form.ClientSize.Height -gt $maxClientH) {
    $form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, $maxClientH)
}
if ($form.MinimumSize.Height -gt $wa.Height) {
    $form.MinimumSize = New-Object System.Drawing.Size($form.MinimumSize.Width, $wa.Height)
}

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
