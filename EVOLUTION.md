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

Umgesetztes Beispiel: Im Event soll `title` kuenftig `name` heissen.

| Phase | Contracts | Task-Service (Publisher) | History-Service (Consumer) |
| --- | --- | --- | --- |
| 0. Ausgangslage | 1.1.0 | sendet `title` (`EVENT_PHASE=1`) | liest `title` |
| 1. **Expand** | 1.2.0: `name` optional hinzu, `title` deprecated | sendet `title` **und** `name` (`EVENT_PHASE=2`) | unveraendert, laeuft weiter |
| 2. **Migrate** | - | - | liest `name`, Fallback auf `title` (eigenes Deployment, siehe "Live-Migration") |
| 3. **Contract** | 2.0.0 (`task-events-v2.yaml`): `title` entfernt, `schemaVersion: 2` | sendet nur noch `name` (`EVENT_PHASE=3`) | - |

Zwischen den Phasen ist das System jederzeit lauffaehig, jede Phase ist
ein einzelnes, unabhaengiges Deployment. Phase 3 erst, wenn **alle**
Consumer Phase 2 erreicht haben (Fanout: auch zukuenftige Consumer pruefen).

**Stand:** Contracts 1.2.0 und Entwurf 2.0.0 sind veroeffentlicht, der
Task-Service kann alle Phasen. Phase 2 (Migrate) gehoert dem Team des
History-Service und steht noch aus - deshalb laeuft produktiv Phase 1
bzw. 2, nie 3.

### Umschalten per Feature Toggle

Der Publisher-Code fuer **alle** Phasen ist bereits deployed; die aktive
Phase kommt aus der Umgebungsvariable `EVENT_PHASE`
(`TaskModel.BuildTaskEventJson`, `/health` zeigt `eventPhase`). Vorteile:

- Phasenwechsel ohne Build: nur Neustart mit anderer Konfiguration
  (`scripts/set-event-phase.ps1 <1-3>`, 1-2 s; Events gehen dank Outbox
  nicht verloren).
- Rollback ist derselbe Schritt mit der alten Phase.
- Das Flag steuert nur die Reihenfolge der Phasen - es ersetzt weder den
  Vertrag noch die Migration der Consumer. Ein einfacher Schalter "alt/neu"
  waere selbst ein Breaking Change fuer alle Consumer gleichzeitig.
- Ungueltige Werte: Der Service startet nicht, statt still ein falsches
  Format zu senden.

### Was passiert, wenn Contract zu frueh kommt

`EVENT_PHASE=3` mit dem noch nicht migrierten History-Service (getestet mit
`scripts/breaking-change-test.ps1`): Der Consumer erkennt `schemaVersion 2`,
bestaetigt das Event und loggt "Event uebersprungen: schemaVersion 2 wird
nicht unterstuetzt". Kein Absturz, keine blockierte Queue - aber die History
bekommt diese Events nicht. Genau deshalb kommt Contract erst nach der
Migration aller Consumer.

Fuer REST gilt dasselbe Muster auf Pfad-Ebene: `/v2/...` kommt dazu
(Expand), Clients migrieren, `/v1/...` wird erst `deprecated`, dann
entfernt (Contract). Genau so wurde in Version 1.1.0 der Uebergang von
`/tasks` auf `/v1/tasks` gemacht - die alten Pfade bleiben als Alias.

## Live-Migration eines Consumers (ohne Unterbruch, ohne Datenverlust)

Moeglich, weil der History-Service eine **durable, benannte Queue**
(`history-export-service.task-events`) nutzt und mehrere Instanzen als
Competing Consumers daraus lesen:

1. Neues Image bauen und zusaetzlich starten, ohne die alten anzufassen:
   `docker compose build history` und
   `docker compose up -d --no-recreate --scale history=4` - die neuen
   Container bekommen das neue Image, die alten laufen weiter. Alte und neue
   Instanzen teilen sich die Queue, nginx verteilt HTTP auf alle.
2. Alte Instanzen sauber beenden (`docker stop <alte Container>`, danach
   `docker rm`): laufende Requests werden fertig bearbeitet, Nachrichten,
   die eine Instanz noch nicht bestaetigt hatte, stellt RabbitMQ automatisch
   einer anderen zu. (Gemessen: 358 Requests waehrend der Migration, 0 Fehler.)
3. Auch wenn **alle** Instanzen kurz weg sind, bleiben Events in der Queue
   liegen und werden beim naechsten Start nachgeliefert.
4. Doppelt zugestellte Events werden ueber `eventId` verworfen
   (Primary Key in der History-Tabelle).

## Checkliste fuer jede Vertragsaenderung

1. PR in diesem Repo, beide reviewen. CI lintet OpenAPI/AsyncAPI.
2. `info.version` erhoehen, `CHANGELOG.md` nachfuehren, nach Merge taggen.
3. Erst danach die Services anpassen - Provider zuerst bei Expand,
   Consumer zuerst bei Contract.
