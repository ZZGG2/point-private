#!/usr/bin/env bash
# point-private 전체 단계 검증 스위트
#
#   tests/run.sh                 # 0~12단계 전부 (기본: 읽기 전용 + 가벼운 E2E)
#   tests/run.sh 07 09           # 특정 단계만
#   tests/run.sh --heavy         # + 무거운 실험 (부하 → HPA/Karpenter 확장, ArgoCD selfHeal)
#   tests/run.sh --no-e2e        # 9단계 E2E(테스트 이벤트 생성·당첨 → demo2·3 잔액 +100 자동 반영) 생략
#   tests/run.sh --report FILE   # 리포트 경로 지정 (기본 tests/reports/report-<시각>.md)
#
# 종료 코드: FAIL 이 하나라도 있으면 1
# 자세한 설명: docs/guide/13-tests.md

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO
source "$REPO/tests/lib.sh"

HEAVY=0; E2E=1; STEPS=(); REPORT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --heavy) HEAVY=1;;
    --no-e2e) E2E=0;;
    --report) REPORT="$2"; shift;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    [0-9][0-9]) STEPS+=("$1");;
    *) echo "알 수 없는 인자: $1" >&2; exit 2;;
  esac; shift
done
export HEAVY E2E
[ "${#STEPS[@]}" -eq 0 ] && STEPS=(00 01 02 03 04 05 06 07 08 09 10 11 12 99)

mkdir -p "$REPO/tests/reports"
[ -z "$REPORT" ] && REPORT="$REPO/tests/reports/report-$(TZ=Asia/Seoul date +%Y%m%d-%H%M%S).md"
: > "$REPORT"; export REPORT

START=$(date +%s)
_md "# 테스트 리포트 — $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')"
_md ""
_md "- 실행: \`tests/run.sh ${STEPS[*]}$([ $HEAVY = 1 ] && echo ' --heavy')$([ $E2E = 0 ] && echo ' --no-e2e')\`"
_md "- Git: \`$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)\` ($(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null))"

trap 'pf_stop; cleanup_test_pods' EXIT INT TERM

# 클러스터 접근 가능 여부 (3단계 이후 테스트들의 전제)
CLUSTER_OK=0; kubectl get --raw /readyz >/dev/null 2>&1 && CLUSTER_OK=1; export CLUSTER_OK

for s in "${STEPS[@]}"; do
  f=$(ls "$REPO"/tests/steps/"$s"-*.sh 2>/dev/null | head -1)
  if [ -z "$f" ]; then echo "단계 $s 스크립트 없음" >&2; continue; fi
  # shellcheck source=/dev/null
  source "$f"
done

pf_stop; cleanup_test_pods
DUR=$(( $(date +%s) - START ))
printf '\n%s━━ 요약 ━━%s  %sPASS %d%s  %sFAIL %d%s  %sWARN %d%s  SKIP %d  (%d분 %d초)\n' "$_CB" "$_CN" "$_CG" "$PASS" "$_CN" "$_CR" "$FAIL" "$_CN" "$_CY" "$WARN" "$_CN" "$SKIP" $((DUR/60)) $((DUR%60))
_md ""; _md "## 요약"; _md ""
_md "| PASS | FAIL | WARN | SKIP | 소요 |"; _md "|---|---|---|---|---|"
_md "| $PASS | $FAIL | $WARN | $SKIP | $((DUR/60))분 $((DUR%60))초 |"
if [ "$FAIL" -gt 0 ]; then printf '%s실패 항목:%s\n' "$_CR" "$_CN"; _md ""; _md "### 실패"; for x in "${FAILED_LIST[@]}"; do printf '  - %s\n' "$x"; _md "- $x"; done; fi
if [ "$WARN" -gt 0 ]; then printf '%s경고 항목:%s\n' "$_CY" "$_CN"; _md ""; _md "### 경고"; for x in "${WARN_LIST[@]}"; do printf '  - %s\n' "$x"; _md "- $x"; done; fi
echo "리포트: $REPORT"
[ "$FAIL" -eq 0 ]
