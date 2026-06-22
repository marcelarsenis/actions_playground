# actions-playground

A scratch repo for learning GitHub Actions before building the dbt failure agent
on `cw_dbt`.

## What's in here

| File | Purpose |
|------|---------|
| `.github/workflows/1-hello-world.yml` | Simplest possible workflow. Runs on every push. |
| `.github/workflows/2-manual-with-inputs.yml` | Manual trigger with form inputs. |
| `.github/workflows/3-webhook-triggered.yml` | Triggered by external HTTP POST (`repository_dispatch`). |

## How to run them

1. Push this folder to your GitHub repo.
2. Go to the **Actions** tab.
3. For workflow 1: it runs automatically on push. Watch it in the Actions tab.
4. For workflow 2: pick "2 - Manual With Inputs" → click **Run workflow** → fill the form.
5. For workflow 3: trigger from your laptop with curl (instructions inside the YAML).

## After these work, the next steps will be

4. Workflow that uses Python + a secret
5. Workflow that creates a PR
6. Tiny dbt project + dbt run in CI
7. LLM call from a workflow
8. Combine everything → mini agent
