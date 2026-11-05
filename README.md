# Task-Management-System - Contracts

Dieses Repo ist die **verbindliche Vertragsgrundlage** zwischen den zwei
unabhaengig entwickelten Services, die **gemeinsame Infrastruktur** und der
**Einstiegspunkt fuer das Gesamtsystem**. Es enthaelt keinen Business-Code.

| Repo | Sprache | Aufgabe |
| --- | --- | --- |
| [`task-service-delphi`](https://github.com/LevinWiederkehr/task-service-delphi) | Delphi | Aufgaben verwalten (CRUD), published Task-Events (Outbox) |
| [`history-export-service-python`](https://github.com/Brandleee/history-export-service-python) | Python | konsumiert Task-Events, bietet History + Export |
| **`contracts`** (dieses Repo) | - | OpenAPI/AsyncAPI-Vertraege, Infrastruktur (Keycloak, RabbitMQ, Seq), Start-Skripte, Doku |

## Schnellstart: Gesamtsystem mit einem Befehl

Voraussetzungen: Windows, Docker Desktop, die drei Repos nebeneinander im
selben Ordner geklont.

```
./start-all.ps1            # alles starten (2 History-Instanzen)
./start-all.ps1 -Test      # starten + End-to-End-Test
./stop-all.ps1             # alles stoppen (-Purge loescht auch die Daten)
```

| Was | Adresse | Login |
| --- | --- | --- |
| Web-Oberflaeche | http://localhost:8091/ui | `levin`/`levin123`, `luca`/`luca123` |
| Task-Service (Delphi) | http://localhost:8090 (bzw. 8095, falls 8090 belegt) | Bearer-Token |
| History-Service (Load-Balancer) | http://localhost:8091, Swagger: `/docs` | Bearer-Token |
| Seq (zentrale Logs) | http://localhost:5341 | - |
| RabbitMQ Management | http://localhost:15672 | `guest`/`guest` |
| Keycloak Admin | http://localhost:8082 | `admin`/`admin` |

Systemtest: `./scripts/e2e-test.ps1 -Resilience` (Durchstich, Autorisierung,
Lastverteilung, Korrelation in Seq, Ausfall des Consumers).

Breaking Change (`title` -> `name` im Event, siehe [`EVOLUTION.md`](EVOLUTION.md)):

```
./scripts/set-event-phase.ps1 2          # Task-Service in Phase 1/2/3 neu starten
./scripts/show-events.ps1                # rohe Events aus RabbitMQ anzeigen
./scripts/breaking-change-test.ps1       # alle Phasen automatisch durchspielen
```

## Dokumentation

| Dokument | Inhalt |
| --- | --- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Service-Grenzen, Protokolle, sync/async Datenfluesse, Fehlerbehandlung, Deployment-Topologie, Skalierung, Sicherheit |
| [`EVOLUTION.md`](EVOLUTION.md) | Versionierung, Tolerant Reader, Expand and Contract, Live-Migration eines Consumers |
| [`CHANGELOG.md`](CHANGELOG.md) | Vertragsversionen (Git-Tags `vX.Y.Z`) |
| [`DEMO.md`](DEMO.md) | Drehbuch fuer die Live-Demo |

## Vertraege (Contract-First)

Aendert sich ein Endpoint, ein Feld oder das Event-Format, wird das **zuerst
hier** angepasst (per PR, den beide reviewen), erst danach in den jeweiligen
Service uebernommen - nach den Regeln in [`EVOLUTION.md`](EVOLUTION.md).

- [`openapi/task-service.yaml`](openapi/task-service.yaml) - REST-API des Task-Service
- [`openapi/history-export-service.yaml`](openapi/history-export-service.yaml) - REST-API des History/Export-Service
- [`asyncapi/task-events.yaml`](asyncapi/task-events.yaml) - Event-Format zwischen den beiden

Aktuelle Version: **1.2.0** (Task-Service und Events; der History-Service
ist unveraendert auf 1.1.0). Die naechste Hauptversion der Events liegt als
Entwurf in [`asyncapi/task-events-v2.yaml`](asyncapi/task-events-v2.yaml).
Jeder Push wird per GitHub Actions mit
[Spectral](https://github.com/stoplightio/spectral) gelintet, lokal:

```
npx @stoplight/spectral-cli lint openapi/*.yaml asyncapi/*.yaml
```

## Architektur in Kuerze

Details und Diagramme: [`ARCHITECTURE.md`](ARCHITECTURE.md).

- **Synchron**: beide Services haben eine eigene, versionierte REST-API
  (`/v1`), per OAuth2 (Bearer-Token von Keycloak) abgesichert.
- **Asynchron**: der Task-Service schreibt jedes Event per Transactional
  Outbox und published es an den Fanout-Exchange `task-events`; der
  History-Service konsumiert es aus einer durable Queue (Competing
  Consumers, idempotent ueber `eventId`). Die Services kennen sich nicht.
- **Authentifizierung**: gemeinsamer Keycloak (Realm `task-mgmt`). Beide
  Services pruefen Tokens unabhaengig inkl. Signatur (RS256/JWKS).
- **Autorisierung**: ressourcenbasiert ueber den `sub`-Claim.
- **Observability**: `X-Correlation-ID` laeuft durch Requests, Events und
  Logs beider Services, zentral durchsuchbar in Seq.

### Bewusste Interoperabilitaets-Demo: zwei Protokolle, ein Exchange

Fuer Delphi gibt es keine offizielle AMQP-0-9-1-Client-Library. Statt eine
inoffizielle einzubinden, published der Task-Service per **STOMP**
(RabbitMQ-STOMP-Plugin, Port 61613). Der Python-Service konsumiert per
**AMQP** (`pika`, Port 5672). RabbitMQ vermittelt zwischen beiden
Protokollen auf demselben Exchange und bildet sogar die Header
(`correlation-id`, `amqp-message-id`, `persistent`) auf AMQP-Properties ab.

## Infrastruktur (dieses Repo)

`docker compose up -d --build` startet nur die Infrastruktur (macht
`start-all.ps1` automatisch):

- **Keycloak** - Realm wird aus [`keycloak/task-mgmt-realm.json`](keycloak/task-mgmt-realm.json) importiert
- **RabbitMQ** mit STOMP-Plugin. Exchange, durable Queue und Binding
  werden aus [`rabbitmq/definitions.json`](rabbitmq/definitions.json)
  geladen - die Queue existiert also schon, bevor der Consumer das erste Mal
  startet (keine verlorenen Events beim Hochfahren).
- **Seq** - zentrale Log-Aggregation, beide Services schicken JSON-Logs (CLEF)

Alle Container haengen am Netzwerk `task-mgmt-net`; das Compose-File des
History-Service tritt diesem Netzwerk bei.

Token manuell holen:

```
curl -X POST http://localhost:8082/realms/task-mgmt/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=task-mgmt-client&username=levin&password=levin123"
```

## Containerisierung des Delphi-Service

Infrastruktur und History-Service laufen in Linux-Containern. Der
Task-Service laeuft als Windows-Prozess (`TaskService.exe`), den
`start-all.ps1` mitstartet. Ein Windows-Container wurde bewusst nicht
gewaehlt: Docker Desktop betreibt entweder Linux- oder Windows-Container,
nicht beide in einem Compose-Projekt - Keycloak, RabbitMQ und Postgres gibt
es nur als Linux-Images. Der saubere Weg ist ein Linux-Build des
Delphi-Service (Delphi Enterprise, Linux64-Compiler) - der Code nutzt nur
plattformunabhaengige Units, bis auf die RS256-Pruefung ueber `bcrypt.dll`,
die dafuer auf OpenSSL umgestellt werden muesste.
