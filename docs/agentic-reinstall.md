# rhdh-agentic: Fullsend Reinstall Log

Clean reinstall of fullsend on `redhat-developer/rhdh-agentic` to start from
a vanilla scaffold and incrementally add only what's needed.

## Context

rhdh-agentic accumulated fullsend customizations organically over May-June
2026 — custom debug agent, Phase 1/2 code agent, openspec review agent,
providers/profiles for sandbox networking, env files, harness overrides.
Meanwhile, the repo was restructured as a two-level Yarn workspaces monorepo
(mirroring rhdh-plugins).

Rather than carry all that forward, we wiped the config and reinstalled
fresh. This document tracks: (1) the reinstall steps, (2) what
rhdh-plugins has customized as reference, and (3) each customization we
add back with rationale.

## Timeline

### 2026-07-10 — Monorepo layout + clean reinstall

**Monorepo setup** (committed directly to main):

- Root `package.json` (`@internal/rhdh-agentic`, `packageManager: yarn@4.12.0`)
- Root `.yarnrc.yml` + `.yarn/releases/yarn-4.12.0.cjs`
- `workspaces/backstage-agent/` — independent workspace with own `yarn.lock`
  - `packages/backend/` — minimal `createBackend()` (auth + catalog + guest)
  - `plugins/agent-common/` — placeholder common-library plugin
  - Backstage 1.52.0, `yarn install` + `yarn tsc` pass clean
- `.gitignore` updated with Yarn Berry + `dist-types/` patterns

**Fullsend wipe** (committed directly to main):

- Old config preserved on branch `fullsend/pre-reset`
- Deleted all `.fullsend/` files (32 files) and all fullsend workflows (3 files)

**Reinstall** (PR #88, merged):

```bash
fullsend github setup redhat-developer/rhdh-agentic \
  --inference-project "$FULLSEND_INFERENCE_PROJECT" \
  --inference-wif-provider "$FULLSEND_INFERENCE_WIF_PROVIDER" \
  --mint-url "$FULLSEND_MINT_URL" \
  --skip-app-setup
```

Installer v0.30.0 scaffolded:
- `.fullsend/config.yaml` — 6 roles, `allowed_remote_resources`, `create_issues`
- `.fullsend/customized/` — empty dirs (`.gitkeep` only)
- `.github/workflows/fullsend.yaml` — shim pinned to `@807037ff` (v0.30.0)
- Secrets/variables set: GCP project, WIF provider, mint URL, region

## Comparison: rhdh-plugins customizations

Reference point for what rhdh-plugins has on top of the vanilla scaffold.
Each row is a potential customization to port to rhdh-agentic.

### Harness overrides

| File | rhdh-plugins | rhdh-agentic (vanilla) | Needed? |
|------|-------------|----------------------|---------|
| `harness/code.yaml` | Custom `image`, `host_files` (2 env files), `skills: [rhdh-workspace]` | Upstream default | Yes — yarn won't work without custom image + env |
| `harness/fix.yaml` | Custom `image`, `host_files`, `skills`, `forge.github.pre_script: scripts/pre-fix-rebase.sh` | Upstream default | Yes — same reasons + rebase before fix |
| `harness/review.yaml` | Upstream default | Upstream default | No |
| `harness/triage.yaml` | Upstream default | Upstream default | No |

### Env files

| File | rhdh-plugins | rhdh-agentic (vanilla) | Needed? |
|------|-------------|----------------------|---------|
| `env/rhdh-toolchain.env` | `COREPACK_HOME=/tmp/corepack`, `OPENSPEC_TELEMETRY=0` | Not present | Yes — corepack needs writable dir, telemetry blocked by sandbox |
| `env/yarn-proxy.env` | Maps `HTTP_PROXY` → `YARN_HTTP_PROXY` | Not present | Yes — Yarn Berry ignores standard proxy vars |

### Skills

| Skill | rhdh-plugins | rhdh-agentic (vanilla) | Needed? |
|-------|-------------|----------------------|---------|
| `rhdh-workspace` | Routes to correct workspace, runs `yarn install --immutable`, scopes tests | Not present | Yes — without it, agent doesn't know it's a monorepo |

### Scripts

| Script | rhdh-plugins | rhdh-agentic (vanilla) | Needed? |
|--------|-------------|----------------------|---------|
| `scripts/pre-fix-rebase.sh` | Rebases PR branch before fix agent runs | Not present | Yes — prevents stale-base conflicts |

### Other

| Item | rhdh-plugins | rhdh-agentic (vanilla) | Needed? |
|------|-------------|----------------------|---------|
| Custom sandbox image | `ghcr.io/redhat-developer/rhdh-fullsend-code:latest` | Upstream `fullsend-code:latest` | Yes — has corepack/yarn pre-activated |
| Providers/profiles | Not present (handled by scaffold) | Not present | No — scaffold includes them |
| Custom agents | Not present | Not present | Not yet |

## Customization log

Each customization added back, with the PR/commit that added it and the
test that validated it.

| # | Customization | PR | Test | Status |
|---|--------------|-----|------|--------|
| 0 | Vanilla scaffold | #88 | `/fs-triage` smoke test | Pending |
| 1 | Custom image + env files + host_files | — | `/fs-code` with yarn install | Pending |
| 2 | rhdh-workspace skill | — | `/fs-code` routes to workspace | Pending |
| 3 | pre-fix-rebase.sh + fix.yaml override | — | `/fs-fix` on a PR | Pending |

## Install values

Stored in rhdh-agentic `.envrc` (gitignored):

```bash
export FULLSEND_INFERENCE_PROJECT=rhdh-sidekick-167988
export FULLSEND_INFERENCE_WIF_PROVIDER=projects/189673402608/locations/global/workloadIdentityPools/fullsend-pool/providers/gh-redhat-developer-rhdh-agentic
export FULLSEND_MINT_URL=https://fullsend-mint-gljhbkcloq-uc.a.run.app
```

## Reference branches

| Branch | Content |
|--------|---------|
| `fullsend/pre-reset` | All old `.fullsend/` config + workflows before the wipe |
| `main` | Vanilla scaffold + monorepo layout |
