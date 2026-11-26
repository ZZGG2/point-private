# 9단계. point 앱 배포 (core-service, event-service, web)

## 목표
LOCAL-DEV.md 의 데모 시나리오(퀴즈 당첨 → Redis Stream → 원장 반영)를 **EKS + ALB** 에서 재현한다.

```
인터넷(내 IP) → ALB (Gateway point-gw)
                 ├ /api/events/** → Service event-service → 파드 :8081 → Valkey: Lua 판정 + XADD event:{id}:rewards
                 ├ /api/**        → Service core-service  → 파드 :8080 → RDS, Valkey Stream 소비 (consumer group point-ledger)
                 └ /              → Service web           → 파드 :8080 (nginx, 정적 파일)
```

> 2026-11-23 실제로 진행한 결과를 반영한 문서.

> 🔄 **2026-11-26 변경 — point-infra 설계 반영 (아직 AWS 에 적용 전)**
> - **Kafka 제거 (ADR-0019):** 당첨 기록은 event-service Lua 가 판정과 같은 스크립트에서 Redis Stream 에 `XADD`, core-service 가 읽어 원장에 반영. Kafka bootstrap 설정은 지우고 **core-service 에도 `REDIS_HOST`** 를 넣는다
> - **monolith → core-service:** Deployment·Service·ConfigMap(`core-service-config`)·Secret(`core-service-db`)·이미지(`point/core-service`)·HTTPRoute. 메인 클래스 `CoreServiceApplication`, JWT `iss` = `point-core`
> - **운영용 이벤트 생성 API** `POST /api/events/admin/{id}` (`X-Admin-Token` = event-secrets 의 `ADMIN_API_TOKEN`). local 프로필의 `open` 은 데모용으로 남아 있다
> - 이미지 `v0.2.0` (Spring Boot 4.1, point-frontend 관리자 패널 조회 전용)
> - 아래 "실제 결과"(11-23)·문제 ①②는 당시(monolith·Kafka) 기록이다

> 🔄 **2026-11-24 변경 — 일괄 정산 제거 (point-infra ADR-0018).** 퀴즈 당첨도 출석처럼 Kafka → monolith 가 **원장에 바로 반영**한다 (1~2초).
> 관리자 정산 API(`/api/admin/events/{id}/settlement`)와 `X-Admin-Token` 은 없어졌다 → 아래 "달라진 점 3", "문제 ②", 실제 결과의 정산 행은 **11-23 당시 기록**이다.
> 이미지 `monolith`·`web` **v0.1.2** 부터 적용 (11-24 클러스터에서만 덮어씀: point-dev Application `spec.source.kustomize.images` — Git overlay 태그는 v0.1.0/v0.1.1 그대로).

## ⚠️ ROADMAP 과 달라진 점 (point-backend 현재 코드 기준)
1. **`X-User-Id` 헤더 인증은 없어졌다.** 지금은 JWT(RS256)다. core-service `/api/auth/login` 으로 토큰을 받아 `Authorization: Bearer` 로 호출한다.
2. **데모 데이터와 데모 이벤트는 `local` 프로필에서만** 생긴다.
   - core-service: `db/local` Flyway 시드 (demo1~5@point.local / `demo1234!`, user 1 = 1,000P)
   - event-service: `LocalEventAdminController` (`@Profile("local")`) — 기동 시 `evt-local` 생성 (재고 3, 마감 없음), `/api/events/{id}/open`. 현황 `/status` 와 운영용 생성 `/api/events/admin/{id}` 는 모든 프로필
3. ~~**당첨이 바로 잔액에 들어가지 않는다 — 정산 단계가 생겼다.**~~ (11-24 ADR-0018 로 철회 — 지금은 바로 들어간다) (당시 monolith 는 Kafka 메시지를 받으면 `reward staged for settlement` (대기 행)만 만들고,
   관리자 API `POST /api/admin/events/{id}/settlement` 를 호출해야 원장에 반영됐다 (point-backend `Makefile` 의 `make settle`).)

→ **실습에서는 `SPRING_PROFILES_ACTIVE=local` 로 띄우고, 접속 정보·JWT 키는 환경변수(8단계 Secret)로 덮어쓴다.**
local 프로필이 바꾸는 건 (1) 데모 시드 (2) 데모 이벤트 API (3) 쿠키 Secure 끔 (4) JWT 키가 없을 때 임시 키 생성. (11-23 에는 (5) admin 토큰 고정도 있었다 — 문제 ②, 지금은 없음)
(4)는 파드 2개 이상이면 파드마다 키가 달라져 토큰 검증이 깨지므로 **`JWT_PRIVATE_KEY` 를 Secret 으로 넣는다.**

