-- 질문함 전용 비밀번호를 없애고 진행용 PIN으로 되돌린다.
-- quiz_asks 표의 브라우저 역할 권한은 005에서 제거한 그대로 둔다.

drop function public.quiz_admin_asks(text);
drop function public.quiz_admin_ask_update(text, uuid, text, text);
drop function public.quiz_admin_ask_order(text, uuid[]);
drop function public.quiz_admin_ask_delete(text, uuid);
drop function public.quiz_admin_ask_open(text, boolean);
drop function public.quiz_ask_has_pass(text);
drop function public.quiz_ask_set_pass(text, text, text);
drop function public.quiz_check_ask_pass(text);
alter table public.quiz_admin drop column ask_pass_hash;

create function public.quiz_admin_asks(p_pin text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
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

create function public.quiz_admin_ask_update(p_pin text, p_id uuid, p_status text default null, p_edited text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
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

create function public.quiz_admin_ask_order(p_pin text, p_ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  update public.quiz_asks a
  set sort_order = o.ord
  from unnest(p_ids) with ordinality as o(id, ord)
  where a.id = o.id;
end $$;

create function public.quiz_admin_ask_delete(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  delete from public.quiz_asks where id = p_id;
end $$;

create function public.quiz_admin_ask_open(p_pin text, p_open boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.quiz_check_pin(p_pin);
  update public.quiz_state set ask_open = p_open where id = 1;
end $$;
