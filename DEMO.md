# Demo-Drehbuch (Live-Demonstration)

Reihenfolge fuer die Live-Demo, ca. 15-20 Minuten. Jeder Schritt zeigt ein
Kriterium aus dem Bewertungsraster.

## Vorbereitung (vor der Demo)

```
cd contracts
./start-all.ps1 -Test
```

Offene Tabs: UI http://localhost:8091/ui, Seq http://localhost:5341,
RabbitMQ http://localhost:15672 (Queues), `ARCHITECTURE.md` auf GitHub.
Zwei Terminals: eines im `contracts`-Repo, eines im Python-Repo.

## 1. Architektur (Kriterium 1) - 2 min

`ARCHITECTURE.md`: Ueberblick, Sequenzdiagramm sync/async, Fehlertabelle,
Deployment-Topologie. Kernaussage: zwei Sprachen, drei Repos, keine
gemeinsame DB, Kopplung nur ueber Vertraege + Broker.

## 2. Durchstich + Security (Kriterien 4, 9) - 3 min

1. UI: als `levin` einloggen (Keycloak), Aufgabe anlegen, erledigen, loeschen.
2. History fuellt sich asynchron - Spalte "Korrelation" und "Instanz" zeigen.
3. Zweites Browserfenster (privat) als `max`: sieht nichts von levin.
4. Optional Terminal: manipulierter Token -> 401 (siehe `scripts/e2e-test.ps1`).

## 3. Vertraege (Kriterium 2) - 2 min

`openapi/*.yaml`, `asyncapi/task-events.yaml`, `CHANGELOG.md`, Git-Tag
`v1.1.0`, Spectral-Lint in GitHub Actions. http://localhost:8091/docs zeigt
die DTOs (Pydantic) - getrennt vom Speichermodell.

## 4. Observability (Kriterium 5) - 2 min

In Seq nach `correlationId = '<ID aus der UI>'` filtern: Request-Log
Delphi -> "Aufgabe angelegt" -> "Event published" -> "Event verarbeitet"
(Python, mit Instanz-Name) - eine durchgehende Spur ueber beide Services
und den Broker.

## 5. Asynchronitaet, Idempotenz, Resilienz (Kriterien 3, 6) - 4 min

```
./scripts/e2e-test.ps1 -Resilience
```

Oder manuell, eindrucksvoller:

1. `docker compose stop history` (Python-Repo) -> in der UI Aufgaben anlegen:
   Task-Service antwortet sofort. RabbitMQ-UI: Nachrichten stauen sich in
   `history-export-service.task-events`.
2. `docker compose start history` -> Queue leert sich, History ist komplett.
3. `docker stop contracts-rabbitmq-1` -> Aufgabe anlegen: geht trotzdem
   (Outbox). `/health` des Task-Service zeigt `pendingEvents: 1`.
   `docker start contracts-rabbitmq-1` -> Event kommt nach (Delphi-Konsole
   zeigt die Retries mit Backoff).
4. Skalieren: `docker compose up -d --scale history=4 --no-recreate` ->
   mehrmals http://localhost:8091/health aufrufen, `instance` wechselt.
   RabbitMQ-UI: 4 Consumer an der Queue.
5. Idempotenz: In der RabbitMQ-UI (Exchange `task-events` -> Publish message)
   dasselbe Event zweimal publizieren -> nur ein History-Eintrag, im Log
   "Duplikat ignoriert".

## 6. Breaking Change live (Kriterium 7) - 5 min

Vorgehen nach `EVOLUTION.md`, Beispiel: Event-Feld `title` -> `name`.

1. **Expand** (contracts 1.2.0): `name` als optionales Feld, `title` deprecated.
   Delphi `TaskModel.BuildTaskEventJson`: zusaetzlich
   `Body.AddPair('name', ATask.Title);` -> `run.cmd`. Python laeuft unveraendert
   weiter (Tolerant Reader ignoriert `name`).
2. **Migrate** Consumer, live ohne Unterbruch: in `app/events.py`
   `title = payload.get("name") or payload["title"]` (Pflichtfeld-Pruefung
   anpassen). Dann Blue/Green im Python-Repo, waehrend in der UI weiter
   Aufgaben angelegt werden:
   ```
   docker compose build history
   docker compose up -d --no-recreate --scale history=4   # 2 alte + 2 neue Instanzen
   docker compose ps                                      # die zwei aeltesten sind die alten
   docker stop <alt-1> <alt-2>; docker rm <alt-1> <alt-2>
   ```
   Alte und neue Instanzen teilen sich kurz die Queue, nginx verteilt auf
   alle; `docker stop` beendet die alten sauber (laufende Requests werden
   fertig bearbeitet). Getestet: 358 Requests waehrend der Migration,
   0 Fehler, keine verlorenen Events.
3. **Contract** (contracts 2.0.0, `schemaVersion: 2`): erst wenn alle Consumer
   migriert sind, sendet Delphi nur noch `name`. Ein alter Consumer wuerde
   `schemaVersion 2` sauber ueberspringen statt abzustuerzen (Test
   `test_unbekannte_schema_version_wird_uebersprungen`).

Dasselbe auf REST-Ebene ist bereits umgesetzt: `/tasks` -> `/v1/tasks`,
alte Pfade antworten weiterhin, mit Header `Deprecation: true`.

## 7. Repos + CI (Kriterium 8) - 1 min

Drei Repos, je eigene GitHub-Actions-Pipeline (Spectral / ruff + pytest +
Docker-Build). Ein Befehl startet alles: `start-all.ps1`.
