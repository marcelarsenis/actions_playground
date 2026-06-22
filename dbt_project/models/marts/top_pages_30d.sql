{{
    config(
        materialized='table'
    )
}}

-- Most-viewed pages over the last 30 days, ranked.
-- Depends on stg_page_events.
-- Will also fail because of the page_url -> page_path rename.

with recent_events as (

    select
        page_url,
        user_id,
        event_timestamp
    from {{ ref('stg_page_events') }}
    where event_timestamp >= dateadd(day, -30, current_timestamp())

),

ranked as (

    select
        page_url,
        count(*) as view_count,
        count(distinct user_id) as unique_users
    from recent_events
    group by 1

)

select
    page_url,
    view_count,
    unique_users,
    rank() over (order by view_count desc) as popularity_rank
from ranked
