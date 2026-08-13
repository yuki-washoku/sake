-- ============================================================
-- 酒帖 / Supabase セットアップSQL（統合版 2026-08）
--
-- これ1本で最新状態になります。
-- 初めての方も、途中まで実行済みの方も、これを丸ごと実行してください。
-- 何度実行しても壊れません。既にあるデータは消えません。
--
-- 手順：Supabase → 左メニュー SQL Editor → New query →
--       この全文を貼り付け → 右下の Run
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- テーブル ----------
create table if not exists profiles(
  id uuid primary key references auth.users on delete cascade,
  email text,
  name text,
  created_at timestamptz default now()
);

create table if not exists groups(
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid references auth.users,
  created_at timestamptz default now()
);

create table if not exists memberships(
  group_id uuid references groups on delete cascade,
  user_id uuid references auth.users on delete cascade,
  role text not null check (role in ('host','admin','staff','viewer')),
  created_at timestamptz default now(),
  primary key (group_id, user_id)
);

create table if not exists accounts(
  id uuid primary key default gen_random_uuid(),
  group_id uuid references groups on delete cascade,
  name text not null,
  deleted_at timestamptz,
  created_at timestamptz default now()
);

-- 内蔵銘柄の在庫も、独自に追加した銘柄も、この1テーブルで扱う
create table if not exists entries(
  id uuid primary key default gen_random_uuid(),
  group_id uuid references groups on delete cascade,
  account_id uuid references accounts on delete cascade,
  ref text not null,                       -- 内蔵銘柄は 'b12' など。独自銘柄は 'custom'
  custom jsonb,                            -- 独自銘柄の中身
  qty jsonb not null default '{}'::jsonb,  -- {"720":3,"1800":1}
  cost numeric, sell numeric, par int,
  loc text, memo text,
  menu boolean default false,
  photo text,
  photos jsonb default '[]'::jsonb,
  updated_by uuid,
  updated_at timestamptz default now(),
  created_at timestamptz default now(),
  deleted_at timestamptz
);
-- 既存のデータベースに後から追加された列（何度実行しても安全）
alter table entries add column if not exists photos jsonb default '[]'::jsonb;
update entries set photos = jsonb_build_array(photo)
 where photo is not null and (photos is null or jsonb_array_length(photos) = 0);

create index if not exists entries_group_idx on entries(group_id, account_id);
create unique index if not exists entries_ref_uniq
  on entries(account_id, ref) where ref <> 'custom' and deleted_at is null;

create table if not exists invites(
  token text primary key,
  group_id uuid references groups on delete cascade,
  role text not null check (role in ('admin','staff','viewer')),
  note text,
  max_uses int default 1,
  uses int default 0,
  expires_at timestamptz not null,
  created_by uuid,
  created_at timestamptz default now()
);

create table if not exists audit(
  id bigserial primary key,
  group_id uuid,
  account_id uuid,
  actor uuid,
  actor_name text,
  action text,          -- add / set / del / restore / member
  label text,
  entry_id uuid,
  before jsonb,
  after jsonb,
  at timestamptz default now()
);
create index if not exists audit_group_idx on audit(group_id, at desc);

-- ---------- 補助関数 ----------
create or replace function rank_of(r text) returns int
language sql immutable as $$
  select case r when 'host' then 4 when 'admin' then 3 when 'staff' then 2 when 'viewer' then 1 else 0 end
$$;

create or replace function my_groups() returns setof uuid
language sql stable security definer set search_path=public as $$
  select group_id from memberships where user_id = auth.uid()
$$;

create or replace function my_role(g uuid) returns text
language sql stable security definer set search_path=public as $$
  select role from memberships where group_id = g and user_id = auth.uid()
$$;

create or replace function my_name() returns text
language sql stable security definer set search_path=public as $$
  select coalesce(name, email, '不明') from profiles where id = auth.uid()
$$;

