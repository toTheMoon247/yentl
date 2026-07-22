-- Phase 9 (Slice 1): payments ledger — the per-confirmed-date fee, backend only.
--
-- Model (docs/implementation-plan.md, Phase 9, decided 2026-07-22): each
-- participant of a confirmed match pays their OWN fee via Apple IAP through
-- RevenueCat. RevenueCat validates the purchase with Apple, but its
-- entitlement model cannot represent a per-match consumable, so THIS table is
-- the source of truth for "who has paid for which match". One row = one
-- verified purchase by one user for one match.
--
-- Writes happen ONLY server-side:
--   - `record-payment` Edge Function (service role) inserts a 'paid' row after
--     independently re-verifying the purchase against RevenueCat's REST API —
--     the client's "I paid" claim is never trusted.
--   - `revenuecat-webhook` Edge Function (service role) flips rows to
--     'refunded' on refund/chargeback events (and back on REFUND_REVERSED).
-- Hence NO insert/update/delete RLS policy exists for clients, on purpose.
--
-- `store_transaction_id` is the App Store transaction id as RevenueCat reports
-- it (`store_purchase_identifier` in REST API v2, `transaction_id` in webhook
-- events). It is UNIQUE: the dedup/replay key. A replayed record-payment call
-- or a duplicated webhook delivery finds the existing row instead of
-- double-writing.
--
-- The per-user shape deliberately represents "one paid, the other ghosted":
-- that is simply a match with exactly one 'paid' row. The refund/timeout
-- policy for that case is deferred (Phase 9 checklist), but the data model
-- already captures it.

create table public.payments (
    id                      uuid primary key default gen_random_uuid(),
    user_id                 uuid not null references public.users(id) on delete cascade,
    match_id                uuid not null references public.matches(id) on delete cascade,
    product_id              text,
    store_transaction_id    text not null unique,
    revenuecat_customer_id  text,
    status                  text not null default 'paid'
                                check (status in ('paid', 'refunded')),
    amount_cents            integer,
    currency                text,
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now()
);

comment on table public.payments is
  'Per-match, per-user fee ledger. Rows are written only by the record-payment '
  'and revenuecat-webhook Edge Functions (service role) after RevenueCat '
  'verification; clients can only read their own rows.';
comment on column public.payments.store_transaction_id is
  'App Store transaction id as RevenueCat reports it. UNIQUE — the idempotency '
  'key for both record-payment replays and duplicated webhook deliveries.';

create index payments_match_id_idx on public.payments (match_id);
create index payments_user_id_idx on public.payments (user_id);

-- Keep updated_at fresh (reuses the helper from the users migration).
create trigger payments_updated_at
    before update on public.payments
    for each row execute function public.handle_updated_at();

alter table public.payments enable row level security;

-- A user reads only their own payment rows; staff read all (payment history is
-- a matchmaker-facing feature). No insert/update/delete policies: all writes
-- go through the Edge Functions with the service role, which bypasses RLS.
create policy payments_select_own on public.payments
    for select to authenticated
    using (auth.uid() = user_id);
create policy payments_select_staff on public.payments
    for select to authenticated
    using (public.is_matchmaker_or_admin());

-- Explicit table grants, per 20260721170000: RLS is the gate; grants are
-- mirrored broad so local, CI and production behave identically.
grant select, insert, update, delete on table
    public.payments
to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- is_match_paid(match): true iff BOTH participants of the match have a 'paid'
-- payments row for it. This is the predicate the Phase 9 chat gate will read;
-- a refund flips it back to false because the refunded row no longer counts.
-- Security definer so a participant can evaluate it without needing to see
-- the OTHER participant's payment row (RLS hides it from them).
-- ---------------------------------------------------------------------------
create or replace function public.is_match_paid(match uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
    select exists (
        select 1
        from public.matches m
        where m.id = match
          and exists (select 1 from public.payments p
                       where p.match_id = m.id and p.user_id = m.user_a
                         and p.status = 'paid')
          and exists (select 1 from public.payments p
                       where p.match_id = m.id and p.user_id = m.user_b
                         and p.status = 'paid')
    );
$$;

-- ---------------------------------------------------------------------------
-- payment_history_for_user(target): staff-only payment history for one user,
-- newest first (Phase 9 checklist item "payment history per user"). Mirrors
-- match_history_for_user's staff guard.
-- ---------------------------------------------------------------------------
create or replace function public.payment_history_for_user(target uuid)
returns table (
    payment_id           uuid,
    match_id             uuid,
    product_id           text,
    store_transaction_id text,
    status               text,
    amount_cents         integer,
    currency             text,
    created_at           timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.is_matchmaker_or_admin() then
        raise exception 'not authorized';
    end if;
    return query
    select p.id, p.match_id, p.product_id, p.store_transaction_id,
           p.status, p.amount_cents, p.currency, p.created_at
    from public.payments p
    where p.user_id = target
    order by p.created_at desc;
end;
$$;

revoke execute on function public.is_match_paid(uuid) from public, anon;
revoke execute on function public.payment_history_for_user(uuid) from public, anon;
grant execute on function public.is_match_paid(uuid) to authenticated, service_role;
grant execute on function public.payment_history_for_user(uuid) to authenticated;
