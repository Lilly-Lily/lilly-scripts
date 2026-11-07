<#
  게임 스크린샷 UID 가리기 / 크롭 / 리사이즈 - PowerShell 버전 (추가 설치 불필요)

  사용법
    WWImageQuickEdit.bat 더블클릭 → 뜨는 창에 이미지(여러 장)나 폴더를 드래그&드롭
    → [이전 설정 그대로] 또는 [새로 설정] 선택 → 처리
    (bat 아이콘 위에 직접 드롭하면 마지막 설정으로 바로 처리)
  결과는 기본적으로 원본 옆 'Result' 폴더에 저장됩니다. (설정에서 저장 폴더 직접 지정 가능)
  파일명 끝에 작업 일시가 붙습니다. 예) 스샷_20261031-181700.jpg
  지원 형식: png, jpg, jpeg, bmp  /  저장: 원본 유지, PNG, JPG(품질 조절 가능)
#>

$ErrorActionPreference = 'Stop'
$DropArgs = @($args)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppVersion = '1.1'   # 창 제목에 표시되는 버전

# ===================== 고정 설정 =====================
# UID 영역: 4K(3840x2160) 기준 px 단위, @(가까운 쪽, 먼 쪽) 거리
#   실제 크기 배율 = min(가로/3840, 세로/2160) → 해상도·화면 비율이 달라도 같은 위치
$UidDesktopRight  = @(70, 423);   $UidDesktopBottom = @(0, 54)    # PC(16:9): 오른쪽·아래 가장자리 기준
$UidLegacyRight    = @(0, 423)                           # 2.2 버전까지(~25.04.28)의 이미지(16:9 일반 화면): UID가 오른쪽 끝에 더 가까움
$UidMobileRight   = @(215, 570);  $UidMobileBottom  = @(0, 75)    # 휴대폰(16:9 외 비율)
$UidCineRight     = @(47, 327);   $UidCineBottom    = @(-19, 54)  # 시네마틱: 검은 띠 제외 화면 아래 기준
$DesktopRatio     = @(1.70, 1.85) # 이 범위의 가로/세로 비율이면 PC 레이아웃, 아니면 휴대폰 레이아웃
$UltraRatioMin    = 2.35          # 이 비율보다 가로로 길면 울트라와이드(21:9·32:9): 시네마틱과 같은 위치 기준(검은 띠 제외 화면 아래·오른쪽 끝)

# 시네마틱 판별: 위/아래 가장자리 평균 밝기가 이 값 이하면 검은 띠로 간주
$LetterboxBand      = 0.04
$LetterboxMaxBright = 6
$LetterboxMinRatio  = 0.03   # 띠 자동 제거 시, 띠 두께가 이 비율 이상일 때만 자름

# 블러 강도·모자이크 블록 크기·단색 색상·JPG 품질은 작업 설정 창에서 바꿈 (기본값은 아래 $Defaults)
$StrengthMin   = 8           # 블러 강도·모자이크 블록 크기 허용 범위 (너무 약하면 UID가 읽힐 수 있음)
$StrengthMax   = 60
$ScaleStrength = $true       # 블러·모자이크 강도를 해상도에 맞춰 조정 (설정값은 4K 기준). $false면 px 그대로 적용
$Preview       = $false      # $true: 가리지 않고 빨간 박스만 그림 (위치 확인용)

$OutDirName      = 'Result'
$OldOutDirNames  = @('masked')           # 이전 버전의 결과 폴더 이름 (하위 폴더까지 처리할 때 건너뜀)
$AddTimestamp    = $true                # 결과 파일명 끝에 작업 일시 추가
$TimestampFormat = 'yyyyMMdd-HHmmss'    # 예) 20261031-181700
$Exts            = @('.png', '.jpg', '.jpeg', '.bmp')
$SettingsFile    = Join-Path $ScriptDir 'settings.json'
$LogFile         = Join-Path $ScriptDir 'error.log'

# 작업 옵션 기본값 (창에서 선택한 값은 SettingsFile에 저장되어 다음에 재사용)
$Defaults = [ordered]@{
    mask           = $true
    legacy_uid     = $false        # 2.2 버전까지(~25.04.28)의 이미지(16:9)의 옛날 UID 위치로 가리기
    mask_mode      = 'blur'        # blur | pixelate | fill
    blur_radius    = 14            # 블러 강도 (4K 기준)
    pixel_block    = 14            # 모자이크 블록 크기 (4K 기준)
    fill_color     = '#000000'     # 단색 덮기 색상
    crop           = 'none'        # none | letterbox | custom
    crop_pillar    = $false        # 레터박스 제거 시 울트라와이드 좌우 검은 띠도 제거
    crop_unit      = 'percent'     # percent | px
    crop_margin    = @(0.0, 0.0, 0.0, 0.0)   # 각 가장자리에서 잘라낼 양: 왼쪽, 위, 오른쪽, 아래
    resize         = $false
    resize_unit    = 'percent'     # percent | px
    resize_percent = 50
    resize_width   = 1920
    format         = 'original'    # original | png | jpg
    jpg_quality    = 95
    out_custom     = $false        # $true면 out_dir에 저장, $false면 원본 폴더\Result
    out_dir        = ''
    keep_structure = $false        # 직접 지정 저장 시 하위 폴더까지 처리하고 원본 폴더 구조 유지
    last_out       = ''            # 최근 결과 폴더 (자동 기록)
}
# =====================================================