-- ---------- 新規ユーザーのプロフィール自動作成 ----------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into profiles(id, email, name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- 権限チェック（従業員の越権を server 側で拒否） ----------
create or replace function entries_guard() returns trigger
language plpgsql security definer set search_path=public as $$
declare r int;
begin
  r := rank_of(my_role(coalesce(new.group_id, old.group_id)));
  if r < 2 then raise exception '権限がありません（閲覧のみ）'; end if;
  if TG_OP = 'UPDATE' and r < 3 then
    if new.cost is distinct from old.cost
      or new.sell is distinct from old.sell
      or new.par  is distinct from old.par
      or new.custom is distinct from old.custom
      or new.menu is distinct from old.menu
      or new.account_id is distinct from old.account_id
      or (new.deleted_at is not null and old.deleted_at is null) then
      raise exception '従業員が変更できるのは在庫数・メモ・保管場所のみです';
    end if;
  end if;
  if TG_OP = 'INSERT' and r < 3 and new.ref = 'custom' then
    raise exception '銘柄の追加は管理以上の権限が必要です';
  end if;
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists t_entries_guard on entries;
create trigger t_entries_guard before insert or update on entries
  for each row execute function entries_guard();

create or replace function accounts_guard() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if rank_of(my_role(coalesce(new.group_id, old.group_id))) < 3 then
    raise exception 'アカウントの操作は管理以上の権限が必要です';
  end if;
  return new;
end $$;
drop trigger if exists t_accounts_guard on accounts;
create trigger t_accounts_guard before insert or update on accounts
  for each row execute function accounts_guard();

-- ---------- 履歴の自動記録 ----------
create or replace function entries_audit() returns trigger
language plpgsql security definer set search_path=public as $$
declare act text;
begin
  if TG_OP = 'INSERT' then act := 'add';
  elsif new.deleted_at is not null and old.deleted_at is null then act := 'del';
  elsif new.deleted_at is null and old.deleted_at is not null then act := 'restore';
  else act := 'set';
  end if;
  insert into audit(group_id, account_id, actor, actor_name, action, label, entry_id, before, after)
  values (new.group_id, new.account_id, auth.uid(), my_name(), act,
          coalesce(new.custom->>'name', new.ref), new.id,
          case when TG_OP='UPDATE' then to_jsonb(old) else null end, to_jsonb(new));
  return null;
end $$;
drop trigger if exists t_entries_audit on entries;
create trigger t_entries_audit after insert or update on entries
  for each row execute function entries_audit();

create or replace function accounts_audit() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into audit(group_id, actor, actor_name, action, label, before, after)
  values (new.group_id, auth.uid(), my_name(),
          case when TG_OP='INSERT' then 'add'
               when new.deleted_at is not null and old.deleted_at is null then 'del'
               else 'set' end,
          'アカウント：' || new.name,
          case when TG_OP='UPDATE' then to_jsonb(old) else null end, to_jsonb(new));
  return null;
end $$;
drop trigger if exists t_accounts_audit on accounts;
create trigger t_accounts_audit after insert or update on accounts
  for each row execute function accounts_audit();

-- ---------- RLS ----------
alter table profiles    enable row level security;
alter table groups      enable row level security;
alter table memberships enable row level security;
alter table accounts    enable row level security;
alter table entries     enable row level security;
alter table invites     enable row level security;
alter table audit       enable row level security;

drop policy if exists p_profiles_sel on profiles;
create policy p_profiles_sel on profiles for select using (
  id = auth.uid() or exists (
    select 1 from memberships m where m.user_id = profiles.id and m.group_id in (select my_groups())
  ));
drop policy if exists p_profiles_upd on profiles;
create policy p_profiles_upd on profiles for update using (id = auth.uid());

drop policy if exists p_groups_sel on groups;
create policy p_groups_sel on groups for select using (id in (select my_groups()));
drop policy if exists p_groups_upd on groups;
create policy p_groups_upd on groups for update using (rank_of(my_role(id)) >= 4);

drop policy if exists p_mem_sel on memberships;
create policy p_mem_sel on memberships for select using (group_id in (select my_groups()));

drop policy if exists p_acc_sel on accounts;
create policy p_acc_sel on accounts for select using (group_id in (select my_groups()));
drop policy if exists p_acc_ins on accounts;
create policy p_acc_ins on accounts for insert with check (rank_of(my_role(group_id)) >= 3);
drop policy if exists p_acc_upd on accounts;
create policy p_acc_upd on accounts for update using (rank_of(my_role(group_id)) >= 3);

drop policy if exists p_ent_sel on entries;
create policy p_ent_sel on entries for select using (group_id in (select my_groups()));
drop policy if exists p_ent_ins on entries;
create policy p_ent_ins on entries for insert with check (rank_of(my_role(group_id)) >= 2);
drop policy if exists p_ent_upd on entries;
create policy p_ent_upd on entries for update using (rank_of(my_role(group_id)) >= 2);

drop policy if exists p_inv_sel on invites;
create policy p_inv_sel on invites for select using (rank_of(my_role(group_id)) >= 3);

drop policy if exists p_audit_sel on audit;
create policy p_audit_sel on audit for select using (group_id in (select my_groups()));

-- ---------- 操作用の関数 ----------
create or replace function create_group(p_name text) returns uuid
language plpgsql security definer set search_path=public as $$
declare g uuid;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  insert into groups(name, created_by) values (coalesce(nullif(p_name,''),'新しいグループ'), auth.uid())
    returning id into g;
  insert into memberships(group_id, user_id, role) values (g, auth.uid(), 'host');
  insert into accounts(group_id, name) values (g, '個人用');
  return g;
end $$;

create or replace function create_invite(p_group uuid, p_role text, p_days int, p_uses int)
returns text language plpgsql security definer set search_path=public as $$
declare t text;
begin
  if rank_of(my_role(p_group)) < 3 then raise exception '招待の発行は管理以上の権限が必要です'; end if;
  if p_role not in ('admin','staff','viewer') then raise exception '権限の指定が不正です'; end if;
  t := replace(gen_random_uuid()::text, '-', '');
  insert into invites(token, group_id, role, max_uses, expires_at, created_by)
  values (t, p_group, p_role, greatest(1, coalesce(p_uses,1)),
          now() + (greatest(1, coalesce(p_days,7)) || ' days')::interval, auth.uid());
  return t;
end $$;

-- ログイン前でもグループ名と権限だけは見せる（token を知っている人だけ）
create or replace function invite_info(p_token text) returns json
language plpgsql security definer set search_path=public as $$
declare i invites%rowtype; gname text;
begin
  select * into i from invites where token = p_token;
  if not found then return json_build_object('ok', false, 'reason', 'notfound'); end if;
  if i.expires_at < now() then return json_build_object('ok', false, 'reason', 'expired'); end if;
  if i.uses >= i.max_uses then return json_build_object('ok', false, 'reason', 'used'); end if;
  select name into gname from groups where id = i.group_id;
  return json_build_object('ok', true, 'group', gname, 'role', i.role);
end $$;

create or replace function accept_invite(p_token text) returns uuid
language plpgsql security definer set search_path=public as $$
declare i invites%rowtype;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into i from invites where token = p_token for update;
  if not found then raise exception '招待リンクが見つかりません'; end if;
  if i.expires_at < now() then raise exception 'この招待リンクは期限切れです'; end if;
  if i.uses >= i.max_uses then raise exception 'この招待リンクは使用済みです'; end if;
  if exists (select 1 from memberships where group_id = i.group_id and user_id = auth.uid()) then
    return i.group_id;
  end if;
  insert into memberships(group_id, user_id, role) values (i.group_id, auth.uid(), i.role);
  update invites set uses = uses + 1 where token = p_token;
  insert into audit(group_id, actor, actor_name, action, label)
  values (i.group_id, auth.uid(), my_name(), 'member', my_name() || ' が招待から参加（' || i.role || '）');
  return i.group_id;
end $$;

create or replace function set_member_role(p_group uuid, p_user uuid, p_role text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if rank_of(my_role(p_group)) < 4 then raise exception '権限の変更はホストのみ可能です'; end if;
  if p_role not in ('host','admin','staff','viewer') then raise exception '権限の指定が不正です'; end if;
  if p_user = auth.uid() and p_role <> 'host' then raise exception '自分自身のホスト権限は外せません'; end if;
  update memberships set role = p_role where group_id = p_group and user_id = p_user;
  insert into audit(group_id, actor, actor_name, action, label)
  values (p_group, auth.uid(), my_name(), 'member',
          (select coalesce(name,email) from profiles where id = p_user) || ' の権限を ' || p_role || ' に変更');
end $$;

create or replace function remove_member(p_group uuid, p_user uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if rank_of(my_role(p_group)) < 4 then raise exception 'メンバーの削除はホストのみ可能です'; end if;
  if p_user = auth.uid() then raise exception '自分自身は削除できません'; end if;
  insert into audit(group_id, actor, actor_name, action, label)
  values (p_group, auth.uid(), my_name(), 'member',
          (select coalesce(name,email) from profiles where id = p_user) || ' をグループから削除');
  delete from memberships where group_id = p_group and user_id = p_user;
end $$;

create or replace function restore_entry(p_audit bigint) returns void
language plpgsql security definer set search_path=public as $$
declare a audit%rowtype; b jsonb;
begin
  select * into a from audit where id = p_audit;
  if not found then raise exception '履歴が見つかりません'; end if;
  if rank_of(my_role(a.group_id)) < 3 then raise exception '復元は管理以上の権限が必要です'; end if;
  b := coalesce(a.before, a.after);
  if b is null or a.entry_id is null then raise exception 'この履歴は復元に対応していません'; end if;
  update entries set
    account_id = (b->>'account_id')::uuid,
    custom = case when b->'custom' = 'null'::jsonb then null else b->'custom' end,
    qty  = coalesce(b->'qty', '{}'::jsonb),
    cost = nullif(b->>'cost','')::numeric,
    sell = nullif(b->>'sell','')::numeric,
    par  = nullif(b->>'par','')::int,
    loc  = b->>'loc',
    memo = b->>'memo',
    menu = coalesce((b->>'menu')::boolean, false),
    photo = b->>'photo',
    photos = coalesce(b->'photos', '[]'::jsonb),
    deleted_at = null
  where id = a.entry_id;
end $$;

-- 実行権限
grant execute on function create_group(text)                       to authenticated;
grant execute on function create_invite(uuid, text, int, int)      to authenticated;
grant execute on function accept_invite(text)                      to authenticated;
grant execute on function set_member_role(uuid, uuid, text)        to authenticated;
grant execute on function remove_member(uuid, uuid)                to authenticated;
grant execute on function restore_entry(bigint)                    to authenticated;
grant execute on function invite_info(text)                        to anon, authenticated;

-- ---------- リアルタイム同期（他の人の変更が自動で反映される） ----------
do $$
begin
  begin
    alter publication supabase_realtime add table entries;
  exception when duplicate_object then null;
  end;
end $$;
alter table entries replica identity full;

-- ---------- 最後にスキーマを再読込 ----------
notify pgrst, 'reload schema';

-- ============================================================
-- 完了です。
-- 左メニューの Table Editor に、profiles / groups / memberships /
-- accounts / entries / invites / audit の7つが並んでいれば成功。
--
-- このあと Authentication → Sign In / Providers → Email を開き、
-- 「Confirm email」をオフにしてください（確認メール不要になります）。
-- ============================================================
