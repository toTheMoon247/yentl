-- Dev-only: create mutual likes among seeded profiles so the Decision Panel
-- has candidates to show. Run in the Studio SQL editor against DEV.
--
-- Seeded profiles never swipe, so out of the box no mutual likes exist and the
-- panel is all empty states. This pairs the first N male seeds with the first N
-- female seeds and inserts likes BOTH ways, creating mutual matches. When a
-- paired user is pinned, their partner shows up as a candidate.
--
-- Idempotent (ON CONFLICT). Bump the `rn <= 10` to make more pairs.

with m as (
    select id, row_number() over (order by display_name) as rn
    from public.profiles where display_name like 'Test Man%'
),
f as (
    select id, row_number() over (order by display_name) as rn
    from public.profiles where display_name like 'Test Woman%'
),
pairs as (
    select m.id as mid, f.id as fid
    from m join f on m.rn = f.rn
    where m.rn <= 10
)
insert into public.swipes (from_user, to_user, action)
select mid, fid, 'like' from pairs
union all
select fid, mid, 'like' from pairs
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
-- select seed_id, (select id from me), 'like' from liked_back
-- on conflict (from_user, to_user) do nothing;
