<#
  게임 스크린샷 UID 가리기 / 크롭 / 리사이즈 - PowerShell 버전 (추가 설치 불필요)

  사용법
    WWImageQuickEdit.bat 더블클릭 → 뜨는 창에 이미지(여러 장)나 폴더를 드래그&드롭
    → [이전 설정 그대로] 또는 [새로 설정] 선택 → 처리
    (bat 아이콘 위에 직접 드롭하면 마지막 설정으로 바로 처리)
  결과는 기본적으로 원본 옆 'masked' 폴더에 저장됩니다. (설정에서 저장 폴더 직접 지정 가능)
  파일명 끝에 작업 일시가 붙습니다. 예) 스샷_20261031-181700.jpg
  지원 형식: png, jpg, jpeg, bmp  /  저장: 원본 유지, PNG, JPG
#>

$ErrorActionPreference = 'Stop'
$DropArgs = @($args)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ===================== 고정 설정 =====================
# UID 영역: 4K(3840x2160) 기준 px 단위, @(가까운 쪽, 먼 쪽) 거리
#   실제 크기 배율 = min(가로/3840, 세로/2160) → 해상도·화면 비율이 달라도 같은 위치
$UidDesktopRight  = @(70, 423);   $UidDesktopBottom = @(0, 54)    # PC(16:9): 오른쪽·아래 가장자리 기준
$UidMobileRight   = @(215, 570);  $UidMobileBottom  = @(0, 75)    # 휴대폰(16:9 외 비율)
$UidCineRight     = @(47, 327);   $UidCineBottom    = @(-19, 54)  # 시네마틱: 검은 띠 제외 화면 아래 기준
$DesktopRatio     = @(1.70, 1.85) # 이 범위의 가로/세로 비율이면 PC 레이아웃, 아니면 휴대폰 레이아웃

# 시네마틱 판별: 위/아래 가장자리 평균 밝기가 이 값 이하면 검은 띠로 간주
$LetterboxBand      = 0.04
$LetterboxMaxBright = 6
$LetterboxMinRatio  = 0.03   # 띠 자동 제거 시, 띠 두께가 이 비율 이상일 때만 자름

$PixelBlock = 14             # 모자이크 블록 크기(px)
$BlurRadius = 14             # 블러 강도 (Python 버전과 같은 기준)
$FillColor  = @(0, 0, 0)     # 단색 덮기 색상 (R, G, B)
$JpgQuality = 95
$Preview    = $false         # $true: 가리지 않고 빨간 박스만 그림 (위치 확인용)

$OutDirName      = 'masked'
$AddTimestamp    = $true                # 결과 파일명 끝에 작업 일시 추가
$TimestampFormat = 'yyyyMMdd-HHmmss'    # 예) 20261031-181700
$Exts            = @('.png', '.jpg', '.jpeg', '.bmp')
$SettingsFile    = Join-Path $ScriptDir 'settings.json'
$LogFile         = Join-Path $ScriptDir 'error.log'

# 작업 옵션 기본값 (창에서 선택한 값은 SettingsFile에 저장되어 다음에 재사용)
$Defaults = [ordered]@{
    mask         = $true
    mask_mode    = 'blur'        # blur | pixelate | fill
    crop         = 'none'        # none | letterbox | custom
    crop_box     = @(0.0, 0.0, 1.0, 1.0)
    resize       = $false
    resize_width = 1920
    format       = 'original'    # original | png | jpg
    out_custom   = $false        # $true면 out_dir에 저장, $false면 원본 폴더\masked
    out_dir      = ''
}
# =====================================================

$MaskModes = [ordered]@{ blur = '블러'; pixelate = '모자이크'; fill = '단색 덮기' }
$CropModes = [ordered]@{ none = '안 함'; letterbox = '시네마틱 검은 띠 제거'; custom = '직접 지정' }
$Formats   = [ordered]@{ original = '원본 유지'; png = 'PNG'; jpg = 'JPG' }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-Error([string]$msg, [switch]$Fatal) {
    try { Set-Content -LiteralPath $LogFile -Value $msg -Encoding UTF8 } catch {}
    try { [void][System.Windows.Forms.MessageBox]::Show($msg, '이미지 간편수정 - 오류', 'OK', 'Error') }
    catch { Write-Host $msg }
    if ($Fatal) { exit 1 }
}

# ---------------- 이미지 처리 엔진 (C#, 실행 시 자동 컴파일) ----------------
$CsCode = @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class UidOpts
{
    public bool Mask = true;
    public string MaskMode = "blur";
    // UID 영역: 4K(3840x2160) 기준 px, {가까운 쪽, 먼 쪽} 거리
    public double[] DeskRight  = new double[] { 70, 423 };
    public double[] DeskBottom = new double[] { 0, 54 };
    public double[] MobRight   = new double[] { 215, 570 };
    public double[] MobBottom  = new double[] { 0, 75 };
    public double[] CineRight  = new double[] { 47, 327 };
    public double[] CineBottom = new double[] { -19, 54 };
    public double DeskRatioMin = 1.70;
    public double DeskRatioMax = 1.85;
    public int PixelBlock = 14;
    public double BlurRadius = 14;
    public int FillR = 0, FillG = 0, FillB = 0;
    public string Crop = "none";
    public double[] CropBox = new double[] { 0, 0, 1, 1 };
    public bool Resize = false;
    public int ResizeWidth = 1920;
    public long JpgQuality = 95;
    public double LbBand = 0.04;
    public double LbMaxBright = 6;
    public double LbMinRatio = 0.03;
    public bool Preview = false;
}

