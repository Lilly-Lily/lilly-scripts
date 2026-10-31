# 키 입력 추적기 (GUI) - 실제 키보드 입력과 프로그램이 주입한 가짜 입력을 구분해서 기록합니다.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

try {
Add-Type -ErrorAction Stop -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public class KeyEvt {
    public DateTime Time; public string Key; public uint Scan;
    public bool Injected; public long Extra; public string Window; public bool Mark;
}

public static class KbHook {
    delegate IntPtr Proc(int n, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    struct KB { public uint vk, scan, flags, time; public IntPtr extra; }

    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, Proc p, IntPtr h, uint t);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string n);

    public static ConcurrentQueue<KeyEvt> Queue = new ConcurrentQueue<KeyEvt>();
    static Dictionary<uint, string> names = new Dictionary<uint, string>();
    static Proc proc = Callback;
    static IntPtr hook = IntPtr.Zero;

    public static bool Running { get { return hook != IntPtr.Zero; } }

    public static bool Start() {
        if (hook != IntPtr.Zero) return true;
        hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0);
        return hook != IntPtr.Zero;
    }

    public static void Stop() {
        if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
    }

    static string ProcName(uint pid) {
        string s;
        if (names.TryGetValue(pid, out s)) return s;
        try { s = Process.GetProcessById((int)pid).ProcessName; } catch { s = "?"; }
        names[pid] = s;
        return s;
    }

    static string KeyName(uint vk) {
        if (vk == 0x15) return "HanYeong";
        if (vk == 0x19) return "Hanja";
        return ((System.Windows.Forms.Keys)vk).ToString();
    }

    static IntPtr Callback(int n, IntPtr w, IntPtr l) {
        int msg = (int)w;
        if (n >= 0 && (msg == 0x100 || msg == 0x104)) {
            KB k = (KB)Marshal.PtrToStructure(l, typeof(KB));
            uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            Queue.Enqueue(new KeyEvt {
                Time = DateTime.Now, Key = KeyName(k.vk), Scan = k.scan,
                Injected = (k.flags & 0x10) != 0, Extra = k.extra.ToInt64(),
                Window = ProcName(pid)
            });
        }
        return CallNextHookEx(hook, n, w, l);
    }
}
"@
} catch {
    [Windows.Forms.MessageBox]::Show("초기화 실패:`n$($_.Exception.Message)", "키 입력 추적기") | Out-Null
    exit
}

[Windows.Forms.Application]::EnableVisualStyles()

$all = New-Object 'System.Collections.Generic.List[KeyEvt]'
$script:autoPath = $null
$script:injCount = 0
$maxRows = 5000
$utf8Bom = New-Object System.Text.UTF8Encoding $true
$csvHeader = 'Time,Key,Scan,Type,Extra,Window'

function Format-Line($e) {
    if ($e.Mark) { return '{0:yyyy-MM-dd HH:mm:ss.fff},---- 증상 표시 ----,,MARK,,' -f $e.Time }
    $type = if ($e.Injected) { 'INJECTED' } else { 'real' }
    '{0:yyyy-MM-dd HH:mm:ss.fff},{1},{2},{3},0x{4:X},{5}' -f $e.Time, $e.Key, $e.Scan, $type, $e.Extra, $e.Window
}

# ---------- UI ----------
$form = New-Object Windows.Forms.Form
$form.Text = '키 입력 추적기'
$form.Size = New-Object Drawing.Size(920, 580)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('맑은 고딕', 9)

$bar = New-Object Windows.Forms.FlowLayoutPanel
$bar.Dock = 'Top'; $bar.AutoSize = $true; $bar.Padding = '6,6,6,6'

function New-Btn($text) { $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.AutoSize = $true; $b.Height = 28; $bar.Controls.Add($b); $b }
function New-Chk($text) { $c = New-Object Windows.Forms.CheckBox; $c.Text = $text; $c.AutoSize = $true; $c.Margin = '10,8,3,3'; $bar.Controls.Add($c); $c }

$btnStart = New-Btn '추적 중지'
$btnMark  = New-Btn '증상 표시'
$btnSave  = New-Btn '로그 저장...'
$btnClear = New-Btn '지우기'
$chkInj   = New-Chk '주입된 키만 보기'
$chkAuto  = New-Chk '자동 저장'
$chkTop   = New-Chk '항상 위'

$lv = New-Object Windows.Forms.ListView
$lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true; $lv.Dock = 'Fill'
# 깜빡임 방지: 더블 버퍼링 활성화
[Windows.Forms.ListView].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($lv, $true, $null)
foreach ($c in @(@('시각',100), @('키',120), @('Scan',60), @('구분',90), @('Extra',110), @('입력 창(프로세스)',220))) {
    [void]$lv.Columns.Add($c[0], $c[1])
}

$statusStrip = New-Object Windows.Forms.StatusStrip
$status = New-Object Windows.Forms.ToolStripStatusLabel
$statusStrip.Items.Add($status) | Out-Null

