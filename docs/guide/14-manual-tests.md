# 14. 수동 테스트 가이드 (단계별로 직접 확인)

[13 문서](13-tests.md)의 `tests/run.sh` 가 자동으로 하는 검사를 **손으로 하나씩** 실행해 보는 순서.
명령마다 "통과 기준"을 적었다. 2026-11-24 재구축 환경 기준.

> 🔄 **2026-11-26 — 명령은 새 설계 기준으로 고쳤다** (Kafka 제거·Redis Stream, Valkey 복제 그룹, monolith → core-service, 이미지 `v0.2.0`, 운영 이벤트 생성 API).
> 아래 11-24 "덮어쓴 곳" 표와 `kafka` namespace 설명은 당시 클러스터 상태 기록이다.

## 공통 준비 (셸마다 1회)
```bash
export PATH=$HOME/.local/bin:$PATH
cd ~/point/point-private
ALB=$(kubectl get gateway -n point point-gw -o jsonpath='{.status.addresses[0].value}')
MYIP=$(curl -s https://checkip.amazonaws.com)
echo "$ALB / $MYIP"
```

> ⚠️ **2026-11-24 재구축은 Git 을 고치지 않고 클러스터에서만 덮어썼다.** 그래서 일부 검사가 다른 문서와 다르게 나온다.
>
> | 항목 | Git | 실제 (덮어쓴 곳) |
> |---|---|---|
> | LBC vpcId | `k8s/platform/aws-lbc/values.yaml` 의 예전 VPC | 새 VPC (aws-lbc Application `spec.sources[0].helm.parameters`) |
> | RDS 마스터 비밀 이름 | `rds!db-c876…` | 새 이름 (point-dev Application `spec.source.kustomize.patches`) |
> | monolith·web 이미지 | `v0.1.0` / `v0.1.1` (overlay `images`) | `v0.1.2` — 퀴즈 즉시 지급 (point-dev Application `spec.source.kustomize.images`, 11-24 오후) |
>
> EKS 엔드포인트 CIDR·Gateway sourceRanges 도 처음엔 덮어썼지만, 공인 IP 가 다시 `183.98.203.186` 으로 돌아와 **Git·tfvars 값으로 되돌렸다** (11-24 11시경).
> 공인 IP 가 또 바뀌면 ALB·`kubectl` 이 둘 다 타임아웃 난다 → `curl -s https://checkip.amazonaws.com` 부터 확인.
>
> 그리고 **root Application 의 자동 Sync 는 꺼져 있다** (자식 Application 덮어쓰기를 지키려고), `kafka` namespace 는 손으로 만들었다 (strimzi Application 에 `CreateNamespace` 없음).
> 확인: `kubectl -n argocd get application aws-lbc -o jsonpath='{.spec.sources[0].helm.parameters}'`, `kubectl -n argocd get application point-dev -o jsonpath='{.spec.source.kustomize.patches}'`

---

## 1단계 — Terraform state
```bash
aws s3api get-bucket-versioning --bucket point-eks-tfstate-020208           # Enabled
aws s3 ls s3://point-eks-tfstate-020208/envs/dev/                             # terraform.tfstate
terraform -chdir=envs/dev plan -detailed-exitcode    # 종료코드 0 = drift 없음 (2 = 변경 있음)
```
- 통과: 종료코드 0 (`No changes`). EKS 애드온 `addon_version` 이 "known after apply" 로 보이는 건 data 재조회라 무시해도 된다.

## 2단계 — VPC
```bash
VPC=$(terraform -chdir=envs/dev output -raw vpc_id)
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC \
  --query 'Subnets[].[CidrBlock,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' --output table
aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC Name=state,Values=available --query 'length(NatGateways)'
aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC \
  --query 'RouteTables[].[Tags[?Key==`Name`].Value|[0], join(`,`, Routes[].DestinationCidrBlock)]' --output table
```
- 통과: 서브넷 9개·AZ 3개, NAT 1개, **Data 라우트 테이블에 `0.0.0.0/0` 없음** (최근 커밋의 수정 사항).

