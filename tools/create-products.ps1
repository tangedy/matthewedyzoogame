<#
Creates every Wash the Zoo developer product and game pass on Roblox through Open Cloud and
writes the new ids into src/shared/FeatureConfig/MonetizationIds.luau. Game passes made here
are put on sale, so they show on the experience's Store page.

Usage (from the repo root):
  $env:ROBLOX_API_KEY = "<your Open Cloud key>"
  # scopes: developer-product:read, developer-product:write, game-pass:read, game-pass:write
  powershell -ExecutionPolicy Bypass -File tools/create-products.ps1 -UniverseId 1234567890

  Or put ROBLOX_API_KEY=... and ROBLOX_UNIVERSE_ID=... in the repo's .env (gitignored) and
  leave both out. A separate key for game passes can go in ROBLOX_GAMEPASS_API_KEY; without
  one, ROBLOX_API_KEY is used for both.

  -DryRun     list what would be created or updated, change nothing.
  -Update     also push the name, price, description and for-sale flag below onto products
              and passes that already exist, so they match this list.

Safe to run again: products and passes that already exist (same name) are reused, not
duplicated. Without -Update their price is left alone.
Names, prices and descriptions below must match MonetizationConfig.luau; prices there are
display-only, Roblox charges what is set here.
Passes are made without an icon; add one on the Creator Dashboard.
#>
param(
	[long]$UniverseId,
	[switch]$DryRun,
	[switch]$Update
)

$ErrorActionPreference = "Stop"

# NAME=value from the repo's .env (gitignored), or $null.
$envFile = Join-Path $PSScriptRoot "..\.env"
function Get-DotEnv([string]$name) {
	if (-not (Test-Path $envFile)) { return $null }
	$line = Get-Content $envFile | Where-Object { $_ -match "^\s*$name\s*=" } | Select-Object -First 1
	if ($line) { return ($line -split '=', 2)[1].Trim() }
	return $null
}

$apiKey = $env:ROBLOX_API_KEY
if (-not $apiKey) { $apiKey = Get-DotEnv "ROBLOX_API_KEY" }
if (-not $apiKey) {
	throw "Set `$env:ROBLOX_API_KEY or put ROBLOX_API_KEY=<key> in .env (Creator Dashboard > Open Cloud > API Keys)."
}
$passKey = $env:ROBLOX_GAMEPASS_API_KEY
if (-not $passKey) { $passKey = Get-DotEnv "ROBLOX_GAMEPASS_API_KEY" }
if (-not $passKey) { $passKey = $apiKey }
if (-not $UniverseId) {
	$fromEnv = Get-DotEnv "ROBLOX_UNIVERSE_ID"
	if ($fromEnv) { $UniverseId = [long]$fromEnv }
}
if (-not $UniverseId) {
	throw "Pass -UniverseId or put ROBLOX_UNIVERSE_ID=<id> in .env."
}

# Key = MonetizationConfig key. Name must be unique in the universe.
$products = @(
	@{ Key = "SuperSoapStarter"; Name = "Super Soap (Starter)"; Price = 5; Description = "2x clean power for 10 min." },
	@{ Key = "SuperSoap"; Name = "Super Soap"; Price = 9; Description = "2x clean power for 10 min. Stacks." },
	@{ Key = "SuperSoapLarge"; Name = "Super Soap x3"; Price = 25; Description = "2x clean power for 30 min. Stacks." },
	@{ Key = "CalmTreat"; Name = "Calm Treat"; Price = 15; Description = "Freeze patience for 60s." },
	@{ Key = "LuckySoap"; Name = "Lucky Soap"; Price = 29; Description = "Next 5 walk-ins: rarer, more mutations." },
	@{ Key = "AutoCollect2h"; Name = "Auto-Collect"; Price = 3; Description = "Pens pay you for 30 min. Stacks." },
	@{ Key = "SpeedBoost"; Name = "2x Speed"; Price = 16; Description = "Run 2x faster for 10 min. Stacks." },
	@{ Key = "IncredibleLuck"; Name = "Incredible Luck"; Price = 79; Description = "Rare+ walk-ins far likelier for 10 min." },
	@{ Key = "CashSmall"; Name = "Pile of Cash"; Price = 7; Description = "1 min of farm income." },
	@{ Key = "CashMedium"; Name = "Bag of Cash"; Price = 75; Description = "20 min of farm income." },
	@{ Key = "CashLarge"; Name = "Vault of Cash"; Price = 149; Description = "60 min of farm income." },
	@{ Key = "CleanNow"; Name = "Clean Now"; Price = 49; Description = "Wash a too-dirty animal now." },
	@{ Key = "CleanNow1"; Name = "Clean Now +1"; Price = 99; Description = "Wash a too-dirty animal now." },
	@{ Key = "CleanNow2"; Name = "Clean Now +2"; Price = 189; Description = "Wash a too-dirty animal now." },
	@{ Key = "CleanNow3"; Name = "Clean Now +3"; Price = 299; Description = "Wash a too-dirty animal now." },
	@{ Key = "CleanNow4"; Name = "Clean Now +4"; Price = 499; Description = "Wash a too-dirty animal now." },
	@{ Key = "TruckAnimal"; Name = "Delivery Truck Animal"; Price = 199; Description = "The animal on your truck." },
	@{ Key = "LimitedAxolotl"; Name = "Limited Axolotl"; Price = 1000; Description = "Limited Mythic. Only 1,000 ever." },
	@{ Key = "OfflineDouble"; Name = "2x Offline"; Price = 25; Description = "Double your away earnings." },
	@{ Key = "HoseTier2"; Name = "Scrub Brush"; Price = 19; Description = "Your next hose." },
	@{ Key = "HoseTier3"; Name = "Garden Hose"; Price = 29; Description = "Your next hose." },
	@{ Key = "HoseTier4"; Name = "Power Washer"; Price = 99; Description = "Your next hose." },
	@{ Key = "HoseTier5"; Name = "Foam Cannon"; Price = 249; Description = "Your next hose." }
)

