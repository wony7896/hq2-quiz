-- 문제마다 응답 제한시간을 둔다. 문제를 처음 열 때 시간이 시작되고, 서버가 마감을 판단한다.
-- 정답을 공개하면 바로 마감되어, 이전 화면으로 돌아가도 다시 답할 수 없다.
-- 전체 초기화나 '20초 다시'로만 시간을 되돌릴 수 있다.

alter table public.quiz_questions add column closes_at timestamptz;

-- 제한시간은 여기 한 곳에서 정한다
create function public.quiz_time_limit_ms() returns int
language sql immutable as $$ select 20000 $$;

create function public.quiz_remaining_ms(p_closes_at timestamptz) returns int
language sql stable as $$
  select case when p_closes_at is not null
    then greatest(0, ceil(extract(epoch from p_closes_at - now()) * 1000))::int end
$$;

create or replace function public.quiz_admin_set_state(p_pin text, p_stage text, p_qno int, p_revealed boolean) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  if p_stage in ('q', 'qdraw') and not exists (select 1 from public.quiz_questions where no = p_qno) then
    raise exception 'invalid_question';
  end if;
  if p_stage = 'q' and not coalesce(p_revealed, false) then
    update public.quiz_questions
    set closes_at = now() + public.quiz_time_limit_ms() * interval '1 millisecond'
    where no = p_qno and closes_at is null;
  elsif p_stage in ('q', 'qdraw') then
    update public.quiz_questions set closes_at = least(closes_at, now()) where no = p_qno;
  end if;
  update public.quiz_state
  set stage = p_stage,
      qno = case when p_stage in ('q', 'qdraw', 'qna') then p_qno else 0 end,
      revealed = case p_stage when 'q' then coalesce(p_revealed, false) when 'qdraw' then true else false end,
      updated_at = now()
  where id = 1;
  return public.quiz_public_state();
end $$;

-- 지금 문제의 시간을 처음부터 다시 잰다. updated_at을 바꿔 휴대폰도 바로 다시 읽게 한다.
create function public.quiz_admin_restart_timer(p_pin text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  update public.quiz_questions q
  set closes_at = now() + public.quiz_time_limit_ms() * interval '1 millisecond'
  from public.quiz_state s
  where s.id = 1 and s.stage = 'q' and not s.revealed and q.no = s.qno;
  update public.quiz_state set updated_at = now() where id = 1;
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
  -- 마지막 순간에 누른 답이 네트워크 지연으로 떨어지지 않게 1초 여유를 둔다
  if v_q.closes_at is not null and now() > v_q.closes_at + interval '1 second' then
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
    update public.quiz_questions set closes_at = null where true;
    update public.quiz_state set stage = 'cover', qno = 0, revealed = false, updated_at = now() where id = 1;
  else
    raise exception 'invalid_scope';
  end if;
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
        'explanation', case when v_s.revealed then v_q.explanation end,
        'remaining_ms', case when v_s.stage = 'q' and not v_s.revealed then public.quiz_remaining_ms(v_q.closes_at) end,
        'limit_ms', public.quiz_time_limit_ms()
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
        'remaining_ms', case when v_s.stage = 'q' and not v_s.revealed then public.quiz_remaining_ms(v_q.closes_at) end,
        'limit_ms', public.quiz_time_limit_ms(),
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
    -- 화면에 올릴 조합원 질문 (정한 순서, 다듬은 문구 우선)
    'qna', coalesce((
      select json_agg(json_build_object('id', a.id, 'text', case when a.edited <> '' then a.edited else a.body end)
                      order by a.sort_order nulls last, a.created_at)
      from public.quiz_asks a where a.status = 'pick'
    ), '[]'::json),
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
