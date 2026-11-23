# airgap-sync

**Mirror only your release branches from one GitLab to another across an air gap, and carry the binaries that go with them.**

[한국어](README.ko.md)

You have two GitLab instances on separated networks: a development GitLab and a production (closed-network) GitLab. The only thing that bridges them is one machine, a laptop or jump PC, that can reach the development side, the production side, or sometimes both. `airgap-sync` runs on that machine:

- It pushes **only** the branches that match your patterns (default `release/*` and `main`). Other branches, tags and deletions stay behind.
- It **refuses non-fast-forward updates**. If the production branch has commits the development branch doesn't, nothing is pushed and the tool exits with code 3. `--force` overrides this, and only when you pass it explicitly. Even then it pushes with `--force-with-lease`.
- It logs every run in a TSV file: the time, the target, and the old SHA → new SHA for each branch. `--dry-run` shows the plan without changing anything.
- It works two ways:
  - **(a) Connected:** when the bridge machine reaches both GitLabs at once, run `mirror`, or run it as a CI job on a shell-executor runner on that machine.
  - **(b) Disconnected:** when it can't, use a two-step `git bundle` handoff. Run `bundle-create` on the development network, which records the sha256. Switch networks, then run `bundle-push`. The push is rejected (exit 4) if the sha256, `git bundle verify`, or the manifest doesn't match.
- It can optionally carry binaries. Lock files list images and jars with their sha256, and `--with-packages` uploads them to the target's generic package registry **before** pushing branches, because a push to `main` usually starts the deployment that downloads them. Each file is checked against its sha256 and skipped if it's already there.
- It runs on Linux, macOS and Windows. The logic lives in one bash script, and `airgap-sync.ps1` runs it through Git for Windows from PowerShell 5.1 or 7.

Console output and the log are in Korean, and the full manual is in [README.ko.md](README.ko.md). This page covers the essentials in English.

```
 (a) connected — one step
   dev GitLab ──fetch──▶ [bridge: mirror / CI job "ci"] ──packages──▶ target package registry
                                                       └──push──────▶ target GitLab (fast-forward only)

 (b) disconnected — two steps
   [on dev network]     bundle-create ──▶ x.bundle + x.bundle.sha256 + x.bundle.manifest
   ───────────── switch networks (same machine, or carry the files) ─────────────
   [on target network]  bundle-push x.bundle --sha256 <recorded value>
                        sha256 → git bundle verify → manifest → fast-forward check → packages → push
```

## Quick start

Requirements: git 2.31 or later, bash 4 or later, and curl. On Windows, Git for Windows provides all three.

```bash
git clone https://github.com/hongsw/airgap-sync && cd airgap-sync
mkdir -p ~/.airgap-sync && chmod 700 ~/.airgap-sync
cp airgap-sync.example.conf ~/.airgap-sync/airgap-sync.conf     # fill in SOURCE_URL, TARGET_URL, ...
printf '%s' '<target token>' > ~/.airgap-sync/target.token && chmod 600 ~/.airgap-sync/target.token

./airgap-sync.sh status
./airgap-sync.sh mirror --dry-run                 # (a) see what would be pushed
./airgap-sync.sh mirror --with-packages           # (a) packages first, then branches

./airgap-sync.sh bundle-create --with-packages    # (b) step 1, on the dev network
./airgap-sync.sh bundle-push <file>.bundle --sha256 <hex> --with-packages   # (b) step 2, on the target network
```

On Windows, run `.\airgap-sync.ps1` with the same arguments.

## Tokens

| Where | Scope | Used for | Stored |
|---|---|---|---|
| Source (dev) GitLab | `read_repository`, or an SSH key | fetch | on the bridge machine. In CI the job token is used automatically |
| Target GitLab | `write_repository` + `api` (Maintainer to push a protected `main`) | push, package lookup and upload | **only** in a file on the bridge machine (`TARGET_TOKEN_FILE`, mode 600) |

Never put the target token in the repository or in the source GitLab's CI/CD variables. Anyone who administers that server, or who can edit its jobs, could then write to production.

The tool never puts tokens on a command line:
- git gets them as an auth header through `GIT_CONFIG_*` environment variables.
- curl reads them from a config on stdin.
- URLs shown on screen or written to the log are stripped of credentials.

## Configuration

Settings are `KEY=VALUE` lines; see [`airgap-sync.example.conf`](airgap-sync.example.conf) for every key. The config file is found in this order: `-c FILE`, then `$AIRGAP_CONFIG`, then `~/.airgap-sync/airgap-sync.conf`. Any key can be overridden with an `AIRGAP_<KEY>` environment variable.

