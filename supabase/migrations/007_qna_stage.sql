-- 표지와 퀴즈 사이에 조합원 질문 단계('qna')를 넣는다.
-- qno는 올릴 질문 중 몇 번째인지를 뜻하고, 질문 내용은 진행 화면(PIN 필요)에만 전달한다.

alter table public.quiz_state drop constraint quiz_state_stage_check;
alter table public.quiz_state add constraint quiz_state_stage_check
  check (stage in ('cover', 'qna', 'q', 'qdraw', 'result', 'draw', 'end'));

-- 퀴즈 전 단계에서는 정답이 하나도 공개되지 않은 상태다
create or replace function public.quiz_revealed_upto() returns int
language sql stable security definer set search_path = public as $$
  select case s.stage
    when 'cover' then 0
    when 'qna' then 0
    when 'q' then case when s.revealed then s.qno else s.qno - 1 end
    when 'qdraw' then s.qno
    else (select coalesce(max(no), 0) from public.quiz_questions)
  end
  from public.quiz_state s where s.id = 1
$$;

create or replace function public.quiz_admin_set_state(p_pin text, p_stage text, p_qno int, p_revealed boolean) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  if p_stage in ('q', 'qdraw') and not exists (select 1 from public.quiz_questions where no = p_qno) then
    raise exception 'invalid_question';
  end if;
  update public.quiz_state
  set stage = p_stage,
      qno = case when p_stage in ('q', 'qdraw', 'qna') then p_qno else 0 end,
      revealed = case p_stage when 'q' then coalesce(p_revealed, false) when 'qdraw' then true else false end,
      updated_at = now()
  where id = 1;
  return public.quiz_public_state();
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
