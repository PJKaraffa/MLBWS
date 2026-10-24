-- World Series Picks: run once in your Supabase SQL Editor.
-- Uses separate ws_ tables; does not modify your football tables.
begin;
create table public.ws_admins(user_id uuid primary key references auth.users(id) on delete cascade);
create table public.ws_profiles(id uuid primary key references auth.users(id) on delete cascade, display_name text not null check(length(display_name) between 1 and 80));
create table public.ws_series(id bigint generated always as identity primary key, season integer not null unique, team_a text not null check(length(team_a) between 1 and 60),team_b text not null check(length(team_b) between 1 and 60),check(team_a<>team_b));
create table public.ws_games(id bigint generated always as identity primary key,series_id bigint not null references public.ws_series(id),game_no integer not null check(game_no between 1 and 7), starts_at timestamptz,score_a integer check(score_a between 0 and 999),score_b integer check(score_b between 0 and 999),unique(series_id,game_no),check((score_a is null and score_b is null) or (score_a is not null and score_b is not null and score_a<>score_b)));
create table public.ws_picks(user_id uuid not null references public.ws_profiles(id) on delete cascade,game_id bigint not null references public.ws_games(id),winner text not null check(winner in ('a','b')),score_a integer not null check(score_a between 0 and 99),score_b integer not null check(score_b between 0 and 99),updated_at timestamptz not null default now(),primary key(user_id,game_id),check((winner='a' and score_a>score_b) or (winner='b' and score_b>score_a)));
create function public.ws_is_admin() returns boolean language sql stable security definer set search_path=public as $$select exists(select 1 from ws_admins where user_id=auth.uid())$$;
create function public.ws_profile_signup() returns trigger language plpgsql security definer set search_path=public as $$begin insert into ws_profiles(id,display_name) values(new.id,left(coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'),''),split_part(new.email,'@',1),'Player'),80)); return new; end$$;
create trigger ws_signup after insert on auth.users for each row execute function public.ws_profile_signup();
insert into ws_profiles select id,left(coalesce(nullif(trim(raw_user_meta_data->>'display_name'),''),split_part(email,'@',1),'Player'),80) from auth.users on conflict do nothing;
-- New seasons and their seven games are created from the Admin screen.
create function public.ws_create_series(p_season integer,p_a text,p_b text) returns void language plpgsql security definer set search_path=public as $$declare sid bigint;begin
if not ws_is_admin() then raise exception 'Administrator access required';end if;
if p_season not between 1900 and 2200 then raise exception 'Enter a valid season';end if;
insert into ws_series(season,team_a,team_b) values(p_season,trim(p_a),trim(p_b)) returning id into sid;
insert into ws_games(series_id,game_no) select sid,generate_series(1,7);end$$;
create function public.ws_save_pick(p_game bigint,p_winner text,p_a integer,p_b integer) returns void language plpgsql security definer set search_path=public as $$declare g ws_games; sid bigint; wa integer; wb integer;begin
if auth.uid() is null then raise exception 'Sign in first';end if;
select series_id into sid from ws_games where id=p_game;
perform 1 from ws_series where id=sid for share;
select * into g from ws_games where id=p_game for update;
if g.id is null then raise exception 'Game not found';end if;
select count(*) filter(where score_a>score_b),count(*) filter(where score_b>score_a) into wa,wb from ws_games where series_id=sid;
if wa>=4 or wb>=4 then raise exception 'The series is complete';end if;
if g.starts_at is null then raise exception 'Game time has not been set';end if;
if clock_timestamp()>=g.starts_at or g.score_a is not null then raise exception 'Picks are locked';end if;
insert into ws_profiles values(auth.uid(),coalesce(nullif(left(trim(auth.jwt()->'user_metadata'->>'display_name'),80),''),'Player')) on conflict do nothing;
insert into ws_picks(user_id,game_id,winner,score_a,score_b) values(auth.uid(),p_game,p_winner,p_a,p_b) on conflict(user_id,game_id) do update set winner=excluded.winner,score_a=excluded.score_a,score_b=excluded.score_b,updated_at=now();end$$;
create function public.ws_set_time(p_game bigint,p_start timestamptz) returns void language plpgsql security definer set search_path=public as $$declare g ws_games;begin
if not ws_is_admin() then raise exception 'Administrator access required';end if;
perform 1 from ws_series where id=(select series_id from ws_games where id=p_game) for update;
select * into g from ws_games where id=p_game for update;
if g.id is null then raise exception 'Game not found';end if;
if g.score_a is not null then raise exception 'Clear the result before changing its time';end if;
-- Prevent reopening exposed picks. Earlier locks are allowed; later changes must remain in the past.
if g.starts_at<=clock_timestamp() and p_start>clock_timestamp() then raise exception 'A locked game cannot be reopened';end if;
if g.starts_at<=clock_timestamp() and p_start is null then raise exception 'A locked game needs a deadline';end if;
update ws_games set starts_at=p_start where id=p_game;end$$;
create function public.ws_set_result(p_game bigint,p_a integer,p_b integer) returns void language plpgsql security definer set search_path=public as $$declare g ws_games;wa integer;wb integer;begin
if not ws_is_admin() then raise exception 'Administrator access required';end if;
perform 1 from ws_series where id=(select series_id from ws_games where id=p_game) for update;
select * into g from ws_games where id=p_game for update;
if g.id is null then raise exception 'Game not found';end if;
if exists(select 1 from ws_games where series_id=g.series_id and game_no>g.game_no and score_a is not null) then raise exception 'Correct or clear later results first';end if;
if p_a is null and p_b is null then update ws_games set score_a=null,score_b=null where id=p_game;return;end if;
if g.starts_at is null or g.starts_at>clock_timestamp() then raise exception 'Set the game start time to the actual past start before entering a result';end if;
if exists(select 1 from ws_games where series_id=g.series_id and game_no<g.game_no and score_a is null) then raise exception 'Enter earlier game results first';end if;
select count(*) filter(where score_a>score_b),count(*) filter(where score_b>score_a) into wa,wb from ws_games where series_id=g.series_id and game_no<g.game_no;
if wa>=4 or wb>=4 then raise exception 'This game was not played: the series is over';end if;
update ws_games set score_a=p_a,score_b=p_b where id=p_game;end$$;
alter table ws_admins enable row level security;
alter table ws_profiles enable row level security;
alter table ws_series enable row level security;
alter table ws_games enable row level security;
alter table ws_picks enable row level security;
create policy admins_self on ws_admins for select to authenticated using(user_id=auth.uid());
create policy profiles_read on ws_profiles for select to authenticated using(true);
create policy series_read on ws_series for select to authenticated using(true);
create policy games_read on ws_games for select to authenticated using(true);
create policy picks_read on ws_picks for select to authenticated using(user_id=auth.uid() or ws_is_admin() or exists(select 1 from ws_games g where g.id=game_id and g.starts_at<=now()));
revoke all on ws_admins,ws_profiles,ws_series,ws_games,ws_picks from anon,authenticated;
grant select on ws_admins,ws_profiles,ws_series,ws_games,ws_picks to authenticated;
revoke all on function ws_is_admin(),ws_profile_signup(),ws_create_series(integer,text,text),ws_save_pick(bigint,text,integer,integer),ws_set_time(bigint,timestamptz),ws_set_result(bigint,integer,integer) from public,anon;
grant execute on function ws_is_admin(),ws_create_series(integer,text,text),ws_save_pick(bigint,text,integer,integer),ws_set_time(bigint,timestamptz),ws_set_result(bigint,integer,integer) to authenticated;
commit;
-- AFTER creating/signing into your account, promote it by running:
-- insert into public.ws_admins(user_id)
-- select id from auth.users where lower(email)=lower('YOUR_EMAIL_HERE')
-- on conflict do nothing;
