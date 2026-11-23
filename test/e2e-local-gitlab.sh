#!/usr/bin/env bash
# =============================================================
# airgap-sync e2e — 로컬 GitLab 한 대의 두 프로젝트를 "개발망"·"운영망" 으로 삼아 (a)·(b) 를 끝까지 돌린다.
#
#   E2E_GITLAB_URL   기본 http://localhost:8929
#   E2E_GITLAB_TOKEN 관리자(api) PAT — 프로젝트·프로젝트 토큰·러너를 만들고 지운다
#   E2E_RUNNER=1     (a) 를 CI 잡으로도 돌린다: docker 로 shell executor 러너를 띄워 개발망 프로젝트에 등록
#   E2E_RUNNER_IMAGE 기본 gitlab/gitlab-runner:alpine-v19.5.3 · E2E_GITLAB_CONTAINER 기본 local-gitlab
#   E2E_VIA_PS=1     도구를 PowerShell 래퍼(airgap-sync.ps1)로 실행 (Windows)
#   E2E_KEEP=1       끝나도 프로젝트·러너를 지우지 않는다
#
#   확인하는 것: release/*·main 만 넘어감 · fast-forward 아니면 멈춤 · --force · bundle sha256 다르면 거부 ·
#               패키지 sha256 대조·이미 있으면 건너뜀·로컬 파일이 다르면 브랜치도 넣지 않음 · 기록(TSV)
# =============================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../airgap-sync.sh"
# E2E_VIA_PS=1 이면 Windows PowerShell 래퍼(airgap-sync.ps1)로 실행한다
if [ -n "${E2E_VIA_PS:-}" ]; then TOOLCMD=(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$HERE/../airgap-sync.ps1")"); else TOOLCMD=(bash "$TOOL"); fi
URL="${E2E_GITLAB_URL:-http://localhost:8929}"
TOKEN="${E2E_GITLAB_TOKEN:?E2E_GITLAB_TOKEN(관리자 api PAT) 이 필요하다}"
API="$URL/api/v4"
RUN="e2e$(date +%H%M%S)"
SRC="airgap-$RUN-dev"; DST="airgap-$RUN-prod"
T="$(mktemp -d)"; W="$T/work"; mkdir -p "$W"
PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$*"); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
sec() { printf '\n\033[1m=== %s\033[0m\n' "$*"; }
api() { local m="$1" p="$2"; shift 2; printf 'header = "PRIVATE-TOKEN: %s"\n' "$TOKEN" | curl -sS -K - -X "$m" "$API$p" "$@"; }
jget() { grep -oE "\"$1\":(\"[^\"]*\"|[0-9]+)" | head -1 | sed -E 's/^"[^"]*"://; s/^"//; s/"$//'; }  # 응답에서 처음 나온 키의 값
enc() { printf '%s' "$1" | sed 's#/#%2F#g'; }
ROOT_USER="$(api GET /user | jget username)"
[ -n "$ROOT_USER" ] || { echo "토큰으로 $API/user 조회 실패"; exit 2; }
SRCP="$ROOT_USER/$SRC"; DSTP="$ROOT_USER/$DST"
SRC_URL="$URL/$SRCP.git"; DST_URL="$URL/$DSTP.git"

cleanup() {
  [ -n "${E2E_KEEP:-}" ] && { echo "E2E_KEEP — 남겨 둠: $SRCP $DSTP $T"; return; }
  [ -n "${RUNNER_CTR:-}" ] && MSYS_NO_PATHCONV=1 docker rm -f "$RUNNER_CTR" >/dev/null 2>&1
  [ -n "${RUNNER_ID:-}" ] && api DELETE "/runners/$RUNNER_ID" >/dev/null 2>&1
  local p n
  for p in "$SRCP" "$DSTP"; do   # 지연 삭제로 표시되면 바뀐 경로로 한 번 더 지워 영구 삭제
    api DELETE "/projects/$(enc "$p")" >/dev/null 2>&1
    n="$(api GET "/projects?search=$(basename "$p")&simple=true" | jget path_with_namespace)"
    [ -n "$n" ] && api DELETE "/projects/$(enc "$n")?permanently_remove=true&full_path=$(enc "$n")" >/dev/null 2>&1
  done
  rm -rf "$T"
}
trap cleanup EXIT

