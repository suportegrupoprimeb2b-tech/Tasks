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

create table if not exists public.messages (
  id uuid primary key default uuid_generate_v4(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  content text,
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
