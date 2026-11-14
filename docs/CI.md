# GitHub Actions checks

FaceTrack uses GitHub Actions for repeatable checks. **These workflows never deploy,
sign, or distribute a client build.** Azure releases still use the operator-run
procedure in [DEPLOY_AZURE.md](DEPLOY_AZURE.md). A successful CI run is not a
physical camera check or permission to publish attendance.

## What runs

| Workflow | Trigger | Checks |
|---|---|---|
| Changed-component CI | Pull request, push to `main`, or manual run | Selects API, worker/ML, Flutter, web-build and browser jobs from changed paths. A manual run exercises all jobs. |
| Repository and deployment checks | Every pull request and `main` push, or manual run | Checks workflow syntax, rejects tracked private artifacts and obvious credential values, and checks shell/Compose and web activation rollback tests. |
| Android compile check | Manual only | Compiles a **debug**, unsigned-for-release Student or Teacher APK to catch Android build failures. It is not uploaded or suitable for client delivery. |

The `CI gate` job fails when any selected component job fails. When configuring
branch protection, require **CI gate** and the **safety** job from Repository
and deployment checks. Do not require individual optional component jobs: they
are intentionally skipped when their paths did not change. Keep workflow-file
changes under review before merging.

The API test job starts its own guarded local PostgreSQL 16 cluster and mocks
Auth/Storage. Worker/ML tests use synthetic fixtures. None of these jobs use
live Supabase, Azure credentials, private model weights, student media, or
release signing material. The ML freeze receipt and signed Android camera
checks remain operator release gates.

## Run the same checks locally

Use the commands in [INSTALLATION.md](INSTALLATION.md#8-tests-that-need-no-private-data).
The API, worker and ML jobs use their separate `uv.lock` files; Flutter uses
`pub get --enforce-lockfile` and Flutter 3.47.7. Browser capture tests use Node.
The repository safety commands are:

```sh
python3 .github/scripts/check_tracked_files.py
sh -n deploy/azure/deploy.sh
cd deploy/azure && python3 -m unittest -q test_activate_web
docker compose -f compose.yaml config --quiet
docker compose -f compose.windows.yaml config --quiet
```

The tracked-file check is a guard against accidental commits, not a replacement
for credential review. Keep `.local/`, `.env`, keystores, media, templates and
private model files out of Git and CI artifacts. If a secret was committed,
remove it and rotate the credential; simply deleting the file in a later commit
does not revoke it.

Dependabot groups GitHub Action updates into one monthly pull request. Review
those updates and let the same CI checks run before merging.

## Cost and troubleshooting

The repository is public. Standard GitHub-hosted runners are free for public
repositories, but downloads and jobs still take time. Jobs run only for affected
components; dependency caches use committed lockfiles. CI publishes no large
APK or web-build artifacts. On a failure, open the failed job and its last step;
the short test output identifies the failing test. Re-run the job after fixing
the cause. A failure in the local PostgreSQL setup is a CI infrastructure
failure, not evidence that hosted Supabase is down.
