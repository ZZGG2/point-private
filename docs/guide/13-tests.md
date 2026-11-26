# 13. 전체 단계 검증 스위트 (`tests/`)

0~12단계에서 만든 것이 **지금도 설계대로 동작하는지** 한 번에 확인한다.
각 단계 문서의 "✅ 확인"을 자동화했고, 실습 중에 겪은 문제(재발 방지)와 보안 경계까지 검사한다.

```bash
cd ~/point/point-private
tests/run.sh                 # 0~12단계 + 비용 점검 (기본: 읽기 위주 + 가벼운 E2E) ≈ 6분
tests/run.sh 07 09           # 특정 단계만
tests/run.sh --heavy         # + 부하 → HPA/Karpenter 확장, ArgoCD selfHeal ≈ 8분
tests/run.sh --no-e2e        # 9단계 E2E(테스트 이벤트 생성·당첨 → 잔액 자동 반영) 생략
SKIP_PLAN=1 tests/run.sh 01  # terraform plan(drift 검사, ≈1분) 생략
```
- 결과: 콘솔에 `PASS / FAIL / WARN / SKIP`, 마크다운 리포트는 `tests/reports/report-<시각>.md` (`.gitignore` — 엔드포인트 등 환경 정보 포함).
- 종료 코드: FAIL 이 있으면 1 → CI 나 정리 전 점검에 그대로 쓸 수 있다.
- **WARN** = 동작은 하지만 알아 둘 것 (설계와 다름, 일시적 상태, 비용). **FAIL** = 설계가 깨짐.

## 구조
```
tests/
├── run.sh               # 인자 처리, 단계 순서대로 source, 요약·리포트
├── lib.sh               # ok/ng/warn/skip, eq/ge/match, tfo(terraform output 캐시),
│                        # kpod(클러스터 안 1회성 파드: run → wait → logs → delete), pf_start(port-forward)
├── steps/00-prep.sh … 12-observability.sh, 99-inventory.sh
└── reports/             # 실행 결과 (git 제외)
```
- 클러스터 안 테스트 파드는 `default` namespace 에 `t-<시각>-<이름>` 으로 뜨고, 라벨 `app.kubernetes.io/part-of=point-tests` → 끝나면(중단해도) 일괄 삭제.
- 비밀값은 출력하지 않는다. 비교가 필요한 값(DB 비밀번호, JWT 키쌍)은 **해시나 파이프 안에서만** 비교.
- 새 검사를 추가하려면 해당 `steps/NN-*.sh` 에 `eq "설명" "$(실제값 명령)" "기대값"` 한 줄.

