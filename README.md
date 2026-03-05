# Guardian 🛡️

CLI tool for managing command protections. Designed to prevent AI agents (and humans) from running dangerous commands - like pushing directly to protected branches or running `npm install` in the wrong environment.

## How It Works

Guardian wraps system commands (git, npm, gh, etc.) with a protection layer. Rules are **append-only by default** - anyone can add blocks, but only the password holder can remove them.

- Wrapper files are **root-owned** and can't be edited directly
- The real binaries are hidden - direct access is blocked
- Rules are stored in `/etc/guardian/rules/`
- Password is hashed (SHA-256) and set once on init

## Install

```bash
sudo cp guardian /usr/local/bin/
sudo chmod +x /usr/local/bin/guardian
sudo guardian init    # Set your password (interactive)
```

## Usage

### Add a rule (no password needed)

```bash
sudo guardian add git commit branch:dev "Direct commits to dev are not allowed. Use a feature branch."
sudo guardian add git push branch:main "Direct push to main is not allowed."
sudo guardian add git cherry-pick branch:dev "cherry-pick on dev is not allowed."
sudo guardian add git merge branch:dev "merge on dev is not allowed. Use a PR."
sudo guardian add npm install any "npm install is blocked on WSL. Run from PowerShell."
sudo guardian add gh "pr merge" any "Merge requires explicit approval."
```

### Remove a rule (password required)

```bash
sudo guardian remove git commit    # Will prompt for password
```

### List all rules

```bash
guardian list
```

### Check status

```bash
guardian status
```

### Test if a command is blocked

```bash
guardian test git commit
guardian test npm install
```

## Context Options

When adding a rule, you can specify when it applies:

| Context | Description | Example |
|---------|-------------|---------|
| `any` | Block everywhere (default) | `sudo guardian add npm install any "blocked"` |
| `branch:<name>` | Block only on specific branch | `sudo guardian add git commit branch:dev "blocked"` |
| `env:<KEY>=<VAL>` | Block when env var is set | `sudo guardian add git commit env:LEFTHOOK=0 "blocked"` |
| `flag:<flag>` | Block when flag is used | `sudo guardian add git commit flag:--no-verify "blocked"` |

## What Gets Blocked (Example Setup)

### Git (on dev/main branches)
- `commit`, `push`, `cherry-pick`, `revert`, `pull`, `rebase`, `merge`, `am`, `reset`
- All variations: `--amend`, `--no-verify`, `-c core.hooksPath=...`, `--force`, etc.

### Git (allowed on any branch)
- `status`, `log`, `diff`, `branch`, `checkout`, `stash`, `fetch`, `add`, `tag`, `show`, `blame`, `config`, `clone`, etc.

### npm
- **Blocked:** `install`, `i`, `ci`, `clean-install`
- **Allowed:** `run`, `list`, `version`, `audit`, `test`, `start`, etc.

### gh (GitHub CLI)
- **Blocked:** `pr merge`
- **Allowed:** `pr list`, `pr view`, `pr create`, `issue`, `release`, `run`, etc.

## Design Principles

1. **Append-only by default** - Easy to add protections, hard to remove them
2. **Password-protected removal** - Only the password holder can weaken protections
3. **Root-owned files** - Can't be edited by non-root users or AI agents
4. **No hook bypassing** - Protection is in the wrapper, not in git hooks. `--no-verify`, `LEFTHOOK=0`, and `core.hooksPath` overrides don't help.
5. **One-time password** - Set on `init`, can't be changed (by design)

## Testing

```bash
bash test-guardian.sh         # Basic tests (32 cases)
bash test-guardian-edge.sh    # Edge cases (176 cases)
```

## License

MIT