## 3단계 — EKS
```bash
aws eks describe-cluster --name point-dev-eks --query 'cluster.[status,version,resourcesVpcConfig.publicAccessCidrs]'
aws eks list-addons --cluster-name point-dev-eks
kubectl get nodes -L workload,karpenter.sh/capacity-type
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | jq '.items|length'
kubectl get pods -A | grep -vE 'Running|Completed'
```
- 통과: `ACTIVE`, `1.37`, CIDR = `$MYIP/32`, 노드 전부 Ready (core 3 + Karpenter event 노드), 마지막 명령은 헤더만.

## 4단계 — smoke
- smoke 앱은 테스트용이라 배포하지 않았다 → 생략.

## 5단계 — LBC + Gateway
```bash
kubectl -n kube-system get deploy aws-load-balancer-controller                               # 2/2
kubectl -n kube-system get deploy aws-load-balancer-controller -o yaml | grep aws-vpc-id      # == $VPC
kubectl get gatewayclass aws-alb
kubectl get crd | grep -c gateway                                                            # 13
kubectl -n kube-system logs deploy/aws-load-balancer-controller --since=30m | grep -ci error
```
- 핵심: `--aws-vpc-id` 가 실제 VPC 와 같아야 한다 (덮어쓰기 확인).

## 6단계 — ECR
```bash
for r in core-service event-service web; do
  echo "$r: $(aws ecr list-images --repository-name point/$r --query 'imageIds[].imageTag' --output text)"; done
kubectl get pods -n point -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u
```
- 통과: 세 레포 모두 `v0.2.0`, `ImagePullBackOff` 없음. (11-24: monolith·event-service `v0.1.0`, web `v0.1.0` + `v0.1.1`)

## 7단계 — 데이터 계층
```bash
RDS=$(terraform -chdir=envs/dev output -raw rds_endpoint)
REDIS=$(terraform -chdir=envs/dev output -raw redis_endpoint)

# app_rw 로 SSL 접속 (클러스터 안 임시 파드)
kubectl run -it --rm pg --image=postgres:16 --env=PGPASSWORD="$(cat ~/.config/point-dev/app_rw_password)" -- \
  psql "host=$RDS dbname=point user=app_rw sslmode=require" \
  -c 'select current_user, ssl from pg_stat_ssl where pid=pg_backend_pid();'      # app_rw | t

# SSL 없이는 거부돼야 함 (rds.force_ssl=1)
kubectl run -it --rm pg2 --image=postgres:16 --env=PGPASSWORD="$(cat ~/.config/point-dev/app_rw_password)" -- \
  psql "host=$RDS dbname=point user=app_rw sslmode=disable" -c 'select 1'          # no pg_hba.conf entry ... no encryption

kubectl run -it --rm rc --image=redis:7-alpine -- redis-cli -h $REDIS ping          # PONG
kubectl run -it --rm rc2 --image=redis:7-alpine -- redis-cli -h $REDIS info replication | grep -E '^(role|connected_slaves):'   # role:master, connected_slaves:1
aws elasticache describe-replication-groups --replication-group-id point-dev-redis \
  --query 'ReplicationGroups[0].[Engine,AutomaticFailover,MultiAZ]' --output text   # valkey enabled enabled  ⚠️ 확인: Engine 필드 출력
# 원장 반영 Stream (9단계 데모 뒤) — group point-ledger 의 pending·lag 0
kubectl run -it --rm rs --image=redis:7-alpine -- sh -c "for s in \$(redis-cli -h $REDIS smembers reward:streams); do echo \$s; redis-cli -h $REDIS xinfo groups \$s; done; echo dlq=\$(redis-cli -h $REDIS xlen reward:dlq)"
```
- Kafka(`kubectl -n kafka get kafka point`)는 11-26 제거 — 대신 위 Stream 확인.
- `app_rw` 생성·권한은 db-init PreSync Job 이 한다: `kubectl -n point logs job/db-init` → `DO / GRANT / GRANT`.

