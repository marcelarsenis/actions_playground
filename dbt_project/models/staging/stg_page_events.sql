{{
    config(
        materialized='view'
    )
}}

select
    event_id,
    user_id,
    page_path,
    event_timestamp,
    _ingested_at
from {{ source('raw', 'page_events') }}
