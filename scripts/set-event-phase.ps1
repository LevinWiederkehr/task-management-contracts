<#
.SYNOPSIS
  Startet den Task-Service (Delphi) mit einer anderen Event-Phase neu.

.DESCRIPTION
  Phasen des Breaking Change "title" -> "name" im Event (siehe EVOLUTION.md):
    1  nur "title", schemaVersion 1   (Ausgangslage, Vertrag 1.1.0)
    2  "title" und "name"             (Expand, Vertrag 1.2.0)
    3  nur "name", schemaVersion 2    (Contract, Vertrag 2.0.0)
  Der Code fuer alle Phasen ist bereits deployed, die Phase wird nur per
  Umgebungsvariable EVENT_PHASE umgeschaltet (Feature Toggle).

  Der Neustart dauert 1-2 Sekunden: HTTP-Requests in dieser Zeit schlagen
  fehl, Events gehen nicht verloren (Outbox). Port bleibt gleich.

.EXAMPLE
  ./scripts/set-event-phase.ps1 2
#>
param(
    [Parameter(Mandatory)][ValidateRange(1, 3)][int]$Phase,
    [string]$ServicesRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)

$ErrorActionPreference = "Stop"
$taskDir = Join-Path $ServicesRoot "task-service-delphi"
$pidFile = Join-Path (Split-Path $PSScriptRoot -Parent) ".taskservice.pid"

$process = $null
if (Test-Path $pidFile) { $process = Get-Process -Id (Get-Content $pidFile) -ErrorAction SilentlyContinue }
if (-not $process -or $process.ProcessName -ne "TaskService") {
    throw "Kein laufender Task-Service von start-all.ps1 gefunden - zuerst ./start-all.ps1 ausfuehren."
}
$port = (Get-NetTCPConnection -OwningProcess $process.Id -State Listen | Select-Object -First 1).LocalPort

Write-Host "Task-Service (PID $($process.Id), Port $port) wird gestoppt ..."
Stop-Process -Id $process.Id
$process.WaitForExit(5000) | Out-Null

# Umgebung wird an den Kindprozess vererbt (wie in start-all.ps1).
$env:PORT = "$port"
$env:SEQ_URL = "http://localhost:5341"
$env:DB_PATH = Join-Path $taskDir "tasks.db"
$env:EVENT_PHASE = "$Phase"
$new = Start-Process -FilePath (Join-Path $taskDir "TaskService.exe") -WorkingDirectory $taskDir -PassThru
$new.Id | Set-Content $pidFile

$deadline = (Get-Date).AddSeconds(20)
do {
    Start-Sleep -Milliseconds 300
    try { $health = Invoke-RestMethod "http://localhost:$port/health" -TimeoutSec 2 } catch { $health = $null }
} until ($health -or (Get-Date) -gt $deadline)
if (-not $health) { throw "Task-Service ist nicht gestartet - Konsolenfenster pruefen." }

$description = @{ 1 = "nur title, schemaVersion 1"; 2 = "title und name (Expand)"; 3 = "nur name, schemaVersion 2 (Contract)" }
Write-Host "Laeuft wieder (PID $($new.Id)): Event-Phase $($health.eventPhase) - $($description[[int]$health.eventPhase])" -ForegroundColor Green