$form.Controls.Add($lv)
$form.Controls.Add($bar)
$form.Controls.Add($statusStrip)

function Update-Status {
    $state = if ([KbHook]::Running) { '추적 중' } else { '중지됨' }
    $auto = if ($script:autoPath) { "  |  자동 저장: $(Split-Path $script:autoPath -Leaf)" } else { '' }
    $status.Text = "$state  |  전체 $($all.Count)건 / 주입 $($script:injCount)건$auto"
}

function Add-Row($e) {
    if ($chkInj.Checked -and -not $e.Injected -and -not $e.Mark) { return }
    if ($e.Mark) {
        $it = New-Object Windows.Forms.ListViewItem($e.Time.ToString('HH:mm:ss.fff'))
        [void]$it.SubItems.Add('---- 증상 표시 ----')
        $it.BackColor = [Drawing.Color]::LightYellow
    } else {
        $it = New-Object Windows.Forms.ListViewItem($e.Time.ToString('HH:mm:ss.fff'))
        $type = if ($e.Injected) { '[주입됨]' } else { '실제 키' }
        foreach ($s in @($e.Key, "$($e.Scan)", $type, ('0x{0:X}' -f $e.Extra), $e.Window)) { [void]$it.SubItems.Add($s) }
        if ($e.Injected) { $it.ForeColor = [Drawing.Color]::DarkRed; $it.BackColor = [Drawing.Color]::MistyRose }
    }
    [void]$lv.Items.Add($it)
    while ($lv.Items.Count -gt $maxRows) { $lv.Items.RemoveAt(0) }
}

function Add-Event($e) {
    $all.Add($e)
    if ($e.Injected) { $script:injCount++ }
    Add-Row $e
    if ($script:autoPath) { [IO.File]::AppendAllText($script:autoPath, (Format-Line $e) + "`r`n", $utf8Bom) }
}

function Rebuild-View {
    $lv.BeginUpdate(); $lv.Items.Clear()
    foreach ($e in $all) { Add-Row $e }
    $lv.EndUpdate()
    if ($lv.Items.Count) { $lv.EnsureVisible($lv.Items.Count - 1) }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    if ([KbHook]::Queue.IsEmpty) { return }
    $e = $null; $added = $false
    $lv.BeginUpdate()
    while ([KbHook]::Queue.TryDequeue([ref]$e)) { Add-Event $e; $added = $true }
    $lv.EndUpdate()
    if ($added) {
        if ($lv.Items.Count) { $lv.EnsureVisible($lv.Items.Count - 1) }
        Update-Status
    }
})

$btnStart.Add_Click({
    if ([KbHook]::Running) { [KbHook]::Stop(); $btnStart.Text = '추적 시작' }
    elseif ([KbHook]::Start()) { $btnStart.Text = '추적 중지' }
    else { [Windows.Forms.MessageBox]::Show('키보드 훅 설치 실패 (보안 프로그램이 막고 있을 수 있어요)') | Out-Null }
    Update-Status
})

$btnMark.Add_Click({
    $m = New-Object KeyEvt; $m.Time = [DateTime]::Now; $m.Mark = $true
    Add-Event $m
    $lv.EnsureVisible($lv.Items.Count - 1)
    Update-Status
})

$btnSave.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV 파일 (*.csv)|*.csv|텍스트 파일 (*.txt)|*.txt'
    $dlg.FileName = 'keylog_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv'
    if ($dlg.ShowDialog() -eq 'OK') {
        $lines = @($csvHeader) + ($all | ForEach-Object { Format-Line $_ })
        [IO.File]::WriteAllLines($dlg.FileName, [string[]]$lines, $utf8Bom)
        $status.Text = "저장 완료: $($dlg.FileName)"
    }
})

$btnClear.Add_Click({ $all.Clear(); $script:injCount = 0; $lv.Items.Clear(); Update-Status })

$chkInj.Add_CheckedChanged({ Rebuild-View })

$chkAuto.Add_CheckedChanged({
    if ($chkAuto.Checked) {
        $dir = if ($PSScriptRoot) { $PSScriptRoot } else { [Environment]::GetFolderPath('Desktop') }
        $script:autoPath = Join-Path $dir ('keylog_auto_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')
        [IO.File]::WriteAllText($script:autoPath, $csvHeader + "`r`n", $utf8Bom)
    } else { $script:autoPath = $null }
    Update-Status
})

$chkTop.Add_CheckedChanged({ $form.TopMost = $chkTop.Checked })

$form.Add_Shown({
    if (-not [KbHook]::Start()) {
        $btnStart.Text = '추적 시작'
        [Windows.Forms.MessageBox]::Show('키보드 훅 설치 실패 (보안 프로그램이 막고 있을 수 있어요)') | Out-Null
    }
    $timer.Start(); Update-Status
})

$form.Add_FormClosing({ $timer.Stop(); [KbHook]::Stop() })

[void]$form.ShowDialog()
