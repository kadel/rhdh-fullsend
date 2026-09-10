# onboard

Add a new repository to the fullsend fleet. Handles WIF provider creation,
GitHub variables/secrets, fleet manifest update, and scaffold installation.

## Usage

```
/fullsend onboard <org>/<repo>
```

## Prerequisites

| Gate | Check | If fail |
|------|-------|---------|
| `repos.yaml` | this repo's fleet manifest | Stop — the file is required |
| `gh` CLI | `gh auth status` | Ask user to authenticate |
| `gcloud` CLI | `gcloud auth list` | Ask user to run `gcloud auth login` |
| `fullsend` CLI | `fullsend --version` | Download from GitHub releases |

## Procedure

### 1. Verify the repo exists

```bash
gh repo view <org>/<repo> --json nameWithOwner -q .nameWithOwner
```

### 2. Check WIF provider

Most RHDH repos already have a WIF provider from a prior `fullsend admin install`.

```bash
gcloud iam workload-identity-pools providers list \
  --location=global --workload-identity-pool=fullsend-inference \
  --project=rhdh-sidekick-167988 \
  --filter="attributeCondition:<repo>" \
  --format="table(name.basename(), state)"
```

If no provider exists, create one:

```bash
PROVIDER_NAME="gh-<org>-<repo>"  # max 32 chars, truncate if needed
PROJECT_NUM="189673402608"
POOL="fullsend-inference"
PROVIDER_PATH="projects/$PROJECT_NUM/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER_NAME"

gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_NAME" \
  --location=global \
  --workload-identity-pool="$POOL" \
  --project=rhdh-sidekick-167988 \
  --issuer-uri=https://token.actions.githubusercontent.com \
  --allowed-audiences="fullsend-mint,https://iam.googleapis.com/$PROVIDER_PATH" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository == '<org>/<repo>'"
```

No per-repo IAM binding is needed — the org-level `aiplatform.user` principal
set covers all repos in `redhat-developer` and `rhdh-parasol` automatically.
If the repo is in a different org, add an org-level binding:

```bash
gcloud projects add-iam-policy-binding rhdh-sidekick-167988 \
  --role="roles/aiplatform.user" \
  --member="principalSet://iam.googleapis.com/projects/189673402608/locations/global/workloadIdentityPools/fullsend-inference/attribute.repository_owner/<org>" \
  --condition=None
```

### 3. Set GitHub variables

```bash
gh variable set FULLSEND_MINT_URL --body "https://mint.fullsend.sh" --repo <org>/<repo>
gh variable set FULLSEND_GCP_REGION --body "global" --repo <org>/<repo>
gh variable set FULLSEND_PER_REPO_INSTALL --body "true" --repo <org>/<repo>
```

Check if already set: `gh variable list --repo <org>/<repo>`

### 4. Set GitHub secrets

```bash
PROJECT_NUM="189673402608"
POOL="fullsend-inference"
PROVIDER_NAME="<from step 2>"

echo "projects/$PROJECT_NUM/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER_NAME" | \
  gh secret set FULLSEND_GCP_WIF_PROVIDER --repo <org>/<repo>

echo "rhdh-sidekick-167988" | \
  gh secret set FULLSEND_GCP_PROJECT_ID --repo <org>/<repo>
```

Check if already set: `gh secret list --repo <org>/<repo>`

### 5. Add to fleet manifest

Add the repo to `repos.yaml` under `github.repos`, in alphabetical order:

```yaml
repos:
  - name: redhat-developer/rhdh-agentic
  - name: redhat-developer/rhdh-cli        # <-- new
  - name: redhat-developer/rhdh-plugins
```

Commit and push to a branch. Open a PR in this repo.

### 6. Install scaffold

After the `repos.yaml` PR is merged, converge the new repo:

```bash
fullsend repos install -f repos.yaml <org>/<repo>
```

This creates a scaffold PR on the target repo. Review and merge it.

### 7. Smoke test

```bash
gh issue create --repo <org>/<repo> \
  --title "test: smoke test after fullsend onboarding" \
  --body "Smoke test — verify triage runs correctly after onboarding.
Close this issue if triage succeeds."
```

Watch the run. If triage succeeds, close the issue.

## What onboarding does NOT do

- Does not create the repo itself
- Does not configure custom agents (use `/fullsend custom-agents` for that)
- Does not rebuild the sandbox image (only needed if the repo uses a
  different yarn version — check `packageManager` in `package.json`)

## Checklist summary

- [ ] WIF provider exists in `fullsend-inference`
- [ ] `FULLSEND_MINT_URL` = `https://mint.fullsend.sh`
- [ ] `FULLSEND_GCP_REGION` = `global`
- [ ] `FULLSEND_GCP_WIF_PROVIDER` secret set
- [ ] `FULLSEND_GCP_PROJECT_ID` secret set
- [ ] Repo added to `repos.yaml`
- [ ] Scaffold PR merged on target repo
- [ ] Smoke test passed
