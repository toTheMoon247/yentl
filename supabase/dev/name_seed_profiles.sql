-- Dev-only: give the existing seeded profiles real gendered names (in place —
-- keeps their IDs, photos, mutual likes, passwords intact).
--
-- Names are assigned by the EMAIL NUMBER (seed-f-05 -> woman name #5), so the
-- mapping is deterministic and matches both seed_profiles.sql and the DEBUG
-- login picker. "Kanyin" is name #5 -> seed-f-05, which is the profile that
-- already holds Kanyin.jpg, so her name and photo line up with no re-upload.
--
-- Seeds are identified by email (seed-%@yentl.test). Run in the Studio SQL
-- editor against DEV. Re-running just re-sets the names (idempotent).

with female_names(ord, name) as (values
    (1, 'Olivia'), (2, 'Maya'), (3, 'Sofia'), (4, 'Aisha'), (5, 'Kanyin'),
    (6, 'Noa'), (7, 'Hannah'), (8, 'Emma'), (9, 'Leila'), (10, 'Yara'),
    (11, 'Chloe'), (12, 'Mia'), (13, 'Tamar'), (14, 'Zoe'), (15, 'Amara'),
    (16, 'Isabella'), (17, 'Priya'), (18, 'Nina'), (19, 'Grace'), (20, 'Ava')
),
male_names(ord, name) as (values
    (1, 'Liam'), (2, 'Noah'), (3, 'Ethan'), (4, 'Omar'), (5, 'Daniel'),
    (6, 'Lucas'), (7, 'Adam'), (8, 'Mateo'), (9, 'Eitan'), (10, 'Yusuf'),
    (11, 'Caleb'), (12, 'Leo'), (13, 'David'), (14, 'Aaron'), (15, 'Kofi'),
    (16, 'James'), (17, 'Arjun'), (18, 'Ben'), (19, 'Marco'), (20, 'Theo')
),
seeds as (
    -- ord = the NN in seed-f-NN / seed-m-NN, so names key off the email number.
    select p.id, p.gender,
           split_part(split_part(u.email, '-', 3), '@', 1)::int as ord
    from public.profiles p
    join auth.users u on u.id = p.id
    where u.email like 'seed-%@yentl.test'
)
update public.profiles p
set display_name = coalesce(fn.name, mn.name, p.display_name)
from seeds s
left join female_names fn on s.gender = 'female' and fn.ord = s.ord
left join male_names mn on s.gender = 'male' and mn.ord = s.ord
where p.id = s.id;
