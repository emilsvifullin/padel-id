-- Padel ID — foundation: schemas, helpers, core tables, integrity constraints,
-- indexes and row level security.
--
-- Access model: the public API consists exclusively of RPC functions (see later
-- migrations). Tables are not readable or writable by the `anon` /
-- `authenticated` roles directly: RLS is enabled everywhere with no permissive
-- policies for those roles, and table privileges are revoked as defense in depth.

create extension if not exists pg_trgm with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Normalises free text for search and uniqueness: lower case, ё→е, collapsed
-- whitespace, trimmed.
create or replace function private.norm(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select btrim(regexp_replace(translate(lower(coalesce(p, '')), 'ё', 'е'), '\s+', ' ', 'g'))
$$;

-- JSON type name that treats a missing key (SQL NULL) as 'missing', so that
-- validations of the form `jtype(x) <> 'number'` reject absent fields.
create or replace function private.jtype(p jsonb)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(jsonb_typeof(p), 'missing')
$$;

-- Raises an application error with a machine readable code. The API layer maps
-- codes to HTTP statuses and localized messages.
create or replace function private.fail(p_code text, p_detail text default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = p_code,
    detail = coalesce(p_detail, '');
end;
$$;

-- Returns the authenticated user id or fails.
create or replace function private.require_uid()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v uuid := auth.uid();
begin
  if v is null then
    perform private.fail('not_authenticated');
  end if;
  return v;
end;
$$;

create or replace function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- The six Padel DNA dimensions, in canonical display order.
create or replace function private.dna_dimensions()
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select array['serve_return', 'defense', 'transition_lob', 'net_game', 'overheads', 'consistency_decisions']::text[]
$$;

-- ---------------------------------------------------------------------------
-- Reference data: cities and clubs
-- ---------------------------------------------------------------------------

create table public.cities (
  id integer generated always as identity primary key,
  name text not null check (char_length(name) between 2 and 60),
  country_code text not null check (country_code ~ '^[A-Z]{2}$'),
  sort_order integer not null default 1000,
  name_norm text generated always as (private.norm(name)) stored,
  unique (country_code, name)
);

create table public.profiles (
  id uuid primary key,
  username text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (
    char_length(display_name) between 2 and 40
    and display_name = btrim(display_name)
    and display_name !~ '\s{2,}'
  ),
  name_norm text generated always as (private.norm(display_name)) stored,
  city_id integer references public.cities(id),
  club_id bigint,
  preferred_side text not null default 'both' check (preferred_side in ('left', 'right', 'both')),
  dominant_hand text not null default 'right' check (dominant_hand in ('right', 'left')),
  playing_since smallint check (playing_since between 1970 and 2100),
  bio text check (char_length(bio) <= 160),
  avatar_path text check (avatar_path ~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{8,64}\.jpg$'),
  discoverable boolean not null default true,
  is_coach boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.clubs (
  id bigint generated always as identity primary key,
  city_id integer not null references public.cities(id),
  name text not null check (
    char_length(name) between 2 and 60
    and name = btrim(name)
    and name !~ '\s{2,}'
  ),
  name_norm text generated always as (private.norm(name)) stored,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (city_id, name_norm)
);

alter table public.profiles
  add constraint profiles_club_fk foreign key (club_id) references public.clubs(id) on delete set null;

create index profiles_search_trgm on public.profiles
  using gin ((name_norm || ' ' || username) extensions.gin_trgm_ops)
  where deleted_at is null;
create index profiles_city_idx on public.profiles (city_id) where deleted_at is null;
create index profiles_club_idx on public.profiles (club_id) where deleted_at is null;
create index clubs_created_by_idx on public.clubs (created_by);

create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Rating
-- ---------------------------------------------------------------------------

create table public.player_ratings (
  player_id uuid primary key references public.profiles(id),
  mu double precision not null check (mu between 0 and 7),
  sigma double precision not null check (sigma > 0 and sigma <= 2),
  ranked_matches integer not null default 0 check (ranked_matches >= 0),
  ranked_wins integer not null default 0 check (ranked_wins >= 0 and ranked_wins <= ranked_matches),
  peak_mu double precision not null check (peak_mu between 0 and 7),
  calibration jsonb not null,
  last_ranked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger player_ratings_touch before update on public.player_ratings
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Matches
-- ---------------------------------------------------------------------------

create table public.matches (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references public.profiles(id),
  match_type text not null check (match_type in ('friendly', 'ranked')),
  format text not null check (format in ('best_of_3', 'best_of_3_super_tiebreak', 'single_set')),
  status text not null default 'pending'
    check (status in ('pending', 'disputed', 'confirmed', 'cancelled', 'expired')),
  played_at timestamptz not null,
  club_id bigint references public.clubs(id) on delete set null,
  score jsonb not null check (jsonb_typeof(score) = 'array'),
  winner_team smallint not null check (winner_team in (1, 2)),
  team1_sets smallint not null check (team1_sets >= 0),
  team2_sets smallint not null check (team2_sets >= 0),
  team1_games smallint not null check (team1_games >= 0),
  team2_games smallint not null check (team2_games >= 0),
  version integer not null default 1 check (version >= 1),
  idempotency_key uuid not null,
  last_edit_key uuid,
  confirmed_at timestamptz,
  rating_applied boolean not null default false,
  rating_weight double precision check (rating_weight > 0 and rating_weight <= 1),
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (created_by, idempotency_key),
  check ((status = 'confirmed') = (confirmed_at is not null)),
  check (status in ('cancelled', 'expired') = (closed_at is not null)),
  check (not rating_applied or (status = 'confirmed' and match_type = 'ranked')),
  check ((winner_team = 1 and team1_sets > team2_sets) or (winner_team = 2 and team2_sets > team1_sets))
);

create index matches_open_idx on public.matches (updated_at) where status in ('pending', 'disputed');
create index matches_created_by_idx on public.matches (created_by, created_at desc);
create index matches_club_idx on public.matches (club_id);

create trigger matches_touch before update on public.matches
  for each row execute function private.touch_updated_at();

create table public.match_players (
  match_id uuid not null references public.matches(id) on delete cascade,
  player_id uuid not null references public.profiles(id),
  team smallint not null check (team in (1, 2)),
  court_side text not null check (court_side in ('left', 'right')),
  response text not null default 'pending' check (response in ('pending', 'confirmed', 'disputed')),
  responded_at timestamptz,
  dispute_reason text check (dispute_reason in ('wrong_score', 'wrong_players', 'wrong_type', 'not_played', 'other')),
  dispute_comment text check (char_length(dispute_comment) <= 140),
  primary key (match_id, player_id),
  unique (match_id, team, court_side),
  check ((response = 'pending') = (responded_at is null)),
  check ((response = 'disputed') = (dispute_reason is not null)),
  check (dispute_reason is not null or dispute_comment is null)
);

create index match_players_player_idx on public.match_players (player_id, match_id);

-- Every match must have exactly four distinct players, two per team, at commit.
-- SECURITY DEFINER: deferred triggers fire at COMMIT under the caller's role
-- (`authenticated` via the API), which has no direct table access.
create or replace function private.check_match_lineup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match uuid;
  v_total integer;
  v_team1 integer;
begin
  if tg_table_name = 'matches' then
    v_match := case when tg_op = 'DELETE' then old.id else new.id end;
  else
    v_match := case when tg_op = 'DELETE' then old.match_id else new.match_id end;
  end if;
  if not exists (select 1 from public.matches where id = v_match) then
    return null;
  end if;
  select count(*), count(*) filter (where team = 1)
    into v_total, v_team1
    from public.match_players
   where match_id = v_match;
  if v_total <> 4 or v_team1 <> 2 then
    raise exception using errcode = '23514', message = 'match_lineup_invalid',
      detail = format('match %s has %s players (%s in team 1)', v_match, v_total, v_team1);
  end if;
  return null;
end;
$$;

create constraint trigger matches_lineup_check
  after insert or update on public.matches
  deferrable initially deferred
  for each row execute function private.check_match_lineup();

create constraint trigger match_players_lineup_check
  after insert or update or delete on public.match_players
  deferrable initially deferred
  for each row execute function private.check_match_lineup();

create table public.rating_events (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.profiles(id),
  match_id uuid references public.matches(id),
  kind text not null check (kind in ('calibration', 'match')),
  mu_before double precision,
  sigma_before double precision,
  mu_after double precision not null check (mu_after between 0 and 7),
  sigma_after double precision not null check (sigma_after > 0),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (player_id, match_id),
  check ((kind = 'match') = (match_id is not null))
);

create index rating_events_player_time_idx on public.rating_events (player_id, created_at desc);
create index rating_events_match_idx on public.rating_events (match_id);

-- ---------------------------------------------------------------------------
-- Padel DNA inputs and derived state
-- ---------------------------------------------------------------------------

create table public.match_feedback (
  match_id uuid not null references public.matches(id) on delete cascade,
  rater_id uuid not null references public.profiles(id),
  ratee_id uuid not null references public.profiles(id),
  strengths text[] not null default '{}',
  improvements text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (match_id, rater_id, ratee_id),
  check (rater_id <> ratee_id),
  check (cardinality(strengths) <= 2 and cardinality(improvements) <= 1),
  check (cardinality(strengths) + cardinality(improvements) >= 1),
  check (strengths <@ private.dna_dimensions() and improvements <@ private.dna_dimensions()),
  check (not (strengths && improvements))
);

create index match_feedback_ratee_idx on public.match_feedback (ratee_id);
create index match_feedback_rater_idx on public.match_feedback (rater_id);

create trigger match_feedback_touch before update on public.match_feedback
  for each row execute function private.touch_updated_at();

create table public.dna_self_assessments (
  player_id uuid primary key references public.profiles(id),
  answers jsonb not null check (jsonb_typeof(answers) = 'object'),
  updated_at timestamptz not null default now()
);

create table public.coach_applications (
  player_id uuid primary key references public.profiles(id),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'revoked')),
  experience_years smallint not null check (experience_years between 0 and 60),
  certification text check (char_length(certification) <= 120),
  about text not null check (char_length(about) between 20 and 500),
  club_id bigint references public.clubs(id) on delete set null,
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  review_note text check (char_length(review_note) <= 300)
);

create index coach_applications_status_idx on public.coach_applications (status, submitted_at);
create index coach_applications_club_idx on public.coach_applications (club_id);
create index coach_applications_reviewer_idx on public.coach_applications (reviewed_by);

create table public.coach_assessments (
  id uuid primary key default gen_random_uuid(),
  coach_id uuid not null references public.profiles(id),
  player_id uuid not null references public.profiles(id),
  scores jsonb not null check (jsonb_typeof(scores) = 'object'),
  player_mu_at double precision not null,
  note text check (char_length(note) <= 500),
  created_at timestamptz not null default now(),
  check (coach_id <> player_id)
);

create index coach_assessments_player_idx on public.coach_assessments (player_id, created_at desc);
create index coach_assessments_coach_idx on public.coach_assessments (coach_id, created_at desc);

create table public.player_dna (
  player_id uuid not null references public.profiles(id),
  dimension text not null check (dimension = any (private.dna_dimensions())),
  offset_mean double precision not null,
  offset_var double precision not null check (offset_var > 0),
  peer_signals integer not null default 0,
  coach_signals integer not null default 0,
  self_signal boolean not null default false,
  match_signal boolean not null default false,
  coach_verified_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (player_id, dimension)
);

create table public.player_dna_history (
  player_id uuid not null references public.profiles(id),
  dimension text not null check (dimension = any (private.dna_dimensions())),
  day date not null,
  offset_mean double precision not null,
  offset_var double precision not null,
  level double precision not null,
  primary key (player_id, dimension, day)
);

-- ---------------------------------------------------------------------------
-- Private operational tables
-- ---------------------------------------------------------------------------

create table private.admins (
  user_id uuid primary key,
  created_at timestamptz not null default now()
);

create table private.recovery_keys (
  user_id uuid primary key,
  key_hash bytea not null,
  created_at timestamptz not null default now()
);

create table private.rate_limits (
  bucket text not null,
  window_start timestamptz not null,
  hits integer not null default 0,
  primary key (bucket, window_start)
);

create table private.bff_secret (
  id boolean primary key default true check (id),
  secret_hash bytea not null,
  rotated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Row level security & privileges
-- ---------------------------------------------------------------------------

alter table public.cities enable row level security;
alter table public.clubs enable row level security;
alter table public.profiles enable row level security;
alter table public.player_ratings enable row level security;
alter table public.matches enable row level security;
alter table public.match_players enable row level security;
alter table public.rating_events enable row level security;
alter table public.match_feedback enable row level security;
alter table public.dna_self_assessments enable row level security;
alter table public.coach_applications enable row level security;
alter table public.coach_assessments enable row level security;
alter table public.player_dna enable row level security;
alter table public.player_dna_history enable row level security;
alter table private.admins enable row level security;
alter table private.recovery_keys enable row level security;
alter table private.rate_limits enable row level security;
alter table private.bff_secret enable row level security;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all tables in schema private from anon, authenticated, public;

-- ---------------------------------------------------------------------------
-- Reference cities (real places where padel is played by Padel ID's audience)
-- ---------------------------------------------------------------------------

insert into public.cities (name, country_code, sort_order) values
  ('Москва', 'RU', 1),
  ('Санкт-Петербург', 'RU', 2);

insert into public.cities (name, country_code) values
  ('Новосибирск', 'RU'), ('Екатеринбург', 'RU'), ('Казань', 'RU'), ('Нижний Новгород', 'RU'),
  ('Красноярск', 'RU'), ('Челябинск', 'RU'), ('Самара', 'RU'), ('Уфа', 'RU'),
  ('Ростов-на-Дону', 'RU'), ('Краснодар', 'RU'), ('Омск', 'RU'), ('Воронеж', 'RU'),
  ('Пермь', 'RU'), ('Волгоград', 'RU'), ('Саратов', 'RU'), ('Тюмень', 'RU'),
  ('Тольятти', 'RU'), ('Барнаул', 'RU'), ('Махачкала', 'RU'), ('Ижевск', 'RU'),
  ('Хабаровск', 'RU'), ('Ульяновск', 'RU'), ('Иркутск', 'RU'), ('Владивосток', 'RU'),
  ('Ярославль', 'RU'), ('Севастополь', 'RU'), ('Ставрополь', 'RU'), ('Томск', 'RU'),
  ('Кемерово', 'RU'), ('Набережные Челны', 'RU'), ('Оренбург', 'RU'), ('Новокузнецк', 'RU'),
  ('Балашиха', 'RU'), ('Рязань', 'RU'), ('Чебоксары', 'RU'), ('Калининград', 'RU'),
  ('Пенза', 'RU'), ('Липецк', 'RU'), ('Киров', 'RU'), ('Астрахань', 'RU'),
  ('Тула', 'RU'), ('Улан-Удэ', 'RU'), ('Сургут', 'RU'), ('Курск', 'RU'),
  ('Тверь', 'RU'), ('Магнитогорск', 'RU'), ('Брянск', 'RU'), ('Якутск', 'RU'),
  ('Иваново', 'RU'), ('Владимир', 'RU'), ('Симферополь', 'RU'), ('Белгород', 'RU'),
  ('Нижний Тагил', 'RU'), ('Калуга', 'RU'), ('Чита', 'RU'), ('Грозный', 'RU'),
  ('Волжский', 'RU'), ('Смоленск', 'RU'), ('Подольск', 'RU'), ('Сочи', 'RU'),
  ('Вологда', 'RU'), ('Мурманск', 'RU'), ('Архангельск', 'RU'), ('Новороссийск', 'RU'),
  ('Ханты-Мансийск', 'RU'), ('Петрозаводск', 'RU'), ('Великий Новгород', 'RU'), ('Псков', 'RU'),
  ('Кострома', 'RU'), ('Мытищи', 'RU'), ('Химки', 'RU'), ('Красногорск', 'RU'),
  ('Одинцово', 'RU'), ('Королёв', 'RU'), ('Люберцы', 'RU'), ('Домодедово', 'RU'),
  ('Реутов', 'RU'), ('Обнинск', 'RU'), ('Анапа', 'RU'), ('Геленджик', 'RU'),
  ('Пятигорск', 'RU'), ('Кисловодск', 'RU'), ('Ессентуки', 'RU'), ('Нальчик', 'RU'),
  ('Владикавказ', 'RU'), ('Майкоп', 'RU'), ('Южно-Сахалинск', 'RU'), ('Петропавловск-Камчатский', 'RU'),
  ('Норильск', 'RU'), ('Сыктывкар', 'RU'), ('Йошкар-Ола', 'RU'), ('Саранск', 'RU'),
  ('Тамбов', 'RU'), ('Орёл', 'RU'), ('Абакан', 'RU'), ('Благовещенск', 'RU'),
  ('Нижневартовск', 'RU'), ('Новый Уренгой', 'RU'), ('Магадан', 'RU'), ('Евпатория', 'RU'),
  ('Ялта', 'RU'),
  ('Минск', 'BY'), ('Брест', 'BY'), ('Гомель', 'BY'),
  ('Алматы', 'KZ'), ('Астана', 'KZ'), ('Шымкент', 'KZ'), ('Атырау', 'KZ'),
  ('Ташкент', 'UZ'), ('Самарканд', 'UZ'),
  ('Бишкек', 'KG'), ('Душанбе', 'TJ'),
  ('Ереван', 'AM'), ('Тбилиси', 'GE'), ('Батуми', 'GE'), ('Баку', 'AZ'),
  ('Рига', 'LV'), ('Таллин', 'EE'), ('Вильнюс', 'LT'),
  ('Дубай', 'AE'), ('Абу-Даби', 'AE'), ('Доха', 'QA'),
  ('Стамбул', 'TR'), ('Анталья', 'TR'),
  ('Лимасол', 'CY'), ('Ларнака', 'CY'), ('Пафос', 'CY'),
  ('Мадрид', 'ES'), ('Барселона', 'ES'), ('Валенсия', 'ES'), ('Малага', 'ES'),
  ('Марбелья', 'ES'), ('Севилья', 'ES'), ('Аликанте', 'ES'), ('Пальма', 'ES'),
  ('Рим', 'IT'), ('Милан', 'IT'), ('Лиссабон', 'PT'), ('Порту', 'PT'),
  ('Париж', 'FR'), ('Лондон', 'GB'), ('Берлин', 'DE'), ('Мюнхен', 'DE'),
  ('Стокгольм', 'SE'), ('Гётеборг', 'SE'), ('Мальмё', 'SE'),
  ('Амстердам', 'NL'), ('Брюссель', 'BE'), ('Хельсинки', 'FI'), ('Копенгаген', 'DK'),
  ('Белград', 'RS'), ('Будва', 'ME'), ('Подгорица', 'ME'),
  ('Буэнос-Айрес', 'AR'), ('Мехико', 'MX'), ('Майами', 'US'),
  ('Бангкок', 'TH'), ('Пхукет', 'TH'), ('Денпасар', 'ID');
