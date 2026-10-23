<#
.SYNOPSIS
  Startet das komplette Task-Management-System mit einem Befehl.

.DESCRIPTION
  1. Gemeinsame Infrastruktur (dieses Repo): Keycloak, RabbitMQ, Seq
  2. History/Export-Service (Python) inkl. Postgres + Load-Balancer, N Instanzen
  3. Task-Service (Delphi) als Windows-Prozess in eigenem Konsolenfenster
     (Port 8090, falls belegt automatisch 8095)
  Wartet jeweils, bis alles gesund ist, und zeigt danach alle Adressen.

  Erwartet die drei Repos nebeneinander im selben Ordner:
    <Ordner>\contracts, <Ordner>\task-service-delphi, <Ordner>\history-export-service-python

.EXAMPLE
  ./start-all.ps1
  ./start-all.ps1 -HistoryReplicas 3 -Test
#>
param(
    [int]$HistoryReplicas = 2,
    [int]$TaskPort = 0,
    [string]$ServicesRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$Test
)

$ErrorActionPreference = "Stop"
$historyDir = Join-Path $ServicesRoot "history-export-service-python"
$taskDir = Join-Path $ServicesRoot "task-service-delphi"
$pidFile = Join-Path $PSScriptRoot ".taskservice.pid"

function Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }

function Invoke-Docker {
    # docker schreibt Fortschritt nach stderr; PowerShell 5.1 wuerde das als Fehler werten.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & docker @args 2>&1 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) { throw "docker $($args -join ' ') ist fehlgeschlagen (Exit $LASTEXITCODE)" }
    } finally { $ErrorActionPreference = $previous }
}

function Test-PortInUse([int]$Port) {
    [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Get-TaskServiceHealth([int]$Port) {
    try { Invoke-RestMethod "http://localhost:$Port/health" -TimeoutSec 2 } catch { $null }
}

foreach ($dir in $historyDir, $taskDir) {
    if (-not (Test-Path $dir)) { throw "Repo nicht gefunden: $dir (alle drei Repos muessen nebeneinander liegen)" }
}

Step "Docker pruefen"
$previous = $ErrorActionPreference; $ErrorActionPreference = "Continue"
docker info *> $null
$dockerOk = $LASTEXITCODE -eq 0
$ErrorActionPreference = $previous
if (-not $dockerOk) {
    $desktop = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path $desktop)) { throw "Docker laeuft nicht und Docker Desktop wurde nicht gefunden." }
    Write-Host "   Docker Desktop wird gestartet ..."
    Start-Process $desktop
    $deadline = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 3
        $ErrorActionPreference = "Continue"; docker info *> $null; $dockerOk = $LASTEXITCODE -eq 0; $ErrorActionPreference = $previous
    } until ($dockerOk -or (Get-Date) -gt $deadline)
    if (-not $dockerOk) { throw "Docker ist nach 3 Minuten nicht bereit." }
}
Write-Host "   Docker laeuft."

Step "Task-Service-Port bestimmen"
if ($TaskPort -eq 0) {
    foreach ($candidate in 8090, 8095) {
        $health = Get-TaskServiceHealth $candidate
        if ($health -and $health.service -eq "task-service-delphi") { $TaskPort = $candidate; $alreadyRunning = $true; break }
        if (-not (Test-PortInUse $candidate)) { $TaskPort = $candidate; break }
        Write-Host "   Port $candidate ist von einem anderen Programm belegt."
    }
    if ($TaskPort -eq 0) { throw "Weder 8090 noch 8095 ist frei - mit -TaskPort <Port> einen anderen waehlen." }
}
Write-Host "   Task-Service-Port: $TaskPort"

Step "1/3 Infrastruktur (Keycloak, RabbitMQ, Seq)"
Invoke-Docker compose --project-directory $PSScriptRoot up -d --build --wait

Step "2/3 History/Export-Service ($HistoryReplicas Instanzen, Postgres, Load-Balancer)"
$env:HISTORY_REPLICAS = "$HistoryReplicas"
$env:TASK_SERVICE_URL = "http://localhost:$TaskPort"
Invoke-Docker compose --project-directory $historyDir up -d --build --wait

Step "3/3 Task-Service (Delphi)"
if ($alreadyRunning) {
    Write-Host "   Laeuft bereits auf Port $TaskPort - wird weiterverwendet."
} else {
    $exe = Join-Path $taskDir "TaskService.exe"
    if (-not (Test-Path $exe)) { throw "TaskService.exe nicht gefunden - im Delphi-Repo run.cmd ausfuehren oder git pull." }
    # Umgebung wird an den Kindprozess vererbt.
    $env:PORT = "$TaskPort"
    $env:SEQ_URL = "http://localhost:5341"
    $env:DB_PATH = Join-Path $taskDir "tasks.db"
    $process = Start-Process -FilePath $exe -WorkingDirectory $taskDir -PassThru
    $process.Id | Set-Content $pidFile
    $deadline = (Get-Date).AddSeconds(20)
    do { Start-Sleep -Milliseconds 500; $health = Get-TaskServiceHealth $TaskPort } until ($health -or (Get-Date) -gt $deadline)
    if (-not $health) { throw "Task-Service ist nicht gestartet - Konsolenfenster pruefen." }
    Write-Host "   Laeuft (PID $($process.Id), eigenes Konsolenfenster)."
}

Write-Host "`nSystem laeuft:" -ForegroundColor Green
@(
    [pscustomobject]@{ Was = "Web-Oberflaeche (levin/levin123)"; Adresse = "http://localhost:8091/ui" }
    [pscustomobject]@{ Was = "Task-Service (Delphi)"; Adresse = "http://localhost:$TaskPort/health" }
    [pscustomobject]@{ Was = "History-Service API-Doku"; Adresse = "http://localhost:8091/docs" }
    [pscustomobject]@{ Was = "Seq (zentrale Logs)"; Adresse = "http://localhost:5341" }
    [pscustomobject]@{ Was = "RabbitMQ (guest/guest)"; Adresse = "http://localhost:15672" }
    [pscustomobject]@{ Was = "Keycloak (admin/admin)"; Adresse = "http://localhost:8082" }
) | Format-Table -AutoSize

Write-Host "Skalieren:  docker compose --project-directory `"$historyDir`" up -d --scale history=4 --no-recreate"
Write-Host "Testen:     ./scripts/e2e-test.ps1 -Resilience"
Write-Host "Stoppen:    ./stop-all.ps1"

if ($Test) {
    & (Join-Path $PSScriptRoot "scripts\e2e-test.ps1") -TaskUrl "http://localhost:$TaskPort"
    exit $LASTEXITCODE
}