public static class UidImg
{
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    // 반환값: 처리 내역 토큰 (normal/mobile/cine, lb, crop, w1920)
    public static string Process(string inPath, string outPath, UidOpts o)
    {
        bool hasAlpha;
        Bitmap bmp = Load(inPath, out hasAlpha);
        List<string> notes = new List<string>();
        try
        {
            int stride;
            byte[] buf = GetBytes(bmp, out stride);
            double[] rows = RowMeans(buf, stride, bmp.Width, bmp.Height);
            bool cine = IsCinematic(rows, o);
            int[] lb = cine ? LetterboxRows(rows, bmp.Height, o) : null;
            string layout;
            Rectangle r = UidBox(bmp.Width, bmp.Height, cine, lb, o, out layout);
            notes.Add(layout);

            // 1) UID 가리기
            if (o.Mask && r.Width > 0 && r.Height > 0)
            {
                if (o.Preview)
                {
                    using (Graphics g = Graphics.FromImage(bmp))
                    using (Pen p = new Pen(Color.Red, Math.Max(2, bmp.Width / 400)))
                        g.DrawRectangle(p, r);
                }
                else
                {
                    if (o.MaskMode == "fill") Fill(buf, stride, r, o);
                    else if (o.MaskMode == "pixelate") Pixelate(buf, stride, r, Math.Max(1, o.PixelBlock));
                    else Blur(buf, stride, r, o.BlurRadius);
                    SetBytes(bmp, buf);
                }
            }

            // 2) 크롭
            if (o.Crop == "letterbox")
            {
                if (lb != null)
                {
                    bmp = Swap(bmp, bmp.Clone(new Rectangle(0, lb[0], bmp.Width, lb[1] - lb[0]), PixelFormat.Format32bppArgb));
                    notes.Add("lb");
                }
            }
            else if (o.Crop == "custom")
            {
                Rectangle c = RatioBox(bmp.Width, bmp.Height, o.CropBox);
                if (c.Width > 0 && c.Height > 0)
                {
                    bmp = Swap(bmp, bmp.Clone(c, PixelFormat.Format32bppArgb));
                    notes.Add("crop");
                }
            }

            // 3) 리사이즈 (확대는 안 함)
            if (o.Resize && o.ResizeWidth > 0 && bmp.Width > o.ResizeWidth)
            {
                int nw = o.ResizeWidth;
                int nh = Math.Max(1, (int)Math.Round(bmp.Height * (double)nw / bmp.Width));
                bmp = Swap(bmp, ResizeHQ(bmp, nw, nh));
                notes.Add("w" + nw);
            }

            Save(bmp, outPath, o.JpgQuality, hasAlpha);
        }
        finally
        {
            bmp.Dispose();
        }
        return string.Join(",", notes.ToArray());
    }

    // UID 영역 계산: 크기 배율 = min(가로/3840, 세로/2160), 오른쪽·아래 가장자리 기준
    static Rectangle UidBox(int w, int h, bool cine, int[] lb, UidOpts o, out string layout)
    {
        double s, edge;
        double[] rr, bb;
        if (cine)
        {
            int top = lb != null ? lb[0] : 0, bottom = lb != null ? lb[1] : h;
            s = Math.Min(w / 3840.0, (bottom - top) / 1620.0);
            rr = o.CineRight; bb = o.CineBottom; edge = bottom; layout = "cine";
        }
        else
        {
            double ratio = (double)w / h;
            bool mobile = ratio < o.DeskRatioMin || ratio > o.DeskRatioMax;
            s = Math.Min(w / 3840.0, h / 2160.0);
            rr = mobile ? o.MobRight : o.DeskRight;
            bb = mobile ? o.MobBottom : o.DeskBottom;
            edge = h; layout = mobile ? "mobile" : "normal";
        }
        int l = Clamp((int)(w - rr[1] * s), 0, w);
        int t = Clamp((int)(edge - bb[1] * s), 0, h);
        int r = Clamp((int)Math.Ceiling(w - rr[0] * s), 0, w);
        int b = Clamp((int)Math.Ceiling(edge - bb[0] * s), 0, h);
        return new Rectangle(l, t, Math.Max(0, r - l), Math.Max(0, b - t));
    }

    static Bitmap Swap(Bitmap oldBmp, Bitmap newBmp)
    {
        oldBmp.Dispose();
        return newBmp;
    }

    static int Clamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

