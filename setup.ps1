#Requires -Version 5.1
<#
.SYNOPSIS
  SWInv one-command bootstrap: Docker stack (n8n + PostgreSQL + Ollama/GPU), database schema and dictionaries,
  n8n owner account, credentials, workflows (imported + activated), local LLM model, smoke test.

.DESCRIPTION
  Idempotent: safe to run again (re-applies schema/seed, re-imports workflows, keeps data).
  Use -Reset to wipe volumes (fresh demo state). Use -SkipModelPull if the model is already present / offline.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\setup.ps1
  powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Reset
#>
[CmdletBinding()]
param(
  [switch]$Reset,
  [switch]$SkipModelPull,
  [switch]$SkipSmoke,
  [int]$SmokeTimeoutSec = 900
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

function Step($msg) { Write-Host ("`n==> {0}" -f $msg) -ForegroundColor Cyan }
function Ok($msg)   { Write-Host ("    [ok] {0}" -f $msg) -ForegroundColor Green }
function Warn($msg) { Write-Host ("    [!!] {0}" -f $msg) -ForegroundColor Yellow }
function Fail($msg) { Write-Host ("    [xx] {0}" -f $msg) -ForegroundColor Red; exit 1 }
function RandHex($bytes) { $b = New-Object byte[] $bytes; (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($b); ($b | ForEach-Object { $_.ToString('x2') }) -join '' }
function Load-DotEnv($path) {
  $h = @{}
  Get-Content $path | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
    $k, $v = $_ -split '=', 2
    $h[$k.Trim()] = $v.Trim()
  }
  return $h
}
function Wait-Http($url, $timeoutSec, $label) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
    try { $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 5; if ($r.StatusCode -eq 200) { return $true } } catch { }
    Start-Sleep -Seconds 3
  }
  Fail ("{0} did not become healthy within {1}s ({2})" -f $label, $timeoutSec, $url)
}
# Run a native command through cmd.exe so that stderr chatter (psql NOTICEs, n8n version warnings)
# never becomes a PowerShell terminating error. Returns the merged output lines; sets $script:NativeExit.
function Native([string]$cmdline) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $out = & cmd /c "$cmdline 2>&1"
  $script:NativeExit = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return @($out)
}
function Psql($sqlFileInContainer) {
  $out = Native ("docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U {0} -d {1} -q -f {2}" -f $env.POSTGRES_USER, $env.INVENTORY_DB, $sqlFileInContainer)
  $out | Where-Object { $_ -match 'ERROR' } | ForEach-Object { Write-Host ("    {0}" -f $_) -ForegroundColor Red }
  if ($script:NativeExit -ne 0) { Fail "psql failed for $sqlFileInContainer" }
}
function PsqlScalar($db, $sql) {
  $out = Native ("docker compose exec -T postgres psql -U {0} -d {1} -tAc ""{2}""" -f $env.POSTGRES_USER, $db, $sql)
  return (($out | Where-Object { $_ -notmatch 'NOTICE' }) -join "`n").Trim()
}

# ------------------------------------------------------------------ 0. preflight
Step "Preflight: Docker"
$dockerOk = $false
try { & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) } catch { }
if (-not $dockerOk) {
  $dd = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
  if (Test-Path $dd) { Warn "Docker engine not running - starting Docker Desktop"; Start-Process $dd | Out-Null } else { Fail "Docker Desktop not found. Install it and re-run." }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 240) { Start-Sleep -Seconds 5; & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break } }
  if (-not $dockerOk) { Fail "Docker engine did not start within 4 minutes" }
}
Ok ("Docker engine: " + (& docker info --format '{{.ServerVersion}}'))