If the target hostname doesn't resolve on the bridge machine, set `TARGET_RESOLVE=<host>:<port>:<ip>`. It applies only to git (`http.curloptResolve`) and curl (`--resolve`); the system hosts file and network settings stay untouched.

## Packages (lock files)

Each lock file describes one package. The package name is the lock file's name without `.lock`, and each file is uploaded to `generic/<package>/<version>/<file>`. Two formats are accepted:

```
# format A — one per line: <name:version> <file> <sha256>   (version = text after the last ':')
registry.example/img:1.2.3 img-1.2.3.tar 0b8c…(64 hex)

# format B — key=value
version=abc123-job42
file=app-ext.jar
sha256=6497…(64 hex)
```

For each file:
1. If the registry already has the file and its sha256 matches the lock, the file is skipped. If the sha256 differs, the run fails and nothing is overwritten.
2. Otherwise the file is looked up in `PACKAGE_DIRS` (separated by `;`). If the local sha256 doesn't match the lock, the run fails.
3. After the upload, the sha256 the server reports is checked again.

If the package step fails, no branches are pushed.

## CI job and always-on runner (mode a)

1. Vendor `airgap-sync.sh` and `airgap-sync.ps1` into the source repository at `tools/airgap-sync/`.
2. Paste the jobs from [`ci/gitlab-ci.example.yml`](ci/gitlab-ci.example.yml) into that repository's `.gitlab-ci.yml`.
3. Set the project CI/CD variable `AIRGAP_SYNC` to `bash` or `powershell`. The jobs exist only where this variable is set, so the same `.gitlab-ci.yml` is harmless on the target GitLab.
4. Register a project runner on the bridge machine with tag `airgap`, the shell executor, and untagged jobs turned off. You can install gitlab-runner natively, or use [`runner/docker-compose.example.yml`](runner/docker-compose.example.yml) to run it as an always-on container (`restart: unless-stopped`).

The job is **manual by default**, because pushing `main` to production usually deploys. Setting `AIRGAP_SYNC_AUTO=1` makes it run on every push to `main` or `release/*`.

A push pipeline syncs only its own branch; web and scheduled pipelines sync every branch that matches. For a manual run, `AIRGAP_DRY_RUN=1`, `AIRGAP_FORCE=1` and `AIRGAP_WITH_PACKAGES=1` are available.

## Exit codes and log

| Code | Meaning |
|---|---|
| 0 | success, including "nothing to push" |
| 1 | usage or config error |
| 2 | network or push failure |
| 3 | a branch is not a fast-forward, so nothing was pushed (`--dry-run` also returns 3) |
| 4 | bundle rejected: sha256, verify, or manifest mismatch |
| 5 | package mismatch or missing file |

Every run appends to `WORK_DIR/sync-log.tsv` (default `~/.airgap-sync/work/<NAME>/sync-log.tsv`). Each row has these columns:

```
time  mode  name  target  branch  old_sha  new_sha  result  note
```

Possible `result` values:
- Branches: `created`, `pushed`, `forced`, `up-to-date`, `dry-run`, `rejected-non-ff`, `failed`, `bundled`
- Bundle rejections: `rejected-sha256`, `rejected-verify`, `rejected-manifest`
- Packages: `pkg-uploaded`, `pkg-skip`, `pkg-missing`, `pkg-bad-local`, `pkg-conflict`, `pkg-failed`

`--report FILE` (or running as a CI job) also writes only the current run's rows to a separate file, `airgap-sync-report.tsv` in CI.

## Testing

`test/e2e-local-gitlab.sh` treats two projects on one local GitLab as "dev" and "prod" and runs both modes end to end. Its tokens use exactly the scopes listed above. When it finishes, it deletes everything it created.

```bash
export E2E_GITLAB_TOKEN=<admin api PAT>            # E2E_GITLAB_URL defaults to http://localhost:8929
bash test/e2e-local-gitlab.sh                      # (a) mirror + (b) bundle
E2E_RUNNER=1 bash test/e2e-local-gitlab.sh         # + the CI job from ci/, on a Docker shell-executor runner
E2E_VIA_PS=1 bash test/e2e-local-gitlab.sh         # drive the tool through airgap-sync.ps1 (Windows)
```

What the test checks:
- Only `release/*` and `main` are transferred.
- A commit made directly on prod makes the run stop, and the other branches are left untouched too. `--force` then overwrites.
- A package whose sha256 doesn't match stops the run before any branch is pushed, and packages that are already present are skipped.
- A wrong sha256, a tampered file, or a missing reference value rejects the bundle. Incremental bundles work.
- Each step of mode (b) works without reaching the other network.
- No token appears in CI traces or in the log.

A ready-made local GitLab (CE 19.5 with a runner) is available at [local-gitlab-ai](https://github.com/hongsw/local-gitlab-ai).

## License

MIT
