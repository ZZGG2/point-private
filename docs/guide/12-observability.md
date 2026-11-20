# 12단계. 관측성 (메트릭, 로그)

## 목표
10단계 부하 테스트 중 **파드 수 / CPU / 응답시간**을 그래프로 본다.

설계 (`../point-infra/docs/05-operations/observability.md`):
| 신호 | 운영 설계 |
|---|---|
| Metrics | kube-prometheus-stack + Micrometer → Grafana |
| Logs | Fluent Bit → CloudWatch Logs |
| 관리형 지표 | CloudWatch (RDS, ElastiCache) → Grafana CloudWatch datasource |

> 아직 실습 전 작성한 가이드. "⚠️ 확인" 은 진행 시 갱신.

둘 중 하나로 시작한다.

| | A. CloudWatch Container Insights | B. kube-prometheus-stack |
|---|---|---|
| 설치 | EKS 애드온 1개 | Helm 차트 1개 (+ ServiceMonitor) |
| 클러스터 부하 | 작음 (DaemonSet 에이전트) | **큼** (Prometheus 1~2Gi, Grafana, 노드당 exporter) |
| 비용 | 지표·로그 수집량만큼 **CloudWatch 과금** | 클러스터 자원만 (노드 여유 필요) |
| 앱 지표(Spring) | 별도 설정 필요 | `/actuator/prometheus` 바로 수집 |
| 설계와 일치 | 로그 쪽 | **메트릭 쪽 (운영 설계)** |

권장: **B** (운영 설계와 같고, 10단계 ADR 측정에 앱 지표가 필요).

---

## B. kube-prometheus-stack

### B-1. 용량
Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics ≈ CPU 0.5, 메모리 2~3Gi.
core 노드그룹 여유 확인 (`kubectl describe nodes | grep -A8 "Allocated resources"`), 부족하면 노드 추가.

### B-2. 설치
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
```
**`k8s/platform/monitoring/values.yaml`**
```yaml
prometheus:
  prometheusSpec:
    retention: 1d                                    # 실습
    resources:
      requests: { cpu: 200m, memory: 1Gi }
    # 모든 namespace 의 ServiceMonitor 를 라벨 상관없이 수집
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
alertmanager:
  enabled: false                                     # 실습: 알람 생략
grafana:
  adminPassword: <임의 값 — Git 에 커밋하지 말 것, --set 으로 넘기기>
```
```bash
helm install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
  -f k8s/platform/monitoring/values.yaml --set grafana.adminPassword=$(openssl rand -hex 8)
kubectl get pods -n monitoring
kubectl get secret -n monitoring kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl port-forward -n monitoring svc/kps-grafana 3000:80        # http://localhost:3000 (admin)
```
- `serviceMonitorSelectorNilUsesHelmValues: false` 가 없으면 Prometheus 는 `release: kps` 라벨이 붙은 ServiceMonitor 만 본다 → 앱 지표가 안 잡히는 가장 흔한 원인.
- 11단계 이후라면 이것도 ArgoCD Application 으로.

### B-3. 앱 지표 수집 (ServiceMonitor)
point-backend 는 이미 `management.endpoints.web.exposure.include: health,info,prometheus` → `/actuator/prometheus` 가 열려 있다.

Service 포트에 **이름**이 있어야 ServiceMonitor 가 참조할 수 있다 → base Service 수정:
```yaml
  ports: [{ name: http, port: 80, targetPort: 8080 }]
```
**`k8s/apps/overlays/dev/servicemonitor.yaml`**
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: point-backend
spec:
  selector:
    matchExpressions:
      - { key: app, operator: In, values: [monolith, event-service] }
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s
```
- Service 에 `app` 라벨이 있어야 selector 가 매칭된다 → base Service `metadata.labels: { app: monolith }` 추가.

**응답시간 p95 를 보려면 히스토그램 활성화** (기본은 count/sum/max 만 나와서 백분위수 계산 불가). overlay ConfigMap 에 추가:
```
MANAGEMENT_METRICS_DISTRIBUTION_PERCENTILES_HISTOGRAM_HTTP_SERVER_REQUESTS=true
```
(Spring 의 relaxed binding: `management.metrics.distribution.percentiles-histogram.http.server.requests=true`)

