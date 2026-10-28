# SkyBroe

Aviation tools for student pilots, airline crews, and flight ops/dispatch — Weather · NOTAMs · Airports · Winds · Briefing · Currency · Dispatch · AI Voice · Ops Intelligence · Replay

[![CI](https://github.com/a-tech-broe/SkyBroe/actions/workflows/ci.yml/badge.svg)](https://github.com/a-tech-broe/SkyBroe/actions/workflows/ci.yml)
[![CD](https://github.com/a-tech-broe/SkyBroe/actions/workflows/cd.yml/badge.svg)](https://github.com/a-tech-broe/SkyBroe/actions/workflows/cd.yml)

> Powered by [ATechBroe](https://atechbroe.com)

---

## Features

| Page | Who it's for | Summary |
|---|---|---|
| **Map** | All | Live weather map — METARs, SIGMETs, TFRs with VFR/IFR color coding on Leaflet |
| **Weather** | All | METAR · TAF · PIREPs · SIGMETs · AIRMETs with VFR/MVFR/IFR/LIFR color coding · AI voice brief |
| **NOTAMs** | All | Full text lookup via FAA API · AI voice brief |
| **Airports** | All | Info · runways · charts · sunrise/sunset · density altitude · frequencies · nearby alternates · AI voice brief |
| **Winds Aloft** | All | FD winds forecast table with ISA temperature deviation |
| **Route Briefing** | GA / airlines | DEP → DEST → ALT preflight strip — METAR, TAF, NOTAM count per station · AI voice brief |
| **Currency** | GA / student | FAR 61 currency tracker — VFR day/night, IFR, flight review — stored on-device |
| **Dispatch** | Airlines / ops | Multi-station weather summary table for route planning and flight release |
| **Ops Overview** | Airlines / ops | Live route health dashboard — flight rules per station, SIGMET/TFR counts, 5-min auto-refresh |
| **Operational Replay** | Ops / training | 15-min weather snapshot history · colored timeline bar · scrubber · playback — up to 7 days |
| **Search history** | All | Every ICAO lookup persisted in Postgres per device; dropdown on all search inputs |
| **Light / Dark mode** | All | Toggle in nav bar; preference persists |
| **Accounts** | All | Email + password sign-up / login (JWT); self-service password reset via emailed link (Amazon SES) |

## Flight Rules

| Color | Category | Ceiling | Visibility |
|---|---|---|---|
| Green | VFR | > 3000 ft | > 5 SM |
| Blue | MVFR | 1000–3000 ft | 3–5 SM |
| Red | IFR | 500–999 ft | 1–3 SM |
| Magenta | LIFR | < 500 ft | < 1 SM |

---

## AI Voice Brief

Available on the Weather, NOTAMs, Airports, and Route Briefing pages. After loading data, a **Voice Brief** button appears. Clicking it:

1. Sends the loaded data to the backend
2. Claude Haiku generates a plain-English aviation briefing (60–120 words)
3. After a 3-second pause, the browser reads it aloud using the Web Speech API

The voice picker selects the most natural-sounding voice available: Google neural → Apple Samantha → any Enhanced US English voice → fallback US English.

Requires `ANTHROPIC_API_KEY` to be set. Returns a `503` with a clear error message if the key is missing.

---

## Accounts & Password Reset

Sign-up and login use email + password, with sessions carried as a JWT (`skybroe_token` in `localStorage`, signed with `JWT_SECRET`).

Password reset is self-service:

1. `POST /api/auth/forgot-password` — always returns the same response (so it never reveals whether an email is registered). If the address exists, a single-use token (1-hour expiry) is stored in `password_reset_tokens` and a reset email is sent.
2. The email is sent via **Amazon SES** from `SES_FROM_EMAIL` and links to `${APP_URL}/reset-password?token=…`.
3. `POST /api/auth/reset-password` — validates the token and sets the new password.

> Delivery requires a **verified SES sender identity** and, for arbitrary recipients, **SES production access** (a new account is in the SES sandbox and can only send to verified addresses). The EC2 instance role grants `ses:SendEmail`; ensure the running container can reach instance-role credentials.

---

## Aviation Observability Platform (Ops Overview)

> "Datadog for aviation operations" — live flight-condition monitoring for a set of route stations.

The **Ops** page (`/ops`) provides a real-time health overview of any airports you care about:

- Add/remove stations by ICAO — saved to `localStorage`
- Each station shows its current flight rules badge (VFR / MVFR / IFR / LIFR), wind, visibility, ceiling, and altimeter
- Global counters: active SIGMETs and TFRs
- Auto-refreshes every 5 minutes with a live countdown
- Quick links to the Map and Dispatch pages for deeper investigation

### Interactive stat tiles

Each of the four summary cards at the top is clickable:

| Tile | Action |
|---|---|
| **Tracked Routes** | Smooth-scrolls to the Route Health table below |
| **IFR / LIFR Airports** | Expands an inline panel listing every IFR or LIFR airport across all tracked routes with its FR badge, wind, visibility, and which routes it belongs to. Click again or ✕ to dismiss. |
| **Active SIGMETs** | Navigates to the Weather Map (`/map`) where the SIGMET GeoJSON layer is rendered |
| **Active TFRs** | Navigates to the Weather Map (`/map`) where the TFR GeoJSON layer is rendered |

---

## Operational Replay Timeline

> "Flight incident replay system" — scrub through historical weather conditions at any tracked airport.

The **Replay** page (`/replay`) records a weather snapshot every 15 minutes for each airport you add to tracking. Data is kept for 7 days.

### Controls

| Control | Action |
|---|---|
| Airport selector | Choose from tracked airports |
| Window buttons | 6 h · 12 h · 24 h · 48 h · 72 h lookback |
| Play / Pause | Step through snapshots at 600 ms per frame |
| Rewind | Jump back to the oldest snapshot in the window |
| Timeline bar | Color-coded segments (VFR/MVFR/IFR/LIFR) — click any segment to jump |
| Scrubber | Range slider for fine-grained navigation |

### Snapshot card

Each snapshot shows: flight rules badge, wind (direction/speed/gust), visibility, temperature, altimeter, and raw METAR string.

### Tracking management

Add any ICAO to the tracked list from the bottom panel. The first snapshot appears within 15 minutes. The background collector runs automatically at backend startup.

### Database schema

```sql
CREATE TABLE tracked_airports (
  icao     TEXT PRIMARY KEY,
  added_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE obs_snapshots (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  icao         TEXT NOT NULL,
  captured_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  flight_rules TEXT NOT NULL,
  raw_metar    TEXT,
  wdir         TEXT,
  wspd         SMALLINT,
  wgst         SMALLINT,
  visib        TEXT,
  temp         NUMERIC(5,1),
  altim        NUMERIC(6,2)
);

CREATE INDEX obs_snapshots_icao_time ON obs_snapshots (icao, captured_at DESC);
```

---

## Airport Details

The Airport page is designed for preflight planning — useful for both student pilots and airline crews.

### Tabs

| Tab | Contents |
|---|---|
| **Overview** | Name · location · elevation · longest runway · METAR · wind indicator · IFR/LIFR alert · sunrise/sunset (UTC) · frequencies · density altitude calculator · nearby alternates (50 nm) |
| **Runways** | Embedded airport diagram (APD) for taxi planning · runway ends ranked by wind favor · headwind/crosswind components · per-runway IAP approach plate links |
| **Charts** | Full FAA d-TPP chart list grouped by type, linked to current-cycle PDFs |

### Runway Wind Analysis

Runway ends are sorted by how well they align with the reported surface wind. For each end the page shows:

- **HW** — headwind component in knots
- **XW** — crosswind component in knots
- **Best** badge on the most favorable end
- Runway length and surface type (Asphalt, Concrete, Gravel, Turf)

Wind is parsed from the live METAR fetched alongside airport data.

### Embedded Airport Diagram

If an Airport Diagram (APD) exists in the current AIRAC cycle, it is rendered inline at the top of the Runways tab as a scrollable PDF — no need to open a separate tab for taxi routing. A **Full screen** link opens the PDF in a new tab.

### Per-Runway Approach Plates

Each runway end card expands to list every IAP chart whose name references that runway (e.g. `ILS OR LOC RWY 24R`, `RNAV (GPS) Z RWY 24R`). Clicking any plate opens the PDF in a new tab. This means a pilot can see wind favor, surface type, and all available instrument approaches for a specific runway in a single view.

### IFR / LIFR Alert

When the METAR indicates IFR or LIFR conditions **and** the airport has FAA approach plates, a color-coded banner appears in the Overview tab:

| Condition | Banner color |
|---|---|
| IFR | Red |
| LIFR | Magenta |

The banner includes a **View Approaches →** button that jumps to the Charts tab with the Instrument Approaches (IAP) section highlighted.

### FAA d-TPP Charts

Chart data is sourced from the FAA digital Terminal Procedures Publication (d-TPP). Coverage is limited to US airports with ICAO identifiers starting with **K**, **P**, or **A**. International airports display a notice to consult the national AIP or Jeppesen.

| Chart code | Type |
|---|---|
| APD | Airport Diagram |
| IAP | Instrument Approach Procedures |
| DP | Departure Procedures (SIDs) |
| STAR | Standard Terminal Arrivals |
| MIN | Takeoff Minimums & Obstacle Departure Procedures |
| HOT | Airport Hot Spots |

Charts are updated automatically each [AIRAC cycle](https://en.wikipedia.org/wiki/AIRAC) (28-day interval). The current cycle identifier is shown at the top of the Charts tab. The backend caches the d-TPP XML index in memory and clears it on cycle change. If the current cycle index is unavailable on the FAA server, the previous cycle is used as a fallback automatically.

### Sunrise & Sunset

The Overview tab computes today's sunrise, solar noon, and sunset times in UTC using the NOAA solar calculator algorithm — no API call required. Useful for planning night currency flights or checking civil twilight for passenger carrying.

### Density Altitude Calculator

Enter the current altimeter setting (in Hg) and OAT (°C) to compute density altitude on the spot. Color-coded output: green below 5,000 ft, orange above 5,000 ft, red above 8,000 ft. A performance warning appears when DA is more than 2,000 ft above field elevation.

### Nearby Alternates

Click **Load** in the Overview tab to fetch up to 8 airports within 50 nm, sorted by distance, each with its current METAR. Clicking an alternate ICAO immediately searches that airport. Useful for alternate planning under FAR 91.169 / FAR 121.

---

## Winds Aloft

The Winds Aloft page fetches the FAA FD 6-hour forecast for any US station and displays a formatted table:

| Column | Detail |
|---|---|
| Altitude | 3,000 ft through FL390 |
| Direction | Degrees magnetic (000–360); "L & V" for light and variable |
| Speed | Knots; red ≥ 50 kt, orange ≥ 30 kt |
| Temp (°C) | Blue below −40°C, orange above +5°C |
| ISA Dev | Actual temp − standard atmosphere temp at that altitude; orange = warmer than ISA (DA higher than indicated) |

FD winds use 3-letter station identifiers (K-prefix stripped). The parser handles the full FD text format including the high-speed encoding (DD > 36 → subtract 50, add 100 kts).

---

## Route Briefing

Enter a departure, destination, and optional alternate ICAO to generate a preflight briefing strip. Each station card shows:

- Flight rules category (VFR / MVFR / IFR / LIFR)
- Raw METAR
- Full TAF (pre-formatted)
- NOTAM count badge

Data for all stations is fetched in parallel. A **Voice Brief** button summarizes the entire route in plain English via Claude AI. Useful as a quick "one-page" preflight awareness check before pulling a full ATC briefing.

---

## Currency Tracker

Tracks FAR 61 recency requirements — stored entirely in the browser (`localStorage`), no account required.

| Requirement | FAR | Rule |
|---|---|---|
| Day VFR (pax) | 61.57(a) | 3 takeoffs & landings in preceding 90 days |
| Night VFR (pax) | 61.57(b) | 3 full-stop night landings in preceding 90 days |
| IFR | 61.57(c) | 6 instrument approaches + hold + intercept/track in preceding 6 calendar months |
| Flight Review | 61.56 | 1 hr ground + 1 hr flight in preceding 24 calendar months |

Each currency card shows the current count, a color-coded status badge (current / not current), and days until expiry or days since expiry. A flight log table tracks individual entries (date, aircraft, day/night landings, approaches, holding). The last flight review or IPC date is stored separately.

---

## Mobile App

The native mobile app (Expo / React Native) targets iOS and Android and is optimised for everyday use on the flight line — no browser required.

### Screens

| Screen | What it does |
|---|---|
| **Weather** | ICAO METAR lookup — wind, visibility, altimeter, temp/dew, cloud layers, flight rules badge (VFR / MVFR / IFR / LIFR), raw METAR string |
| **NOTAMs** | ICAO NOTAM lookup via FAA API — number, effective dates, full text |
| **Airports** | ICAO airport lookup — elevation, lat/lon, longest runway, runway directions |

### Navigation

Screens are laid out as a **horizontal swipe-pager**: swipe left or right to move between Weather → NOTAMs → Airports. The tab strip at the top stays fixed — it scrolls independently from the content panels and never moves when you scroll within a screen. Tapping a tab label jumps to that panel; the sliding indicator bar tracks the active page.

### Responsive layout

The `useLayout()` hook drives every size value (font, padding, border radius, touch targets, grid columns) and re-runs automatically on orientation change. The pager re-snaps to the correct page after rotation so no content is lost.

| Device class | Stat grid | Font scale | Content width |
|---|---|---|---|
| Phone portrait | 2 columns | base | full width |
| Phone landscape | 3 columns | base | full width |
| iPad portrait | 3 columns | +2 pt | max 720 px centred |
| iPad landscape | 4 columns | +2 pt | max 720 px centred |

### Running the mobile app

```bash
cd app/mobile
npm install
npx expo start          # opens Metro — scan QR with Expo Go on device
npx expo start --ios    # or --android for simulator
```

Set `EXPO_PUBLIC_API_URL` in `app/mobile/.env` (or export it) to point at the running backend before launching.

---

## Dispatch Strip

Enter any number of ICAO codes (space or comma-separated) to get a parallel weather pull for all stations simultaneously. Each station is summarized in a single row:

| Field | Source |
|---|---|
| Category | VFR / MVFR / IFR / LIFR derived from METAR |
| Wind | Direction @ speed (with gust if reported) |
| Vis | Statute miles |
| Ceiling | Lowest BKN or OVC layer |
| Temp/Dew | °C / °C |
| Altimeter | Inches Hg |

On mobile, stations render as stacked cards instead of a table. Useful for airline dispatcher route planning, multi-leg charter ops, or checking a string of alternates.

---

## Search History

Every ICAO lookup (Weather, NOTAMs, Airports) is persisted in PostgreSQL tied to an anonymous device UUID stored in `localStorage`. History is per-device and survives browser restarts.

### How it works

1. On first visit the browser generates a UUID and stores it as `skybroe_device_id` in `localStorage`
2. Every search fires a background `POST /api/history` with the device ID, ICAO, and search type
3. Clicking any search input fetches `GET /api/history?deviceId=...&type=...` and shows a dropdown of recent lookups (deduplicated by airport, most recent first, top 10)
4. Selecting a history item fills the field and immediately triggers the search

### Database schema

```sql
CREATE TABLE search_history (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id   TEXT NOT NULL,
  icao        TEXT NOT NULL,
  search_type TEXT NOT NULL,   -- 'airport' | 'weather' | 'notam'
  searched_at TIMESTAMPTZ DEFAULT NOW()
);
```

---

## Repository Layout

```
SkyBroe/
├── app/
│   ├── backend/                    # Node.js 22 + Express + TypeScript API
│   ├── web/                        # React 18 + Vite + Tailwind CSS (light/dark mode)
│   ├── mobile/                     # Expo (React Native) — single-screen horizontal pager
│   ├── docker-compose.yml          # Build from source (local prod simulation)
│   └── docker-compose.dev.yml      # Dev with hot reload
├── infra/
│   ├── terraform/                  # AWS — EC2, DNS, IAM, SG, CloudWatch/RUM (Terraform ≥ 1.8)
│   ├── docker-compose.prod.yml     # App EC2 runtime (caddy + web + backend + db)
│   └── Caddyfile                   # TLS (Let's Encrypt) + routing on the instance
└── .github/workflows/
    ├── ci.yml       # PR / dev — lint · scan · build · infra plan
    ├── cd.yml       # main    — build · push · infra apply · deploy · smoke test
    └── cleanup.yml  # manual  — tear down cost-incurring resources (EC2)
```

---

## Stack

| Layer | Tech |
|---|---|
| Web | React 18 + Vite + Tailwind CSS (dark mode via class strategy) |
| Mobile | Expo (React Native) + Expo Router — custom horizontal pager, fully responsive (phone · tablet · landscape) |
| API | Node.js 22 + Express + TypeScript |
| AI | Anthropic Claude Haiku — AI voice brief generation across weather, NOTAMs, airports, route briefing |
| Voice | Web Speech API — browser-native TTS with smart voice picker (Google neural → Apple Samantha → Enhanced) |
| Database | PostgreSQL 16 |
| Containers | Docker + Docker Compose |
| Infra | Terraform → AWS (EC2 Graviton, Route53, IAM) · Caddy for TLS |

---

## Quick Start

### Dev

```bash
# Create app/.env with your API keys (dev uses built-in DB creds and a dev JWT fallback)
# Needed for full functionality: FAA_CLIENT_ID, FAA_CLIENT_SECRET, ANTHROPIC_API_KEY

docker compose -f app/docker-compose.dev.yml up --build
```

| Service | URL / method |
|---|---|
| Web | http://localhost:5173 |
| API | http://localhost:3001 |
| Mobile | `cd app/mobile && npx expo start` — scan QR with Expo Go |

### Production (build from source)

```bash
# Required: JWT_SECRET (backend refuses to boot without it), DB_PASSWORD,
#           FAA_CLIENT_ID, FAA_CLIENT_SECRET, ANTHROPIC_API_KEY
docker compose -f app/docker-compose.yml up --build -d   # web on http://localhost
```

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `DB_USER` | Yes | PostgreSQL username |
| `DB_PASSWORD` | Yes | PostgreSQL password |
| `JWT_SECRET` | Yes | Secret used to sign auth tokens — set a long random string in production |
| `FAA_CLIENT_ID` | Yes (NOTAMs) | FAA API client ID — register at [api.faa.gov](https://api.faa.gov/) |
| `FAA_CLIENT_SECRET` | Yes (NOTAMs) | FAA API client secret |
| `ANTHROPIC_API_KEY` | Yes (AI Voice) | Anthropic API key for Claude Haiku — get at [console.anthropic.com](https://console.anthropic.com/) |
| `APP_URL` | No (defaults) | Base URL used to build the password-reset link in emails (defaults to `https://skybroe.com`) |
| `SES_FROM_EMAIL` | Yes (password reset) | Verified Amazon SES sender for reset emails (defaults to `noreply@skybroe.com`) |
| `AWS_REGION` | No (defaults) | Region for the SES client (defaults to `us-east-1`) |
| `EXPO_PUBLIC_API_URL` | Yes | Backend URL for mobile |

---

## CI/CD Pipeline

Four workflows cover the full DevSecOps lifecycle. Every action is pinned to a
full commit SHA (tag in a trailing comment), every job starts from read-only
`GITHUB_TOKEN` permissions and is granted only what it needs, checkouts don't
persist credentials, and Dependabot (`.github/dependabot.yml`) opens weekly
update PRs against `dev` for npm, base images, compose images, actions and
Terraform providers.

### `ci.yml` — every PR and `dev` push

| Job | Tool | Gate |
|---|---|---|
| Secret scan | Gitleaks (full history) | Blocks |
| Lint & type check | Hadolint + `tsc --noEmit` | Blocks |
| Dependency audit | `npm audit --audit-level=critical` | Blocks |
| SAST | Semgrep | SARIF → Security tab |
| Build & CVE scan | Docker Buildx + Trivy (FS + image) | Warn, SARIF → Security tab |
| Infra plan | `terraform plan` preview | Blocks (PR only) |

### `cd.yml` — merge to `main` / version tags

Runs all security gates (the dependency audit here blocks on **high**, scoped to shipped dependencies with `--omit=dev`), then:

| Job | What happens |
|---|---|
| Build & push | Multi-arch (`amd64` + `arm64`) → DockerHub + Trivy scan (**blocks** on a fixable CRITICAL CVE) + Cosign sign & verify + SBOM |
| Infra apply | `terraform apply` — re-imports survivors, then provisions EC2, DNS records, SG, IAM, CloudWatch/RUM |
| Deploy | SCP `infra/docker-compose.prod.yml` + `infra/Caddyfile` → app EC2, write `.env` with the immutable `sha-<commit>` image tag → `docker compose up --wait`; if the backend healthcheck never passes, it **rolls back** to the previous tag and fails the run |
| Production smoke test | HTTPS `curl` against `APP_DOMAIN`: `/health`, web HTML, weather and airport endpoints |
| Summary | Release digest table + `cosign verify` instructions |

On a state-loss recovery (e.g. after a teardown that wiped Terraform state), `infra apply` first re-imports every surviving `do_not_delete` resource so Terraform reconciles instead of colliding with existing infrastructure.

### `security.yml` — PRs, pushes and weekly (Mondays)

Free scanners; findings land in **Security → Code scanning**.

| Job | Tool | Runs | Gate |
|---|---|---|---|
| SAST | CodeQL (`security-extended`, TypeScript + workflows) | PR / push / weekly | SARIF |
| Dependency review | `actions/dependency-review-action` | PR | **Blocks** new runtime deps with HIGH+ CVEs or GPL/AGPL licences |
| SCA | OSV-Scanner on all three lockfiles | PR / push / weekly | SARIF (npm audit is the gate) |
| IaC | Trivy config (Terraform + Dockerfiles) | PR / push / weekly | **Blocks** on CRITICAL; accepted exceptions are justified in `.trivyignore` |
| Workflow audit | zizmor (injection, permissions, unpinned actions) | PR / push / weekly | SARIF |
| Deployed images | Trivy on the `:latest` images in production | weekly | SARIF — catches CVEs disclosed after release |
| DAST | OWASP ZAP baseline (passive) against `https://APP_DOMAIN` | weekly | Report artifact |
| Posture | OpenSSF Scorecard | `main` / weekly | SARIF |

### `cleanup.yml` — manual teardown

Manually dispatched, with a typed `DESTROY` confirmation and **dry-run on by default**. Walks resources in dependency order (Route53 → EC2 → security groups → observability → IAM → optional TF state; ALB/ACM phases remain only to clear leftovers from the pre-MVP design) and **skips anything tagged `do_not_delete = true`**, so a normal run destroys only the EC2 instance. Set `dry_run=false` to actually delete; `clean_tf_state=true` additionally wipes the remote state file.

### GitHub Secrets

| Secret | Used by |
|---|---|
| `DOCKERHUB_USERNAME` | CD — push, sign, deploy |
| `DOCKERHUB_TOKEN` | CD — push |
| `DB_USER` | CD — written to app EC2 `.env` |
| `DB_PASSWORD` | CD — written to app EC2 `.env` |
| `FAA_CLIENT_ID` | CD — written to app EC2 `.env` |
| `FAA_CLIENT_SECRET` | CD — written to app EC2 `.env` |
| `JWT_SECRET` | CD — written to app EC2 `.env`; signs auth tokens |
| `ANTHROPIC_API_KEY` | CD — written to app EC2 `.env`; required for AI voice brief |
| `APP_DOMAIN` | CD — Caddy TLS certificate domain, DNS records + smoke tests (e.g. `skybroe.example.com`) |
| `HOSTED_ZONE_ID` | CI/CD — Route53 hosted zone ID for auto DNS validation + A records (optional) |
| `AWS_ACCESS_KEY_ID` | CI infra plan + CD infra apply |
| `AWS_SECRET_ACCESS_KEY` | CI infra plan + CD infra apply |
| `AWS_REGION` | Optional — defaults to `us-east-1` |
| `TF_BACKEND_BUCKET` | Terraform S3 state bucket name |
| `TF_BACKEND_DYNAMO_TABLE` | Terraform DynamoDB lock table name |
| `EC2_HOST` | App server Elastic IP — allocate before first deploy, set as secret |
| `EC2_SSH_KEY` | Private key content (PEM) for app EC2 |
| `SEMGREP_APP_TOKEN` | Optional — enables Semgrep cloud dashboard |
| `EC2_SSH_FINGERPRINT` | Optional — pins the app server's SSH host key for deploys (`ssh-keyscan -t ed25519 <EC2_HOST> \| ssh-keygen -lf -`, the `SHA256:…` part) |

### GitHub Variables (optional)

| Variable | Used by |
|---|---|
| `VITE_RUM_APP_ID` | CD web build — from `terraform output rum_app_monitor_id`; enables CloudWatch RUM |
| `VITE_RUM_IDENTITY_POOL_ID` | CD web build — from `terraform output rum_identity_pool_id` |

RUM stays disabled in the browser until both are set (the IDs only exist after the first `terraform apply`, so set them and re-run CD).

---

## Infrastructure

### Architecture

Sized for an MVP with test users: a single small Graviton instance, no load balancer. Caddy on the instance terminates TLS with free, auto-renewing Let's Encrypt certificates and routes requests.

```
Internet ── DNS A record (apex + www) ──► Elastic IP
                                             │
App EC2  (t4g.micro · arm64 · 1 GB + 2 GB swap)
└── Caddy  :80 → 301 HTTPS · :443 TLS (Let's Encrypt)
     ├── /api/*  ──► backend :3001  (Node.js API)
     ├── /health ──► backend :3001
     └── /*      ──► web     :8080  (nginx → React SPA)
    backend ──► db (Postgres 16, local volume)
```

Only Caddy publishes host ports; backend, web and Postgres are reachable solely on the Docker network. The stack definition is `infra/docker-compose.prod.yml` + `infra/Caddyfile` — the deploy job copies both to the instance, so the repo is the single source of truth.

### What gets provisioned

| Resource | Detail |
|---|---|
| App EC2 | Amazon Linux 2023 (arm64), `t4g.micro`, 16 GB gp3 encrypted, 2 GB swap — AMI architecture follows `instance_type`, and the subnet is pinned to an AZ that offers it |
| TLS | Caddy + Let's Encrypt on the instance (certificates persist in the `caddy_data` volume) |
| DNS | Route53 A records for `APP_DOMAIN` and `www.` → Elastic IP (when `HOSTED_ZONE_ID` is set) |
| Internet gateway | The default VPC's existing IGW, referenced as a **data source** (not created — a default VPC already has one) |
| Security group | 80 + 443 public (Caddy), 22 from `allowed_ssh_cidr` |
| IAM role | Least-privilege — SSM read scoped to `/skybroe/*`, SES send, CloudWatch agent, SSM managed-instance core (also enables Session Manager), X-Ray |
| Elastic IP | Pre-allocated — referenced as a data source, never recreated by Terraform |
| Observability | CloudWatch dashboard, metric alarms, log groups, RUM, SNS alerts (see below) — all within the free tier |

### Estimated monthly cost (us-east-1, on-demand, light test traffic)

| Item | $/month |
|---|---|
| EC2 `t4g.micro` | 6.13 |
| EBS gp3 16 GB | 1.28 |
| Public IPv4 (Elastic IP) | 3.65 |
| Route53 hosted zone | 0.50 |
| CloudWatch (2 custom metrics, 4 alarms, 1 dashboard, logs), RUM, SNS, SSM, Cognito | ~0.50 |
| S3 + DynamoDB (Terraform state) | ~0.05 |
| **Total** | **≈ $12** |

The earlier ALB-based design cost ≈ $67/month — the ALB alone (hourly + LCUs + per-AZ public IPv4) was ≈ $27. Before adding a load balancer back, scale up first: `instance_type = "t4g.small"` (2 GB) is +$6/month. Container images are built for both `amd64` and `arm64`, so any instance family works. Anthropic API and SES usage are billed separately per use.

### Protected vs. disposable resources

Every free / near-zero-cost resource (networking, IAM and the entire observability stack) is tagged `do_not_delete = true`, and most also carry `lifecycle { prevent_destroy = true }`. Only the cost-incurring **EC2 instance** is left disposable. This lets the `cleanup` workflow tear down the expensive piece while preserving the scaffolding for cheap re-provisioning. Postgres data lives on the instance volume, so a teardown also discards the database.

### Observability

| Component | Detail |
|---|---|
| Dashboard | `SkyBroe-Overview` — EC2 CPU/mem/disk/network and live app-log query widgets |
| Alarms | CPU, memory, disk, EC2 status check → SNS topic `skybroe-alerts` (email on `alarm_email`) |
| Logs | CloudWatch log groups `/skybroe/app` and `/skybroe/system` (14 d); CloudWatch agent config in SSM |
| RUM | CloudWatch RUM app monitor `skybroe-web` with a Cognito guest identity pool for browser telemetry |

### First-time setup

1. Allocate an Elastic IP in your AWS account for the app EC2
2. Set `EC2_HOST` GitHub Secret to that IP **before the first run**
3. Create an EC2 key pair named `keyit` in your AWS account
4. Register a domain and point it at AWS (Route53 recommended)
5. Add all remaining GitHub Secrets listed above
6. Push to `main` — the pipeline provisions the server and deploys the app

**With Route53 (`HOSTED_ZONE_ID` set):** the apex and `www` A records are created automatically.

**Without Route53:** add A records for `APP_DOMAIN` and `www.APP_DOMAIN` pointing at the Elastic IP (see `terraform output dns_records`) **before** the first deploy — Caddy needs them to resolve to obtain its certificate.

### Manual infra operations

```bash
cd infra/terraform

terraform init \
  -backend-config="bucket=YOUR_BUCKET" \
  -backend-config="key=ec2/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=YOUR_LOCK_TABLE" \
  -backend-config="encrypt=true"

terraform plan   # preview
terraform apply  # provision
```

---

## Data Sources

| Source | Auth | Data |
|---|---|---|
| [AviationWeather.gov](https://aviationweather.gov/data/api/) | None | METAR, TAF, PIREPs, SIGMETs, AIRMETs, airports (global), winds aloft FD text |
| [FAA NOTAM API](https://api.faa.gov/) | Client credentials | NOTAMs (US airspace only) |
| [FAA d-TPP](https://aeronav.faa.gov/d-tpp/) | None | Approach plates, airport diagrams, SIDs, STARs (US only, updated each AIRAC cycle) |
| [Anthropic Claude](https://console.anthropic.com/) | API key | AI-generated plain-English aviation briefings (Claude Haiku) |

### Backend API Endpoints

| Method | Path | Description |
| --- | --- | --- |
| `POST` | `/api/auth/register` | Create an account (email + password) |
| `POST` | `/api/auth/login` | Log in, returns a JWT |
| `GET` | `/api/auth/me` | Current user (requires auth) |
| `POST` | `/api/auth/forgot-password` | Email a password-reset link (always 200) |
| `POST` | `/api/auth/reset-password` | Set a new password from a reset token |
| `GET` | `/api/weather/metar/:icao` | METAR JSON |
| `GET` | `/api/weather/taf/:icao` | TAF JSON |
| `GET` | `/api/weather/pireps/:icao` | PIREPs within 100 SM |
| `GET` | `/api/weather/sigmets` | Active SIGMETs |
| `GET` | `/api/notams/:icao` | NOTAMs (FAA API) |
| `GET` | `/api/airports/:icao` | Airport info + merged METAR |
| `GET` | `/api/airports/:icao/charts` | FAA d-TPP charts for AIRAC cycle |
| `GET` | `/api/airports/:icao/alternates?radius=50` | Nearby airports within radius nm with METARs |
| `GET` | `/api/winds/:icao` | Parsed FD winds aloft for station |
| `GET` | `/api/map/metars` | METARs for the weather map |
| `GET` | `/api/map/sigmets` | SIGMET GeoJSON for the weather map |
| `GET` | `/api/map/tfrs` | TFR GeoJSON for the weather map |
| `GET` | `/api/history?deviceId=&type=` | Recent ICAO searches for device |
| `POST` | `/api/history` | Record a search event |
| `POST` | `/api/voice/brief` | Generate AI plain-English briefing via Claude Haiku |
| `POST` | `/api/obs/stations` | Batch METAR fetch for array of ICAOs (max 30) |
| `GET` | `/api/obs/counts` | Active SIGMET and TFR counts |
| `GET` | `/api/replay/tracked` | List tracked airports |
| `POST` | `/api/replay/track` | Add airport to snapshot tracking |
| `DELETE` | `/api/replay/track/:icao` | Remove airport from tracking |
| `GET` | `/api/replay/:icao?hours=N` | Weather snapshots for last N hours (max 168) |
| `GET` | `/health` | Health check |
