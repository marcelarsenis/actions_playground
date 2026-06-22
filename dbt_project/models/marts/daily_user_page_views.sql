{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key=['user_id', 'event_date']
    )
}}

-- Daily aggregation of page views per user.

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
