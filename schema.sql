-- MERÅKER CASINO v2 — run once in Supabase SQL Editor.
-- IMPORTANT: Set the admin email at the bottom of this file BEFORE running.
create extension if not exists pgcrypto;
create table if not exists public.players (
 id uuid primary key default gen_random_uuid(), email text not null unique, display_name text not null,
 role text not null default 'player' check(role in ('player','admin')),
 team text check(team in ('A','B','C')), user_id uuid unique references auth.users(id) on delete set null,
 created_at timestamptz not null default now()
);
create table if not exists public.game_settings (
 id integer primary key default 1 check(id=1), revealed boolean not null default false,
 reveal_count integer not null default 0 check(reveal_count between 0 and 9),
 created_at timestamptz not null default now()
);
insert into public.game_settings(id) values(1) on conflict do nothing;
create table if not exists public.ledger (
 id bigint generated always as identity primary key, from_player uuid references public.players(id),
 to_player uuid references public.players(id), amount integer not null check(amount>0),
 reason text not null, created_at timestamptz not null default now(),
 check (from_player is distinct from to_player)
);
-- null means bank. Exactly one of from/to can be null; the other must be a player.
create table if not exists public.bids (
 id uuid primary key default gen_random_uuid(), player_id uuid not null references public.players(id),
 auction text not null, amount integer not null check(amount>0), created_at timestamptz not null default now(),
 unique(player_id,auction)
);
create table if not exists public.contracts (
 id uuid primary key default gen_random_uuid(), proposer uuid not null references public.players(id),
 counterparty uuid not null references public.players(id), terms text not null,
 status text not null default 'proposed' check(status in ('proposed','accepted','rejected','settled','broken')),
 created_at timestamptz not null default now(), check(proposer<>counterparty)
);
create table if not exists public.dilemmas (
 id uuid primary key default gen_random_uuid(), title text not null, status text not null default 'open' check(status in ('open','closed','settled')),
 created_at timestamptz not null default now()
);
create table if not exists public.dilemma_members (
 dilemma_id uuid not null references public.dilemmas(id) on delete cascade,
 player_id uuid not null references public.players(id), choice text check(choice in ('samarbeid','svik')),
 primary key(dilemma_id,player_id)
);
create table if not exists public.schedule_done (
 event_key text primary key, completed boolean not null default true
);

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.players where user_id=auth.uid() and role='admin')
$$;
create or replace function public.my_player_id() returns uuid language sql stable security definer set search_path=public as $$
 select id from public.players where user_id=auth.uid() limit 1
$$;
create or replace function public.claim_account() returns void language plpgsql security definer set search_path=public as $$
declare v_email text; v_id uuid;
begin
 if auth.uid() is null then raise exception 'Not signed in'; end if;
 select lower(email) into v_email from auth.users where id=auth.uid();
 if v_email is null then raise exception 'Email missing'; end if;
 select id into v_id from public.players where lower(email)=v_email;
 if v_id is null then raise exception 'E-postadressen er ikke invitert til spillet'; end if;
 update public.players set user_id=auth.uid() where id=v_id and (user_id is null or user_id=auth.uid());
 if not found then raise exception 'Denne spilleren er allerede knyttet til en annen konto'; end if;
