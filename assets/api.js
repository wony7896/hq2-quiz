// Supabase 연결 정보 (공개용 키 — 데이터 접근은 DB 함수가 통제한다)
export const SUPABASE_URL = 'https://amoysregnxglrjlsxzvr.supabase.co';
export const SUPABASE_KEY = 'sb_publishable_8aPQtzeRptdI8wflI4Pfxg_X4pVlfX0';

const ERRORS = {
  invalid_pin: '관리자 PIN이 맞지 않아요.',
  nickname_taken: '이미 사용 중인 아이디예요. 다른 아이디를 입력해 주세요.',
  invalid_nickname: '아이디는 1~12자로 입력해 주세요.',
  full: '참여 인원이 가득 찼어요.',
  closed: '이 문제는 응답이 마감됐어요.',
  not_joined: '참여 정보가 없어요. 다시 참여해 주세요.',
  invalid_choice: '보기를 다시 선택해 주세요.',
  invalid_question: '문제 번호가 올바르지 않아요.',
  invalid_questions: '문제는 1~30개까지 저장할 수 있어요.',
  pin_too_short: '새 PIN은 6자 이상이어야 해요.',
  ask_closed: '질문 접수가 마감됐어요.',
  invalid_ask: '질문은 2자 이상 500자 이내로 적어 주세요.',
  invalid_ask_name: '이름은 30자 이내로 적어 주세요.',
  asks_full: '질문이 많이 접수되어 더 받을 수 없어요.',
};

export class ApiError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export async function rpc(fn, args = {}) {
  let res;
  try {
    res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: {
        apikey: SUPABASE_KEY,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(args),
    });
  } catch {
    throw new ApiError('network', '인터넷 연결을 확인해 주세요.');
  }
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const code = body?.message || 'unknown';
    if (code.includes('violates check constraint')) {
      throw new ApiError('check', '입력값을 다시 확인해 주세요. (보기 2~4개, 정답 선택, 문제 200자 이내)');
    }
    throw new ApiError(code, ERRORS[code] || '잠시 후 다시 시도해 주세요.');
  }
  return body;
}

// 진행 상태가 바뀌면 onChange를 부른다. 실시간 연결이 끊겨도 주기적으로 다시 확인한다.
export function watchState(onChange, { pollMs = 4000 } = {}) {
  let timer = null;
  const poll = () => {
    clearTimeout(timer);
    onChange();
    timer = setTimeout(poll, pollMs);
  };

  const lib = window.supabase;
  if (lib?.createClient) {
    const client = lib.createClient(SUPABASE_URL, SUPABASE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    client
      .channel('quiz_state')
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'quiz_state' }, () => {
        // 참여자 수백 명이 한꺼번에 요청하지 않도록 조금씩 흩어서 다시 읽는다
        setTimeout(poll, Math.random() * 350);
      })
      .subscribe();
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') poll();
  });
  poll();
}

export function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
