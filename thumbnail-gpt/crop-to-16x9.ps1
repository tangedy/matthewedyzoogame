# Centre-crops images to 16:9 and resizes them to 1920x1080 PNGs, saved next to the
# originals as <name>_16x9.png. Usage:
#   powershell -ExecutionPolicy Bypass -File crop-to-16x9.ps1 image1.png image2.webp
# With no arguments it does every image in this folder's "raw" subfolder.

param([string[]]$Paths)

Add-Type -AssemblyName System.Drawing

$TargetWidth = 1920
$TargetHeight = 1080

if (-not $Paths -or $Paths.Count -eq 0) {
	$raw = Join-Path $PSScriptRoot "raw"
	$Paths = Get-ChildItem $raw -File -Include *.png, *.jpg, *.jpeg, *.webp -Recurse | ForEach-Object { $_.FullName }
}

foreach ($path in $Paths) {
	$full = (Resolve-Path $path).Path
	$source = [System.Drawing.Image]::FromFile($full)
	try {
		# The largest 16:9 rectangle that fits, centred.
		$cropWidth = $source.Width
		$cropHeight = [int][Math]::Round($cropWidth * 9 / 16)
		if ($cropHeight -gt $source.Height) {
			$cropHeight = $source.Height
			$cropWidth = [int][Math]::Round($cropHeight * 16 / 9)
		}
		$x = [int](($source.Width - $cropWidth) / 2)
		$y = [int](($source.Height - $cropHeight) / 2)

		$output = New-Object System.Drawing.Bitmap $TargetWidth, $TargetHeight
		$graphics = [System.Drawing.Graphics]::FromImage($output)
		$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
		$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
		$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
		$destination = New-Object System.Drawing.Rectangle 0, 0, $TargetWidth, $TargetHeight
		$graphics.DrawImage($source, $destination, $x, $y, $cropWidth, $cropHeight, [System.Drawing.GraphicsUnit]::Pixel)
		$graphics.Dispose()

		$name = [System.IO.Path]::GetFileNameWithoutExtension($full)
		$target = Join-Path ([System.IO.Path]::GetDirectoryName($full)) "${name}_16x9.png"
		$output.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
		$output.Dispose()
		Write-Output "Saved $target"
	} finally {
		$source.Dispose()
	}
}
