-- 본사2지부 문화행사 퀴즈 & 추첨
-- 모든 표는 quiz_ 로 시작하며, 기존 프로젝트의 다른 표와 섞이지 않는다.
-- 브라우저는 표에 직접 접근하지 않고 아래 함수(RPC)만 호출한다.
-- 진행자 함수는 모두 관리자 PIN을 확인한다. PIN은 이 파일에 넣지 않는다.

create extension if not exists pgcrypto with schema extensions;

-- 진행 상태 (한 줄)
create table public.quiz_state (
  id int primary key default 1 check (id = 1),
  stage text not null default 'cover' check (stage in ('cover', 'q', 'result', 'draw', 'end')),
  qno int not null default 0,
  revealed boolean not null default false,
  title text not null default '본사2지부 문화행사',
  subtitle text not null default '퀴즈 & 경품 추첨',
  updated_at timestamptz not null default now()
);
insert into public.quiz_state (id) values (1);

create table public.quiz_admin (
  id int primary key default 1 check (id = 1),
  pin_hash text not null
);

create table public.quiz_questions (
  no int primary key check (no between 1 and 30),
  question text not null check (char_length(question) between 1 and 200),
  options text[] not null check (array_length(options, 1) between 2 and 4),
  answer int not null,
  explanation text not null default '',
  check (answer >= 0 and answer < array_length(options, 1))
);