## 8단계 — External Secrets
```bash
kubectl get clustersecretstore aws-sm                       # Valid / True
kubectl -n point get externalsecret                         # SecretSynced / True
kubectl -n point get secret core-service-db -o json | jq -r '.data|keys[]'     # DB_PASSWORD DB_URL DB_USERNAME JWT_PRIVATE_KEY
kubectl -n point get secret event-secrets   -o json | jq -r '.data|keys[]'     # ADMIN_API_TOKEN JWT_PUBLIC_KEY
# JWT 개인키 ↔ 공개키가 같은 쌍인지 (값은 출력하지 않음)
diff <(kubectl -n point get secret core-service-db -o jsonpath='{.data.JWT_PRIVATE_KEY}' | base64 -d | openssl pkey -pubout) \
     <(kubectl -n point get secret event-secrets -o jsonpath='{.data.JWT_PUBLIC_KEY}'  | base64 -d) && echo "keypair OK"
```
- `db-master` 는 PreSync hook 이라 Sync 때마다 다시 만들어진다 (앱 파드는 참조하지 않음).

## 9단계 — point 앱
### 라우팅·보안
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://$ALB/                          # 200 (web)
curl -s http://$ALB/api/events/evt-local/status | jq -c .data                  # event-service
curl -s -o /dev/null -w '%{http_code}\n' http://$ALB/api/points/balance        # 401 (core-service, 토큰 없음)
curl -s -o /dev/null -w '%{http_code}\n' http://$ALB/actuator/health           # 200 이 아니어야 함 (비노출)
for tg in $(aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'point')].TargetGroupArn" --output text); do
  aws elbv2 describe-target-health --target-group-arn $tg --query 'TargetHealthDescriptions[].TargetHealth.State' --output text; done
```
- 통과: 타겟그룹 전부 `healthy`. 다른 IP(예: 휴대폰 LTE)에서는 ALB 접속이 타임아웃돼야 한다.

### 데모 시나리오
```bash
login() { curl -s -X POST http://$ALB/api/auth/login -H 'Content-Type: application/json' \
  -d "{\"email\":\"$1\",\"password\":\"demo1234!\"}" | jq -r .data.accessToken; }
answer() { curl -s -o /dev/null -w '%{http_code}\n' -X POST http://$ALB/api/events/evt-local/answers \
  -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d '{"answer":"A"}'; }

TOKEN=$(login demo1@point.local)
curl -s http://$ALB/api/points/balance -H "Authorization: Bearer $TOKEN" | jq -c .data    # 1000
answer $TOKEN; answer $TOKEN                                     # 202, 409
for u in 2 3 4; do answer $(login demo$u@point.local); done      # 202 202 200(재고 소진)
sleep 2   # Redis Stream → core-service → 원장 (보통 1초 안쪽)
curl -s http://$ALB/api/points/balance -H "Authorization: Bearer $TOKEN" | jq -c .data    # 1500 (자동 반영)
kubectl logs -n point -l app=core-service --since=5m | grep 'reward applied'              # reason=QUIZ_REWARD ×3
curl -s http://$ALB/api/points/history -H "Authorization: Bearer $TOKEN" | jq -c '[.data[]|select(.referenceId=="evt-local")]|length'   # 1 (중복 지급 없음)
curl -s -o /dev/null -w '%{http_code}\n' http://$ALB/api/admin/events/evt-local/settlement  # 404 (정산 API 제거됨 — /api/admin/** 는 공개 경로로 남아 있음)
```

### 운영용 이벤트 생성 API (event-day 런북 방식)
```bash
ADM=$(aws secretsmanager get-secret-value --secret-id point-dev/event-service --query SecretString --output text | jq -r .ADMIN_API_TOKEN)
EV=evt-manual-$(date +%m%d%H%M); ENDS=$(date -u -d '+30 min' +%Y-%m-%dT%H:%M:%SZ)
create() { curl -s -o /dev/null -w '%{http_code}\n' -X POST http://$ALB/api/events/admin/$EV -H "X-Admin-Token: $1" \
  -H 'Content-Type: application/json' -d "{\"stock\":2,\"amount\":100,\"endsAt\":\"$ENDS\"}"; }
