-- Dev-only: create mutual likes among seeded profiles so the Decision Panel
-- has candidates to show. Run in the Studio SQL editor against DEV.
--
-- Seeded profiles never swipe, so out of the box no mutual likes exist and the
-- panel is all empty states. This pairs the first N male seeds with the first N
-- female seeds and inserts likes BOTH ways, creating mutual matches. When a
-- paired user is pinned, their partner shows up as a candidate.
--
-- Idempotent (ON CONFLICT). Two parts:
--   - a base 1:1 pairing (man rn ↔ woman rn) for the first 10, and
--   - a fan-out so the first 5 men ALSO match women rn+1 and rn+2, giving
--     several people 2–3 mutual matches (e.g. man #1 ↔ women #1/#2/#3, and
--     woman #3 ends up matched with men #1/#2/#3).

with m as (
    select id, row_number() over (order by display_name) as rn
    from public.profiles where display_name like 'Test Man%'
),
f as (
    select id, row_number() over (order by display_name) as rn
    from public.profiles where display_name like 'Test Woman%'
),
pairs as (
    -- base 1:1
    select m.id as mid, f.id as fid
    from m join f on f.rn = m.rn
    where m.rn <= 10
    union
    -- fan-out: first 5 men also match the next two women
    select m.id, f.id
    from m join f on f.rn in (m.rn + 1, m.rn + 2)
    where m.rn <= 5
)
insert into public.swipes (from_user, to_user, action)
select mid, fid, 'like'::public.swipe_action from pairs
union all
select fid, mid, 'like'::public.swipe_action from pairs
on conflict (from_user, to_user) do nothing;

-- Also make a few seeds mutually like YOUR real account, so YOUR profile (when
-- pinned) shows candidates too. Replace the email, then uncomment.
-- with me as (
--     select u.id from auth.users u where u.email = 'YOUR-GMAIL@gmail.com'
-- ),
-- liked_back as (
--     -- opposite-gender seeds that you already liked
--     select s.to_user as seed_id
--     from public.swipes s
--     join me on s.from_user = me.id
--     where s.action = 'like'
--     limit 5
-- )
-- insert into public.swipes (from_user, to_user, action)
-- select seed_id, (select id from me), 'like'::public.swipe_action from liked_back
-- on conflict (from_user, to_user) do nothing;
