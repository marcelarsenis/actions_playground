# dbt Failure Agent — Architecture

## What this is

An autonomous agent that watches our prod dbt Cloud jobs (`Production Daily Build` 12032 and `Production Hourly Build` 22404). When one fails, the agent investigates the failure, proposes a fix, validates it actually works by running dbt against a dev schema, and opens a pull request on `cw_dbt` for human review.

The point is to wake up to a reviewable PR instead of a stack trace.

## End-to-end flow

```
dbt Cloud job fails
        |
        v
dbt Cloud sends webhook (POST + HMAC signature)
        |
        v
Azure Function (webhook receiver)
   - validates HMAC signature
   - filters: only act on monitored job IDs
   - filters: only act on run_status = Error
   - translates the dbt payload into a GitHub repository_dispatch event
   - POSTs to api.github.com/repos/<owner>/cw_dbt/dispatches
        |
        v
GitHub Actions workflow on cw_dbt fires
   - checks out cw_dbt
   - installs dbt-snowflake + python deps
   - pulls full failure context from dbt Cloud API
       (manifest.json, catalog.json, run_results.json, error message,
        failing model SQL, upstream/downstream models)
   - calls Cortex inference REST API with the context
       (claude-sonnet-4 or whatever we land on)
   - LLM proposes a fix (modified SQL or YAML)
   - workflow writes the proposed change to disk
   - runs `dbt build --select <model>` against dev schema
   - if pass:
       - run downstream models too to confirm no regression
       - commit fix to a branch
       - open PR with summary of what was tried and why
   - if fail:
       - feed dbt's error back to LLM
       - try again, capped at 3 to 5 iterations
       - if still failing, open a "needs human" issue with full context
        |
        v
PR appears on cw_dbt
        |
        v
Human reviews and merges (or closes)
```

## Why the Azure piece is still there

We already have an Azure Function (`func-cw-dbtagent-001`) wired up to dbt Cloud's webhook with HMAC validation working and job-ID filtering in place. Rather than tear it down, we reuse it as a thin translator between dbt Cloud's webhook format and GitHub's `repository_dispatch` API.

This split is intentional:

- The Azure Function does the boring webhook-receiver job (HMAC verify, filter noise, idempotency check)
- GitHub Actions does the real work (clone, run dbt, call LLM, open PR)

Could we collapse this and have dbt Cloud POST directly to GitHub? In theory, yes. dbt Cloud webhooks let you set a custom URL with a signed payload, but the signature scheme is dbt's HMAC, not GitHub's auth header. GitHub's `repository_dispatch` endpoint expects a specific `Authorization: token <PAT>` header, which dbt Cloud doesn't send. So we need something in the middle to translate. The Azure Function is that translator.

The Azure Function gets dramatically simpler than what we built originally. No more queue, no more orchestrator, no more AI agent code in Python. Just:

1. Receive POST
2. Validate HMAC
3. If monitored job + status = Error, fire `repository_dispatch` to GitHub
4. Return 200

Maybe 50 lines of Python.

## Component map

### Azure Function: webhook receiver

- **Code lives in:** `agent_mvp` repo (existing, will be slimmed down)
- **Deployed to:** `func-cw-dbtagent-001` (Flex Consumption, southcentralus)
- **Triggers:** HTTP POST from dbt Cloud webhook
- **Outputs:** HTTPS POST to `https://api.github.com/repos/<owner>/cw_dbt/dispatches`
- **App settings needed:**
  - `DBT_WEBHOOK_SECRET` — for HMAC verification (already set)
  - `MONITORED_JOB_IDS` — comma-separated list, currently `12032,22404` (already set)
  - `GITHUB_REPO` — `<owner>/cw_dbt`
  - `GITHUB_DISPATCH_PAT` — a fine-grained PAT scoped to `cw_dbt` only with `Contents: Write`
- **What we drop from the original architecture:**
  - Storage queue (`dbt-failures`)
  - Queue trigger orchestrator
  - AI agent code
  - GitHub PR creation
  - Teams notifier
  - Approval handler

### GitHub Actions workflow on cw_dbt

- **Lives at:** `cw_dbt/.github/workflows/dbt-failure-agent.yml`
- **Triggers on:** `repository_dispatch` with type `dbt-failure`
- **Permissions block:**
  ```yaml
  permissions:
    contents: write
    pull-requests: write
  ```
- **Runs on:** `ubuntu-latest` (GitHub-hosted runner). May switch to self-hosted on Azure if the DBA wants tighter IP control on the Snowflake side.
- **Scripts it calls:**
  - `scripts/fetch_failure.py` — pulls run details from dbt Cloud API
  - `scripts/get_fix.py` — calls Cortex with the failure context, parses fix proposal
  - `scripts/apply_fix.py` — writes the LLM's proposed change to disk
  - `scripts/iterate.py` — orchestrates the build/retry loop

### Snowflake (Cortex + dev compute)