    static Bitmap Load(string path, out bool hasAlpha)
    {
        byte[] data = File.ReadAllBytes(path);   // 파일 잠금 방지
        using (MemoryStream ms = new MemoryStream(data))
        using (Image src = Image.FromStream(ms, false, true))
        {
            hasAlpha = Image.IsAlphaPixelFormat(src.PixelFormat);
            Bitmap bmp = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.CompositingMode = CompositingMode.SourceCopy;
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.DrawImage(src, new Rectangle(0, 0, src.Width, src.Height), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel);
            }
            return bmp;
        }
    }

    static byte[] GetBytes(Bitmap b, out int stride)
    {
        BitmapData d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        stride = d.Stride;
        byte[] buf = new byte[stride * b.Height];
        Marshal.Copy(d.Scan0, buf, 0, buf.Length);
        b.UnlockBits(d);
        return buf;
    }

    static void SetBytes(Bitmap b, byte[] buf)
    {
        BitmapData d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(buf, 0, d.Scan0, buf.Length);
        b.UnlockBits(d);
    }

    static Rectangle RatioBox(int w, int h, double[] b)
    {
        int l = Clamp((int)(w * b[0]), 0, w);
        int t = Clamp((int)(h * b[1]), 0, h);
        int r = Clamp((int)(w * b[2]), 0, w);
        int btm = Clamp((int)(h * b[3]), 0, h);
        return new Rectangle(l, t, Math.Max(0, r - l), Math.Max(0, btm - t));
    }

    // 각 행의 평균 밝기 (ITU-R 601 휘도)
    static double[] RowMeans(byte[] buf, int stride, int w, int h)
    {
        double[] m = new double[h];
        for (int y = 0; y < h; y++)
        {
            long s = 0;
            int k = y * stride;
            for (int x = 0; x < w; x++, k += 4)
                s += buf[k + 2] * 299 + buf[k + 1] * 587 + buf[k] * 114;
            m[y] = s / 1000.0 / w;
        }
        return m;
    }

    static bool IsCinematic(double[] rows, UidOpts o)
    {
        int h = rows.Length;
        int band = Math.Max(1, (int)(h * o.LbBand));
        double top = 0, bottom = 0;
        for (int i = 0; i < band; i++) { top += rows[i]; bottom += rows[h - 1 - i]; }
        return top / band <= o.LbMaxBright && bottom / band <= o.LbMaxBright;
    }

    static int[] LetterboxRows(double[] rows, int h, UidOpts o)
    {
        int top = -1, bottom = -1;
        for (int y = 0; y < h; y++) if (rows[y] > o.LbMaxBright) { top = y; break; }
        if (top < 0) return null;
        for (int y = h - 1; y >= 0; y--) if (rows[y] > o.LbMaxBright) { bottom = y + 1; break; }
        if (top < h * o.LbMinRatio && (h - bottom) < h * o.LbMinRatio) return null;
        return new int[] { top, bottom };
    }

    static void Fill(byte[] buf, int stride, Rectangle r, UidOpts o)
    {
        for (int y = r.Top; y < r.Bottom; y++)
            for (int x = r.Left; x < r.Right; x++)
            {
                int k = y * stride + x * 4;
                buf[k] = (byte)o.FillB; buf[k + 1] = (byte)o.FillG; buf[k + 2] = (byte)o.FillR; buf[k + 3] = 255;
            }
    }

    // 영역을 block 크기 칸으로 평균 낸 뒤 칸 단위로 채움 (Pillow BOX 축소 + NEAREST 확대와 동일 원리)
    static void Pixelate(byte[] buf, int stride, Rectangle r, int block)
    {
        int w = r.Width, h = r.Height;
        int sw = Math.Max(1, w / block), sh = Math.Max(1, h / block);
        byte[] cells = new byte[sw * sh * 4];
        for (int j = 0; j < sh; j++)
        {
            int y0 = r.Y + j * h / sh, y1 = r.Y + (j + 1) * h / sh;
            for (int i = 0; i < sw; i++)
            {
                int x0 = r.X + i * w / sw, x1 = r.X + (i + 1) * w / sw;
                long s0 = 0, s1 = 0, s2 = 0, s3 = 0; int n = 0;
                for (int y = y0; y < y1; y++)
                    for (int x = x0; x < x1; x++)
                    {
                        int k = y * stride + x * 4;
                        s0 += buf[k]; s1 += buf[k + 1]; s2 += buf[k + 2]; s3 += buf[k + 3]; n++;
                    }
                if (n == 0) n = 1;
                int ci = (j * sw + i) * 4;
                cells[ci] = (byte)((s0 + n / 2) / n); cells[ci + 1] = (byte)((s1 + n / 2) / n);
                cells[ci + 2] = (byte)((s2 + n / 2) / n); cells[ci + 3] = (byte)((s3 + n / 2) / n);
            }
        }
        // NEAREST 확대 (Pillow와 같은 좌표 매핑)
        for (int y = 0; y < h; y++)
        {
            int j = Math.Min(sh - 1, (int)((y + 0.5) * sh / h));
            for (int x = 0; x < w; x++)
            {
                int i = Math.Min(sw - 1, (int)((x + 0.5) * sw / w));
                int ci = (j * sw + i) * 4, k = (r.Y + y) * stride + (r.X + x) * 4;
                buf[k] = cells[ci]; buf[k + 1] = cells[ci + 1]; buf[k + 2] = cells[ci + 2]; buf[k + 3] = cells[ci + 3];
            }
        }
    }

    // 가우시안 블러: Pillow와 같은 방식 (확장 박스 블러 3회, 가로→세로, 가장자리 반복)
    static void Blur(byte[] buf, int stride, Rectangle r, double sigma)
    {
        if (sigma <= 0) return;
        int w = r.Width, h = r.Height;
        const int passes = 3;
        double s2 = sigma * sigma / passes;
        double L = Math.Sqrt(12.0 * s2 + 1.0);
        int l = (int)Math.Floor((L - 1.0) / 2.0);
        double a = (2 * l + 1) * (l * (l + 1) - 3 * s2) / (6 * (s2 - (l + 1) * (l + 1)));

        int n = Math.Max(w, h);
        double[] line = new double[n], outl = new double[n];
        double[] p = new double[w * h];
        for (int c = 0; c < 4; c++)
        {
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                    p[y * w + x] = buf[(r.Y + y) * stride + (r.X + x) * 4 + c];

            for (int pass = 0; pass < passes; pass++)
                for (int y = 0; y < h; y++)
                {
                    for (int x = 0; x < w; x++) line[x] = p[y * w + x];
                    Box1D(line, outl, w, l, a);
                    for (int x = 0; x < w; x++) p[y * w + x] = outl[x];
                }
            for (int pass = 0; pass < passes; pass++)
                for (int x = 0; x < w; x++)
                {
                    for (int y = 0; y < h; y++) line[y] = p[y * w + x];
                    Box1D(line, outl, h, l, a);
                    for (int y = 0; y < h; y++) p[y * w + x] = outl[y];
                }

            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    double v = Math.Round(p[y * w + x]);
                    buf[(r.Y + y) * stride + (r.X + x) * 4 + c] = (byte)(v < 0 ? 0 : (v > 255 ? 255 : v));
                }
        }
    }

    static void Box1D(double[] src, double[] dst, int n, int l, double a)
    {
        double norm = 1.0 / (2 * l + 1 + 2 * a);
        int last = n - 1;
        for (int i = 0; i < n; i++)
        {
            double s = 0;
            for (int k = -l; k <= l; k++) s += src[Clamp(i + k, 0, last)];
            s += a * (src[Clamp(i - l - 1, 0, last)] + src[Clamp(i + l + 1, 0, last)]);
            dst[i] = s * norm;
        }
    }

    static Bitmap ResizeHQ(Bitmap src, int nw, int nh)
    {
        Bitmap dst = new Bitmap(nw, nh, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(dst))
        using (ImageAttributes ia = new ImageAttributes())
        {
            g.CompositingMode = CompositingMode.SourceCopy;
            g.CompositingQuality = CompositingQuality.HighQuality;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.SmoothingMode = SmoothingMode.HighQuality;
            ia.SetWrapMode(WrapMode.TileFlipXY);   // 가장자리 어두워짐 방지
            g.DrawImage(src, new Rectangle(0, 0, nw, nh), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel, ia);
        }
        return dst;
    }

    static Bitmap To24(Bitmap src)
    {
        return src.Clone(new Rectangle(0, 0, src.Width, src.Height), PixelFormat.Format24bppRgb);
    }

    static void Save(Bitmap bmp, string path, long quality, bool hasAlpha)
    {
        string ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext == ".jpg" || ext == ".jpeg")
        {
            ImageCodecInfo codec = null;
            foreach (ImageCodecInfo ci in ImageCodecInfo.GetImageEncoders())
                if (ci.FormatID == ImageFormat.Jpeg.Guid) codec = ci;
            using (Bitmap rgb = To24(bmp))
            using (EncoderParameters ep = new EncoderParameters(1))
            {
                ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
                rgb.Save(path, codec, ep);
            }
        }
        else if (ext == ".bmp")
        {
            using (Bitmap rgb = To24(bmp)) rgb.Save(path, ImageFormat.Bmp);
        }
        else
        {
            if (hasAlpha) bmp.Save(path, ImageFormat.Png);
            else using (Bitmap rgb = To24(bmp)) rgb.Save(path, ImageFormat.Png);
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $CsCode -ReferencedAssemblies System.Drawing -Language CSharp
} catch {
    Show-Error ("이미지 처리 모듈을 준비하지 못했습니다.`r`n`r`n" + $_.Exception.Message) -Fatal
}

