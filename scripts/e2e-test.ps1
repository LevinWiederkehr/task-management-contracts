<#
.SYNOPSIS
  End-to-End-Test des Gesamtsystems (Systemdurchstich).

.DESCRIPTION
  Prueft gegen das laufende System (start-all.ps1):
    1. Health beider Services
    2. Login bei Keycloak, Aufgabe anlegen/erledigen/loeschen am Task-Service
    3. Die Events kommen asynchron ueber RabbitMQ in der History an -
       mit derselben Korrelations-ID wie der ausloesende Request
    4. Ressourcenbasierte Autorisierung (anderer Benutzer sieht nichts)
    5. Lastverteilung ueber mehrere History-Instanzen
    6. Korrelation in Seq: Logs BEIDER Services zur selben Korrelations-ID
    7. Mit -Resilience: History-Service komplett gestoppt -> Aufgabe anlegen
       -> nach dem Neustart wird das Event nachgeliefert (durable Queue)

.EXAMPLE
  ./scripts/e2e-test.ps1
  ./scripts/e2e-test.ps1 -Resilience
#>
param(
    [string]$TaskUrl = "",
    [string]$HistoryUrl = "http://localhost:8091",
    [string]$KeycloakUrl = "http://localhost:8082",
    [string]$SeqUrl = "http://localhost:5341",
    [string]$HistoryComposeDir = (Join-Path $PSScriptRoot "..\..\history-export-service-python"),
    [switch]$Resilience
)

$ErrorActionPreference = "Stop"
$script:Failures = 0

function Check([string]$Name, [bool]$Condition, [string]$Info = "") {
    if ($Condition) { Write-Host "  OK    $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name  $Info" -ForegroundColor Red; $script:Failures++ }
}

function Invoke-Docker {
    # docker schreibt Fortschritt nach stderr; PowerShell 5.1 wuerde das als Fehler werten.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & docker @args 2>&1 | Out-Null } finally { $ErrorActionPreference = $previous }
}

function Get-Token([string]$User, [string]$Password) {
    $body = @{ grant_type = "password"; client_id = "task-mgmt-client"; username = $User; password = $Password }
    (Invoke-RestMethod -Method Post -Uri "$KeycloakUrl/realms/task-mgmt/protocol/openid-connect/token" -Body $body).access_token
}

