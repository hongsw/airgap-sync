#!/usr/bin/env bash
# =============================================================
# airgap-sync 운영망 연결 재시도 시험 — GitLab 없이 로컬 bare 저장소 둘(개발망·운영망)과 가짜 git·curl 래퍼로 돌린다.
#
#   가짜 git : 운영망 주소로 가는 fetch·push·ls-remote 를 정해 둔 횟수만큼 정해 둔 오류로 실패시킨다
#              (.land 가 있으면 실제로 보낸 뒤 응답만 끊긴 것처럼 실패)
#   가짜 curl: 패키지 API(목록·파일 목록·올리기)를 흉내 내고, 같은 방식으로 실패를 넣는다
#   닫힌 포트: http://127.0.0.1:9 로 진짜 연결 실패도 한 번 본다
#
#   확인하는 것: 연결 실패류만 재시도 · 횟수·지수 백오프 · 환경 변수 덮어쓰기 · 인증 실패·거부·non-fast-forward 는 바로 종료 ·
#               push 가 들어간 뒤 응답만 끊긴 경우 "이미 반영됨"(precheck·lease 불일치 둘 다) · 패키지 올리기 재시도 · 토큰 비노출
#   사용: bash test/retry.sh   (Linux · macOS · Windows Git Bash)
# =============================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/../airgap-sync.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$*"); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
sec() { printf '\n\033[1m=== %s\033[0m\n' "$*"; }
has() { [[ "$1" == *"$2"* ]]; }
hasnt() { [[ "$1" != *"$2"* ]]; }
np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

REAL_GIT="$(command -v git)"
SECRET="tok-SECRET-$RANDOM$RANDOM"
export AIRGAP_TARGET_TOKEN="$SECRET" GIT_TERMINAL_PROMPT=0
unset AIRGAP_TARGET_RETRIES AIRGAP_TARGET_RETRY_DELAY AIRGAP_CONFIG

# ---------- 가짜 git·curl ----------
F="$T/fake"; mkdir -p "$T/bin" "$F"
cat > "$T/bin/git" <<'EOF'
#!/usr/bin/env bash
op=""; hit=""
for a in "$@"; do
  case "$a" in fetch|push|ls-remote) [ -z "$op" ] && op="$a";; esac
  [ "$a" = "$FAKE_TARGET" ] && hit=1
done
if [ -n "$hit" ] && [ -n "$op" ]; then
  echo "$op" >> "$FAKE_DIR/calls"
  n="$(cat "$FAKE_DIR/$op.fail" 2>/dev/null || echo 0)"
  if [ "$n" -gt 0 ]; then
    echo $((n-1)) > "$FAKE_DIR/$op.fail"
    [ -f "$FAKE_DIR/$op.land" ] && "$REAL_GIT" "$@" >/dev/null 2>&1   # 실제로 보낸 뒤 응답만 끊긴 것처럼
    m="$FAKE_DIR/$op.msg"; [ -f "$m.$n" ] && m="$m.$n"   # 시도별 메시지(<op>.msg.<남은 횟수>)가 있으면 그것
    cat "$m" >&2
    exit "$(cat "$FAKE_DIR/$op.rc" 2>/dev/null || echo 128)"
  fi
fi
exec "$REAL_GIT" "$@"
EOF
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; up=""; prev=""
for a in "$@"; do
  [ "$prev" = "--upload-file" ] && up="$a"
  case "$a" in http://*|https://*) url="$a";; esac
  prev="$a"
done
cat > "$FAKE_DIR/curl.stdin"   # -K - 로 받은 설정(토큰 헤더)
case "$url" in *"/packages/generic/"*) op=upload;; *"/package_files"*) op=files;; *) op=list;; esac
echo "$op" >> "$FAKE_DIR/curl.calls"
n="$(cat "$FAKE_DIR/curl-$op.fail" 2>/dev/null || echo 0)"
record() { local r="${url#*/packages/generic/}"; r="${r%%\?*}"; IFS=/ read -r name ver file <<<"$r"
  echo "$name $ver $file $(sha256sum "$up" | cut -d' ' -f1)" > "$FAKE_DIR/pkg"; echo x >> "$FAKE_DIR/uploads"; }
if [ "$n" -gt 0 ]; then
  echo $((n-1)) > "$FAKE_DIR/curl-$op.fail"
  [ "$op" = upload ] && [ -f "$FAKE_DIR/curl-upload.land" ] && record
  cat "$FAKE_DIR/curl-$op.msg" >&2
  exit "$(cat "$FAKE_DIR/curl-$op.rc")"
