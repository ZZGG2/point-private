#!/usr/bin/env bash
# 테스트 공통 함수 — run.sh 가 source 한다. 단독 실행하지 않는다.
# 결과: PASS / FAIL / WARN / SKIP 을 콘솔(색)과 마크다운 리포트($REPORT)에 동시에 기록.

export PATH="$HOME/.local/bin:$PATH"
export AWS_PAGER=""
REGION=ap-northeast-2
NS_TEST=default                      # 클러스터 안 임시 테스트 파드를 띄울 namespace
TEST_POD_PREFIX="t-$(date +%H%M%S)"  # 임시 파드 이름 접두사 (중복 방지)

PASS=0; FAIL=0; WARN=0; SKIP=0
FAILED_LIST=(); WARN_LIST=()
CUR_STEP=""

if [ -t 1 ]; then _CG=$'\e[32m'; _CR=$'\e[31m'; _CY=$'\e[33m'; _CB=$'\e[36m'; _CD=$'\e[2m'; _CN=$'\e[0m'; else _CG=; _CR=; _CY=; _CB=; _CD=; _CN=; fi

_md() { [ -n "${REPORT:-}" ] && printf '%s\n' "$*" >> "$REPORT"; }
_esc() { printf '%s' "$1" | tr '\n' ' ' | sed 's/|/\\|/g' | cut -c1-300; }

step() {   # step "07" "데이터 계층"
  CUR_STEP="$1"
  printf '\n%s━━ %s단계 · %s ━━%s\n' "$_CB" "$1" "$2" "$_CN"
  _md ""; _md "## $1단계 · $2"; _md ""; _md "| 결과 | 항목 | 상세 |"; _md "|---|---|---|"
}
ok()   { PASS=$((PASS+1)); printf '  %s✔ PASS%s %s %s%s%s\n' "$_CG" "$_CN" "$1" "$_CD" "${2:-}" "$_CN"; _md "| ✅ PASS | $(_esc "$1") | $(_esc "${2:-}") |"; }
ng()   { FAIL=$((FAIL+1)); FAILED_LIST+=("[$CUR_STEP] $1"); printf '  %s✘ FAIL%s %s %s%s%s\n' "$_CR" "$_CN" "$1" "$_CR" "${2:-}" "$_CN"; _md "| ❌ FAIL | $(_esc "$1") | $(_esc "${2:-}") |"; }
warn() { WARN=$((WARN+1)); WARN_LIST+=("[$CUR_STEP] $1"); printf '  %s▲ WARN%s %s %s%s%s\n' "$_CY" "$_CN" "$1" "$_CD" "${2:-}" "$_CN"; _md "| ⚠️ WARN | $(_esc "$1") | $(_esc "${2:-}") |"; }
skip() { SKIP=$((SKIP+1)); printf '  %s○ SKIP%s %s %s%s%s\n' "$_CD" "$_CN" "$1" "$_CD" "${2:-}" "$_CN"; _md "| ⏭️ SKIP | $(_esc "$1") | $(_esc "${2:-}") |"; }
info() { printf '  %s· %s%s\n' "$_CD" "$*" "$_CN"; _md "| ℹ️ | $(_esc "$*") | |"; }

# check "설명" 명령...   → 명령이 exit 0 이면 PASS
check() { local d="$1"; shift; local out; if out=$("$@" 2>&1); then ok "$d"; else ng "$d" "$(printf '%s' "$out" | tail -2)"; fi; }
# eq "설명" 실제 기대
eq() { if [ "$2" = "$3" ]; then ok "$1" "= $2"; else ng "$1" "실제 '$2' / 기대 '$3'"; fi; }
# eq_warn: 다르면 FAIL 대신 WARN
eq_warn() { if [ "$2" = "$3" ]; then ok "$1" "= $2"; else warn "$1" "실제 '$2' / 기대 '$3'"; fi; }
# ge "설명" 실제 최소값 (정수)
ge() { if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge "$3" ]; then ok "$1" "$2 (≥ $3)"; else ng "$1" "실제 '$2' / 기대 ≥ $3"; fi; }
# match "설명" 문자열 정규식
match() { if printf '%s' "$2" | grep -Eq -- "$3"; then ok "$1" "$(printf '%s' "$2" | grep -Em1 -- "$3" | head -c 120)"; else ng "$1" "'$(printf '%s' "$2" | head -c 160)' !~ /$3/"; fi; }
nomatch() { if printf '%s' "$2" | grep -Eq -- "$3"; then ng "$1" "'$(printf '%s' "$2" | grep -E -- "$3" | head -3 | tr '\n' ' ')'"; else ok "$1"; fi; }