# ------------------------------------------------------------------ 1. .env
Step ".env"
if (-not (Test-Path "$root\.env")) {
  Copy-Item "$root\.env.example" "$root\.env"
  $c = Get-Content "$root\.env" -Raw
  $c = $c -replace 'N8N_ENCRYPTION_KEY=.*', ("N8N_ENCRYPTION_KEY=" + (RandHex 24))
  $c = $c -replace 'INVENTORY_WEBHOOK_TOKEN=.*', ("INVENTORY_WEBHOOK_TOKEN=" + (RandHex 16))
  [IO.File]::WriteAllText("$root\.env", $c, (New-Object System.Text.UTF8Encoding($false)))
  Ok "created .env with fresh secrets"
} else { Ok ".env exists" }
$env = Load-DotEnv "$root\.env"
foreach ($k in 'POSTGRES_USER','POSTGRES_PASSWORD','INVENTORY_DB','N8N_OWNER_EMAIL','N8N_OWNER_PASSWORD','INVENTORY_WEBHOOK_TOKEN','OLLAMA_MODEL') {
  if (-not $env[$k]) { Fail ".env is missing $k" }
}
if (-not $env['OLLAMA_BASE_URL']) { $env['OLLAMA_BASE_URL'] = 'http://ollama:11434' }

# GPU: enable the docker-compose.gpu.yml override when Docker exposes the NVIDIA runtime
$envText = Get-Content "$root\.env" -Raw
if ($envText -notmatch '(?m)^COMPOSE_FILE=') {
  $runtimes = & docker info --format '{{json .Runtimes}}' 2>$null
  if ($runtimes -match 'nvidia') {
    Add-Content "$root\.env" "`nCOMPOSE_PATH_SEPARATOR=:`nCOMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml"
    Ok "NVIDIA runtime detected: GPU override enabled (COMPOSE_FILE in .env)"
  } else { Warn "no NVIDIA runtime in Docker: Ollama will run on CPU (slower). See docker-compose.gpu.yml" }
} else { Ok ("compose files: " + (($envText | Select-String '(?m)^COMPOSE_FILE=(.*)$').Matches[0].Groups[1].Value)) }

# ------------------------------------------------------------------ 2. compose
if ($Reset) { Step "Reset: docker compose down -v (all data will be wiped)"; Native "docker compose down -v --remove-orphans" | Out-Null; Ok "volumes removed" }
Step "docker compose up -d"
Native "docker compose up -d" | Where-Object { $_ -match 'Created|Started|Running|Healthy|error' } | ForEach-Object { Write-Host ("    " + $_.Trim()) -ForegroundColor DarkGray }
if ($script:NativeExit -ne 0) { Fail "docker compose up failed" }
Wait-Http "http://localhost:5678/healthz" 180 "n8n" | Out-Null
Ok "n8n is up (http://localhost:5678)"
# wait for postgres to accept connections
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 120) { Native ("docker compose exec -T postgres pg_isready -U {0}" -f $env.POSTGRES_USER) | Out-Null; if ($script:NativeExit -eq 0) { break }; Start-Sleep -Seconds 2 }
Ok "postgres is ready"

# ------------------------------------------------------------------ 3. database
Step "Inventory database: schema + dictionaries (idempotent)"
$exists = PsqlScalar 'postgres' ("select 1 from pg_database where datname = '{0}'" -f $env.INVENTORY_DB)
if ($exists -ne '1') { Native ("docker compose exec -T postgres createdb -U {0} {1}" -f $env.POSTGRES_USER, $env.INVENTORY_DB) | Out-Null; Ok ("database {0} created" -f $env.INVENTORY_DB) }
Native "docker cp ""$root\db\schema.sql"" swinv-postgres:/tmp/schema.sql" | Out-Null
Native "docker cp ""$root\db\seed.sql"" swinv-postgres:/tmp/seed.sql" | Out-Null
Psql /tmp/schema.sql
Psql /tmp/seed.sql
$counts = PsqlScalar $env.INVENTORY_DB "select (select count(*) from dict_category)||' categories, '||(select count(*) from dict_vendor)||' vendors, '||(select count(*) from dict_rules)||' rules'"
Ok ("dictionaries: " + $counts)

