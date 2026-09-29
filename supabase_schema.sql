-- Estrutura mínima para o painel Logística B2B funcionar com Auth + Tasks + IA
-- Execute no SQL Editor do Supabase.

create extension if not exists "uuid-ossp";

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique,
  full_name text,
  avatar_url text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles_usuarios_podem_ver_proprio_perfil" on public.profiles;
create policy "profiles_usuarios_podem_ver_proprio_perfil"
on public.profiles for select
using (auth.uid() = id);

drop policy if exists "profiles_usuarios_podem_atualizar_proprio_perfil" on public.profiles;
create policy "profiles_usuarios_podem_atualizar_proprio_perfil"
on public.profiles for update
using (auth.uid() = id)
with check (auth.uid() = id);

drop policy if exists "profiles_usuarios_podem_criar_proprio_perfil" on public.profiles;
create policy "profiles_usuarios_podem_criar_proprio_perfil"
on public.profiles for insert
with check (auth.uid() = id);

create table if not exists public.tasks (
  id uuid primary key default uuid_generate_v4(),
  title text not null,
  type text not null default 'task',
  group_name text,
  status text not null default 'pending',
  due_date timestamptz,
  description text,
  user_id uuid references auth.users(id) on delete cascade,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table public.tasks enable row level security;

drop policy if exists "tasks_usuarios_acessam_somente_suas_tarefas" on public.tasks;
create policy "tasks_usuarios_acessam_somente_suas_tarefas"
on public.tasks for all
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create table if not exists public.ai_conversations (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid references auth.users(id) on delete cascade,
  title text,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table public.ai_conversations enable row level security;

drop policy if exists "ai_conversations_acesso_usuario" on public.ai_conversations;
create policy "ai_conversations_acesso_usuario"
on public.ai_conversations for all
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create table if not exists public.ai_messages (
  id uuid primary key default uuid_generate_v4(),
  conversation_id uuid references public.ai_conversations(id) on delete cascade,
  role text not null check (role in ('user','assistant','system')),
  content text,
  tool_calls jsonb default '[]'::jsonb,
  model text,
  client_msg_id text,
  status text default 'done',
  created_at timestamptz default now()
);

alter table public.ai_messages enable row level security;

drop policy if exists "ai_messages_acesso_usuario" on public.ai_messages;
create policy "ai_messages_acesso_usuario"
on public.ai_messages for all
using (
  exists (
    select 1 from public.ai_conversations c
    where c.id = ai_messages.conversation_id and c.user_id = auth.uid()
  )
)
with check (
  exists (
    select 1 from public.ai_conversations c
    where c.id = ai_messages.conversation_id and c.user_id = auth.uid()
  )
);

create table if not exists public.conversations (
  id uuid primary key default uuid_generate_v4(),
  user1_id uuid not null references auth.users(id) on delete cascade,
  user2_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz default now(),
  unique (user1_id, user2_id)
);

alter table public.conversations enable row level security;

drop policy if exists "conversations_acesso_usuario" on public.conversations;
create policy "conversations_acesso_usuario"
on public.conversations for all
using (auth.uid() = user1_id or auth.uid() = user2_id)
with check (auth.uid() = user1_id or auth.uid() = user2_id);

create table if not exists public.conversation_ai_settings (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  enabled boolean not null default false,
  instructions text not null default '',
  reply_blocks jsonb not null default '[]'::jsonb check (jsonb_typeof(reply_blocks) = 'array'),
  updated_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

alter table public.conversation_ai_settings enable row level security;

drop policy if exists "conversation_ai_settings_acesso_proprio_usuario"
on public.conversation_ai_settings;

create policy "conversation_ai_settings_acesso_proprio_usuario"
on public.conversation_ai_settings for all
using (
  auth.uid() = user_id
  and exists (
    select 1 from public.conversations c
    where c.id = conversation_ai_settings.conversation_id
      and (c.user1_id = auth.uid() or c.user2_id = auth.uid())
  )
)
with check (
  auth.uid() = user_id
  and exists (
    select 1 from public.conversations c
    where c.id = conversation_ai_settings.conversation_id
      and (c.user1_id = auth.uid() or c.user2_id = auth.uid())
  )
);

create table if not exists public.messages (
  id uuid primary key default uuid_generate_v4(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  content text,
  created_at timestamptz default now(),
  read_at timestamptz,
  automated_reply_to uuid references public.messages(id) on delete set null
);

alter table public.messages add column if not exists read_at timestamptz;
alter table public.messages add column if not exists automated_reply_to uuid references public.messages(id) on delete set null;
create unique index if not exists idx_messages_automated_reply_to on public.messages(automated_reply_to);

alter table public.messages enable row level security;

drop policy if exists "messages_acesso_usuario" on public.messages;
create policy "messages_acesso_usuario"
on public.messages for all
using (
  exists (
    select 1 from public.conversations c
    where c.id = messages.conversation_id
      and (c.user1_id = auth.uid() or c.user2_id = auth.uid())
  )
)
with check (
  exists (
    select 1 from public.conversations c
    where c.id = messages.conversation_id
      and (c.user1_id = auth.uid() or c.user2_id = auth.uid())
  )
  and messages.automated_reply_to is null
);

create table if not exists public.ai_reply_jobs (
  id uuid primary key default uuid_generate_v4(),
  message_id uuid not null unique references public.messages(id) on delete cascade,
  status text not null default 'queued'
    check (status in ('queued', 'processing', 'completed', 'ignored', 'failed')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  reply_message_id uuid references public.messages(id) on delete set null,
  last_error text,
  created_at timestamptz not null default now()
);

alter table public.ai_reply_jobs enable row level security;

create or replace function public.enqueue_ai_reply_job()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.automated_reply_to is not null then
    return new;
  end if;

  insert into public.ai_reply_jobs (message_id)
  select new.id
  from public.conversations c
  join public.conversation_ai_settings s
    on s.conversation_id = c.id
   and s.user_id = case
     when new.sender_id = c.user1_id then c.user2_id
     when new.sender_id = c.user2_id then c.user1_id
     else null
   end
  where c.id = new.conversation_id
    and s.enabled
  on conflict (message_id) do nothing;

  return new;
end;
$$;

drop trigger if exists enqueue_ai_reply_job_after_message on public.messages;
create trigger enqueue_ai_reply_job_after_message
after insert on public.messages
for each row execute function public.enqueue_ai_reply_job();

create or replace function public.claim_ai_reply_jobs(p_batch_size integer default 10)
returns setof public.ai_reply_jobs
language sql
security definer
set search_path = pg_catalog, public
as $$
  with expired_leases as (
    update public.ai_reply_jobs
    set status = 'failed',
        locked_at = null,
        last_error = coalesce(last_error, 'Worker lease expired after final attempt')
    where status = 'processing'
      and locked_at < now() - interval '5 minutes'
      and attempts >= 5
    returning id
  ), candidates as (
    select j.id
    from public.ai_reply_jobs j
    where (
      (j.status = 'queued' and j.available_at <= now())
      or (j.status = 'processing' and j.locked_at < now() - interval '5 minutes')
    )
      and j.attempts < 5
    order by j.created_at
    for update skip locked
    limit least(greatest(coalesce(p_batch_size, 10), 1), 50)
  )
  update public.ai_reply_jobs j
  set status = 'processing',
      attempts = j.attempts + 1,
      locked_at = now()
  from candidates c
  where j.id = c.id
  returning j.*;
$$;

revoke all on function public.claim_ai_reply_jobs(integer) from public, anon, authenticated;
grant execute on function public.claim_ai_reply_jobs(integer) to service_role;
grant select, update on public.ai_reply_jobs to service_role;
grant select on public.conversations, public.conversation_ai_settings to service_role;
grant select, insert on public.messages to service_role;

drop trigger if exists set_updated_at_profiles on public.profiles;
drop trigger if exists set_updated_at_tasks on public.tasks;
drop trigger if exists set_updated_at_ai_conversations on public.ai_conversations;

create index if not exists idx_profiles_email on public.profiles(email);
create index if not exists idx_tasks_user_id on public.tasks(user_id);
create index if not exists idx_ai_messages_conversation on public.ai_messages(conversation_id, created_at);
create index if not exists idx_messages_conversation on public.messages(conversation_id, created_at);

-- Trigger para atualizar updated_at
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger set_updated_at_profiles
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger set_updated_at_tasks
before update on public.tasks
for each row execute function public.set_updated_at();

create trigger set_updated_at_ai_conversations
before update on public.ai_conversations
for each row execute function public.set_updated_at();
