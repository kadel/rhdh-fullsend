# fleet-status

Audit all repos with fullsend installed across `redhat-developer` and
`rhdh-parasol` orgs. Compare against the managed fleet in `repos.yaml`.

## Usage

```
/fullsend fleet-status
```

## Concepts

| Term | Meaning |
|------|---------|
| **Managed** | Listed in `repos.yaml` — version-pinned, converged via `fullsend repos install`, scaffold PRs on upgrade |
| **Installed** | Has `.fullsend/config.yaml` — was set up via `fullsend admin install` or manual config, may or may not be actively used |
| **Unmanaged** | Installed but not in `repos.yaml` — runs fullsend but is not version-converged by the fleet |

`repos.yaml` is the source of truth for which repos we actively maintain.
Unmanaged repos may still have working fullsend (WIF, secrets, workflows)
but won't receive scaffold upgrades or shim customizations.

## Procedure

### 1. Scan both orgs for installed repos

```bash
ORGS="redhat-developer rhdh-parasol"
for org in $ORGS; do
  for repo in $(gh repo list "$org" --json name --jq '.[].name' --limit 300); do
    if gh api "repos/$org/$repo/contents/.fullsend/config.yaml" --jq '.name' &>/dev/null; then
      echo "$org/$repo"
    fi
  done
done
```

### 2. Parse managed repos from manifest

```bash
grep '^\s*- name:' repos.yaml | sed 's/.*name:\s*//'
```

### 3. Report

Show three columns:

| Column | Meaning |
|--------|---------|
| Repo | `org/name` |
| Managed | Yes if in `repos.yaml` |
| Shim version | `reusable-dispatch.yml` SHA comment (e.g. `v0.43.0`) or `none` |

Group by org. Highlight unmanaged repos — these are candidates for either
adding to the manifest or removing fullsend from.

### 4. Optional: check shim version on unmanaged repos

For unmanaged repos that have a fullsend workflow, check what version
they're running:

```bash
gh api "repos/$ORG/$REPO/contents/.github/workflows/fullsend.yaml" \
  --jq '.content' | base64 -d | grep -o '# v[0-9.]*'
```

## When to run

- Before and after a fleet-wide upgrade (`/fullsend upgrade`)
- When onboarding a new repo (`/fullsend onboard`)
- Periodically to catch repos that were installed outside the fleet workflow
