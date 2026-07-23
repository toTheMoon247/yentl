-- Phase 11 Slice 2: account data rights (GDPR / App Store 5.1.1).
--
-- export_my_data(): the signed-in user's own data as one JSON document, for
-- the consumer "Download my data" flow. Owner-only (keys off auth.uid());
-- there is no argument, so a user can only ever export themselves.
--
-- Account DELETION is not here — it must remove the auth.users row and the
-- Storage photos too, which needs the service role, so it lives in the
-- `delete-account` Edge Function. (public.users has no FK to auth.users, so
-- deleting the app row and the auth row are two separate steps; deleting the
-- public.users row cascades every app table — see the FK map.)

create or replace function public.export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
    uid    uuid := auth.uid();
    result jsonb;
begin
    if uid is null then
        raise exception 'not authenticated';
    end if;

    select jsonb_build_object(
        'exported_at', now(),
        'user_id', uid,
        'account', (
            select to_jsonb(u) from public.users u where u.id = uid
        ),
        'profile', (
            select to_jsonb(p) from public.profiles p where p.id = uid
        ),
        'photos', (
            select coalesce(jsonb_agg(to_jsonb(ph) order by ph.created_at), '[]'::jsonb)
            from public.profile_photos ph where ph.user_id = uid
        ),
        'prompts', (
            select coalesce(jsonb_agg(to_jsonb(pr)), '[]'::jsonb)
            from public.profile_prompts pr where pr.user_id = uid
        ),
        'matches', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'id', m.id, 'state', m.state, 'created_at', m.created_at)), '[]'::jsonb)
            from public.matches m where m.user_a = uid or m.user_b = uid
        ),
        'payments', (
            select coalesce(jsonb_agg(to_jsonb(pay) order by pay.created_at), '[]'::jsonb)
            from public.payments pay where pay.user_id = uid
        ),
        'reports_filed', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'reason', r.reason, 'note', r.note, 'created_at', r.created_at)), '[]'::jsonb)
            from public.reports r where r.reporter_id = uid
        ),
        'blocks_made', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'blocked_id', b.blocked_id, 'created_at', b.created_at)), '[]'::jsonb)
            from public.blocks b where b.blocker_id = uid
        )
    ) into result;

    return result;
end;
$$;

revoke execute on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;