```bash
kubectl apply -k k8s/apps/overlays/dev
# Prometheus UI 에서 타겟 확인
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090/targets 에 serviceMonitor/point/point-backend UP
```
⚠️ 확인: Prometheus Service 이름 (`kubectl get svc -n monitoring`).

### B-4. 대시보드 (부하 테스트용)
Grafana → New dashboard → 패널 추가 (PromQL):

| 패널 | 쿼리 |
|---|---|
| event-service 파드 수 | `count(kube_pod_status_ready{namespace="point", pod=~"event-service-.*", condition="true"})` |
| 노드 수 (Karpenter) | `count(kube_node_labels{label_workload="event"})` ⚠️ kube-state-metrics 는 기본으로 노드 라벨을 일부만 노출 → 안 나오면 `count(kube_node_info)` |
| 파드별 CPU | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="point", container="event-service"}[1m]))` |
| RPS | `sum(rate(http_server_requests_seconds_count{namespace="point", service="event-service"}[1m]))` |
| p95 응답시간 | `histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{service="event-service"}[1m])))` |
| 상태코드별 | `sum by (status) (rate(http_server_requests_seconds_count{service="event-service"}[1m]))` |
| HPA 목표 vs 현재 | `kube_horizontalpodautoscaler_status_current_replicas` / `..._spec_max_replicas` |

- 기본 제공 대시보드: "Kubernetes / Compute Resources / Namespace (Pods)" 로 `point` 선택.
- JVM: Grafana.com 대시보드 ID **4701** (JVM Micrometer) Import.
- 대시보드 JSON 은 Export 해서 `k8s/platform/monitoring/dashboards/` 에 커밋 → 재현 가능.

### B-5. (선택) 로그 — Loki
```bash
helm repo add grafana https://grafana.github.io/helm-charts
# loki (single binary, filesystem) + promtail/alloy → Grafana datasource 추가
```
⚠️ 확인: Loki 차트의 single-binary 최소 구성 values (차트 버전마다 다름). 리소스 여유 없으면 생략하고 `kubectl logs` / CloudWatch 로.

---

## A. CloudWatch Container Insights (대안)
EKS 애드온 `amazon-cloudwatch-observability` + Pod Identity.

`modules/eks` 의 `addons` 에 추가 + IAM:
```hcl
# envs/dev/cloudwatch.tf
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
```
```hcl
# modules/eks addons 에
amazon-cloudwatch-observability = {}
```
→ CloudWatch 콘솔 → Container Insights → 클러스터/노드/파드 대시보드, Logs 에 `/aws/containerinsights/point-dev-eks/application`.

💸 ⚠️ Container Insights(enhanced observability)는 관측 대상 수에 따라 과금되고, 로그 수집량(GB)도 과금된다. 하루 실습이면 소액이지만 **끄는 걸 잊지 말 것**. 로그 그룹은 애드온을 지워도 **남는다** → 수동 삭제.

---

## ✅ 확인
10단계 부하 테스트를 다시 돌리면서:
- 파드 수 그래프가 1 → N 으로 계단처럼 오르고
- 노드 수가 뒤따라 오르고
- CPU 가 60% 근처에서 HPA 가 반응하고
- p95 응답시간이 확장 직후 튀었다가 안정되는 모습

스크린샷을 `docs/log/12-observability.md` 에 첨부하고, 10단계 표의 시간들을 그래프로 교차 확인.

## 🧹 정리
```bash
helm uninstall kps -n monitoring
kubectl delete crd -l app.kubernetes.io/part-of=kube-prometheus-stack   # ⚠️ 확인: 라벨. CRD 는 helm uninstall 로 안 지워짐
# Container Insights 를 썼다면
aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/point-dev-eks --query 'logGroups[].logGroupName'
aws logs delete-log-group --log-group-name <각 그룹>
```
클러스터째 destroy 하면 Helm 리소스는 함께 사라지지만, **CloudWatch 로그 그룹은 남는다.**