# ---------------- 설정 저장/불러오기 ----------------
function Copy-Opts($src) {
    $n = [ordered]@{}
    foreach ($k in @($src.Keys)) {
        $v = $src[$k]
        if ($v -is [array]) { $v = @($v) }
        $n[$k] = $v
    }
    return $n
}

function Load-Opts {
    if (-not (Test-Path -LiteralPath $SettingsFile)) { return $null }
    try {
        $j = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $o = Copy-Opts $Defaults
        $names = @($j.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($k in @($o.Keys)) { if ($names -contains $k) { $o[$k] = $j.$k } }
        $o['mask']         = [bool]$o['mask']
        $o['resize']       = [bool]$o['resize']
        $o['out_custom']   = [bool]$o['out_custom']
        $o['resize_width'] = [int]$o['resize_width']
        $o['out_dir']      = [string]$o['out_dir']
        $o['crop_box']     = [double[]]@($o['crop_box'])
        if ($o['crop_box'].Count -ne 4) { $o['crop_box'] = [double[]]@(0, 0, 1, 1) }
        if (-not $MaskModes.Contains([string]$o['mask_mode'])) { $o['mask_mode'] = $Defaults['mask_mode'] }
        if (-not $CropModes.Contains([string]$o['crop']))      { $o['crop'] = 'none' }
        if (-not $Formats.Contains([string]$o['format']))      { $o['format'] = 'original' }
        return $o
    } catch { return $null }
}

function Save-Opts($o) {
    try { ($o | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $SettingsFile -Encoding UTF8 } catch {}
}

function Use-CustomOut($o) {
    return [bool]($o['out_custom'] -and ([string]$o['out_dir']).Trim())
}

function Get-Desc($o) {
    $l = New-Object System.Collections.Generic.List[string]
    if ($o['mask']) { $l.Add('가리기: ' + $MaskModes[[string]$o['mask_mode']]) } else { $l.Add('가리기: 안 함') }
    if ($o['crop'] -eq 'custom') {
        $l.Add('크롭: 직접 지정 ' + ((@($o['crop_box']) | ForEach-Object { '{0:g}' -f $_ }) -join ', '))
    } else { $l.Add('크롭: ' + $CropModes[[string]$o['crop']]) }
    if ($o['resize']) { $l.Add('리사이즈: 가로 ' + $o['resize_width'] + 'px') } else { $l.Add('리사이즈: 안 함') }
    $l.Add('포맷: ' + $Formats[[string]$o['format']])
    if (Use-CustomOut $o) { $l.Add('저장: ' + ([string]$o['out_dir']).Trim()) } else { $l.Add("저장: 원본 폴더\$OutDirName") }
    return ,$l.ToArray()
}

# ---------------- 일괄 처리 ----------------
function Write-Log([string]$m) {
    if ($script:LogBox) {
        $script:LogBox.AppendText($m + "`r`n")
        [System.Windows.Forms.Application]::DoEvents()
    } else { Write-Host $m }
}

function Get-Files($paths) {
    $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($p in $paths) {
        if ([System.IO.Directory]::Exists($p)) {
            Get-ChildItem -LiteralPath $p -File |
                Where-Object { $Exts -contains $_.Extension.ToLower() } |
                Sort-Object Name |
                ForEach-Object { $list.Add($_) }
        } elseif ([System.IO.File]::Exists($p)) {
            $fi = New-Object System.IO.FileInfo -ArgumentList $p
            if ($Exts -contains $fi.Extension.ToLower()) { $list.Add($fi) }
        }
    }
    return ,$list.ToArray()
}

function New-CsOpts($o) {
    $c = New-Object UidOpts
    $c.Mask         = [bool]$o['mask']
    $c.MaskMode     = [string]$o['mask_mode']
    $c.DeskRight    = [double[]]$UidDesktopRight
    $c.DeskBottom   = [double[]]$UidDesktopBottom
    $c.MobRight     = [double[]]$UidMobileRight
    $c.MobBottom    = [double[]]$UidMobileBottom
    $c.CineRight    = [double[]]$UidCineRight
    $c.CineBottom   = [double[]]$UidCineBottom
    $c.DeskRatioMin = [double]$DesktopRatio[0]
    $c.DeskRatioMax = [double]$DesktopRatio[1]
    $c.PixelBlock   = [int]$PixelBlock
    $c.BlurRadius   = [double]$BlurRadius
    $c.FillR = [int]$FillColor[0]; $c.FillG = [int]$FillColor[1]; $c.FillB = [int]$FillColor[2]
    $c.Crop         = [string]$o['crop']
    $c.CropBox      = [double[]]@($o['crop_box'])
    $c.Resize       = [bool]$o['resize']
    $c.ResizeWidth  = [int]$o['resize_width']
    $c.JpgQuality   = [long]$JpgQuality
    $c.LbBand       = [double]$LetterboxBand
    $c.LbMaxBright  = [double]$LetterboxMaxBright
    $c.LbMinRatio   = [double]$LetterboxMinRatio
    $c.Preview      = [bool]$Preview
    return $c
}

function Convert-Notes([string]$tokens) {
    $out = foreach ($t in ($tokens -split ',')) {
        switch -Regex ($t) {
            '^cine$'   { '시네마틱' }
            '^normal$' { '일반' }
            '^mobile$' { '휴대폰' }
            '^lb$'     { '띠 제거' }
            '^crop$'   { '크롭' }
            '^w(\d+)$' { $Matches[1] + 'px' }
        }
    }
    return (@($out) -join ', ')
}

# 파일명 끝에 작업 일시를 붙이고, 그래도 겹치면 _2, _3 …을 덧붙임
function Get-OutputPath([string]$outDir, [string]$stem, [string]$ext) {
    $base = $stem
    if ($AddTimestamp) { $base = $stem + '_' + (Get-Date -Format $TimestampFormat) }
    $out = [System.IO.Path]::Combine($outDir, $base + $ext)
    $k = 2
    while ([System.IO.File]::Exists($out)) {
        $out = [System.IO.Path]::Combine($outDir, $base + '_' + $k + $ext)
        $k++
    }
    return $out
}

function Invoke-Batch($paths, $o) {
    $files = Get-Files $paths
    if ($files.Count -eq 0) {
        Write-Log '처리할 이미지가 없습니다. (지원 형식: png, jpg, jpeg, bmp)'
        return
    }
    $cs = New-CsOpts $o
    $n = $files.Count; $i = 0; $ok = 0
    foreach ($f in $files) {
        $i++
        try {
            $ext = if ($o['format'] -eq 'original') { $f.Extension.ToLower() } else { '.' + $o['format'] }
            if (Use-CustomOut $o) { $outDir = ([string]$o['out_dir']).Trim() }
            else { $outDir = [System.IO.Path]::Combine($f.DirectoryName, $OutDirName) }
            [void][System.IO.Directory]::CreateDirectory($outDir)
            $out = Get-OutputPath $outDir $f.BaseName $ext
            $note = Convert-Notes ([UidImg]::Process($f.FullName, $out, $cs))
            $ok++
            $shown = (Split-Path -Leaf $outDir) + '\' + (Split-Path -Leaf $out)
            Write-Log ('[{0}/{1}] OK  {2} ({3}) -> {4}' -f $i, $n, $f.Name, $note, $shown)
        } catch {
            $e = $_.Exception
            while ($e.InnerException) { $e = $e.InnerException }
            Write-Log ('[{0}/{1}] 실패  {2}: {3}' -f $i, $n, $f.Name, $e.Message)
        }
    }
    Write-Log ("완료: {0}/{1}장`r`n" -f $ok, $n)
}

# ---------------- GUI 도우미 ----------------
function P([double]$v) { return [int][Math]::Round($v * $script:Scale) }

function New-Pad([int]$l, [int]$t = -1, [int]$r = -1, [int]$b = -1) {
    if ($t -lt 0) { return New-Object System.Windows.Forms.Padding -ArgumentList $l }
    return New-Object System.Windows.Forms.Padding -ArgumentList $l, $t, $r, $b
}

function New-Flow([string]$dir = 'LeftToRight') {
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.FlowDirection = $dir
    $p.WrapContents  = $false
    $p.AutoSize      = $true
    $p.AutoSizeMode  = 'GrowAndShrink'
    $p.Margin        = New-Pad 0
    return $p
}

function New-Label([string]$text) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $text; $c.AutoSize = $true; $c.Anchor = 'Left'
    $c.Margin = New-Pad (P 3) (P 5) (P 3) (P 5)
    return $c
}

function New-Hint([string]$text) {
    $c = New-Label $text
    $c.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
    $c.Margin = New-Pad (P 3) (P 1) (P 3) (P 1)
    return $c
}

function New-Check([string]$text, [bool]$checked) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text; $c.Checked = $checked; $c.AutoSize = $true; $c.Anchor = 'Left'
    $c.Margin = New-Pad (P 3) (P 4) (P 10) (P 4)
    return $c
}

