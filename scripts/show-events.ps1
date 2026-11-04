<#
.SYNOPSIS
  Zeigt die Task-Events roh, so wie sie ueber RabbitMQ laufen (fuer die Demo).

.DESCRIPTION
  Legt beim ersten Aufruf die Queue "demo.event-inspector" an und bindet sie
  an den Fanout-Exchange "task-events". Sie bekommt damit eine Kopie jedes
  Events, ohne den History-Service zu stoeren (Fanout = Broadcast). Jeder
  Aufruf zeigt die seit dem letzten Aufruf angekommenen Events und nimmt sie
  aus der Queue. -Remove loescht die Queue wieder.

.EXAMPLE
  ./scripts/show-events.ps1           # beim ersten Mal: Queue anlegen
  ./scripts/show-events.ps1 -Json     # Events komplett als JSON
#>
param(
    [string]$RabbitUrl = "http://localhost:15672",
    [switch]$Json,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$queue = "demo.event-inspector"
$api = "$RabbitUrl/api"
$headers = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("guest:guest")) }

if ($Remove) {
    Invoke-RestMethod -Method Delete -Uri "$api/queues/%2F/$queue" -Headers $headers | Out-Null
    Write-Host "Queue $queue geloescht."
    return
}

# Beides ist idempotent: existiert die Queue/das Binding schon, aendert sich nichts.
# Nicht durable und auf 50 Nachrichten begrenzt - reine Demo-Hilfe.
Invoke-RestMethod -Method Put -Uri "$api/queues/%2F/$queue" -Headers $headers -ContentType "application/json" `
    -Body '{"durable":false,"auto_delete":false,"arguments":{"x-max-length":50}}' | Out-Null
Invoke-RestMethod -Method Post -Uri "$api/bindings/%2F/e/task-events/q/$queue" -Headers $headers `
    -ContentType "application/json" -Body '{"routing_key":""}' | Out-Null

$result = Invoke-RestMethod -Method Post -Uri "$api/queues/%2F/$queue/get" -Headers $headers `
    -ContentType "application/json" -Body '{"count":50,"ackmode":"ack_requeue_false","encoding":"auto"}'
# Erst in eine Variable, dann aufzaehlen: sonst zaehlt PowerShell "[]" als ein Element.
$messages = @($result | ForEach-Object { $_ } | Where-Object { $_.payload })
if ($messages.Count -eq 0) {
    Write-Host "Keine neuen Events seit dem letzten Aufruf. (Die Queue $queue ist angelegt und sammelt ab jetzt mit.)"
    return
}

if ($Json) {
    $messages | ForEach-Object { $_.payload }
} else {
    $messages | ForEach-Object { $_.payload | ConvertFrom-Json } | ForEach-Object {
        [pscustomobject]@{
            schemaVersion = $_.schemaVersion
            eventType = $_.eventType
            title = $_.title
            name = $_.name
            correlationId = $_.correlationId
        }
    } | Format-Table -AutoSize
}