create table public.quiz_participants (
  id uuid primary key default gen_random_uuid(),
  token uuid not null unique default gen_random_uuid(),
  nickname text not null check (char_length(nickname) between 1 and 12),
  is_demo boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index quiz_participants_nickname_key on public.quiz_participants (lower(nickname));

create table public.quiz_answers (
  participant_id uuid not null references public.quiz_participants (id) on delete cascade,
  question_no int not null,
  choice int not null,
  created_at timestamptz not null default now(),
  primary key (participant_id, question_no)
);

create table public.quiz_winners (
  id bigint generated always as identity primary key,
  participant_id uuid not null unique references public.quiz_participants (id) on delete cascade,
  reveal_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table public.quiz_state enable row level security;
alter table public.quiz_admin enable row level security;
alter table public.quiz_questions enable row level security;
alter table public.quiz_participants enable row level security;
alter table public.quiz_answers enable row level security;
alter table public.quiz_winners enable row level security;

-- 진행 상태만 공개로 읽을 수 있다 (실시간 화면 전환 알림용)
create policy quiz_state_read on public.quiz_state for select to anon, authenticated using (true);
alter publication supabase_realtime add table public.quiz_state;

-- ───────── 내부 도우미 ─────────

create or replace function public.quiz_check_pin(p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (
    select 1 from public.quiz_admin
    where id = 1 and pin_hash = extensions.crypt(coalesce(p_pin, ''), pin_hash)
  ) then
    raise exception 'invalid_pin';
  end if;
end $$;

-- 지금까지 정답이 공개된 마지막 문제 번호
create or replace function public.quiz_revealed_upto() returns int
language sql stable security definer set search_path = public as $$
  select case s.stage
    when 'cover' then 0
    when 'q' then case when s.revealed then s.qno else s.qno - 1 end
    else (select coalesce(max(no), 0) from public.quiz_questions)
  end
  from public.quiz_state s where s.id = 1
$$;

create or replace function public.quiz_score(p_pid uuid, p_upto int) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int
  from public.quiz_answers a
  join public.quiz_questions q on q.no = a.question_no and q.answer = a.choice
  where a.participant_id = p_pid and a.question_no <= p_upto
$$;

-- 추첨 후보: 아직 당첨되지 않았고 정답 수가 기준 이상인 참여자
create or replace function public.quiz_pool(p_min int) returns table (id uuid, nickname text)
language sql stable security definer set search_path = public as $$
  select p.id, p.nickname
  from public.quiz_participants p
  where not exists (select 1 from public.quiz_winners w where w.participant_id = p.id)
    and public.quiz_score(p.id, 1000) >= coalesce(p_min, 0)
$$;

revoke execute on function public.quiz_check_pin(text) from public, anon, authenticated;
revoke execute on function public.quiz_revealed_upto() from public, anon, authenticated;
revoke execute on function public.quiz_score(uuid, int) from public, anon, authenticated;
revoke execute on function public.quiz_pool(int) from public, anon, authenticated;

-- ───────── 참여자용 ─────────

create or replace function public.quiz_public_state() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'stage', s.stage, 'qno', s.qno, 'revealed', s.revealed,
    'title', s.title, 'subtitle', s.subtitle,
    'total', (select count(*) from public.quiz_questions),
    'participants', (select count(*) from public.quiz_participants)
  )
  from public.quiz_state s where s.id = 1
$$;

create or replace function public.quiz_join(p_nickname text) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_nick text := btrim(regexp_replace(coalesce(p_nickname, ''), '\s+', ' ', 'g'));
  v_row public.quiz_participants;
begin
  if char_length(v_nick) < 1 or char_length(v_nick) > 12 then
    raise exception 'invalid_nickname';
  end if;
  if (select count(*) from public.quiz_participants) >= 1000 then
    raise exception 'full';
  end if;
  begin
    insert into public.quiz_participants (nickname) values (v_nick) returning * into v_row;
  exception when unique_violation then
    raise exception 'nickname_taken';
  end;
  return json_build_object('token', v_row.token, 'nickname', v_row.nickname);
end $$;

create or replace function public.quiz_me(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_p public.quiz_participants;
  v_s public.quiz_state;
  v_q public.quiz_questions;
  v_total int;
  v_choice int;
  v_rank int;
  v_question json;
begin
  select * into v_p from public.quiz_participants where token = p_token;
  if not found then
    return json_build_object('ok', false);
  end if;
  select * into v_s from public.quiz_state where id = 1;
  select count(*) into v_total from public.quiz_questions;

  -- 당첨은 진행 화면의 추첨 연출이 끝난 뒤에만 알려준다
  select r.rn into v_rank from (
    select w.participant_id, w.reveal_at, row_number() over (order by w.created_at, w.id) as rn
    from public.quiz_winners w
  ) r where r.participant_id = v_p.id and r.reveal_at <= now();

  if v_s.stage = 'q' then
    select * into v_q from public.quiz_questions where no = v_s.qno;
    if found then
      select choice into v_choice from public.quiz_answers
      where participant_id = v_p.id and question_no = v_q.no;
      v_question := json_build_object(
        'no', v_q.no, 'question', v_q.question, 'options', to_json(v_q.options),
        'my_choice', v_choice,
        'answer', case when v_s.revealed then v_q.answer end,
        'explanation', case when v_s.revealed then v_q.explanation end
      );
    end if;
  end if;

  return json_build_object(
    'ok', true,
    'nickname', v_p.nickname,
    'score', public.quiz_score(v_p.id, public.quiz_revealed_upto()),
    'win_rank', v_rank,
    'state', json_build_object(
      'stage', v_s.stage, 'qno', v_s.qno, 'revealed', v_s.revealed,
      'title', v_s.title, 'subtitle', v_s.subtitle, 'total', v_total
    ),
    'question', v_question
  );
end $$;

create or replace function public.quiz_answer(p_token uuid, p_qno int, p_choice int) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid;
  v_s public.quiz_state;
  v_q public.quiz_questions;
  v_choice int;
begin
  select id into v_pid from public.quiz_participants where token = p_token;
  if not found then
    raise exception 'not_joined';
  end if;
  -- 정답 공개와 동시에 들어온 답은 공개가 끝난 뒤 상태로 판단한다
  select * into v_s from public.quiz_state where id = 1 for share;
  if v_s.stage <> 'q' or v_s.qno <> p_qno or v_s.revealed then
    raise exception 'closed';
  end if;
  select * into v_q from public.quiz_questions where no = p_qno;
  if not found then
    raise exception 'closed';
  end if;
  if p_choice is null or p_choice < 0 or p_choice >= array_length(v_q.options, 1) then
    raise exception 'invalid_choice';
  end if;
  insert into public.quiz_answers (participant_id, question_no, choice)
  values (v_pid, p_qno, p_choice)
  on conflict do nothing;
  select choice into v_choice from public.quiz_answers where participant_id = v_pid and question_no = p_qno;
  return json_build_object('ok', true, 'choice', v_choice);
end $$;

-- ───────── 진행자용 (PIN 필요) ─────────

create or replace function public.quiz_admin_login(p_pin text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  return true;
end $$;

create or replace function public.quiz_admin_status(p_pin text) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_s public.quiz_state;
  v_q public.quiz_questions;
  v_upto int;
  v_current json;
begin
  perform public.quiz_check_pin(p_pin);
  select * into v_s from public.quiz_state where id = 1;
  v_upto := public.quiz_revealed_upto();

  if v_s.stage = 'q' then
    select * into v_q from public.quiz_questions where no = v_s.qno;
    if found then
      v_current := json_build_object(
        'no', v_q.no, 'question', v_q.question, 'options', to_json(v_q.options),
        'answer', v_q.answer, 'explanation', v_q.explanation,
        'counts', (
          select json_agg(coalesce(c.cnt, 0) order by i)
          from generate_series(0, array_length(v_q.options, 1) - 1) as i
          left join (
            select choice, count(*)::int as cnt from public.quiz_answers
            where question_no = v_q.no group by choice
          ) c on c.choice = i
        )
      );
    end if;
  end if;

  return json_build_object(
    'state', json_build_object(
      'stage', v_s.stage, 'qno', v_s.qno, 'revealed', v_s.revealed,
      'title', v_s.title, 'subtitle', v_s.subtitle,
      'total', (select count(*) from public.quiz_questions)
    ),
    'current', v_current,
    'participants', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'nickname', p.nickname, 'demo', p.is_demo,
        'score', public.quiz_score(p.id, v_upto),
        'won', exists (select 1 from public.quiz_winners w where w.participant_id = p.id)
      ) order by p.created_at)
      from public.quiz_participants p
    ), '[]'::json),
    'winners', coalesce((
      select json_agg(json_build_object('id', r.id, 'nickname', p.nickname, 'rank', r.rn) order by r.rn)
      from (
        select w.id, w.participant_id, row_number() over (order by w.created_at, w.id) as rn
        from public.quiz_winners w
      ) r join public.quiz_participants p on p.id = r.participant_id
    ), '[]'::json)
  );
