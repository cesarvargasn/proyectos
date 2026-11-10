-- Enable pgcrypto for token generation
create extension if not exists pgcrypto;

-- Participants: created at registration
create table participants (
  id uuid primary key default gen_random_uuid(),
  token text unique not null default encode(gen_random_bytes(16), 'hex'),
  first_name text not null,
  email text not null,
  phone text,
  birthday date,
  completed_at timestamptz,
  created_at timestamptz default now()
);

-- Question bank: all possible questions
create table questions (
  id uuid primary key default gen_random_uuid(),
  text text not null,
  category text not null default 'general',
  weight float not null default 1.0,
  created_at timestamptz default now()
);

-- Event questions: which questions are active for this event, in order
create table event_questions (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references questions(id) on delete cascade,
  display_order int not null,
  active boolean not null default true,
  created_at timestamptz default now(),
  unique(question_id)
);

-- Answers: one row per participant per question (Likert 1-5)
create table answers (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants(id) on delete cascade,
  question_id uuid not null references questions(id) on delete cascade,
  value int not null check (value >= 1 and value <= 5),
  created_at timestamptz default now(),
  unique(participant_id, question_id)
);

-- Matches: populated after algorithm runs
create table matches (
  id uuid primary key default gen_random_uuid(),
  participant_a uuid not null references participants(id),
  participant_b uuid not null references participants(id),
  score float not null,
  created_at timestamptz default now()
);

-- Event state: singleton row
create table event_state (
  id int primary key default 1,
  phase text not null default 'waiting',
  reveal_at timestamptz,
  admin_participates boolean not null default false,
  admin_participant_id uuid references participants(id),
  constraint single_row check (id = 1)
);
insert into event_state (id) values (1);

-- RLS: open for anon (token security handled in app layer)
alter table participants enable row level security;
alter table questions enable row level security;
alter table event_questions enable row level security;
alter table answers enable row level security;
alter table matches enable row level security;
alter table event_state enable row level security;

create policy "anon_all_participants" on participants for all to anon using (true) with check (true);
create policy "anon_all_questions" on questions for all to anon using (true) with check (true);
create policy "anon_all_event_questions" on event_questions for all to anon using (true) with check (true);
create policy "anon_all_answers" on answers for all to anon using (true) with check (true);
create policy "anon_all_matches" on matches for all to anon using (true) with check (true);
create policy "anon_all_event_state" on event_state for all to anon using (true) with check (true);