$MaskModes = [ordered]@{ blur = '블러'; pixelate = '모자이크'; fill = '단색 덮기' }
$CropModes = [ordered]@{ none = '안 함'; letterbox = '시네마틱 레터박스 제거'; custom = '직접 지정' }
$Formats   = [ordered]@{ original = '원본 유지'; png = 'PNG'; jpg = 'JPG' }
$Units     = [ordered]@{ percent = '비율 (%)'; px = '픽셀 (px)' }

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
    public double[] LegacyRight = new double[] { 0, 423 };   // 2.2 버전까지(~25.04.28)의 이미지(16:9 일반 화면)의 UID 위치
    public bool LegacyUid = false;
    public double[] DeskBottom = new double[] { 0, 54 };
    public double[] MobRight   = new double[] { 215, 570 };
    public double[] MobBottom  = new double[] { 0, 75 };
    public double[] CineRight  = new double[] { 47, 327 };
    public double[] CineBottom = new double[] { -19, 54 };
    public double DeskRatioMin = 1.70;
    public double DeskRatioMax = 1.85;
    public double UltraRatioMin = 2.35;  // 이 비율보다 가로로 길면 울트라와이드(21:9·32:9) 화면으로 판별
    public int PixelBlock = 14;          // 4K 기준
    public double BlurRadius = 14;       // 4K 기준
    public bool ScaleStrength = true;    // 강도를 해상도에 맞춰 조정
    public int FillR = 0, FillG = 0, FillB = 0;
    public string Crop = "none";
    public bool CropPillar = false;      // letterbox 크롭 시 좌우 검은 띠도 제거 (울트라와이드)
    public string CropUnit = "percent";  // percent | px
    public double[] CropMargin = new double[] { 0, 0, 0, 0 };   // 왼쪽, 위, 오른쪽, 아래에서 잘라낼 양
    public bool Resize = false;
    public string ResizeUnit = "percent";   // percent | px
    public double ResizePercent = 50;
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
            bool wide = !cine && (double)bmp.Width / bmp.Height > o.UltraRatioMin;   // 위아래 띠 없는 울트라와이드 화면
            int[] cb = (cine || wide) ? PillarCols(buf, stride, bmp.Width, bmp.Height, lb, o) : null;   // 좌우 검은 띠를 뺀 화면 범위
            string layout;
            double scale;
            Rectangle r = UidBox(bmp.Width, bmp.Height, cine || wide, wide, lb, cb, o, out layout, out scale);
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
                    else if (o.MaskMode == "pixelate")
                    {
                        int blk = o.ScaleStrength ? (int)Math.Round(o.PixelBlock * scale) : o.PixelBlock;
                        Pixelate(buf, stride, r, Math.Max(2, blk));
                    }
                    else
                    {
                        double sg = o.ScaleStrength ? o.BlurRadius * scale : o.BlurRadius;
                        Blur(buf, stride, r, Math.Max(1.0, sg));
                    }
                    SetBytes(bmp, buf);
                }
            }

            // 2) 크롭
            if (o.Crop == "letterbox")
            {
                bool usePillar = o.CropPillar && cb != null;
                if (lb != null || usePillar)
                {
                    int cy0 = lb != null ? lb[0] : 0, cy1 = lb != null ? lb[1] : bmp.Height;
                    int cx0 = usePillar ? cb[0] : 0, cx1 = usePillar ? cb[1] : bmp.Width;
                    bmp = Swap(bmp, bmp.Clone(new Rectangle(cx0, cy0, cx1 - cx0, cy1 - cy0), PixelFormat.Format32bppArgb));
                    if (lb != null) notes.Add("lb");
                    if (usePillar) notes.Add("pillar");
                }
            }
            else if (o.Crop == "custom")
            {
                Rectangle c = CropRect(bmp.Width, bmp.Height, o);
                if (c.Width > 0 && c.Height > 0)
                {
                    if (c.Width != bmp.Width || c.Height != bmp.Height)
                    {
                        bmp = Swap(bmp, bmp.Clone(c, PixelFormat.Format32bppArgb));
                        notes.Add("crop");
                    }
                }
                else notes.Add("cropskip");   // 잘라낼 양이 이미지보다 커서 건너뜀
            }

            // 3) 리사이즈 (확대는 안 함)
            int nw = 0;
            if (o.Resize)
            {
                if (o.ResizeUnit == "percent")
                {
                    if (o.ResizePercent > 0 && o.ResizePercent < 100)
                        nw = Math.Max(1, (int)Math.Round(bmp.Width * o.ResizePercent / 100.0));
                }
                else nw = o.ResizeWidth;
            }
            if (nw > 0 && nw < bmp.Width)
            {
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
    static Rectangle UidBox(int w, int h, bool cine, bool wide, int[] lb, int[] cb, UidOpts o, out string layout, out double scale)
    {
        double s, edge;
        double right = w;   // 오른쪽 기준선 (시네마틱에서 좌우 검은 띠가 있으면 화면 영역의 오른쪽 끝)
        double[] rr, bb;
        if (cine)
        {
            int top = lb != null ? lb[0] : 0, bottom = lb != null ? lb[1] : h;
            s = Math.Min(w / 3840.0, (bottom - top) / 1620.0);
            rr = o.CineRight; bb = o.CineBottom; edge = bottom; layout = wide ? "ultra" : "cine";
            if (cb != null) right = cb[1];
        }
        else
        {
            double ratio = (double)w / h;
            bool mobile = ratio < o.DeskRatioMin || ratio > o.DeskRatioMax;
            s = Math.Min(w / 3840.0, h / 2160.0);
            rr = mobile ? o.MobRight : (o.LegacyUid ? o.LegacyRight : o.DeskRight);
            bb = mobile ? o.MobBottom : o.DeskBottom;
            edge = h; layout = mobile ? "mobile" : "normal";
        }
        scale = s;
        int l = Clamp((int)(right - rr[1] * s), 0, w);
        int t = Clamp((int)(edge - bb[1] * s), 0, h);
        int r = Clamp((int)Math.Ceiling(right - rr[0] * s), 0, w);
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

    // 크롭: 각 가장자리에서 잘라낼 양(비율 % 또는 px)을 뺀 나머지 영역
    static Rectangle CropRect(int w, int h, UidOpts o)
    {
        double l = Math.Max(0, o.CropMargin[0]), t = Math.Max(0, o.CropMargin[1]);
        double r = Math.Max(0, o.CropMargin[2]), b = Math.Max(0, o.CropMargin[3]);
        if (o.CropUnit == "percent")
        {
            l = w * l / 100.0; r = w * r / 100.0;
            t = h * t / 100.0; b = h * b / 100.0;
        }
        int x0 = Clamp((int)Math.Round(l), 0, w);
        int y0 = Clamp((int)Math.Round(t), 0, h);
        int x1 = Clamp((int)Math.Round(w - r), 0, w);
        int y1 = Clamp((int)Math.Round(h - b), 0, h);
        return new Rectangle(x0, y0, Math.Max(0, x1 - x0), Math.Max(0, y1 - y0));
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

    // 시네마틱 화면 높이 안에서 좌우 검은 띠를 찾아 실제 화면의 [왼쪽, 오른쪽) 열을 반환 (띠가 없거나 너무 얇으면 null)
    static int[] PillarCols(byte[] buf, int stride, int w, int h, int[] lb, UidOpts o)
    {
        int y0 = lb != null ? lb[0] : 0, y1 = lb != null ? lb[1] : h;
        if (y1 - y0 < 1) return null;
        long[] sum = new long[w];
        for (int y = y0; y < y1; y++)
        {
            int k = y * stride;
            for (int x = 0; x < w; x++, k += 4)
                sum[x] += buf[k + 2] * 299 + buf[k + 1] * 587 + buf[k] * 114;
        }
        double div = 1000.0 * (y1 - y0);
        int left = -1, right = -1;
        for (int x = 0; x < w; x++) if (sum[x] / div > o.LbMaxBright) { left = x; break; }
        if (left < 0) return null;
        for (int x = w - 1; x >= 0; x--) if (sum[x] / div > o.LbMaxBright) { right = x + 1; break; }
        if (left < w * o.LbMinRatio && (w - right) < w * o.LbMinRatio) return null;
        return new int[] { left, right };
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

# ---------------- 화면 부품 (C#, 창을 띄울 때 자동 컴파일) ----------------
$UiCode = @'
using System;
using System.IO;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class UiUtil
{
    public static readonly TextFormatFlags Flags = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;

    public static GraphicsPath Round(RectangleF r, float rad)
    {
        GraphicsPath p = new GraphicsPath();
        float d = Math.Max(0.1f, rad * 2);
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    public static Size Measure(string text, Font f)
    {
        return TextRenderer.MeasureText(text, f, new Size(int.MaxValue, int.MaxValue), Flags);
    }
}

// 알약 모양 선택 버튼 (같은 Group 안에서 하나만 선택되는 라디오 방식)
public class Chip : Control
{
    bool chk, hover;
    Color swatch = Color.Empty;
    public double S = 1.0;
    public string Group = "";
    public bool HasSwatch = false;
    public event EventHandler CheckedChanged;

    public Chip()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        Cursor = Cursors.Hand;
        TabStop = true;
    }

    public bool Checked
    {
        get { return chk; }
        set
        {
            if (chk == value) return;
            chk = value;
            Invalidate();
            if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty);
        }
    }

    public Color Swatch
    {
        get { return swatch; }
        set { swatch = value; Invalidate(); }
    }

    public void Fit()
    {
        using (Font b = new Font(Font, FontStyle.Bold))
        {
            Size ts = UiUtil.Measure(Text, b);
            int padX = (int)Math.Round(14 * S), padY = (int)Math.Round(5 * S);
            int sw = HasSwatch ? (int)Math.Round(20 * S) : 0;
            this.Size = new Size(ts.Width + 2 * padX + sw, ts.Height + 2 * padY);
        }
    }

    protected override void OnClick(EventArgs e)
    {
        base.OnClick(e);
        if (!Enabled || chk) return;
        chk = true;
        Invalidate();
        if (Parent != null && Group.Length > 0)
        {
            foreach (Control c in Parent.Controls)
            {
                Chip o = c as Chip;
                if (o != null && o != this && o.Group == Group) o.Checked = false;
            }
        }
        if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { OnClick(EventArgs.Empty); e.Handled = true; }
    }

    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        Color fill = Color.White, border = Color.FromArgb(201, 201, 201), text = Color.FromArgb(51, 51, 51);
        if (!Enabled)
        {
            fill = Color.FromArgb(247, 247, 247); border = Color.FromArgb(225, 225, 225); text = Color.FromArgb(160, 160, 160);
            if (chk) { fill = Color.FromArgb(240, 246, 252); border = Color.FromArgb(175, 203, 232); }
        }
        else if (chk) { fill = Color.FromArgb(234, 243, 253); border = Color.FromArgb(0, 103, 192); text = Color.FromArgb(11, 79, 148); }
        else if (hover) { fill = Color.FromArgb(249, 249, 249); border = Color.FromArgb(140, 140, 140); }

        using (GraphicsPath p = UiUtil.Round(r, r.Height / 2f))
        using (SolidBrush b = new SolidBrush(fill))
        using (Pen pen = new Pen(border, chk ? 1.5f : 1f))
        {
            g.FillPath(b, p);
            g.DrawPath(pen, p);
        }

        int sw = 0;
        if (HasSwatch)
        {
            sw = (int)Math.Round(20 * S);
            int d = (int)Math.Round(12 * S);
            Rectangle sr = new Rectangle((int)Math.Round(11 * S), (Height - d) / 2, d, d);
            using (SolidBrush sb = new SolidBrush(swatch.IsEmpty ? Color.White : swatch))
            using (Pen sp = new Pen(Color.FromArgb(150, 150, 150)))
            {
                g.FillRectangle(sb, sr);
                g.DrawRectangle(sp, sr);
            }
        }
        Rectangle tr = new Rectangle(sw, 0, Width - sw, Height);
        if (chk)
        {
            using (Font bf = new Font(Font, FontStyle.Bold))
                TextRenderer.DrawText(g, Text, bf, tr, text, UiUtil.Flags | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        else TextRenderer.DrawText(g, Text, Font, tr, text, UiUtil.Flags | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);

        if (Focused && ShowFocusCues)
            ControlPaint.DrawFocusRectangle(g, new Rectangle(3, 3, Width - 6, Height - 6));
    }
}

// 켜고 끄는 토글 스위치 (체크박스 대용)
public class ToggleSwitch : Control
{
    bool chk;
    public double S = 1.0;
    public event EventHandler CheckedChanged;

    public ToggleSwitch()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        Cursor = Cursors.Hand;
        TabStop = true;
    }

    public bool Checked
    {
        get { return chk; }
        set
        {
            if (chk == value) return;
            chk = value;
            Invalidate();
            if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty);
        }
    }

    public void Fit()
    {
        Size ts = UiUtil.Measure(Text, Font);
        int track = (int)Math.Round(36 * S), gap = (int)Math.Round(8 * S), padY = (int)Math.Round(4 * S);
        this.Size = new Size(track + gap + ts.Width + (int)Math.Round(4 * S), Math.Max((int)Math.Round(20 * S), ts.Height) + 2 * padY);
    }

    protected override void OnClick(EventArgs e)
    {
        base.OnClick(e);
        if (Enabled) Checked = !chk;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.Space) { OnClick(EventArgs.Empty); e.Handled = true; }
    }

    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float tw = (float)(36 * S), th = (float)(18 * S);
        float ty = (Height - th) / 2f;
        RectangleF tr = new RectangleF(1f, ty, tw, th);
        Color on = Enabled ? Color.FromArgb(0, 103, 192) : Color.FromArgb(150, 190, 225);
        Color off = Enabled ? Color.FromArgb(150, 150, 150) : Color.FromArgb(205, 205, 205);
        using (GraphicsPath p = UiUtil.Round(tr, th / 2f))
        using (SolidBrush b = new SolidBrush(chk ? on : off))
            g.FillPath(b, p);
        float d = (float)(12 * S), m = (th - d) / 2f;
        float kx = chk ? tr.Right - m - d : tr.X + m;
        using (SolidBrush kb = new SolidBrush(Color.White))
            g.FillEllipse(kb, kx, ty + m, d, d);
        Rectangle txt = new Rectangle((int)(tw + 8 * S), 0, Width - (int)(tw + 8 * S), Height);
        TextRenderer.DrawText(g, Text, Font, txt, Enabled ? Color.FromArgb(27, 27, 27) : Color.FromArgb(150, 150, 150),
            UiUtil.Flags | TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
        if (Focused && ShowFocusCues)
            ControlPaint.DrawFocusRectangle(g, new Rectangle(0, 0, Width, Height));
    }
}

// 둥근 모서리 흰색 카드 (세로로 쌓이는 패널)
public class Card : FlowLayoutPanel
{
    public double S = 1.0;

    public Card()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw, true);
        BackColor = Color.White;
        FlowDirection = FlowDirection.TopDown;
        WrapContents = false;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.Clear(Parent != null ? Parent.BackColor : SystemColors.Control);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using (GraphicsPath p = UiUtil.Round(r, (float)(8 * S)))
        using (SolidBrush b = new SolidBrush(BackColor))
        using (Pen pen = new Pen(Color.FromArgb(226, 226, 226)))
        {
            g.FillPath(b, p);
            g.DrawPath(pen, p);
        }
    }

    protected override void OnPaint(PaintEventArgs e) { }
}