function New-Radio([string]$text, [bool]$checked) {
    $c = New-Object System.Windows.Forms.RadioButton
    $c.Text = $text; $c.Checked = $checked; $c.AutoSize = $true; $c.Anchor = 'Left'
    $c.Margin = New-Pad (P 3) (P 4) (P 10) (P 4)
    return $c
}

function New-Button([string]$text) {
    $c = New-Object System.Windows.Forms.Button
    $c.Text = $text; $c.AutoSize = $true; $c.Anchor = 'Left'
    $c.MinimumSize = New-Object System.Drawing.Size -ArgumentList (P 84), (P 30)
    $c.Padding = New-Pad (P 6) 0 (P 6) 0
    $c.Margin  = New-Pad 0 (P 4) (P 8) (P 4)
    return $c
}

function New-Group([string]$text, $inner) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $text
    $g.AutoSize = $true; $g.AutoSizeMode = 'GrowAndShrink'
    $g.Padding = New-Pad (P 8) (P 4) (P 8) (P 8)
    $g.Margin  = New-Pad 0 0 0 (P 8)
    $g.MinimumSize = New-Object System.Drawing.Size -ArgumentList (P 520), 0
    $inner.Location = New-Object System.Drawing.Point -ArgumentList (P 10), ([int]($script:Font.Height * 1.4))
    $g.Controls.Add($inner)
    return $g
}

