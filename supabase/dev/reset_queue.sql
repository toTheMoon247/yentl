-- Dev-only: reset the matchmaking queue for testing.
--
-- Two problems this fixes:
--   1) Only women get pinned. The Decision Panel walks the queue by enqueued_at,
--      and M/F alternation depends on the two genders' timestamps interleaving.
--      New seeds and every "Next profile" set enqueued_at = now(), so the men
--      pile up at the back and you see all the women first. This re-staggers the
--      active queue so it interleaves F, M, F, M again.
--   2) Some users never appear (e.g. skipped long ago, or stuck 'matched' from a
--      test). This reactivates them so everyone is reachable again.
--
-- Run in the Studio SQL editor against DEV. Re-run after adding seeds or after a
-- lot of skipping/matching. (Jump-to-pin in the Queue tab also reaches anyone
-- directly, regardless of order.)

-- Reactivate everyone who fell out of the active queue.
update public.matchmaking_queue
set status = 'active', skipped_at = null, updated_at = now()
where status <> 'active';

-- Interleave the two genders by per-gender FIFO rank: rank-1 female, rank-1
-- male, rank-2 female, ... Spread one second apart, an hour back, so new live
-- profiles (enqueued at now()) simply append to the end.
with interleaved as (
    select user_id, row_number() over (order by rn, gender) as seq
    from (
        select user_id, gender,
               row_number() over (partition by gender order by enqueued_at, user_id) as rn
        from public.matchmaking_queue
        where status = 'active'
    ) g
)
update public.matchmaking_queue q
set enqueued_at = now() - interval '1 day' + (i.seq * interval '1 second'),
    updated_at = now()
from interleaved i
where q.user_id = i.user_id;
