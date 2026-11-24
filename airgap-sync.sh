#!/usr/bin/env bash
# =============================================================
# airgap-sync — 망이 분리된 두 GitLab 사이에서 지정한 브랜치만 옮긴다 (+ lock 파일에 적힌 바이너리 반입)
#
#   개발망 GitLab(SOURCE) ──fetch──▶ 중간 PC 작업 저장소 ──push(fast-forward 만)──▶ 운영망 GitLab(TARGET)
#
#   방식 (a) 두 망에 동시에 붙는 경우:  mirror        (CI 잡에서는 ci)
#   방식 (b) 망을 바꿔 가며 붙는 경우:   bundle-create (개발망) → 망 전환 → bundle-push <파일> (운영망)
#   바이너리 반입:                       packages      (mirror·bundle-push 에 --with-packages 로도 붙는다)
#
#   지키는 것
#     · BRANCHES 패턴(기본 "release/* main")에 맞는 브랜치만 넣는다. 삭제는 옮기지 않는다.
#     · 운영망 브랜치가 fast-forward 가 아니면 아무것도 넣지 않고 멈춘다(종료 3). --force 를 줬을 때만 덮는다(lease 로 보호).
#     · bundle 의 sha256 이 기록과 다르면 거부한다(종료 4).
#     · lock 의 파일은 sha256 을 대조하고, 운영망 패키지 저장소에 이미 같은 파일이 있으면 건너뛴다.
#     · 패키지는 브랜치 push 보다 먼저 올린다(push 가 배포 파이프라인을 깨우기 때문).
#     · 결과(브랜치별 이전 SHA → 새 SHA, 시각, 대상)를 WORK_DIR/sync-log.tsv 에 남긴다.
#     · 토큰은 설정 파일이 가리키는 토큰 파일이나 환경 변수로만 받고, 명령줄·로그에 남기지 않는다.
#
#   사용법: airgap-sync.sh help   ·  문서: 같은 폴더 README.md
# =============================================================
set -euo pipefail
PROG=airgap-sync
EX_USAGE=1 EX_FAIL=2 EX_NONFF=3 EX_REJECT=4 EX_PKG=5

# ---------- 출력 ----------
hr()   { printf '\n▶ %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*" >&2; }
die()  { local c="$1"; shift; printf '  ✗ %s\n' "$*" >&2; exit "$c"; }

usage() {
  cat <<'EOF'
airgap-sync — 망분리 GitLab 브랜치 미러 + 바이너리 반입

명령
  mirror                 개발망 fetch → fast-forward 확인 → 운영망 push       (방식 a, 두 망 동시 연결)
  ci                     CI 잡용 mirror. push 파이프라인이면 그 브랜치만, 아니면 패턴 전체
  bundle-create          개발망 fetch → git bundle + .sha256 + .manifest 생성  (방식 b, 1단계)
  bundle-push <bundle>   sha256·bundle 검증 → fast-forward 확인 → 운영망 push  (방식 b, 2단계)
  packages               lock 파일의 바이너리를 운영망 패키지 저장소에 올린다
  status                 설정·작업 저장소·최근 기록 보기
  help

공통 옵션
  -c, --config FILE      설정 파일 (기본: $AIRGAP_CONFIG → ~/.airgap-sync/airgap-sync.conf)
  -n, --dry-run          무엇을 넣을지(브랜치·패키지)만 보여 주고 아무것도 바꾸지 않는다
      --force            fast-forward 가 아닌 브랜치도 덮어쓴다 (명시했을 때만, --force-with-lease)
      --only BRANCH      이번 실행을 이 브랜치로 한정 (여러 번 가능, 패턴에도 맞아야 한다)
      --branches "P..."  설정의 BRANCHES 대신 이 패턴 목록 (공백 구분 glob)
      --with-packages    브랜치 push 전에 packages 단계도 실행
      --report FILE      이번 실행 결과만 TSV 로 따로 저장 (CI 아티팩트용)
bundle-create
  -o, --out FILE         bundle 경로 (기본: WORK_DIR/bundles/<이름>-<시각>.bundle)
      --full             증분이 아닌 전체 bundle (운영망 쪽 저장소 상태를 모를 때)
bundle-push
      --sha256 HEX       따로 받아 적어 둔 sha256 (없으면 <bundle>.sha256 파일과 대조)
packages
      --lock FILE        저장소 대신 이 lock 파일을 쓴다 (여러 번 가능)
      --ref BRANCH       lock 을 읽을 브랜치 (기본 PACKAGE_REF)

운영망 연결 재시도  TARGET_RETRIES(기본 3)·TARGET_RETRY_DELAY(기본 5초, 매번 두 배) — 연결 실패류만
                   (환경 변수 AIRGAP_TARGET_RETRIES·AIRGAP_TARGET_RETRY_DELAY 로도 덮는다. 0 이면 재시도 안 함)

종료 코드  0 성공 · 1 사용법/설정 · 2 실패 · 3 fast-forward 아님(멈춤) · 4 bundle 거부 · 5 패키지 불일치
EOF
}

# ---------- 공용 ----------
now()  { date '+%Y-%m-%dT%H:%M:%S%z'; }
stamp(){ date '+%Y%m%d-%H%M%S'; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
# URL 에서 사용자·비밀번호(토큰)를 지운다 — 화면·로그에는 이것만 쓴다
clean_url() { printf '%s' "$1" | sed -E 's#^([a-z+]+://)[^/@]*@#\1#'; }
# Windows 경로(C:\...)를 Git Bash 경로로
upath() { if [[ "$1" == [A-Za-z]:[\\/]* ]] && command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
npath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }  # git·curl(네이티브)에 넘길 경로
expand_home() { case "$1" in "~"|"~/"*) printf '%s%s' "$HOME" "${1#\~}";; *) printf '%s' "$1";; esac; }
ZERO=0000000000000000000000000000000000000000