# ------------------------------------------------------------------ 4. n8n owner
Step "n8n owner account"
# /healthz turns green before the REST layer is ready ("n8n is starting up") -> wait for real JSON settings
$settings = $null
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 180 -and -not $settings) {
  try {
    $raw = (Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:5678/rest/settings" -TimeoutSec 10).Content
    if ($raw -like '{*') { $settings = $raw | ConvertFrom-Json }
  } catch { }
  if (-not $settings) { Start-Sleep -Seconds 3 }
}
if (-not $settings) { Fail "n8n REST API did not become ready (GET /rest/settings)" }
if ($settings.data.userManagement.showSetupOnFirstLoad) {
  $body = @{ email = $env.N8N_OWNER_EMAIL; firstName = $env.N8N_OWNER_FIRSTNAME; lastName = $env.N8N_OWNER_LASTNAME; password = $env.N8N_OWNER_PASSWORD } | ConvertTo-Json
  $done = $false
  for ($attempt = 1; $attempt -le 5 -and -not $done; $attempt++) {
    try {
      Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://localhost:5678/rest/owner/setup" -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null
      $done = $true
    } catch {
      Warn ("owner setup attempt {0} failed: {1}" -f $attempt, $_.Exception.Message)
      Start-Sleep -Seconds 5
    }
  }
  if (-not $done) { Fail "could not create the n8n owner account" }
  Ok ("owner created: {0}" -f $env.N8N_OWNER_EMAIL)
} else { Ok "owner already set up" }

# ------------------------------------------------------------------ 5. credentials
Step "n8n credentials (Postgres, Ollama, webhook token)"
$tpl = Get-Content "$root\n8n\credentials\credentials.template.json" -Raw
$tpl = $tpl.Replace('__INVENTORY_DB__', $env.INVENTORY_DB).Replace('__POSTGRES_USER__', $env.POSTGRES_USER).Replace('__POSTGRES_PASSWORD__', $env.POSTGRES_PASSWORD).Replace('__INVENTORY_WEBHOOK_TOKEN__', $env.INVENTORY_WEBHOOK_TOKEN).Replace('__OLLAMA_BASE_URL__', $env['OLLAMA_BASE_URL'])
$tmpCred = Join-Path $env:TEMP 'swinv-credentials.json'
[IO.File]::WriteAllText($tmpCred, $tpl, (New-Object System.Text.UTF8Encoding($false)))
Native "docker cp ""$tmpCred"" swinv-n8n:/tmp/credentials.json" | Out-Null
Remove-Item $tmpCred -Force
$out = Native "docker compose exec -T n8n n8n import:credentials --input=/tmp/credentials.json"
$out | Where-Object { $_ -match 'imported|error' } | ForEach-Object { Ok $_ }
if ($script:NativeExit -ne 0) { Fail "credential import failed" }

# ------------------------------------------------------------------ 6. workflows
Step "n8n workflows: import + activate"
$wfFiles = Get-ChildItem "$root\n8n\workflows\*.json" | Sort-Object Name
foreach ($f in $wfFiles) {
  Native ("docker cp ""{0}"" swinv-n8n:/tmp/{1}" -f $f.FullName, $f.Name) | Out-Null
  $out = Native ("docker compose exec -T n8n n8n import:workflow --input=/tmp/{0}" -f $f.Name)
  $out | Where-Object { $_ -match 'imported|error' } | ForEach-Object { Ok ("{0}: {1}" -f $f.Name, $_) }
  if ($script:NativeExit -ne 0) { Fail ("workflow import failed: " + $f.Name) }
}
foreach ($f in $wfFiles) {
  $id = (Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).id
  Native ("docker compose exec -T n8n n8n update:workflow --id={0} --active=true" -f $id) | Out-Null
}
Ok "workflows activated; restarting n8n to register webhooks"
Native "docker compose restart n8n" | Out-Null
Wait-Http "http://localhost:5678/healthz" 180 "n8n" | Out-Null
Start-Sleep -Seconds 5
$hooks = PsqlScalar $env.POSTGRES_DB "select method||' /webhook/'||\""webhookPath\"" from webhook_entity order by 1"
$hooks -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Ok $_.Trim() }

