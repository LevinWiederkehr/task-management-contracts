# Architektur - Task-Management-System

Zwei unabhaengig entwickelte und deployte Services, verbunden ueber formale
Vertraege (dieses Repo) und einen Message-Broker. Die Diagramme sind
Mermaid und werden auf GitHub direkt gerendert.

## 1. Ueberblick: Services, Grenzen, Protokolle

```mermaid
flowchart LR
    user([Browser / Client])

    subgraph idp[Identity Provider]
        kc[Keycloak<br/>Realm task-mgmt]
    end

    subgraph ts[Task-Service - Delphi]
        tsapi[REST /v1/tasks]
        tsdb[(SQLite<br/>tasks + outbox)]
        pub[Outbox-Publisher<br/>Thread]
        tsapi -- "1 Transaktion" --> tsdb
        pub -- liest --> tsdb
    end

    subgraph mq[RabbitMQ]
        ex{{Fanout-Exchange<br/>task-events}}
        q[[Durable Queue<br/>history-export-service.task-events]]
        ex --> q
    end

    subgraph hs[History/Export-Service - Python]
        lb[nginx<br/>Load-Balancer]
        h1[Instanz 1]
        h2[Instanz N]
        hdb[(PostgreSQL<br/>history)]
        lb --> h1 & h2
        h1 & h2 --> hdb
    end

    seq[(Seq<br/>zentrale Logs)]

    user -- "OIDC Password Grant" --> kc
    user -- "HTTP + Bearer JWT<br/>X-Correlation-ID" --> tsapi
    user -- "HTTP + Bearer JWT" --> lb
    tsapi -. "JWKS (RS256)" .-> kc
    h1 & h2 -. JWKS .-> kc
    pub -- "STOMP SEND + RECEIPT" --> ex
    q -- "AMQP 0-9-1<br/>Competing Consumers" --> h1 & h2
    ts -. "CLEF/HTTP" .-> seq
    hs -. "CLEF/HTTP" .-> seq
```

| Komponente | Verantwortung | Besitzt Daten | Vertrag |
| --- | --- | --- | --- |
| **Task-Service** (Delphi) | Aufgaben anlegen/aendern/loeschen, Ownership pruefen, Events publizieren | `tasks`, `outbox` (SQLite) | `openapi/task-service.yaml` (Provider), `asyncapi/task-events.yaml` (Publisher) |
| **History/Export-Service** (Python) | Events konsumieren, History pro Benutzer, Export JSON/CSV | `history` (PostgreSQL) | `openapi/history-export-service.yaml` (Provider), `asyncapi/task-events.yaml` (Consumer) |
| **Keycloak** | Login, Ausstellen signierter Access-Tokens (RS256) | Benutzer | OIDC |
| **RabbitMQ** | Entkopplung, Puffern von Events, Protokoll-Bruecke STOMP <-> AMQP | Nachrichten in Queues | - |
| **Seq** | Zentrale Log-Suche ueber alle Services per Korrelations-ID | Logs | CLEF |

Grenzen: Die Services teilen **keinen** Code, **keine** Datenbank und rufen
sich **nicht** gegenseitig auf. Einzige Kopplung sind die Vertraege in diesem
Repo. Jede Datenbank gehoert genau einem Service (Database per Service).

## 2. Datenfluss: synchron + asynchron

```mermaid
sequenceDiagram
    autonumber
    actor U as Browser
    participant KC as Keycloak
    participant TS as Task-Service
    participant DB as SQLite
    participant P as Outbox-Publisher
    participant MQ as RabbitMQ
    participant HS as History (Instanz x)
    participant PG as PostgreSQL

    U->>KC: POST /token (username, password)
    KC-->>U: access_token (JWT, RS256)

    rect rgb(230, 240, 255)
    Note over U,DB: synchron - Benutzer wartet
    U->>TS: POST /v1/tasks  Bearer + X-Correlation-ID: c1
    TS->>TS: Signatur, iss, exp pruefen (JWKS gecacht)
    TS->>DB: BEGIN, INSERT task, INSERT outbox(event, c1), COMMIT
    TS-->>U: 201 Created  X-Correlation-ID: c1
    end

    rect rgb(235, 250, 235)
    Note over P,PG: asynchron - Benutzer wartet nicht
    P->>DB: unversendete Events lesen
    P->>MQ: STOMP SEND (persistent, correlation-id c1, receipt)
    MQ-->>P: RECEIPT
    P->>DB: outbox.sent_at setzen
    MQ->>HS: deliver (AMQP)
    HS->>PG: INSERT ... ON CONFLICT (event_id) DO NOTHING
    HS->>MQ: ack
    end

    U->>HS: GET /v1/history (via nginx)
    HS->>PG: SELECT ... WHERE owner = sub
    HS-->>U: Eintraege inkl. correlationId c1
```

Die Korrelations-ID `c1` steht dabei in jedem Log-Eintrag beider Services
(Request-Log, "Aufgabe angelegt", "Event published", "Event verarbeitet")
und laesst sich in Seq mit `correlationId = 'c1'` als durchgehende Spur
anzeigen.

