# Changelog

Alle Vertragsaenderungen, nach [SemVer](https://semver.org). Jede Version
ist als Git-Tag `vX.Y.Z` markiert. Regeln siehe [EVOLUTION.md](EVOLUTION.md).

## 2.0.0 - geplant (Entwurf), breaking

**task-events-v2.yaml**
- `title` entfaellt, `name` ist Pflicht, `schemaVersion` ist 2.
- Contract-Phase des Breaking Change aus 1.2.0. Erst gueltig, wenn alle
  Consumer `name` lesen. Der Task-Service kann es bereits senden
  (`EVENT_PHASE=3`), Default bleibt Phase 1.

## 1.2.0 - additiv, nicht breaking (Expand)

**task-events.yaml**
- Neues optionales Feld `name` (gleicher Wert wie `title`), `title` ist
  `deprecated`. Beginn des Breaking Change `title` -> `name` nach Expand and
  Contract (siehe EVOLUTION.md). Consumer sollen `name` lesen, Fallback `title`.

**task-service.yaml**
- `HealthResponse`: optionale Felder `eventPhase` und `pendingEvents`.

## 1.1.0 - additiv, nicht breaking

**task-service.yaml / history-export-service.yaml**
- Neue versionierte Pfade `/v1/...`. Die unversionierten Pfade aus 1.0.0
  bleiben als `deprecated` Alias (Expand-Phase).
- Optionaler Header `X-Correlation-ID` (Request + Response),
  `correlationId` in `ErrorResponse`.
- `HealthResponse`: optionale Felder `version`, `instance`.
- `HistoryEntry`: optionales Feld `correlationId`.
- Zeitstempel sind UTC (`Z`).
- Validierungsgrenzen fuer `title` (1-200) und `description` (max. 2000).

**task-events.yaml**
- Neue optionale Felder `schemaVersion` (Default 1) und `correlationId`.
- Zustellgarantie dokumentiert: at-least-once ueber Transactional Outbox,
  Consumer deduplizieren ueber `eventId`.
- Consumer nutzen eine durable, benannte Queue pro Service (vorher:
  exklusive, temporaere Queue) - keine verlorenen Events mehr bei
  Consumer-Ausfall.

## 1.0.0 - Initiale Vertraege

- REST-API Task-Service (`/tasks`), History/Export-Service (`/history`, `/export`).
- Event `TaskEvent` auf Fanout-Exchange `task-events`.
