{{
    config(
        materialized='incremental',
        incremental_strategy='merge'
    )
}}

-- Daily aggregation of page views per user.
-- Buggy: incremental with merge strategy needs a unique_key, but none is set.
-- When Snowflake tries to merge new rows on top of existing rows, it has no
-- way to identify duplicates, leading to the merge picking up multiple
-- candidate rows for the same target row.
--
-- Real-world failure mode (matches Pendo incidents in prod):
--   100090 (42P18): Duplicate row detected during DML action

with page_events as (

    select * from {{ ref('stg_page_events') }}

    {% if is_incremental() %}
        where event_timestamp >= (select coalesce(max(event_date), '1900-01-01') from {{ this }})
    {% endif %}

),

aggregated as (

    select
        user_id,
        cast(event_timestamp as date) as event_date,
        count(*) as page_view_count,
        count(distinct page_url) as distinct_pages_viewed,
        min(event_timestamp) as first_view_at,
        max(event_timestamp) as last_view_at
    from page_events
    group by 1, 2

)

select * from aggregated
