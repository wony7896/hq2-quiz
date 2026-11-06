-- 응답 제한시간을 20초에서 30초로 늘린다.
-- 진행자가 문제와 보기를 읽어 주는 동안에도 시간이 흐르므로, 답을 고르고 제출할 여유를 둔다.
-- 이미 시작된 문제의 마감 시각은 그대로이고, 다음에 여는 문제나 '다시' 버튼부터 적용된다.

create or replace function public.quiz_time_limit_ms() returns int
language sql immutable as $$ select 30000 $$;