## 단계별 검사 항목
| 단계 | 주요 검사 |
|---|---|
| 00 준비 | 도구 9개, Terraform ≥ 1.10, AWS 자격증명·리전, `origin/master` 동기화, `.gitignore` 항목, 추적 중인 민감 파일 0, **Git 히스토리 전체** 비밀값 패턴(개인키·AWS키·GitHub 토큰) 0, 로컬 비밀 파일 권한 600 |
| 01 state | 버킷 버전관리·암호화·퍼블릭 차단·리전, state 객체, `use_lockfile`, 잡힌 락 없음, **`terraform plan` drift 0** |
| 02 VPC | CIDR, 서브넷 9개·AZ 3개·태그(elb / internal-elb / karpenter discovery), NAT 1, IGW 1, S3 Gateway 엔드포인트가 App 라우트에 연결, App → NAT, **Data 서브넷 인터넷 경로 여부**, DB 서브넷 그룹 |
| 03 EKS | ACTIVE·1.37·인증모드 API, 엔드포인트 허용 CIDR = 내 IP (현재 IP 와도 비교), 애드온 5개 ACTIVE, 노드그룹 3/4/3·ON_DEMAND·health, kubectl 버전 차 ≤1, 노드 Ready, max pods 110(prefix delegation), DaemonSet, metrics API, **노드 SG 규칙**, 앱 포트 ≥1025, 비정상/재시작 많은 파드 |
| 04 smoke | (smoke 를 지웠으면 SKIP) probe·resources, 같은 노드 / 다른 노드에서 파드 접속 |
| 05 LBC | 2/2·v3.6.3, Pod Identity, values vpcId = 실제 VPC, Gateway API CRD v1.6.0, GatewayClass Accepted, error 로그, (smoke) ALB 200·SG |
| 06 ECR | IMMUTABLE·scan on push·lifecycle, `point/{core-service,event-service,web}` `v0.2.0`(`IMG_TAG`) 이미지·CRITICAL 취약점, **overlay 가 쓰는 태그가 ECR 에 있는지**, ImagePullBackOff 0 |
| 07 데이터 | RDS 16.15·비공개·암호화·Secrets Manager 비밀번호·`rds.force_ssl=1`·SG = 노드 SG:5432 만, **Valkey 복제 그룹**(engine valkey·노드 2·자동 장애 조치·Multi-AZ·Cluster mode 꺼짐·서로 다른 AZ·SG = 노드 SG:6379·output = primary 엔드포인트), **클러스터 안에서** app_rw 접속(DB·public 스키마 CREATE 권한, SSL 여부), SSL 없는 접속 거부, Flyway 이력, PING·`valkey_version` 7.2·role master + replica 1, **원장 반영 Stream**(`reward:streams` 등록·모든 Stream 에 group `point-ledger`·pending/lag 합계 0·DLQ 0) — 11-26 Kafka 검사 삭제 |
| 08 ESO | Secrets Manager 비밀·키, **IAM 정책 시뮬레이터로 허용/거부 4건**, ESO 3개·v2.15.0, ClusterSecretStore·ExternalSecret 3개 Synced, Secret 키(`core-service-db`, event-secrets 의 `ADMIN_API_TOKEN`)·DB_URL, K8s 값 == Secrets Manager 값(해시), **JWT 개인키 ↔ 공개키 같은 쌍**·PKCS#8·2048 |
| 09 앱 | Deployment 3개, local 프로필·기동, runAsNonRoot·startupProbe, Gateway·HTTPRoute, 타겟그룹 3개 healthy, ALB SG, **라우팅 3분기**, actuator 비노출, 401(무토큰·위조토큰·틀린 비번)·403(틀린 관리자 토큰), JWT RS256·iss·15분, 쿠키 Secure 없음·HttpOnly, 같은 토큰 10회(파드 2개 키 공유) |
| 09 E2E | 이벤트 생성 API 403(토큰 없음·틀림), **운영용 생성 API** 로 테스트 이벤트 `evt-test-<시각>` (재고 2, 100P, 30분 마감) → 같은 id 409, 열기 전 410 → 202 → 409 → 202 → 200(낙첨) → 상태 → **Redis Stream 경유 잔액 +100 자동 반영** → 낙첨자 불변 → **원장 이벤트당 1건·3초 뒤에도 불변 (멱등)**. 정산 API 404 (제거됨, ADR-0018). core-service `reward stream read failed` 로그 없음 |
| 10 확장 | SQS·EventBridge 5·노드 Access Entry·Spot SLR·Pod Identity, Karpenter 1.15.3·core 노드에 위치·ERROR 로그, NodePool(limits·taint)·EC2NodeClass(서브넷 3·SG·AMI), event 노드 = NodeClaim = EC2(고아 0), event 노드엔 event-service 만, Git 에 replicas 없음, KEDA·APIService, ScaledObject·HPA(1/20, CPU 수집) / `--heavy`: **250 RPS × 90초 → HPA·노드 확장** |
| 11 ArgoCD | 컴포넌트·v3.6.2, Helm 릴리스 = Terraform 소유 2개, Application 9개 각각 Synced/Healthy·automated·에러 없음, Git 최신 커밋, **`argocd app diff` 8개 = 0**, db-init Complete·PreSync·로그, 마스터 비밀은 앱 파드가 참조 안 함 / `--heavy`: **selfHeal** |
| 12 관측성 | 컴포넌트, node-exporter 전 노드, Alertmanager 꺼짐, retention, ServiceMonitor, DOWN 타겟 0, 타겟 수 = 파드 수, 히스토그램·p95·JVM·Lettuce(Stream 소비, 11-26 Kafka 대신)·노드 라벨·HPA·cAdvisor 지표, Grafana 비밀번호(줄바꿈 없음)·무인증 401·로그인·데이터소스 health·대시보드 6패널 **각 쿼리에 데이터** |
| 99 비용 | EC2·ALB·NAT·RDS·Redis·비밀 현황, 미연결 EBS·EIP 0, **Gateway 없는 고아 ALB·ALB 보안그룹** 0, 떠 있으면 과금 경고 |

## 실행 결과 (2026-11-23 15:31, `--heavy`)
**PASS 334 · FAIL 0 · WARN 4 · SKIP 2 · 7분 51초**

| 구분 | 내용 |
|---|---|
| SKIP 2 | smoke 앱 — 테스트용이라 지웠음 (아래) |
| WARN | 작업 트리 미커밋 (테스트 파일 작성 중) |
| WARN | 리소스 떠 있음 — 과금 중 (의도) |
| WARN | LBC error 로그 14건 — 전부 smoke Gateway 삭제 직후 재시도 오류 (`still in use`, SG 삭제 대기). 고아 SG 없음 확인 |
| **WARN (발견)** | **Data 서브넷이 App 라우트 테이블(→NAT)을 공유** — 아래 발견 ①, 이후 수정 |
| `--heavy` 확장 | k6 29,999 req, p95 48ms, 실패 0 / HPA 1 → 9 (첫 증가 48초) / NodeClaim 1 → 3 |
| `--heavy` selfHeal | `kubectl scale web` → 1초 만에 Git 값(2) |
| E2E | 당첨 → Kafka → 정산 대기 반영 327ms, 정산 후 잔액 +100, 재정산 멱등 (11-23 일괄 정산·Kafka 버전 — 11-24 부터 즉시 반영, 11-26 부터 Redis Stream 검사) |

