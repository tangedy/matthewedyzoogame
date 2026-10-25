<#
Creates every Wash the Zoo developer product on Roblox through Open Cloud and writes the
new ids into src/shared/FeatureConfig/MonetizationIds.luau.

Usage (from the repo root):
  $env:ROBLOX_API_KEY = "<your Open Cloud key>"   # scopes: developer-product:read, developer-product:write
  powershell -ExecutionPolicy Bypass -File tools/create-products.ps1 -UniverseId 1234567890

  -DryRun     list what would be created, change nothing.

Safe to run again: products that already exist (same name) are reused, not duplicated.
Their price is NOT changed on a re-run; change an existing product's price on the Creator
Dashboard (Monetization > Developer Products).
Names, prices and descriptions below must match MonetizationConfig.luau; prices there are
display-only, Roblox charges what is set here.

Game passes (VIP Keeper, 399) are not covered: make it on the Creator Dashboard and paste the
id into MonetizationIds.luau by hand.
#>
param(
	[Parameter(Mandatory = $true)][long]$UniverseId,
	[switch]$DryRun
)

$ErrorActionPreference = "Stop"
$apiKey = $env:ROBLOX_API_KEY
if (-not $apiKey) {
	throw "Set `$env:ROBLOX_API_KEY first (Creator Dashboard > Open Cloud > API Keys)."
}

# Key = MonetizationConfig key. Name must be unique in the universe.
$products = @(
	@{ Key = "SuperSoapStarter"; Name = "Super Soap (Starter)"; Price = 5; Description = "2x clean power for 10 min." },
	@{ Key = "SuperSoap"; Name = "Super Soap"; Price = 9; Description = "2x clean power for 10 min. Stacks." },
	@{ Key = "SuperSoapLarge"; Name = "Super Soap x3"; Price = 25; Description = "2x clean power for 30 min. Stacks." },
	@{ Key = "CalmTreat"; Name = "Calm Treat"; Price = 15; Description = "Freeze patience for 60s." },
	@{ Key = "LuckySoap"; Name = "Lucky Soap"; Price = 29; Description = "Next 5 walk-ins: rarer, more mutations." },
	@{ Key = "AutoCollect2h"; Name = "Auto-Collect"; Price = 49; Description = "Pens pay you for 30 min. Stacks." },
	@{ Key = "SpeedBoost"; Name = "2x Speed"; Price = 19; Description = "Run 2x faster for 10 min. Stacks." },
	@{ Key = "IncredibleLuck"; Name = "Incredible Luck"; Price = 79; Description = "Rare+ walk-ins far likelier for 10 min." },
	@{ Key = "CashSmall"; Name = "Pile of Cash"; Price = 25; Description = "5 min of farm income." },
	@{ Key = "CashMedium"; Name = "Bag of Cash"; Price = 75; Description = "20 min of farm income." },
	@{ Key = "CashLarge"; Name = "Vault of Cash"; Price = 149; Description = "60 min of farm income." },
	@{ Key = "CleanNow"; Name = "Clean Now"; Price = 39; Description = "Wash a too-dirty animal now." },
	@{ Key = "CleanNow1"; Name = "Clean Now +1"; Price = 79; Description = "Wash a too-dirty animal now." },
	@{ Key = "CleanNow2"; Name = "Clean Now +2"; Price = 149; Description = "Wash a too-dirty animal now." },
	@{ Key = "CleanNow3"; Name = "Clean Now +3"; Price = 249; Description = "Wash a too-dirty animal now." },
	@{ Key = "CleanNow4"; Name = "Clean Now +4"; Price = 399; Description = "Wash a too-dirty animal now." },
	@{ Key = "TruckAnimal"; Name = "Delivery Truck Animal"; Price = 199; Description = "The animal on your truck." },
	@{ Key = "LimitedAxolotl"; Name = "Limited Axolotl"; Price = 1000; Description = "Limited Mythic. Only 1,000 ever." },
	@{ Key = "OfflineDouble"; Name = "2x Offline"; Price = 25; Description = "Double your away earnings." },
	@{ Key = "HoseTier2"; Name = "Scrub Brush"; Price = 19; Description = "Your next hose." },
	@{ Key = "HoseTier3"; Name = "Garden Hose"; Price = 29; Description = "Your next hose." },
	@{ Key = "HoseTier4"; Name = "Power Washer"; Price = 99; Description = "Your next hose." },
	@{ Key = "HoseTier5"; Name = "Foam Cannon"; Price = 249; Description = "Your next hose." }
)

$base = "https://apis.roblox.com/developer-products/v2/universes/$UniverseId/developer-products"
$headers = @{ "x-api-key" = $apiKey }

# What already exists, by name.
$existing = @{}
$token = $null
do {
	$url = "$base/creator?pageSize=50"
	if ($token) { $url += "&pageToken=$([uri]::EscapeDataString($token))" }
	$page = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
	foreach ($p in $page.developerProducts) { $existing[$p.name] = [long]$p.productId }
	$token = $page.nextPageToken
	Start-Sleep -Milliseconds 400 # 3 requests per second
} while ($token)

Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
$client.DefaultRequestHeaders.Add("x-api-key", $apiKey)

$ids = @{}
foreach ($product in $products) {
	if ($existing.ContainsKey($product.Name)) {
		$ids[$product.Key] = $existing[$product.Name]
		Write-Host "exists   $($product.Name) -> $($ids[$product.Key])"
		continue
	}
	if ($DryRun) {
		Write-Host "create   $($product.Name) ($($product.Price) R$)"
		$ids[$product.Key] = 0
		continue
	}
	$form = New-Object System.Net.Http.MultipartFormDataContent
	$form.Add((New-Object System.Net.Http.StringContent($product.Name)), "name")
	$form.Add((New-Object System.Net.Http.StringContent($product.Description)), "description")
	$form.Add((New-Object System.Net.Http.StringContent([string]$product.Price)), "price")
	$form.Add((New-Object System.Net.Http.StringContent("true")), "isForSale")
	$response = $client.PostAsync($base, $form).Result
	$body = $response.Content.ReadAsStringAsync().Result
	if (-not $response.IsSuccessStatusCode) {
		throw "Creating $($product.Name) failed ($([int]$response.StatusCode)): $body"
	}
	$ids[$product.Key] = [long](($body | ConvertFrom-Json).productId)
	Write-Host "created  $($product.Name) -> $($ids[$product.Key])"
	Start-Sleep -Milliseconds 400
}

if ($DryRun) {
	Write-Host "Dry run: nothing created, MonetizationIds.luau unchanged."
	return
}

# Rewrite each "Key = <number>," line inside the Products table.
$path = Join-Path $PSScriptRoot "..\src\shared\FeatureConfig\MonetizationIds.luau"
$text = [IO.File]::ReadAllText($path)
foreach ($key in $ids.Keys) {
	$text = [regex]::Replace($text, "(?m)^(\t\t$key = )\d+,", "`${1}$($ids[$key]),")
}
[IO.File]::WriteAllText($path, $text)
Write-Host "Wrote $($ids.Count) product ids to $path"
