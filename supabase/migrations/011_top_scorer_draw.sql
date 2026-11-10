-- 만점자가 없으면 마지막 추첨 대상을 '가장 많이 맞힌 사람'으로 자동으로 정한다.
-- 기준(정답 N개 이상)은 서버에 두어 진행 화면과 참여자 휴대폰이 같은 값을 본다.
--   draw_min 이 비어 있으면 자동: 문제별 추첨에 당첨되지 않은 사람 중 가장 높은 정답 수
--     (만점자가 남아 있으면 만점, 아니면 그다음으로 많이 맞힌 정답 수)
--   진행자가 오른쪽 위 −/+ 로 바꾸면 그 값을 쓴다. 전체 초기화·당첨자 초기화 때 자동으로 돌아간다.
-- 마지막 추첨 당첨자는 자동 기준 계산에서 빼지 않는다 (한 명 뽑은 뒤 기준이 바뀌지 않도록).

alter table public.quiz_state add column draw_min int;

create function public.quiz_draw_min() returns int
language sql stable security definer set search_path = public as $$
  with t as (select count(*)::int as n from public.quiz_questions),
  best as (
    select max(public.quiz_score(p.id, public.quiz_revealed_upto())) as sc
    from public.quiz_participants p
    where not exists (
      select 1 from public.quiz_winners w
      where w.participant_id = p.id and w.question_no is not null
    )
  )
  select greatest(1, least(greatest(t.n, 1), coalesce(s.draw_min, best.sc, t.n)))
  from t, best, public.quiz_state s
  where s.id = 1
$$;

-- 참여자 전체에서 가장 높은 정답 수 (추첨 이름을 '최다 정답자 추첨'으로 부를지 정할 때 쓴다)
create function public.quiz_top_score() returns int
language sql stable security definer set search_path = public as $$
  select coalesce(max(public.quiz_score(p.id, public.quiz_revealed_upto())), 0)
  from public.quiz_participants p
$$;

revoke execute on function public.quiz_draw_min() from public, anon, authenticated;
revoke execute on function public.quiz_top_score() from public, anon, authenticated;

-- 진행자가 −/+ 로 기준을 바꾼다. null 이면 자동으로 돌아간다.
create function public.quiz_admin_set_draw_min(p_pin text, p_min int) returns int
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  update public.quiz_state set draw_min = p_min, updated_at = now() where id = 1;
  return public.quiz_draw_min();
end $$;

create or replace function public.quiz_admin_reset(p_pin text, p_scope text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  if p_scope = 'winners' then
    delete from public.quiz_winners where true;
    update public.quiz_state set draw_min = null, updated_at = now() where id = 1;
  elsif p_scope = 'all' then
    delete from public.quiz_winners where true;
    delete from public.quiz_answers where true;
    delete from public.quiz_participants where true;
    update public.quiz_questions set closes_at = null where true;
    update public.quiz_state set stage = 'cover', qno = 0, revealed = false, draw_min = null, updated_at = now() where id = 1;
  else
    raise exception 'invalid_scope';
  end if;
end $$;

-- 휴대폰: 퀴즈가 끝난 뒤(결과·마지막 추첨·마무리)에만 추첨 기준과 최고 정답 수를 함께 보낸다
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
  v_final boolean;
begin
  select * into v_p from public.quiz_participants where token = p_token;
  if not found then
    return json_build_object('ok', false);
  end if;
  select * into v_s from public.quiz_state where id = 1;
  select count(*) into v_total from public.quiz_questions;
  v_final := v_s.stage in ('result', 'draw', 'end');

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
      'title', v_s.title, 'subtitle', v_s.subtitle, 'total', v_total,
      'draw_min', case when v_final then public.quiz_draw_min() end,
      'top', case when v_final then public.quiz_top_score() end
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
      'total', (select count(*) from public.quiz_questions),
      -- 마지막 추첨 기준 (정답 N개 이상)
      'draw_min', public.quiz_draw_min()
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
