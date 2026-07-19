# CuliOps 101

Companion source code for videos on the **CuliOps** YouTube channel. Each video gets its
own folder, named by release month and topic — clone it, run it, break it, learn.

## Contents

| Folder | Topic | Video |
|---|---|---|
| [`2026-06-docker-to-fargate`](2026-06-docker-to-fargate) | Ship a Docker container to real production on AWS ECS Fargate | CuliOps on YouTube |
| [`2026-07-github-actions-deploy-fargate`](2026-07-github-actions-deploy-fargate) | Auto-deploy to ECS Fargate with GitHub Actions + OIDC — no stored AWS keys | CuliOps on YouTube |
| [`2026-07-backup-restore-drill`](2026-07-backup-restore-drill) | A backup you never restored is not a backup — restore drill, compression, encryption at rest (local PostgreSQL) | CuliOps on YouTube |

## Usage

```bash
git clone https://github.com/culiops/culiops-101.git
cd culiops-101/<video-folder>
# read that folder's README and follow along
```

Every folder has its own README with prerequisites, run steps, and how to clean up.

## Heads up

Some labs create **billable** cloud resources (AWS, etc.). Each lab ships a `cleanup.sh` —
run it when you're done so you don't get a surprise bill. Estimated cost is noted in each
lab's README (usually a few cents if you tear down right away).

## License

See [LICENSE](LICENSE). This code is for learning and reference — use it freely, and you're
responsible for anything you run on your own cloud account.

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs.
