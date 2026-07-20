# DEVRAIL.md

- DEVRAIL_VERSION: 0.1.0
- TEMPLATE_TIER: infra
- OWNER_TEAM: hardware-infra
- REPO_CRITICALITY: medium

## Migration Plan

This repository already has partial DevRail wiring through .devrail.yml, .editorconfig, .gitlab-ci.yml, and/or Makefile support.

Complete migration target:
- Keep existing project-specific DevRail config in .devrail.yml.
- Use this file for repo ownership, tier, criticality, and local override tracking.
- Use the default merge request template for validation evidence, risk, rollback, and compliance checks.
- Do not weaken existing CI or security gates during migration.

## Local Overrides
> Add only if required; include rationale + expiry date.

- None