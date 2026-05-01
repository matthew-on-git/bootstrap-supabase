# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- nginx TCP stream proxy for Postgres on `:5432`. The supabase-db
  container stays bound to `127.0.0.1:5432` (no compose change), and
  nginx exposes Postgres on the host's primary external interface via
  the `stream` module — same architectural pattern as the existing
  HTTP reverse proxy. Enables external CI tooling (migration jobs,
  IDE clients) to reach Postgres without rebinding the Docker port.
  Bind address is auto-detected from the default-route interface;
  override with `PG_PROXY_LISTEN_IP=<ip>` env var if needed (e.g.,
  multi-NIC hosts). Cannot use `0.0.0.0:5432` because Linux treats it
  as overlapping with the docker-proxy's `127.0.0.1:5432` — would
  fail to bind. Idempotent on re-run; opt out by deleting
  `/etc/nginx/stream.d/postgres.conf` and reloading nginx.
- `libnginx-mod-stream` added to apt packages when TLS is enabled
  (provides the dynamic stream module nginx needs for the above).

### Changed

- Updated beta banner to v1 stable

## [1.0.0] - 2026-03-01

### Added

- Makefile with all 7 language ecosystems (Python, Bash, Terraform, Ansible, Ruby, Go, JavaScript/TypeScript)
- `make init` / `make _init` config scaffolding target
- `.gitlab-ci.yml` with parallel jobs: lint, format, test, security, scan, docs
- Pre-commit hooks for all supported languages (commented out by default)
- Agent instruction files (CLAUDE.md, AGENTS.md, .cursorrules, .opencode/agents.yaml)
- DevRail compliance badge in README
- Retrofit guide for adding DevRail to existing repositories
- `.devrail.yml` with all 7 languages listed (commented out)
- `.editorconfig`, `.gitignore`, `DEVELOPMENT.md`, `CHANGELOG.md`, `LICENSE`
