-- 아이디 최대 글자 수를 12자에서 13자로 늘린다.
-- '이름 + 팀'으로 쓰면 "홍길동 수도권마케팅기획팀"처럼 13자가 되는 경우가 있다.
-- 룰렛과 당첨 화면에서 글자가 너무 작아지지 않도록 13자에서 멈춘다.

alter table public.quiz_participants drop constraint quiz_participants_nickname_check;
alter table public.quiz_participants
  add constraint quiz_participants_nickname_check check (char_length(nickname) between 1 and 13);

create or replace function public.quiz_join(p_nickname text) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_nick text := btrim(regexp_replace(coalesce(p_nickname, ''), '\s+', ' ', 'g'));
  v_row public.quiz_participants;
begin
  if char_length(v_nick) < 1 or char_length(v_nick) > 13 then
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