create wrong          # 403
create "$ADM"         # 201
create "$ADM"         # 409 (한 번 쓴 id 는 재사용 불가)
curl -s http://$ALB/api/events/$EV/status | jq -c .data      # open true, endsAt = 30분 뒤 (UTC)
```
- 통과: 403 → 201 → 409. 마감(`endsAt`) 뒤 참여하면 410.
- ⚠️ `evt-local` 은 한 번 쓰면 재고가 소진된다. 다시 하려면 `curl -X POST "http://$ALB/api/events/evt-local/open?stock=3&amount=500"` (local 전용 초기화) — 단, 같은 사용자의 재당첨은 멱등키가 같아 원장에 다시 들어가지 않는다. 새 확인은 위 생성 API 로 새 id.
- 브라우저에서도 `http://$ALB` 로 로그인 → 퀴즈 당첨("500P가 곧 적립돼요") → 잠시 뒤 잔액 1,500P.
- 퀴즈 당첨은 **즉시 지급**이다 (point-infra ADR-0018). 일괄 정산(ADR-0017)은 철회됐다. 원장 반영 경로는 Redis Stream (ADR-0019).

## 10단계 — Karpenter + KEDA
```bash
kubectl get nodepool,ec2nodeclass,nodeclaim
kubectl -n point get scaledobject,hpa
kubectl get pods -n point -l app=event-service -o wide          # event 노드에만
```
부하 (터미널 3개):
```bash
# 1) 관찰
kubectl get nodes -L workload -w
# 2) 관찰
kubectl -n point get hpa -w
# 3) 부하 — TOKEN 은 위 데모 시나리오의 login 으로
docker run --rm -i -e BASE_URL=http://$ALB -e EVENT_ID=evt-local -e TOKEN=$TOKEN \
  grafana/k6 run - < load-test/s2-event-spike-dev.js
```
- 통과: 부하 중 HPA replicas·NodeClaim 증가 → 종료 후 몇 분 안에 회수. "부하 시작 → 새 노드 Ready" 시간을 기록.

## 11단계 — ArgoCD
```bash
kubectl -n argocd get applications                              # 자식 8개 Synced / Healthy
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
argocd login localhost:8080 --username admin --insecure \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd app diff point-dev; argocd app diff aws-lbc              # 출력 없음 = 차이 없음

# selfHeal: 손으로 바꾸면 되돌아와야 함
kubectl -n point scale deploy web --replicas=1; sleep 30; kubectl -n point get deploy web   # 다시 2
```
- `root` 는 자동 Sync 가 꺼져 있다. `argocd app sync root` 를 해도 덮어쓰기로 **추가한** 필드는 유지된다 (client-side apply).

## 12단계 — 관측성
```bash
kubectl -n monitoring get pods
kubectl -n monitoring port-forward svc/kps-grafana 3000:80 &
# 브라우저 localhost:3000 — admin / $(cat ~/.config/point-dev/grafana_admin_password)
#   → 대시보드 "point — 이벤트 확장": 패널마다 데이터가 있는지 (10단계 부하 중에 보면 좋다)

kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090 &
curl -s localhost:9090/api/v1/targets | jq '[.data.activeTargets[]|select(.health!="up")]|length'   # 0
curl -s 'localhost:9090/api/v1/query' --data-urlencode 'query=count(kube_node_labels{label_workload="event"})' | jq -c '.data.result'
```

## 99 — 비용 점검
```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'                 # point-gw 1개
aws ec2 describe-volumes --filters Name=status,Values=available --query 'length(Volumes)'     # 0
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null]|length(@)'                # 0
```

---

## 끝나면 정리 (순서 중요)
```bash
# 0) 자동 Sync 끄기 — 안 끄면 지운 Gateway/NodePool 을 ArgoCD 가 다시 만든다
for a in point-dev platform-config; do
  kubectl -n argocd patch application $a --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'; done
# 1) 컨트롤러가 만든 리소스
kubectl delete httproute,gateway --all -A          # → ALB 삭제
kubectl delete nodepool --all                       # → Karpenter 노드 회수
# 2) 1~2분 뒤 남은 ALB·EC2 확인
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId'
# 3) 인프라
terraform -chdir=envs/dev destroy
```
- Secrets Manager 비밀 2개(`point-dev/core-service`, `point-dev/event-service`)는 Terraform 밖이다 → 필요하면 `aws secretsmanager delete-secret --force-delete-without-recovery`.