sec "준비 — 프로젝트 $SRCP(개발망) · $DSTP(운영망)"
SRC_ID="$(api POST /projects --data-urlencode "name=$SRC" --data "visibility=private" | jget id)"
DST_ID="$(api POST /projects --data-urlencode "name=$DST" --data "visibility=private" | jget id)"
[ -n "$SRC_ID" ] && [ -n "$DST_ID" ] || { echo "프로젝트 생성 실패"; exit 2; }
# 토큰·러너를 엉뚱한 프로젝트에 만들지 않게 id 가 방금 만든 프로젝트인지 확인
[ "$(api GET "/projects/$SRC_ID" | jget path_with_namespace)" = "$SRCP" ] && [ "$(api GET "/projects/$DST_ID" | jget path_with_namespace)" = "$DSTP" ] \
  || { echo "프로젝트 id 확인 실패 ($SRC_ID $DST_ID)"; exit 2; }
EXP="$(date -d '+2 days' +%F 2>/dev/null || date -v+2d +%F)"
# 문서에 적은 권한 그대로: 개발망 read_repository, 운영망 write_repository+api(Maintainer — 보호된 main push)
api POST "/projects/$SRC_ID/access_tokens" --data "name=airgap-read&access_level=20&expires_at=$EXP&scopes[]=read_repository" | jget token | tr -d '\n' > "$T/source.token"
api POST "/projects/$DST_ID/access_tokens" --data "name=airgap-write&access_level=40&expires_at=$EXP&scopes[]=write_repository&scopes[]=api" | jget token | tr -d '\n' > "$T/target.token"
[ -s "$T/source.token" ] && [ -s "$T/target.token" ] || { echo "프로젝트 토큰 생성 실패"; exit 2; }
echo "  프로젝트 토큰 2개 생성 (개발망 read_repository · 운영망 write_repository+api)"

# 관리자 토큰으로 git 을 쓰는 보조 함수 (시험 데이터 만들기·운영망 직접 커밋 흉내)
ADMIN_HDR="Authorization: Basic $(printf 'root:%s' "$TOKEN" | base64 | tr -d '\n')"
ag() { git -c "http.extraHeader=$ADMIN_HDR" -c user.name=e2e -c user.email=e2e@example.invalid "$@"; }

# 개발망 저장소: main · release/1.0 · release/2.0 · feature/x · hotfix-1 + lock 파일 + 도구 자체(CI 잡용)
D="$T/dev"; git init -q -b main "$D"
mkdir -p "$D/deploy/releases" "$D/tools/airgap-sync" "$T/pkgs"
cp "$TOOL" "$D/tools/airgap-sync/airgap-sync.sh"
printf 'image-a payload %s\n' "$RUN" > "$T/pkgs/img-a-1.0.tar"
printf 'ext payload %s\n' "$RUN" > "$T/pkgs/ext-0.1.jar"
SA="$(sha256sum "$T/pkgs/img-a-1.0.tar" | cut -d' ' -f1)"; SE="$(sha256sum "$T/pkgs/ext-0.1.jar" | cut -d' ' -f1)"
printf '# 형식 A\nexample/img-a:1.0 img-a-1.0.tar %s\n' "$SA" > "$D/deploy/releases/test-images.lock"
printf 'version=v0.1\nfile=ext-0.1.jar\nsha256=%s\n' "$SE" > "$D/deploy/releases/test-ext.lock"
# CI 잡은 ci/gitlab-ci.example.yml (문서의 잡 정의)을 그대로 쓴다
CI_SRC="${E2E_CI_FILE:-$HERE/../ci/gitlab-ci.example.yml}"
{ echo 'stages: [deploy]'; cat "$CI_SRC"; } > "$D/.gitlab-ci.yml"
echo one > "$D/app.txt"
ag -C "$D" add -A && ag -C "$D" commit -qm "init"
ag -C "$D" branch release/1.0; ag -C "$D" branch release/2.0; ag -C "$D" branch feature/x; ag -C "$D" branch hotfix-1
ag -C "$D" push -q -o ci.skip "$SRC_URL" main release/1.0 release/2.0 feature/x hotfix-1 2>&1 | grep -v '^remote:' || true
dev_commit() { # 브랜치 메시지
  ag -C "$D" checkout -q "$1" && echo "$2" >> "$D/app.txt" && ag -C "$D" commit -qam "$2" && ag -C "$D" push -q -o ci.skip "$SRC_URL" "$1" 2>&1 | grep -v '^remote:' || true
}
prod_sha() { ag ls-remote "$DST_URL" "refs/heads/$1" 2>/dev/null | cut -f1; }
dev_sha()  { ag ls-remote "$SRC_URL" "refs/heads/$1" 2>/dev/null | cut -f1; }
prod_branches() { ag ls-remote --heads "$DST_URL" 2>/dev/null | sed 's#.*refs/heads/##' | sort | tr '\n' ' '; }

