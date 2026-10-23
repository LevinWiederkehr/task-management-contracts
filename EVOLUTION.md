# Evolution & Breaking Changes

Wie sich die Vertraege in diesem Repo weiterentwickeln, ohne dass ein
Service den anderen bricht. Ziel: **jeder Service wird unabhaengig deployed**,
nie "beide gleichzeitig".

## Versionierung

| Was | Wo | Regel |
| --- | --- | --- |
| Vertragsdatei | `info.version` (SemVer) + Git-Tag `vX.Y.Z` in diesem Repo | Patch = Doku, Minor = additiv, Major = Breaking |
| REST-API | Pfad-Praefix `/v1`, `/v2`, ... | Neue Hauptversion laeuft **parallel** zur alten |
| Event | Feld `schemaVersion` (Integer, Default 1) | Nur bei Breaking Changes erhoehen |

**Additiv (nicht breaking):** neues optionales Feld, neuer Endpoint, neuer
Enum-Wert *nur in einer Request-Richtung*, die der Provider akzeptiert.

**Breaking:** Feld entfernen/umbenennen, Typ aendern, optionales Feld wird
Pflicht, Enum-Wert im Event/Response hinzufuegen, den ein alter Consumer nicht
kennt, Semantik aendern.

## Tolerant Reader (alle Consumer)

- Unbekannte Felder werden ignoriert (nie "strict" parsen).
- Fehlende optionale Felder bekommen Defaults (`schemaVersion` fehlt -> 1).
- Unbekannte `schemaVersion` oder `eventType`: Event wird geloggt und
  bestaetigt (ack), aber nicht verarbeitet - es blockiert die Queue nicht.
- Der Consumer verarbeitet idempotent ueber `eventId` (at-least-once).

## Vorgehen bei einem Breaking Change: Expand and Contract

Beispiel: Im Event soll `title` kuenftig `name` heissen.

| Phase | Contracts | Task-Service (Publisher) | History-Service (Consumer) |
| --- | --- | --- | --- |
| 0. Ausgangslage | 1.1.0 | sendet `title` | liest `title` |
| 1. **Expand** | 1.2.0: `name` optional hinzu, `title` deprecated | sendet `title` **und** `name` (deploy) | unveraendert, laeuft weiter |
| 2. **Migrate** | - | - | liest `name`, Fallback auf `title` (deploy, siehe "Live-Migration") |
| 3. **Contract** | 2.0.0: `title` entfernt, `schemaVersion: 2` | sendet nur noch `name` (deploy) | - |

Zwischen den Phasen ist das System jederzeit lauffaehig, jede Phase ist
ein einzelnes, unabhaengiges Deployment. Phase 3 erst, wenn **alle**
Consumer Phase 2 erreicht haben (Fanout: auch zukuenftige Consumer pruefen).

Fuer REST gilt dasselbe Muster auf Pfad-Ebene: `/v2/...` kommt dazu
(Expand), Clients migrieren, `/v1/...` wird erst `deprecated`, dann
entfernt (Contract). Genau so wurde in Version 1.1.0 der Uebergang von
`/tasks` auf `/v1/tasks` gemacht - die alten Pfade bleiben als Alias.

## Live-Migration eines Consumers (ohne Unterbruch, ohne Datenverlust)

Moeglich, weil der History-Service eine **durable, benannte Queue**
(`history-export-service.task-events`) nutzt und mehrere Instanzen als
Competing Consumers daraus lesen:

1. Neue Version zusaetzlich starten (`docker compose up -d --scale history=4`
   mit neuem Image) - alte und neue Instanzen teilen sich die Queue.
2. Alte Instanzen stoppen. Nachrichten, die eine Instanz noch nicht
   bestaetigt hatte, stellt RabbitMQ automatisch einer anderen zu.
3. Auch wenn **alle** Instanzen kurz weg sind, bleiben Events in der Queue
   liegen und werden beim naechsten Start nachgeliefert.
4. Doppelt zugestellte Events werden ueber `eventId` verworfen
   (Primary Key in der History-Tabelle).

## Checkliste fuer jede Vertragsaenderung

1. PR in diesem Repo, beide reviewen. CI lintet OpenAPI/AsyncAPI.
2. `info.version` erhoehen, `CHANGELOG.md` nachfuehren, nach Merge taggen.
3. Erst danach die Services anpassen - Provider zuerst bei Expand,
   Consumer zuerst bei Contract.
