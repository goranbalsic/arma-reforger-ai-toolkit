# ReforgerMods.net API - complete reference (copied 2026-11-15)

Source: https://reforgermods.net/arma-reforger-mods-api/v2/ (docs last updated Sep 2, 2026).
This file is the full V2 reference, restructured for AI/machine reading: every
endpoint, parameter, field and structure from the official docs, plus verified
practical notes from live probing. No information was dropped; only site
navigation/marketing text was removed.

## Base facts

- Base URL: `https://api.reforgermods.net/v2`
- No OpenAPI spec exists. This document is the machine-readable surface.
- Free tier (no API key): 60 requests/minute, 5,000/day. Paid keys raise limits
  (see `/v2/rate-limits`). The three `/v2/tools/*` POST endpoints need no key.
- Send a descriptive `User-Agent` header (e.g. `my-tool/1.0`).
- Server snapshots refresh ~1/minute. List/detail responses carry a `dataset`
  freshness envelope: `warming`, `stale`, `snapshotAgeSeconds`, `lastCollectionAt`,
  `serverCount`, `onlineServerCount`, `offlineServerCount`.
- Successful responses are `"status": "success"`; list responses also have
  `meta` (pagination) and `links` (`next`/`prev` URLs).
- Mod IDs are 16 hex chars, uppercase (`5965550F24A0C152`). Server IDs are GUIDs.