cat > "$T/a.conf" <<EOF
NAME=e2e-a
SOURCE_URL=$SRC_URL
SOURCE_TOKEN_FILE=$T/source.token
TARGET_URL=$DST_URL
TARGET_TOKEN_FILE=$T/target.token
BRANCHES=release/* main
PUSH_OPTIONS=ci.skip
WORK_DIR=$W/a
PACKAGE_LOCKS=deploy/releases/test-images.lock deploy/releases/test-ext.lock
PACKAGE_REF=main
PACKAGE_DIRS=$T/nowhere;$T/pkgs
EOF
A() { "${TOOLCMD[@]}" "$1" -c "$T/a.conf" "${@:2}"; }

sec "(a) mirror — 두 망 동시 연결"
out="$(A mirror --dry-run 2>&1)"; rc=$?
check "dry-run 은 성공(0)" [ $rc -eq 0 ]
check "dry-run 계획에 main·release/1.0·release/2.0" bash -c '[[ "$0" == *"release/1.0"* && "$0" == *"release/2.0"* && "$0" == *"main "* ]]' "$out"
check "dry-run 계획에 feature/x·hotfix-1 없음" bash -c '[[ "$0" != *feature/x* && "$0" != *hotfix-1* ]]' "$out"
check "dry-run 뒤 운영망은 비어 있음" [ -z "$(prod_branches | tr -d ' ')" ]

out="$(A mirror --with-packages 2>&1)"; rc=$?; printf '%s\n' "$out" | sed 's/^/    | /' | tail -22
check "mirror --with-packages 성공" [ $rc -eq 0 ]
check "운영망 브랜치 = main release/1.0 release/2.0 (feature/x·hotfix-1 제외)" [ "$(prod_branches)" = "main release/1.0 release/2.0 " ]
check "운영망 main SHA = 개발망" [ "$(prod_sha main)" = "$(dev_sha main)" ]
check "패키지 2개 올림" [ "$(printf '%s' "$out" | grep -c '올림 (')" -eq 2 ]
check "기록에 created 3줄" [ "$(grep -c $'\tcreated\t' "$W/a/sync-log.tsv")" -eq 3 ]
check "기록 줄 = 시각·대상·브랜치·이전·새 SHA" awk -F'\t' -v s="$(dev_sha main)" '$5=="main" && $7==s && $6 ~ /^0+$/ && $4 ~ /prod\.git$/ && $1 ~ /^20/ {f=1} END{exit !f}' "$W/a/sync-log.tsv"
check "기록에 토큰 없음" bash -c '! grep -qF "$(cat "$0")" "$1" && ! grep -qF "$(cat "$2")" "$1"' "$T/target.token" "$W/a/sync-log.tsv" "$T/source.token"

out="$(A mirror --with-packages 2>&1)"; rc=$?
check "다시 돌리면 넣을 것 없음" bash -c '[ $1 -eq 0 ] && [[ "$0" == *"이미 최신"* ]]' "$out" $rc
check "이미 있는 패키지는 건너뜀(2)" [ "$(printf '%s' "$out" | grep -c '이미 있음')" -eq 2 ]

dev_commit release/1.0 "fix on 1.0"
out="$(A mirror 2>&1)"; rc=$?
check "release/1.0 fast-forward push" bash -c '[ $1 -eq 0 ] && [[ "$0" == *"fast-forward +1"* ]]' "$out" $rc
check "운영망 release/1.0 = 개발망" [ "$(prod_sha release/1.0)" = "$(dev_sha release/1.0)" ]

sec "(a) fast-forward 가 아니면 멈춤"
P="$T/prodclone"; ag clone -q "$DST_URL" "$P" 2>/dev/null; ag -C "$P" checkout -q release/1.0
echo "hotfix made in prod" >> "$P/prod.txt"; ag -C "$P" add -A; ag -C "$P" commit -qm "prod-only"; ag -C "$P" push -q -o ci.skip origin release/1.0 2>&1 | grep -v '^remote:' || true
PROD_BEFORE="$(prod_sha release/1.0)"
dev_commit release/1.0 "second fix"; dev_commit main "main moves"
MAIN_BEFORE="$(prod_sha main)"
out="$(A mirror 2>&1)"; rc=$?; printf '%s\n' "$out" | sed 's/^/    | /' | tail -6
check "종료 코드 3" [ $rc -eq 3 ]
check "운영망 release/1.0 그대로" [ "$(prod_sha release/1.0)" = "$PROD_BEFORE" ]
check "같이 넣으려던 main 도 그대로 (아무것도 넣지 않음)" [ "$(prod_sha main)" = "$MAIN_BEFORE" ]
check "기록에 rejected-non-ff" grep -q $'release/1.0\t.*\trejected-non-ff' "$W/a/sync-log.tsv"
out="$(A mirror --dry-run 2>&1)"; rc=$?
check "dry-run 도 fast-forward 아님을 보여 주고 3" bash -c '[ $1 -eq 3 ] && [[ "$0" == *"fast-forward 아님"* ]]' "$out" $rc

out="$(A mirror --force 2>&1)"; rc=$?
check "--force 를 주면 덮어씀" [ $rc -eq 0 ]
check "운영망 release/1.0 = 개발망" [ "$(prod_sha release/1.0)" = "$(dev_sha release/1.0)" ]
check "운영망 main 도 넣음" [ "$(prod_sha main)" = "$(dev_sha main)" ]
check "기록에 forced" grep -q $'release/1.0\t.*\tforced' "$W/a/sync-log.tsv"

sec "(a) 패키지 sha256 불일치면 브랜치도 넣지 않음"
ag -C "$D" checkout -q main
printf 'version=v0.2\nfile=ext-0.2.jar\nsha256=%s\n' "$SE" > "$D/deploy/releases/test-ext.lock"   # 파일 내용과 다른 sha
printf 'not the same bytes\n' > "$T/pkgs/ext-0.2.jar"
ag -C "$D" commit -qam "bump ext lock" && ag -C "$D" push -q -o ci.skip "$SRC_URL" main 2>&1 | grep -v '^remote:' || true
MAIN_BEFORE="$(prod_sha main)"
out="$(A mirror --with-packages 2>&1)"; rc=$?
check "종료 코드 5" [ $rc -eq 5 ]
check "로컬 sha256 불일치 보고" bash -c '[[ "$0" == *"sha256 불일치"* ]]' "$out"
check "운영망 main 그대로" [ "$(prod_sha main)" = "$MAIN_BEFORE" ]
cp "$T/pkgs/ext-0.1.jar" "$T/pkgs/ext-0.2.jar"   # 고쳐서 다시
out="$(A mirror --with-packages 2>&1)"; rc=$?
check "고친 뒤 패키지 올리고 main push" bash -c '[ $1 -eq 0 ] && [[ "$0" == *"ext-0.2.jar"* ]]' "$out" $rc
check "운영망 main = 개발망" [ "$(prod_sha main)" = "$(dev_sha main)" ]

sec "(b) bundle — 망을 바꿔 가며"
# 1단계 설정은 운영망 주소를, 2단계 설정은 개발망 주소를 일부러 닿지 않는 곳으로 둔다 → 각 단계가 한쪽 망만 쓰는지 확인
sed -e "s#^TARGET_URL=.*#TARGET_URL=http://127.0.0.1:9/unreachable/prod.git#" -e "s#^NAME=.*#NAME=e2e-b#" -e "s#^WORK_DIR=.*#WORK_DIR=$W/b#" "$T/a.conf" > "$T/b-dev.conf"
sed -e "s#^SOURCE_URL=.*#SOURCE_URL=http://127.0.0.1:9/unreachable/dev.git#" -e "s#^NAME=.*#NAME=e2e-b#" -e "s#^WORK_DIR=.*#WORK_DIR=$W/b#" "$T/a.conf" > "$T/b-prod.conf"
dev_commit release/2.0 "2.0 change"; ag -C "$D" checkout -q -b release/3.0; ag -C "$D" push -q -o ci.skip "$SRC_URL" release/3.0 2>&1 | grep -v '^remote:' || true
dev_commit feature/x "feature work"
out="$("${TOOLCMD[@]}" bundle-create -c "$T/b-dev.conf" --full -o "$T/b1.bundle" --with-packages 2>&1)"; rc=$?; printf '%s\n' "$out" | sed 's/^/    | /' | tail -12
check "bundle-create 성공 (운영망 연결 없이)" [ $rc -eq 0 ]
check "bundle·.sha256·.manifest 생성" test -f "$T/b1.bundle" -a -f "$T/b1.bundle.sha256" -a -f "$T/b1.bundle.manifest"
HEADS="$(git bundle list-heads "$T/b1.bundle" | sed 's#.*refs/heads/##' | sort | tr '\n' ' ')"
check "bundle 브랜치 = main release/1.0 release/2.0 release/3.0 ($HEADS)" [ "$HEADS" = "main release/1.0 release/2.0 release/3.0 " ]
GOOD="$(cut -d' ' -f1 "$T/b1.bundle.sha256")"
check ".sha256 = 실제 sha256" [ "$GOOD" = "$(sha256sum "$T/b1.bundle" | cut -d' ' -f1)" ]

R20="$(prod_sha release/2.0)"
out="$("${TOOLCMD[@]}" bundle-push "$T/b1.bundle" -c "$T/b-prod.conf" --sha256 "$(printf '%064d' 0)" 2>&1)"; rc=$?
check "--sha256 이 다르면 거부(4)" [ $rc -eq 4 ]
check "거부 뒤 운영망 그대로" test "$(prod_sha release/2.0)" = "$R20" -a -z "$(prod_sha release/3.0)"
cp "$T/b1.bundle" "$T/b2.bundle"; cp "$T/b1.bundle.sha256" "$T/b2.bundle.sha256"; cp "$T/b1.bundle.manifest" "$T/b2.bundle.manifest"; printf 'x' >> "$T/b2.bundle"
out="$("${TOOLCMD[@]}" bundle-push "$T/b2.bundle" -c "$T/b-prod.conf" 2>&1)"; rc=$?
check "bundle 이 바뀌면(.sha256 과 다르면) 거부(4)" bash -c '[ $1 -eq 4 ] && [[ "$0" == *"sha256 불일치"* ]]' "$out" $rc
rm -f "$T/b2.bundle.sha256"; out="$("${TOOLCMD[@]}" bundle-push "$T/b2.bundle" -c "$T/b-prod.conf" 2>&1)"; rc=$?
check "기준 sha256 이 없으면 거부(4)" [ $rc -eq 4 ]
check "기록에 rejected-sha256" grep -q $'\trejected-sha256\t' "$W/b/sync-log.tsv"

out="$("${TOOLCMD[@]}" bundle-push "$T/b1.bundle" -c "$T/b-prod.conf" --sha256 "$GOOD" --dry-run 2>&1)"; rc=$?
check "bundle-push --dry-run 은 계획만" bash -c '[ $1 -eq 0 ] && [[ "$0" == *DRY-RUN* ]]' "$out" $rc
check "dry-run 뒤 release/3.0 없음" [ -z "$(prod_sha release/3.0)" ]
out="$("${TOOLCMD[@]}" bundle-push "$T/b1.bundle" -c "$T/b-prod.conf" --sha256 "$GOOD" --with-packages 2>&1)"; rc=$?; printf '%s\n' "$out" | sed 's/^/    | /' | tail -12
check "bundle-push 성공 (개발망 연결 없이)" [ $rc -eq 0 ]
check "운영망 release/2.0·3.0 = 개발망" test "$(prod_sha release/2.0)" = "$(dev_sha release/2.0)" -a "$(prod_sha release/3.0)" = "$(dev_sha release/3.0)"
check "feature/x 는 여전히 없음" bash -c '[[ "$0" != *feature/x* ]]' "$(prod_branches)"

sec "(b) 증분 bundle · fast-forward 아님"
dev_commit release/3.0 "3.0 change"
out="$("${TOOLCMD[@]}" bundle-create -c "$T/b-dev.conf" -o "$T/b3.bundle" 2>&1)"; rc=$?
check "증분 bundle 생성 (바뀐 release/3.0 만)" bash -c '[ $1 -eq 0 ] && [ "$(git bundle list-heads "$0" | wc -l)" -eq 1 ]' "$T/b3.bundle" $rc
check "증분 bundle 은 전체보다 작다" [ "$(wc -c < "$T/b3.bundle")" -lt "$(wc -c < "$T/b1.bundle")" ]
ag -C "$P" fetch -q origin 2>/dev/null; ag -C "$P" checkout -q -B release/3.0 origin/release/3.0; echo prod >> "$P/prod3.txt"; ag -C "$P" add -A; ag -C "$P" commit -qm "prod-only 3.0"; ag -C "$P" push -q -o ci.skip origin release/3.0 2>&1 | grep -v '^remote:' || true
R30="$(prod_sha release/3.0)"
out="$("${TOOLCMD[@]}" bundle-push "$T/b3.bundle" -c "$T/b-prod.conf" 2>&1)"; rc=$?
check "운영망이 갈라졌으면 bundle-push 도 멈춤(3)" [ $rc -eq 3 ]
check "운영망 release/3.0 그대로" [ "$(prod_sha release/3.0)" = "$R30" ]

if [ -n "${E2E_RUNNER:-}" ]; then
  sec "(a) CI 잡 — shell executor 러너"
  IMG="${E2E_RUNNER_IMAGE:-gitlab/gitlab-runner:alpine-v19.5.3}"; GLC="${E2E_GITLAB_CONTAINER:-local-gitlab}"
  # 실제 잡 정의가 요구하는 프로젝트 변수: AIRGAP_SYNC=bash(리눅스·Git Bash 러너), AIRGAP_SYNC_AUTO=1(push 마다 자동)
  api POST "/projects/$SRC_ID/variables" --data "key=AIRGAP_SYNC&value=bash" >/dev/null
  api POST "/projects/$SRC_ID/variables" --data "key=AIRGAP_SYNC_AUTO&value=1" >/dev/null
  RT="$(api POST /user/runners --data "runner_type=project_type&project_id=$SRC_ID&description=airgap-e2e&tag_list=airgap" )"
  RUNNER_ID="$(printf '%s' "$RT" | jget id)"; RTOK="$(printf '%s' "$RT" | jget token)"
  # Git Bash: 컨테이너 안 경로가 Windows 경로로 바뀌지 않게, 로컬 경로는 직접 변환
  dk() { MSYS_NO_PATHCONV=1 docker "$@"; }
  lp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
  RUNNER_CTR="airgap-e2e-runner-$RUN"
  dk run -d --name "$RUNNER_CTR" --network "container:$GLC" --entrypoint sh "$IMG" -c 'sleep infinity' >/dev/null
  cat > "$(lp "$T/ci.conf")" <<EOF
NAME=e2e-ci
TARGET_URL=http://localhost:8929/$DSTP.git
TARGET_TOKEN_FILE=/home/gitlab-runner/.airgap-sync/target.token
BRANCHES=release/* main
PUSH_OPTIONS=ci.skip
EOF
  dk exec "$RUNNER_CTR" mkdir -p /home/gitlab-runner/.airgap-sync
  dk cp "$(lp "$T/ci.conf")" "$RUNNER_CTR:/home/gitlab-runner/.airgap-sync/airgap-sync.conf" >/dev/null
  dk cp "$(lp "$T/target.token")" "$RUNNER_CTR:/home/gitlab-runner/.airgap-sync/target.token" >/dev/null
  dk exec "$RUNNER_CTR" sh -c 'chown -R gitlab-runner /home/gitlab-runner/.airgap-sync && chmod 600 /home/gitlab-runner/.airgap-sync/target.token'
  dk exec "$RUNNER_CTR" gitlab-runner register --non-interactive --url http://localhost:8929 --token "$RTOK" --executor shell --name airgap-e2e >/dev/null 2>&1
  dk exec -d "$RUNNER_CTR" gitlab-runner run --user gitlab-runner --working-directory /home/gitlab-runner
  dev_commit release/2.0 "ci-driven change"
  # ci.skip 없이 push 해 파이프라인을 깨운다
  echo "ci" >> "$D/app.txt"; ag -C "$D" commit -qam "trigger ci"; ag -C "$D" push -q "$SRC_URL" release/2.0 2>&1 | grep -v '^remote:' || true
  WANT="$(dev_sha release/2.0)"; st=""
  for i in $(seq 1 60); do
    st="$(api GET "/projects/$SRC_ID/pipelines?ref=release%2F2.0&sha=$WANT" | jget status)"
    case "$st" in success|failed|canceled) break;; esac; sleep 5
  done
  JOB="$(api GET "/projects/$SRC_ID/pipelines?ref=release%2F2.0&sha=$WANT" | jget id)"
  JID="$(api GET "/projects/$SRC_ID/pipelines/$JOB/jobs" | jget id)"
  api GET "/projects/$SRC_ID/jobs/$JID/trace" | sed -E 's/\x1b\[[0-9;]*[mK]//g' | grep -E '▶|✓|✗|⚠|  · |release/' | sed 's/^/    | /' | tail -14
  check "CI 잡 성공 ($st)" [ "$st" = success ]
  check "CI 잡이 release/2.0 을 운영망에 넣음" [ "$(prod_sha release/2.0)" = "$WANT" ]
  check "push 파이프라인은 그 브랜치만 (release/3.0 은 갈라진 채 그대로)" [ "$(prod_sha release/3.0)" = "$R30" ]
  TRACE="$(api GET "/projects/$SRC_ID/jobs/$JID/trace")"
  check "CI 잡 trace 에 토큰 없음" bash -c '! grep -qF "$(cat "$0")" <<<"$1"' "$T/target.token" "$TRACE"
  api GET "/projects/$SRC_ID/jobs/$JID/artifacts/airgap-sync-report.tsv" > "$T/report.tsv"
  check "아티팩트 airgap-sync-report.tsv 에 release/2.0 pushed" grep -q $'release/2.0\t.*\tpushed' "$T/report.tsv"
fi

sec "결과"
echo "  PASS $PASS · FAIL $FAIL"
for f in "${FAILED[@]}"; do echo "   - $f"; done
[ "$FAIL" -eq 0 ]
