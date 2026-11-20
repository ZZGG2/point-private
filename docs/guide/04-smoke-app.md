# 4단계. 테스트 앱 배포 (kubectl 로 직접)

## 목표
Namespace → Deployment → Service 를 직접 만들고, 일부러 망가뜨려 보면서 상태를 읽는 법을 익힌다.

## 💡 YAML 은 외우지 않는다
```bash
# 뼈대 생성 (클러스터엔 아무것도 안 만듦)
kubectl create deployment nginx --image=nginx:1.27-alpine --replicas=2 --dry-run=client -o yaml
# 필드 설명
kubectl explain deployment.spec.template.spec.containers.readinessProbe
```

## 4-1. 매니페스트 (`k8s/smoke/`)
파일 이름 숫자 접두사 → `kubectl apply -f 폴더/` 가 **이름순**으로 적용 → namespace 가 먼저 생김.

**`00-namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: smoke
```

**`10-deployment.yaml`** (최종본)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: smoke
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx            # ← 이 Deployment가 관리할 파드를 고르는 기준
  template:
    metadata:
      labels:
        app: nginx          # ← 위 selector와 반드시 일치
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits:   { memory: 128Mi }
          readinessProbe:
            httpGet: { path: /, port: 80 }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 5
            periodSeconds: 10
```

**`20-service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: smoke
spec:
  type: ClusterIP
  selector:
    app: nginx              # ← 이 라벨을 가진 파드로 트래픽 분배
  ports:
    - port: 80              # Service 포트
      targetPort: 80        # 파드 포트
```

### 리소스 관계
```
Deployment ──(관리)──▶ ReplicaSet ──(관리)──▶ Pod ×2 (label app=nginx)
                                                 ▲
Service(selector app=nginx) ──▶ EndpointSlice ───┘  (Ready 인 파드 IP 만)
```

## 4-2. 배포 & 접속
```bash
cd ~/point/point-private
kubectl apply -f k8s/smoke/
kubectl get all -n smoke
kubectl get pods -n smoke -o wide        # 파드 IP 가 10.10.x.x (VPC IP), 노드 2대에 분산
```
터미널 A: `kubectl port-forward -n smoke svc/nginx 8080:80` (켜 둔다)
터미널 B: `curl localhost:8080` → `Welcome to nginx!`

관찰용 터미널: `kubectl get pods -n smoke -w`

## 4-3. 일부러 망가뜨리기
각 실험마다 **현상 → 원인 찾은 명령 → 복구**를 `docs/log/04-smoke.md` 에 기록.

### ① 자가 치유
```bash
kubectl delete pod -n smoke <파드 하나>
```
→ 즉시 새 파드. ReplicaSet 이 "2개" 라는 **원하는 상태**를 계속 맞춘다 (reconcile loop).

### ② 이미지 태그 오타
`image: nginx:1.27-alpne` 로 바꾸고:
```bash
kubectl apply -f k8s/smoke/
kubectl rollout status deployment/nginx -n smoke     # 안 끝남 (Ctrl+C)
kubectl get pods -n smoke                            # ErrImagePull → ImagePullBackOff
kubectl describe pod -n smoke <새 파드>               # Events: manifest unknown / not found
```
- 이때도 `curl` 은 **응답이 온다** → 롤링 업데이트는 새 파드가 Ready 가 되기 전엔 기존 파드를 안 지운다.
- 복구: 파일의 오타 수정 → apply. (`kubectl rollout undo` 도 되지만 파일과 클러스터가 어긋남 → GitOps 습관상 파일 수정)

### ③ requests 과다 → Pending
```yaml
          resources:
            requests: { cpu: "4", memory: 64Mi }
```
→ `Pending`, `describe` Events 에 `Insufficient cpu` (t3.medium = 2 vCPU).
```bash
kubectl describe node <노드> | grep -A8 "Allocated resources"
```
- `requests` = **스케줄러가 자리 잡을 때** 보는 예약량. `limits` = 실행 중 상한 (메모리 초과 시 OOMKilled).
- 10단계 Karpenter 는 Pending 파드의 requests 를 보고 노드를 추가한다.

### ④ readinessProbe 실패
```yaml
          readinessProbe:
            httpGet: { path: /healthz-wrong, port: 80 }
```
→ `Running` 인데 `READY 0/1`.
```bash
kubectl get endpointslices -n smoke      # 엔드포인트에서 빠짐 → Service 가 트래픽 안 보냄
```

### ⑤ livenessProbe 실패
```yaml
          livenessProbe:
            httpGet: { path: /wrong, port: 80 }
            periodSeconds: 5
            failureThreshold: 2
```
→ `RESTARTS` 증가 → `CrashLoopBackOff`.
```bash
kubectl describe pod ...                    # Liveness probe failed ... will be restarted
kubectl logs -n smoke <파드> --previous     # 재시작 직전 컨테이너 로그
```

| | readiness 실패 | liveness 실패 |
|---|---|---|
| 결과 | 트래픽에서 **제외** | 컨테이너 **재시작** |
| 용도 | 아직 준비 안 됨 / 일시 과부하 | 데드락 등 회복 불가 상태 |
| 흔한 사고 | — | DB 체크 같은 무거운 걸 liveness 에 넣어 DB 장애 시 전체 재시작 |

### ⑥ 스케일
```bash
kubectl scale deployment/nginx -n smoke --replicas=5
kubectl get pods -n smoke -o wide
kubectl apply -f k8s/smoke/       # 파일 기준(2개)으로 복귀
```

## ✅ 완료 기준
- `curl localhost:8080` 응답
- ②~⑤ 원인을 `describe` / `logs` / `get endpointslices` 로 직접 찾음
- 최종 YAML 에 `resources` / `readinessProbe` / `livenessProbe` 가 **정상값**
- `kubectl diff -f k8s/smoke/` 출력 없음 (파일 = 클러스터)

```bash
git add k8s/smoke docs/log && git commit -m "feat: step4 smoke app" && git push
```

## 🧹 정리
5단계로 이어가면 **지우지 않는다** (HTTPRoute 가 이 Service 로 보냄). 끝낼 거면 `kubectl delete ns smoke`.