## Endpoint index

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/v2/health` | process health only |
| GET | `/v2/mods` | Workshop mod search/pagination |
| GET | `/v2/mods/{id}` | full mod detail (deps + scenarios inline) |
| GET | `/v2/mods/{id}/versions` | lightweight version history |
| GET | `/v2/mods/{id}/versions/{version}` | one version: changelog + scenarios |
| GET | `/v2/mods/{id}/dependencies` | direct dependencies + byte totals |
| GET | `/v2/mods/{id}/scenarios` | scenarios included with the mod |
| GET | `/v2/mods/{id}/license` | license label + full text |
| GET | `/v2/servers` | server discovery snapshot |
| GET | `/v2/servers/{id}` | one server incl. reported mods |
| GET | `/v2/servers/{id}/mods` | server mods (size enrichment unless `?sizes=false`) |
| GET | `/v2/servers/{id}/history` | per-server population buckets |
| GET | `/v2/servers/history` | fleet-wide population |
| GET | `/v2/analytics` | global analytics snapshot |
| GET | `/v2/analytics/servers` | server leaderboard |
| GET | `/v2/analytics/servers/{id}` | one server's analytics row (404 if none) |
| GET | `/v2/analytics/mods` | mod leaderboard (popular/rising/falling) |
| GET | `/v2/analytics/mods/{id}` | one mod's analytics row |
| GET | `/v2/rate-limits` | the tier resolved for this request |
| GET | `/v2/refresh/jobs/{id}` | background refresh job progress |
| POST | `/v2/tools/storage-plan` | plan storage between current/desired mod sets |
| POST | `/v2/tools/dependency-analysis` | "what breaks if I remove this?" |
| POST | `/v2/tools/hosting-estimate` | RAM/CPU/disk estimate for a modded DS |

## GET /v2/health

```json
{ "status": "success", "data": { "code": 200, "alive": true } }
```

`serversReportingNoMods` is the honest name for zero reported mods (does not
prove vanilla); `vanillaServers` is a deprecated alias with the same value.

## GET /v2/mods

| Parameter | Description |
| --- | --- |
| `page` | positive page number, default 1 |
| `search` | preferred search text parameter |
| `query`, `q`, `s` | accepted search aliases |
| `sort` | `popularity`, `most-rated`, `newest`, `created`, `recently-updated`, `highest-rated`, `subscribers`, `version_size`, `largest`, `name` |
| `tags` | Workshop tag filter; repeat for multiple (`?tags=SCENARIOS&tags=TERRAIN`) |
| `category` | alias for a single `tags` value; prefer `tags` |

```json
{
  "status": "success",
  "meta": { "totalPages": 2593, "currentPage": 2, "totalMods": 41478,
            "shownMods": 16, "modsIndexStart": 17, "modsIndexEnd": 32 },
  "data": [ { "id": "5965550F24A0C152", "name": "Example Mod", "type": "addon",
    "summary": "...", "authorId": "author_id", "author": "Example Author",
    "version": "1.2.3", "versionId": 123, "gameVersion": "1.7.0.54",
    "size": 203434353, "sizeFormatted": "194 MiB", "rating": 0.88,
    "ratingCount": 9178, "subscriberCount": 31995,
    "createdAt": "2022-05-18T22:02:44Z", "updatedAt": "2026-07-30T07:10:47Z",
    "unlisted": false, "private": false, "tags": ["VEHICLES", "WEAPONS"],
    "imageUrl": "...", "workshopUrl": "...", "apiUrl": "..." } ],
  "links": { "next": "...page=3...", "prev": "...page=1..." }
}
```

List rows are [mod previews](#v2-mod-preview-object) (no description, no
scenario/dependency arrays).

## GET /v2/mods/{id}

Full detail. Workshop asset-detail metadata; `dependencies` and `scenarios`
included inline for convenience; version history only via subresource URLs.

| Field | Note |
| --- | --- |
| `size` | raw bytes, current Workshop version |
| `dependencySize` | raw bytes of known direct dependencies |
| `totalSize` | `size` + known direct dependency bytes |
| `contributors` | extra credited users (`{id, username}`); primary stays in `authorId`/`author` |
| `dependencies` | direct deps of the current version (same list as `/dependencies`) |
| `scenarios` | scenarios of the mod (same as `/scenarios`) |
| `versions` | NOT in detail; use `/versions` |
| `*Formatted` | IEC display values (`B`,`KiB`,`MiB`,`GiB`,`TiB`) of the matching byte field |
| `downloadCount` | omitted when unknown (never fabricated as 0) |
| `blocked`, `reported` | not exposed in V2; full license text only via `/license` |

Also present: `description`, `obsolete`, `license` (short label), `tags`,
`imageUrl`, `previewImages`, `screenshots`, `versionCount`, `dependencyCount`,
`scenarioCount`, `workshopUrl`, `apiUrl`, `versionsUrl`, `dependenciesUrl`,
`scenariosUrl`, `licenseUrl`.

## GET /v2/mods/{id}/versions

Lightweight history; does NOT fetch each historical version (cheap).

```json
{ "status": "success", "data": { "modId": "...", "count": 10,
  "versions": [ { "version": "1.2.3", "gameVersion": "1.7.0.54", "size": 203434353,
    "sizeFormatted": "194 MiB", "approved": true, "published": true,
    "createdAt": "...", "updatedAt": "...", "scenarioCount": 11,
    "dependencyCount": 2, "apiUrl": ".../versions/1.2.3" } ] } }
```

Rows are [mod version objects](#mod-version-object) (no changelog text).

## GET /v2/mods/{id}/versions/{version}

One version with changelog and version-specific scenarios when the Workshop
provides them. `changelog` preserves Workshop text incl. line breaks; may be
`""`. Dots are valid in the `version` segment (URL-escape other special chars).

```json
{ "status": "success", "data": { "modId": "...", "version": "1.2.3",
  "gameVersion": "1.7.0.54", "size": 203434353, "sizeFormatted": "194 MiB",
  "approved": true, "published": true,
  "changelog": "[Improved] ...", "createdAt": "...", "updatedAt": "...",
  "scenarioCount": 11, "dependencyCount": 2, "scenarios": [ { } ],
  "apiUrl": ".../versions/1.2.3" } }