### 테스트로 새로 드러난 것
**① Data 서브넷에 인터넷 경로가 있다 (2단계 설계와 다름) → ✅ 2026-11-23 16:08 수정함**
```
rtb-...-private  subnets = App 3개 + Data 3개   routes = 0.0.0.0/0 → nat-..., S3 pl → vpce-...
```
- terraform-aws-modules/vpc 는 `create_database_subnet_route_table = true` 가 아니면 database 서브넷을 private 라우트 테이블에 붙인다.
- 영향: RDS 는 퍼블릭 IP 가 없고 SG 가 노드 SG 만 허용하므로 **외부에서 들어오는 경로는 없다.** 다만 "Data 계층은 밖으로 나가는 경로도 없음"이라는 3-Tier 의도와 다르다 (예: 침해된 DB 가 외부로 유출하는 경로).
- 수정: `modules/vpc/main.tf` 에 `create_database_subnet_route_table = true` → plan `1 to add, 4 to change, 0 to destroy` → apply.
  ```
  point-dev-vpc-db       subnets=3  routes = 10.10.0.0/16→local, pl-(S3)→vpce-...      ← 0.0.0.0/0 없음
  point-dev-vpc-private  subnets=3  routes = 10.10.0.0/16→local, 0.0.0.0/0→nat-..., pl-(S3)→vpce-...
  ```
  재검증 `tests/run.sh 01 02 07 09` → PASS 102 · FAIL 0 · **WARN 0** (drift 0, app_rw·Redis·Kafka·E2E 정상). [02 문서](02-vpc.md)에도 반영.
- 처음 쓴 검사는 "이름에 db 가 들어간 라우트 테이블"을 찾았는데 그런 테이블이 없어서 **잘못 PASS** 했다 → "서브넷에 실제로 연결된 라우트 테이블" 기준으로 고쳤다. 검사도 검증이 필요하다.

**② 노드 간 파드 통신은 1025 이상 포트만 된다**
```
노드 SG 인바운드 (자기 자신에서):  tcp 1025-65535, tcp/udp 53   ← EKS 모듈 기본값
```
- smoke nginx(포트 80)는 **같은 노드에서만** 접속되고, 다른 노드의 파드에서 Service 로 접속하면 타임아웃이었다. 4단계 때는 우연히 같은 노드에서 시험해서 몰랐다.
- ALB 는 LB Controller 가 `80-8081 from ALB SG` 규칙을 따로 넣어서 동작한다.
- point 앱(8080/8081), Kafka(9092), Redis/RDS(별도 SG) 는 영향 없음 → 03 단계에 "앱 파드 포트 전부 ≥ 1025" 검사를 추가해 회귀를 막는다.
- 1024 이하 포트를 쓰는 앱을 올릴 거면 EKS 모듈 `node_security_group_additional_rules` 에 노드 간 규칙 추가 (또는 컨테이너 포트를 8080 등으로).

### 테스트 작성 중 고친 버그 (참고)
| 증상 | 원인 |
|---|---|
| 출력에 `0`, Deployment JSON 이 통째로 섞임 | 단계 스크립트의 변수 `D` 가 lib 의 색상 변수 `D` 를 덮어씀 → 색상 변수를 `_CD` 등으로 |
| K8s Secret ≠ Secrets Manager (FAIL) | `jq -r` 이 끝에 줄바꿈을 붙여 해시가 달라짐 → `jq -j` |
| Flyway 이력 FAIL | `bool_and()` 를 문자열로 합치면 `t` 가 아니라 `true` |
| smoke curl 이 빈 출력 | 테스트 버그가 아니라 발견 ② 였음 |

## 언제 돌리나
- **재시작 직후** (README 체크리스트 끝): 전부 PASS 면 이전 상태 복구 완료.
- **변경 후**: 해당 단계만 (`tests/run.sh 09`).
- **정리 전**: `tests/run.sh 99` 로 무엇이 과금 중인지 확인, **정리 후** 다시 `99` → EC2·ALB·고아 0 확인.

## smoke 앱 정리 (2026-11-23)
4~5단계 확인용 smoke 앱은 역할을 다해서 지웠다:
```bash
kubectl delete namespace smoke      # Deployment·Service·Gateway·HTTPRoute·LBC 설정 → ALB·타겟그룹·SG 삭제
```
- ⚠️ `kubectl delete -f k8s/smoke/` 로 지우면 안 된다 — `30-gateway.yaml` 에 클러스터 전역 **GatewayClass `aws-alb`** 가 들어 있어 point ALB 까지 영향. (지금 GatewayClass 는 `platform-config` Application 소유)
- 매니페스트(`k8s/smoke/`)는 4~5단계 기록으로 Git 에 남겨 둔다. 테스트 04 와 05 의 smoke 부분은 namespace 가 없으면 SKIP.