# ---------- 설정 ----------
CFG_KEYS="NAME SOURCE_URL TARGET_URL SOURCE_USER TARGET_USER BRANCHES WORK_DIR LOG_FILE SOURCE_TOKEN_FILE TARGET_TOKEN_FILE SOURCE_RESOLVE TARGET_RESOLVE PUSH_OPTIONS PUSH_ATOMIC TARGET_API_URL TARGET_PROJECT PACKAGE_LOCKS PACKAGE_REF PACKAGE_DIRS TARGET_RETRIES TARGET_RETRY_DELAY"
load_config() {
  local f="$1" line k v
  [ -f "$f" ] || die $EX_USAGE "설정 파일이 없다: $f  (예시: $(dirname "${BASH_SOURCE[0]}")/airgap-sync.example.conf)"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue;; esac
    [[ "$line" == *=* ]] || { warn "설정 줄 무시: $line"; continue; }
    k="${line%%=*}"; v="${line#*=}"
    k="$(printf '%s' "$k" | tr -d '[:space:]')"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    case "$v" in \"*\") v="${v:1:${#v}-2}";; \'*\') v="${v:1:${#v}-2}";; esac
    case " $CFG_KEYS " in *" $k "*) printf -v "CFG_$k" '%s' "$v";; *) warn "모르는 설정 키 무시: $k";; esac
  done < "$f"
}
# 값 우선순위: 명령줄 > 환경 변수 AIRGAP_<키> > 설정 파일 > 기본값
cfg() { local k="$1" d="${2:-}" e="AIRGAP_$1" c="CFG_$1"; if [ -n "${!e:-}" ]; then printf '%s' "${!e}"; elif [ -n "${!c:-}" ]; then printf '%s' "${!c}"; else printf '%s' "$d"; fi; }

