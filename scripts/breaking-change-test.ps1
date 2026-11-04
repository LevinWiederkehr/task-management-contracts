<#
.SYNOPSIS
  Spielt den Breaking Change "title" -> "name" gegen das laufende System durch.

.DESCRIPTION
  Fuer jede Event-Phase (siehe EVOLUTION.md): Task-Service neu starten,
  Aufgabe anlegen, das rohe Event aus RabbitMQ pruefen und das Verhalten des
  (unveraenderten) History-Service pruefen:
    1  title, schemaVersion 1        -> History-Eintrag
    2  title + name (Expand)         -> History-Eintrag (Tolerant Reader)
    3  nur name, schemaVersion 2     -> kein Eintrag, Event sauber uebersprungen
  Danach wird wieder Phase 1 gesetzt. Generalprobe fuer die Live-Demo.

.EXAMPLE
  ./scripts/breaking-change-test.ps1
#>
param(
    [string]$HistoryUrl = "http://localhost:8091",
    [string]$KeycloakUrl = "http://localhost:8082",
    [string]$SeqUrl = "http://localhost:5341"
)

$ErrorActionPreference = "Stop"
$script:Failures = 0

function Check([string]$Name, [bool]$Condition, [string]$Info = "") {
    if ($Condition) { Write-Host "  OK    $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name  $Info" -ForegroundColor Red; $script:Failures++ }
}

function Get-RawEvents([string]$CorrelationId, [int]$TimeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $found = @(& "$PSScriptRoot\show-events.ps1" -Json 6>$null | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.correlationId -eq $CorrelationId })
        if ($found.Count -gt 0) { return $found }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @()
}

function Get-HistoryEntries([hashtable]$Headers, [string]$CorrelationId) {
    $all = Invoke-RestMethod -Uri "$HistoryUrl/v1/history" -Headers $Headers
    return @($all | Where-Object { $_.correlationId -eq $CorrelationId })
}

$body = @{ grant_type = "password"; client_id = "task-mgmt-client"; username = "levin"; password = "levin123" }
$levin = @{ Authorization = "Bearer " + (Invoke-RestMethod -Method Post -Body $body `
    -Uri "$KeycloakUrl/realms/task-mgmt/protocol/openid-connect/token").access_token }

& "$PSScriptRoot\show-events.ps1" 6>$null | Out-Null # Inspector-Queue anlegen und leeren

try {
    foreach ($phase in 1, 2, 3) {
        Write-Host "`nPhase $phase" -ForegroundColor Cyan
        & "$PSScriptRoot\set-event-phase.ps1" $phase 6>$null
        $taskUrl = "http://localhost:" + (Get-NetTCPConnection -OwningProcess (Get-Content "$PSScriptRoot\..\.taskservice.pid") -State Listen |
            Select-Object -First 1).LocalPort
        Check "Task-Service meldet eventPhase $phase" ((Invoke-RestMethod "$taskUrl/health").eventPhase -eq $phase)

        $correlationId = "bc$phase-" + [guid]::NewGuid().ToString("N").Substring(0, 10)
        $headers = $levin + @{ "X-Correlation-ID" = $correlationId }
        $task = Invoke-RestMethod -Method Post -Uri "$taskUrl/v1/tasks" -Headers $headers `
            -ContentType "application/json" -Body (@{ title = "Breaking-Change Phase $phase" } | ConvertTo-Json)

        $event = (Get-RawEvents $correlationId) | Select-Object -First 1
        $hasTitle = $null -ne $event.title
        $hasName = $null -ne $event.name
        $expected = @{ 1 = @(1, $true, $false); 2 = @(1, $true, $true); 3 = @(2, $false, $true) }[$phase]
        Check "Rohes Event: schemaVersion $($event.schemaVersion), title=$hasTitle, name=$hasName" `
            ($event -and $event.schemaVersion -eq $expected[0] -and $hasTitle -eq $expected[1] -and $hasName -eq $expected[2])

        if ($phase -lt 3) {
            $deadline = (Get-Date).AddSeconds(10)
            do { $entries = Get-HistoryEntries $levin $correlationId; Start-Sleep -Milliseconds 300 }
            until ($entries.Count -gt 0 -or (Get-Date) -gt $deadline)
            Check "History-Service (unveraendert) speichert das Event: '$($entries[0].title)'" ($entries.Count -eq 1)
        } else {
            Start-Sleep -Seconds 4 # Consumer + gebuendelter Log-Versand
            Check "History-Service speichert schemaVersion 2 nicht" ((Get-HistoryEntries $levin $correlationId).Count -eq 0)
            $filter = [uri]::EscapeDataString("correlationId = '$correlationId'")
            $logs = @(Invoke-RestMethod "$SeqUrl/api/events?filter=$filter&count=50&render=true" | ForEach-Object { $_ })
            $skipped = @($logs | Where-Object { $_.RenderedMessage -like "Event uebersprungen*" })
            Check "...sondern ueberspringt es sauber (Seq: 'Event uebersprungen')" ($skipped.Count -ge 1)
        }
        Invoke-WebRequest -Method Delete -Uri "$taskUrl/v1/tasks/$($task.id)" -Headers $levin -UseBasicParsing | Out-Null
    }
} finally {
    Write-Host "`nZurueck auf Phase 1" -ForegroundColor Cyan
    & "$PSScriptRoot\set-event-phase.ps1" 1
    & "$PSScriptRoot\show-events.ps1" -Remove 6>$null
}

Write-Host ""
if ($script:Failures -eq 0) { Write-Host "Alle Pruefungen bestanden." -ForegroundColor Green; exit 0 }
Write-Host "$($script:Failures) Pruefung(en) fehlgeschlagen." -ForegroundColor Red
exit 1