end $$;
create or replace function public.admin_add_player(p_email text,p_name text,p_role text default 'player',p_team text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
 if not public.is_admin() then raise exception 'Kun administrator'; end if;
 if p_role not in ('admin','player') then raise exception 'Invalid role'; end if;
 if p_team is not null and p_team not in ('A','B','C') then raise exception 'Invalid team'; end if;
 if trim(p_name)='' or position('@' in p_email)=0 then raise exception 'Ugyldig navn eller e-post'; end if;
 insert into public.players(email,display_name,role,team) values(lower(trim(p_email)),trim(p_name),p_role,p_team) returning id into v_id;
 if p_role='player' then
  insert into public.ledger(from_player,to_player,amount,reason) values(null,v_id,50,'Startkapital');
 end if;
 return v_id;
end $$;
create or replace function public.player_balance(p_id uuid) returns integer language sql stable security definer set search_path=public as $$
 select  coalesce((select sum(amount) from public.ledger where to_player=p_id),0)::integer -
 coalesce((select sum(amount) from public.ledger where from_player=p_id),0)::integer
$$;
create or replace function public.bank_balance() returns integer language sql stable security definer set search_path=public as $$
 select 1500 - coalesce((select sum(amount) from public.ledger where from_player is null),0)::integer +
 coalesce((select sum(amount) from public.ledger where to_player is null),0)::integer
$$;
create or replace function public.admin_transfer(p_from uuid,p_to uuid,p_amount integer,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'Kun administrator'; end if;
 if p_amount is null or p_amount<=0 or p_from is not distinct from p_to then raise exception 'Ugyldig overføring'; end if;
 perform pg_advisory_xact_lock(884291);
 if p_from is null then
  if public.bank_balance()<p_amount then raise exception 'Banken har ikke nok sedler'; end if;
 elsif public.player_balance(p_from)<p_amount then raise exception 'Avsender har ikke nok sedler'; end if;
 if p_to is not null and not exists(select 1 from public.players where id=p_to) then raise exception 'Ukjent mottaker'; end if;
 insert into public.ledger(from_player,to_player,amount,reason) values(p_from,p_to,p_amount,left(coalesce(nullif(trim(p_reason),''),'Overføring'),250));
end $$;
create or replace function public.submit_bid(p_auction text,p_amount integer)
returns void language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
 v_id:=public.my_player_id();
 if v_id is null then raise exception 'Ikke registrert'; end if;
 if (select revealed from public.game_settings where id=1) then raise exception 'Hemmelig auksjon er stengt'; end if;
 if p_amount<=0 or p_amount>public.player_balance(v_id) then raise exception 'Ugyldig bud eller manglende dekning'; end if;
 insert into public.bids(player_id,auction,amount) values(v_id,left(trim(p_auction),100),p_amount)
 on conflict(player_id,auction) do update set amount=excluded.amount,created_at=now();
end $$;
create or replace function public.admin_settle_auction(p_auction text)
returns text language plpgsql security definer set search_path=public as $$
declare v_bid public.bids%rowtype; v_name text;
begin
 if not public.is_admin() then raise exception 'Kun administrator'; end if;
 perform pg_advisory_xact_lock(884291);
 select * into v_bid from public.bids where auction=p_auction order by amount desc,created_at asc limit 1;
 if v_bid.id is null then raise exception 'Ingen bud'; end if;
 if public.player_balance(v_bid.player_id)<v_bid.amount then raise exception 'Vinneren mangler dekning'; end if;
 insert into public.ledger(from_player,to_player,amount,reason) values(v_bid.player_id,null,v_bid.amount,'Auksjon: '||p_auction);
 select display_name into v_name from public.players where id=v_bid.player_id;
 delete from public.bids where auction=p_auction;
 return v_name||' vant for '||v_bid.amount||' sedler';
end $$;
create or replace function public.propose_contract(p_other uuid,p_terms text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if public.my_player_id() is null or p_other=public.my_player_id() or length(trim(p_terms))<3 then raise exception 'Ugyldig avtale'; end if;
 if not exists(select 1 from public.players where id=p_other and role='player') then raise exception 'Ukjent motpart'; end if;
 insert into public.contracts(proposer,counterparty,terms) values(public.my_player_id(),p_other,left(trim(p_terms),500));
end $$;
create or replace function public.respond_contract(p_id uuid,p_accept boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
 update public.contracts set status=case when p_accept then 'accepted' else 'rejected' end
 where id=p_id and counterparty=public.my_player_id() and status='proposed';
 if not found then raise exception 'Kan ikke svare på denne avtalen'; end if;
end $$;
create or replace function public.admin_set_contract(p_id uuid,p_status text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() or p_status not in ('settled','broken','rejected') then raise exception 'Ikke tillatt'; end if;
 update public.contracts set status=p_status where id=p_id;
end $$;
create or replace function public.admin_create_dilemma(p_title text,p_members uuid[])
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_member uuid;
begin
 if not public.is_admin() then raise exception 'Kun administrator'; end if;
 if array_length(p_members,1) not in (2,3) or (select count(distinct x) from unnest(p_members) x)<>array_length(p_members,1) then raise exception 'Velg 2 eller 3 forskjellige spillere'; end if;
 insert into public.dilemmas(title) values(left(trim(p_title),100)) returning id into v_id;
 foreach v_member in array p_members loop
  if not exists(select 1 from public.players where id=v_member and role='player') then raise exception 'Ukjent spiller'; end if;
  insert into public.dilemma_members(dilemma_id,player_id) values(v_id,v_member);
 end loop;
 return v_id;
end $$;
create or replace function public.submit_choice(p_dilemma uuid,p_choice text)
returns void language plpgsql security definer set search_path=public as $$
begin
 if p_choice not in ('samarbeid','svik') then raise exception 'Ugyldig valg'; end if;
 update public.dilemma_members set choice=p_choice where dilemma_id=p_dilemma and player_id=public.my_player_id()
 and exists(select 1 from public.dilemmas where id=p_dilemma and status='open');
 if not found then raise exception 'Ikke tilgjengelig'; end if;
end $$;
create or replace function public.admin_settle_dilemma(p_dilemma uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_total int; v_traitors int; v_r record; v_change int;
begin
 if not public.is_admin() then raise exception 'Kun administrator'; end if;
 perform pg_advisory_xact_lock(884291);
 if not exists(select 1 from public.dilemmas where id=p_dilemma and status='open') then raise exception 'Allerede avgjort'; end if;
 select count(*),count(*) filter(where choice='svik') into v_total,v_traitors from public.dilemma_members where dilemma_id=p_dilemma;
 if exists(select 1 from public.dilemma_members where dilemma_id=p_dilemma and choice is null) then raise exception 'Ikke alle har valgt'; end if;
 for v_r in select * from public.dilemma_members where dilemma_id=p_dilemma loop
  if v_total=2 then
   v_change:=case when v_traitors=0 then 10 when v_traitors=2 then -5 when v_r.choice='svik' then 20 else -10 end;
  else
   v_change:=case when v_traitors=0 then 10 when v_traitors=3 then -5 when v_r.choice='svik' then 15 else -10 end;
  end if;
  if v_change<0 and public.player_balance(v_r.player_id)<abs(v_change) then raise exception 'En deltaker mangler dekning'; end if;
  if v_change>0 and public.bank_balance()<v_change then raise exception 'Banken mangler dekning'; end if;
  insert into public.ledger(from_player,to_player,amount,reason)
  values(case when v_change<0 then v_r.player_id else null end,case when v_change>0 then v_r.player_id else null end,abs(v_change),'Fangens dilemma');
 end loop;
 update public.dilemmas set status='settled' where id=p_dilemma;
end $$;
create or replace function public.admin_reveal(p_count integer) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() or p_count<0 or p_count>9 then raise exception 'Ikke tillatt'; end if;
 update public.game_settings set revealed=(p_count>0),reveal_count=p_count where id=1;
end $$;
create or replace function public.admin_set_event(p_key text,p_done boolean) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'Kun administrator'; end if;
 insert into public.schedule_done(event_key,completed) values(left(p_key,120),p_done) on conflict(event_key) do update set completed=excluded.completed;
end $$;

alter table public.players enable row level security;
alter table public.game_settings enable row level security;
alter table public.ledger enable row level security;
alter table public.bids enable row level security;
alter table public.contracts enable row level security;
alter table public.dilemmas enable row level security;
alter table public.dilemma_members enable row level security;
alter table public.schedule_done enable row level security;
create policy "players limited visibility" on public.players for select to authenticated using (id=public.my_player_id() or public.is_admin());
create policy "settings read" on public.game_settings for select to authenticated using (true);
create policy "ledger admin or own" on public.ledger for select to authenticated using (public.is_admin() or from_player=public.my_player_id() or to_player=public.my_player_id());
create policy "bids admin or own" on public.bids for select to authenticated using (public.is_admin() or player_id=public.my_player_id());
create policy "contracts parties or admin" on public.contracts for select to authenticated using (public.is_admin() or proposer=public.my_player_id() or counterparty=public.my_player_id());
create policy "dilemmas visible" on public.dilemmas for select to authenticated using (public.is_admin() or exists(select 1 from public.dilemma_members m where m.dilemma_id=id and m.player_id=public.my_player_id()));
create policy "dilemma members own or admin" on public.dilemma_members for select to authenticated using (public.is_admin() or player_id=public.my_player_id());
create policy "schedule read" on public.schedule_done for select to authenticated using (true);
-- Revoke default RPC access from anon. Authenticated users may invoke; each function checks authorization.
revoke execute on function public.is_admin() from anon;
revoke execute on function public.my_player_id() from anon;
revoke execute on function public.claim_account() from anon;
revoke execute on function public.admin_add_player(text,text,text,text) from anon;
revoke execute on function public.player_balance(uuid) from public,anon;
revoke execute on function public.bank_balance() from public,anon;
revoke execute on function public.admin_transfer(uuid,uuid,integer,text) from anon;
revoke execute on function public.submit_bid(text,integer) from anon;
revoke execute on function public.admin_settle_auction(text) from anon;
revoke execute on function public.propose_contract(uuid,text) from anon;
revoke execute on function public.respond_contract(uuid,boolean) from anon;
revoke execute on function public.admin_set_contract(uuid,text) from anon;
revoke execute on function public.admin_create_dilemma(text,uuid[]) from anon;
revoke execute on function public.submit_choice(uuid,text) from anon;
revoke execute on function public.admin_settle_dilemma(uuid) from anon;
revoke execute on function public.admin_reveal(integer) from anon;
revoke execute on function public.admin_set_event(text,boolean) from anon;
-- SECURITY: player_balance() and bank_balance() are security definer, so restrict their callers.
create or replace function public.player_balance(p_id uuid) returns integer language plpgsql stable security definer set search_path=public as $$
begin
 if not public.is_admin() and p_id is distinct from public.my_player_id() then raise exception 'Ingen tilgang til annen saldo'; end if;
 return (select coalesce(sum(case when to_player=p_id then amount when from_player=p_id then -amount else 0 end),0)::integer from public.ledger where from_player=p_id or to_player=p_id);
end $$;
create or replace function public.bank_balance() returns integer language plpgsql stable security definer set search_path=public as $$
begin
 if not public.is_admin() then raise exception 'Kun administrator'; end if;
 return 1500-(select coalesce(sum(case when from_player is null then amount when to_player is null then -amount else 0 end),0)::integer from public.ledger where from_player is null or to_player is null);
end $$;
-- Internal admin_transfer/admin_settle_* call the guarded balance functions as admin, so this is safe.
grant execute on function public.player_balance(uuid),public.bank_balance() to authenticated;
-- BOOTSTRAP: REPLACE email below with your own. It must match the email used for login.
insert into public.players(email,display_name,role) values('DIN_EPOST@EKSEMPEL.NO','Banksjef','admin') on conflict(email) do nothing;

-- Public roster reveals only names, IDs and teams; never emails, roles or balances.
create or replace function public.roster() returns table(id uuid,display_name text,team text) language sql stable security definer set search_path=public as $$
 select p.id,p.display_name,p.team from public.players p where p.role='player' and auth.uid() is not null order by p.created_at
$$;
revoke execute on function public.roster() from public,anon;
grant execute on function public.roster() to authenticated;
-- Reveal uses an explicit, restricted RPC, not unrestricted player_balance.
create or replace function public.revealed_rankings() returns table(display_name text,balance integer,place integer)
language plpgsql stable security definer set search_path=public as $$
begin
 if not public.is_admin() and not exists(select 1 from public.game_settings where id=1 and revealed) then raise exception 'Ikke avslørt'; end if;
 return query with balances as (
  select p.display_name, (coalesce(sum(case when l.to_player=p.id then l.amount when l.from_player=p.id then -l.amount else 0 end),0))::integer as bal
  from public.players p left join public.ledger l on l.to_player=p.id or l.from_player=p.id where p.role='player' group by p.id
 ) select ranked.display_name,ranked.bal,ranked.place from (select b.display_name,b.bal, row_number() over(order by b.bal desc,b.display_name)::integer as place from balances b) ranked where public.is_admin() or ranked.place > 9-(select reveal_count from public.game_settings where id=1);
end $$;
revoke execute on function public.revealed_rankings() from public,anon;
grant execute on function public.revealed_rankings() to authenticated;