resolve_settings() {
  NAME="$(cfg NAME "$(basename "${CONFIG%.*}")")"
  SOURCE_URL="$(cfg SOURCE_URL)"
  TARGET_URL="$(cfg TARGET_URL)"
  [ -n "$BRANCHES_OVERRIDE" ] && BRANCHES="$BRANCHES_OVERRIDE" || BRANCHES="$(cfg BRANCHES 'release/* main')"
  WORK_DIR="$(upath "$(expand_home "$(cfg WORK_DIR "$HOME/.airgap-sync/work/$NAME")")")"
  LOG_FILE="$(upath "$(expand_home "$(cfg LOG_FILE "$WORK_DIR/sync-log.tsv")")")"
  REPO="$(npath "$WORK_DIR/repo.git")"
  PUSH_OPTIONS="$(cfg PUSH_OPTIONS)"
  PUSH_ATOMIC="$(cfg PUSH_ATOMIC 1)"
  PACKAGE_LOCKS="$(cfg PACKAGE_LOCKS)"
  PACKAGE_REF="${REF_OVERRIDE:-$(cfg PACKAGE_REF main)}"
  PACKAGE_DIRS="$(cfg PACKAGE_DIRS)"
  TARGET_API_URL="$(cfg TARGET_API_URL)"
  TARGET_PROJECT="$(cfg TARGET_PROJECT)"
  TARGET_RETRIES="$(cfg TARGET_RETRIES 3)"
  [[ "$TARGET_RETRIES" =~ ^[0-9]+$ ]] || { warn "TARGET_RETRIES 는 0 이상의 정수여야 한다 ($TARGET_RETRIES) — 3 으로 한다"; TARGET_RETRIES=3; }
  TARGET_RETRY_DELAY="$(cfg TARGET_RETRY_DELAY 5)"
  [[ "$TARGET_RETRY_DELAY" =~ ^[0-9]+$ ]] || { warn "TARGET_RETRY_DELAY 는 0 이상의 정수(초)여야 한다 ($TARGET_RETRY_DELAY) — 5 로 한다"; TARGET_RETRY_DELAY=5; }
  if [ -z "$TARGET_API_URL" ] && [[ "$TARGET_URL" == http*://* ]]; then
    local base; base="$(clean_url "$TARGET_URL")"; base="${base#*://}"
    TARGET_API_URL="${TARGET_URL%%://*}://${base%%/*}/api/v4"
  fi
  if [ -z "$TARGET_PROJECT" ] && [ -n "$TARGET_URL" ]; then
    local p; p="$(clean_url "$TARGET_URL")"
    case "$p" in *://*) p="${p#*://}"; p="${p#*/}";; *:*) p="${p#*:}";; esac
    TARGET_PROJECT="${p%.git}"
  fi
}

read_token() { # $1 = SOURCE|TARGET → 토큰 문자열(없으면 빈 값)
  local env="AIRGAP_$1_TOKEN" f
  if [ -n "${!env:-}" ]; then printf '%s' "${!env}"; return; fi
  f="$(cfg "$1_TOKEN_FILE")"; [ -n "$f" ] || return 0
  f="$(upath "$(expand_home "$f")")"
  [ -f "$f" ] || { warn "$1_TOKEN_FILE 이 가리키는 파일이 없다: $f"; return 0; }  # 토큰이 꼭 필요한 곳(api_curl)에서 멈춘다
  tr -d '\r\n' < "$f"
}

# git 에 인증 헤더·주소 고정을 환경 변수(GIT_CONFIG_*)로 넘긴다 — 명령줄(프로세스 목록)에 토큰이 보이지 않게
GITCFG_N=0
gitcfg_add() { export "GIT_CONFIG_KEY_$GITCFG_N=$1" "GIT_CONFIG_VALUE_$GITCFG_N=$2"; GITCFG_N=$((GITCFG_N+1)); export GIT_CONFIG_COUNT=$GITCFG_N; }
setup_git_auth() {
  local side url tok r
  for side in SOURCE TARGET; do
    url="${side}_URL"; url="${!url}"; [ -n "$url" ] || continue
    if [[ "$url" == http*://* ]]; then
      tok="$(read_token "$side")"
      if [ -n "$tok" ]; then
        gitcfg_add "http.$(clean_url "$url").extraHeader" "Authorization: Basic $(printf '%s:%s' "$(cfg "${side}_USER" oauth2)" "$tok" | base64 | tr -d '\n')"
      fi
    fi
    r="$(cfg "${side}_RESOLVE")"; [ -n "$r" ] && gitcfg_add http.curloptResolve "$r"
  done
  [ -n "${CI:-}" ] && export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
  return 0
}
G() { git --git-dir="$REPO" "$@"; }

# ---------- 운영망 연결 재시도 ----------
# 운영망 접속이 간헐적으로 TCP 연결 단계에서 끊기는 경우(curl 28/7·RPC failed 등)만 다시 시도한다.
# 인증 실패·보호 브랜치 거부·non-fast-forward·lease 불일치 같은 "서버가 답한 거부" 는 다시 해도 같으니 바로 실패시킨다.
NO_RETRY_RE='HTTP (400|401|403|404|405|407|409|411|413|422)|returned error: 4[0-9][0-9]|Authentication failed|Access denied|could not read (Username|Password)|terminal prompts disabled|\[rejected\]|\[remote rejected\]|stale info|non-fast-forward|fetch first|protected branch|pre-receive hook declined|^! '
RETRY_RE="curl (6|7|28|35|52|55|56)([^0-9]|\$)|curl: \((6|7|28|35|52|55|56)\)|Could not connect|Couldn't connect|Failed to connect|Could not resolve host|Connection (timed out|refused|reset)|Operation timed out|RPC failed|unexpected disconnect|remote end hung up|early EOF|Empty reply from server|(Send|Recv) failure|HTTP (502|503|504)|returned error: (502|503|504)"
is_transient() { # $1 = 출력 → 연결 실패류면 0
  printf '%s\n' "$1" | grep -qiE "$NO_RETRY_RE" && return 1
  printf '%s\n' "$1" | grep -qiE "$RETRY_RE"
}
# 출력에서 URL 안의 사용자·비밀번호를 지운다 (토큰은 헤더로만 넘기지만 URL 에 적었을 때 대비)
scrub() { sed -E 's#([a-zA-Z+]+://)[^/@[:space:]]*@#\1#g'; }

# retry_target <명령...> — 운영망에 닿는 명령을 실행하고, 연결 실패류면 TARGET_RETRIES 번까지 다시 한다.
#   결과: 종료 코드 그대로 · RT_OUT(stdout) · RT_ERR(stderr) · RT_TRIES(재시도한 횟수) · RT_DONE(1 = 확인 함수가 이미 반영됐다고 함)
#   RT_PRECHECK=<함수> 를 주면 다시 보내기 전에 그 함수로 "첫 시도가 사실은 들어갔는지" 를 본다 (0 이면 다시 보내지 않고 성공, 함수 출력이 RT_OUT).
#   재시도 안내는 stderr 로 쓴다 — $(...) 로 결과를 받는 곳(api_curl)을 더럽히지 않게.
RT_OUT="" RT_ERR="" RT_TRIES=0 RT_DONE="" RT_PRECHECK="" RT_IN_PRECHECK=""
retry_target() {
  local max="$TARGET_RETRIES" delay="$TARGET_RETRY_DELAY" i=0 rc errf pc="$RT_PRECHECK" why landed
  [ -n "$RT_IN_PRECHECK" ] && max=0   # 확인 함수 안에서는 한 번만 (재시도 안에서 또 재시도하지 않게)
  errf="$(mktemp "${TMPDIR:-/tmp}/airgap-rt.XXXXXX")"
  RT_DONE=""
  while :; do
    rc=0; RT_OUT="$("$@" 2>"$errf")" || rc=$?
    RT_ERR="$(cat "$errf")"
    [ $rc -eq 0 ] && break
    is_transient "$RT_OUT"$'\n'"$RT_ERR" || break
    [ "$i" -lt "$max" ] || break
    i=$((i+1))
    why="$(printf '%s\n%s\n' "$RT_ERR" "$RT_OUT" | grep -iE "$RETRY_RE" | head -1 | scrub | cut -c1-160)"
    printf '  ↻ 운영망 연결 재시도 %d/%d (%d초 후)%s\n' "$i" "$max" "$delay" "${why:+ — $why}" >&2
    sleep "$delay"; delay=$((delay*2))
    if [ -n "$pc" ] && landed="$(RT_IN_PRECHECK=1; RT_PRECHECK=""; "$pc" 2>/dev/null)"; then
      printf '  ✓ 끊기기 전에 운영망에 이미 반영됨 — 다시 보내지 않는다\n' >&2
      RT_OUT="$landed"; RT_ERR=""; RT_DONE=1; rc=0; break
    fi
  done
  rm -f "$errf"
  RT_TRIES=$i
  return $rc
}

ensure_repo() {
  mkdir -p "$WORK_DIR"
  [ -d "$REPO" ] || { git init -q --bare "$REPO"; G config gc.auto 0; G config fetch.prune false; }
}
LOCKDIR=""
take_lock() {
  LOCKDIR="$WORK_DIR/.lock"
  mkdir -p "$WORK_DIR"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    die $EX_FAIL "다른 airgap-sync 가 같은 WORK_DIR 에서 도는 중이다 ($LOCKDIR). 아니라면 그 폴더를 지운다"
  fi
  trap 'rm -rf "$LOCKDIR"' EXIT
}

# ---------- 기록 ----------
LOG_HEADER=$'time\tmode\tname\ttarget\tbranch\told_sha\tnew_sha\tresult\tnote'
log_row() { # mode branch old new result note
  local row
  row="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(now)" "$1" "$NAME" "$(clean_url "${TARGET_URL:--}")" "$2" "$3" "$4" "$5" "${6:-}")"
  mkdir -p "$(dirname "$LOG_FILE")"
  [ -s "$LOG_FILE" ] || printf '%s\n' "$LOG_HEADER" > "$LOG_FILE"
  printf '%s\n' "$row" >> "$LOG_FILE"
  if [ -n "$REPORT" ]; then [ -s "$REPORT" ] || printf '%s\n' "$LOG_HEADER" > "$REPORT"; printf '%s\n' "$row" >> "$REPORT"; fi
}

# ---------- 브랜치 선택 ----------
match_branch() { # 패턴·--only 둘 다 통과해야 한다
  local b="$1" p o hit="" pats=()
  read -r -a pats <<<"$BRANCHES"
  for p in "${pats[@]}"; do
    # shellcheck disable=SC2053
    [[ "$b" == $p ]] && { hit=1; break; }
  done
  [ -n "$hit" ] || return 1
  [ ${#ONLY[@]} -eq 0 ] && return 0
  for o in ${ONLY[@]+"${ONLY[@]}"}; do [ "$b" = "$o" ] && return 0; done
  return 1
}

fetch_source() {
  [ -n "$SOURCE_URL" ] || die $EX_USAGE "SOURCE_URL 이 없다"
  hr "개발망 fetch — $(clean_url "$SOURCE_URL")"
  G fetch -q --prune --no-tags "$SOURCE_URL" '+refs/heads/*:refs/heads/*' || die $EX_FAIL "개발망 fetch 실패"
  ok "브랜치 $(G for-each-ref --format=x refs/heads | wc -l | tr -d ' ')개"
}
fetch_target() {
  [ -n "$TARGET_URL" ] || die $EX_USAGE "TARGET_URL 이 없다"
  hr "운영망 상태 확인 — $(clean_url "$TARGET_URL")"
  if ! retry_target G fetch -q --prune --no-tags "$TARGET_URL" '+refs/heads/*:refs/airgap/target/*'; then
    [ -z "$RT_ERR" ] || printf '%s\n' "$RT_ERR" | scrub | sed 's/^/    /' >&2
    die $EX_FAIL "운영망 fetch 실패$([ "$RT_TRIES" -gt 0 ] && printf ' (재시도 %s회 뒤)' "$RT_TRIES") (주소·토큰(read_repository)·망 연결 확인)"
  fi
  [ "$RT_TRIES" -eq 0 ] || info "운영망 연결 — 재시도 ${RT_TRIES}회 만에 성공"
  ok "운영망 브랜치 $(G for-each-ref --format=x refs/airgap/target | wc -l | tr -d ' ')개"
}

# PLAN 줄: <branch> <old|ZERO> <new> <same|new|ff|nonff>
PLAN=()
make_plan() { # $1 = 원본 ref 접두어(refs/heads 또는 refs/airgap/bundle)
  local prefix="$1" ref b new old st
  PLAN=()
  while IFS=' ' read -r new ref; do
    b="${ref#"$prefix"/}"
    match_branch "$b" || continue
    old="$(G rev-parse -q --verify "refs/airgap/target/$b^{commit}" 2>/dev/null || true)"
    if [ -z "$old" ]; then st=new; old=$ZERO
    elif [ "$old" = "$new" ]; then st=same
    elif G merge-base --is-ancestor "$old" "$new" 2>/dev/null; then st=ff
    else st=nonff; fi
    PLAN+=("$b $old $new $st")
  done < <(G for-each-ref --format='%(objectname) %(refname)' "$prefix")
}
show_plan() {
  local l b old new st n=0 lbl
  hr "넣을 브랜치 (패턴: $BRANCHES${ONLY:+ · 한정: ${ONLY[*]}})"
  [ ${#PLAN[@]} -gt 0 ] || { info "패턴에 맞는 브랜치가 없다"; return 0; }
  for l in "${PLAN[@]}"; do
    read -r b old new st <<<"$l"
    case "$st" in
      same)  lbl="그대로";;
      new)   lbl="새 브랜치";;
      ff)    lbl="fast-forward +$(G rev-list --count "$old..$new")";;
      nonff) if [ -n "$FORCE" ]; then lbl="강제(--force) — 운영망에만 있는 커밋 $(G rev-list --count "$new..$old")개 사라짐"; else lbl="✗ fast-forward 아님 — 운영망에만 있는 커밋 $(G rev-list --count "$new..$old")개"; fi;;
    esac
    printf '  %-40s %s → %s  %s\n' "$b" "${old:0:12}" "${new:0:12}" "$lbl"
    [ "$st" = same ] || n=$((n+1))
  done
  CHANGES=$n
}

guard_nonff() { # fast-forward 가 아닌 브랜치가 있고 --force 가 없으면 기록하고 멈춘다
  local mode="$1" l b old new st nonff=()
  [ -n "$FORCE" ] && return 0
  for l in ${PLAN[@]+"${PLAN[@]}"}; do read -r b old new st <<<"$l"; [ "$st" = nonff ] && nonff+=("$b"); done
  [ ${#nonff[@]} -eq 0 ] && return 0
  for l in "${PLAN[@]}"; do read -r b old new st <<<"$l"; [ "$st" = nonff ] && log_row "$mode" "$b" "$old" "$new" rejected-non-ff "운영망에만 있는 커밋 있음"; done
  die $EX_NONFF "fast-forward 가 아닌 브랜치가 있어 아무것도 넣지 않고 멈춘다: ${nonff[*]} — 운영망에서 직접 커밋된 것이 없는지 확인하고, 덮어써도 되면 --force"
}

# 운영망 브랜치가 PLAN 의 목표 SHA 와 모두 같으면 0 — push 응답만 끊기고 실제로는 들어간 경우를 알아낸다
push_landed() {
  local l b old new st refs=() remote
  for l in ${PLAN[@]+"${PLAN[@]}"}; do read -r b old new st <<<"$l"; [ "$st" = same ] || refs+=("refs/heads/$b"); done
  [ ${#refs[@]} -gt 0 ] || return 1
  retry_target G ls-remote "$TARGET_URL" "${refs[@]}" || return 1
  remote="$RT_OUT"
  for l in "${PLAN[@]}"; do
    read -r b old new st <<<"$l"; [ "$st" = same ] && continue
    printf '%s\n' "$remote" | grep -qxF "$new"$'\t'"refs/heads/$b" || return 1
  done
  return 0
}

push_plan() { # $1 = mode 이름
  local mode="$1" l b old new st refspecs=() leases=() opt args=() out rc tries landed="" note=""
  guard_nonff "$mode"
  for l in ${PLAN[@]+"${PLAN[@]}"}; do
    read -r b old new st <<<"$l"
    case "$st" in
      same) ;;
      nonff) refspecs+=("+$new:refs/heads/$b"); leases+=("--force-with-lease=refs/heads/$b:$old");;
      *) refspecs+=("$new:refs/heads/$b");;
    esac
  done
  if [ ${#refspecs[@]} -eq 0 ]; then
    ok "운영망이 이미 최신 — 넣을 것 없음"
    for l in ${PLAN[@]+"${PLAN[@]}"}; do read -r b old new st <<<"$l"; log_row "$mode" "$b" "$old" "$new" up-to-date; done
    return 0
  fi
  if [ -n "$DRY_RUN" ]; then
    for l in "${PLAN[@]}"; do read -r b old new st <<<"$l"; [ "$st" = same ] || log_row "$mode" "$b" "$old" "$new" dry-run "$st"; done
    ok "DRY-RUN — 여기까지 (push 하지 않음)"; return 0
  fi
  hr "운영망 push — ${#refspecs[@]}개 브랜치"
  [ "$PUSH_ATOMIC" = 1 ] && args+=(--atomic)
  for opt in $PUSH_OPTIONS; do args+=(-o "$opt"); done
  # 재시도해도 안전하다: fast-forward·새 브랜치는 같은 SHA 를 다시 보내면 "이미 최신", --force 브랜치는 이전 SHA 기준 lease 라
  # 첫 시도가 들어갔으면 lease 불일치로 거부된다 → 어느 쪽이든 운영망 ref 가 목표 SHA 와 같은지 다시 보고 "이미 반영됨" 으로 처리
  rc=0
  RT_PRECHECK=push_landed
  retry_target G push --porcelain ${args[@]+"${args[@]}"} ${leases[@]+"${leases[@]}"} "$TARGET_URL" "${refspecs[@]}" || rc=$?
  RT_PRECHECK=""
  out="$RT_ERR"$'\n'"$RT_OUT"; tries=$RT_TRIES
  if [ -n "$RT_DONE" ]; then landed=1
  elif [ $rc -ne 0 ] && [ "$tries" -gt 0 ] && push_landed; then
    landed=1; rc=0; info "재시도가 거부됐지만(lease 불일치·이미 최신) 운영망 ref 가 목표 SHA 와 같다 — 첫 시도가 들어간 것"
  fi
  [ -n "$landed" ] || printf '%s\n' "$out" | grep -vE '^(To |Done$|remote: *$|remote: +(To create a merge request|http))' | grep . | scrub | sed 's/^/    /' || true
  [ "$tries" -gt 0 ] && note="재시도 ${tries}회"
  [ -n "$landed" ] && note="${note:+$note · }응답 끊김 뒤 반영 확인"
  for l in "${PLAN[@]}"; do
    read -r b old new st <<<"$l"; [ "$st" = same ] && continue
    if [ $rc -eq 0 ]; then
      G update-ref "refs/airgap/target/$b" "$new"
      case "$st" in new) log_row "$mode" "$b" "$old" "$new" created "$note";; nonff) log_row "$mode" "$b" "$old" "$new" forced "--force${note:+ · $note}";; *) log_row "$mode" "$b" "$old" "$new" pushed "$note";; esac
    else
      log_row "$mode" "$b" "$old" "$new" failed "${note:+$note · }$(printf '%s' "$out" | grep -E '^!|error|rejected|fatal' | head -1 | scrub | tr '\t' ' ')"
    fi
  done
  [ $rc -eq 0 ] || die $EX_FAIL "push 실패$([ "$tries" -gt 0 ] && printf ' (재시도 %s회 뒤)' "$tries") (위 출력 확인 — 그 사이 운영망이 바뀌었거나 토큰에 write_repository 가 없거나 보호 브랜치 설정)"
  ok "push 완료${note:+ ($note)} — 기록: $LOG_FILE"
}

# ---------- 패키지 ----------
api_curl_once() { # $1 = 토큰 (셸 함수 인자 — 프로세스 명령줄에는 나오지 않는다)
  local tok="$1"; shift
  printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok" | curl -sS "$@" -K -
}
api_curl() { # 토큰은 stdin 설정(-K -)으로만 넘긴다. 연결 실패류는 retry_target 이 다시 한다
  local tok resolve=() rc=0
  tok="$(read_token TARGET)"
  [ -n "$tok" ] || die $EX_USAGE "패키지 저장소 접근에 TARGET 토큰(api 권한)이 필요하다 — TARGET_TOKEN_FILE 또는 AIRGAP_TARGET_TOKEN"
  local r; r="$(cfg TARGET_RESOLVE)"; [ -n "$r" ] && resolve=(--resolve "$r")
  retry_target api_curl_once "$tok" ${resolve[@]+"${resolve[@]}"} "$@" || rc=$?
  [ -z "$RT_ERR" ] || printf '%s\n' "$RT_ERR" | scrub >&2
  printf '%s' "$RT_OUT"
  return $rc
}
# 올리기 응답이 끊긴 뒤 다시 올리기 전에: 운영망에 이미 같은 sha256 의 파일이 있으면 그 응답 모양을 내고 0 (run_packages 의 pkg·ver·file·sum)
upload_landed() {
  local r; r="$(remote_sha "$pkg" "$ver" "$file")" || return 1
  [ "$r" = "$sum" ] || return 1
  printf '{"file_sha256":"%s"}' "$sum"
}
enc_project() { printf '%s' "$TARGET_PROJECT" | sed 's#/#%2F#g'; }

# lock 내용 → "<패키지> <버전> <파일> <sha256>" 줄
#   형식 A (한 줄에 하나):  <이름:버전> <파일> <sha256>        예) registry/img:1.2.3 img-1.2.3.tar <sha>
#   형식 B (key=value):     version=… file=… sha256=…
#   패키지 이름 = lock 파일 이름에서 .lock 을 뗀 것
parse_lock() { # $1 = lock 이름, stdin = 내용
  local pkg; pkg="$(basename "$1")"; pkg="${pkg%.lock}"
  local body; body="$(tr -d '\r')"
  if printf '%s\n' "$body" | grep -qE '^version='; then
    local v f s
    v="$(printf '%s\n' "$body" | sed -n 's/^version=//p' | head -1)"
    f="$(printf '%s\n' "$body" | sed -n 's/^file=//p' | head -1)"
    s="$(printf '%s\n' "$body" | sed -n 's/^sha256=//p' | head -1)"
    [ -n "$v" ] && [ -n "$f" ] && [ ${#s} -eq 64 ] || die $EX_PKG "$1: version·file·sha256(64자) 가 모두 있어야 한다"
    printf '%s %s %s %s\n' "$pkg" "$v" "$f" "$s"
  else
    local a f s rest
    while read -r a f s rest; do
      case "$a" in ''|'#'*) continue;; esac
      [ -n "$f" ] && [ ${#s} -eq 64 ] && [[ "${a##*/}" == *:* ]] || die $EX_PKG "$1 형식 오류: $a $f $s"
      printf '%s %s %s %s\n' "$pkg" "${a##*:}" "$f" "$s"
    done <<<"$body"
  fi
}

collect_locks() { # → PKG_LINES
  PKG_LINES=""
  local l rev=""
  if [ ${#LOCK_FILES[@]} -gt 0 ]; then
    for l in "${LOCK_FILES[@]}"; do l="$(upath "$l")"; [ -f "$l" ] || die $EX_USAGE "lock 파일이 없다: $l"; PKG_LINES+="$(parse_lock "$l" < "$l")"$'\n'; done
    return 0
  fi
  [ -n "$PACKAGE_LOCKS" ] || die $EX_USAGE "PACKAGE_LOCKS 가 비어 있다 (설정 또는 --lock)"
  for rev in "refs/airgap/bundle/$PACKAGE_REF" "refs/heads/$PACKAGE_REF"; do G rev-parse -q --verify "$rev" >/dev/null 2>&1 && break; rev=""; done
  [ -n "$rev" ] || die $EX_USAGE "작업 저장소에 $PACKAGE_REF 가 없다 — 먼저 mirror/bundle-push 를 하거나 --lock 으로 파일을 준다"
  info "lock 은 $PACKAGE_REF @ $(G rev-parse --short "$rev") 에서 읽는다"
  local locks=(); read -r -a locks <<<"$PACKAGE_LOCKS"
  for l in "${locks[@]}"; do
    if G cat-file -e "$rev:$l" 2>/dev/null; then PKG_LINES+="$(G show "$rev:$l" | parse_lock "$l")"$'\n'
    else warn "$PACKAGE_REF 에 $l 이 없다 — 건너뜀"; fi
  done
}

find_local() { # 파일 이름 → 경로 (PACKAGE_DIRS 는 ; 로 구분)
  local name="$1" d IFS=';'
  for d in $PACKAGE_DIRS; do
    d="$(upath "$(expand_home "$d")")"
    [ -f "$d/$name" ] && { printf '%s' "$d/$name"; return 0; }
  done
  return 1
}

# 운영망에 같은 파일이 있으면 그 sha256, 없으면 빈 값 (조회 실패는 종료)
remote_sha() { # pkg ver file
  local api="$TARGET_API_URL/projects/$(enc_project)" list id files
  list="$(api_curl -f "$api/packages?package_type=generic&package_name=$1&per_page=100")" || die $EX_FAIL "패키지 목록 조회 실패 ($api) — 토큰 api 권한·주소 확인"
  id="$(printf '%s' "$list" | tr '{' '\n' | grep -F "\"name\":\"$1\"" | grep -F "\"version\":\"$2\"" | sed -nE 's/^"id":([0-9]+).*/\1/p' | head -1)"
  [ -n "$id" ] || return 0
  files="$(api_curl -f "$api/packages/$id/package_files?per_page=100")" || die $EX_FAIL "패키지 파일 목록 조회 실패"
  local hits; hits="$(printf '%s' "$files" | tr '{' '\n' | grep -F "\"file_name\":\"$3\"" || true)"
  [ -n "$hits" ] || return 0
  printf '%s\n' "$hits" | sed -nE 's/.*"file_sha256":"([0-9a-f]{64})".*/\1/p' | tail -1 | grep . || printf 'unknown'
}

run_packages() {
  local mode="$1" pkg ver file sum rsum path lsum resp got fail=0 n=0 have_token
  hr "바이너리 반입 — 운영망 패키지 저장소 ${TARGET_PROJECT:-?} (generic)"
  collect_locks
  have_token="$(read_token TARGET)"
  while read -r pkg ver file sum; do
    [ -n "$pkg" ] || continue; n=$((n+1))
    printf '  %s/%s/%s\n' "$pkg" "$ver" "$file"
    if [ -n "$LOCAL_ONLY" ]; then rsum="?"
    elif [ -z "$have_token" ] && [ -n "$DRY_RUN" ]; then rsum="?"; info "토큰 없음 — 운영망 보유 여부는 건너뛰고 로컬 파일만 본다"
    else [ -n "$TARGET_API_URL" ] || die $EX_USAGE "TARGET_API_URL 을 정할 수 없다"; rsum="$(remote_sha "$pkg" "$ver" "$file")"; fi
    if [ "$rsum" = "$sum" ]; then ok "이미 있음 (sha256 ${sum:0:12}…) — 건너뜀"; log_row "$mode" "pkg:$pkg/$ver/$file" - "$sum" pkg-skip "already present"; continue; fi
    if [ -n "$rsum" ] && [ "$rsum" != "?" ]; then
      warn "운영망에 같은 이름의 다른 파일이 있다 (원격 ${rsum:0:12}… · lock ${sum:0:12}…) — 덮지 않는다"; log_row "$mode" "pkg:$pkg/$ver/$file" "$rsum" "$sum" pkg-conflict; fail=1; continue
    fi
    if ! path="$(find_local "$file")"; then warn "로컬에 없다 — PACKAGE_DIRS($PACKAGE_DIRS) 확인"; log_row "$mode" "pkg:$pkg/$ver/$file" - "$sum" pkg-missing; fail=1; continue; fi
    lsum="$(sha256_of "$path")"
    if [ "$lsum" != "$sum" ]; then warn "로컬 파일 sha256 불일치: $path ${lsum:0:12}… ≠ lock ${sum:0:12}…"; log_row "$mode" "pkg:$pkg/$ver/$file" - "$sum" pkg-bad-local "$lsum"; fail=1; continue; fi
    if [ -n "$DRY_RUN" ]; then ok "올릴 예정 — $path ($(du -h "$path" | cut -f1), sha256 일치)"; log_row "$mode" "pkg:$pkg/$ver/$file" - "$sum" dry-run; continue; fi
    resp="$(RT_PRECHECK=upload_landed; api_curl -f --upload-file "$(npath "$path")" "$TARGET_API_URL/projects/$(enc_project)/packages/generic/$pkg/$ver/$file?select=package_file")" \
      || { warn "올리기 실패"; log_row "$mode" "pkg:$pkg/$ver/$file" - "$sum" pkg-failed; fail=1; continue; }
    got="$(printf '%s' "$resp" | sed -nE 's/.*"file_sha256":"([0-9a-f]{64})".*/\1/p')"
    if [ -n "$got" ] && [ "$got" != "$sum" ]; then warn "올린 뒤 서버 sha256 ${got:0:12}… 이 다르다"; log_row "$mode" "pkg:$pkg/$ver/$file" - "$sum" pkg-bad-remote "$got"; fail=1; continue; fi
    ok "올림 ($(du -h "$path" | cut -f1), 서버 sha256 ${got:0:12}…)"; log_row "$mode" "pkg:$pkg/$ver/$file" - "$sum" pkg-uploaded
  done <<<"$PKG_LINES"
  [ $n -gt 0 ] || info "lock 에 항목이 없다"
  [ $fail -eq 0 ] || die $EX_PKG "패키지 단계 실패 — 브랜치는 넣지 않는다 (배포 잡이 없는 파일을 받으려다 멈추지 않게)"
}

# ---------- 명령 ----------
cmd_mirror() {
  local mode="${1:-mirror}"
  take_lock; ensure_repo; setup_git_auth
  fetch_source; fetch_target
  make_plan refs/heads; CHANGES=0; show_plan
  # fast-forward 판정을 패키지보다 먼저 — 멈출 실행에서 파일을 올리지 않는다. 패키지는 브랜치가 최신이어도 확인한다
  guard_nonff "$mode"
  [ -z "$WITH_PACKAGES" ] || run_packages "$mode"
  push_plan "$mode"
}

cmd_ci() {
  [ -n "${CI:-}" ] || warn "CI 밖에서 ci 명령 — mirror 와 같다"
  # SOURCE_URL 이 없으면 이 잡의 저장소를 job token 으로 읽는다 (토큰은 URL 이 아니라 헤더로)
  if [ -z "$(cfg SOURCE_URL)" ] && [ -n "${CI_REPOSITORY_URL:-}" ]; then
    export AIRGAP_SOURCE_URL; AIRGAP_SOURCE_URL="$(clean_url "$CI_REPOSITORY_URL")"
    if [ -z "${AIRGAP_SOURCE_TOKEN:-}" ] && [ -n "${CI_JOB_TOKEN:-}" ]; then export AIRGAP_SOURCE_TOKEN="$CI_JOB_TOKEN" AIRGAP_SOURCE_USER=gitlab-ci-token; fi
  fi
  [ -n "${AIRGAP_DRY_RUN:-}" ] && DRY_RUN=1
  [ "${AIRGAP_FORCE:-}" = 1 ] && FORCE=1
  [ "${AIRGAP_WITH_PACKAGES:-}" = 1 ] && WITH_PACKAGES=1
  if [ ${#ONLY[@]} -eq 0 ] && [ "${CI_PIPELINE_SOURCE:-}" = push ] && [ -n "${CI_COMMIT_BRANCH:-}" ]; then ONLY=("$CI_COMMIT_BRANCH"); fi
  [ -z "$REPORT" ] && [ -n "${CI_PROJECT_DIR:-}" ] && REPORT="$CI_PROJECT_DIR/airgap-sync-report.tsv"
  resolve_settings
  [ -n "$REPORT" ] && rm -f "$REPORT"
  cmd_mirror ci
}

cmd_bundle_create() {
  take_lock; ensure_repo; setup_git_auth
  fetch_source
  make_plan refs/heads; CHANGES=0; show_plan
  info "운영망 상태는 이 작업 저장소가 마지막으로 본 것 기준 — 최종 판정은 bundle-push 가 운영망에서 다시 한다"
  local l b old new st heads=() nots=() out
  for l in "${PLAN[@]}"; do
    read -r b old new st <<<"$l"
    { [ "$st" != same ] || [ -n "$FULL" ]; } || continue
    heads+=("refs/heads/$b")
    [ -z "$FULL" ] && [ "$old" != $ZERO ] && nots+=("$old")
  done
  [ ${#heads[@]} -gt 0 ] || { ok "운영망(마지막 확인 기준)이 이미 최신 — bundle 만들 것 없음 (전체로 만들려면 --full)"; return 0; }
  if [ -n "$DRY_RUN" ]; then for l in "${PLAN[@]}"; do read -r b old new st <<<"$l"; [ "$st" = same ] || log_row bundle-create "$b" "$old" "$new" dry-run "$st"; done
    [ -n "$WITH_PACKAGES" ] && ( LOCAL_ONLY=1 run_packages bundle-create )
    ok "DRY-RUN — bundle 을 만들지 않음"; return 0; fi
  out="${OUT:-$WORK_DIR/bundles/$NAME-$(stamp).bundle}"; out="$(upath "$out")"
  mkdir -p "$(dirname "$out")"
  hr "bundle 만들기 — $out"
  out="$(npath "$out")"
  if [ ${#nots[@]} -gt 0 ]; then G bundle create -q "$out" "${heads[@]}" --not "${nots[@]}" 2>/dev/null || true; fi
  # 증분 bundle 에서 빠진 ref 가 있으면(되감긴 브랜치 등) 전체로 다시 만든다
  if [ ! -f "$out" ] || [ "$(G bundle list-heads "$out" 2>/dev/null | wc -l | tr -d ' ')" -ne ${#heads[@]} ]; then
    [ ${#nots[@]} -gt 0 ] && info "증분으로는 모든 브랜치가 담기지 않아 전체 bundle 로 만든다"
    rm -f "$out"; nots=(); G bundle create -q "$out" "${heads[@]}" || die $EX_FAIL "git bundle create 실패"
  fi
  local sum; sum="$(sha256_of "$out")"
  printf '%s  %s\n' "$sum" "$(basename "$out")" > "$out.sha256"
  {
    printf 'airgap-sync-manifest=1\nname=%s\ncreated=%s\nsource=%s\ntarget=%s\nbundle=%s\nsha256=%s\nprerequisites=%s\n' \
      "$NAME" "$(now)" "$(clean_url "$SOURCE_URL")" "$(clean_url "${TARGET_URL:--}")" "$(basename "$out")" "$sum" "${nots[*]+${nots[*]}}"
    G bundle list-heads "$out" | while read -r s r; do printf 'branch %s %s\n' "${r#refs/heads/}" "$s"; done
  } > "$out.manifest"
  for l in "${PLAN[@]}"; do read -r b old new st <<<"$l"; case " ${heads[*]} " in *" refs/heads/$b "*) log_row bundle-create "$b" "$old" "$new" bundled "$(basename "$out")";; esac; done
  ok "bundle $(du -h "$out" | cut -f1) · 브랜치 ${#heads[@]}개 · 증분 기준 커밋 ${#nots[@]}개"
  ok "sha256 $sum"
  info "이 sha256 을 bundle 과 다른 경로(작업 기록·메신저 등)로도 남겨 두고, 운영망에서 --sha256 으로 대조한다"
  if [ -n "$WITH_PACKAGES" ]; then ( DRY_RUN=1 LOCAL_ONLY=1 run_packages bundle-create ) || warn "망을 바꾸기 전에 위 패키지 문제를 해결한다"; info "패키지는 운영망에서 bundle-push --with-packages 로 올린다"; fi
  hr "다음 — 망을 바꾼 뒤"
  printf '  %s bundle-push "%s" --sha256 %s%s\n' "$0" "$out" "$sum" "${WITH_PACKAGES:+ --with-packages}"
}

cmd_bundle_push() {
  local bundle="$1"; bundle="$(npath "$(upath "$bundle")")"
  [ -f "$bundle" ] || die $EX_USAGE "bundle 파일이 없다: $bundle"
  take_lock; ensure_repo; setup_git_auth
  hr "bundle 검증 — $bundle"
  local got want
  got="$(sha256_of "$bundle")"
  if [ -n "$EXPECT_SHA" ]; then want="$(printf '%s' "$EXPECT_SHA" | tr 'A-F' 'a-f')"; info "기준: --sha256"
  elif [ -f "$bundle.sha256" ]; then want="$(cut -d' ' -f1 < "$bundle.sha256" | tr -d '\r\n')"; info "기준: $(basename "$bundle").sha256 (따로 적어 둔 값이 있으면 --sha256 으로 주는 편이 낫다)"
  else die $EX_REJECT "기준 sha256 이 없다 — --sha256 HEX 를 주거나 $bundle.sha256 를 함께 가져온다"; fi
  if [ "$got" != "$want" ]; then
    log_row bundle-push "-" - - rejected-sha256 "got $got want $want"
    die $EX_REJECT "sha256 불일치 — 거부: 파일 $got · 기준 $want (복사 중 손상 또는 다른 파일)"
  fi
  ok "sha256 일치 ${got:0:16}…"
  fetch_target
  if ! G bundle verify -q "$bundle" >/dev/null 2>&1; then
    log_row bundle-push "-" - - rejected-verify "$(basename "$bundle")"
    G bundle verify "$bundle" 2>&1 | sed 's/^/    /' | head -10 >&2 || true
    die $EX_REJECT "git bundle verify 실패 — 증분 기준 커밋이 운영망·작업 저장소에 없다. 개발망에서 bundle-create --full 로 다시 만든다"
  fi
  ok "git bundle verify 통과"
  if [ -f "$bundle.manifest" ]; then
    local m h
    m="$(grep '^branch ' "$bundle.manifest" | tr -d '\r' | awk '{print $2, $3}' | sort)"
    h="$(G bundle list-heads "$bundle" | awk '{sub("refs/heads/","",$2); print $2, $1}' | sort)"
    [ "$m" = "$h" ] || { log_row bundle-push "-" - - rejected-manifest "$(basename "$bundle")"; die $EX_REJECT "bundle 안의 브랜치가 manifest 와 다르다 — 거부"; }
    ok "manifest 와 브랜치·SHA 일치 ($(printf '%s\n' "$h" | wc -l | tr -d ' ')개)"
  fi
  for r in $(G for-each-ref --format='%(refname)' refs/airgap/bundle); do G update-ref -d "$r"; done
  G fetch -q --no-tags "$bundle" '+refs/heads/*:refs/airgap/bundle/*' || die $EX_FAIL "bundle 에서 가져오기 실패"
  make_plan refs/airgap/bundle; CHANGES=0; show_plan
  guard_nonff bundle-push
  [ -z "$WITH_PACKAGES" ] || run_packages bundle-push
  push_plan bundle-push
}

cmd_packages() { take_lock; ensure_repo; run_packages packages; }

cmd_status() {
  hr "설정 — $CONFIG"
  printf '  이름      %s\n  개발망    %s\n  운영망    %s\n  패턴      %s\n  작업 폴더 %s\n  기록      %s\n  패키지    %s (%s) · lock: %s\n' \
    "$NAME" "$(clean_url "${SOURCE_URL:-—}")" "$(clean_url "${TARGET_URL:-—}")" "$BRANCHES" "$WORK_DIR" "$LOG_FILE" "${TARGET_PROJECT:-—}" "${TARGET_API_URL:-—}" "${PACKAGE_LOCKS:-—}"
  info "운영망 연결 재시도 ${TARGET_RETRIES}회 · 첫 대기 ${TARGET_RETRY_DELAY}초 (매번 두 배)"
  local t; for t in SOURCE TARGET; do if [ -n "$(read_token $t)" ]; then info "$t 토큰 있음"; else info "$t 토큰 없음 (git credential·SSH 로 인증)"; fi; done
  if [ -d "$REPO" ]; then
    hr "작업 저장소가 마지막으로 본 운영망 브랜치"
    G for-each-ref --format='  %(refname:lstrip=3)  %(objectname:short=12)' refs/airgap/target | while read -r b s; do match_branch "$b" && printf '  %-40s %s\n' "$b" "$s"; done || true
  fi
  [ -f "$LOG_FILE" ] && { hr "최근 기록"; tail -n 8 "$LOG_FILE" | column -t -s $'\t' 2>/dev/null || tail -n 8 "$LOG_FILE"; }
  return 0
}

# ---------- 인자 ----------
CMD="${1:-help}"; [ $# -gt 0 ] && shift
LOCAL_ONLY="" CONFIG="" DRY_RUN="" FORCE="" WITH_PACKAGES="" FULL="" OUT="" EXPECT_SHA="" REPORT="" BRANCHES_OVERRIDE="" REF_OVERRIDE=""
ONLY=() LOCK_FILES=() POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config) CONFIG="$2"; shift 2;;
    -n|--dry-run) DRY_RUN=1; shift;;
    --force) FORCE=1; shift;;
    --only) ONLY+=("$2"); shift 2;;
    --branches) BRANCHES_OVERRIDE="$2"; shift 2;;
    --with-packages) WITH_PACKAGES=1; shift;;
    --report) REPORT="$(upath "$2")"; shift 2;;
    -o|--out) OUT="$2"; shift 2;;
    --full) FULL=1; shift;;
    --sha256) EXPECT_SHA="$2"; shift 2;;
    --lock) LOCK_FILES+=("$2"); shift 2;;
    --ref) REF_OVERRIDE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) die $EX_USAGE "모르는 옵션: $1 (help 참고)";;
    *) POS+=("$1"); shift;;
  esac
done
case "$CMD" in help|-h|--help) usage; exit 0;; esac
CONFIG="${CONFIG:-${AIRGAP_CONFIG:-$HOME/.airgap-sync/airgap-sync.conf}}"
CONFIG="$(upath "$(expand_home "$CONFIG")")"
load_config "$CONFIG"
resolve_settings
[ -n "$REPORT" ] && [ "$CMD" != ci ] && rm -f "$REPORT"
case "$CMD" in
  mirror) cmd_mirror mirror;;
  ci) cmd_ci;;
  bundle-create) cmd_bundle_create;;
  bundle-push) [ ${#POS[@]} -ge 1 ] || die $EX_USAGE "bundle-push <bundle 파일>"; cmd_bundle_push "${POS[0]}";;
  packages) cmd_packages;;
  status) cmd_status;;
  *) usage >&2; exit $EX_USAGE;;
esac
