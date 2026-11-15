# Makes the plugin's pictures (resources/): the icons, with their sizes (src/data/icon_sizes.lua), and the
# forest's zones.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\make_map_art.ps1 [-Detail 3]
#
# -Detail: the icons from the wiki's pictures, and those drawn here, are saved at this many times the size the plugin
# places them at (src/data/icon_sizes.lua holds the placed size), so that they stay sharp on a large map.
#
# -WikiMapFolder: the RuneScape Wiki's map tiles of the map square the forest's zones are copied from (tools\wiki_map,
# <x>_<y>.png at zoom 3: maps.runescape.wiki/rs/versions/<version>/map_squares/-1/3/0_<x>_<y>.png for 130..131, 20..21).
# -WikiImagesFolder: the RuneScape Wiki's pictures of the tool sources and barriers (tools\wiki_images, each named
# after its feature's key: "Fire pit (Mazcab).png" is fire_pit.png, and so on).
#
# The node icons are the wiki's pictures of the nodes (tools\wiki_images, named by key), each fitted to the size the
# icon had in Donnor and Oreant's map pack (NODE_BOXES below) with a pale outline, as the pack's had. Those in
# HAND_MADE_ICONS are drawn by hand and kept in resources\ as they are. The entrance signs are drawn here. The
# map's frame, compass and skill symbols are not pictures: the plugin draws the frame, and the others are the
# game's.
# Run with Windows PowerShell (it has System.Drawing).
param(
    [int]$Detail = 3,
    [string]$WikiImagesFolder,
    [string]$WikiMapFolder,
    [string]$PluginFolder
)
# The plugin's folder is the one above tools/.
if (-not $PluginFolder) { $PluginFolder = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent }
if (-not $WikiImagesFolder) { $WikiImagesFolder = Join-Path $PluginFolder 'tools\wiki_images' }
if (-not $WikiMapFolder) { $WikiMapFolder = Join-Path $PluginFolder 'tools\wiki_map' }

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;

public class Picture
{
    public int Width, Height;
    public int[] Pixels; // ARGB

    public Picture(int width, int height) { Width = width; Height = height; Pixels = new int[width * height]; }