function New-Dialog([string]$title) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title
    $d.Font = $script:Font
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
    $d.StartPosition = 'CenterParent'
    $d.TopMost = $true
    $d.AutoSize = $true; $d.AutoSizeMode = 'GrowAndShrink'
    $d.Padding = New-Pad (P 12)
    return $d
}

function Show-Warn([string]$msg) {
    [void][System.Windows.Forms.MessageBox]::Show($script:SD.Form, $msg, '입력 확인', 'OK', 'Warning')
}

# ---------------- 선택지: 이전 설정 사용 vs 새로 설정 ----------------
function Show-ChoiceDialog($prev, [int]$count) {
    $d = New-Dialog '작업 선택'
    $root = New-Flow 'TopDown'

    $h = New-Label "${count}개 항목을 받았습니다. 어떻게 처리할까요?"
    $h.Font = New-Object System.Drawing.Font -ArgumentList 'Malgun Gothic', 10.5, ([System.Drawing.FontStyle]::Bold)
    $h.Margin = New-Pad 0 0 0 (P 8)
    $root.Controls.Add($h)

    $desc = New-Label ((Get-Desc $prev) -join "`r`n")
    $root.Controls.Add((New-Group ' 이전 설정 ' $desc))

    $btns = New-Flow
    $b1 = New-Button '① 이전 설정 그대로'; $b1.DialogResult = 'Yes'
    $b2 = New-Button '② 새로 설정';       $b2.DialogResult = 'No'
    $b3 = New-Button '취소';              $b3.DialogResult = 'Cancel'
    $btns.Controls.Add($b1); $btns.Controls.Add($b2); $btns.Controls.Add($b3)
    $root.Controls.Add($btns)

    $d.Controls.Add($root)
    $d.AcceptButton = $b1
    $d.CancelButton = $b3
    $r = $d.ShowDialog($script:Main)
    $d.Dispose()
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { return 'prev' }
    if ($r -eq [System.Windows.Forms.DialogResult]::No)  { return 'new' }
    return 'cancel'
}

# ---------------- 작업 설정 창 ----------------
function Update-SettingsState {
    $sd = $script:SD
    foreach ($rb in $sd.MaskRadios.Values) { $rb.Enabled = $sd.MaskCheck.Checked }
    $custom = $sd.CropRadios['custom'].Checked
    foreach ($tb in $sd.BoxTexts) { $tb.Enabled = $custom }
    $sd.Combo.Enabled  = $sd.ResizeCheck.Checked
    $sd.OutBox.Enabled = $sd.OutCheck.Checked
}

function Confirm-Settings {
    $sd = $script:SD
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $box = New-Object System.Collections.Generic.List[double]
    foreach ($tb in $sd.BoxTexts) {
        $v = 0.0
        if (-not [double]::TryParse($tb.Text.Trim(), [System.Globalization.NumberStyles]::Float, $inv, [ref]$v)) {
            Show-Warn '크롭 비율에는 숫자를 입력해 주세요.'; return
        }
        $box.Add($v)
    }
    $w = 0
    if (-not [int]::TryParse($sd.Combo.Text.Trim(), [ref]$w)) { Show-Warn '리사이즈 가로 값은 숫자로 입력해 주세요.'; return }

    $mode = 'blur'; foreach ($k in $sd.MaskRadios.Keys) { if ($sd.MaskRadios[$k].Checked) { $mode = $k } }
    $crop = 'none'; foreach ($k in $sd.CropRadios.Keys) { if ($sd.CropRadios[$k].Checked) { $crop = $k } }
    $fmt  = 'original'; foreach ($k in $sd.FmtRadios.Keys) { if ($sd.FmtRadios[$k].Checked) { $fmt = $k } }

    if ($crop -eq 'custom') {
        $l = $box[0]; $t = $box[1]; $r = $box[2]; $b = $box[3]
        if (-not (0 -le $l -and $l -lt $r -and $r -le 1 -and 0 -le $t -and $t -lt $b -and $b -le 1)) {
            Show-Warn '크롭 비율은 0~1 사이, 왼쪽<오른쪽, 위<아래여야 해요.'; return
        }
    }
    if ($sd.ResizeCheck.Checked -and $w -lt 16) { Show-Warn '리사이즈 가로 값이 너무 작아요.'; return }

    $outDir = $sd.OutBox.Text.Trim()
    if ($sd.OutCheck.Checked) {
        if (-not $outDir) { Show-Warn '저장 폴더를 지정해 주세요.'; return }
        if (-not [System.IO.Path]::IsPathRooted($outDir)) {
            Show-Warn "저장 폴더는 전체 경로로 지정해 주세요.`r`n(예: D:\Screenshots\masked)"; return
        }
    }

    $o = [ordered]@{
        mask         = $sd.MaskCheck.Checked
        mask_mode    = $mode
        crop         = $crop
        crop_box     = [double[]]$box.ToArray()
        resize       = $sd.ResizeCheck.Checked
        resize_width = $w
        format       = $fmt
        out_custom   = $sd.OutCheck.Checked
        out_dir      = $outDir
    }
    if (-not ($o.mask -or $o.crop -ne 'none' -or $o.resize -or $o.format -ne 'original')) {
        Show-Warn '선택된 작업이 없어요.'; return
    }
    $sd.Result = $o
    $sd.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
}