// 둥근 모서리 흰색 카드 (Dock/Anchor로 배치하는 패널)
public class CardPanel : Panel
{
    public double S = 1.0;

    public CardPanel()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw, true);
        BackColor = Color.White;
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.Clear(Parent != null ? Parent.BackColor : SystemColors.Control);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using (GraphicsPath p = UiUtil.Round(r, (float)(8 * S)))
        using (SolidBrush b = new SolidBrush(BackColor))
        using (Pen pen = new Pen(Color.FromArgb(226, 226, 226)))
        {
            g.FillPath(b, p);
            g.DrawPath(pen, p);
        }
    }

    protected override void OnPaint(PaintEventArgs e) { }
}

// 둥근 모서리 버튼 (Primary: 진한 테두리·굵은 글씨)
public class RoundButton : Button
{
    bool hover, down;
    public double S = 1.0;
    public bool Primary = false;
    public int MinW = 0;

    public RoundButton()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw, true);
        Cursor = Cursors.Hand;
    }

    public void Fit()
    {
        using (Font f = new Font(Font, Primary ? FontStyle.Bold : FontStyle.Regular))
        {
            Size ts = UiUtil.Measure(Text, f);
            int w = ts.Width + 2 * (int)Math.Round(18 * S);
            int h = ts.Height + 2 * (int)Math.Round(8 * S);
            this.Size = new Size(Math.Max(w, MinW), h);
        }
    }

    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.Clear(Parent != null ? Parent.BackColor : SystemColors.Control);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        Color fill = Color.White, border = Primary ? Color.FromArgb(110, 110, 110) : Color.FromArgb(201, 201, 201);
        Color text = Color.FromArgb(27, 27, 27);
        if (!Enabled) { fill = Color.FromArgb(247, 247, 247); border = Color.FromArgb(225, 225, 225); text = Color.FromArgb(160, 160, 160); }
        else if (down) { fill = Color.FromArgb(232, 232, 232); }
        else if (hover) { fill = Color.FromArgb(244, 244, 244); border = Color.FromArgb(150, 150, 150); }
        using (GraphicsPath p = UiUtil.Round(r, (float)(6 * S)))
        using (SolidBrush b = new SolidBrush(fill))
        using (Pen pen = new Pen(border, Primary ? 1.5f : 1f))
        {
            g.FillPath(b, p);
            g.DrawPath(pen, p);
        }
        using (Font f = new Font(Font, Primary ? FontStyle.Bold : FontStyle.Regular))
            TextRenderer.DrawText(g, Text, f, new Rectangle(0, 0, Width, Height), text,
                UiUtil.Flags | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        if (Focused && ShowFocusCues)
            ControlPaint.DrawFocusRectangle(g, new Rectangle(4, 4, Width - 8, Height - 8));
    }
}

// 점선 테두리 드롭 영역 (State: 0 대기, 1 드래그 중, 2 처리 중)
public class DropZone : Control
{
    int state;
    public double S = 1.0;

    public DropZone()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.ResizeRedraw, true);
        AllowDrop = true;
    }

    public int State
    {
        get { return state; }
        set { state = value; Invalidate(); }
    }

    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.Clear(Parent != null ? Parent.BackColor : SystemColors.Control);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Color fill = Color.White, line = Color.FromArgb(154, 163, 173), text = Color.FromArgb(85, 85, 85);
        if (state == 1) { fill = Color.FromArgb(234, 243, 253); line = Color.FromArgb(0, 103, 192); text = Color.FromArgb(11, 79, 148); }
        else if (state == 2) { fill = Color.FromArgb(244, 244, 244); line = Color.FromArgb(190, 190, 190); text = Color.FromArgb(130, 130, 130); }
        float w = (float)(2 * S);
        RectangleF r = new RectangleF(w, w, Width - 2 * w - 1, Height - 2 * w - 1);
        using (GraphicsPath p = UiUtil.Round(r, (float)(10 * S)))
        using (SolidBrush b = new SolidBrush(fill))
        using (Pen pen = new Pen(line, w))
        {
            pen.DashStyle = DashStyle.Dash;
            g.FillPath(b, p);
            g.DrawPath(pen, p);
        }
        TextRenderer.DrawText(g, Text, Font, new Rectangle(0, 0, Width, Height), text,
            UiUtil.Flags | TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }
}

// 윈도우 탐색기 스타일 폴더 선택 창 (IFileOpenDialog)
public static class FolderPicker
{
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    class FileOpenDialogCom { }