## 사전 상태
- 5단계: LB Controller + Gateway API CRD, GatewayClass `aws-alb`
- 6단계: ECR 에 `point/{core-service,event-service,web}:v0.2.0` (linux/amd64)
- 7단계: RDS(`app_rw` + **public 스키마 권한**), ElastiCache Valkey 복제 그룹
- 8단계: `point` namespace, Secret `core-service-db`, `event-secrets`(JWT_PUBLIC_KEY, ADMIN_API_TOKEN)
- 노드 용량: t3.medium 2대로 충분했다 (11-23: monolith 768Mi×2 + event 768Mi + web + Kafka 1Gi + ESO 등 → 노드당 메모리 50~60%. 지금은 Kafka 1Gi 가 빠진다)

## 9-1. 디렉터리 (Kustomize)
```
k8s/
├── platform/gateway/gatewayclass.yaml       ← 클러스터 전역 (앱 overlay 에 넣지 않음)
└── apps/
    ├── base/
    │   ├── core-service/    deployment.yaml  service.yaml  kustomization.yaml
    │   ├── event-service/   deployment.yaml  service.yaml  kustomization.yaml
    │   └── web/             deployment.yaml  service.yaml  kustomization.yaml
    └── overlays/dev/
        ├── kustomization.yaml      ← namespace, 이미지 태그, ConfigMap, (10단계) 패치
        ├── external-secrets.yaml   ← 8단계 ExternalSecret 2개
        ├── gateway.yaml            ← LoadBalancerConfiguration, TGC×3, Gateway, HTTPRoute
        └── scaledobject.yaml       ← 10단계
```

## 9-2. base
point-infra base 를 참고하되: requests 를 노드 2대에 맞게 줄이고, `startupProbe` 추가, ServiceAccount/PDB 는 생략.

**[`base/core-service/deployment.yaml`](../../k8s/apps/base/core-service/deployment.yaml)**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: core-service
  labels: { app: core-service }
spec:
  replicas: 2
  strategy:
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }
  selector:
    matchLabels: { app: core-service }
  template:
    metadata:
      labels: { app: core-service }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 10001 }   # Dockerfile 의 USER 10001
      containers:
        - name: core-service
          image: core-service            # overlay 의 images 로 치환
          ports: [{ containerPort: 8080 }]
          envFrom:
            - configMapRef: { name: core-service-config }
            - secretRef: { name: core-service-db }      # 8단계 ESO 가 생성
          resources:
            requests: { cpu: 250m, memory: 768Mi }
            limits:   { memory: 1Gi }
          startupProbe:                              # Flyway + Spring 기동이 길어도 liveness 가 죽이지 않게
            httpGet: { path: /actuator/health/liveness, port: 8080 }
            periodSeconds: 5
            failureThreshold: 36                     # 최대 3분
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: 8080 }
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: 8080 }
          lifecycle:
            preStop: { exec: { command: ["sleep", "10"] } }   # ALB 타겟 해제 전에 트래픽 끊기지 않게
