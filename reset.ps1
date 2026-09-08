#Requires -Version 5.1
<#
.SYNOPSIS
  SWInv: wipe the whole stack (containers + volumes = database, n8n data, model cache) and rebuild from zero.
  Use before a demo rehearsal when you want a pristine state. Model download is skipped if -KeepModel is set
  (the Ollama volume is preserved).
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\reset.ps1 -KeepModel
#>
param([switch]$KeepModel)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
Write-Host "==> Stopping stack and removing volumes" -ForegroundColor Cyan
if ($KeepModel) {
  & docker compose down --remove-orphans | Out-Null
  & docker volume rm swinv_pg_data swinv_n8n_data 2>$null | Out-Null
  Write-Host "    kept volume swinv_ollama_models (model cache)" -ForegroundColor DarkGray
} else {
  & docker compose down -v --remove-orphans | Out-Null
}
Write-Host "==> Rebuilding via setup.ps1" -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