have() { command -v "$1" >/dev/null 2>&1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # ver_ge 실제 최소

# ── Terraform output (한 번만 읽어서 캐시) ──
TF_OUT=""
tfo() {   # tfo rds_endpoint
  if [ -z "$TF_OUT" ]; then TF_OUT=$(terraform -chdir="$REPO/envs/dev" output -json 2>/dev/null || echo '{}'); fi
  printf '%s' "$TF_OUT" | jq -r --arg k "$1" '.[$k].value // empty | if type=="string" then . else tojson end'
}

# ── 클러스터 안에서 1회성 명령 실행 (07단계 문서의 run → wait → logs 패턴) ──
# kpod 이름 이미지 timeout초 [--env K=V ...] -- 명령...   → 파드가 Succeeded 면 0. 출력은 $KPOD_OUT
KPOD_OUT=""
kpod() {
  local name="$TEST_POD_PREFIX-$1" image="$2" to="$3"; shift 3
  local envs=(); while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  kubectl run "$name" -n "$NS_TEST" --restart=Never --image="$image" "${envs[@]}" \
    --labels=app.kubernetes.io/part-of=point-tests --command -- "$@" >/dev/null 2>&1
  local phase="" i
  for ((i=0; i<to; i+=2)); do
    phase=$(kubectl get pod "$name" -n "$NS_TEST" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$phase" in Succeeded|Failed) break;; esac; sleep 2
  done
  KPOD_OUT=$(kubectl logs "$name" -n "$NS_TEST" 2>&1)
  kubectl delete pod "$name" -n "$NS_TEST" --wait=false >/dev/null 2>&1
  [ "$phase" = "Succeeded" ]
}
cleanup_test_pods() { kubectl delete pod -n "$NS_TEST" -l app.kubernetes.io/part-of=point-tests --wait=false >/dev/null 2>&1 || true; }

# ── port-forward 를 띄우고 로컬 포트가 열릴 때까지 대기. 종료는 pf_stop ──
PF_PIDS=()
pf_start() {   # pf_start ns svc/name 로컬:원격
  kubectl port-forward -n "$1" "$2" "$3" >/dev/null 2>&1 & PF_PIDS+=($!)
  local port=${3%%:*} i; for i in $(seq 1 20); do (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null && return 0; sleep 0.5; done; return 1
}
pf_stop() { local p; for p in "${PF_PIDS[@]}"; do kill "$p" 2>/dev/null; done; PF_PIDS=(); }

# ── HTTP ──
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time "${HTTP_TIMEOUT:-10}" "$@"; }
alb_host() { kubectl get gateway -n "$1" "$2" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null; }
login_token() {   # login_token ALB email
  curl -s --max-time 10 -X POST "http://$1/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$2\",\"password\":\"demo1234!\"}" | jq -r '.data.accessToken // empty'
}

# 앱 이름/상태 한 줄 요약
deploy_ready() { kubectl get deploy -n "$1" "$2" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null; }
check_deploy() {   # check_deploy ns name [최소 ready]
  local r; r=$(deploy_ready "$1" "$2"); local ready=${r%/*} want=${r#*/}
  if [ -n "$r" ] && [ "${ready:-0}" -ge "${3:-1}" ] && [ "${ready:-0}" = "$want" ]; then ok "Deployment $1/$2 Ready" "$r"; else ng "Deployment $1/$2 Ready" "${r:-없음}"; fi
}

requires_cluster() { [ "${CLUSTER_OK:-0}" = 1 ] || { skip "$1" "클러스터 접근 불가"; return 1; }; }