```

## GET /v2/mods/{id}/dependencies

```json
{ "status": "success", "data": { "modId": "...", "count": 2,
  "size": 8342292061, "sizeFormatted": "7.77 GiB",
  "totalSizeWithMod": 8545726414, "totalSizeWithModFormatted": "7.96 GiB",
  "dependencies": [ { } ] } }
```

Totals cover known direct dependency sizes only; if one dep lacks size data the
totals stay accurate and `unknownSizeCount` may appear.

## GET /v2/mods/{id}/scenarios

```json
{ "status": "success", "data": { "modId": "...", "count": 11,
  "scenarios": [ { } ] } }
```

Localization keys (`#AR-*`) are returned as-is.

## GET /v2/mods/{id}/license

```json
{ "status": "success", "data": { "modId": "...",
  "license": "Custom license", "licenseText": "Full license text…" } }
```

## GET /v2/servers

Paginated snapshot from the server index (collected from the backend behind
Arma Reforger's own server browser, normalized).

| Parameter | Description |
| --- | --- |
| `page`, `perPage` | pagination; `perPage` capped at 500 |
| `search` | case-insensitive across server and scenario names |
| `sort` | `players`, `name`, `newest`, `lastSeen` |
| `region`, `platform` | ping-site / platform filters; friendly platforms `pc`, `xbox`, `psn` |
| `official`, `hasMods`, `includeOffline` | boolean filters |
| `battleye`, `locked` | boolean filters (BattlEye / password-protected) |

```json
{
  "status": "success",
  "dataset": { "warming": false, "stale": false, "snapshotAgeSeconds": 18,
               "lastCollectionAt": "...", "serverCount": 5300,
               "onlineServerCount": 2400, "offlineServerCount": 2900 },
  "meta": { "totalPages": 53, "currentPage": 1, "totalServers": 5300,
            "shownServers": 100, "serverIndexStart": 1, "serverIndexEnd": 100 },
  "data": [ { } ],
  "links": { "next": "...page=2..." }
}
```

Server preview rows (verified live) carry: `id`, `name`, `scenarioId`,
`scenarioName`, `scenarioImageUrl/Width/Height`, `scenarioThumbnailUrl/Width/Height`,
`gameVersion`, `official`, `passwordProtected`, `battlEye`, `crossPlay`,
`players`, `maxPlayers`, `queue`, `queueMax`, `region`, `platform`,
`platforms[]`, `modCount`, `scenarioModId`, `online`, `firstSeen`, `lastSeen`,
`joinUrl`. A nested `analytics` ranking object may appear (additive; whole page
filled in one lookup; omitted when unranked or warming). OFFLINE rows omit
`mods` and several live fields - guard before use.

## GET /v2/servers/{id}

One server: live status, scenario, queue, supported clients, reported mods,
activity summary, optional nested `analytics`.

| Field | Note |
| --- | --- |
| `positionAvgWaitTime` | lobby-reported avg wait (s) per queue position; omitted when absent |
| `sessionId` | current upstream lobby session id; omitted when absent |
| `host`, `port` | join address |
| `fps` | server FPS |
| `modSummary` | `{count, knownSize, knownSizeText?, unresolvedCount}` |
| `mods[]` | reported mod list, see below |
| `activity` | `{peak24h, avg24h, median24h, low24h, peak7d, samples24h, samples7d, trackingSince}` |

Verified `mods[]` row shape:

```json
{ "id": "61B514B96692C049", "name": "ConflictPVERemixedVanilla2.0",
  "version": "2.6.25", "size": 21197809, "sizeText": "20.2 MiB",
  "sizeKnown": true, "apiModURL": ".../v2/mods/61B514B96692C049",
  "modURL": ".../mods/61B514B96692C049/", "dependentCount": 1 }
```

`size` is present and exact when the index could enrich it (`sizeKnown: true`).
When `sizeKnown` is false the size fields may be absent - do not assume.
Official docs show `sizeKnown: false` rows without `size`/`sizeText`.

## GET /v2/servers/{id}/mods

Same server-to-Workshop relationship; does exact-version size enrichment by
default (`?sizes=false` skips it).

## GET /v2/servers/{id}/history

Per-server activity buckets. `range`: `6h`, `24h`, `72h`, `7d`, `30d`, `90d`,
`1y`, `all`.

```json
{ "t": 1790299800, "avg": 124, "min": 119, "max": 128, "cap": 128,
  "positionAvgWaitTime": 51 }
```

`positionAvgWaitTime` only appears when at least one observation in the bucket
reported a wait estimate (rounded average of those).

## GET /v2/servers/history

Fleet-wide population. `range`: same values; default `24h`. Bucket width: 5 min
up to 24h, hourly to 30d, daily beyond.

```json
{ "status": "success", "range": "24h", "bucket": "5m",
  "now": { "onlineServers": 5071, "trackedServers": 23686, "players": 17186,
           "capacity": 225303, "queue": 872, "observedAt": "..." },
  "points": [ { "t": 1788390000, "players": 18915, "capacity": 230347,
                "servers": 5283, "sumOfServerPeaks": 20110, "peak": 20110 } ] }
```

`now` is live from the index (fresher than buckets). Each point sums per-server
bucket averages; servers with no samples contribute nothing. `sumOfServerPeaks`
sums independently sampled per-server maxima - NOT a concurrent fleet peak
(`peak` is a deprecated alias with the same value). Not published by BI; not
Steam concurrent users.

## GET /v2/analytics

```json
{ "status": "success",
  "analytics": { "available": true, "sourceSnapshotId": 5399,
    "calculatedAt": "...", "modelVersion": "analytics-2026-09-1", "stale": false },
  "data": { "onlineServers": 2400, "trackedServers": 5300,
    "totalPlayers": 42000, "totalQueue": 180, "moddedServers": 1800,
    "serversReportingNoMods": 600, "vanillaServers": 600,
    "uniqueModsDeployed": 12200, "totalModDeployments": 91000,
    "sourceSnapshotId": 5399, "observedAt": "...", "calculatedAt": "..." } }
```

If `analytics.available` is false, analytics are warming up; server/mod
endpoints stay usable.

## GET /v2/analytics/servers

Server leaderboard. `sort`: `overall` (default), `activity`, `reliability`,
`demand`, `rising`, `falling` (directions of `momentumScore`; `momentum` = alias
for `rising`). `page`, `limit` (cap 500). `search`/`region`/`platform` and the
same boolean filters as `/v2/servers` narrow the population without renumbering
(`rank` stays ecosystem-wide). Default: currently-listed servers only.

```json
{ "serverId": "...", "rank": 12, "modelVersion": "...",
  "activityScore": 94.2, "observedAvailabilityScore": 89.4,
  "reliabilityScore": 89.4, "demandScore": 91.8, "momentumScore": 73.1,
  "confidence": 0.87, "overallScore": 91.4, "calculatedAt": "...",
  "sourceSnapshotId": 5399,
  "server": { "id": "...", "name": "...", "scenarioName": "...", "online": true,
              "players": 48, "maxPlayers": 64, "region": "frankfurt", "modCount": 27 } }
```

`server` carries the same list row object so one request can render a full
card; absent when the ranked server left the index. Field meanings:

| Field | Meaning |
| --- | --- |
| `activityScore` | observed player activity relative to the tracked fleet |
| `observedAvailabilityScore` | how consistently present in collection checks (NOT uptime/SLA); `reliabilityScore` is a deprecated alias |
| `demandScore` | observed queue frequency/size relative to fleet; not a fullness score |
| `momentumScore` | direction of recent change; describes the past, not the future |
| `confidence` | model confidence given history depth; not a trust rating |
| `overallScore`, `rank` | combined ecosystem-relative score and position |

`GET /v2/analytics/servers/{id}` returns one row or `404 ANALYTICS_NOT_AVAILABLE`.

## GET /v2/analytics/mods

Mod leaderboard for discovery. `sort`: `popular` (default), `rising`,
`falling`, `deployments` (orders by `totalDeployments`, a raw count). `page`,
`limit` (cap 500). Rising/falling exclude unranked rows (rank 0). Rows carry
the indexed Workshop preview under `mod` in one batch lookup (absent if the
mod is unknown to the local index).

```json
{ "modId": "...", "name": "Example Mod", "totalDeployments": 2305,
  "confirmedRootDeployments": 1400, "dependencyDeployments": 700,
  "unclassifiedDeployments": 205, "dependencyClassificationCoverage": 0.91,
  "currentPlayerExposure": 10309, "playerHoursExposure7d": 88240.5,
  "playerHoursExposureCoverage7d": 0.96, "deploymentScore": 96.2,
  "activityScore": 93.1, "popularityScore": 98.8, "trendSignal": 1.4,
  "risingScore": 88.0, "fallingScore": 0, "popularityRank": 3, "risingRank": 12,
  "fallingRank": 0, "calculatedAt": "...", "sourceSnapshotId": 5399,
  "modelVersion": "..." }
```

| Field | Meaning |
| --- | --- |
| `totalDeployments` | tracked servers reporting the mod: `confirmedRootDeployments` (loaded directly) + `dependencyDeployments` (pulled in) + `unclassifiedDeployments` |
| `dependencyClassificationCoverage` | fraction classified root/dependency, 0..1 |
| `currentPlayerExposure` | players currently on servers reporting the mod (exposure, not unique users) |
| `playerHoursExposure7d` | estimated player-hours on servers reporting the mod over 7d of sampled intervals (not unique users) |
| `playerHoursExposureCoverage7d` | fraction of the 7d window covered by complete trusted population buckets reporting the mod |
| `popularityScore`, `popularityRank` | ecosystem-relative popularity + leaderboard position |
| `trendSignal`, `risingScore`, `fallingScore` | direction/strength of recent observed change |
| `risingRank`, `fallingRank` | directional leaderboards; 0 = signal absent/insufficient |

`GET /v2/analytics/mods/{id}` reads straight from the analytics dataset; the
nested `analytics` on `/v2/mods/{id}` can be older (cached with Workshop
metadata) - compare `calculatedAt` and prefer this endpoint for current numbers.

## GET /v2/rate-limits

```json
{ "authenticated": true,
  "rate_limit": { "plan": "pro", "limit_per_minute": 1200, "burst": 300,
    "limit_per_day": 500000, "window": "1 minute", "daily_window": "UTC day",
    "shared_by": "account", "daily_shared_by": "account", "active_key_limit": 10 } }
```

## GET /v2/refresh/jobs/{id}

```json
{ "id": "...", "status": "queued", "resource_url": "/v2/mods?search=radio",
  "retry_after_seconds": 2 }
```

## POST /v2/tools/storage-plan

Plans storage between a `current` and a `desired` mod set. Sizes resolved
server-side from real Workshop package bytes; exact and estimated bytes are
carried separately everywhere and never merged. No API key required.

| Field | Meaning |
| --- | --- |
| `mode` | `replace` (default): `desired` is the complete end state, everything installed but unreferenced becomes removable. `add`: `desired` installs on top of `current`, keeping installed mods the wish list omits |
| `budgetBytes` | optional; enables a `budget` verdict and (opt-in) removal candidates |
| `includeRemovalImpact` | opt-in; adds a `removal` block when the plan does not fit; costs dependency resolution for every requested mod |

Request:

```json
{ "current": [ { "id": "5965550F24A0C152", "version": "1.0.0" } ],
  "desired": [ { "id": "597706D1E4C7BAAD" } ],
  "mode": "add", "budgetBytes": 107374182400, "includeRemovalImpact": true }
```

Response (abridged):

```json
{ "status": "success", "data": {
    "mode": "add",
    "current": { "totalBytes": 16106127360, "totalText": "15 GiB",
                 "exactCount": 42, "estimatedCount": 0, "coverage": 1 },
    "download": { "totalBytes": 2147483648, "totalText": "2 GiB",
                  "exactCount": 3, "estimatedCount": 0 },
    "projected": { "totalBytes": 18253611008, "totalText": "17 GiB" },
    "peak": { "totalBytes": 18253611008, "totalText": "17 GiB" },
    "budget": { "set": true, "text": "100 GiB", "verdict": "fits",
                "headroomText": "83 GiB" },
    "downloads": [ { "id": "...", "name": "Example Mod", "bytes": 2147483648,
                     "exact": true, "source": "workshop-download-list" } ],
    "removal": { "neededText": "0 B", "recommendedCount": 0, "candidates": [],
                 "dependencyDataAvailable": true },
    "coverage": 1, "unsizedCount": 0, "notes": [] },
  "resolution": { "requested": 45, "resolved": 45, "unresolved": 0,
                  "exactSizes": 45, "sizeCoverage": 1 },
  "model": "reforgermods.net storage model 2026.08-1" }
```

Removal candidates carry a three-valued `status`: `safe`, `blocked`
(`requiredBy` names what would break), or `unknown` (incomplete dependency
data). Blocked/unknown never count toward the savings total.

Verified practical note: the endpoint accepts large batches (~480 ids/request
worked at 60 req/min free tier). `downloads[]` gives `{id, name, bytes, exact}`
per desired mod - use it to fill size maps. `source` values observed:
`workshop-download-list`, `workshop-mod-detail`.

## POST /v2/tools/dependency-analysis

"What breaks if I remove this?" Send `targetId` (one) or `targetIds` (set);
both are unioned. No API key required.

Key semantics: a mod inside the removal set is never a blocker for another set
member (both are leaving). `coveredBySelection` counts mods that only break due
to another selected mod. `missingTargets` lists requested ids absent from the
pack. `unresolvedMods` = dependency metadata could not be fetched; an empty
dependency list there means UNKNOWN, not none - the verdict says so.
`includeAll` is a drawing option only (adds every remaining mod as role
`related`); it never changes the verdict.

```json
{ "mods": [ { "id": "...", "version": "1.0.0" } ],
  "targetIds": [ "5965550F24A0C152" ], "includeAll": false }
```

Response (abridged): `data.status` = verdict (`blocked`/`ok`/`unknown`), plus
`reason`, `targets`, `missingTargets`, `coveredBySelection`, `directBlockers`
(`{id, name, depth, chainNames}`), `transitiveBlockers`, `affectedCount`,
`orphanedIfRemoved`, `reclaimable` (`{totalBytes, totalText, exactCount,
estimatedCount}`), `unresolvedMods`, `missingDependencies`, `cycles`, `graph`.

## POST /v2/tools/hosting-estimate

RAM/CPU/disk estimate for a modded dedicated server. With `mods[]` = exact
byte-based sizing; without, falls back to `modCount` + median indexed mod size
and says so. No API key required. Every figure carries its components and
calibration constants; `calibrationBasis` is the weakest basis among them
(most currently `provisional`). Estimates are reforgermods.net's own, not
vendor measurements.

```json
{ "slots": 64, "concurrentPlayers": 48, "scenario": "heavy",
  "logRetentionDays": 14, "backupCopies": 1,
  "mods": [ { "id": "5965550F24A0C152", "version": "1.0.0" } ] }
```

Response (abridged): `data.memory` (`recommendedGiB`, `minimumGiB`,
`workingSetMiB`, `components[]`), `data.cpu` (`recommendedCores`, `clockClass`,
`clockNote` - "Reforger's simulation loop is single-threaded"), `data.disk`
(`recommendedGiB`, `withMarginText`, `modBytesExact`), `data.workload`,
`data.assumptions[]`, `data.calibrationVersion`, `data.calibrationBasis`.

## Structures

### List response
`status`, `meta` (`totalPages`, `currentPage`, `totalMods|totalServers`,
`shownMods|shownServers`, `modsIndexStart/End|serverIndexStart/End`), `data[]`,
`links.next/prev`. Server lists additionally carry `dataset`.

### V2 mod preview object
`id, name, type, summary, authorId, author, version, versionId, size,
sizeFormatted, rating (0.0..1.0), ratingCount, subscriberCount, createdAt,
updatedAt, unlisted, private, tags[], imageUrl, workshopUrl, apiUrl`.
Previews omit: description, scenarios, dependency lists, large image arrays.

### V2 mod detail object
Everything above plus: `description, contributors[], downloadCount, obsolete,
license (short), previewImages[], screenshots[], versionCount, dependencyCount,
scenarioCount, dependencySize, totalSize, dependencies[], scenarios[],
workshopUrl, apiUrl, versionsUrl, dependenciesUrl, scenariosUrl, licenseUrl`.
Timestamps RFC3339. Optional fields are omitted (never nulled/faked) when the
Workshop lacks them. Upstream moderation/access/bitfield data is not exposed.

### Version history object
`{ modId, count, versions[] }` - versions are [mod version objects](#mod-version-object).

### Mod version object
`{ version, gameVersion, size, sizeFormatted, approved, published, createdAt,
updatedAt, scenarioCount, dependencyCount, apiUrl }` (+ optional `id`).
No changelog text in the list form.

### Version detail object
Adds `changelog` (Workshop text preserved incl. line breaks; may be `""`) and
version-specific `scenarios[]` / `dependencies[]` when available.

### Dependency object
`{ id, name, version, size, sizeFormatted, published, private, dependencyCount,
workshopUrl, apiUrl }`. Direct deps of the current version. V2 exposes no
dependency-level `blocked`.

### Scenario object
`{ name, description?, gameId, gameMode, author, playerCount }`. No image
URLs - use mod-level `imageUrl` / `previewImages` / `screenshots`.

## V1 -> V2 migration

| V1 | V2 |
| --- | --- |
| `/v1/mods/{page}` | `/v2/mods?page={page}` |
| `/v1/search?query={query}` | `/v2/mods?search={query}` |
| `/v1/mod/{id}` | `/v2/mods/{id}` |
| `/v1/mod/{id}/versions` | `/v2/mods/{id}/versions` |
| detail `dependencies` array | `/v2/mods/{id}/dependencies` |
| detail `scenarios` array | `/v2/mods/{id}/scenarios` |
| `size: "5.90 GB"` | `size: 6335076761`, `sizeFormatted: "5.9 GiB"` |
| `rating: "88%"` | `rating: 0.88` |
| `created: "18.05.2022"` | `createdAt: "2022-05-18T22:02:44Z"` |

V2 mod data is normalized from Workshop metadata and may be temporarily
unavailable if the Workshop data shape changes.

## Practical notes from live use (this project)

- `GET /v2/servers?search=X&includeOffline=true` returns both online and
  offline rows; offline rows have `mods: null` and mostly no live fields.
  Online rows do NOT include `mods` in the list - use the detail endpoint.
- `GET /v2/servers/{id}` detail mods include exact `size` bytes when
  `sizeKnown: true`; that is the fastest way to get a whole server's mod sizes
  in one request (no storage-plan roundtrip needed for well-indexed mods).
- `POST /v2/tools/storage-plan` with `mode: "replace"` and `desired` = full
  modlist resolves exact sizes in ~480-id chunks - used by `get-sizes.ps1`.
- `fix-sizes.ps1` fills the rest via `GET /v2/mods/{id}` with a 1200 ms sleep
  to stay under the 60 req/min free tier.
- Always send a real `User-Agent`; the API was designed for bots/tools.