fi
case "$op" in
  upload) record; read -r _ _ _ s < "$FAKE_DIR/pkg"; printf '{"id":7,"file_sha256":"%s"}' "$s";;
  list) if [ -f "$FAKE_DIR/pkg" ]; then read -r name ver _ _ < "$FAKE_DIR/pkg"; printf '[{"id":1,"name":"%s","version":"%s"}]' "$name" "$ver"; else printf '[]'; fi;;
  files) read -r _ _ file s < "$FAKE_DIR/pkg"; printf '[{"id":9,"file_name":"%s","file_sha256":"%s"}]' "$file" "$s";;
esac
EOF
chmod +x "$T/bin/git" "$T/bin/curl"
export PATH="$T/bin:$PATH" FAKE_DIR="$F" REAL_GIT

# ---------- 개발망·운영망 ----------
SRC="$(np "$T/src.git")"; TGT="$(np "$T/tgt.git")"; export FAKE_TARGET="$TGT"
"$REAL_GIT" init -q --bare "$SRC"
D="$T/dev"; "$REAL_GIT" init -q -b main "$D"
g() { "$REAL_GIT" -C "$D" -c core.autocrlf=false -c user.name=t -c user.email=t@example.invalid "$@"; }
echo one > "$D/a.txt"; g add -A; g commit -qm one; g branch release/1.0
g push -q "$SRC" main release/1.0
dev_commit() { g checkout -q "$1"; echo "$2" >> "$D/a.txt"; g commit -qam "$2"; g push -q "$SRC" "$1"; }
tgt_sha() { "$REAL_GIT" --git-dir="$TGT" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
src_sha() { "$REAL_GIT" --git-dir="$SRC" rev-parse "refs/heads/$1"; }
calls() { [ -f "$F/calls" ] || { echo 0; return; }; grep -cx "$1" "$F/calls" || true; }
retries() { printf '%s' "$1" | grep -c '↻ 운영망 연결 재시도' || true; }

N=0
fresh() { # 운영망·작업 저장소·가짜 상태를 새로
  N=$((N+1)); rm -rf "$T/tgt.git" "$F"; mkdir -p "$F"; "$REAL_GIT" init -q --bare "$TGT"
  cat > "$T/c.conf" <<EOF
NAME=rt
SOURCE_URL=$SRC
TARGET_URL=$TGT
BRANCHES=release/* main
WORK_DIR=$T/work$N
TARGET_API_URL=http://fake.invalid/api/v4
TARGET_PROJECT=g/app
PACKAGE_DIRS=$T/pkgs
TARGET_RETRY_DELAY=0
EOF
}
inject() { # op 횟수 종료코드 메시지 [land]
  echo "$2" > "$F/$1.fail"; echo "$3" > "$F/$1.rc"; printf '%s\n' "$4" > "$F/$1.msg"; [ -z "${5:-}" ] || touch "$F/$1.land"
}
run() { out="$(bash "$TOOL" "$@" -c "$T/c.conf" 2>&1)"; rc=$?; }
show() { printf '%s\n' "$out" | sed 's/^/    | /' | tail -"${1:-8}"; }
LOG() { cat "$T/work$N/sync-log.tsv"; }

CURL28="error: RPC failed; curl 28 Failed to connect to 172.28.1.42 port 80 after 21053 ms: Could not connect to server"
UNREACH="fatal: unable to access 'http://172.28.1.42/g/app.git/': Failed to connect to 172.28.1.42 port 80 after 21053 ms: Couldn't connect to server"

sec "연결 실패 없음"
fresh; run mirror
check "mirror 성공(0)" [ $rc -eq 0 ]
check "재시도 없음" [ "$(retries "$out")" -eq 0 ]
check "운영망 main = 개발망" [ "$(tgt_sha main)" = "$(src_sha main)" ]
check "기록 note 비어 있음" awk -F'\t' '$5=="main" && $8=="created" && $9=="" {f=1} END{exit !f}' "$T/work$N/sync-log.tsv"

sec "운영망 fetch — 연결 실패 2번 뒤 성공"
fresh; inject fetch 2 128 "$UNREACH"; run mirror; show 12
check "mirror 성공(0)" [ $rc -eq 0 ]
check "재시도 2번 출력" [ "$(retries "$out")" -eq 2 ]
check "'↻ 운영망 연결 재시도 1/3 (0초 후)' 형식" has "$out" "  ↻ 운영망 연결 재시도 1/3 (0초 후)"
check "fetch 3번 호출" [ "$(calls fetch)" -eq 3 ]
check "운영망 release/1.0 = 개발망" [ "$(tgt_sha release/1.0)" = "$(src_sha release/1.0)" ]

sec "운영망 fetch — 끝까지 실패하면 재시도 3번 뒤 종료 2"
fresh; inject fetch 9 128 "$UNREACH"; run mirror; show 6
check "종료 2" [ $rc -eq 2 ]
check "재시도 3번 (기본 TARGET_RETRIES=3)" [ "$(retries "$out")" -eq 3 ]
check "fetch 4번 호출" [ "$(calls fetch)" -eq 4 ]
check "'운영망 fetch 실패 (재시도 3회 뒤)'" has "$out" "운영망 fetch 실패 (재시도 3회 뒤)"
check "운영망은 비어 있음" [ -z "$(tgt_sha main)" ]

sec "환경 변수 AIRGAP_TARGET_RETRIES=0 → 재시도 안 함 · =1 → 한 번"
fresh; inject fetch 9 128 "$UNREACH"; out="$(AIRGAP_TARGET_RETRIES=0 bash "$TOOL" mirror -c "$T/c.conf" 2>&1)"; rc=$?
check "0: 종료 2 · 재시도 없음 · fetch 1번" [ $rc -eq 2 ] && [ "$(retries "$out")" -eq 0 ] && [ "$(calls fetch)" -eq 1 ]
fresh; inject fetch 9 128 "$UNREACH"; out="$(AIRGAP_TARGET_RETRIES=1 bash "$TOOL" mirror -c "$T/c.conf" 2>&1)"; rc=$?
check "1: 재시도 1/1 · fetch 2번" bash -c '[[ "$0" == *"재시도 1/1"* ]] && [ "$1" -eq 2 ]' "$out" "$(calls fetch)"
fresh; out="$(AIRGAP_TARGET_RETRIES=abc bash "$TOOL" status -c "$T/c.conf" 2>&1)"
check "잘못된 값은 경고하고 기본 3" bash -c '[[ "$0" == *"TARGET_RETRIES 는 0 이상의 정수"* && "$0" == *"재시도 3회"* ]]' "$out"

sec "운영망 fetch — 인증 실패(401)는 재시도하지 않음"
fresh; inject fetch 9 128 "fatal: unable to access 'http://172.28.1.42/g/app.git/': The requested URL returned error: 401"; run mirror
check "종료 2 · 재시도 없음 · fetch 1번" bash -c '[ $0 -eq 2 ] && [ $1 -eq 0 ] && [ $2 -eq 1 ]' $rc "$(retries "$out")" "$(calls fetch)"
fresh; inject fetch 9 128 $'remote: HTTP Basic: Access denied\nfatal: Authentication failed for \'http://172.28.1.42/g/app.git/\''; run mirror
check "Authentication failed 도 재시도 없음" bash -c '[ $0 -eq 2 ] && [ $1 -eq 0 ]' $rc "$(retries "$out")"

sec "운영망 push — RPC failed(curl 28) 1번 뒤 성공"
fresh; inject push 1 128 $'error: RPC failed; curl 28 Failed to connect to 172.28.1.42 port 80 after 21053 ms: Could not connect to server\nfatal: the remote end hung up unexpectedly'
run mirror; show 8
check "mirror 성공(0)" [ $rc -eq 0 ]
check "재시도 1번 · push 2번" bash -c '[ $0 -eq 1 ] && [ $1 -eq 2 ]' "$(retries "$out")" "$(calls push)"
check "다시 보내기 전에 반영 여부 확인(ls-remote)" [ "$(calls ls-remote)" -ge 1 ]
check "운영망 main = 개발망" [ "$(tgt_sha main)" = "$(src_sha main)" ]
check "기록 note '재시도 1회' · 결과 created" awk -F'\t' '$5=="main" && $8=="created" && $9=="재시도 1회" {f=1} END{exit !f}' "$T/work$N/sync-log.tsv"
check "기록은 브랜치당 한 줄(최종 결과만)" [ "$(LOG | grep -c $'\tmain\t')" -eq 1 ]

sec "운영망 push — 실제로 들어간 뒤 응답만 끊김 → 다시 보내지 않고 이미 반영됨"
fresh; run mirror; dev_commit main "two"; : > "$F/calls"
inject push 1 128 $'error: RPC failed; curl 56 Recv failure: Connection reset by peer\nfatal: the remote end hung up unexpectedly' land
run mirror; show 8
check "mirror 성공(0)" [ $rc -eq 0 ]
check "push 1번만 (다시 보내지 않음)" [ "$(calls push)" -eq 1 ]
check "'이미 반영됨' 출력" has "$out" "이미 반영됨"
check "운영망 main = 개발망" [ "$(tgt_sha main)" = "$(src_sha main)" ]
check "기록 pushed · note 에 재시도·반영 확인" awk -F'\t' '$5=="main" && $8=="pushed" && $9 ~ /재시도 1회/ && $9 ~ /반영 확인/ {f=1} END{exit !f}' "$T/work$N/sync-log.tsv"

sec "fast-forward 아님 — 재시도 없이 종료 3 · --force 가 들어갔는데 끊기면 lease 불일치로 '이미 반영됨'"
fresh; run mirror
P="$T/prod$N"; "$REAL_GIT" clone -q -b main "$TGT" "$P"; echo prod > "$P/p.txt"
"$REAL_GIT" -C "$P" -c core.autocrlf=false add -A; "$REAL_GIT" -C "$P" -c core.autocrlf=false -c user.name=p -c user.email=p@example.invalid commit -qm prod-only; "$REAL_GIT" -C "$P" push -q origin main
PROD="$(tgt_sha main)"; dev_commit main "three"; : > "$F/calls"
run mirror
check "종료 3 · push 안 함 · 재시도 없음" bash -c '[ $0 -eq 3 ] && [ $1 -eq 0 ] && [ $2 -eq 0 ]' $rc "$(calls push)" "$(retries "$out")"
check "운영망 main 그대로" [ "$(tgt_sha main)" = "$PROD" ]
# 첫 push 는 들어가고 응답만 끊김 + 반영 확인(ls-remote)도 한 번 끊김 → 다시 보낸 push 는 "이미 최신"(lease 를 줘도 같은 SHA 면 git 은 up to date)
inject push 1 128 "$CURL28" land; inject ls-remote 1 128 "$UNREACH"
run mirror --force; show 10
check "--force 성공(0) · push 2번" bash -c '[ $0 -eq 0 ] && [ $1 -eq 2 ]' $rc "$(calls push)"
check "운영망 main = 개발망" [ "$(tgt_sha main)" = "$(src_sha main)" ]
check "기록 forced · note '--force · 재시도 1회'" awk -F'\t' '$5=="main" && $8=="forced" && $9=="--force · 재시도 1회" {f=1} END{exit !f}' "$T/work$N/sync-log.tsv"
# 같은 상황에서 서버가 두 번째 push 를 lease 불일치(stale info)로 거부하면 → 운영망 ref 가 목표 SHA 와 같은지 보고 성공 처리
fresh; run mirror
P="$T/prod$N"; "$REAL_GIT" clone -q -b main "$TGT" "$P"; echo prod > "$P/p.txt"
"$REAL_GIT" -C "$P" -c core.autocrlf=false add -A; "$REAL_GIT" -C "$P" -c core.autocrlf=false -c user.name=p -c user.email=p@example.invalid commit -qm prod-only; "$REAL_GIT" -C "$P" push -q origin main
dev_commit main "four"; : > "$F/calls"
inject push 2 128 "$CURL28" land; printf '%s\n' "$CURL28" > "$F/push.msg.2"
printf '%s\n' 'To http://172.28.1.42/g/app.git' $'!\trefs/heads/main:refs/heads/main\t[rejected] (stale info)' 'Done' > "$F/push.msg.1"
inject ls-remote 1 128 "$UNREACH"
run mirror --force; show 10
check "lease 불일치: 성공(0) · push 2번" bash -c '[ $0 -eq 0 ] && [ $1 -eq 2 ]' $rc "$(calls push)"
check "lease 불일치를 '이미 반영'으로 처리" has "$out" "lease 불일치"
check "운영망 main = 개발망" [ "$(tgt_sha main)" = "$(src_sha main)" ]
check "기록 forced · note 에 반영 확인" awk -F'\t' '$5=="main" && $8=="forced" && $9 ~ /반영 확인/ {f=1} END{exit !f}' "$T/work$N/sync-log.tsv"

sec "운영망 push — 인증 실패·서버 거부는 재시도하지 않음"
fresh; inject push 9 128 $'remote: HTTP Basic: Access denied\nfatal: Authentication failed for \'http://172.28.1.42/g/app.git/\''; run mirror
check "인증 실패: 종료 2 · push 1번 · 재시도 없음" bash -c '[ $0 -eq 2 ] && [ $1 -eq 1 ] && [ $2 -eq 0 ]' $rc "$(calls push)" "$(retries "$out")"
check "기록 failed" bash -c 'grep -q $'"'"'\tmain\t.*\tfailed\t'"'"' "$0"' "$T/work$N/sync-log.tsv"
fresh; inject push 9 1 $'To http://172.28.1.42/g/app.git\n! [remote rejected] main -> main (pre-receive hook declined)\nerror: failed to push some refs'; run mirror
check "보호 브랜치 거부: 종료 2 · push 1번" bash -c '[ $0 -eq 2 ] && [ $1 -eq 1 ] && [ $2 -eq 0 ]' $rc "$(calls push)" "$(retries "$out")"
fresh; inject push 9 1 $'! [rejected] main -> main (non-fast-forward)\nerror: failed to push some refs\nfatal: the remote end hung up unexpectedly'; run mirror
check "non-fast-forward 거부(hung up 이 섞여도): push 1번" bash -c '[ $0 -eq 2 ] && [ $1 -eq 1 ]' $rc "$(calls push)"

sec "닫힌 포트(진짜 연결 실패) · 지수 백오프 · 토큰 비노출"
fresh; sed -i "s#^TARGET_URL=.*#TARGET_URL=http://oauth2:$SECRET@127.0.0.1:9/g/app.git#; /^TARGET_RETRY_DELAY/d" "$T/c.conf"
out="$(AIRGAP_TARGET_RETRIES=2 AIRGAP_TARGET_RETRY_DELAY=1 bash "$TOOL" mirror -c "$T/c.conf" 2>&1)"; rc=$?; show 6
check "종료 2" [ $rc -eq 2 ]
check "재시도 1/2 (1초 후) → 2/2 (2초 후)" bash -c '[[ "$0" == *"재시도 1/2 (1초 후)"* && "$0" == *"재시도 2/2 (2초 후)"* ]]' "$out"
check "출력에 토큰 없음" hasnt "$out" "$SECRET"

sec "packages — 패키지 API 연결 재시도"
mkdir -p "$T/pkgs"; printf 'payload\n' > "$T/pkgs/x-1.0.tar"; S="$(sha256sum "$T/pkgs/x-1.0.tar" | cut -d' ' -f1)"
printf 'version=1.0\nfile=x-1.0.tar\nsha256=%s\n' "$S" > "$T/x.lock"
pinject() { echo "$2" > "$F/curl-$1.fail"; echo "$3" > "$F/curl-$1.rc"; printf '%s\n' "$4" > "$F/curl-$1.msg"; [ -z "${5:-}" ] || touch "$F/curl-$1.land"; }
uploads() { [ -f "$F/uploads" ] && wc -l < "$F/uploads" | tr -d ' ' || echo 0; }
fresh; pinject list 2 7 "curl: (7) Failed to connect to fake.invalid port 80 after 21053 ms: Could not connect to server"
run packages --lock "$T/x.lock"; show 8
check "성공(0) · 재시도 2번 · 1번 올림" bash -c '[ $0 -eq 0 ] && [ $1 -eq 2 ] && [ $2 -eq 1 ]' $rc "$(retries "$out")" "$(uploads)"
check "토큰은 curl stdin(-K -)으로만 · 출력에 없음" bash -c 'grep -qF "$0" "$1" && [[ "$2" != *"$0"* ]]' "$SECRET" "$F/curl.stdin" "$out"
fresh; pinject upload 1 52 "curl: (52) Empty reply from server" land
run packages --lock "$T/x.lock"; show 8
check "올리기가 들어간 뒤 끊김: 성공(0) · 다시 올리지 않음(1번)" bash -c '[ $0 -eq 0 ] && [ $1 -eq 1 ]' $rc "$(uploads)"
check "'이미 반영됨' 출력 · 기록 pkg-uploaded" bash -c '[[ "$0" == *"이미 반영됨"* ]] && grep -q $'"'"'\tpkg-uploaded'"'"' "$1"' "$out" "$T/work$N/sync-log.tsv"
fresh; pinject upload 1 28 "curl: (28) Operation timed out after 30000 milliseconds with 0 bytes received"
run packages --lock "$T/x.lock"
check "올리기 timeout 1번 뒤 다시 올려 성공" bash -c '[ $0 -eq 0 ] && [ $1 -eq 1 ] && [ $2 -eq 1 ]' $rc "$(retries "$out")" "$(uploads)"
fresh; pinject upload 9 22 "curl: (22) The requested URL returned error: 401"
run packages --lock "$T/x.lock"
check "올리기 401: 재시도 없음 · 종료 5" bash -c '[ $0 -eq 5 ] && [ $1 -eq 0 ] && [ "$(grep -c upload "$2")" -eq 1 ]' $rc "$(retries "$out")" "$F/curl.calls"

sec "결과"
echo "  PASS $PASS · FAIL $FAIL"
for f in ${FAILED[@]+"${FAILED[@]}"}; do echo "   - $f"; done
[ "$FAIL" -eq 0 ]