- **Service user:** `DBT_FAILURE_AGENT_USER` (to be created by DBA, ask is queued)
- **Auth:** PAT, stored in GitHub Secrets
- **Network policy:** allows GitHub Actions runner IP ranges (or self-hosted runner static IP if we go that route)
- **Cortex usage:** `/api/v2/cortex/inference:complete` for diagnosis, model TBD (claude-sonnet-4 default)
- **dbt usage:** runs `dbt build` against a dev schema. Service user has no prod access at all.

### dbt Cloud

- **Read-only API token:** for pulling run details, manifest, error messages
- **Stored in:** GitHub Secrets as `DBT_CLOUD_API_TOKEN`
- **Already exists** (used during the local prototype work)

## Credentials inventory

What lives where, and what each thing can do:

| Credential | Where stored | Scope | Risk if leaked |
|---|---|---|---|
| `DBT_WEBHOOK_SECRET` | Azure App Settings | HMAC verification of dbt webhooks | Medium. Attacker could forge fake failure events. Mitigated by GitHub Actions being read-only on dbt Cloud anyway. |
| `GITHUB_DISPATCH_PAT` | Azure App Settings | Fire `repository_dispatch` to one repo | Low. Can only trigger workflows, can't read code or modify anything else. |
| GitHub Actions `GITHUB_TOKEN` | Auto-injected per-run by GitHub | Modify cw_dbt during one workflow run | Negligible. Ephemeral, scoped to one run, expires when run ends. |
| `DBT_CLOUD_API_TOKEN` | GitHub Secrets on cw_dbt | Read-only on dbt Cloud account | Medium. Read access to job runs, models, errors. No write capability used. |
| `SNOWFLAKE_PAT` for `DBT_FAILURE_AGENT_USER` | GitHub Secrets on cw_dbt | Cortex inference + dbt builds in dev only | Low to medium depending on dev schema content. No prod access. |

No personal PATs. No long-lived credentials with broad scope. Each credential does one job.

## Iteration loop (the hard part)

The workflow doesn't just call the LLM once and call it done. The loop:

1. Pull failure context (error message, failing model SQL, related files, recent git history of those files)
2. Send context to Cortex with a prompt that asks for a fix as structured JSON: `{ files_to_change: [...], reasoning: "..." }`
3. Apply the proposed change to disk
4. Run `dbt build --select <failing_model> --target dev`
5. Capture the result
6. If `dbt build` succeeds: break out of the loop, validate downstream, open PR
7. If `dbt build` fails: send dbt's new error output back to the LLM with a "your previous fix didn't work, here's what happened, try again" prompt
8. Repeat up to N iterations (default 4)
9. If still failing after N iterations: open a "needs human investigation" issue with the LLM's notes and what was tried

This is the part that needs careful prompt engineering and conversation state management. Most of the engineering effort goes here.

## Cost guards

- Hard cap of 4 LLM iterations per failure
- GitHub Actions workflow timeout: 30 minutes
- Snowflake warehouse: small (XS) for the agent's dev runs
- Idempotency: don't fire on the same `run_id` twice (use a small marker file in a GitHub branch or an Azure Table)

Worst case for one failure: ~4 LLM calls (~$2), ~4 dbt builds (~30 seconds of XS warehouse time), one PR creation. Maybe $3 per failure. If we get 10 failures a month, $30 a month. Manageable.

## What we're not building (yet)

- Teams notifications. The PR shows up in your GitHub notifications, that's enough for now. Can add later.
- Auto-merge. The agent only opens PRs. A human always merges. This is by design.
- Multi-model fixes. If a failure cascades and three models need to change, v1 punts and asks a human. v2 might handle it.
- Cross-repo fixes. Some dbt failures are caused by upstream Fivetran schema changes. The agent only edits files in cw_dbt for v1.

## Open questions / dependencies

- [ ] Snowflake service user needs to be provisioned (ask sent)
- [ ] Confirm Cortex models available in our region/edition
- [ ] Decide on GitHub-hosted vs self-hosted runners (impacts network policy)
- [ ] Pick a dev schema for the agent to materialize into (probably a fresh `DBT_AGENT_DEV` to keep it isolated)
- [ ] Idempotency mechanism: GitHub branch marker vs Azure Table vs in-workflow check via gh API
- [ ] Cortex tool-calling format: confirm Snowflake's REST API matches OpenAI's tools schema or has its own

## What's been tried and tossed

We initially built the whole thing inside Azure (queue, orchestrator, AI agent, GitHub client, Teams notifier, approval handler). It worked end-to-end up to the AI step but the architecture had problems:

- Required service credentials living in Azure App Settings (not a key vault, not federated)
- Snowflake PAT required a network policy that wasn't in place yet
- GitHub PAT required for PR creation, which felt heavy for a personal-PAT MVP
- Teams card with approval buttons added complexity for limited value (you'd see the PR in GitHub anyway)

The pivot to GitHub Actions does three things at once:
- GitHub Actions runtime gets a free `GITHUB_TOKEN`, no PAT needed for PR creation
- Service credentials live in GitHub Secrets, which has the right access controls
- The workflow runs in a fresh Linux container with the repo checked out, which is exactly the environment dbt + LLM tooling expects

Most of the existing Azure code becomes unnecessary. The webhook receiver stays, slimmed down. Everything else moves to GitHub Actions.
