# 12단계. 관측성 (메트릭)

## 목표
10단계 부하 테스트 중 **파드 수 / 노드 수 / CPU / RPS / 응답시간**을 그래프로 본다.

설계 (`../point-infra/docs/05-operations/observability.md`):
| 신호 | 운영 설계 | 이번 실습 |
|---|---|---|
| Metrics | kube-prometheus-stack + Micrometer → Grafana | ✅ 진행 |
| Logs | Fluent Bit → CloudWatch Logs | 생략 (`kubectl logs`) — 아래 "로그" 참고 |
| 관리형 지표 | CloudWatch (RDS, ElastiCache) → Grafana CloudWatch datasource | 생략 |

> 2026-11-23 실제로 진행한 결과를 반영한 문서. kube-prometheus-stack **93.9.0** (operator v0.95.2, Prometheus v3.16.0, Grafana 13.3.1). **11단계 ArgoCD 로 설치.**

방식 선택:
| | A. CloudWatch Container Insights | **B. kube-prometheus-stack (선택)** |
|---|---|---|
| 설치 | EKS 애드온 1개 | Helm 차트 1개 (+ ServiceMonitor) |
| 클러스터 부하 | 작음 (DaemonSet 에이전트) | 큼 (Prometheus 1Gi+, Grafana, 노드당 exporter) |
| 비용 | 지표·로그 수집량만큼 CloudWatch 과금 | 클러스터 자원만 |
| 앱 지표(Spring) | 별도 설정 | `/actuator/prometheus` 바로 수집 |
| 설계와 일치 | 로그 쪽 | 메트릭 쪽 |