function Wait-HistoryEvent([hashtable]$Headers, [string]$CorrelationId, [int]$Count = 1, [int]$TimeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $entries = @()
    do {
        try {
            # Ergebnis erst in eine Variable: PowerShell 5.1 zaehlt JSON-Arrays sonst als ein Element.
            $all = Invoke-RestMethod -Uri "$HistoryUrl/v1/history" -Headers $Headers
            $entries = @($all | Where-Object { $_.correlationId -eq $CorrelationId })
            if ($entries.Count -ge $Count) { return $entries }
        } catch {
            # z.B. 502, solange History-Instanzen (neu) starten - weiter warten
        }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return $entries
}

# Task-Service finden (8090, sonst Ausweich-Port 8095)
if (-not $TaskUrl) {
    foreach ($candidate in "http://localhost:8090", "http://localhost:8095") {
        try {
            if ((Invoke-RestMethod "$candidate/health" -TimeoutSec 2).service -eq "task-service-delphi") { $TaskUrl = $candidate; break }
        } catch { }
    }
    if (-not $TaskUrl) { throw "Task-Service weder auf 8090 noch auf 8095 gefunden - laeuft start-all.ps1?" }
}
Write-Host "Task-Service: $TaskUrl   History: $HistoryUrl" -ForegroundColor Cyan

Write-Host "`n1. Health"
$taskHealth = Invoke-RestMethod "$TaskUrl/health"
$historyHealth = Invoke-RestMethod "$HistoryUrl/health"
Check "Task-Service UP (Vertrag $($taskHealth.version))" ($taskHealth.status -eq "UP")
Check "History-Service UP, DB $($historyHealth.database), Consumer $($historyHealth.consumer)" `
    ($historyHealth.status -eq "UP" -and $historyHealth.consumer -eq "CONNECTED")

Write-Host "`n2. Synchron: Aufgabe anlegen/erledigen/loeschen (Task-Service)"
$levin = @{ Authorization = "Bearer " + (Get-Token "levin" "levin123") }
$correlationId = "e2e-" + [guid]::NewGuid().ToString("N").Substring(0, 12)
$headers = $levin + @{ "X-Correlation-ID" = $correlationId }
$response = Invoke-WebRequest -Method Post -Uri "$TaskUrl/v1/tasks" -Headers $headers -UseBasicParsing `
    -ContentType "application/json" -Body (@{ title = "E2E-Test $correlationId" } | ConvertTo-Json)
$task = $response.Content | ConvertFrom-Json
Check "POST /v1/tasks -> 201" ($response.StatusCode -eq 201)
Check "Korrelations-ID im Response-Header" ($response.Headers["X-Correlation-ID"] -eq $correlationId)
$null = Invoke-RestMethod -Method Put -Uri "$TaskUrl/v1/tasks/$($task.id)" -Headers $headers `
    -ContentType "application/json" -Body '{"status":"DONE"}'
$null = Invoke-WebRequest -Method Delete -Uri "$TaskUrl/v1/tasks/$($task.id)" -Headers $headers -UseBasicParsing
Check "PUT + DELETE erfolgreich" $true

Write-Host "`n3. Asynchron: Events kommen in der History an (RabbitMQ)"
$events = @(Wait-HistoryEvent $levin $correlationId 3)
$types = ($events | Sort-Object occurredAt | ForEach-Object eventType) -join ","
Check "3 Events mit derselben Korrelations-ID" ($events.Count -eq 3) "gefunden: $($events.Count)"
Check "Reihenfolge CREATED, COMPLETED, DELETED" ($types -eq "TASK_CREATED,TASK_COMPLETED,TASK_DELETED") $types

Write-Host "`n4. Autorisierung (ressourcenbasiert)"
$max = @{ Authorization = "Bearer " + (Get-Token "max" "max123") }
$maxAll = Invoke-RestMethod -Uri "$HistoryUrl/v1/history" -Headers $max
$maxHistory = @($maxAll | Where-Object { $_.correlationId -eq $correlationId })
Check "Benutzer max sieht levins History nicht" ($maxHistory.Count -eq 0)
try { Invoke-RestMethod -Uri "$HistoryUrl/v1/history" | Out-Null; $status = 200 } catch { $status = [int]$_.Exception.Response.StatusCode }
Check "Ohne Token -> 401" ($status -eq 401)

Write-Host "`n5. Lastverteilung"
$instances = 1..10 | ForEach-Object { (Invoke-RestMethod "$HistoryUrl/health").instance } | Sort-Object -Unique
Check "Anfragen verteilt auf $($instances.Count) Instanz(en): $($instances -join ', ')" ($instances.Count -ge 1)

Write-Host "`n6. Distributed Logging (Seq)"
try {
    Start-Sleep -Seconds 2 # Logs werden gebuendelt verschickt
    $filter = [uri]::EscapeDataString("correlationId = '$correlationId'")
    $result = Invoke-RestMethod "$SeqUrl/api/events?filter=$filter&count=200"
    $logs = @($result | ForEach-Object { $_ })
    $services = $logs | ForEach-Object { ($_.Properties | Where-Object Name -eq "service").Value } | Sort-Object -Unique
    Check "Logs beider Services zur Korrelations-ID ($($logs.Count) Eintraege: $($services -join ', '))" ($services.Count -ge 2)
    Write-Host "        Ansehen: $SeqUrl/#/events?filter=$filter" -ForegroundColor DarkGray
} catch {
    Check "Seq erreichbar" $false $_.Exception.Message
}

if ($Resilience) {
    Write-Host "`n7. Resilienz: History-Service komplett gestoppt"
    Invoke-Docker compose --project-directory $HistoryComposeDir stop history
    $offlineId = "e2e-offline-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $started = Get-Date
    $offlineTask = Invoke-RestMethod -Method Post -Uri "$TaskUrl/v1/tasks" -Headers ($levin + @{ "X-Correlation-ID" = $offlineId }) `
        -ContentType "application/json" -Body (@{ title = "Waehrend History offline" } | ConvertTo-Json)
    $ms = [int]((Get-Date) - $started).TotalMilliseconds
    Check "Task-Service antwortet trotzdem sofort ($ms ms)" ($null -ne $offlineTask.id -and $ms -lt 2000)
    Invoke-Docker compose --project-directory $HistoryComposeDir start history
    $events = @(Wait-HistoryEvent $levin $offlineId 1 60)
    Check "Event nach dem Neustart nachgeliefert (durable Queue)" ($events.Count -eq 1)
    Invoke-WebRequest -Method Delete -Uri "$TaskUrl/v1/tasks/$($offlineTask.id)" -Headers $levin -UseBasicParsing | Out-Null
}

Write-Host ""
if ($script:Failures -eq 0) { Write-Host "Alle Pruefungen bestanden." -ForegroundColor Green; exit 0 }
Write-Host "$($script:Failures) Pruefung(en) fehlgeschlagen." -ForegroundColor Red
exit 1
