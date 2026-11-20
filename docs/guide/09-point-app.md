# 9단계. point 앱 배포 (monolith, event-service, web)

## 목표
LOCAL-DEV.md 의 데모 시나리오(퀴즈 당첨 → Kafka → 원장 반영)를 **EKS + ALB** 에서 재현한다.

```
인터넷(내 IP) → ALB (Gateway point-gw)
                 ├ /api/events/** → Service event-service → 파드 :8081 → Redis(ElastiCache), Kafka(Strimzi)
                 ├ /api/**        → Service monolith      → 파드 :8080 → RDS, Kafka 소비
                 └ /              → Service web           → 파드 :8080 (nginx, 정적 파일)
```

> 아직 실습 전 작성한 가이드. "⚠️ 확인" 은 진행 시 갱신.

## ⚠️ ROADMAP 과 달라진 점 (point-backend 현재 코드 기준)
1. **`X-User-Id` 헤더 인증은 없어졌다.** 지금은 JWT(RS256)다. monolith `/api/auth/login` 으로 토큰을 받아 `Authorization: Bearer` 로 호출한다. ROADMAP 9단계의 `curl -H "X-User-Id: 1"` 은 동작하지 않는다.
2. **데모 데이터와 데모 이벤트는 `local` 프로필에서만** 생긴다.
   - monolith: `db/local` Flyway 시드 (demo1~5@point.local / `demo1234!`, user 1 = 1,000P)
   - event-service: `LocalEventAdminController` (`@Profile("local")`) — 기동 시 `evt-local` 생성, `/api/events/{id}/open`, `/status`
   - `aws` 프로필(point-infra overlay 설정)로 띄우면 계정도 이벤트도 없어서 데모 시나리오를 못 돌린다.

→ **실습에서는 `SPRING_PROFILES_ACTIVE=local` 로 띄우고, 접속 정보·JWT 키는 환경변수로 덮어쓴다.**
local 프로필이 바꾸는 건 (1) 데모 시드 (2) 데모 이벤트 API (3) 쿠키 Secure 끔 (4) admin 토큰 기본값 (5) JWT 키가 없을 때 임시 키 생성 — 이 중 (5)는 파드 2개 이상이면 파드마다 키가 달라져 토큰 검증이 깨지므로 **반드시 `JWT_PRIVATE_KEY` 를 8단계 Secret 으로 넣는다.**
운영 설계와 다른 점이므로 log 에 기록.

## 사전 상태
- 5단계: LB Controller + Gateway API CRD 설치됨
- 6단계: ECR 에 `point/monolith`, `point/event-service`, `point/web` 이미지
- 7단계: RDS(`app_rw` 생성), ElastiCache, Strimzi Kafka
- 8단계: `point` namespace 에 Secret `monolith-db`, `event-secrets`
- 노드 용량: 7단계 문서의 "노드 용량" 참고 (3대 이상 권장)

## 9-1. 디렉터리 (Kustomize)
```
k8s/apps/
├── base/
│   ├── monolith/        deployment.yaml  service.yaml  kustomization.yaml
│   ├── event-service/   deployment.yaml  service.yaml  kustomization.yaml
│   └── web/             deployment.yaml  service.yaml  kustomization.yaml
└── overlays/
    └── dev/
        ├── kustomization.yaml      ← 이미지 태그, ConfigMap, 패치
        ├── external-secrets.yaml   ← 8단계 ExternalSecret 2개
        └── gateway.yaml            ← LoadBalancerConfiguration, TGC×3, GatewayClass, Gateway, HTTPRoute
```
base 는 `../point-infra/k8s/base/{monolith,event-service}` 를 참고해 쓰되 아래를 바꾼다.

## 9-2. base

**`base/monolith/deployment.yaml`** (point-infra base 에서 변경: secretRef 유지, startupProbe 추가)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monolith
  labels: { app: monolith }
spec:
  replicas: 2
  strategy:
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }
  selector:
    matchLabels: { app: monolith }
  template:
    metadata:
      labels: { app: monolith }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 10001 }
      containers:
        - name: monolith
          image: monolith            # overlay 의 images 로 치환
          ports: [{ containerPort: 8080 }]
          envFrom:
            - configMapRef: { name: monolith-config }
            - secretRef: { name: monolith-db }      # 8단계 ESO 가 생성
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
**`base/monolith/service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: monolith
spec:
  selector: { app: monolith }
  ports: [{ port: 80, targetPort: 8080 }]
```
**`base/monolith/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [deployment.yaml, service.yaml]
```

