{{
    config(
        materialized='view'
    )
}}

select
    event_id,
    user_id,
    page_path,
    occurred_at,
    _ingested_at
from {{ source('raw', 'page_events') }}