    [ComImport, Guid("d57c7288-d4ad-4768-be02-9d969532d960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
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

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid, out IShellItem item);

    // 선택한 폴더 경로, 취소하면 null
    public static string Pick(IntPtr owner, string title, string initial)
    {
        IFileOpenDialog dlg = (IFileOpenDialog)new FileOpenDialogCom();
        try
        {
            uint opts;
            dlg.GetOptions(out opts);
            dlg.SetOptions(opts | 0x20 | 0x40 | 0x800);   // 폴더 선택 | 파일 시스템만 | 경로 존재
            if (!string.IsNullOrEmpty(title)) dlg.SetTitle(title);
            if (!string.IsNullOrEmpty(initial) && Directory.Exists(initial))
            {
                Guid iid = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
                IShellItem si;
                SHCreateItemFromParsingName(initial, IntPtr.Zero, ref iid, out si);
                dlg.SetFolder(si);
            }
            int hr = dlg.Show(owner);
            if (hr == unchecked((int)0x800704C7)) return null;   // 사용자가 취소
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
            IShellItem res;
            dlg.GetResult(out res);
            string path;
            res.GetDisplayName(0x80058000, out path);          // 파일 시스템 경로
            return path;
        }
        finally { Marshal.ReleaseComObject(dlg); }
    }
}
'@

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

function Get-Num($v, [double]$def, [double]$min, [double]$max) {
    $d = 0.0
    if (-not [double]::TryParse(([string]$v), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $d = $def }
    if ($d -lt $min) { $d = $min }
    if ($d -gt $max) { $d = $max }
    return $d
}

function Load-Opts {
    if (-not (Test-Path -LiteralPath $SettingsFile)) { return $null }
    try {
        $j = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $o = Copy-Opts $Defaults
        $names = @($j.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($k in @($o.Keys)) { if ($names -contains $k) { $o[$k] = $j.$k } }
        # 이전 버전 설정(crop_box: 왼쪽·위·오른쪽·아래 좌표 비율 0~1)을 '잘라낼 양(%)'으로 변환
        if (($names -contains 'crop_box') -and -not ($names -contains 'crop_margin')) {
            $cb = @($j.crop_box)
            if ($cb.Count -eq 4) {
                $o['crop_unit']   = 'percent'
                $o['crop_margin'] = @(([double]$cb[0] * 100), ([double]$cb[1] * 100), ((1 - [double]$cb[2]) * 100), ((1 - [double]$cb[3]) * 100))
            }
        }
        # 이전 버전 설정은 리사이즈 단위가 없고 가로 px만 있었음
        if (($names -contains 'resize_width') -and -not ($names -contains 'resize_unit')) { $o['resize_unit'] = 'px' }
        $o['mask']           = [bool]$o['mask']
        $o['legacy_uid']     = [bool]$o['legacy_uid']
        $o['resize']         = [bool]$o['resize']
        $o['out_custom']     = [bool]$o['out_custom']
        $o['out_dir']        = [string]$o['out_dir']
        $o['keep_structure'] = [bool]$o['keep_structure']
        $o['crop_pillar']    = [bool]$o['crop_pillar']
        $o['last_out']       = [string]$o['last_out']
        $o['blur_radius']    = [int](Get-Num $o['blur_radius'] 14 $StrengthMin $StrengthMax)
        $o['pixel_block']    = [int](Get-Num $o['pixel_block'] 14 $StrengthMin $StrengthMax)
        $o['jpg_quality']    = [int](Get-Num $o['jpg_quality'] 95 1 100)
        $o['resize_percent'] = (Get-Num $o['resize_percent'] 50 1 100)
        $o['resize_width']   = [int](Get-Num $o['resize_width'] 1920 16 100000)
        if (([string]$o['fill_color']) -notmatch '^#[0-9A-Fa-f]{6}$') { $o['fill_color'] = $Defaults['fill_color'] }
        $m = @($o['crop_margin'])
        if ($m.Count -ne 4) { $m = @(0, 0, 0, 0) }
        $o['crop_margin'] = [double[]]@($m | ForEach-Object { Get-Num $_ 0 0 1000000 })
        if (-not $MaskModes.Contains([string]$o['mask_mode'])) { $o['mask_mode'] = $Defaults['mask_mode'] }
        if (-not $CropModes.Contains([string]$o['crop']))      { $o['crop'] = 'none' }
        if (-not $Units.Contains([string]$o['crop_unit']))     { $o['crop_unit'] = 'percent' }
        if (-not $Units.Contains([string]$o['resize_unit']))   { $o['resize_unit'] = 'percent' }
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

function Use-Structure($o) {
    return [bool]((Use-CustomOut $o) -and $o['keep_structure'])
}

function Get-Desc($o) {
    $l = New-Object System.Collections.Generic.List[string]
    if ($o['mask']) {
        $mm = [string]$o['mask_mode']
        $extra = switch ($mm) { 'blur' { ' ' + $o['blur_radius'] } 'pixelate' { ' ' + $o['pixel_block'] } 'fill' { ' ' + $o['fill_color'] } default { '' } }
        $l.Add('가리기: ' + $MaskModes[$mm] + $extra + $(if ($o['legacy_uid']) { ' (2.2 버전까지 위치)' } else { '' }))
    } else { $l.Add('가리기: 안 함') }
    if ($o['crop'] -eq 'custom') {
        $u = if ($o['crop_unit'] -eq 'px') { ' px' } else { '%' }
        $l.Add('크롭: 자를 양(좌·상·우·하) ' + ((@($o['crop_margin']) | ForEach-Object { '{0:g}' -f $_ }) -join ', ') + $u)
    } else { $l.Add('크롭: ' + $CropModes[[string]$o['crop']] + $(if (($o['crop'] -eq 'letterbox') -and $o['crop_pillar']) { ' (좌우 포함)' } else { '' })) }
    if ($o['resize']) {
        if ($o['resize_unit'] -eq 'px') { $l.Add('리사이즈: 가로 ' + $o['resize_width'] + 'px') }
        else { $l.Add('리사이즈: ' + ('{0:g}' -f $o['resize_percent']) + '%') }
    } else { $l.Add('리사이즈: 안 함') }
    $fm = 'PNG'
    $fmt = [string]$o['format']
    if ($fmt -eq 'original') { $fm = '원본 유지' } elseif ($fmt -eq 'jpg') { $fm = 'JPG ' + $o['jpg_quality'] + '%' }
    $l.Add('포맷: ' + $fm)
    if (Use-CustomOut $o) {
        $l.Add('저장: ' + ([string]$o['out_dir']).Trim() + $(if ($o['keep_structure']) { ' (원본 폴더 구조 유지, 하위 폴더 포함)' } else { '' }))
    } else { $l.Add("저장: 원본 폴더\$OutDirName") }
    return ,$l.ToArray()
}

# ---------------- 일괄 처리 ----------------
function Write-Log([string]$m) {
    if ($script:LogBox) {
        $script:LogBox.AppendText($m + "`r`n")
        [System.Windows.Forms.Application]::DoEvents()
    } else {
        Write-Host $m
        if ($script:DropLog) { $script:DropLog.Add($m.Trim()) }
    }
}

function Test-Under([string]$path, [string]$dir) {
    if (-not $dir) { return $false }
    return $path.StartsWith(($dir.TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase)
}

# 결과 폴더 아래에 만들 하위 폴더 이름 (같은 이름의 서로 다른 폴더는 _2, _3 …로 구분)
function Get-GroupName([string]$root, $names, $used) {
    $key = $root.TrimEnd('\').ToLowerInvariant()
    if ($names.ContainsKey($key)) { return $names[$key] }
    $base = [System.IO.Path]::GetFileName($root.TrimEnd('\'))
    if (-not $base) { $base = $root.TrimEnd('\', '/', ':') -replace '[\\/:]', '_' }
    if (-not $base) { $base = 'root' }
    $n = $base; $k = 2
    while ($used.Contains($n)) { $n = $base + '_' + $k; $k++ }
    [void]$used.Add($n)
    $names[$key] = $n
    return $n
}

# 처리 대상 목록. File: 파일, Sub: 지정 결과 폴더 아래 하위 경로 ('원본 폴더 구조 유지'일 때만 사용)
function Get-Jobs($paths, $o) {
    $jobs = New-Object System.Collections.Generic.List[object]
    $keep = Use-Structure $o
    $outDir = ''
    if (Use-CustomOut $o) { $outDir = ([string]$o['out_dir']).Trim() }
    $seen  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $used  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $names = @{}
    foreach ($p in $paths) {
        if ([System.IO.Directory]::Exists($p)) {
            if ($keep) {
                # 하위 폴더까지 모두 처리 (지정 결과 폴더·'Result'(이전 'masked') 폴더 안 파일은 제외)
                $root  = [System.IO.Path]::GetFullPath($p).TrimEnd('\')
                $group = Get-GroupName $root $names $used
                $all = @(Get-ChildItem -LiteralPath $p -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $Exts -contains $_.Extension.ToLower() } | Sort-Object FullName)
                foreach ($fi in $all) {
                    if (Test-Under $fi.FullName $outDir) { continue }
                    $rel = $fi.DirectoryName.Substring($root.Length).Trim('\')
                    $skip = $false
                    foreach ($seg in ($rel -split '\\')) { if ($seg -and (($seg -ieq $OutDirName) -or ($OldOutDirNames -contains $seg))) { $skip = $true } }
                    if ($skip) { continue }
                    if (-not $seen.Add($fi.FullName)) { continue }
                    $sub = $group
                    if ($rel) { $sub = $group + '\' + $rel }
                    $jobs.Add([pscustomobject]@{ File = $fi; Sub = $sub })
                }
            } else {
                $all = @(Get-ChildItem -LiteralPath $p -File |
                    Where-Object { $Exts -contains $_.Extension.ToLower() } | Sort-Object Name)
                foreach ($fi in $all) {
                    if (-not $seen.Add($fi.FullName)) { continue }
                    $jobs.Add([pscustomobject]@{ File = $fi; Sub = '' })
                }
            }
        } elseif ([System.IO.File]::Exists($p)) {
            $fi = New-Object System.IO.FileInfo -ArgumentList $p
            if (($Exts -contains $fi.Extension.ToLower()) -and $seen.Add($fi.FullName)) {
                $sub = ''
                if ($keep) { $sub = Get-GroupName ([string]$fi.DirectoryName) $names $used }
                $jobs.Add([pscustomobject]@{ File = $fi; Sub = $sub })
            }
        }
    }
    return ,$jobs.ToArray()
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
    $c.LegacyRight  = [double[]]$UidLegacyRight
    $c.LegacyUid    = [bool]$o['legacy_uid']
    $c.UltraRatioMin = [double]$UltraRatioMin
    $c.PixelBlock   = [int]$o['pixel_block']
    $c.BlurRadius   = [double]$o['blur_radius']
    $c.ScaleStrength = [bool]$ScaleStrength
    $hex = [string]$o['fill_color']
    $c.FillR = [Convert]::ToInt32($hex.Substring(1, 2), 16)
    $c.FillG = [Convert]::ToInt32($hex.Substring(3, 2), 16)
    $c.FillB = [Convert]::ToInt32($hex.Substring(5, 2), 16)
    $c.Crop         = [string]$o['crop']
    $c.CropPillar   = [bool]$o['crop_pillar']
    $c.CropUnit     = [string]$o['crop_unit']
    $c.CropMargin   = [double[]]@($o['crop_margin'])
    $c.Resize       = [bool]$o['resize']
    $c.ResizeUnit   = [string]$o['resize_unit']
    $c.ResizePercent = [double]$o['resize_percent']
    $c.ResizeWidth  = [int]$o['resize_width']
    $c.JpgQuality   = [long]$o['jpg_quality']
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
            '^ultra$'  { '울트라와이드' }
            '^pillar$' { '좌우 띠 제거' }
            '^normal$' { '일반' }
            '^mobile$' { '휴대폰' }
            '^lb$'     { '띠 제거' }
            '^crop$'   { '크롭' }
            '^cropskip$' { '크롭 건너뜀(범위 초과)' }
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
    $jobs = Get-Jobs $paths $o
    if ($jobs.Count -eq 0) {
        Write-Log '처리할 이미지가 없습니다. (지원 형식: png, jpg, jpeg, bmp)'
        return
    }
    $cs = New-CsOpts $o
    $n = $jobs.Count; $i = 0; $ok = 0
    foreach ($job in $jobs) {
        $f = $job.File
        $i++
        try {
            $ext = if ($o['format'] -eq 'original') { $f.Extension.ToLower() } else { '.' + $o['format'] }
            if (Use-CustomOut $o) {
                $outDir = ([string]$o['out_dir']).Trim()
                if ($job.Sub) { $outDir = [System.IO.Path]::Combine($outDir, [string]$job.Sub) }
            } else { $outDir = [System.IO.Path]::Combine($f.DirectoryName, $OutDirName) }
            [void][System.IO.Directory]::CreateDirectory($outDir)
            $out = Get-OutputPath $outDir $f.BaseName $ext
            $note = Convert-Notes ([UidImg]::Process($f.FullName, $out, $cs))
            $ok++
            if ($job.Sub) { $shown = [string]$job.Sub + '\' + (Split-Path -Leaf $out) }
            else { $shown = (Split-Path -Leaf $outDir) + '\' + (Split-Path -Leaf $out) }
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

function New-Size([int]$w, [int]$h) { return New-Object System.Drawing.Size -ArgumentList $w, $h }
function New-Rgb([int]$r, [int]$g, [int]$b) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }

# 카드 폭 / 카드 안쪽 폭
function Get-CardW  { return (P 520) }
function Get-InnerW { return ((P 520) - 2 * (P 16)) }

function New-Flow([string]$dir = 'LeftToRight', [bool]$wrap = $false) {
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.FlowDirection = $dir
    $p.WrapContents  = $wrap
    $p.AutoSize      = $true
    $p.AutoSizeMode  = 'GrowAndShrink'
    $p.Margin        = New-Pad 0
    if ($wrap) { $p.MaximumSize = New-Size (Get-InnerW) 0 }
    return $p
}

function New-Label([string]$text) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $text; $c.AutoSize = $true; $c.Anchor = 'Left'
    $c.Margin = New-Pad 0 (P 5) (P 6) (P 5)
    return $c
}

# 설명 글: $warn 이면 주의 색
function New-Hint([string]$text, [bool]$warn = $false) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $text; $c.AutoSize = $true
    $c.Font = $script:FontSmall
    $c.MaximumSize = New-Size (Get-InnerW) 0
    $c.ForeColor = if ($warn) { New-Rgb 138 90 0 } else { New-Rgb 119 119 119 }
    $c.Margin = New-Pad 0 (P 2) 0 0
    return $c
}

function New-Chip([string]$text, [bool]$checked, [string]$group) {
    $c = New-Object Chip
    $c.S = $script:Scale; $c.Font = $script:Font
    $c.Text = $text; $c.Group = $group
    $c.Checked = $checked
    $c.Fit()
    $c.Margin = New-Pad (P 2) (P 3) (P 4) (P 3)
    return $c
}

function New-Toggle([string]$text, [bool]$on) {
    $c = New-Object ToggleSwitch
    $c.S = $script:Scale; $c.Font = $script:Font
    $c.Text = $text
    $c.Checked = $on
    $c.Fit()
    return $c
}

function New-Button([string]$text, [bool]$primary = $false, [int]$minW = 84) {
    $c = New-Object RoundButton
    $c.S = $script:Scale; $c.Font = $script:Font
    $c.Text = $text; $c.Primary = $primary
    $c.MinW = P $minW
    $c.Fit()
    $c.Anchor = 'Left'
    $c.Margin = New-Pad (P 4) (P 4) (P 4) (P 4)
    return $c
}

function New-Input([double]$width, [string]$text) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Width = P $width; $t.Anchor = 'Left'
    $t.Margin = New-Pad (P 2) (P 3) (P 8) (P 3)
    $t.Text = $text
    return $t
}

function New-LinkLabel([string]$text) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $text; $c.AutoSize = $true; $c.Anchor = 'Left'
    $c.Font = $script:FontSmall
    $c.ForeColor = New-Rgb 0 103 192
    $c.Cursor = [System.Windows.Forms.Cursors]::Hand
    $c.Margin = New-Pad (P 6) (P 5) 0 (P 5)
    return $c
}

# 카드: 폭 고정, 높이는 내용에 맞춤
function New-Card {
    $c = New-Object Card
    $c.S = $script:Scale
    $w = Get-CardW
    $c.MinimumSize = New-Size $w 0
    $c.MaximumSize = New-Size $w 0
    $c.Padding = New-Pad (P 16) (P 12) (P 16) (P 14)
    $c.Margin  = New-Pad 0 0 0 (P 10)
    return $c
}

# 카드 제목줄: 왼쪽 제목, 오른쪽 토글(선택)
function New-Header([string]$title, $toggle = $null) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Size (Get-InnerW) (P 30)
    $p.Margin = New-Pad 0 0 0 (P 6)
    if ($toggle) { $toggle.Dock = 'Right'; $p.Controls.Add($toggle) }
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $title; $l.AutoSize = $true; $l.Dock = 'Left'
    $l.TextAlign = 'MiddleLeft'
    $l.Font = $script:FontTitle
    $p.Controls.Add($l)
    return $p
}

# 슬라이더 + 숫자 입력 한 줄 (강도·품질용)
function New-SliderRow([string]$label, [int]$min, [int]$max, [int]$val, [string]$unit) {
    $row = New-Flow
    $row.Controls.Add((New-Label $label))
    $tr = New-Object System.Windows.Forms.TrackBar
    $tr.Minimum = $min; $tr.Maximum = $max
    $tr.Value = [Math]::Max($min, [Math]::Min($max, $val))
    $tr.TickStyle = 'None'; $tr.AutoSize = $false
    $tr.Size = New-Size (P 220) (P 30)
    $tr.Margin = New-Pad 0 0 (P 6) 0
    $tr.Anchor = 'Left'
    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Minimum = $min; $num.Maximum = $max
    $num.Value = $tr.Value
    $num.Width = P 58; $num.Anchor = 'Left'
    $num.Margin = New-Pad 0 (P 3) (P 2) (P 3)
    $tr.Tag = $num; $num.Tag = $tr
    $tr.add_ValueChanged({ param($s, $e) if ([int]$s.Tag.Value -ne $s.Value) { $s.Tag.Value = $s.Value } })
    $num.add_ValueChanged({ param($s, $e) $v = [int]$s.Value; if ($s.Tag.Value -ne $v) { $s.Tag.Value = $v } })
    $row.Controls.Add($tr); $row.Controls.Add($num)
    if ($unit) { $ul = New-Label $unit; $ul.Margin = New-Pad (P 3) (P 5) (P 6) (P 5); $row.Controls.Add($ul) }
    $link = New-LinkLabel '기본값으로'
    $link.Tag = @{ Num = $num; Def = $val }
    $link.add_Click({ param($s, $e) $s.Tag.Num.Value = $s.Tag.Def })
    $row.Controls.Add($link)
    return @{ Row = $row; Track = $tr; Num = $num }
}

function New-Dialog([string]$title) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title
    $d.Font = $script:Font
    $d.BackColor = $script:ColBg
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
    $d.StartPosition = 'CenterParent'
    $d.TopMost = $true
    return $d
}

function Show-Warn([string]$msg) {
    [void][System.Windows.Forms.MessageBox]::Show($script:SD.Form, $msg, '입력 확인', 'OK', 'Warning')
}

# 칩 묶음에서 선택된 항목의 키
function Get-Checked($chips, [string]$default) {
    foreach ($k in $chips.Keys) { if ($chips[$k].Checked) { return $k } }
    return $default
}

# ---------------- 선택지: 이전 설정 사용 vs 새로 설정 ----------------
function Show-ChoiceDialog($prev, [int]$count) {
    $d = New-Dialog '작업 선택'
    $root = New-Flow 'TopDown'

    $h = New-Label "${count}개 항목을 받았습니다. 어떻게 처리할까요?"
    $h.Font = $script:FontTitle
    $h.Margin = New-Pad (P 2) 0 0 (P 10)
    $root.Controls.Add($h)

    $card = New-Card
    $card.Controls.Add((New-Header '이전 설정'))
    foreach ($line in (Get-Desc $prev)) {
        $lb = New-Label $line
        $lb.MaximumSize = New-Size (Get-InnerW) 0
        $lb.Margin = New-Pad 0 (P 2) 0 (P 2)
        $card.Controls.Add($lb)
    }
    $root.Controls.Add($card)

    $btns = New-Flow 'RightToLeft'
    $btns.Width = Get-CardW
    $btns.AutoSize = $false
    $btns.Height = P 44
    $b3 = New-Button '취소';              $b3.DialogResult = 'Cancel'
    $b2 = New-Button '새로 설정';         $b2.DialogResult = 'No'
    $b1 = New-Button '이전 설정 그대로' $true;  $b1.DialogResult = 'Yes'
    $btns.Controls.Add($b3); $btns.Controls.Add($b2); $btns.Controls.Add($b1)
    $root.Controls.Add($btns)

    $d.Controls.Add($root)
    $root.Location = New-Object System.Drawing.Point -ArgumentList (P 16), (P 14)
    $root.PerformLayout()
    $pref = $root.PreferredSize
    $d.ClientSize = New-Size ($pref.Width + (P 32)) ($pref.Height + (P 24))   # 좌우 여백 같게
    $d.AcceptButton = $b1
    $d.CancelButton = $b3
    $r = $d.ShowDialog($script:Main)
    $d.Dispose()
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { return 'prev' }
    if ($r -eq [System.Windows.Forms.DialogResult]::No)  { return 'new' }
    return 'cancel'
}

# ---------------- 작업 설정 창 ----------------
# 내용 높이에 맞춰 창 크기를 조절 (화면보다 길면 스크롤)
function Update-DialogSize {
    $sd = $script:SD
    $d = $sd.Form
    $sd.Root.PerformLayout()
    $pref = $sd.Root.PreferredSize
    $wa = [System.Windows.Forms.Screen]::FromControl($script:Main).WorkingArea
    $need = $pref.Height + (P 16) + $sd.Footer.Height
    $maxH = [int]($wa.Height * 0.92)
    $h = [Math]::Min($need, $maxH)
    $w = $pref.Width + (P 32)
    if ($need -gt $maxH) { $w += [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth }
    $d.ClientSize = New-Size $w $h
    if ($d.Visible) {
        if ($d.Bottom -gt $wa.Bottom) { $d.Top = [Math]::Max($wa.Top, $wa.Bottom - $d.Height) }
        if ($d.Right -gt $wa.Right) { $d.Left = [Math]::Max($wa.Left, $wa.Right - $d.Width) }
    }
}

function Update-FillPreview {
    $sd = $script:SD
    $hex = [string]$sd.FillColor
    $sd.FillPreview.BackColor = [System.Drawing.ColorTranslator]::FromHtml($hex)
    $sd.FillText.Text = $hex.ToUpper()
}

function Update-SettingsState {
    $sd = $script:SD
    # UID 가리기
    $maskOn = $sd.MaskToggle.Checked
    $sd.MaskBody.Enabled = $maskOn
    $mode = Get-Checked $sd.MaskChips 'blur'
    $sd.BlurRow.Visible = ($mode -eq 'blur')
    $sd.PixRow.Visible  = ($mode -eq 'pixelate')
    $sd.FillRow.Visible = ($mode -eq 'fill')

    # 크롭
    $custom = ((Get-Checked $sd.CropChips 'none') -eq 'custom')
    $sd.CropBody.Enabled = $custom
    $sd.PillarBody.Visible = ((Get-Checked $sd.CropChips 'none') -eq 'letterbox')
    $sd.CropSuffix.Text = if ((Get-Checked $sd.CUnitChips 'percent') -eq 'px') { 'px' } else { '%' }

    # 리사이즈
    $sd.ResizeBody.Enabled = $sd.ResizeToggle.Checked
    $unit = Get-Checked $sd.RUnitChips 'percent'
    if ($sd.ResizeUnitShown -ne $unit) {
        $sd.ResizeVals[$sd.ResizeUnitShown] = $sd.RCombo.Text
        $sd.RCombo.Items.Clear()
        $items = if ($unit -eq 'px') { @('3840', '2560', '1920', '1600', '1280') } else { @('75', '50', '25') }
        foreach ($v in $items) { [void]$sd.RCombo.Items.Add($v) }
        $sd.RCombo.Text = [string]$sd.ResizeVals[$unit]
        $sd.ResizeUnitShown = $unit
    }
    $sd.RSuffix.Text = if ($unit -eq 'px') { 'px' } else { '%' }

    # 저장 포맷 / 위치
    $sd.JpgBody.Visible = ((Get-Checked $sd.FmtChips 'original') -eq 'jpg')
    $sd.OutBox.Enabled = $sd.OutToggle.Checked
    $sd.KeepToggle.Enabled = $sd.OutToggle.Checked

    Update-DialogSize
}

function Confirm-Settings {
    $sd = $script:SD
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $flt = [System.Globalization.NumberStyles]::Float

    $crop  = Get-Checked $sd.CropChips 'none'
    $cunit = Get-Checked $sd.CUnitChips 'percent'
    $mode  = Get-Checked $sd.MaskChips 'blur'
    $fmt   = Get-Checked $sd.FmtChips 'original'
    $runit = Get-Checked $sd.RUnitChips 'percent'

    # 크롭: 가장자리에서 잘라낼 양
    $m = New-Object System.Collections.Generic.List[double]
    foreach ($tb in $sd.BoxTexts) {
        $v = 0.0
        if ($crop -eq 'custom') {
            if (-not [double]::TryParse($tb.Text.Trim(), $flt, $inv, [ref]$v) -or $v -lt 0) {
                Show-Warn '크롭 값에는 0 이상의 숫자를 입력해 주세요.'; return
            }
        } else { [void][double]::TryParse($tb.Text.Trim(), $flt, $inv, [ref]$v); if ($v -lt 0) { $v = 0.0 } }
        $m.Add($v)
    }
    if ($crop -eq 'custom' -and $cunit -eq 'percent') {
        if (($m[0] + $m[2]) -ge 100 -or ($m[1] + $m[3]) -ge 100) {
            Show-Warn '비율 크롭은 왼쪽+오른쪽, 위+아래가 각각 100% 미만이어야 해요.'; return
        }
    }

    # 리사이즈
    $sd.ResizeVals[$sd.ResizeUnitShown] = $sd.RCombo.Text
    $pct = Get-Num $sd.ResizeVals['percent'] 50 1 100
    $wpx = [int](Get-Num $sd.ResizeVals['px'] 1920 16 100000)
    if ($sd.ResizeToggle.Checked) {
        $d0 = 0.0
        $txt = ([string]$sd.ResizeVals[$runit]).Trim()
        if ($runit -eq 'percent') {
            if (-not [double]::TryParse($txt, $flt, $inv, [ref]$d0) -or $d0 -lt 1 -or $d0 -gt 100) {
                Show-Warn '리사이즈 비율은 1~100 사이 숫자로 입력해 주세요.'; return
            }
            $pct = $d0
        } else {
            if (-not [double]::TryParse($txt, $flt, $inv, [ref]$d0) -or $d0 -lt 16) {
                Show-Warn '리사이즈 가로 값은 16 이상의 숫자로 입력해 주세요.'; return
            }
            $wpx = [int][Math]::Round($d0)
        }
    }

    $outDir = $sd.OutBox.Text.Trim()
    if ($sd.OutToggle.Checked) {
        if (-not $outDir) { Show-Warn '저장 폴더를 지정해 주세요.'; return }
        if (-not [System.IO.Path]::IsPathRooted($outDir)) {
            Show-Warn "저장 폴더는 전체 경로로 지정해 주세요.`r`n(예: D:\Screenshots\Result)"; return
        }
    }

    $o = [ordered]@{
        mask           = $sd.MaskToggle.Checked
        legacy_uid     = [bool]$sd.LegacyToggle.Checked
        mask_mode      = $mode
        blur_radius    = [int]$sd.BlurUi.Num.Value
        pixel_block    = [int]$sd.PixUi.Num.Value
        fill_color     = [string]$sd.FillColor
        crop           = $crop
        crop_pillar    = [bool]$sd.PillarToggle.Checked
        crop_unit      = $cunit
        crop_margin    = [double[]]$m.ToArray()
        resize         = $sd.ResizeToggle.Checked
        resize_unit    = $runit
        resize_percent = $pct
        resize_width   = $wpx
        format         = $fmt
        jpg_quality    = [int]$sd.JpgUi.Num.Value
        out_custom     = $sd.OutToggle.Checked
        out_dir        = $outDir
        keep_structure = [bool]($sd.OutToggle.Checked -and $sd.KeepToggle.Checked)
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
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $onChange = { Update-SettingsState }
    $root = New-Flow 'TopDown'
    $sd.Root = $root

    # ── UID 가리기 ──
    $sd.MaskToggle = New-Toggle '사용' ([bool]$base['mask'])
    $sd.MaskToggle.add_CheckedChanged($onChange)
    $card = New-Card
    $card.Controls.Add((New-Header 'UID 가리기' $sd.MaskToggle))
    $body = New-Flow 'TopDown'
    $sd.MaskBody = $body
    $row = New-Flow
    $row.Controls.Add((New-Label '방식'))
    $sd.MaskChips = [ordered]@{}
    foreach ($k in $MaskModes.Keys) {
        $c = New-Chip $MaskModes[$k] ($base['mask_mode'] -eq $k) 'mask'
        $c.add_CheckedChanged($onChange)
        $row.Controls.Add($c); $sd.MaskChips[$k] = $c
    }
    $body.Controls.Add($row)

    $sd.BlurUi = New-SliderRow '블러 강도' $StrengthMin $StrengthMax ([int]$base['blur_radius']) ''
    $sd.BlurRow = $sd.BlurUi.Row; $body.Controls.Add($sd.BlurRow)
    $sd.PixUi = New-SliderRow '블록 크기' $StrengthMin $StrengthMax ([int]$base['pixel_block']) 'px'
    $sd.PixRow = $sd.PixUi.Row; $body.Controls.Add($sd.PixRow)
    # 기본값(링크)은 설정 파일 값이 아니라 고정 기본값으로 되돌리도록 지정
    $sd.BlurUi.Row.Controls[$sd.BlurUi.Row.Controls.Count - 1].Tag.Def = [int]$Defaults['blur_radius']
    $sd.PixUi.Row.Controls[$sd.PixUi.Row.Controls.Count - 1].Tag.Def = [int]$Defaults['pixel_block']

    # 단색 색상
    $sd.FillColor = [string]$base['fill_color']
    $fr = New-Flow 'LeftToRight' $true
    $fr.Controls.Add((New-Label '색상'))
    $sd.FillChips = [ordered]@{}
    $presets = @( @('검정', '#000000'), @('흰색', '#FFFFFF') )
    foreach ($pr in $presets) {
        $c = New-Chip $pr[0] ($sd.FillColor.ToUpper() -eq $pr[1]) 'fill'
        $c.HasSwatch = $true
        $c.Swatch = [System.Drawing.ColorTranslator]::FromHtml($pr[1])
        $c.Tag = $pr[1]
        $c.Fit()
        $c.add_CheckedChanged({ param($s, $e) if ($s.Checked) { $script:SD.FillColor = [string]$s.Tag; Update-FillPreview } })
        $fr.Controls.Add($c); $sd.FillChips[$pr[0]] = $c
    }
    $pick = New-Button '색 선택…' $false 70
    $pick.add_Click({
        $s = $script:SD
        $cd = New-Object System.Windows.Forms.ColorDialog
        $cd.FullOpen = $true
        $cd.Color = [System.Drawing.ColorTranslator]::FromHtml([string]$s.FillColor)
        if ($cd.ShowDialog($s.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
            foreach ($ch in $s.FillChips.Values) { $ch.Checked = $false }
            $s.FillColor = ('#{0:X2}{1:X2}{2:X2}' -f $cd.Color.R, $cd.Color.G, $cd.Color.B)
            Update-FillPreview
        }
        $cd.Dispose()
    })
    $sd.FillPreview = New-Object System.Windows.Forms.Label
    $sd.FillPreview.AutoSize = $false; $sd.FillPreview.Size = New-Size (P 22) (P 22)
    $sd.FillPreview.BorderStyle = 'FixedSingle'; $sd.FillPreview.Anchor = 'Left'
    $sd.FillPreview.Margin = New-Pad (P 4) (P 4) (P 4) (P 4)
    $sd.FillText = New-Label ''
    $sd.FillText.Font = $script:FontSmall
    $flink = New-LinkLabel '기본값으로'
    $flink.add_Click({
        $s = $script:SD
        $s.FillColor = [string]$Defaults['fill_color']
        foreach ($ch in $s.FillChips.Values) { $ch.Checked = ($ch.Tag -eq $s.FillColor) }
        Update-FillPreview
    })
    $fr.Controls.Add($pick); $fr.Controls.Add($sd.FillPreview); $fr.Controls.Add($sd.FillText); $fr.Controls.Add($flink)
    $sd.FillRow = $fr; $body.Controls.Add($fr)
    Update-FillPreview

    $body.Controls.Add((New-Hint "기본값은 4K 기준, 강도가 약하면 UID가 잘 안 가려질 수 있어요. (최소값 $StrengthMin)"))
    $sd.LegacyToggle = New-Toggle '2.2 버전까지의 이미지 (~25.04.28)' ([bool]$base['legacy_uid'])
    $legacyRow = New-Object System.Windows.Forms.Panel
    $legacyRow.Size = New-Size (Get-InnerW) (P 30)
    $legacyRow.Margin = New-Pad 0 (P 8) 0 0
    $sd.LegacyToggle.Dock = 'Right'
    $legacyRow.Controls.Add($sd.LegacyToggle)
    $body.Controls.Add($legacyRow)
    $body.Controls.Add((New-Hint 'UID 위치가 달라진 2.3 버전 이전 이미지는 켜 주세요. 16:9 화면에만 적용돼요.'))
    $card.Controls.Add($body)
    $root.Controls.Add($card)

    # ── 크롭 ──
    $card = New-Card
    $card.Controls.Add((New-Header '크롭'))
    $row = New-Flow
    $sd.CropChips = [ordered]@{}
    foreach ($k in $CropModes.Keys) {
        $c = New-Chip $CropModes[$k] ($base['crop'] -eq $k) 'crop'
        $c.add_CheckedChanged($onChange)
        $row.Controls.Add($c); $sd.CropChips[$k] = $c
    }
    $card.Controls.Add($row)
    $sd.PillarToggle = New-Toggle '울트라와이드 좌우 레터박스 제거' ([bool]$base['crop_pillar'])
    $pillarRow = New-Object System.Windows.Forms.Panel
    $pillarRow.Size = New-Size (Get-InnerW) (P 30)
    $pillarRow.Margin = New-Pad 0 (P 4) 0 0
    $sd.PillarToggle.Dock = 'Right'
    $pillarRow.Controls.Add($sd.PillarToggle)
    $sd.PillarBody = New-Flow 'TopDown'
    $sd.PillarBody.Controls.Add($pillarRow)
    $card.Controls.Add($sd.PillarBody)
    $body = New-Flow 'TopDown'
    $sd.CropBody = $body
    $row = New-Flow
    $row.Controls.Add((New-Label '단위'))
    $sd.CUnitChips = [ordered]@{}
    foreach ($k in $Units.Keys) {
        $c = New-Chip $Units[$k] ($base['crop_unit'] -eq $k) 'cunit'
        $c.add_CheckedChanged($onChange)
        $row.Controls.Add($c); $sd.CUnitChips[$k] = $c
    }
    $body.Controls.Add($row)
    $row = New-Flow
    $sd.BoxTexts = New-Object System.Collections.Generic.List[object]
    $names = @('왼쪽', '위', '오른쪽', '아래')
    for ($i = 0; $i -lt 4; $i++) {
        $row.Controls.Add((New-Label $names[$i]))
        $tb = New-Input 48 ([double]@($base['crop_margin'])[$i]).ToString('0.##', $inv)
        $row.Controls.Add($tb); $sd.BoxTexts.Add($tb)
    }
    $sd.CropSuffix = New-Label '%'
    $sd.CropSuffix.Margin = New-Pad (P 3) (P 5) (P 6) (P 5)
    $row.Controls.Add($sd.CropSuffix)
    $body.Controls.Add($row)
    $card.Controls.Add($body)
    $card.Controls.Add((New-Hint '각 가장자리에서 잘라낼 양을 입력해요.'))
    $card.Controls.Add((New-Hint '해상도가 다른 여러 이미지를 처리시 픽셀 단위는 범위가 달라지므로 비율을 권장해요.' $true))
    $card.Controls.Add((New-Hint '레터박스 제거는 시네마틱으로 판별된 이미지에만 적용돼요.'))
    $root.Controls.Add($card)

    # ── 리사이즈 ──
    $sd.ResizeToggle = New-Toggle '사용' ([bool]$base['resize'])
    $sd.ResizeToggle.add_CheckedChanged($onChange)
    $card = New-Card
    $card.Controls.Add((New-Header '리사이즈' $sd.ResizeToggle))
    $body = New-Flow
    $sd.ResizeBody = $body
    $body.Controls.Add((New-Label '단위'))
    $sd.RUnitChips = [ordered]@{}
    foreach ($k in $Units.Keys) {
        $c = New-Chip $Units[$k] ($base['resize_unit'] -eq $k) 'runit'
        $c.add_CheckedChanged($onChange)
        $body.Controls.Add($c); $sd.RUnitChips[$k] = $c
    }
    $sd.ResizeVals = @{ percent = ([double]$base['resize_percent']).ToString('0.##', $inv); px = [string]$base['resize_width'] }
    $sd.ResizeUnitShown = [string]$base['resize_unit']
    $sd.RCombo = New-Object System.Windows.Forms.ComboBox
    $sd.RCombo.DropDownStyle = 'DropDown'; $sd.RCombo.Width = P 80; $sd.RCombo.Anchor = 'Left'
    $sd.RCombo.Margin = New-Pad (P 8) (P 3) (P 2) (P 3)
    $initItems = if ($sd.ResizeUnitShown -eq 'px') { @('3840', '2560', '1920', '1600', '1280') } else { @('75', '50', '25') }
    foreach ($v in $initItems) { [void]$sd.RCombo.Items.Add($v) }
    $sd.RCombo.Text = [string]$sd.ResizeVals[$sd.ResizeUnitShown]
    $sd.RSuffix = New-Label '%'
    $sd.RSuffix.Margin = New-Pad (P 3) (P 5) (P 6) (P 5)
    $body.Controls.Add($sd.RCombo); $body.Controls.Add($sd.RSuffix)
    $card.Controls.Add($body)
    $card.Controls.Add((New-Hint '해상도가 다른 여러 이미지를 처리시 픽셀 단위는 범위가 달라지므로 비율을 권장해요.' $true))
    $card.Controls.Add((New-Hint '확대는 하지 않아요. 비율은 1~100%, 가로 px는 원본 가로 이하만 적용돼요.'))
    $root.Controls.Add($card)

    # ── 저장 포맷 ──
    $card = New-Card
    $card.Controls.Add((New-Header '저장 포맷'))
    $row = New-Flow
    $sd.FmtChips = [ordered]@{}
    foreach ($k in $Formats.Keys) {
        $c = New-Chip $Formats[$k] ($base['format'] -eq $k) 'fmt'
        $c.add_CheckedChanged($onChange)
        $row.Controls.Add($c); $sd.FmtChips[$k] = $c
    }
    $card.Controls.Add($row)
    $jb = New-Flow 'TopDown'
    $sd.JpgBody = $jb
    $sd.JpgUi = New-SliderRow 'JPG 품질' 1 100 ([int]$base['jpg_quality']) '%'
    $sd.JpgUi.Row.Controls[$sd.JpgUi.Row.Controls.Count - 1].Tag.Def = [int]$Defaults['jpg_quality']
    $jb.Controls.Add($sd.JpgUi.Row)
    $jb.Controls.Add((New-Hint '1~100%, 높을수록 화질이 좋고 용량이 커요.'))
    $card.Controls.Add($jb)
    $root.Controls.Add($card)

    # ── 저장 위치 ──
    $sd.OutToggle = New-Toggle '직접 지정' ([bool]$base['out_custom'])
    $sd.OutToggle.add_CheckedChanged($onChange)
    $card = New-Card
    $card.Controls.Add((New-Header '저장 위치' $sd.OutToggle))
    $card.Controls.Add((New-Hint "기본값은 원본 폴더 안 '$OutDirName'에 저장되고, '직접 지정' 선택시 변경 가능해요."))
    $row = New-Flow
    $row.Margin = New-Pad 0 (P 6) 0 0
    $browse = New-Button '찾아보기…'
    $browse.Margin = New-Pad 0 (P 3) 0 (P 3)
    $sd.OutBox = New-Input 100 ([string]$base['out_dir'])
    $sd.OutBox.Width = (Get-InnerW) - $browse.Width - (P 8) - (P 2)
    $browse.add_Click({
        $s = $script:SD
        $cur = $s.OutBox.Text.Trim()
        $picked = $null
        try { $picked = [FolderPicker]::Pick($s.Form.Handle, '결과를 저장할 폴더를 선택하세요', $cur) }
        catch {
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            $fb.Description = '결과를 저장할 폴더를 선택하세요'
            if ($cur -and [System.IO.Directory]::Exists($cur)) { $fb.SelectedPath = $cur }
            if ($fb.ShowDialog($s.Form) -eq [System.Windows.Forms.DialogResult]::OK) { $picked = $fb.SelectedPath }
            $fb.Dispose()
        }
        if ($picked) { $s.OutBox.Text = $picked; $s.OutToggle.Checked = $true }
    })
    $row.Controls.Add($sd.OutBox); $row.Controls.Add($browse)
    $card.Controls.Add($row)
    $sd.KeepToggle = New-Toggle '원본 폴더 구조 유지' ([bool]$base['keep_structure'])
    $keepRow = New-Object System.Windows.Forms.Panel
    $keepRow.Size = New-Size (Get-InnerW) (P 30)
    $keepRow.Margin = New-Pad 0 (P 8) 0 0
    $sd.KeepToggle.Dock = 'Right'
    $keepRow.Controls.Add($sd.KeepToggle)
    $card.Controls.Add($keepRow)
    $card.Controls.Add((New-Hint '이 옵션을 활성화하면 폴더 드롭시 원본 폴더 구조를 그대로 유지하여 저장해요.'))
    $root.Controls.Add($card)

    # ── 아래쪽 버튼 (오른쪽 정렬) ──
    $footer = New-Object System.Windows.Forms.FlowLayoutPanel
    $footer.Dock = 'Bottom'; $footer.Height = P 56
    $footer.FlowDirection = 'RightToLeft'; $footer.WrapContents = $false
    $footer.Padding = New-Pad (P 16) (P 10) (P 16) (P 10)
    $sd.Footer = $footer
    $cancel = New-Button '취소'; $cancel.DialogResult = 'Cancel'
    $ok = New-Button '이 설정으로 실행' $true
    $ok.add_Click({ Confirm-Settings })
    $footer.Controls.Add($cancel); $footer.Controls.Add($ok)

    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = 'Fill'; $scroll.AutoScroll = $true
    $scroll.AutoScrollMargin = New-Size (P 16) (P 8)
    $root.Location = New-Object System.Drawing.Point -ArgumentList (P 16), (P 8)
    $scroll.Controls.Add($root)

    $d.Controls.Add($scroll)
    $d.Controls.Add($footer)
    $d.AcceptButton = $ok
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

    $p0 = [string]$paths[0]
    if (Use-CustomOut $o) { $script:LastOut = ([string]$o['out_dir']).Trim() }
    elseif ([System.IO.Directory]::Exists($p0)) { $script:LastOut = [System.IO.Path]::Combine($p0, $OutDirName) }
    else { $script:LastOut = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($p0), $OutDirName) }
    $o['last_out'] = [string]$script:LastOut   # 다음에 실행해도 '최근 결과 폴더'를 열 수 있게 함
    Save-Opts $o

    $script:Zone.Text = '처리 중…'
    $script:Zone.State = 2
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
    try {
        Add-Type -TypeDefinition $UiCode -ReferencedAssemblies System.Windows.Forms, System.Drawing -Language CSharp
    } catch {
        Show-Error ("화면 모듈을 준비하지 못했습니다.`r`n`r`n" + $_.Exception.Message) -Fatal
    }
    $script:Font      = New-Object System.Drawing.Font -ArgumentList 'Malgun Gothic', 9.5
    $script:FontSmall = New-Object System.Drawing.Font -ArgumentList 'Malgun Gothic', 9
    $script:FontTitle = New-Object System.Drawing.Font -ArgumentList 'Malgun Gothic', 10.5, ([System.Drawing.FontStyle]::Bold)
    $script:ColBg     = New-Rgb 243 243 243
    $script:IdleText  = '여기에 이미지 / 폴더를 드롭하세요'
    $script:Busy = $false
    $script:LastOut = $null
    $saved = Load-Opts
    if ($saved -and ([string]$saved['last_out']).Trim()) { $script:LastOut = ([string]$saved['last_out']).Trim() }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = '명조 이미지 간편 수정 v' + $AppVersion
    $f.Font = $script:Font
    $f.BackColor = $script:ColBg
    $f.ClientSize  = New-Size (P 580) (P 520)
    $f.MinimumSize = New-Size (P 420) (P 400)
    $f.StartPosition = 'CenterScreen'
    $f.TopMost = $true
    $f.Padding = New-Pad (P 14)
    $script:Main = $f

    # 위쪽 막대: 항상 위 / 결과 폴더 열기
    $topBar = New-Object CardPanel
    $topBar.S = $script:Scale
    $topBar.Dock = 'Top'; $topBar.Height = P 54
    $topBar.Padding = New-Pad (P 14) (P 8) (P 10) (P 8)
    $chk = New-Toggle '항상 위' $true
    $chk.Dock = 'Left'
    $chk.add_CheckedChanged({ $script:Main.TopMost = $script:TopChk.Checked })
    $script:TopChk = $chk
    $btn = New-Button '최근 결과 폴더'
    $btn.Margin = New-Pad 0
    $btn.Dock = 'Right'
    $btn.add_Click({
        $p = $script:LastOut
        if ($p -and [System.IO.Directory]::Exists($p)) { [void][System.Diagnostics.Process]::Start('explorer.exe', '"' + $p + '"') }
        else { Write-Log '열 수 있는 최근 결과 폴더가 없습니다.' }
    })
    $topBar.Controls.Add($chk); $topBar.Controls.Add($btn)

    # 드롭 영역
    $zone = New-Object DropZone
    $zone.S = $script:Scale
    $zone.Text = $script:IdleText
    $zone.Dock = 'Fill'
    $zone.Font = New-Object System.Drawing.Font -ArgumentList 'Malgun Gothic', 14
    $script:Zone = $zone

    # 진행 로그 카드
    $logCard = New-Object CardPanel
    $logCard.S = $script:Scale
    $logCard.Dock = 'Bottom'; $logCard.Height = P 190
    $logCard.Padding = New-Pad (P 16) (P 12) (P 12) (P 12)
    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.WordWrap = $false
    $log.BorderStyle = 'None'
    $log.Dock = 'Fill'
    $log.Font = $script:FontSmall
    $log.BackColor = [System.Drawing.Color]::White
    $script:LogBox = $log
    $logTitle = New-Object System.Windows.Forms.Label
    $logTitle.Text = '진행 로그'; $logTitle.AutoSize = $false
    $logTitle.Dock = 'Top'; $logTitle.Height = P 26
    $logTitle.TextAlign = 'MiddleLeft'
    $logTitle.Font = $script:FontTitle
    $logCard.Controls.Add($log); $logCard.Controls.Add($logTitle)

    $spTop = New-Object System.Windows.Forms.Panel;    $spTop.Dock = 'Top';    $spTop.Height = P 10
    $spBot = New-Object System.Windows.Forms.Panel;    $spBot.Dock = 'Bottom'; $spBot.Height = P 10

    # 도킹은 나중에 추가한 컨트롤부터 적용됨
    $f.Controls.Add($zone); $f.Controls.Add($spBot); $f.Controls.Add($logCard); $f.Controls.Add($spTop); $f.Controls.Add($topBar)

    $zone.add_DragEnter({
        param($s, $e)
        if (-not $script:Busy -and $e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
            $script:Zone.State = 1
        } else { $e.Effect = [System.Windows.Forms.DragDropEffects]::None }
    })
    $zone.add_DragLeave({ if (-not $script:Busy) { $script:Zone.State = 0 } })
    $zone.add_DragDrop({
        param($s, $e)
        $script:Zone.State = 0
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
            $script:Zone.State = 0
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
        $script:DropLog = New-Object System.Collections.Generic.List[string]
        Write-Log ('설정: ' + ((Get-Desc $o) -join ' · '))
        Invoke-Batch $DropArgs $o
        # 콘솔 창 없이 실행되므로 결과를 안내창으로 보여줌
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($ln in $script:DropLog) { if ($ln -like '설정:*' -or $ln -like '완료:*' -or $ln -like '*실패*' -or $ln -like '처리할 이미지가 없습니다*') { $lines.Add($ln) } }
        $icon = if ($lines | Where-Object { $_ -like '*실패*' -or $_ -like '처리할 이미지가 없습니다*' }) { 'Warning' } else { 'Information' }
        if ($lines.Count -gt 12) { $lines = $lines.GetRange(0, 12); $lines.Add('...') }
        [void][System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), ('명조 이미지 간편 수정 v' + $AppVersion), 'OK', $icon)
    } else {
        Start-Gui
    }
} catch {
    Show-Error ("실행 중 오류가 발생했습니다.`r`n`r`n" + ($_ | Out-String)) -Fatal
}
