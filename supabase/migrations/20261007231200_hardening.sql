-- Hardening after the security advisor review.
--
-- 1. The privileges loop of the API migration touched every function in
--    `public`, including the platform's `rls_auto_enable()` event-trigger
--    function. Event-trigger functions cannot be called through the API, but
--    API roles should hold no privileges on them.
-- 2. Tables are accessed exclusively through SECURITY DEFINER API functions.
--    Explicit restrictive deny-all policies document that intent (RLS is
--    already enabled with no permissive policies, which denies by default).

do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke all on function public.rls_auto_enable() from anon, authenticated;
  end if;
end;
$$;

drop policy if exists "no direct access" on public.cities;
create policy "no direct access" on public.cities as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.clubs;
create policy "no direct access" on public.clubs as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.profiles;
create policy "no direct access" on public.profiles as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.player_ratings;
create policy "no direct access" on public.player_ratings as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.matches;
create policy "no direct access" on public.matches as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.match_players;
create policy "no direct access" on public.match_players as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.rating_events;
create policy "no direct access" on public.rating_events as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.match_feedback;
create policy "no direct access" on public.match_feedback as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.dna_self_assessments;
create policy "no direct access" on public.dna_self_assessments as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.coach_applications;
create policy "no direct access" on public.coach_applications as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.coach_assessments;
create policy "no direct access" on public.coach_assessments as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.player_dna;
create policy "no direct access" on public.player_dna as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on public.player_dna_history;
create policy "no direct access" on public.player_dna_history as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on private.admins;
create policy "no direct access" on private.admins as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on private.recovery_keys;
create policy "no direct access" on private.recovery_keys as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on private.rate_limits;
create policy "no direct access" on private.rate_limits as restrictive for all to anon, authenticated using (false) with check (false);

drop policy if exists "no direct access" on private.bff_secret;
create policy "no direct access" on private.bff_secret as restrictive for all to anon, authenticated using (false) with check (false);
