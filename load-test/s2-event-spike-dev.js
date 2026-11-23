// point-infra/load-test/k6/s2-event-spike.js 를 dev 용으로 수정
// - X-User-Id 헤더 → JWT (Authorization: Bearer). TOKEN 은 9단계 로그인으로 발급 (TTL 15분 → 직전 발급)
// - 5,000 RPS → 300 RPS (집 회선·ALB 비용·Karpenter limits.cpu 16)
// 실행: docker run --rm -i -e BASE_URL=http://$ALB -e EVENT_ID=evt-local -e TOKEN=$TOKEN grafana/k6 run - < load-test/s2-event-spike-dev.js
import http from 'k6/http';
import { check } from 'k6';

// 409(중복)·410(마감)도 정상 응답 → http_req_failed 에 집계하지 않음
http.setResponseCallback(http.expectedStatuses({ min: 200, max: 299 }, 409, 410));

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-arrival-rate',
      startRate: 0,
      timeUnit: '1s',
      preAllocatedVUs: 200,
      maxVUs: 1000,
      stages: [
        { target: 300, duration: '30s' },
        { target: 300, duration: '5m' },
        { target: 0, duration: '30s' },
      ],
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<500'],
    http_req_failed: ['rate<0.01'],
  },
};

const BASE = __ENV.BASE_URL;
const EVENT = __ENV.EVENT_ID || 'evt-local';
const TOKEN = __ENV.TOKEN;

export default function () {
  // 같은 사용자 토큰 → 대부분 409(중복). 그래도 JWT 검증 + Redis 조회로 CPU 부하는 생긴다
  const res = http.post(`${BASE}/api/events/${EVENT}/answers`, JSON.stringify({ answer: 'A' }),
    { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` } });
  check(res, { 'accepted|ok|dup|closed': (r) => [200, 202, 409, 410].includes(r.status) });
}
