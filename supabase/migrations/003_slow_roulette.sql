-- 룰렛 연출이 약 7초로 길어져서, 당첨자 휴대폰에 당첨을 알리는 시점도 그만큼 늦춘다
create or replace function public.quiz_admin_draw(p_pin text, p_min_score int default 0, p_qno int default null) returns json
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
  values (v_wid, p_qno, now() + interval '7.4 seconds');

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
