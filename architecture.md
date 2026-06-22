# dbt Failure Agent — Architecture

## What this is

When a prod dbt job fails (`Production Daily Build` 12032 or `Production Hourly Build` 22404), our existing Azure Function receives the dbt Cloud webhook, pulls the error context, and creates a richly-formatted GitHub Issue on `cw_dbt` describing what broke. A human triages the issue, clicks "Assign to Agent" if it looks fixable, and **GitHub Copilot Coding Agent** does the actual diagnosis, code change, and PR creation.

The point: turn 3am dbt failures into a clean queue of triaged-and-fixable issues by 9am, with one-click AI fixes that produce reviewable PRs.

## End-to-end flow

```
dbt Cloud job fails (run_status = Error)
        |
        v
dbt Cloud sends webhook (POST + HMAC signature)
        |
        v
Azure Function (existing, slimmed down)
   - validates HMAC signature
   - filters: monitored job IDs only
   - filters: run_status = Error only
   - pulls failure context from dbt Cloud API
       (failing model name, error message, file path, run URL, run logs)
   - creates a GitHub Issue on cw_dbt with that context
        |
        v
Issue appears in cw_dbt's issue tracker
   - title: "[Auto] <Job name> failed: <model name>"
   - body: error, file path, run links, suggested prompt for Copilot
        |
        v
Human triages (could be anyone on the team)
   - looks at the issue
   - decides: fixable by AI? yes -> click "Assign to Agent"
              maybe   -> add notes, then assign
              no      -> close the issue, fix manually
        |
        v
GitHub Copilot Coding Agent picks it up
   - reads the issue body
   - reads the cw_dbt codebase
   - runs `dbt parse` + `dbt compile` to verify the fix at least compiles
   - opens a PR linked back to the issue
        |
        v
Human reviews the PR
   - reads the proposed fix
   - checks out the branch locally
   - runs `dbt build --select <model> --target dev` to validate
   - merges if good, closes if bad
```

## Why this design

We arrived here after evaluating two more ambitious versions:

### Version A: Fully autonomous Azure-hosted agent
Original plan. Azure Function with a queue, an orchestrator, an LLM client (Cortex via REST), a GitHub client for PRs, a Teams notifier, and an approval handler. Got most of the way built before we realized the AI step needed credentials we didn't want to set up (Snowflake PAT with network policy, GitHub PAT with PR-create scope, possibly Anthropic key).

### Version B: GitHub Actions-hosted agent
Replace Azure with a GitHub Actions workflow that runs the agent loop ourselves (LLM call → fix → dbt build → iterate → PR). Cleaner credential story (only Snowflake creds + LLM creds in GitHub Secrets). But still required service-user negotiation, prompt engineering for the iteration loop, cost guards, and roughly 1.5–2 weeks of focused engineering.

### Version C: This one (issue-creation + Copilot Coding Agent)
Realized after seeing the Agents tab on cw_dbt that GitHub already runs the autonomous coding agent we were going to build. Their version has the LLM, the iteration loop, the dev sandbox, and PR creation all wired up. We just feed it issues.

The key insight: **since we're going to review every PR anyway, the marginal value of fully-autonomous trigger is low**. The "human clicks Assign to Agent" step costs ~2 seconds and gains a triage layer that prevents the agent from burning premium-request quota on un-fixable failures.

## What we keep, what we throw away

From the original Azure build:

| Component | Status |
|-----------|--------|
| `webhook_receiver` (HTTP trigger, HMAC validation) | Keep |
| `failure_investigator.py` (pulls run context from dbt Cloud) | Keep, simplify |
| `dbt_cloud_client.py` | Keep |
| `config.py` | Keep, slim down |
| `host.json` | Keep |
| `agent_orchestrator` (queue trigger) | Drop |
| `dbt-failures` storage queue | Drop |
| `ai_agent.py` | Drop |
| `github_client.py` (PR creation logic) | Drop |
| `teams_notifier.py` | Drop |
| `approval_handler` | Drop |

Net result: the Azure Function shrinks from a ~600-line orchestration thing to maybe ~100 lines of "receive webhook, format issue, POST to GitHub."

## Component map

### Azure Function (slimmed down)

- **Lives in:** existing `agent_mvp` repo, gets pruned heavily
- **Deployed to:** `func-cw-dbtagent-001` (Flex Consumption, southcentralus)
- **Code shape:**
  ```
  function_app.py        # one HTTP-triggered function
  github_issue_client.py # ~30 lines: takes a payload, POSTs to GitHub Issues API
  config.py              # env var loading
  dbt_cloud_client.py    # existing, used to enrich the issue body
  failure_investigator.py # existing, simplified
  ```
- **App settings:**
  - `DBT_WEBHOOK_SECRET` — for HMAC verification (already set)
  - `DBT_CLOUD_API_TOKEN` — read-only, fetches run details (already set)
  - `DBT_CLOUD_BASE_URL`, `DBT_CLOUD_ACCOUNT_ID` (already set)
  - `MONITORED_JOB_IDS` — `12032,22404` (already set)
  - `GITHUB_REPO` — `cw-data-services/cw_dbt`
  - `GITHUB_ISSUE_PAT` — fine-grained PAT, `Issues: Read and write` on `cw_dbt` only

### GitHub Copilot Coding Agent (already wired up by GitHub)

