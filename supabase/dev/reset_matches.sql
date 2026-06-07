-- Dev-only: clear all matches so seeds are free to be matched again during
-- testing, and return anyone who was 'matched' in the queue to 'active'.
--
-- create_match refuses to match a user who already has a pending match, so once
-- you've created a few test matches those people are stuck. Run this to wipe the
-- slate. Run in the Studio SQL editor against DEV. Pair with reset_queue.sql to
-- also re-interleave the queue order.

delete from public.matches;

update public.matchmaking_queue
set status = 'active', updated_at = now()
where status = 'matched';
