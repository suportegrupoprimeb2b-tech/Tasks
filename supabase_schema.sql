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

create policy "profiles_usuarios_podem_ver_proprio_perfil"
on public.profiles for select
using (auth.uid() = id);

create policy "profiles_usuarios_podem_atualizar_proprio_perfil"
on public.profiles for update
using (auth.uid() = id)
with check (auth.uid() = id);

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

create policy "conversations_acesso_usuario"
on public.conversations for all
using (auth.uid() = user1_id or auth.uid() = user2_id)
with check (auth.uid() = user1_id or auth.uid() = user2_id);

create table if not exists public.conversation_automations (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  command text not null check (command ~ '^/[A-Za-z0-9_-]+$'),
  topic text not null check (length(trim(topic)) > 0),
  start_message text not null check (length(trim(start_message)) > 0),
  instructions text not null default '',
  reply_blocks jsonb not null default '[]'::jsonb check (jsonb_typeof(reply_blocks) = 'array'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, command)
);

alter table public.conversation_automations enable row level security;

drop policy if exists "conversation_automations_acesso_proprio_usuario"
on public.conversation_automations;

create policy "conversation_automations_acesso_proprio_usuario"
on public.conversation_automations for all
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create table if not exists public.conversation_ai_settings (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  automation_id uuid references public.conversation_automations(id) on delete set null,
  enabled boolean not null default false,
  instructions text not null default '',
  reply_blocks jsonb not null default '[]'::jsonb check (jsonb_typeof(reply_blocks) = 'array'),
  updated_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

alter table public.conversation_ai_settings
  add column if not exists automation_id uuid references public.conversation_automations(id) on delete set null;

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
  read_at timestamptz,
  automated_reply_to uuid references public.messages(id) on delete set null,
  created_at timestamptz default now()
);

alter table public.messages enable row level security;

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
);

create table if not exists public.ai_reply_jobs (
  id uuid primary key default uuid_generate_v4(),
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'queued' check (status in ('queued','processing','completed','failed','ignored')),
  attempts int not null default 0,
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  last_error text,
  reply_message_id uuid references public.messages(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (message_id)
);

alter table public.ai_reply_jobs enable row level security;

create policy "ai_reply_jobs_acesso_proprio_usuario"
on public.ai_reply_jobs for all
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create or replace function public.enqueue_ai_reply_job_for_message()
returns trigger
language plpgsql
as $$
declare
  v_conversation public.conversations%rowtype;
  v_other_user uuid;
  v_settings public.conversation_ai_settings%rowtype;
begin
  if NEW.automated_reply_to is not null then
    return NEW;
  end if;

  select * into v_conversation
  from public.conversations
  where id = NEW.conversation_id;

  if not found then
    return NEW;
  end if;

  if v_conversation.user1_id = NEW.sender_id then
    v_other_user := v_conversation.user2_id;
  elsif v_conversation.user2_id = NEW.sender_id then
    v_other_user := v_conversation.user1_id;
  else
    return NEW;
  end if;

  select * into v_settings
  from public.conversation_ai_settings
  where conversation_id = NEW.conversation_id
    and user_id = v_other_user
    and enabled = true
    and automation_id is not null
  limit 1;

  if not found then
    return NEW;
  end if;

  if not exists (
    select 1 from public.ai_reply_jobs where message_id = NEW.id
  ) then
    insert into public.ai_reply_jobs (
      message_id,
      user_id,
      status,
      attempts,
      available_at,
      created_at,
      updated_at
    ) values (
      NEW.id,
      v_other_user,
      'queued',
      0,
      now(),
      now(),
      now()
    );
  end if;

  return NEW;
end;
$$;

drop trigger if exists enqueue_ai_reply_job_after_message_insert on public.messages;
create trigger enqueue_ai_reply_job_after_message_insert
after insert on public.messages
for each row
execute function public.enqueue_ai_reply_job_for_message();

create or replace function public.claim_ai_reply_jobs(p_batch_size int default 10)
returns table (
  id uuid,
  message_id uuid,
  user_id uuid,
  status text,
  attempts int,
  available_at timestamptz,
  locked_at timestamptz,
  last_error text,
  reply_message_id uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
as $$
begin
  return query
  with claimed as (
    select j.id
    from public.ai_reply_jobs j
    where j.status in ('queued', 'failed')
      and j.available_at <= now()
      and (j.locked_at is null or j.locked_at < now() - interval '30 minutes')
    order by j.available_at asc, j.created_at asc
    limit greatest(coalesce(p_batch_size, 10), 1)
    for update skip locked
  )
  update public.ai_reply_jobs j
  set status = 'processing',
      attempts = j.attempts + 1,
      locked_at = now(),
      updated_at = now()
  from claimed
  where j.id = claimed.id
  returning j.id, j.message_id, j.user_id, j.status, j.attempts, j.available_at, j.locked_at, j.last_error, j.reply_message_id, j.created_at, j.updated_at;
end;
$$;

create index if not exists idx_profiles_email on public.profiles(email);
create index if not exists idx_tasks_user_id on public.tasks(user_id);
create index if not exists idx_ai_messages_conversation on public.ai_messages(conversation_id, created_at);
create index if not exists idx_messages_conversation on public.messages(conversation_id, created_at);
create index if not exists idx_ai_reply_jobs_status on public.ai_reply_jobs(status, available_at, locked_at);
create index if not exists idx_conversation_automations_user on public.conversation_automations(user_id, name);

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
