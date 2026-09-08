#Requires -Version 5.1
<#
.SYNOPSIS
  Demo helper: registers a fake, previously unseen application in the CURRENT USER's Uninstall registry hive
  (no admin rights needed). The next collector run will pick it up as a NEW package; the dictionary has never
  seen it, so exactly ONE AI batch will be triggered for it.
.EXAMPLE
  .\scripts\demo-plant-unknown-app.ps1                      # "Zorbix Ledger 3.1" by "Zorbix Financial Software"
  .\scripts\demo-plant-unknown-app.ps1 -Name "Foo VPN Client" -Publisher "Foo Networks" -Version "2.0"
#>
param(
  [string]$Name = 'Zorbix Ledger 3.1',
  [string]$Publisher = 'Zorbix Financial Software',
  [string]$Version = '3.1.0'
)
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SWInvDemoApp'
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name DisplayName -Value $Name
Set-ItemProperty -Path $key -Name Publisher -Value $Publisher
Set-ItemProperty -Path $key -Name DisplayVersion -Value $Version
Set-ItemProperty -Path $key -Name InstallDate -Value (Get-Date -Format 'yyyyMMdd')
Set-ItemProperty -Path $key -Name UninstallString -Value 'cmd /c echo demo'
Write-Host ("Planted '{0}' ({1}) under HKCU Uninstall. Now run: powershell -ExecutionPolicy Bypass -File .\collector\Collect-Inventory.ps1" -f $Name, $Publisher) -ForegroundColor Green
Write-Host "Remove it later with: .\scripts\demo-remove-unknown-app.ps1" -ForegroundColor DarkGray