**`base/event-service/deployment.yaml`** — point-infra base 와 같되 **`nodeSelector`/`tolerations` 는 빼 둔다** (Karpenter 노드가 아직 없음 → Pending. 10단계 overlay 패치로 추가). 차이점만:
```yaml
      containers:
        - name: event-service
          image: event-service
          ports: [{ containerPort: 8081 }]
          envFrom:
            - configMapRef: { name: event-config }
            - secretRef: { name: event-secrets }      # JWT_PUBLIC_KEY
          resources:
            requests: { cpu: 250m, memory: 768Mi }    # KEDA CPU 트리거가 이 requests 기준으로 % 계산
            limits:   { memory: 1Gi }
          startupProbe:
            httpGet: { path: /actuator/health/liveness, port: 8081 }
            periodSeconds: 5
            failureThreshold: 24
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: 8081 }
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: 8081 }
```
Service: `port: 80 → targetPort: 8081`.

**`base/web/deployment.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels: { app: web }
spec:
  replicas: 2
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      containers:
        - name: web
          image: web
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 25m, memory: 32Mi }
            limits:   { memory: 64Mi }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }   # point-frontend/nginx.conf 에 정의됨
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
```
Service: `port: 80 → targetPort: 8080`.

## 9-3. overlays/dev

**`overlays/dev/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: point
resources:
  - ../../base/monolith
  - ../../base/event-service
  - ../../base/web
  - external-secrets.yaml
  - gateway.yaml
configMapGenerator:
  - name: monolith-config
    literals:
      - SPRING_PROFILES_ACTIVE=local          # 데모 시드 (위 "달라진 점" 참고)
      - KAFKA_BOOTSTRAP=point-kafka-bootstrap.kafka.svc:9092
      - AUTH_COOKIE_SECURE=false              # ALB 가 HTTP 라 Secure 쿠키 불가
  - name: event-config
    literals:
      - SPRING_PROFILES_ACTIVE=local          # evt-local 자동 생성
      - REDIS_HOST=<terraform output -raw redis_endpoint>
      - REDIS_PORT=6379
      - KAFKA_BOOTSTRAP=point-kafka-bootstrap.kafka.svc:9092
      # JWT_PUBLIC_KEY 가 Secret 에 있으면 그게 우선 (SecurityConfig: public-key → jwk-set-uri 순)
images:
  - name: monolith
    newName: <계정>.dkr.ecr.ap-northeast-2.amazonaws.com/point/monolith
    newTag: v0.1.0
  - name: event-service
    newName: <계정>.dkr.ecr.ap-northeast-2.amazonaws.com/point/event-service
    newTag: v0.1.0
  - name: web
    newName: <계정>.dkr.ecr.ap-northeast-2.amazonaws.com/point/web
    newTag: v0.1.0
```
- `configMapGenerator` 는 이름 뒤에 내용 해시를 붙인다 (`monolith-config-7h2k...`) → 값이 바뀌면 Deployment 가 참조하는 이름도 바뀌어 **자동으로 롤링 재시작**.
- `images` 를 쓰면 base 는 레지스트리를 몰라도 된다. 11단계에서 CI 가 이 `newTag` 만 바꿔 커밋한다.

**`overlays/dev/gateway.yaml`** — 5단계 smoke 와 같은 구조, 백엔드 3개:
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
metadata: { name: monolith-tg }
spec:
  targetReference: { name: monolith }
  defaultConfiguration:
    targetType: ip
    healthCheckConfig: { healthCheckPath: /actuator/health/readiness }
---
apiVersion: gateway.k8s.aws/v1
kind: TargetGroupConfiguration
metadata: { name: event-service-tg }
spec:
  targetReference: { name: event-service }
  defaultConfiguration:
    targetType: ip
    healthCheckConfig: { healthCheckPath: /actuator/health/readiness }
---
apiVersion: gateway.k8s.aws/v1
kind: TargetGroupConfiguration
metadata: { name: web-tg }
spec:
  targetReference: { name: web }
  defaultConfiguration:
    targetType: ip
    healthCheckConfig: { healthCheckPath: /healthz }
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
      backendRefs: [{ name: monolith, port: 80 }]
    - matches: [{ path: { type: PathPrefix, value: / } }]
      backendRefs: [{ name: web, port: 80 }]