end $$;

create or replace function public.quiz_admin_questions(p_pin text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  return coalesce((
    select json_agg(json_build_object(
      'no', no, 'question', question, 'options', to_json(options),
      'answer', answer, 'explanation', explanation
    ) order by no)
    from public.quiz_questions
  ), '[]'::json);
end $$;

create or replace function public.quiz_admin_save_questions(p_pin text, p_questions json) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  if json_array_length(p_questions) < 1 or json_array_length(p_questions) > 30 then
    raise exception 'invalid_questions';
  end if;
  delete from public.quiz_questions where true;
  insert into public.quiz_questions (no, question, options, answer, explanation)
  select t.n::int,
         btrim(t.x ->> 'question'),
         array(select btrim(o) from json_array_elements_text(t.x -> 'options') as o where btrim(o) <> ''),
         (t.x ->> 'answer')::int,
         coalesce(btrim(t.x ->> 'explanation'), '')
  from json_array_elements(p_questions) with ordinality as t (x, n);
  return public.quiz_admin_questions(p_pin);
end $$;

create or replace function public.quiz_admin_set_state(p_pin text, p_stage text, p_qno int, p_revealed boolean) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  if p_stage = 'q' and not exists (select 1 from public.quiz_questions where no = p_qno) then
    raise exception 'invalid_question';
  end if;
  update public.quiz_state
  set stage = p_stage,
      qno = case when p_stage = 'q' then p_qno else 0 end,
      revealed = case when p_stage = 'q' then coalesce(p_revealed, false) else false end,
      updated_at = now()
  where id = 1;
  return public.quiz_public_state();
end $$;

create or replace function public.quiz_admin_set_info(p_pin text, p_title text, p_subtitle text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  update public.quiz_state
  set title = coalesce(nullif(btrim(p_title), ''), title),
      subtitle = coalesce(btrim(p_subtitle), ''),
      updated_at = now()
  where id = 1;
  return public.quiz_public_state();
end $$;

create or replace function public.quiz_admin_draw(p_pin text, p_min_score int) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_size int;
  v_pool json;
  v_wid uuid;
  v_wnick text;
begin
  perform public.quiz_check_pin(p_pin);
  -- 동시에 두 번 눌러도 한 명씩만 뽑힌다
  lock table public.quiz_winners in exclusive mode;

  select count(*) into v_size from public.quiz_pool(p_min_score);
  if v_size = 0 then
    return json_build_object('winner', null, 'pool', '[]'::json, 'pool_size', 0);
  end if;

  select id, nickname into v_wid, v_wnick from public.quiz_pool(p_min_score) order by random() limit 1;
  select json_agg(s.nickname) into v_pool from (
    select nickname from public.quiz_pool(p_min_score) order by random() limit 150
  ) s;

  insert into public.quiz_winners (participant_id, reveal_at)
  values (v_wid, now() + interval '5.5 seconds');

  return json_build_object(
    'winner', json_build_object(
      'nickname', v_wnick,
      'rank', (select count(*) from public.quiz_winners)
    ),
    'pool', v_pool,
    'pool_size', v_size
  );
end $$;

create or replace function public.quiz_admin_remove_winner(p_pin text, p_winner_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  delete from public.quiz_winners where id = p_winner_id;
end $$;

create or replace function public.quiz_admin_delete_participant(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  delete from public.quiz_participants where id = p_id;
end $$;

-- p_scope: 'winners' = 당첨 기록만, 'all' = 참여자·답변·당첨 전부 지우고 첫 화면으로
create or replace function public.quiz_admin_reset(p_pin text, p_scope text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  if p_scope = 'winners' then
    delete from public.quiz_winners where true;
  elsif p_scope = 'all' then
    delete from public.quiz_winners where true;
    delete from public.quiz_answers where true;
    delete from public.quiz_participants where true;
    update public.quiz_state set stage = 'cover', qno = 0, revealed = false, updated_at = now() where id = 1;
  else
    raise exception 'invalid_scope';
  end if;
end $$;

-- 리허설용 가짜 참여자 (모든 문제에 무작위로 답함, 약 70% 정답)
create or replace function public.quiz_admin_seed_demo(p_pin text, p_count int) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_added int := 0;
  v_pid uuid;
  i int;
begin
  perform public.quiz_check_pin(p_pin);
  for i in 1 .. least(greatest(coalesce(p_count, 0), 0), 200) loop
    insert into public.quiz_participants (nickname, is_demo)
    values ('테스트' || lpad(i::text, 3, '0'), true)
    on conflict ((lower(nickname))) do nothing
    returning id into v_pid;
    if v_pid is not null then
      v_added := v_added + 1;
      insert into public.quiz_answers (participant_id, question_no, choice)
      select v_pid, q.no,
             case when random() < 0.7 then q.answer
                  else floor(random() * array_length(q.options, 1))::int end
      from public.quiz_questions q;
    end if;
    v_pid := null;
  end loop;
  return v_added;
end $$;

create or replace function public.quiz_admin_set_pin(p_pin text, p_new_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.quiz_check_pin(p_pin);
  if char_length(coalesce(p_new_pin, '')) < 6 then
    raise exception 'pin_too_short';
  end if;
  update public.quiz_admin set pin_hash = extensions.crypt(p_new_pin, extensions.gen_salt('bf')) where id = 1;
end $$;

-- 예시 문제 (진행 화면의 설정에서 본사2지부 문제로 바꾼다)
insert into public.quiz_questions (no, question, options, answer, explanation)
select n,
       '예시 문제 ' || n || ' — 설정에서 본사2지부 문제로 바꿔주세요',
       case when n = 10 then array['O', 'X'] else array['보기 1', '보기 2', '보기 3', '보기 4'] end,
       0,
       ''
from generate_series(1, 10) as n;
