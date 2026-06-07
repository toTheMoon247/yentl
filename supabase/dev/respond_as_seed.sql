-- Dev-only: simulate the SEEDED side of a match responding, so the full
-- accept/reject flow can be tested with just one real account.
--
-- You play your real account's side in the app (Accept/Reject in the Matches
-- tab); this snippet plays the seed's side. It targets the most recent PENDING
-- match that has a seeded participant (display_name like 'Test %').
--
-- Default: the seed ACCEPTS. To make the seed REJECT instead, change BOTH
-- 'accepted' values below to 'rejected', then run.
--
-- Typical flow for "both accept -> confirmed":
--   1. In the matchmaker app, create a match between your account and a seed.
--   2. Run this (seed accepts).
--   3. In Yentl (your account) -> Matches -> Accept. State becomes 'confirmed'.
-- For "other rejects": set this to 'rejected' and run; your Matches tab shows
-- "Not a match" regardless of what you tap.

with target as (
    select m.id, (pa.display_name like 'Test %') as a_is_seed
    from public.matches m
    join public.profiles pa on pa.id = m.user_a
    join public.profiles pb on pb.id = m.user_b
    where m.state = 'pending'
      and (pa.display_name like 'Test %' or pb.display_name like 'Test %')
    order by m.created_at desc
    limit 1
)
update public.matches m
set a_response = case when t.a_is_seed then 'accepted' else m.a_response end,
    b_response = case when t.a_is_seed then m.b_response else 'accepted' end
from target t
where m.id = t.id;

-- Recompute state from the two responses (matches respond_to_match's logic).
update public.matches
set state = case
    when a_response = 'rejected' or b_response = 'rejected' then 'rejected'
    when a_response = 'accepted' and b_response = 'accepted' then 'confirmed'
    else 'pending'
end
where state = 'pending';

-- Peek at recent matches:
-- select id, state, a_response, b_response, expires_at from public.matches
-- order by created_at desc limit 5;