# ------------------------------------------------------------------ 7. model
Step ("Ollama model {0}" -f $env.OLLAMA_MODEL)
$tags = $null
try { $tags = (Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:11434/api/tags" -TimeoutSec 15).Content | ConvertFrom-Json } catch { Warn "Ollama API not reachable yet" }
$have = $false
if ($tags -and $tags.models) { $have = [bool]($tags.models | Where-Object { $_.name -eq $env.OLLAMA_MODEL -or $_.name -eq ($env.OLLAMA_MODEL + ':latest') }) }
if ($have) { Ok "model present" }
elseif ($SkipModelPull) { Warn "model missing and -SkipModelPull set: AI step will fail until you run: docker compose exec ollama ollama pull $($env.OLLAMA_MODEL)" }
else {
  Write-Host "    pulling model (several GB, once)..." -ForegroundColor DarkGray
  Native ("docker compose exec -T ollama ollama pull {0}" -f $env.OLLAMA_MODEL) | Select-Object -Last 2 | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor DarkGray }
  if ($script:NativeExit -ne 0) { Fail "ollama pull failed" }
  Ok "model pulled"
}
try {
  $warm = @{ model = $env.OLLAMA_MODEL; prompt = 'Reply with OK'; stream = $false; keep_alive = '24h'; options = @{ num_predict = 2 } } | ConvertTo-Json -Compress
  $t = [Diagnostics.Stopwatch]::StartNew()
  Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://localhost:11434/api/generate" -ContentType 'application/json' -Body $warm -TimeoutSec 300 | Out-Null
  Ok ("model warmed up in {0:N1}s (kept in GPU memory for 24h)" -f $t.Elapsed.TotalSeconds)
} catch { Warn ("warm-up skipped: " + $_.Exception.Message) }

# ------------------------------------------------------------------ 8. smoke test
if (-not $SkipSmoke) {
  Step "Smoke test: POST samples\inventory-sample.json -> /webhook/inventory/ingest"
  $sample = "$root\samples\inventory-sample.json"
  if (Test-Path $sample) {
    $bytes = [IO.File]::ReadAllBytes($sample)
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://localhost:5678/webhook/inventory/ingest" -Headers @{ 'X-Inventory-Token' = $env.INVENTORY_WEBHOOK_TOKEN } -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 300
    Ok ("webhook answered HTTP {0}: {1}" -f $r.StatusCode, $r.Content)
    $runId = ($r.Content | ConvertFrom-Json).run_id
    Write-Host "    waiting for classification to finish (AI runs only for unknown packages)..." -ForegroundColor DarkGray
    $sw = [Diagnostics.Stopwatch]::StartNew(); $row = ''
    while ($sw.Elapsed.TotalSeconds -lt $SmokeTimeoutSec) {
      $row = PsqlScalar $env.INVENTORY_DB ("select status||' | packages='||packages_total||' known='||known_before||' rules='||resolved_rule||' ai='||resolved_ai||' ai_calls='||ai_calls||' unresolved='||unresolved||' dict_changes='||dict_changes||' ms='||coalesce(duration_ms::text,'-') from inventory_runs where run_id='{0}'" -f $runId)
      if ($row -like 'done*') { break }
      Start-Sleep -Seconds 5
    }
    if ($row -like 'done*') { Ok $row } else { Warn ("run not finished yet: " + $row) }
  } else { Warn "sample file missing - run collector\Collect-Inventory.ps1 instead" }
}

# ------------------------------------------------------------------ 9. summary
Step "Ready"
Write-Host ""
Write-Host ("  n8n editor      : http://localhost:5678   (login {0} / see .env)" -f $env.N8N_OWNER_EMAIL)
Write-Host  "  Dashboard       : http://localhost:5678/webhook/inventory/dashboard"
Write-Host  "  Review form     : http://localhost:5678/form/inventory/review"
Write-Host  "  JSON API        : http://localhost:5678/webhook/inventory/api/dashboard"
Write-Host  "  Collector       : powershell -ExecutionPolicy Bypass -File .\collector\Collect-Inventory.ps1"
Write-Host ""
