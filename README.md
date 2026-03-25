# Bootstrap Supabase

> Built with [DevRail](https://devrail.dev) `v1` standards. See [STABILITY.md](STABILITY.md) for component status.

> Idempotent installer for self-hosted Supabase on Ubuntu 22.04 / 24.04.

[![pipeline status](https://gitlab.mfsoho.linkridge.net/hardware-infra/supabase/badges/main/pipeline.svg)](https://gitlab.mfsoho.linkridge.net/hardware-infra/supabase/-/commits/main)
[![DevRail compliant](https://devrail.dev/images/badge.svg)](https://devrail.dev)

## What It Deploys

A single `install.sh` deploys the full Supabase stack via Docker Compose:

| Service | Image | Role |
|---------|-------|------|
| db | supabase/postgres | PostgreSQL with Supabase extensions |
| kong | kong/kong | API gateway (single entry point) |
| auth | supabase/gotrue | Authentication (GoTrue) |
| rest | postgrest/postgrest | REST API (PostgREST) |
| realtime | supabase/realtime | WebSocket subscriptions |
| storage | supabase/storage-api | File storage API |
| imgproxy | darthsim/imgproxy | Image transformations |
| meta | supabase/postgres-meta | Database management for Studio |
| functions | supabase/edge-runtime | Deno edge functions |
| studio | supabase/studio | Dashboard UI |
| analytics | supabase/logflare | Log analytics (optional) |
| vector | timberio/vector | Log collection (optional) |

All component versions are pinned to a tested set. No `:latest` tags.

## Quick Start

```bash
# Download and run as root
sudo bash install.sh
```

The installer prompts for configuration interactively. For unattended installs:

```bash
sudo bash install.sh -y
```

This accepts all defaults (domain: `localhost`, port: `8000`, TLS: off, analytics: on).

## Requirements

- Ubuntu 22.04 or 24.04
- Root access
- Internet connectivity (pulls Docker images)
- Docker is installed automatically if not present

## Configuration

The installer prompts for:

| Setting | Default | Description |
|---------|---------|-------------|
| Domain | `localhost` | Public domain name |
| Install directory | `/opt/supabase` | Where all files and volumes live |
| API port | `8000` | Kong API gateway port |
| TLS mode | `off` | `off`, `letsencrypt-http`, or `dns-cloudflare` |
| SMTP | disabled | Optional email delivery for auth |
| Analytics | enabled | Logflare + Vector log collection |
| Backup retention | 7 days | How long daily backups are kept |

Configuration is saved to `/opt/supabase/.install.conf` and reloaded on subsequent runs.

## TLS Modes

| Mode | Description | Requirements |
|------|-------------|--------------|
| `off` | No TLS. Use when behind an external load balancer or for local dev. | None |
| `letsencrypt-http` | nginx + certbot with HTTP-01 challenge. | Port 80 and 443 reachable from internet |
| `dns-cloudflare` | nginx + certbot with DNS-01 via Cloudflare API. | Cloudflare API token with DNS edit permissions |

With TLS enabled, nginx handles termination and routes:

- `/` — Studio dashboard
- `/rest/v1/`, `/auth/v1/`, `/realtime/v1/`, `/storage/v1/`, `/functions/v1/`, `/pg/`, `/graphql/v1/` — API via Kong

## Idempotency

The script is safe to re-run. On subsequent runs:

- **Secrets are preserved** from the existing `.env` file
- **JWT tokens** (ANON_KEY, SERVICE_ROLE_KEY) are only regenerated if JWT_SECRET changes
- **Data volumes** (database, storage) are never deleted
- **Configuration files** (docker-compose.yml, kong.yml) are regenerated with current settings
- **TLS certificates** are skipped if already present
- **Docker Compose** only recreates containers with changed configuration

## Architecture

```
                    ┌──────────────────────────────────┐
                    │         nginx (TLS only)          │
                    │    terminates TLS, routes paths   │
                    └──────────────┬───────────────────┘
                                   │
                    ┌──────────────▼───────────────────┐
                    │         Kong (port 8000)          │
Internet ──────────►│    API gateway + key-auth + ACL   │
                    └──┬──┬──┬──┬──┬──┬──┬──┬─────────┘
                       │  │  │  │  │  │  │  │
        ┌──────────────┘  │  │  │  │  │  │  └──────────┐
        ▼                 ▼  ▼  ▼  ▼  ▼  ▼             ▼
     Studio           Auth REST RT Store Meta Func   GraphQL
     (3000)          (9999)(3000)(4000)(5000)(8080)(9000)
                       │    │    │    │    │
                       └────┴────┴────┴────┘
                              ▼
                    ┌─────────────────────┐
                    │   PostgreSQL (5432)  │
                    │   localhost only     │
                    └─────────────────────┘
```

Kong is the single externally-facing service. All API routes use key-auth with `anon` and `service_role` consumers. The `/pg/` endpoint (Postgres Meta) is restricted to `service_role` only.

## Files

After installation, the directory structure is:

```
/opt/supabase/
├── .env                    # Secrets (chmod 600)
├── .install.conf           # Saved configuration (chmod 600)
├── docker-compose.yml      # Generated service definitions
├── backups/                # Daily pg_dump backups (gzipped)
└── volumes/
    ├── api/
    │   └── kong.yml        # Kong declarative config (API keys embedded)
    ├── db/
    │   └── init/           # Database initialization scripts
    ├── functions/
    │   └── hello/          # Example edge function
    │       └── index.ts
    ├── logs/
    │   └── vector.yml      # Log collection config (if analytics enabled)
    └── storage/            # File storage data
```

## Backups

A cron job at `/etc/cron.d/supabase-backup` runs daily at 02:00:

- `pg_dump` of the `postgres` database, gzipped
- Stored in `/opt/supabase/backups/`
- Retention configurable (default: 7 days)

To restore from a backup:

```bash
gunzip -c /opt/supabase/backups/supabase-YYYYMMDD-HHMMSS.sql.gz \
  | PGPASSWORD='<password>' psql -h 127.0.0.1 -U supabase_admin -d postgres
```

## Post-Install

After installation, the summary displays:

- Container status
- Access URLs (API + Studio)
- API keys (anon + service_role)
- Dashboard login credentials
- Database connection details
- JWT_SECRET (back this up — loss invalidates all keys and sessions)

### Connect with Supabase client libraries

```javascript
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  'http://your-domain:8000',  // API URL
  'your-anon-key'             // From install summary
)
```

### Add edge functions

Place functions in `/opt/supabase/volumes/functions/`:

```
volumes/functions/
├── hello/
│   └── index.ts
└── my-function/
    └── index.ts
```

Restart the functions container to pick up changes:

```bash
cd /opt/supabase && docker compose restart functions
```

### Common operations

```bash
cd /opt/supabase

# View logs
docker compose logs -f                    # All services
docker compose logs -f auth               # Single service

# Restart a service
docker compose restart auth

# Stop everything
docker compose down

# Start everything
docker compose up -d

# Update (edit versions in .install.conf, then re-run)
sudo bash /path/to/install.sh
```

## Disaster Recovery

1. **Back up secrets first:** Copy `/opt/supabase/.env` to a secure location. The `JWT_SECRET` is irrecoverable — if lost, all API keys and user sessions are invalidated.

2. **Database:** Restore from the latest backup in `/opt/supabase/backups/`.

3. **Full rebuild:** On a fresh server, copy `.env` and `.install.conf` to `/opt/supabase/`, then run `install.sh -y`. It will regenerate all config files and start services with the preserved secrets.

## Development

All project checks run inside the [dev-toolchain](https://github.com/devrail-dev/dev-toolchain) container. The only host requirements are **Docker** and **Make**.

```bash
make check          # Run all checks (lint, format, test, security, docs)
make lint           # ShellCheck
make format         # shfmt format check
make help           # See all targets
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for the complete DevRail standards reference.
