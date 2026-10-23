# Task-Management-System - Contracts

Dieses Repo ist die **verbindliche Vertragsgrundlage** zwischen den zwei
unabhaengig entwickelten Services und die **gemeinsame Infrastruktur**, gegen
die beide laufen. Es enthaelt keinen Business-Code.

| Repo | Person | Sprache | Aufgabe |
| --- | --- | --- | --- |
| `task-service-delphi` | Levin | Delphi | Aufgaben verwalten (CRUD), published Task-Events |
| `history-export-service-python` | Freund | Python | konsumiert Task-Events, bietet History + Export |
| **`contracts`** (dieses Repo) | gemeinsam | - | OpenAPI/AsyncAPI-Vertraege + Keycloak/RabbitMQ |

## Regel: Contract-First

Aendert sich ein Endpoint, ein Feld oder das Event-Format, wird das **zuerst
hier** angepasst (per PR, den beide reviewen), erst danach in den jeweiligen
Service uebernommen. Kein Service darf eigenmaechtig vom Vertrag abweichen -
sonst bricht die Interoperabilitaet, ohne dass man es sofort merkt.

- [`openapi/task-service.yaml`](openapi/task-service.yaml) - REST-API des Task-Service
- [`openapi/history-export-service.yaml`](openapi/history-export-service.yaml) - REST-API des History/Export-Service
- [`asyncapi/task-events.yaml`](asyncapi/task-events.yaml) - asynchrones Event-Format zwischen den beiden

Beide OpenAPI-Dateien lassen sich z.B. auf https://editor.swagger.io ansehen
und testen (Datei-Inhalt einfuegen).

Die Vertraege sind versioniert (SemVer in `info.version`, Git-Tag `vX.Y.Z`,
siehe [`CHANGELOG.md`](CHANGELOG.md)). Wie Breaking Changes ohne
gleichzeitiges Deployment ablaufen (Expand and Contract, Tolerant Reader),
steht in [`EVOLUTION.md`](EVOLUTION.md). Jeder Push wird per GitHub Actions
mit [Spectral](https://github.com/stoplightio/spectral) gelintet
(`.github/workflows/lint-contracts.yml`), lokal:

```
npx @stoplight/spectral-cli lint openapi/*.yaml asyncapi/*.yaml
```

## Architektur-Uebersicht

```
                     Login (Username/Passwort)
   Client  ────────────────────────────────────────▶  Keycloak
     │                                                 (Realm "task-mgmt")
     │  Bearer-Token                                        │
     │                                          JWKS /       │ JWKS
     ▼                                          Issuer       ▼
  Task-Service (Delphi, :8090) ◀──────────────────────  History/Export-Service
     │  REST: /tasks (CRUD)                              (Python, :8091)
     │                                                 REST: /history, /export
     │  STOMP SEND                                           ▲
     │  (Aenderung an Aufgabe)                                │  AMQP consume
     ▼                                                        │
  RabbitMQ Fanout-Exchange "task-events" ────────────────────┘
```

- **Synchron**: beide Services haben eine eigene REST-API (OpenAPI), per
  OAuth2 (Bearer-Token) abgesichert.
- **Asynchron**: der Task-Service published bei jeder Aenderung ein Event an
  den Fanout-Exchange `task-events`; der History-Service konsumiert es. Die
  beiden Services kennen sich nicht direkt, nur ueber den Broker.
- **Authentifizierung**: ein gemeinsamer Keycloak (Realm `task-mgmt`). Beide
  Services validieren denselben Access-Token unabhaengig voneinander (keine
  Session, kein gemeinsamer State) - das ist der Punkt bei OAuth2/JWT.
- **Autorisierung**: **ressourcenbasiert**, nicht rollenbasiert - jede
  Aufgabe/History-Eintrag gehoert einem Benutzer (`sub`-Claim aus dem Token).
  Ein Service gibt nur Daten heraus, die dem eingeloggten Benutzer gehoeren.
  (Anders als im M321-Demo-Projekt, wo es um Rollen ging - hier geht es um
  Besitz.)

### Bewusste Interoperabilitaets-Demo: zwei Protokolle, ein Exchange

Fuer Delphi gibt es keine offizielle AMQP-0-9-1-Client-Library. Statt eine
inoffizielle/unsichere einzubinden, published der Task-Service per **STOMP**
(RabbitMQ-STOMP-Plugin, Port 61613) - ein einfaches Textprotokoll, das sich
mit ein paar Zeilen TCP-Code selbst implementieren laesst. Der Python-Service
konsumiert ganz normal per **AMQP** (z.B. mit `pika`, Port 5672). RabbitMQ
vermittelt zwischen beiden Protokollen auf demselben Exchange - fuer den
Exchange spielt es keine Rolle, mit welchem Protokoll publiziert wurde. Das
ist keine Einschraenkung, sondern zeigt, dass "verteilte Systeme" nicht
bedeutet, dass alle dieselbe Sprache/Bibliothek nutzen muessen - nur derselbe
Vertrag zaehlt.

## Gemeinsame Infrastruktur starten

```
docker compose up --build
```

| Was | URL / Zugriff |
| --- | --- |
| Keycloak (Admin-Konsole) | http://localhost:8082 (Login `admin`/`admin`) |
| RabbitMQ Management-UI | http://localhost:15672 (Login `guest`/`guest`) |
| RabbitMQ AMQP (fuer Python/pika) | `localhost:5672` |
| RabbitMQ STOMP (fuer Delphi) | `localhost:61613` |

Realm `task-mgmt` wird automatisch importiert (siehe
[`keycloak/task-mgmt-realm.json`](keycloak/task-mgmt-realm.json)):

| Username | Passwort | Client-ID (public, kein Secret) |
| --- | --- | --- |
| `levin` | `levin123` | `task-mgmt-client` |
| `max` | `max123` | `task-mgmt-client` |

Login-Token holen (Resource-Owner-Password-Flow):

```
curl -X POST http://localhost:8082/realms/task-mgmt/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=task-mgmt-client&username=levin&password=levin123"
```

Der `access_token` aus der Antwort wird dann als
`Authorization: Bearer <token>` an beide Services mitgeschickt.

### Fuer eigene Docker-Container beider Services

Beide Service-Repos koennen ihre Container an das hier deklarierte,
gemeinsame Netzwerk `task-mgmt-net` haengen (per `docker-compose.yml` im
jeweiligen Repo, `networks: default: external: true, name: task-mgmt-net`)
und erreichen Keycloak/RabbitMQ dann per Hostname `keycloak`/`rabbitmq` statt
`localhost`. Muss die gemeinsame Infra vorher stehen (`docker compose up` in
diesem Repo).

## Naechste Schritte pro Person

Siehe die README im jeweiligen Service-Repo - beide enthalten ein
lauffaehiges Grundgerueest (Health-Endpoint, Auth-Pruefung, ein Event wird
tatsaechlich End-to-End durchgereicht) mit klar markierten TODOs fuer den
Rest (vollstaendiges CRUD, Persistenz, Export-Formate, Fehlerbehandlung, ...).
