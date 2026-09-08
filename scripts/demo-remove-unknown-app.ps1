#Requires -Version 5.1
# Demo helper: removes the fake application planted by demo-plant-unknown-app.ps1.
# The next collector run reports it as REMOVED (removed = 1) — the dictionary entry stays (knowledge is kept).
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SWInvDemoApp'
if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force; Write-Host "Removed SWInvDemoApp from HKCU Uninstall." -ForegroundColor Green }
else { Write-Host "Nothing to remove (SWInvDemoApp not present)." -ForegroundColor Yellow }