    public static Picture FromBitmap(Bitmap source)
    {
        using (var bitmap = source.Clone(new Rectangle(0, 0, source.Width, source.Height), PixelFormat.Format32bppArgb))
        {
            var picture = new Picture(bitmap.Width, bitmap.Height);
            var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly,
                PixelFormat.Format32bppArgb);
            Marshal.Copy(data.Scan0, picture.Pixels, 0, picture.Pixels.Length);
            bitmap.UnlockBits(data);
            return picture;
        }
    }

    public static Picture Load(string path)
    {
        using (var source = new Bitmap(path)) return FromBitmap(source);
    }

    public Bitmap ToBitmap()
    {
        var bitmap = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
        var data = bitmap.LockBits(new Rectangle(0, 0, Width, Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(Pixels, 0, data.Scan0, Pixels.Length);
        bitmap.UnlockBits(data);
        return bitmap;
    }

    public void Save(string path)
    {
        using (var bitmap = ToBitmap()) bitmap.Save(path, ImageFormat.Png);
    }

    // The picture turned a quarter turn anticlockwise, so its right end is at the top.
    public Picture TurnedLeft()
    {
        var turned = new Picture(Height, Width);
        for (int y = 0; y < Height; y++)
            for (int x = 0; x < Width; x++)
                turned.Pixels[(Width - 1 - x) * Height + y] = Pixels[y * Width + x];
        return turned;
    }

    public Picture Crop(int x, int y, int width, int height)
    {
        var crop = new Picture(width, height);
        for (int row = 0; row < height; row++)
            Array.Copy(Pixels, (y + row) * Width + x, crop.Pixels, row * width, width);
        return crop;
    }
}

public static class MapArt
{
    static int Channel(int argb, int shift) { return (argb >> shift) & 255; }

    // The wiki's four map tiles (256 pixels each, 8 pixels a game tile) of one map square as one picture, north up.
    public static Picture MapSquare(string folder, int squareX, int squareZ)
    {
        var square = new Picture(512, 512);
        for (int tileX = 0; tileX < 2; tileX++)
            for (int tileZ = 0; tileZ < 2; tileZ++)
            {
                string name = (squareX * 2 + tileX) + "_" + (squareZ * 2 + tileZ) + ".png";
                var tile = Picture.Load(System.IO.Path.Combine(folder, name));
                for (int y = 0; y < 256; y++)
                    Array.Copy(tile.Pixels, y * 256, square.Pixels, ((1 - tileZ) * 256 + y) * 512 + tileX * 256, 256);
            }
        return square;
    }

    // Where the wiki has no map a tile is black or clear: such pixels are made clear. Returns the share that is map.
    public static double ClearUnmapped(Picture picture)
    {
        int mapped = 0;
        for (int p = 0; p < picture.Pixels.Length; p++)
        {
            int pixel = picture.Pixels[p];
            if (Channel(pixel, 24) == 0 || (pixel & 0xFFFFFF) == 0) picture.Pixels[p] = 0;
            else mapped++;
        }
        return mapped / (double)picture.Pixels.Length;
    }

    // A picture scaled down to fit a box, keeping its proportions.
    public static Picture Fit(Picture source, int boxWidth, int boxHeight)
    {
        double scale = Math.Min(boxWidth / (double)source.Width, boxHeight / (double)source.Height);
        int width = Math.Max(1, (int)Math.Round(source.Width * scale)), height = Math.Max(1, (int)Math.Round(source.Height * scale));
        using (var from = source.ToBitmap())
        using (var to = new Bitmap(width, height, PixelFormat.Format32bppArgb))
        {
            using (var graphics = Graphics.FromImage(to))
            {
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                graphics.CompositingQuality = CompositingQuality.HighQuality;
                using (var wrap = new ImageAttributes())
                {
                    wrap.SetWrapMode(WrapMode.TileFlipXY);
                    graphics.DrawImage(from, new Rectangle(0, 0, width, height), 0, 0, from.Width, from.Height, GraphicsUnit.Pixel, wrap);
                }
            }
            return Picture.FromBitmap(to);
        }
    }

    // The picture with a coloured line drawn round its shape, as the map pack's icons have.
    public static Picture Outline(Picture source, int rgb, double thickness)
    {
        int margin = (int)Math.Ceiling(thickness) + 1, reach = margin;
        var result = new Picture(source.Width + margin * 2, source.Height + margin * 2);
        for (int y = 0; y < result.Height; y++)
            for (int x = 0; x < result.Width; x++)
            {
                double lineAlpha = 0;
                for (int dy = -reach; dy <= reach; dy++)
                    for (int dx = -reach; dx <= reach; dx++)
                    {
                        int sx = x - margin + dx, sy = y - margin + dy;
                        if (sx < 0 || sy < 0 || sx >= source.Width || sy >= source.Height) continue;
                        double nearness = Math.Min(1.0, Math.Max(0.0, thickness + 0.5 - Math.Sqrt(dx * dx + dy * dy)));
                        lineAlpha = Math.Max(lineAlpha, nearness * Channel(source.Pixels[sy * source.Width + sx], 24) / 255.0);
                    }
                int ownX = x - margin, ownY = y - margin, own = 0;
                if (ownX >= 0 && ownY >= 0 && ownX < source.Width && ownY < source.Height) own = source.Pixels[ownY * source.Width + ownX];
                double ownAlpha = Channel(own, 24) / 255.0, alpha = ownAlpha + lineAlpha * (1 - ownAlpha);
                if (alpha <= 0) continue;
                int pixel = (int)Math.Round(alpha * 255) << 24;
                for (int shift = 0; shift < 24; shift += 8)
                {
                    double mixed = (Channel(own, shift) * ownAlpha + Channel(rgb, shift) * lineAlpha * (1 - ownAlpha)) / alpha;
                    pixel |= (int)Math.Round(mixed) << shift;
                }
                result.Pixels[y * result.Width + x] = pixel;
            }
        return result;
    }

    // Pictures are drawn at DrawScale times their placed size, so the drawing code works in placed pixels.
    public static double DrawScale = 1;
    static Picture Drawn(int width, int height, Action<Graphics> draw)
    {
        using (var bitmap = new Bitmap((int)Math.Round(width * DrawScale), (int)Math.Round(height * DrawScale), PixelFormat.Format32bppArgb))
        {
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.ScaleTransform((float)DrawScale, (float)DrawScale);
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                draw(graphics);
            }
            return Picture.FromBitmap(bitmap);
        }
    }

    // The wiki's picture of the lightning has scenery behind it, so a bolt is drawn instead.
    public static Picture LightningBolt()
    {
        return Drawn(34, 48, graphics =>
        {
            var bolt = new[] { new PointF(21, 0), new PointF(4, 25), new PointF(15, 25), new PointF(9, 48),
                new PointF(31, 18), new PointF(19, 18), new PointF(27, 0) };
            using (var brush = new LinearGradientBrush(new Point(0, 0), new Point(0, 48), Color.White, Color.FromArgb(120, 220, 255)))
                graphics.FillPolygon(brush, bolt);
        });
    }

    // The wiki's picture of the web has scenery behind it, so a web is drawn instead.
    public static Picture SpiderWeb()
    {
        return Drawn(46, 46, graphics =>
        {
            using (var pen = new Pen(Color.FromArgb(245, 240, 225), 1.6f))
            {
                for (int spoke = 0; spoke < 8; spoke++)
                {
                    double angle = spoke * Math.PI / 4 + 0.2;
                    graphics.DrawLine(pen, 23, 23, 23 + (float)(Math.Cos(angle) * 22), 23 + (float)(Math.Sin(angle) * 22));
                }
                foreach (float radius in new[] { 7f, 14f, 21f })
                {
                    var ring = new PointF[8];
                    for (int corner = 0; corner < 8; corner++)
                    {
                        double angle = corner * Math.PI / 4 + 0.2;
                        ring[corner] = new PointF(23 + (float)(Math.Cos(angle) * radius), 23 + (float)(Math.Sin(angle) * radius));
                    }
                    graphics.DrawPolygon(pen, ring);
                }
            }
        });
    }

    // A wooden trail sign pointing right: a board with its right end pointed and its left end flat, its long
    // sides parallel, and a name painted on it as large as the flat part holds.
    public static Picture TrailSign(string text, int length, int height)
    {
        return Drawn(length, height, graphics =>
        {
            float tip = height / 2f, edge = 0.8f, middle = height / 2f;
            var board = new GraphicsPath();
            board.AddPolygon(new[] { new PointF(edge, edge), new PointF(length - tip, edge),
                new PointF(length - edge, middle), new PointF(length - tip, height - edge),
                new PointF(edge, height - edge) });
            using (var wood = new LinearGradientBrush(new PointF(0, 0), new PointF(0, height),
                Color.FromArgb(184, 124, 66), Color.FromArgb(118, 72, 33)))
                graphics.FillPath(wood, board);
            // The grain: faint wavy lines along the board.
            graphics.SetClip(board);
            using (var grain = new Pen(Color.FromArgb(80, 70, 38, 14), 0.6f))
            {
                foreach (float share in new[] { 0.22f, 0.5f, 0.78f })
                {
                    float y = height * share;
                    graphics.DrawBezier(grain, 0, y, length * 0.3f, y - 1.2f, length * 0.6f, y + 1.2f, length, y);
                }
            }
            graphics.ResetClip();
            using (var rim = new Pen(Color.FromArgb(58, 34, 14), 1.4f))
            {
                rim.LineJoin = LineJoin.Miter;
                graphics.DrawPath(rim, board);
            }
            using (var nail = new SolidBrush(Color.FromArgb(52, 44, 36)))
                graphics.FillEllipse(nail, 2.6f, middle - 1f, 2f, 2f);
            using (var family = new FontFamily("Georgia"))
            using (var letters = new GraphicsPath())
            {
                letters.AddString(text, family, (int)FontStyle.Bold, 100, new PointF(0, 0), StringFormat.GenericTypographic);
                var bounds = letters.GetBounds();
                float left = 6.5f, right = length - tip - 1f, top = height * 0.17f, bottom = height * 0.83f;
                float scale = Math.Min((right - left) / bounds.Width, (bottom - top) / bounds.Height);
                using (var place = new Matrix())
                {
                    place.Translate((left + right) / 2f, (top + bottom) / 2f);
                    place.Scale(scale, scale);
                    place.Translate(-(bounds.X + bounds.Width / 2f), -(bounds.Y + bounds.Height / 2f));
                    letters.Transform(place);
                }
                using (var shadow = (GraphicsPath)letters.Clone())
                using (var drop = new Matrix())
                using (var dark = new SolidBrush(Color.FromArgb(200, 40, 22, 8)))
                using (var paint = new SolidBrush(Color.FromArgb(247, 231, 180)))
                {
                    drop.Translate(0.5f, 0.6f);
                    shadow.Transform(drop);
                    graphics.FillPath(dark, shadow);
                    graphics.FillPath(paint, letters);
                }
            }
        });
    }

    // The wiki's picture of the portal has scenery behind it, so a portal is drawn instead, looking like the game's
    // one: a sheet of pale cyan light standing across the path, brighter at its foot, with orange crystal shards
    // along the ground in front of it. It is kept low and see-through so it does not weigh on the map.
    public static Picture Portal()
    {
        return Drawn(48, 22, graphics =>
        {
            var sheet = new Rectangle(3, 1, 42, 16);
            using (var light = new LinearGradientBrush(new Point(0, 1), new Point(0, 17),
                Color.FromArgb(150, 150, 235, 250), Color.FromArgb(170, 225, 255, 255)))
                graphics.FillRectangle(light, sheet);
            using (var streak = new Pen(Color.FromArgb(90, 255, 255, 255), 1.5f))
            {
                graphics.DrawLine(streak, 12, 3, 10, 15);
                graphics.DrawLine(streak, 30, 2, 33, 16);
            }
            using (var edge = new Pen(Color.FromArgb(160, 90, 210, 230), 1f))
                graphics.DrawRectangle(edge, sheet);
            using (var crystal = new SolidBrush(Color.FromArgb(220, 235, 120, 45)))
            using (var crystalLight = new SolidBrush(Color.FromArgb(220, 255, 175, 95)))
            {
                var shards = new[] { 4, 12, 20, 28, 36, 43 };
                for (int index = 0; index < shards.Length; index++)
                {
                    int x = shards[index], height = index % 2 == 0 ? 5 : 4;
                    var shard = new[] { new Point(x - 2, 22), new Point(x, 22 - height), new Point(x + 2, 22) };
                    graphics.FillPolygon(index % 2 == 0 ? crystal : crystalLight, shard);
                }
            }
        });
    }

}
'@

