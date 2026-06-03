-- Phase 2 (Slice 3): profile details — bio, interests, prompts, and the
-- hidden matchmaker fields (height, income).
--
-- bio / interests / prompts are optional; height_cm and income_annual are
-- required to finish the wizard (enforced in the app at completion time —
-- the columns stay nullable because the profile is built up step by step).
-- height/income are "hidden" matchmaker fields: only the owner and staff can
-- read them (existing RLS); keeping them from *other* consumers is the
-- Phase 4 discovery projection's job.

alter table public.profiles
    add column bio           text,
    add column height_cm     int,
    add column income_annual int,
    add column interests      text[] not null default '{}',
    add constraint profiles_height_cm_range
        check (height_cm is null or height_cm between 100 and 250),
    add constraint profiles_income_nonneg
        check (income_annual is null or income_annual >= 0);

-- Prompts the user answered (chosen from a preset list in the app). The
-- question text is stored alongside the answer so existing answers survive
-- changes to the preset list.
create table public.profile_prompts (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references public.users(id) on delete cascade,
    prompt      text not null,
    answer      text not null,
    order_index int  not null default 0,
    created_at  timestamptz not null default now()
);

create index profile_prompts_user_order_idx
    on public.profile_prompts (user_id, order_index);

alter table public.profile_prompts enable row level security;

create policy profile_prompts_select_own
    on public.profile_prompts for select to authenticated
    using (auth.uid() = user_id);

create policy profile_prompts_insert_own
    on public.profile_prompts for insert to authenticated
    with check (auth.uid() = user_id);

create policy profile_prompts_update_own
    on public.profile_prompts for update to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

create policy profile_prompts_delete_own
    on public.profile_prompts for delete to authenticated
    using (auth.uid() = user_id);

create policy profile_prompts_select_all_for_staff
    on public.profile_prompts for select to authenticated
    using (public.is_matchmaker_or_admin());
