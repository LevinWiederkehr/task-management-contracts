<#
.SYNOPSIS
  Stoppt das komplette Task-Management-System (Gegenstueck zu start-all.ps1).

.PARAMETER Purge
  Loescht zusaetzlich alle Daten (Docker-Volumes: History-DB, RabbitMQ, Seq).
  Die SQLite-Datei des Task-Service (tasks.db) bleibt erhalten.
#>
param(
    [string]$ServicesRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$Purge
)

$pidFile = Join-Path $PSScriptRoot ".taskservice.pid"
if (Test-Path $pidFile) {
    $taskPid = Get-Content $pidFile
    $process = Get-Process -Id $taskPid -ErrorAction SilentlyContinue
    if ($process -and $process.ProcessName -eq "TaskService") {
        Stop-Process -Id $taskPid
        Write-Host "Task-Service (PID $taskPid) gestoppt."
    }
    Remove-Item $pidFile
}

$downArgs = @("down")
if ($Purge) { $downArgs += "--volumes" }
$ErrorActionPreference = "Continue"
& docker compose --project-directory (Join-Path $ServicesRoot "history-export-service-python") @downArgs 2>&1 | Out-Null
& docker compose --project-directory $PSScriptRoot @downArgs 2>&1 | Out-Null
Write-Host "History-Service und Infrastruktur gestoppt$(if ($Purge) { ', Daten geloescht' })."