$ErrorActionPreference = 'Stop'
# One flat folder, as PrettyUI uses, since pictures in sub-folders are untried in this client.
$resourceFolder = Join-Path $PluginFolder 'resources'
New-Item -ItemType Directory -Force $resourceFolder | Out-Null

$icons = [ordered]@{}
$iconDetail = @{} # key -> how many times its placed size the picture is (1 for the pack's)
[MapArt]::DrawScale = $Detail

# --- The node icons: the wiki's pictures, each in the box the map pack's icon had ---------------------------------
# The pack's icons' sizes, outline included. The plugin's layout and the map's scale were made with these.
$NODE_BOXES = [ordered]@{
    chest = 56, 49; fungus = 43, 53; flowers = 47, 57; mushrooms = 59, 44; rocks = 51, 41; obelisk = 34, 57
    explorer = 80, 44; monk = 76, 32; pool = 45, 51; pahtli = 39, 53; traitor = 38, 52
}
# The explorer's box is wider than the pack's 70: he is a lying figure, fitted by his width, and at 70 looks too
# thin.
$NODE_OUTLINE_RGB = 0xF2E6C8 # pale, as the pack's icons are outlined
# The outline's thickness in placed pixels: a light band and a dark rim outside it, matching the hand-made icons
# (a band of 3 of their pixels and a rim of 1, drawn at 0.8 scale).
$OUTLINE_BAND, $OUTLINE_RIM = 2.4, 0.8
# Icons whose pictures were made by hand, outlined white. They are kept in resources\ as they are and placed at
# these heights (the pack's icons' heights) in their own proportions.
$HAND_MADE_ICONS = @{ flowers = 56; obelisk = 50 }
foreach ($key in $NODE_BOXES.Keys) {
    if ($HAND_MADE_ICONS.Contains($key)) {
        $kept = [Picture]::Load((Join-Path $resourceFolder "$key.png"))
        $icons[$key] = $kept
        $iconDetail[$key] = $kept.Height / $HAND_MADE_ICONS[$key]
        "  ${key}: $($kept.Width)x$($kept.Height), kept (made by hand)"
        continue
    }
    $box = $NODE_BOXES[$key]
    # The picture is fitted inside the box less the outline, so that the icon keeps the box's size.
    $inner = [MapArt]::Fit([Picture]::Load((Join-Path $WikiImagesFolder "$key.png")), ($box[0] - 9) * $Detail, ($box[1] - 9) * $Detail)
    $outlined = [MapArt]::Outline([MapArt]::Outline($inner, $NODE_OUTLINE_RGB, $OUTLINE_BAND * $Detail), 0x14140F,
        $OUTLINE_RIM * $Detail)
    $outlined.Save((Join-Path $resourceFolder "$key.png"))
    $icons[$key] = $outlined
    $iconDetail[$key] = $Detail
    "  ${key}: $($outlined.Width)x$($outlined.Height)"
}


