-- 조합원 질문은 질문함 비밀번호를 아는 사람만 읽는다. 진행용 PIN으로는 읽을 수 없다.
-- 비밀번호는 관리자가 화면에서 직접 만들고, 해시만 저장한다.

-- 브라우저 역할에게는 표 권한 자체를 주지 않는다 (함수는 소유자 권한으로 동작한다)
revoke all on table public.quiz_asks from public, anon, authenticated;

alter table public.quiz_admin add column ask_pass_hash text;

create function public.quiz_check_ask_pass(p_pass text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (
    select 1 from public.quiz_admin
    where id = 1
      and ask_pass_hash is not null
      and ask_pass_hash = extensions.crypt(coalesce(p_pass, ''), ask_pass_hash)
  ) then
    raise exception 'invalid_ask_pass';
  end if;
end $$;
revoke execute on function public.quiz_check_ask_pass(text) from public, anon, authenticated;

create function public.quiz_ask_has_pass(p_pin text) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  return exists (select 1 from public.quiz_admin where id = 1 and ask_pass_hash is not null);
end $$;

-- 처음에는 진행용 PIN으로 만들고, 그 뒤로는 지금 비밀번호를 알아야 바꿀 수 있다
create function public.quiz_ask_set_pass(p_pin text, p_new text, p_old text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_new text := coalesce(p_new, '');
begin
  perform public.quiz_check_pin(p_pin);
  if exists (select 1 from public.quiz_admin where id = 1 and ask_pass_hash is not null) then
    perform public.quiz_check_ask_pass(p_old);
  end if;
  if char_length(v_new) < 10 or v_new ~ '^[0-9]+$' then
    raise exception 'ask_pass_too_weak';
  end if;
  update public.quiz_admin
  set ask_pass_hash = extensions.crypt(v_new, extensions.gen_salt('bf', 10))
  where id = 1;
end $$;

-- 질문을 읽고 정리하는 함수는 진행용 PIN 대신 질문함 비밀번호를 확인한다
drop function public.quiz_admin_asks(text);
drop function public.quiz_admin_ask_update(text, uuid, text, text);
drop function public.quiz_admin_ask_order(text, uuid[]);
drop function public.quiz_admin_ask_delete(text, uuid);
drop function public.quiz_admin_ask_open(text, boolean);

create function public.quiz_admin_asks(p_pass text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.quiz_check_ask_pass(p_pass);
  return json_build_object(
    'open', (select ask_open from public.quiz_state where id = 1),
    'items', coalesce((
      select json_agg(json_build_object(
        'id', a.id, 'body', a.body, 'author', a.author, 'edited', a.edited,
        'status', a.status, 'sort_order', a.sort_order, 'created_at', a.created_at
      ) order by a.created_at desc)
      from public.quiz_asks a
    ), '[]'::json)
  );
end $$;

create function public.quiz_admin_ask_update(p_pass text, p_id uuid, p_status text default null, p_edited text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_ask_pass(p_pass);
  update public.quiz_asks a
  set status = coalesce(p_status, a.status),
      edited = coalesce(btrim(p_edited), a.edited),
      -- 답변 요청으로 새로 옮긴 질문은 목록 맨 뒤로 보낸다
      sort_order = case
        when p_status = 'pick' and a.status <> 'pick' then (
          select coalesce(max(x.sort_order), 0) + 1 from public.quiz_asks x where x.status = 'pick'
        )
        else a.sort_order
      end
  where a.id = p_id;
end $$;

create function public.quiz_admin_ask_order(p_pass text, p_ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_ask_pass(p_pass);
  update public.quiz_asks a
  set sort_order = o.ord
  from unnest(p_ids) with ordinality as o(id, ord)
  where a.id = o.id;
end $$;

create function public.quiz_admin_ask_delete(p_pass text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_ask_pass(p_pass);
  delete from public.quiz_asks where id = p_id;
end $$;

create function public.quiz_admin_ask_open(p_pass text, p_open boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_ask_pass(p_pass);
  update public.quiz_state set ask_open = p_open where id = 1;
end $$;