# Game passes (MonetizationConfig passes). Every one is put on sale, so it's on the Store page.
$passes = @(
	@{ Key = "DoubleCash"; Name = "2x Cash Forever"; Price = 49; Description = "Double all cash you earn. Forever!" },
	@{ Key = "VIPKeeper"; Name = "VIP Keeper"; Price = 399; Description = "+25% income forever and a VIP title." }
)

Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient

# A POST or PATCH of $item's form, sent with $key.
function Send-Form([string]$method, [string]$url, $item, [string]$key) {
	$request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($method), $url)
	$request.Headers.Add("x-api-key", $key)
	$request.Content = New-Form $item
	return $client.SendAsync($request).Result
}

function New-Form($item) {
	$form = New-Object System.Net.Http.MultipartFormDataContent
	$form.Add((New-Object System.Net.Http.StringContent($item.Name)), "name")
	$form.Add((New-Object System.Net.Http.StringContent($item.Description)), "description")
	$form.Add((New-Object System.Net.Http.StringContent([string]$item.Price)), "price")
	$form.Add((New-Object System.Net.Http.StringContent("true")), "isForSale")
	return , $form # the comma stops PowerShell unrolling the form into its parts
}

# Creates (or with -Update, updates) each item at $base with $key and returns its ids by key.
# $listField / $idField are the list response's array and id names for this kind of item.
function Sync-Items($items, [string]$base, [string]$listField, [string]$idField, [string]$key) {
	$headers = @{ "x-api-key" = $key }
	# What already exists, by name.
	$existing = @{}
	$token = $null
	do {
		$url = "$base/creator?pageSize=50"
		if ($token) { $url += "&pageToken=$([uri]::EscapeDataString($token))" }
		$page = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
		foreach ($p in $page.$listField) { $existing[$p.name] = [long]$p.$idField }
		$token = $page.nextPageToken
		Start-Sleep -Milliseconds 400 # 3 requests per second
	} while ($token)

	$ids = @{}
	foreach ($item in $items) {
		if ($existing.ContainsKey($item.Name)) {
			$ids[$item.Key] = $existing[$item.Name]
			if (-not $Update) {
				Write-Host "exists   $($item.Name) -> $($ids[$item.Key])"
				continue
			}
			if ($DryRun) {
				Write-Host "update   $($item.Name) -> $($ids[$item.Key]) ($($item.Price) R$)"
				continue
			}
			$response = Send-Form "PATCH" "$base/$($ids[$item.Key])" $item $key
			if (-not $response.IsSuccessStatusCode) {
				$body = $response.Content.ReadAsStringAsync().Result
				throw "Updating $($item.Name) failed ($([int]$response.StatusCode)): $body"
			}
			Write-Host "updated  $($item.Name) -> $($ids[$item.Key]) ($($item.Price) R$)"
			Start-Sleep -Milliseconds 400
			continue
		}
		if ($DryRun) {
			Write-Host "create   $($item.Name) ($($item.Price) R$)"
			$ids[$item.Key] = 0
			continue
		}
		$response = Send-Form "POST" $base $item $key
		$body = $response.Content.ReadAsStringAsync().Result
		if (-not $response.IsSuccessStatusCode) {
			throw "Creating $($item.Name) failed ($([int]$response.StatusCode)): $body"
		}
		$ids[$item.Key] = [long](($body | ConvertFrom-Json).$idField)
		Write-Host "created  $($item.Name) -> $($ids[$item.Key])"
		Start-Sleep -Milliseconds 400
	}
	return $ids
}

Write-Host "Developer products:"
$ids = Sync-Items $products "https://apis.roblox.com/developer-products/v2/universes/$UniverseId/developer-products" "developerProducts" "productId" $apiKey
Write-Host "Game passes:"
$passIds = Sync-Items $passes "https://apis.roblox.com/game-passes/v1/universes/$UniverseId/game-passes" "gamePasses" "gamePassId" $passKey
foreach ($key in $passIds.Keys) { $ids[$key] = $passIds[$key] }

if ($DryRun) {
	Write-Host "Dry run: nothing created or updated, MonetizationIds.luau unchanged."
	return
}

# Rewrite each "Key = <number>," line in the Products and Passes tables (keys are unique).
$path = Join-Path $PSScriptRoot "..\src\shared\FeatureConfig\MonetizationIds.luau"
$text = [IO.File]::ReadAllText($path)
foreach ($key in $ids.Keys) {
	$text = [regex]::Replace($text, "(?m)^(\t\t$key = )\d+,", "`${1}$($ids[$key]),")
}
[IO.File]::WriteAllText($path, $text)
Write-Host "Wrote $($ids.Count) product and pass ids to $path"