# --- The tool and barrier icons: each pair shares its outline colour --------------------------------------------
function New-OutlinedIcon([string]$key, $picture, [int]$rgb) {
    # A dark edge outside the coloured line, as the map pack's icons have, keeps it clear on sand and on trees.
    $outlined = [MapArt]::Outline([MapArt]::Outline($picture, $rgb, $OUTLINE_BAND * $Detail), 0x14140F, $OUTLINE_RIM * $Detail)
    $outlined.Save((Join-Path $resourceFolder "$key.png"))
    $script:icons[$key] = $outlined
    $script:iconDetail[$key] = $Detail
    return $outlined
}
function Get-WikiIcon([string]$fileName) {
    return [MapArt]::Fit([Picture]::Load((Join-Path $WikiImagesFolder $fileName)), 54 * $Detail, 46 * $Detail)
}
$toolPairs = @(
    @{ source = 'fire_pit'; barrier = 'web'; rgb = 0xFF8A1E
       sourcePicture = (Get-WikiIcon 'fire_pit.png'); barrierPicture = [MapArt]::Fit([MapArt]::SpiderWeb(), 46 * $Detail, 46 * $Detail) },
    @{ source = 'mysterious_weapon'; barrier = 'barricade'; rgb = 0xC77DFF
       sourcePicture = (Get-WikiIcon 'mysterious_weapon.png'); barrierPicture = (Get-WikiIcon 'barricade.png') },
    @{ source = 'lightning'; barrier = 'pillars'; rgb = 0x4FD8FF
       sourcePicture = [MapArt]::Fit([MapArt]::LightningBolt(), 54 * $Detail, 46 * $Detail); barrierPicture = (Get-WikiIcon 'pillars.png') },
    @{ source = 'axe_in_stake'; barrier = 'bound_logs'; rgb = 0xFF5A4F
       sourcePicture = (Get-WikiIcon 'axe_in_stake.png'); barrierPicture = (Get-WikiIcon 'bound_logs.png') },
    @{ source = 'mysterious_statue'; barrier = 'statues'; rgb = 0x7DDC5A
       sourcePicture = (Get-WikiIcon 'mysterious_statue.png'); barrierPicture = (Get-WikiIcon 'statues.png') },
    @{ source = 'goebie'; barrier = 'portal_light'; rgb = 0xFF7AD1
       sourcePicture = (Get-WikiIcon 'goebie.png'); barrierPicture = [MapArt]::Portal() }
)
foreach ($pair in $toolPairs) {
    New-OutlinedIcon $pair.source $pair.sourcePicture $pair.rgb | Out-Null
    New-OutlinedIcon $pair.barrier $pair.barrierPicture $pair.rgb | Out-Null
}

