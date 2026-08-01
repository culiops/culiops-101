# Guardrails for AI coding agents

Companion code for the video: three layers you turn on before letting an AI coding agent
run commands on your machine. Everything here runs locally — no cloud account needed.

In August 2025 the Nx supply-chain attack did not defeat a guardrail. The malware called
the developer's **own installed agents** and asked them to go find the secrets, harvesting
GitHub tokens, npm tokens, SSH keys and environment variables from 1,000+ accounts into
public repos owned by the victims. No vulnerability was exploited. The agents did what they
were allowed to do.

These are the settings that would have made that a non-event.

## Prerequisites

- **Claude Code v2.1.199+** — `sandbox.credentials` needs 2.1.187, `mode: "mask"` needs
  2.1.199. Older builds silently strip unknown entries with a warning, which is the same
  silent-downgrade failure this lab is about. Check with `claude --version`.
- Linux/WSL2 or macOS. Native Windows cannot run the sandbox; use WSL2.
- Equivalents for Cursor, Gemini CLI and Copilot are noted inline below.

The files in `settings/` are cumulative — each is complete on its own. Copy the one for the
layer you want into `~/.claude/settings.json` (user scope) or `.claude/settings.json`
(project scope, committed so a team inherits it).

## Layer 1 — don't hand over the keys (~5 min)

```bash
cp settings/01-deny-secrets.json ~/.claude/settings.json
```

`permissions.deny` blocks reading `.env`, `secrets/`, `*.pem`, `id_rsa*`.
`sandbox.credentials` denies `~/.aws/credentials`, `~/.ssh`, gcloud and kube config, and
unsets `GITHUB_TOKEN` / `NPM_TOKEN` / AWS keys before a sandboxed command runs.

Two things that are easy to miss in the docs:

- **There is no built-in credential deny list.** The sandbox's default read policy still
  allows `~/.aws/credentials` and `~/.ssh`. If you don't list them, nothing blocks them.
- **`deny` rules merge across scopes** and no scope can remove one another scope added, so
  committing this to the repo cannot be quietly switched off locally.

The `credentials` half only bites while the sandbox is on (`"enabled": true`) — free on
macOS, Layer 2 on Linux. The `permissions.deny` half works either way.

Need a token to stay usable for `gh` or `npm`? On **environment variables only**,
`"mode": "mask"` shows the agent a sentinel and substitutes the real value on requests to
hosts you name. Two traps: it needs TLS termination at the sandbox proxy, and it is ignored
when it comes from repo settings. File entries accept `deny` only. And a masked credential
still never expires — prefer short-lived ones (GitHub App tokens last 1h, STS sessions
default to 1h, give a PAT an expiry).

This is a policy layer, evaluated before a command runs. It is not a wall.

## Layer 2 — turn on the sandbox (~30 min on Linux)

```bash
./scripts/enable-sandbox-linux.sh --check   # reports what is missing, changes nothing
./scripts/enable-sandbox-linux.sh           # installs it (needs sudo)
cp settings/02-sandbox.json ~/.claude/settings.json
```

On Ubuntu 24.04+ this is genuinely two steps: `bubblewrap` + `socat`, **and** an AppArmor
profile, because the default policy blocks bubblewrap from creating user namespaces. Skip
the second and the sandbox silently never engages. macOS needs none of this (Seatbelt is
built in).

The load-bearing line in the file:

```json
"failIfUnavailable": true
```

**By default, when the sandbox cannot start, Claude Code prints a warning and runs the
commands anyway, unsandboxed.** You would believe you were protected while running bare.

Scope it to the project while you are here. Two lines, and the agent stops seeing the rest
of your home directory — company keys, other repos, another project's `.env`:

```json
"filesystem": { "denyRead": ["~/"], "allowRead": ["."] }
```

That `.` only resolves to the project root from **project** settings
(`.claude/settings.json` in the repo), not from `~/.claude/`.

### Proving it actually engaged

The obvious test is a bad test. Asking the agent to read a private key and POST it
somewhere gets refused by the model itself, before the sandbox is ever consulted — so you
cannot tell the guardrail from the model's own judgement. Use harmless commands the model
*will* run but the sandbox stops:

```bash
# filesystem layer — a file outside the project it should not be able to read
echo secret > ~/outside.txt
claude -p 'run: cat ~/outside.txt'                            # -> "No such file or directory"

# network layer — a host that is not on the allowlist
claude -p 'run: curl -sS --max-time 8 https://example.com'    # -> proxy 403
```

The first fails because `denyRead ~/` hides the file at the OS level; a file *inside* the
project still reads fine, which is the scope working rather than a blanket block. The
second is refused by the sandbox's network proxy.

Keep `allowedDomains` short. Anthropic's docs warn that allowing a broad domain such as
`github.com` can itself become an exfiltration path — which is exactly where the Nx malware
sent everything it stole.

And the quiet part, from the same docs: *"sandboxing reduces risk but is not a complete
isolation boundary."* The proxy filters on the hostname the client claims and does not
inspect TLS by default. Good layer. Not a wall.

## Layer 3 — never the bypass flag (~2 min)

```bash
cp settings/03-strict.json ~/.claude/settings.json
```

The Nx payload ran these on developers' own machines:

```
claude --dangerously-skip-permissions -p [PROMPT]
gemini --yolo                         -p [PROMPT]
q chat --trust-all-tools --no-interactive [PROMPT]
```

Don't rely on willpower at 2am. Make it structural:

```json
"allowUnsandboxedCommands": false
```

Strict sandbox mode — the escape hatch is ignored entirely. Managing a team? Ship this
through managed settings so nobody can widen it.

Second brake, and it works with **every** tool including the ones whose guardrails are
weak: give the agent a workspace you can throw away.

```bash
git worktree add ../agent-run -b agent/refactor-auth
# ... let the agent work in ../agent-run ...
git worktree remove ../agent-run --force
```

This is the only layer that also covers the destructive accident. Layers 1 and 2 are about
leakage; this one is about loss.

## Check your own defaults

| Tool | Enable | Default |
|---|---|---|
| Claude Code | `/sandbox` | **off** |
| Gemini CLI | `-s` / `GEMINI_SANDBOX=docker` | macOS: Seatbelt · **Linux: none** |
| Copilot coding agent | org *Internet access* tab | firewall **on** |
| Cursor | Run Modes | terminal commands need approval |

Cursor's own docs call Run Modes *"best-effort guardrails rather than a hard security
boundary"*, and the denylist was deprecated in 1.3 after researchers found bypasses. That
is honest of them, and it is why layer 3 matters most.

## Troubleshooting

- **`/sandbox` shows only a Dependencies tab.** The AppArmor profile did not install. Run
  `./scripts/enable-sandbox-linux.sh --check` again.
- **Removing the AppArmor profile doesn't disable it.** Deleting `/etc/apparmor.d/bwrap`
  and reloading does *not* unload it from the kernel — `aa-status` still lists it. Use
  `apparmor_parser -R` if you want to reproduce the "sandbox cannot start" behaviour.
- **Settings appear to do nothing.** Check `claude --version`. Below v2.1.199 invalid
  entries are stripped with a warning and the valid subset is enforced.

## Cost

Zero. Everything here runs on your own machine.

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs. Full walkthrough on the CuliOps YouTube channel.
