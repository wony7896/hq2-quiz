-- 조합원 사전 질문: 로그인 없이 받고, 관리자 PIN으로만 읽고 정리한다
-- 전체 초기화(quiz_admin_reset)는 이 표를 지우지 않는다.

alter table public.quiz_state add column ask_open boolean not null default true;

create table public.quiz_asks (
  id uuid primary key default gen_random_uuid(),
  body text not null check (char_length(body) between 2 and 500),
  author text not null default '' check (char_length(author) <= 30),
  edited text not null default '' check (char_length(edited) <= 500), -- 위원장에게 전달할 다듬은 문구
  status text not null default 'new' check (status in ('new', 'pick', 'hold')), -- 새 질문 / 답변 요청 / 보류
  sort_order int, -- 답변 요청 목록의 순서
  created_at timestamptz not null default now()
);

-- 정책을 두지 않아 브라우저에서는 표를 직접 읽거나 쓸 수 없다
alter table public.quiz_asks enable row level security;

-- ───────── 조합원용 ─────────

create function public.quiz_ask_info() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('open', ask_open) from public.quiz_state where id = 1
$$;

create function public.quiz_ask_submit(p_body text, p_author text default '') returns json
language plpgsql security definer set search_path = public as $$
declare
  v_body text := btrim(coalesce(p_body, ''), E' \t\r\n');
  v_author text := btrim(regexp_replace(coalesce(p_author, ''), '\s+', ' ', 'g'));
begin
  if not (select ask_open from public.quiz_state where id = 1) then
    raise exception 'ask_closed';
  end if;
  if char_length(v_body) < 2 or char_length(v_body) > 500 then
    raise exception 'invalid_ask';
  end if;
  if char_length(v_author) > 30 then
    raise exception 'invalid_ask_name';
  end if;
  if (select count(*) from public.quiz_asks) >= 1000 then
    raise exception 'asks_full';
  end if;
  -- 응답을 못 받아 다시 눌러도 같은 글이 두 번 쌓이지 않게 한다
  if not exists (
    select 1 from public.quiz_asks
    where body = v_body and author = v_author and created_at > now() - interval '10 minutes'
  ) then
    insert into public.quiz_asks (body, author) values (v_body, v_author);
  end if;
  return json_build_object('ok', true);
end $$;

-- ───────── 관리자용 ─────────

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