## 12-1. 용량과 비밀번호
- 용량: 11단계에서 core 노드를 **3대**로 늘려 둠 ([11-2](11-argocd.md#11-2-용량--core-노드-2--3대)).
- Grafana 관리자 비밀번호는 **Git 에 넣지 않는다** → 차트의 `grafana.admin.existingSecret` 으로 직접 만든 Secret 을 쓰게 한다:
  ```bash
  kubectl create namespace monitoring
  (umask 077; openssl rand -hex 12 > ~/.config/point-dev/grafana_admin_password)     # 레포 밖, 600
  kubectl create secret generic grafana-admin -n monitoring \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(cat ~/.config/point-dev/grafana_admin_password)"
  ```

### 문제 ① — Grafana 로그인 실패 (`Invalid username or password`)
- 처음엔 `--from-file=admin-password=<파일>` 로 만들었다 → **파일 끝 줄바꿈까지 값에 들어감** (24자 비밀번호가 25바이트).
  ```bash
  kubectl get secret -n monitoring grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d | wc -c   # 25 → 문제, 24 → 정상
  ```
- 해결: `--from-literal="$(cat 파일)"` (`$(...)` 가 끝 줄바꿈을 제거) 로 다시 만들고 `kubectl rollout restart -n monitoring deploy/kps-grafana`.
- Grafana 는 관리자 비밀번호를 **첫 기동 때 DB 에 저장**한다. 이번 구성은 영속 볼륨이 없어서 재시작하면 DB 가 새로 만들어져 새 값이 적용됐다 (PVC 를 쓰면 `grafana-cli admin reset-admin-password` 필요).

## 12-2. 설치 — ArgoCD Application
**[`k8s/platform/monitoring/values.yaml`](../../k8s/platform/monitoring/values.yaml)**
```yaml
prometheus:
  prometheusSpec:
    retention: 1d
    resources:
      requests: { cpu: 200m, memory: 1Gi }
      limits:   { memory: 1536Mi }
    # 모든 namespace 의 ServiceMonitor/PodMonitor 를 release 라벨 상관없이 수집
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
alertmanager:
  enabled: false
grafana:
  admin:
    existingSecret: grafana-admin
  sidecar:
    dashboards:
      searchNamespace: ALL                  # grafana_dashboard=1 라벨 ConfigMap 을 모든 ns 에서
kube-state-metrics:
  # 노드 라벨 중 이것만 kube_node_labels 로 노출 → Karpenter 노드 수를 셀 수 있다
  metricLabelsAllowlist:
    - nodes=[workload,karpenter.sh/capacity-type,node.kubernetes.io/instance-type]
# EKS 컨트롤플레인은 AWS 관리 → 수집 불가. 켜 두면 타겟이 항상 DOWN
kubeEtcd: { enabled: false }
kubeControllerManager: { enabled: false }
kubeScheduler: { enabled: false }
kubeProxy: { enabled: false }               # EKS kube-proxy 는 metrics 를 127.0.0.1 에만 엶
```
- `serviceMonitorSelectorNilUsesHelmValues: false` 가 없으면 Prometheus 는 `release: kps` 라벨이 붙은 ServiceMonitor 만 본다 → 앱 지표가 안 잡히는 가장 흔한 원인.
- `metricLabelsAllowlist` 가 없으면 kube-state-metrics 는 노드 라벨을 노출하지 않아 `kube_node_labels{label_workload="event"}` 가 비어 있다.

**[`k8s/argocd/apps/monitoring.yaml`](../../k8s/argocd/apps/monitoring.yaml)** — 11단계 multi-source 패턴, wave -2 (ServiceMonitor CRD 를 point-dev 보다 먼저):
```yaml
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: 93.9.0
      helm:
        releaseName: kps
        valueFiles: [$values/k8s/platform/monitoring/values.yaml]
    - repoURL: https://github.com/<계정>/point-private.git
      targetRevision: master
      ref: values
  destination: { server: https://kubernetes.default.svc, namespace: monitoring }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true, CreateNamespace=true]   # CRD 가 커서 SSA 필수
```
설치 흐름 (push 후 약 1분 반): admission-create Job(Helm hook → ArgoCD PreSync 로 매핑) → CRD → operator → Prometheus → Grafana.
- Grafana 이미지가 488MB 라 pull 에 38초 → 그동안 Application 이 잠깐 `Degraded` 로 보였다가 `Healthy`. 일시적.
```bash
kubectl get pods -n monitoring   # grafana(3/3), operator, kube-state-metrics, node-exporter×노드 수, prometheus-...-0 (2/2)
kubectl get svc -n monitoring    # kps-grafana:80, kps-kube-prometheus-stack-prometheus:9090
```

## 12-3. 앱 지표 수집 (ServiceMonitor)
point-backend 는 이미 `management.endpoints.web.exposure.include: health,info,prometheus` → `/actuator/prometheus` 가 열려 있다.

**base Service 3개 수정** — 포트 **이름**과 `app` **라벨** (ServiceMonitor 는 Service 라벨로 찾고, 포트를 이름으로 참조):
```yaml
metadata:
  name: core-service             # 11-26 monolith → core-service
  labels: { app: core-service }
spec:
  selector: { app: core-service }
  ports: [{ name: http, port: 80, targetPort: 8080 }]
```
**[`k8s/apps/overlays/dev/servicemonitor.yaml`](../../k8s/apps/overlays/dev/servicemonitor.yaml)** (kustomization `resources` 에 추가)
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: point-backend
spec:
  selector:
    matchExpressions:
      - { key: app, operator: In, values: [core-service, event-service] }
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s
```

**응답시간 p95 를 위한 히스토그램** (기본은 count/sum/max 만 → 백분위수 계산 불가). overlay 의 두 ConfigMap 에 추가:
```
MANAGEMENT_METRICS_DISTRIBUTION_PERCENTILESHISTOGRAM_HTTP_SERVER_REQUESTS=true
```

### 문제 ② — core-service(당시 monolith)·event-service 새 파드 CrashLoopBackOff
처음엔 `..._PERCENTILES_HISTOGRAM_HTTP_SERVER_REQUESTS=true` 로 썼다:
```
Failed to bind properties under 'management.metrics.distribution.percentiles.histogram.http.server.requests' to double[]:
    Reason: failed to convert java.lang.String to double (... For input string: "true")
```
- 원인: 환경변수의 `_` 는 `.` 이 된다 → `percentiles-histogram`(boolean) 이 아니라 **`percentiles`(double[])** 맵의 `histogram.http.server.requests` 키로 해석.
- 해결: Spring relaxed binding 규칙 — **하이픈이 든 속성은 하이픈을 빼고** 쓴다 → `PERCENTILESHISTOGRAM`. (9단계 `APP_ADMIN_APITOKEN` 과 같은 규칙: `api-token` → `APITOKEN`)
- 피해 없음: `maxUnavailable: 0` 이라 기존 파드가 계속 서비스했다. 고친 커밋 push → ArgoCD 가 1분 내 반영 → 롤링 완료.

### 확인
```bash
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/targets 또는 API:
curl -s 'http://localhost:9090/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | select(.labels.namespace=="point") | "\(.labels.job) \(.labels.pod) \(.health)"'
curl -s 'http://localhost:9090/api/v1/targets?state=active' | jq '[.data.activeTargets[] | select(.health!="up")] | length'
```
결과 (11-23, monolith 시절 — 지금은 job 이름이 `core-service`):

| 확인 | 결과 |
|---|---|
| point 타겟 | monolith ×2, event-service ×1 — 전부 `up` |
| DOWN 타겟 | **0** (컨트롤플레인 수집을 끈 덕분) |
| `http_server_requests_seconds_bucket` | monolith 207 시리즈, event-service 138 시리즈 |
| `kube_node_labels` by workload | core 3, event 1 |

### 11-26 — Kafka 지표 대신 Redis Stream 소비 확인
Kafka 를 뺐으므로 `kafka_consumer_*` 지표(spring-kafka)는 없다. core-service 의 Stream 소비는 Redis 클라이언트(Lettuce) 지표와 로그로 본다:
```bash
# core-service 의 Lettuce 명령 지표 (XREADGROUP 등) — ⚠️ 확인: Spring Boot 4 에서 지표 이름이 lettuce_command_* 인지 적용 후 기록
curl -s --get 'http://localhost:9090/api/v1/query' --data-urlencode 'query=count({namespace="point",job="core-service",__name__=~"lettuce_.*"})' | jq -r '.data.result[0].value[1]'
kubectl logs -n point -l app=core-service --since=10m | grep -cE 'reward applied'                     # 반영 건수
kubectl logs -n point -l app=core-service --since=10m | grep -E 'reward (stream read|apply) failed|DLQ'  # 없어야 정상
```
pending·lag 는 Valkey 에서 직접 본다 (7단계 확인 5번, `tests/run.sh 07`).

## 12-4. 대시보드 — 코드로 ([`k8s/platform/monitoring/dashboards/point-scaling.yaml`](../../k8s/platform/monitoring/dashboards/point-scaling.yaml))
Grafana UI 에서 만들고 Export 하는 대신, **ConfigMap 으로 커밋** → Grafana 사이드카가 `grafana_dashboard: "1"` 라벨을 보고 자동으로 불러온다. 11단계 `platform-config` Application 의 `include` 에 `monitoring/dashboards/*.yaml` 추가.
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-point-scaling
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  point-scaling.json: |
    { "uid": "point-scaling", "title": "point — 이벤트 확장 (10단계 부하 테스트)", "panels": [ ... ] }
```
패널 (datasource uid `prometheus` — 차트가 만드는 기본 데이터소스):
| 패널 | PromQL |
|---|---|
| 파드 (Ready) vs HPA 목표 | `count(kube_pod_status_ready{namespace="point",pod=~"event-service-.*",condition="true"})`, `kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="keda-hpa-event-service"}` |
| 노드 수 | `count by (label_workload, label_karpenter_sh_capacity_type) (kube_node_labels)` |
| CPU (requests 대비 %) | `sum(rate(container_cpu_usage_seconds_total{namespace="point",container="event-service"}[1m])) / sum(kube_pod_container_resource_requests{namespace="point",container="event-service",resource="cpu"}) * 100` |
| RPS (상태코드별) | `sum by (status) (rate(http_server_requests_seconds_count{namespace="point",service="event-service",uri!~"/actuator.*"}[1m]))` |
| p50/p95/p99 | `histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{namespace="point",service="event-service",uri!~"/actuator.*"}[1m])))` |
| JVM heap | `sum by (pod) (jvm_memory_used_bytes{namespace="point",area="heap"})` |
- `uri!~"/actuator.*"` — Prometheus 수집·probe 요청이 RPS/지연을 왜곡하지 않게 제외.
- CPU 패널은 HPA 와 같은 기준(requests 대비 %)으로 그려서 목표 60% 와 직접 비교.
- 기본 대시보드도 쓸 만하다: "Kubernetes / Compute Resources / Namespace (Pods)" → `point`.

```bash
kubectl port-forward -n monitoring svc/kps-grafana 3000:80      # http://localhost:3000 (admin / ~/.config/point-dev/grafana_admin_password)
curl -s -u admin:$(cat ~/.config/point-dev/grafana_admin_password) 'http://localhost:3000/api/search?query=point' | jq     # uid point-scaling
```

## ✅ 확인 — 부하 테스트를 다시 돌리며 (14:58:24 ~ 15:04:25 KST)
10단계와 같은 k6 스크립트·demo5 토큰. k6: 98,464 건, 실패 0%, **p95 47.4ms**.
Prometheus `query_range` (step 30s) 로 대시보드 쿼리를 그대로 뽑은 값 (1분 간격):
| 시리즈 | 값 (1분 간격) | 최대 |
|---|---|---|
| event-service Ready 파드 | 1 → 1 → 2 → 4 → 7 → 7 → 7 → 8 → 11 | 11 |
| HPA desired | 1 → 1 → 2 → 7 → 7 → 7 → 7 → 11 → 11 | 11 |
| event 노드 | 1 → 1 → 1 → 2 → 2 → 2 → 2 → 3 → 3 | 3 (core 는 3 고정) |
| CPU (requests 대비 %) | 3 → 2 → **169** → 50 → 15 → 1 → **97** → 35 | 169% (부하 시작 직후) |
| RPS (409) | 69 → 264 → 292 → 288 → 289 → 292 → 70 | 308 |
| 서버 측 p95 | 6.8 → 12 → 5.4 → 8.4 → 5.4 → 13 → 3.7 ms | 13ms |

10단계에서 기대했던 모습과 대조:
- ✅ **파드 수가 계단식으로** 오르고 HPA desired 를 Ready 가 약 30초~1분 뒤 따라간다 (노드가 필요한 파드는 노드 Ready 33초 + 기동).
- ✅ **노드 수가 파드를 뒤따라** 1 → 2 → 3.
- ✅ CPU 가 목표 60% 를 크게 넘자(169%) 바로 확장, 파드가 늘자 50% → 15% 로 떨어짐.
- ⚠️ 부하 후반(15:03)에 CPU 가 다시 97% → 11개로 한 번 더 확장. 원인은 **확인하지 못했다** (CPU 시리즈 중간의 1% 구간은 metrics 수집 공백일 가능성도 있음). 다음에 Grafana 로 파드별 CPU·JVM GC 를 같이 보며 확인할 것.
- 💡 **서버 측 p95(≤13ms) vs k6 p95(47ms)** — 차이 ≈ 집 → 서울 리전 네트워크 + ALB. 서버는 확장 중에도 느려지지 않았다 → 지연의 대부분은 앱 밖. 이것이 "클라이언트 지표와 서버 지표를 둘 다 봐야 하는" 이유.
- 응답이 전부 409 인 것: demo5 는 첫 부하 테스트에서 이미 참여 → 중복. 부하 경로(JWT 검증 + Redis 조회)는 동일.

## 로그 (생략한 부분)
- 이번엔 `kubectl logs` 로 충분했다 (9~12단계의 문제 원인을 전부 로그에서 찾음).
- 운영 설계대로 하려면 A 안의 `amazon-cloudwatch-observability` 애드온 (Fluent Bit 포함) 또는 Loki 를 추가한다:
  ```hcl
  # envs/dev/cloudwatch.tf — Pod Identity 패턴
  resource "aws_iam_role" "cw_agent" {
    name               = "${local.name}-cloudwatch-agent"
    assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  }
  resource "aws_iam_role_policy_attachment" "cw_agent" {
    role       = aws_iam_role.cw_agent.name
    policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  }
  resource "aws_eks_pod_identity_association" "cw_agent" {
    cluster_name    = module.eks.cluster_name
    namespace       = "amazon-cloudwatch"
    service_account = "cloudwatch-agent"
    role_arn        = aws_iam_role.cw_agent.arn
  }
  # modules/eks addons 에: amazon-cloudwatch-observability = {}
  ```
  💸 Container Insights 는 관측 대상 수·로그 GB 로 과금. **로그 그룹은 애드온을 지워도 남는다** → 수동 삭제.

## 자주 막히는 곳
| 증상 | 원인 / 해결 |
|---|---|
| 앱 타겟이 Prometheus 에 없음 | `serviceMonitorSelectorNilUsesHelmValues: false`, Service 의 `app` 라벨, 포트 이름 `http` |
| `kube_node_labels` 에 `label_workload` 없음 | kube-state-metrics `metricLabelsAllowlist` |
| `histogram_quantile` 결과 없음 | 히스토그램 비활성 → `..._PERCENTILESHISTOGRAM_...=true` |
| 앱 기동 실패 `to double[] ... "true"` | 환경변수 이름에 `PERCENTILES_HISTOGRAM` (하이픈 자리 `_`) → `PERCENTILESHISTOGRAM` (문제 ②) |
| Grafana 로그인 실패 | Secret 값 끝 줄바꿈 (`--from-file`) (문제 ①) |
| kubeEtcd / scheduler 타겟 DOWN | EKS 는 수집 불가 → values 에서 끔 |
| Application `metadata.annotations: Too long` | `ServerSideApply=true` |
| 대시보드가 안 보임 | ConfigMap 라벨 `grafana_dashboard: "1"`, 사이드카 `searchNamespace` |

## 🧹 정리
ArgoCD 가 관리하므로 11단계 정리 순서를 따른다 (root → Application 제거 → 리소스 정리). monitoring 만 따로 지운다면:
```bash
kubectl delete application monitoring -n argocd            # finalizer 없음 → 리소스는 남음 (11단계 정리 참고)
helm template kps prometheus-community/kube-prometheus-stack --version 93.9.0 -n monitoring \
  -f k8s/platform/monitoring/values.yaml | kubectl delete -f - --ignore-not-found
kubectl delete ns monitoring
kubectl get crd -o name | grep monitoring.coreos.com | xargs kubectl delete     # CRD 는 별도로 남는다
```
클러스터째 `terraform destroy` 하면 전부 사라진다 (EBS 를 쓰지 않으므로 잔여 볼륨 없음 — Prometheus·Grafana 모두 emptyDir).
`~/.config/point-dev/grafana_admin_password` 는 다음에 재사용하거나 삭제.
