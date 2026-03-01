# Project Name

> Built with [DevRail](https://devrail.dev) `v1` standards. See [STABILITY.md](STABILITY.md) for component status.

> One-line project description.

<!-- TODO: Replace badge URLs with actual project paths -->
[![pipeline status](https://gitlab.com/NAMESPACE/PROJECT/badges/main/pipeline.svg)](https://gitlab.com/NAMESPACE/PROJECT/-/commits/main)
[![DevRail compliant](https://devrail.dev/images/badge.svg)](https://devrail.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Quick Start

1. **Clone the repository:**

   ```bash
   git clone https://gitlab.com/NAMESPACE/PROJECT.git
   cd PROJECT
   ```

2. **Configure your languages** in `.devrail.yml`:

   ```yaml
   languages:
     - python
     - bash
   ```

3. **Install pre-commit hooks:**

   ```bash
   make install-hooks
   ```

## Usage

All project tasks are managed through the Makefile. Run `make help` to see available targets:

```
check                Run all checks (lint, format, test, security, docs)
docs                 Generate documentation
format               Run all formatters
help                 Show this help
install-hooks        Install pre-commit hooks
lint                 Run all linters
scan                 Run full scan (lint + security)
security             Run security scanners
test                 Run all tests
```

All tools run inside the [dev-toolchain](https://github.com/devrail-dev/dev-toolchain) container. The only host requirements are **Docker** and **Make**.

## Configuration

### `.devrail.yml`

The `.devrail.yml` file at the project root declares which languages and settings apply to this project. Uncomment the languages you use:

```yaml
languages:
  - python       # ruff, bandit, pytest, mypy
  - bash         # shellcheck, shfmt, bats
  - terraform    # tflint, terraform fmt, tfsec, checkov, terraform-docs
  - ansible      # ansible-lint, molecule

fail_fast: false   # true = stop at first failure
log_format: json   # json or human
```

### `.pre-commit-config.yaml`

Pre-commit hooks are pre-configured. Language-specific hooks are commented out by default. Uncomment the hooks matching your `.devrail.yml` languages.

### `.editorconfig`

Formatting rules (indent style, line endings, trailing whitespace) are defined in `.editorconfig`. All editors and AI agents must respect these settings.

## Contributing

See [DEVELOPMENT.md](DEVELOPMENT.md) for the complete development standards. To add a new language ecosystem to DevRail, see the [Contributing to DevRail](https://github.com/devrail-dev/devrail-standards/blob/main/standards/contributing.md) guide.

This section covers:

- Critical rules for all contributors
- Makefile contract and target descriptions
- Conventional commit format
- Per-language tool references

## Retrofit Existing Project

To add DevRail standards to an existing GitLab repository, follow the steps below. The order matters because some files reference others.

**Prerequisites:** Docker and Make must be installed on the host. Verify Docker access with `docker pull ghcr.io/devrail-dev/dev-toolchain:v1`.

### Step 1: Core Configuration

Copy the foundation files that all other DevRail components depend on.

- [ ] Copy `.devrail.yml` and uncomment your project's languages
- [ ] Copy `.editorconfig`
- [ ] Merge `.gitignore` patterns into your existing `.gitignore` (do not overwrite)
- [ ] Copy `Makefile` (or merge DevRail targets if you have an existing Makefile)

### Step 2: Pre-Commit Hooks

Set up local enforcement for commit standards and secret detection.

- [ ] Copy `.pre-commit-config.yaml` and uncomment hooks matching your `.devrail.yml` languages
- [ ] Run `make install-hooks`

### Step 3: Agent Instruction Files

Add AI agent integration so any tool used on the project knows the standards.

- [ ] Copy `DEVELOPMENT.md`, `CLAUDE.md`, `AGENTS.md`, `.cursorrules`
- [ ] Create `.opencode/` directory and copy `.opencode/agents.yaml`

### Step 4: CI Pipeline

Set up remote enforcement to validate every push and merge request.

- [ ] Copy `.gitlab-ci.yml`
- [ ] Enable "Pipelines must succeed" in Settings > General > Merge requests

### Step 5: Project Documentation

Add MR template, code ownership, and changelog.

- [ ] Copy `.gitlab/merge_request_templates/default.md` (create directories first)
- [ ] Copy `.gitlab/CODEOWNERS` and configure ownership patterns for your team
- [ ] Copy `CHANGELOG.md` if not already present

### Step 6: Verify

Confirm everything works end-to-end.

- [ ] Run `make check` and fix any issues
- [ ] Create a test commit to verify pre-commit hooks fire
- [ ] Create a test MR to verify the CI pipeline runs

### Troubleshooting

**Container pull failure:** Ensure Docker is running and can pull from `ghcr.io`. Test with:

```bash
docker pull ghcr.io/devrail-dev/dev-toolchain:v1
```

**Pre-commit install failure:** Ensure `pre-commit` is installed on the host. Install via `pip install pre-commit` or `brew install pre-commit`.

**Makefile conflicts:** If the project has an existing Makefile, merge the DevRail targets into it. The DevRail Makefile structure (variables, `.PHONY`, public targets, internal targets) can coexist with project-specific targets.

**.gitignore conflicts:** Do not overwrite the existing `.gitignore`. Merge the DevRail patterns (OS files, editor files, language artifacts, `.devrail-output/`, secrets) into your existing file.

**CI pipeline not running:** Ensure the GitLab project has CI/CD enabled in Settings > General > Visibility, project features, permissions.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