```
**`base/core-service/service.yaml`** — `port: 80 → targetPort: 8080`, selector `app: core-service`.
**`base/*/kustomization.yaml`** — 세 앱 모두 같음:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [deployment.yaml, service.yaml]
```

**[`base/event-service/deployment.yaml`](../../k8s/apps/base/event-service/deployment.yaml)** — core-service 와 구조가 같고 차이점만:
- **`replicas` 를 적지 않는다** → 기본 1. 10단계부터 KEDA(HPA)가 파드 수를 관리하는데, 매니페스트에 `replicas` 가 있으면 `apply` 할 때마다 되돌린다.
- **`nodeSelector`/`tolerations` 없음** → 지금은 core 노드에 뜬다. 10단계 overlay 패치로 Karpenter 노드에 보낸다.
- 포트 8081, `secretRef: event-secrets` (JWT_PUBLIC_KEY, ADMIN_API_TOKEN), `startupProbe.failureThreshold: 24`.
- Service: `port: 80 → targetPort: 8081`.

**[`base/web/deployment.yaml`](../../k8s/apps/base/web/deployment.yaml)**
```yaml
    spec:
      securityContext: { runAsNonRoot: true }       # nginx-unprivileged 이미지 (uid 101)
      containers:
        - name: web
          image: web
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits:   { memory: 64Mi }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }   # point-frontend/nginx.conf
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
```
`replicas: 2`, Service `port: 80 → targetPort: 8080`.

## 9-3. overlays/dev

**[`overlays/dev/kustomization.yaml`](../../k8s/apps/overlays/dev/kustomization.yaml)** (9단계 시점, 11-26 설계)
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: point
resources:
  - ../../base/core-service
  - ../../base/event-service
  - ../../base/web
  - external-secrets.yaml
  - gateway.yaml
configMapGenerator:
  - name: core-service-config
    literals:
      - SPRING_PROFILES_ACTIVE=local          # 데모 시드 (위 "달라진 점")
      - REDIS_HOST=<terraform output -raw redis_endpoint>   # 원장 반영 Stream 을 읽는다 (ADR-0019)
      - REDIS_PORT=6379
      - REWARD_STREAM_ENABLED=true            # 기본값도 true. DR(gcp-dr) 에서만 false
      - AUTH_COOKIE_SECURE=false              # ALB 가 HTTP 라 Secure 쿠키 불가 (local 프로필도 false 라 중복이지만 명시)
  - name: event-config
    literals:
      - SPRING_PROFILES_ACTIVE=local          # evt-local 자동 생성
      - REDIS_HOST=<terraform output -raw redis_endpoint>   # core-service 와 같은 값
      - REDIS_PORT=6379
      # JWT_PUBLIC_KEY(Secret) 가 있으면 local 의 jwk-set-uri 보다 우선 (SecurityConfig)
images:
  - name: core-service
    newName: <계정>.dkr.ecr.ap-northeast-2.amazonaws.com/point/core-service
    newTag: v0.2.0
  - name: event-service
    newName: <계정>.dkr.ecr.ap-northeast-2.amazonaws.com/point/event-service
    newTag: v0.2.0
  - name: web
    newName: <계정>.dkr.ecr.ap-northeast-2.amazonaws.com/point/web
    newTag: v0.2.0
```
- Git 의 overlay 에는 `REDIS_HOST=CHANGE_ME_redis_primary_endpoint` 로 들어 있다 → 7단계 apply 뒤 **두 곳 모두** 실제 primary 엔드포인트로 바꾼다
- `configMapGenerator` 는 이름 뒤에 내용 해시를 붙인다 (`core-service-config-5f658mggkt`) → 값이 바뀌면 Deployment 가 참조하는 이름도 바뀌어 **자동으로 롤링 재시작**.
- `images` 를 쓰면 base 는 레지스트리를 몰라도 된다. 11단계에서 CI 가 이 `newTag` 만 바꿔 커밋한다.
- Redis 엔드포인트는 ElastiCache 를 다시 만들면 바뀐다 → 재시작 시 확인 (1노드 → 복제 그룹으로 바꿀 때도 바뀐다).

**[`overlays/dev/gateway.yaml`](../../k8s/apps/overlays/dev/gateway.yaml)** — 5단계 smoke 와 같은 구조, 백엔드 3개:
```yaml
apiVersion: gateway.k8s.aws/v1
kind: LoadBalancerConfiguration
metadata: { name: point-alb }
spec:
  scheme: internet-facing
  sourceRanges: ["<내IP>/32"]
---
apiVersion: gateway.k8s.aws/v1
kind: TargetGroupConfiguration
metadata: { name: core-service-tg }
spec:
  targetReference: { name: core-service }
  defaultConfiguration:
    targetType: ip
    healthCheckConfig: { healthCheckPath: /actuator/health/readiness }
---
# event-service-tg (/actuator/health/readiness), web-tg (/healthz) 도 같은 모양
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: point-gw }
spec:
  gatewayClassName: aws-alb
  infrastructure:
    parametersRef: { group: gateway.k8s.aws, kind: LoadBalancerConfiguration, name: point-alb }
  listeners:
    - { name: http, protocol: HTTP, port: 80 }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: point }
spec:
  parentRefs: [{ name: point-gw }]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /api/events } }]
      backendRefs: [{ name: event-service, port: 80 }]
    - matches: [{ path: { type: PathPrefix, value: /api } }]
      backendRefs: [{ name: core-service, port: 80 }]
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs: [{ name: web, port: 80 }]
```
- 이벤트 생성 API 가 `/api/admin` 이 아니라 **`/api/events/admin/{id}`** 인 이유: 이 라우트에서 `/api/events/**` 만 event-service 로 간다 (`/api/admin/**` 는 core-service)
- Gateway API 규칙: 여러 매치가 겹치면 **더 긴 PathPrefix 가 우선** → `/api/events` 가 `/api` 보다 먼저. 그래도 읽기 쉽게 긴 것부터 쓴다.
- `/actuator/**` 는 경로에 없다 → `/` 규칙으로 web 에 가서 SPA 의 index.html(200, text/html)이 나온다. 앱의 actuator 는 외부로 노출되지 않음 (확인함).

**GatewayClass 는 overlay 에 넣지 않는다.** 클러스터 전역 리소스인데, kustomize 는 CRD 의 scope 를 몰라서 `namespace: point` 를 붙여 버린다. 플랫폼 소유이기도 하므로 [`k8s/platform/gateway/gatewayclass.yaml`](../../k8s/platform/gateway/gatewayclass.yaml) 에 따로 둔다 (5단계 smoke 와 같은 내용 → `unchanged`).

## 9-4. 배포
```bash
cd ~/point/point-private
kubectl apply -f k8s/platform/gateway/gatewayclass.yaml
kubectl kustomize k8s/apps/overlays/dev | less        # 렌더링 결과 먼저 읽기 (namespace, 이미지, ConfigMap 해시)
kubectl apply -k k8s/apps/overlays/dev
kubectl rollout status -n point deploy/core-service
kubectl get pods -n point -o wide
kubectl logs -n point deploy/core-service | grep -E 'Migrating|Successfully applied|Started '
kubectl logs -n point deploy/core-service | grep 'reward stream read failed'   # 나오면 REDIS_HOST 확인 (없어야 정상)
kubectl get gateway -n point point-gw                 # ADDRESS, PROGRAMMED True
```

### 문제 ① — core-service(당시 monolith) `CrashLoopBackOff`: `permission denied for schema public`
```
Migrating schema "public" ...
ERROR: permission denied for schema public
Error creating bean with name 'flywayInitializer'
```
- 원인: **PostgreSQL 15 부터 `public` 스키마의 CREATE 권한이 PUBLIC(모든 사용자)에서 회수됐다.** 7단계에서는 `GRANT CREATE ON DATABASE` (새 스키마를 만들 권한)만 줬고, Flyway 는 `public` 스키마 **안에** 테이블을 만든다.
- 해결: 마스터 계정으로 한 줄 추가 (7단계 7-6 문서에도 반영함):
  ```bash
  cd ~/point/point-private/envs/dev
  RDS=$(terraform output -raw rds_endpoint)
  MASTER_PW=$(aws secretsmanager get-secret-value --secret-id "$(terraform output -raw rds_master_secret_arn)" \
    --query SecretString --output text | jq -r .password)
  kubectl run pg-grant -n default --restart=Never --image=postgres:16 --env PGPASSWORD="$MASTER_PW" --command -- \
    psql "host=$RDS user=point_admin dbname=point sslmode=require" -v ON_ERROR_STOP=1 \
    -c "GRANT USAGE, CREATE ON SCHEMA public TO app_rw;"
  kubectl wait pod/pg-grant --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s; kubectl logs pg-grant; kubectl delete pod pg-grant
  kubectl rollout restart -n point deploy/core-service
  ```
- 결과 (11-23): `Successfully applied 5 migrations` → `Started MonolithApplication in 9.9 seconds`. (지금은 `Started CoreServiceApplication`)

### ALB 준비
```bash
ALB=$(kubectl get gateway -n point point-gw -o jsonpath='{.status.addresses[0].value}')
curl -s http://$ALB/healthz          # ok
for tg in $(aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'point')].TargetGroupArn" --output text); do
  aws elbv2 describe-target-health --target-group-arn $tg --query 'TargetHealthDescriptions[].TargetHealth.State' --output text; done
# healthy healthy / healthy / healthy healthy   (core-service 2, event 1, web 2)
```

## ✅ 확인 (LOCAL-DEV.md 시나리오)
```bash
ALB=$(kubectl get gateway -n point point-gw -o jsonpath='{.status.addresses[0].value}')
login() { curl -s -X POST http://$ALB/api/auth/login -H 'Content-Type: application/json' \
  -d "{\"email\":\"$1\",\"password\":\"demo1234!\"}" | jq -r .data.accessToken; }
answer() { curl -s -o /dev/null -w '%{http_code}\n' -X POST http://$ALB/api/events/evt-local/answers \
  -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d '{"answer":"A"}'; }
TOKEN=$(login demo1@point.local)

# 1) 잔액 1,000P
curl -s http://$ALB/api/points/balance -H "Authorization: Bearer $TOKEN" | jq -c .data

# 2) 이벤트 상태 (모든 프로필, 인증 불필요) — 재고 3, endsAt null (local open 은 마감 없음)
curl -s http://$ALB/api/events/evt-local/status | jq -c .data

# 3) 퀴즈 참여: demo1 → 202 당첨, 다시 → 409 중복, demo2·3 → 202, demo4 → 200 (재고 소진 = 낙첨)
answer $TOKEN; answer $TOKEN
for u in 2 3 4; do answer $(login demo$u@point.local); done

# 4) 1초 안팎 뒤 잔액 1,500P — Redis Stream 경유 자동 반영 (ADR-0018·0019)
sleep 2
curl -s http://$ALB/api/points/balance -H "Authorization: Bearer $TOKEN" | jq -c .data     # 1500
kubectl logs -n point -l app=core-service --since=5m | grep 'reward applied'               # reason=QUIZ_REWARD
curl -s http://$ALB/api/points/history -H "Authorization: Bearer $TOKEN" | jq -c '.data[0]'  # EARN 500, referenceId evt-local

# 5) 운영용 이벤트 생성 API (event-day 런북 방식) — 토큰은 Secrets Manager 에서 바로 꺼내 쓰고 화면에 찍지 않는다
ADM=$(aws secretsmanager get-secret-value --secret-id point-dev/event-service --query SecretString --output text | jq -r .ADMIN_API_TOKEN)
ENDS=$(date -u -d '+30 min' +%Y-%m-%dT%H:%M:%SZ)
curl -s -X POST http://$ALB/api/events/admin/evt-demo-1 -H "X-Admin-Token: $ADM" -H 'Content-Type: application/json' \
  -d "{\"stock\":2,\"amount\":300,\"endsAt\":\"$ENDS\"}" | jq -c       # 201 CREATED, endsAt 포함
# 같은 id 다시 → 409 EVENT_ALREADY_EXISTS (한 번 쓴 id 는 재사용 불가), 토큰 없음 → 403
```

### 실제 결과 (2026-11-23, monolith·Kafka·일괄 정산 버전 v0.1.0 — 정산·Kafka 행은 지금과 다름)
| 확인 | 결과 |
|---|---|
| 로그인 | access token 발급 (monolith, Secret 의 개인키로 서명) |
| 잔액 (전) | `{"balance":1000}` |
| 상태 | `{"winners":0,"rewardAmount":500,"participants":0,"open":true,"remainingStock":3}` |
| 참여 demo1 / 재참여 / demo2 / demo3 / demo4 | **202** / **409** / 202 / 202 / **200** — 재고가 0이면 410 이 아니라 200(낙첨). 410 은 이벤트가 닫혔을 때(`CLOSED`) |
| 인증 없이 참여 | **401** (event-service 가 공개키로 검증 → monolith 키쌍 일치 확인) |
| Kafka → monolith | `reward staged for settlement key=evt-local:1 user=1 amount=500` (×3) |
| 정산 | `rowCount 3, totalAmount 1500, appliedNow 3` |
| 잔액 (후) | demo1 **1500**, demo2·3 500, demo4 0 |
| 정산 다시 호출 | `appliedNow 0, repaired true` — 멱등 (중복 지급 없음) |
| `/` | `<title>Point Platform</title>`, `/admin` → 200 (SPA 라우팅) |
| `/actuator/health` | web 의 index.html (앱 actuator 비노출) |

### 문제 ② — 관리자 토큰이 `local-admin-token` 으로 고정 (11-24 정산 API 제거로 지금은 해당 없음 — 11-26 `APP_ADMIN_APITOKEN` 매핑도 삭제)
처음엔 Secret 의 `ADMIN_API_TOKEN` 으로 정산 API 를 부르면 **403**, `local-admin-token` 이면 200 이었다.
- 원인: Spring 설정 우선순위.
  - `application.yml`: `app.admin.api-token: ${ADMIN_API_TOKEN:}` ← 환경변수는 이 **자리표시자**에만 들어감
  - `application-local.yml`: `app.admin.api-token: local-admin-token` ← **프로필 파일이 기본 파일보다 우선** → 덮어씀
- 해결: 속성 이름을 직접 가리키는 환경변수 **`APP_ADMIN_APITOKEN`** (relaxed binding: `.`→`_`, `-` 제거, 대문자)는 **모든 설정 파일보다 우선**한다.
  ExternalSecret 에 같은 값을 이 이름으로 하나 더 넣었다 ([external-secrets.yaml](../../k8s/apps/overlays/dev/external-secrets.yaml) 의 `data:`).
- 결과: Secret 토큰 200, `local-admin-token` 403.
- 같은 이유로 `JWT_PRIVATE_KEY` 는 문제없다 — local 프로필 파일이 `private-key` 를 덮어쓰지 않으므로.
- 교훈: **local 프로필을 클러스터에서 쓰면 "프로필 파일에 하드코딩된 값"을 하나하나 확인**해야 한다. 운영(`aws` 프로필)에선 생기지 않는 문제.

### 그 밖에 볼 것
- 브라우저: `http://$ALB` → 로그인 → 퀴즈 탭 → 잔액 갱신 확인.
- 보상 Stream 직접 보기 (7단계 run 패턴) — Kafka 콘솔 consumer 대신:
  ```bash
  REDIS=$(terraform -chdir=envs/dev output -raw redis_endpoint)
  kubectl run rs --restart=Never --image=redis:7-alpine --command -- sh -c \
    "redis-cli -h $REDIS xrange 'event:{evt-local}:rewards' - + ; redis-cli -h $REDIS xinfo groups 'event:{evt-local}:rewards'"
  sleep 10; kubectl logs rs; kubectl delete pod rs
  # 항목 필드: idempotencyKey, userId, eventId, amount, reason, occurredAt / group point-ledger 의 pending·lag 0 이면 다 반영
  ```
- 8단계 **회전 실험**은 이 시점(앱이 떠 있을 때)에 진행 → [08 문서](08-external-secrets.md#회전-실험-9단계-앱을-띄운-뒤-진행).
- 이벤트를 처음부터 다시: `curl -X POST "http://$ALB/api/events/evt-local/open?stock=3&amount=500"` (local 전용 초기화). 원장 데이터는 RDS 에 남고, 같은 사용자는 멱등키(`evt-local:<userId>`)가 같아 **다시 당첨돼도 원장에 안 들어간다** → 새로 확인하려면 운영 생성 API 로 새 id 를 쓴다.

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| core-service `CrashLoopBackOff`, `permission denied for schema public` | PG15+ → `GRANT USAGE, CREATE ON SCHEMA public TO app_rw` (문제 ①) |
| `Connection refused/timeout :5432` | RDS SG / `DB_URL` 엔드포인트 |
| `FATAL: no pg_hba.conf entry ... no encryption` | `DB_URL` 에 `?sslmode=require` 누락 |
| `JWT_PRIVATE_KEY ... 설정되지 않았습니다` | Secret 키 이름 / ESO 동기화 상태 |
| event-service 401 | 토큰 서명 키 불일치 — core-service 개인키와 event 공개키가 같은 쌍인지 |
| 당첨인데 잔액 안 바뀜 | core-service 로그 `reward applied` 가 있는지 → 없으면 `reward stream read failed`(REDIS_HOST) / `xinfo groups` 의 pending·lag / DLQ `reward:dlq`. `reward:streams` 에 그 이벤트 Stream 이 등록돼 있는지 |
| 이벤트 생성 API 403 | `event-secrets` 에 `ADMIN_API_TOKEN` 이 없거나, 비밀을 바꾼 뒤 event-service 를 재시작하지 않음 (8단계 회전 실험) |
| 이벤트 생성 API 409 | 이미 쓴 id. 새 id 로 |
| ALB 503 | target-health unhealthy → readiness 경로/startupProbe 시간 |
| 파드 Pending | 노드 용량 부족 → `kubectl describe pod` Events |
| `ImagePullBackOff` | overlay `images.newName`/`newTag` 오타 |

## 🧹 정리
```bash
kubectl delete -k k8s/apps/overlays/dev      # Gateway 삭제 → ALB 삭제 (ExternalSecret 삭제 → Secret 도 삭제)
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'   # point ALB 가 없는지
```
그 다음 7 → 6 단계 리소스 순서로 terraform destroy (8단계 Secrets Manager 는 수동 삭제).
10단계까지 진행했다면 **10단계 정리(Karpenter 노드)를 먼저.**