function Show-SettingsDialog($base) {
    $script:SD = @{ Result = $null }
    $sd = $script:SD
    $d = New-Dialog '작업 설정'
    $sd.Form = $d
    $root = New-Flow 'TopDown'
    $onChange = { Update-SettingsState }

    # UID 가리기
    $row = New-Flow
    $sd.MaskCheck = New-Check '사용' ([bool]$base['mask'])
    $sd.MaskCheck.add_CheckedChanged($onChange)
    $row.Controls.Add($sd.MaskCheck)
    $sd.MaskRadios = [ordered]@{}
    foreach ($k in $MaskModes.Keys) {
        $rb = New-Radio $MaskModes[$k] ($base['mask_mode'] -eq $k)
        $row.Controls.Add($rb); $sd.MaskRadios[$k] = $rb
    }
    $root.Controls.Add((New-Group ' UID 가리기 ' $row))

    # 크롭
    $col = New-Flow 'TopDown'
    $r1 = New-Flow
    $sd.CropRadios = [ordered]@{}
    foreach ($k in $CropModes.Keys) {
        $rb = New-Radio $CropModes[$k] ($base['crop'] -eq $k)
        $rb.add_CheckedChanged($onChange)
        $r1.Controls.Add($rb); $sd.CropRadios[$k] = $rb
    }
    $col.Controls.Add($r1)
    $r2 = New-Flow
    $sd.BoxTexts = New-Object System.Collections.Generic.List[object]
    $names = @('왼쪽', '위', '오른쪽', '아래')
    for ($i = 0; $i -lt 4; $i++) {
        $r2.Controls.Add((New-Label $names[$i]))
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Width = P 52; $tb.Anchor = 'Left'
        $tb.Margin = New-Pad 0 (P 3) (P 10) (P 3)
        $tb.Text = ([double]@($base['crop_box'])[$i]).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $r2.Controls.Add($tb); $sd.BoxTexts.Add($tb)
    }
    $col.Controls.Add($r2)
    $col.Controls.Add((New-Hint '직접 지정은 0~1 비율 (예: 왼쪽 0.25, 오른쪽 0.75 → 가운데 절반)'))
    $col.Controls.Add((New-Hint '띠 제거는 시네마틱으로 판별된 이미지에만 적용돼요'))
    $root.Controls.Add((New-Group ' 크롭 ' $col))

    # 리사이즈
    $row = New-Flow
    $sd.ResizeCheck = New-Check '사용    가로' ([bool]$base['resize'])
    $sd.ResizeCheck.Margin = New-Pad (P 3) (P 4) (P 4) (P 4)
    $sd.ResizeCheck.add_CheckedChanged($onChange)
    $sd.Combo = New-Object System.Windows.Forms.ComboBox
    $sd.Combo.DropDownStyle = 'DropDown'; $sd.Combo.Width = P 80; $sd.Combo.Anchor = 'Left'
    foreach ($v in @('3840', '2560', '1920', '1600', '1280')) { [void]$sd.Combo.Items.Add($v) }
    $sd.Combo.Text = [string]$base['resize_width']
    $row.Controls.Add($sd.ResizeCheck); $row.Controls.Add($sd.Combo)
    $row.Controls.Add((New-Label 'px (비율 유지, 확대는 안 함)'))
    $root.Controls.Add((New-Group ' 리사이즈 ' $row))

    # 저장 포맷
    $row = New-Flow
    $sd.FmtRadios = [ordered]@{}
    foreach ($k in $Formats.Keys) {
        $rb = New-Radio $Formats[$k] ($base['format'] -eq $k)
        $row.Controls.Add($rb); $sd.FmtRadios[$k] = $rb
    }
    $root.Controls.Add((New-Group ' 저장 포맷 ' $row))

    # 저장 위치
    $col = New-Flow 'TopDown'
    $sd.OutCheck = New-Check "직접 지정  (해제 시 원본 폴더 안 '$OutDirName' 폴더에 저장)" ([bool]$base['out_custom'])
    $sd.OutCheck.add_CheckedChanged($onChange)
    $col.Controls.Add($sd.OutCheck)
    $row = New-Flow
    $sd.OutBox = New-Object System.Windows.Forms.TextBox
    $sd.OutBox.Width = P 380; $sd.OutBox.Anchor = 'Left'
    $sd.OutBox.Margin = New-Pad (P 3) (P 3) (P 6) (P 3)
    $sd.OutBox.Text = [string]$base['out_dir']
    $browse = New-Button '찾아보기…'
    $browse.add_Click({
        $s = $script:SD
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = '결과를 저장할 폴더를 선택하세요'
        $cur = $s.OutBox.Text.Trim()
        if ($cur -and [System.IO.Directory]::Exists($cur)) { $fb.SelectedPath = $cur }
        if ($fb.ShowDialog($s.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $s.OutBox.Text = $fb.SelectedPath
            $s.OutCheck.Checked = $true
        }
        $fb.Dispose()
    })
    $row.Controls.Add($sd.OutBox); $row.Controls.Add($browse)
    $col.Controls.Add($row)
    $root.Controls.Add((New-Group ' 저장 위치 ' $col))

    # 버튼
    $btns = New-Flow
    $ok = New-Button '이 설정으로 실행'
    $ok.add_Click({ Confirm-Settings })
    $cancel = New-Button '취소'; $cancel.DialogResult = 'Cancel'
    $btns.Controls.Add($ok); $btns.Controls.Add($cancel)
    $root.Controls.Add($btns)

    $d.Controls.Add($root)
    $d.CancelButton = $cancel
    Update-SettingsState
    $r = $d.ShowDialog($script:Main)
    $d.Dispose()
    if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return $sd.Result }
    return $null
}