# --- The entrance signs: wooden trail signs naming where each opening leads, pointing out of the forest -------
# OTOT's opening is on the forest's north edge, so its sign is turned to point up; KANATAH's is on the east edge.
$SIGN_HEIGHT = 26
$signs = @(
    @{ key = 'sign_otot'; text = 'OTOT'; length = 70; pointsUp = $true },
    @{ key = 'sign_kanatah'; text = 'KANATAH'; length = 110; pointsUp = $false }
)
foreach ($sign in $signs) {
    $picture = [MapArt]::TrailSign($sign.text, $sign.length, $SIGN_HEIGHT)
    if ($sign.pointsUp) { $picture = $picture.TurnedLeft() }
    $outlined = [MapArt]::Outline([MapArt]::Outline($picture, $NODE_OUTLINE_RGB, $OUTLINE_BAND * $Detail), 0x14140F,
        $OUTLINE_RIM * $Detail)
    $outlined.Save((Join-Path $resourceFolder "$($sign.key).png"))
    $icons[$sign.key] = $outlined
    $iconDetail[$sign.key] = $Detail
    "  $($sign.key): $($outlined.Width)x$($outlined.Height)"
}

# --- The forest's zones: 8x8 tiles each, copied by the game from map square 65,10 -------------------------------
# Each is named after the tile of its south-west corner, which is how the game names a zone's source.
$templateSquareX = 65; $templateSquareZ = 10
$templateSquare = [MapArt]::MapSquare($WikiMapFolder, $templateSquareX, $templateSquareZ)
$zoneCount = 0
for ($zoneX = 0; $zoneX -lt 8; $zoneX++) {
    for ($zoneZ = 0; $zoneZ -lt 8; $zoneZ++) {
        $zone = $templateSquare.Crop($zoneX * 64, (7 - $zoneZ) * 64, 64, 64)
        if ([MapArt]::ClearUnmapped($zone) -lt 0.05) { continue }
        $zoneName = "$($templateSquareX * 64 + $zoneX * 8)_$($templateSquareZ * 64 + $zoneZ * 8)"
        $zone.Save((Join-Path $resourceFolder "zone_$zoneName.png"))
        $zoneCount++
    }
}

# --- The icons' sizes, which the plugin places and scales them by -----------------------------------------------
$lua = New-Object System.Collections.Generic.List[string]
$lua.Add('-- The size each icon is placed at, in the map pack''s pixels. The plugin scales the pictures to these, as a')
$lua.Add('-- picture may be saved larger to stay sharp.')
$lua.Add('-- Made by tools/make_map_art.ps1: run it again instead of editing this file.')
$lua.Add('')
$lua.Add('return {')
foreach ($key in $icons.Keys) {
    $width = [int][Math]::Round($icons[$key].Width / $iconDetail[$key])
    $height = [int][Math]::Round($icons[$key].Height / $iconDetail[$key])
    $lua.Add("    $key = { width = $width, height = $height },")
}
$lua.Add('}')
$dataFolder = Join-Path $PluginFolder 'src\data'
New-Item -ItemType Directory -Force $dataFolder | Out-Null
[System.IO.File]::WriteAllText((Join-Path $dataFolder 'icon_sizes.lua'), ($lua -join "`r`n") + "`r`n")
"wrote $($icons.Count) icons and $zoneCount zones to resources\ and src\data\icon_sizes.lua"
