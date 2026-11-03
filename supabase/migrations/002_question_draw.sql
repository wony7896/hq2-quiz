-- 문제마다 정답자 추첨 + 문제 화면에 응답자 아이디 표시
-- schema.sql 다음에 적용한다.

-- 'qdraw' = n번 문제 정답자 추첨 화면
alter table public.quiz_state drop constraint quiz_state_stage_check;
alter table public.quiz_state add constraint quiz_state_stage_check
  check (stage in ('cover', 'q', 'qdraw', 'result', 'draw', 'end'));

-- 문제 정답자 추첨으로 뽑혔으면 그 문제 번호, 마지막 경품 추첨이면 null
alter table public.quiz_winners add column question_no int;

create or replace function public.quiz_revealed_upto() returns int
language sql stable security definer set search_path = public as $$
  select case s.stage
    when 'cover' then 0
    when 'q' then case when s.revealed then s.qno else s.qno - 1 end
    when 'qdraw' then s.qno
    else (select coalesce(max(no), 0) from public.quiz_questions)
  end
  from public.quiz_state s where s.id = 1
$$;

-- 추첨 후보: 아직 당첨되지 않은 사람 중
--   p_qno 가 있으면 그 문제를 맞힌 사람, 없으면 정답 수가 p_min 이상인 사람
drop function public.quiz_admin_draw(text, int);
drop function public.quiz_pool(int);
create function public.quiz_pool(p_min int, p_qno int) returns table (id uuid, nickname text)
language sql stable security definer set search_path = public as $$
  select p.id, p.nickname
  from public.quiz_participants p
  where not exists (select 1 from public.quiz_winners w where w.participant_id = p.id)
    and case
      when p_qno is null then public.quiz_score(p.id, 1000) >= coalesce(p_min, 0)
      else exists (
        select 1 from public.quiz_answers a
        join public.quiz_questions q on q.no = a.question_no and q.answer = a.choice
        where a.participant_id = p.id and a.question_no = p_qno
      )
    end
$$;
revoke execute on function public.quiz_pool(int, int) from public, anon, authenticated;

create or replace function public.quiz_me(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  v_p public.quiz_participants;
  v_s public.quiz_state;
  v_q public.quiz_questions;
  v_total int;
  v_choice int;
  v_rank int;
  v_wq int;
  v_question json;
begin
  select * into v_p from public.quiz_participants where token = p_token;
  if not found then
    return json_build_object('ok', false);
  end if;
  select * into v_s from public.quiz_state where id = 1;
  select count(*) into v_total from public.quiz_questions;

  -- 당첨은 진행 화면의 추첨 연출이 끝난 뒤에만 알려준다
  select r.rn, r.question_no into v_rank, v_wq from (
    select w.participant_id, w.reveal_at, w.question_no,
           row_number() over (partition by w.question_no order by w.created_at, w.id) as rn
    from public.quiz_winners w
  ) r where r.participant_id = v_p.id and r.reveal_at <= now();

  if v_s.stage in ('q', 'qdraw') then
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
    'win', case when v_rank is not null then json_build_object('qno', v_wq, 'rank', v_rank) end,
    'state', json_build_object(
      'stage', v_s.stage, 'qno', v_s.qno, 'revealed', v_s.revealed,
      'title', v_s.title, 'subtitle', v_s.subtitle, 'total', v_total
    ),
    'question', v_question
  );
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

  if v_s.stage in ('q', 'qdraw') then
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
        ),
        -- 응답한 사람 (먼저 낸 순서)
        'answers', coalesce((
          select json_agg(json_build_object('id', a.participant_id, 'nickname', p.nickname, 'choice', a.choice)
                          order by a.created_at, p.nickname)
          from public.quiz_answers a join public.quiz_participants p on p.id = a.participant_id
          where a.question_no = v_q.no
        ), '[]'::json)
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
      select json_agg(json_build_object('id', r.id, 'nickname', p.nickname, 'qno', r.question_no, 'rank', r.rn)
                      order by r.created_at, r.id)
      from (
        select w.id, w.participant_id, w.question_no, w.created_at,
               row_number() over (partition by w.question_no order by w.created_at, w.id) as rn
        from public.quiz_winners w
      ) r join public.quiz_participants p on p.id = r.participant_id
    ), '[]'::json)
  );
end $$;

create or replace function public.quiz_admin_set_state(p_pin text, p_stage text, p_qno int, p_revealed boolean) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  if p_stage in ('q', 'qdraw') and not exists (select 1 from public.quiz_questions where no = p_qno) then
    raise exception 'invalid_question';
  end if;
  update public.quiz_state
  set stage = p_stage,
      qno = case when p_stage in ('q', 'qdraw') then p_qno else 0 end,
      revealed = case p_stage when 'q' then coalesce(p_revealed, false) when 'qdraw' then true else false end,
      updated_at = now()
  where id = 1;
  return public.quiz_public_state();
end $$;

-- 추첨 연출이 끝난 뒤 참여자 휴대폰이 바로 다시 읽도록 실시간 알림만 보낸다
create or replace function public.quiz_admin_touch(p_pin text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  update public.quiz_state set updated_at = now() where id = 1;
end $$;

-- p_qno 가 있으면 그 문제 정답자 중에서, 없으면 정답 수 기준으로 한 명을 뽑는다
create function public.quiz_admin_draw(p_pin text, p_min_score int default 0, p_qno int default null) returns json
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

  select count(*) into v_size from public.quiz_pool(p_min_score, p_qno);
  if v_size = 0 then
    return json_build_object('winner', null, 'pool', '[]'::json, 'pool_size', 0);
  end if;

  select id, nickname into v_wid, v_wnick from public.quiz_pool(p_min_score, p_qno) order by random() limit 1;
  select json_agg(s.nickname) into v_pool from (
    select nickname from public.quiz_pool(p_min_score, p_qno) order by random() limit 150
  ) s;

  insert into public.quiz_winners (participant_id, question_no, reveal_at)
  values (v_wid, p_qno, now() + interval '5.5 seconds');

  return json_build_object(
    'winner', json_build_object(
      'nickname', v_wnick,
      'qno', p_qno,
      'rank', (select count(*) from public.quiz_winners where question_no is not distinct from p_qno)
    ),
    'pool', v_pool,
    'pool_size', v_size
  );
end $$;