- **Where it runs:** GitHub-managed sandbox environment, ephemeral per run
- **Auth:** GitHub-internal — none of our concern
- **Trigger:** human clicks "Assign to Agent" button in the issue UI
- **What it can do without external creds:**
  - Read the cw_dbt codebase
  - Read the issue body (which has all our enriched context)
  - Run `dbt parse` and `dbt compile` (offline checks)
  - Run other static checks (sqlfluff, dbt-checkpoint, etc.)
  - Make file changes
  - Open a PR linked to the issue
- **What it can't do without external creds:**
  - Run `dbt build` against real Snowflake data (live execution)
  - Verify a fix actually produces correct rows

The "can't run dbt build" gap is acceptable because the human reviewer does that step locally before merging — same as a normal PR review.

### dbt Cloud

- Webhook configured to POST to the Azure Function on `run.errored` events
- HMAC secret already set
- Read-only API token already in place

### cw_dbt repo

- No changes needed in the repo itself
- Copilot Coding Agent is already enabled (visible from the Agents tab in the UI)
- Optional future enhancement: add a `.github/copilot-instructions.md` to give the agent project-specific context (where models live, how to run tests locally, etc.)

## Credentials inventory

| Credential | Where stored | What it can do | Risk if leaked |
|---|---|---|---|
| `DBT_WEBHOOK_SECRET` | Azure App Settings | HMAC verify dbt webhooks | Medium — could forge fake failure events. Triage step catches anything weird. |
| `DBT_CLOUD_API_TOKEN` | Azure App Settings | Read-only on dbt Cloud | Medium — visibility into job runs and errors only |
| `GITHUB_ISSUE_PAT` | Azure App Settings | Create issues on cw_dbt only | Low — could spam issues, but `Issues: Write` can't modify code or merge PRs |

That's it. **Three credentials, all narrowly scoped, no service-user negotiation, no Snowflake credentials, no network policies.**

## Issue body template (what the Azure Function generates)

```markdown
## Failure summary

- **Job:** Production Daily Build (id: 12032)
- **Run:** 70437506979734 ([dbt Cloud link](https://hu993.us1.dbt.com/...))
- **Started:** 2026-06-22 03:00 ET
- **Branch:** master
- **Failed model:** `pendo_page_history`
- **File:** `models/pendo/pendo_page_history.sql`

## Error

```
Database Error in model pendo_page_history
  100090 (42P18): Duplicate row detected during DML action
```

## Suggested context for the agent

This looks like a classic incremental-model dedup issue. Likely fixes:
- Add or fix a `unique_key` on the incremental config
- Add a deduplication step before the merge
- Switch incremental_strategy

## How to validate before merging

```bash
git checkout <agent-branch>
dbt build --select pendo_page_history --target dev
```
```

That structured body is what makes Copilot effective — it doesn't have to dig for context, it's all there.

## Open questions / dependencies

- [ ] Confirm Copilot Coding Agent license actually includes premium-request capacity for `cw_dbt` use volume (already enabled, just need to confirm quota)
- [ ] Decide: Azure Function caller's PAT — owned by Marcel personally, or by a team service identity? Ideally team-owned so it doesn't break when individuals change roles.
- [ ] Decide: should the Azure Function auto-tag certain failures with labels like `dbt-failure` for filtering?
- [ ] Optional: add `.github/copilot-instructions.md` to cw_dbt with project-specific guidance for the agent
- [ ] Optional: idempotency check — don't create duplicate issues for the same `run_id` if dbt Cloud retries the webhook

## What's not in scope (and might never be)

- **Auto-assign to Copilot.** Possible, but requires a Classic PAT with `repo` scope or a GitHub App. Saves ~2 seconds per failure but loses the triage layer. Probably not worth it.
- **Teams notifications.** GitHub's own notifications already handle this — issue assigned, PR opened, etc. all show up in your inbox if you're a member of the repo.
- **Automated dbt build validation.** Would require Snowflake service-user setup. Skip for v1; the human reviewer handles validation locally.
- **Multi-model fixes.** When one failure cascades to several models, the agent might need to touch multiple files. Copilot can handle this in principle; we'll see how it does in practice.

## Effort to ship

Roughly:

| Task | Time |
|---|---|
| Slim down `function_app.py` to just the webhook handler | 1 hour |
| Write `github_issue_client.py` (~30 lines) | 1 hour |
| Build the issue body template with all the enrichment | 2 hours |
| Generate fine-grained PAT, add to App Settings | 5 minutes |
| Redeploy Azure Function | 15 minutes |
| Test end-to-end: trigger a fake failure, see issue appear, assign Copilot, watch PR | 30 minutes |

**Probably half a day** of actual work. Plus whatever ad-hoc tuning the issue template needs after watching Copilot's first few real-world runs.

## What we learned during exploration

A summary of dead ends so future-us doesn't relitigate:

- Azure Function with full agent loop: works in theory, but credential management was untenable for an MVP
- GitHub Actions workflow with custom LLM loop: cleaner credentials, but still ~2 weeks of work and required Snowflake service user
- Cortex Code desktop app deep-link: Cortex Code can be opened with `coco://` URLs but has no documented "open chat with prefilled prompt" mechanism, and it's a desktop app anyway so no autonomous use possible
- Auto-assign Copilot via fine-grained PAT: not supported, GitHub gates Bot assignment behind Classic PAT or GitHub App
- Snowflake PAT for the agent: blocked on network policy, required admin negotiation, ultimately not needed in this design
