param(
    [ValidateSet('Patch', 'Restore', 'Check')]
    [string]$Mode = 'Check',
    [string]$AppPath = (Join-Path $env:ProgramFiles 'WuwaTappoGlobal\WuwaTappo.exe')
)

# WuwaTappo: 마우스 "이동" 이벤트만 앱으로 전달하지 않게 만드는 1바이트 패치
# - rdev 이벤트 변환 함수에서 MouseMove 결과를 "이벤트 없음(6)"으로 바꿉니다.
# - 클릭, 휠, 키보드 이벤트는 그대로 유지됩니다.
$ErrorActionPreference = 'Stop'

# 변환 함수의 MouseMove 분기 (32바이트). 인덱스 28의 값(04)이 이벤트 종류(MouseMove)입니다.
$origHex  = 'F2 41 0F 2A 08 0F 57 C0 F2 41 0F 2A 40 04 66 49 0F 7E CA 44 89 D7 49 C1 EA 20 41 B1 04 31 C9 EB'
$orig     = [byte[]]($origHex -split ' ' | ForEach-Object { [Convert]::ToByte($_, 16) })
$valueIdx = 28
$oldValue = [byte]0x04   # MouseMove
$newValue = [byte]0x06   # None (이벤트 없음)

if ($orig[$valueIdx] -ne $oldValue -or $orig[$valueIdx - 1] -ne 0xB1) { throw '내부 패턴 오류' }

Add-Type -TypeDefinition @'
public static class BytePattern {
    public static int Count(byte[] h, byte[] n) { int c = 0, i = 0; while ((i = IndexOf(h, n, i)) >= 0) { c++; i++; } return c; }
    public static int IndexOf(byte[] h, byte[] n, int start) {
        int last = h.Length - n.Length;
        for (int i = start; i <= last; i++) {
            if (h[i] != n[0]) continue;
            int j = 1;
            while (j < n.Length && h[i + j] == n[j]) j++;
            if (j == n.Length) return i;
        }
        return -1;
    }
}
'@

function Test-Admin {
    if ($IsWindows -eq $false) { return $true }
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-State([byte[]]$bytes) {
    $patched = [byte[]]$orig.Clone()
    $patched[$valueIdx] = $newValue
    $co = [BytePattern]::Count($bytes, $orig)
    $cp = [BytePattern]::Count($bytes, $patched)
    if ($co -eq 1 -and $cp -eq 0) { return @{ State = 'Original'; Index = [BytePattern]::IndexOf($bytes, $orig, 0) } }
    if ($cp -eq 1 -and $co -eq 0) { return @{ State = 'Patched';  Index = [BytePattern]::IndexOf($bytes, $patched, 0) } }
    return @{ State = 'Unknown'; Index = -1 }
}

if (-not (Test-Path -LiteralPath $AppPath)) { throw "파일을 찾을 수 없습니다: $AppPath" }
$AppPath = (Resolve-Path -LiteralPath $AppPath).Path

$bytes = [IO.File]::ReadAllBytes($AppPath)
$info  = Get-State $bytes
$sha   = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')

if ($Mode -eq 'Check') {
    switch ($info.State) {
        'Original' { Write-Host '상태: 원본 (패치 대상 위치를 찾았습니다. 적용 가능)' }
        'Patched'  { Write-Host '상태: 패치됨 (마우스 이동 이벤트 차단 중)' }
        default    { Write-Host '상태: 알 수 없음 (앱 버전이 달라 패치 위치를 확정할 수 없습니다. 아무것도 바꾸지 않습니다)' }
    }
    Write-Host ('SHA256: ' + $sha)
    return
}

if ($info.State -eq 'Unknown') {
    throw '패치 위치를 확정할 수 없어 중단합니다. (앱이 업데이트되었을 수 있습니다. 아무것도 바꾸지 않았습니다)'
}
if ($Mode -eq 'Patch'   -and $info.State -eq 'Patched')  { Write-Host '이미 패치되어 있습니다.'; return }
if ($Mode -eq 'Restore' -and $info.State -eq 'Original') { Write-Host '이미 원본 상태입니다.';   return }

if (-not (Test-Admin)) {
    Write-Host '관리자 권한으로 다시 실행합니다...'
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode -AppPath `"$AppPath`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
    return
}

# 실행 중이면 종료 (같은 경로의 프로세스만)
$wasRunning = $false
if ($IsWindows -ne $false) {
    $procs = Get-Process -Name 'WuwaTappo' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $AppPath }
    foreach ($p in $procs) { $wasRunning = $true; $p.Kill(); $p.WaitForExit(10000) | Out-Null }
}

if ($Mode -eq 'Patch') {
    $bak = "$AppPath.mousemove-original.$($sha.Substring(0, 8)).bak"
    if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $AppPath -Destination $bak }
    $bytes[$info.Index + $valueIdx] = $newValue
} else {
    $bytes[$info.Index + $valueIdx] = $oldValue
}

$tmp = "$AppPath.tmp"
[IO.File]::WriteAllBytes($tmp, $bytes)
Move-Item -LiteralPath $tmp -Destination $AppPath -Force

$after = Get-State ([IO.File]::ReadAllBytes($AppPath))
if ($Mode -eq 'Patch') {
    if ($after.State -ne 'Patched')  { throw '패치 후 검증에 실패했습니다.' }
    Write-Host '완료: 마우스 이동 이벤트 차단 적용 (변경 1바이트)'
    Write-Host "원본 백업: $bak"
} else {
    if ($after.State -ne 'Original') { throw '복원 후 검증에 실패했습니다.' }
    Write-Host '완료: 원본으로 복원했습니다.'
}

if ($wasRunning) { Start-Process -FilePath $AppPath -WorkingDirectory (Split-Path $AppPath); Write-Host 'WuwaTappo를 다시 실행했습니다.' }