```
- Gateway API 규칙: 여러 매치가 겹치면 **더 긴 PathPrefix 가 우선** → 순서와 무관하게 `/api/events` 가 `/api` 보다 먼저 매칭. 그래도 읽기 쉽게 긴 것부터 쓴다.
- `/actuator/**` 는 경로에 없으므로 외부로 노출되지 않는다 (`/` → web 으로 감). 의도한 것.
- **GatewayClass 는 여기 넣지 않는다.** 클러스터 전역 리소스인데, kustomize 는 CRD 의 scope 를 몰라서 `namespace: point` 를 붙여 버린다. 플랫폼 소유이기도 하므로 따로 둔다:
  ```yaml
  # k8s/platform/gateway/gatewayclass.yaml  (5단계에서 지웠으면 다시 apply)
  apiVersion: gateway.networking.k8s.io/v1
  kind: GatewayClass
  metadata: { name: aws-alb }
  spec:
    controllerName: gateway.k8s.aws/alb
  ```

## 9-4. 배포
```bash
cd ~/point/point-private
kubectl apply -f k8s/platform/gateway/gatewayclass.yaml
kubectl kustomize k8s/apps/overlays/dev | less        # 렌더링 결과 먼저 읽기
kubectl apply -k k8s/apps/overlays/dev
kubectl get externalsecret,secret -n point
kubectl get pods -n point -w                          # monolith 기동 ≈ 1~2분 (Flyway)
kubectl logs -n point deploy/monolith | grep -i -E 'flyway|Started|ERROR'
kubectl get gateway -n point point-gw                 # ADDRESS
```

## ✅ 확인 (LOCAL-DEV.md 4절 시나리오)
```bash
ALB=$(kubectl get gateway -n point point-gw -o jsonpath='{.status.addresses[0].value}')

# 1) 로그인 → access token
TOKEN=$(curl -s -X POST http://$ALB/api/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"demo1@point.local","password":"demo1234!"}' | jq -r .data.accessToken)

# 2) 잔액 1,000P
curl -s http://$ALB/api/points/balance -H "Authorization: Bearer $TOKEN" | jq

# 3) 이벤트 상태 (local 프로필 전용 API, 인증 불필요)
curl -s http://$ALB/api/events/evt-local/status | jq

# 4) 퀴즈 참여 → 202 당첨
curl -s -X POST http://$ALB/api/events/evt-local/answers \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"answer":"A"}' | jq

# 5) 1~2초 뒤 잔액 1,500P (event-service → Kafka → monolith → RDS)
sleep 2; curl -s http://$ALB/api/points/balance -H "Authorization: Bearer $TOKEN" | jq
```
- 같은 사용자로 다시 참여 → 409 "이미 참여", demo2~4 로 참여 → 4번째 410 "마감".
- 브라우저: `http://$ALB` → 로그인 → 퀴즈 탭 → 잔액 갱신 확인.
- Kafka 메시지 직접 보기:
  ```bash
  kubectl run -it --rm kc --image=apache/kafka:3.8.0 --restart=Never -- \
    /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server point-kafka-bootstrap.kafka.svc:9092 \
    --topic point.reward.requested --from-beginning
  ```

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| monolith `CrashLoopBackOff`, `Connection refused/timeout :5432` | RDS SG / `DB_URL` 엔드포인트 |
| `FATAL: no pg_hba.conf entry ... no encryption` | `DB_URL` 에 `?sslmode=require` 누락 |
| Flyway `permission denied for database point` | 7단계 `GRANT CREATE ON DATABASE` 누락 |
| `JWT_PRIVATE_KEY ... 설정되지 않았습니다` | Secret 키 이름 / ESO 동기화 상태 |
| event-service 401 | 토큰 서명 키 불일치 — monolith 의 개인키와 event 의 공개키가 같은 쌍인지 |
| 당첨인데 잔액 안 바뀜 | monolith 로그 `reward applied`, Kafka bootstrap 주소, consumer 그룹 |
| ALB 503 | target-health unhealthy → readiness 경로/startupProbe 시간 |
| 파드 Pending | 노드 용량 부족 → `kubectl describe pod` Events, 노드 추가 |
| `ImagePullBackOff` | overlay `images.newName`/`newTag` 오타 |

## 🧹 정리
```bash
kubectl delete -k k8s/apps/overlays/dev      # Gateway 삭제 → ALB 삭제
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'   # 비었는지
```
그 다음 7 → 6 단계 리소스 순서로 terraform destroy (8단계 Secrets Manager 는 수동 삭제).
