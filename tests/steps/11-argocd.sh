# 11단계 — ArgoCD GitOps (App of Apps, 이전, db-init hook)
step 11 "ArgoCD (GitOps)"
requires_cluster "ArgoCD 검사" || return

for d in argocd-server argocd-repo-server argocd-applicationset-controller argocd-redis; do check_deploy argocd $d 1; done
eq "application-controller StatefulSet Ready" "$(kubectl get sts -n argocd argocd-application-controller -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')" "1/1"
eq "ArgoCD 버전 v3.6.2" "$(kubectl get deploy -n argocd argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -o 'v[0-9.]*$')" "v3.6.2"
eq "Helm 릴리스 = Terraform 소유 2개만 (나머지는 ArgoCD 로 이전)" "$(helm list -A -q 2>/dev/null | sort | tr '\n' ' ')" "argocd argocd-root "

HEAD=$(git -C "$REPO" rev-parse origin/master)
APPS=$(kubectl get applications -n argocd -o json)
EXPECT="aws-lbc external-secrets karpenter keda monitoring platform-config point-dev root"
eq "Application 8개 (root + 하위 7, strimzi 는 Kafka 제거로 삭제)" "$(echo "$APPS" | jq -r '[.items[].metadata.name] | sort | join(" ")')" "$EXPECT"
for a in $EXPECT; do
  A=$(echo "$APPS" | jq --arg a "$a" '.items[] | select(.metadata.name==$a)')
  S="$(echo "$A" | jq -r '.status.sync.status')/$(echo "$A" | jq -r '.status.health.status')"
  eq "app $a Synced/Healthy" "$S" "Synced/Healthy"
  eq "app $a automated prune+selfHeal" "$(echo "$A" | jq -r '.spec.syncPolicy.automated | "\(.prune)/\(.selfHeal)"')" "true/true"
  CE=$(echo "$A" | jq -r '[.status.conditions[]? | select(.type|test("Error")) | .message] | join(" ")')
  eq "app $a 에러 condition 없음" "${CE:-없음}" "없음"
done
for a in root platform-config point-dev; do
  eq_warn "app $a 가 Git 최신 커밋을 보고 있음" "$(echo "$APPS" | jq -r --arg a "$a" '.items[] | select(.metadata.name==$a) | .status.sync.revision // (.status.sync.revisions[]? | select(length==40))' | head -1 | cut -c1-7)" "${HEAD:0:7}"
done
if have argocd; then
  kubectl config set-context --current --namespace=argocd >/dev/null
  for a in aws-lbc external-secrets karpenter keda monitoring platform-config point-dev; do
    if argocd app diff "$a" --core --exit-code=false >/tmp/point-tests-diff.txt 2>&1; then
      NDIFF=$(grep -cE '^[<>] ' /tmp/point-tests-diff.txt); eq "argocd app diff $a: Git == 클러스터" "$NDIFF" "0"
    else ng "argocd app diff $a" "$(tail -1 /tmp/point-tests-diff.txt)"; fi
  done
  kubectl config set-context --current --namespace=default >/dev/null
else skip "argocd app diff" "argocd CLI 없음"; fi

# db-init PreSync hook (ADR-0013)
J=$(kubectl get job -n point db-init -o json 2>/dev/null)
if [ -n "$J" ]; then
  eq "db-init Job Complete" "$(echo "$J" | jq -r '.status.conditions[]? | select(.type=="Complete") | .status')" "True"
  eq "db-init 는 ArgoCD PreSync hook" "$(echo "$J" | jq -r '.metadata.annotations["argocd.argoproj.io/hook"]')" "PreSync"
  eq "db-init 로그 DO/GRANT/GRANT" "$(kubectl logs -n point job/db-init 2>/dev/null | tr '\n' ' ')" "DO GRANT GRANT "
else warn "db-init Job" "없음 (point-dev 가 아직 sync 되지 않음)"; fi
check "db-master Secret 은 Job 용 namespace(point)에만" kubectl get secret db-master -n point
for d in core-service event-service web; do
  REF=$(kubectl get deploy -n point $d -o json | jq -r '[.spec.template.spec.containers[].envFrom[]?.secretRef.name] | join(",")')
  nomatch "$d 파드는 마스터 비밀(db-master)을 참조하지 않음" "$REF" 'db-master'
done

if [ "${HEAVY:-0}" != 1 ]; then skip "selfHeal 실험" "--heavy 로 실행"; return; fi
W0=$(kubectl get deploy web -n point -o jsonpath='{.spec.replicas}')
kubectl scale deploy/web -n point --replicas=$((W0+2)) >/dev/null; t0=$(date +%s)
for i in $(seq 1 60); do r=$(kubectl get deploy web -n point -o jsonpath='{.spec.replicas}'); [ "$r" = "$W0" ] && break; sleep 1; done
[ "$r" = "$W0" ] && ok "selfHeal: kubectl scale web → Git 값($W0)으로 복구" "$(( $(date +%s)-t0 ))초" || ng "selfHeal" "60초 뒤에도 replicas=$r"