# ---------------- 드롭 처리 흐름 ----------------
function Start-Work($paths) {
    $prev = Load-Opts
    $o = $null
    if ($prev) {
        $c = Show-ChoiceDialog $prev $paths.Count
        if ($c -eq 'cancel') { return }
        if ($c -eq 'prev') { $o = $prev } else { $o = Show-SettingsDialog $prev }
    } else {
        $o = Show-SettingsDialog (Copy-Opts $Defaults)
    }
    if ($null -eq $o) { return }
    Save-Opts $o

    $p0 = [string]$paths[0]
    if (Use-CustomOut $o) { $script:LastOut = ([string]$o['out_dir']).Trim() }
    elseif ([System.IO.Directory]::Exists($p0)) { $script:LastOut = [System.IO.Path]::Combine($p0, $OutDirName) }
    else { $script:LastOut = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($p0), $OutDirName) }

    $script:Zone.Text = '처리 중…'
    $script:Zone.BackColor = $script:ColBusy
    Write-Log ('설정: ' + ((Get-Desc $o) -join ' · '))
    Invoke-Batch $paths $o
}

# ---------------- 메인 창 ----------------
function Start-Gui {
    try { [void][UidImg]::SetProcessDPIAware() } catch {}
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = $gfx.DpiX / 96.0
    $gfx.Dispose()
    $script:Font    = New-Object System.Drawing.Font -ArgumentList 'Malgun Gothic', 9.5
    $script:ColIdle  = [System.Drawing.Color]::FromArgb(43, 47, 54)
    $script:ColHover = [System.Drawing.Color]::FromArgb(54, 80, 110)
    $script:ColBusy  = [System.Drawing.Color]::FromArgb(61, 74, 92)
    $script:IdleText = '여기에 이미지 / 폴더를 드롭하세요'
    $script:Busy = $false
    $script:LastOut = $null

    $f = New-Object System.Windows.Forms.Form
    $f.Text = '명조 이미지 간편수정'
    $f.Font = $script:Font
    $f.ClientSize  = New-Object System.Drawing.Size -ArgumentList (P 560), (P 460)
    $f.MinimumSize = New-Object System.Drawing.Size -ArgumentList (P 380), (P 320)
    $f.StartPosition = 'CenterScreen'
    $f.TopMost = $true
    $f.Padding = New-Pad (P 10)
    $script:Main = $f

    $zone = New-Object System.Windows.Forms.Label
    $zone.Text = $script:IdleText
    $zone.TextAlign = 'MiddleCenter'
    $zone.Dock = 'Fill'
    $zone.Font = New-Object System.Drawing.Font -ArgumentList 'Malgun Gothic', 14
    $zone.BackColor = $script:ColIdle
    $zone.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
    $zone.BorderStyle = 'FixedSingle'
    $zone.AllowDrop = $true
    $script:Zone = $zone

    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.Dock = 'Bottom'; $spacer.Height = P 10

    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.WordWrap = $false
    $log.Dock = 'Bottom'; $log.Height = P 160
    $log.Font = New-Object System.Drawing.Font -ArgumentList 'Malgun Gothic', 9
    $log.BackColor = [System.Drawing.SystemColors]::Window
    $script:LogBox = $log

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'; $top.Height = P 40
    $top.Padding = New-Pad 0 0 0 (P 8)
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = '항상 위'; $chk.Checked = $true; $chk.AutoSize = $true; $chk.Dock = 'Left'
    $chk.add_CheckedChanged({ $script:Main.TopMost = $script:TopChk.Checked })
    $script:TopChk = $chk
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = '결과 폴더 열기'; $btn.AutoSize = $true; $btn.Dock = 'Right'
    $btn.add_Click({
        $p = $script:LastOut
        if ($p -and [System.IO.Directory]::Exists($p)) { [void][System.Diagnostics.Process]::Start('explorer.exe', '"' + $p + '"') }
        else { Write-Log '아직 처리한 결과 폴더가 없습니다.' }
    })
    $top.Controls.Add($chk); $top.Controls.Add($btn)

    # 도킹은 나중에 추가한 컨트롤부터 적용됨
    $f.Controls.Add($zone); $f.Controls.Add($spacer); $f.Controls.Add($log); $f.Controls.Add($top)

    $zone.add_DragEnter({
        param($s, $e)
        if (-not $script:Busy -and $e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
            $script:Zone.BackColor = $script:ColHover
        } else { $e.Effect = [System.Windows.Forms.DragDropEffects]::None }
    })
    $zone.add_DragLeave({ if (-not $script:Busy) { $script:Zone.BackColor = $script:ColIdle } })
    $zone.add_DragDrop({
        param($s, $e)
        $script:Zone.BackColor = $script:ColIdle
        if ($script:Busy) { Write-Log '처리 중입니다. 끝난 뒤 다시 드롭해 주세요.'; return }
        $script:Pending = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
        if ($script:Pending.Count -eq 0) { return }
        $script:Busy = $true
        $script:DropTimer.Start()   # 드롭 이벤트가 끝난 뒤 대화상자를 띄움 (탐색기 멈춤 방지)
    })

    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 60
    $t.add_Tick({
        $script:DropTimer.Stop()
        try { Start-Work $script:Pending }
        catch { Show-Error ("처리 중 오류가 발생했습니다.`r`n`r`n" + ($_ | Out-String)) }
        finally {
            $script:Busy = $false
            $script:Zone.Text = $script:IdleText
            $script:Zone.BackColor = $script:ColIdle
        }
    })
    $script:DropTimer = $t

    $msg = '준비 완료.'
    if ($Preview) { $msg += ' [미리보기 모드: 빨간 박스만 표시]' }
    Write-Log $msg
    [System.Windows.Forms.Application]::Run($f)
}

# ---------------- 시작 ----------------
try {
    if ($DropArgs.Count -gt 0) {
        # bat 아이콘에 직접 드롭 → 마지막 설정(없으면 기본값)으로 바로 처리
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
        $o = Load-Opts
        if ($null -eq $o) { $o = Copy-Opts $Defaults }
        Write-Log ('설정: ' + ((Get-Desc $o) -join ' · '))
        Invoke-Batch $DropArgs $o
    } else {
        Start-Gui
    }
} catch {
    Show-Error ("실행 중 오류가 발생했습니다.`r`n`r`n" + ($_ | Out-String)) -Fatal
}