## 3. Fehlerbehandlung

| Ausfall / Fehler | Verhalten | Ergebnis |
| --- | --- | --- |
| **RabbitMQ down** | Task-Service speichert Aenderung + Event trotzdem (Outbox). Publisher versucht es mit Backoff 1 s -> 30 s erneut. | Request unverzoegert (gemessen ~10-400 ms), Event wird nachgeliefert |
| **Broker bestaetigt nicht** (Verbindungsabbruch nach SEND) | Kein RECEIPT -> Event bleibt in der Outbox -> erneuter Versand | Moegliches Duplikat -> beim Consumer verworfen |
| **History-Service komplett down** / Deployment | Events bleiben in der durable Queue liegen | Nachlieferung nach Start, Task-Service merkt nichts |
| **Eine History-Instanz stirbt mitten in der Verarbeitung** | Nicht bestaetigte Nachricht geht an eine andere Instanz | Keine Verluste; nginx leitet HTTP an andere Instanz weiter |
| **Doppelt zugestelltes Event** | Primary Key `event_id` -> `ON CONFLICT DO NOTHING`, ack | Genau ein Eintrag (idempotent) |
| **PostgreSQL down** | Consumer: nack + requeue (Retry). API: `503` statt Timeout | Keine Verluste, sauberer Fehler fuer den Client |
| **Ungueltiges Event** (kein JSON, Pflichtfeld fehlt) | Geloggt (Warning) + ack | Blockiert die Queue nicht (kein Poison-Loop) |
| **Unbekannte `schemaVersion` / `eventType`** | Tolerant Reader: uebersprungen + geloggt | Alte Consumer brechen nicht bei neuen Publishern |
| **Keycloak down** | Gecachte JWKS -> bestehende Tokens funktionieren weiter; Login nicht moeglich; History antwortet `503` wenn JWKS fehlt | Graceful Degradation |
| **Token manipuliert / `alg: none` / abgelaufen** | Signatur- bzw. Claim-Pruefung schlaegt fehl | `401` |
| **Seq down** | Logs werden verworfen, stdout bleibt | Kein Einfluss auf Requests |

## 4. Deployment-Topologie

```mermaid
flowchart TB
    subgraph host[Windows-Host]
        exe["TaskService.exe<br/>:8090 (oder :8095)<br/>tasks.db"]
        browser([Browser])

        subgraph docker[Docker Desktop - Netzwerk task-mgmt-net]
            subgraph infra[compose: contracts]
                kc["keycloak<br/>8082 -> 8080"]
                rmq["rabbitmq<br/>5672, 61613, 15672"]
                seq["seq<br/>5341 -> 80"]
            end
            subgraph hist[compose: history-export-service]
                lb["history-lb (nginx)<br/>8091 -> 80"]
                h["history x N<br/>(--scale history=N)"]
                pg[("history-db<br/>postgres:16")]
            end
        end
    end

    browser --> exe
    browser --> lb
    exe -- "localhost:61613" --> rmq
    exe -- "localhost:8082" --> kc
    exe -- "localhost:5341" --> seq
    lb --> h --> pg
    h -- "rabbitmq:5672" --> rmq
    h -- "keycloak:8080" --> kc
    h -- "seq:80" --> seq
```

- Start/Stop des Gesamtsystems: `start-all.ps1` / `stop-all.ps1` in diesem Repo.
- Der Task-Service laeuft als Windows-Prozess, weil der Delphi-Linux-Compiler
  nicht verfuegbar ist (siehe README "Containerisierung").
- Persistente Daten: Docker-Volumes `history-db-data`, `rabbitmq-data`,
  `seq-data`, sowie `tasks.db` im Delphi-Repo-Ordner.

## 5. Skalierung

- **History-Service**: zustandslos (Daten in PostgreSQL), horizontal
  skalierbar mit `docker compose up -d --scale history=N --no-recreate`.
  nginx loest den Service-Namen alle 5 s neu auf (Docker-DNS) und verteilt
  Round-Robin - neue Instanzen bekommen ohne Neustart Traffic. Alle Instanzen
  sind Competing Consumers derselben Queue (Prefetch 10).
- **Task-Service**: eine Instanz (SQLite). Der Code haelt keinen Zustand im
  Speicher; fuer mehrere Instanzen muesste nur die DB auf einen Server
  wechseln. Die Outbox ist dafuer bereits geeignet (Versand per eventId
  idempotent).

## 6. Sicherheit

- OIDC/OAuth2 ueber eigenen Identity Provider (Keycloak), Realm als Code
  (`keycloak/task-mgmt-realm.json`).
- Beide Services pruefen Tokens **unabhaengig** und vollstaendig: Signatur
  RS256 gegen die JWKS (Key-Rotation: Neu-Laden bei unbekanntem `kid`),
  Issuer, Ablaufzeit. Kein gemeinsamer Session-State.
- Autorisierung ressourcenbasiert ueber den `sub`-Claim: fremde Aufgaben
  liefern `404`, fremde History-Eintraege werden nie ausgeliefert.
