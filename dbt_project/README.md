# Fake dbt project (for testing)

This is a tiny dbt project that exists only to give Copilot Coding Agent a realistic codebase to fix when we test the failure-fix workflow. It mirrors the structure of `cw_dbt` at a very small scale.

## Layout

```
dbt_project/
├── dbt_project.yml
├── models/
│   ├── staging/
│   │   ├── sources.yml
│   │   └── stg_page_events.sql       (view, just selects from source)
│   └── marts/
│       ├── schema.yml
│       └── daily_user_page_views.sql (incremental, intentionally broken)
```

## The intentional bug

`daily_user_page_views.sql` is materialized as `incremental` with `incremental_strategy='merge'` but **does not declare a `unique_key`**. When dbt tries to merge new rows on top of existing rows, Snowflake can't identify which target rows match, leading to:

```
100090 (42P18): Duplicate row detected during DML action
```

This is the same failure mode we saw in the Pendo prod failure (run 70437506979734). It's a common bug pattern — incremental + merge without unique_key, or with a unique_key that isn't actually unique in the source data.

## Expected fix

A correct fix would be one of:
- Add `unique_key=['user_id', 'event_date']` to the incremental config
- Switch `incremental_strategy='delete+insert'` (also requires unique_key)
- Pre-deduplicate in a CTE before the final select

We're not going to "run" this project against a real warehouse — its purpose is solely to give the agent something to read and propose a fix against.
