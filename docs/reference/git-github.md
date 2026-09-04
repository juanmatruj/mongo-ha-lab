# Reference · Git and GitHub

> Working reference for the `mongo-ha-lab` project.
> Covers Git's mental model, the commands used, configuration decisions, and
> practices common in professional environments.
> Suggested location: `docs/reference/git-github.md`

---

## Contents

1. [Git vs. GitHub](#1-git-vs-github)
2. [The three-area model](#2-the-three-area-model)
3. [Initial configuration](#3-initial-configuration)
4. [SSH authentication](#4-ssh-authentication)
5. [Basic workflow](#5-basic-workflow)
6. [Undoing things](#6-undoing-things)
7. [`.gitignore`](#7-gitignore)
8. [Secret prevention: pre-commit and gitleaks](#8-secret-prevention-pre-commit-and-gitleaks)
9. [Handling leaked secrets](#9-handling-leaked-secrets)
10. [Commit message conventions](#10-commit-message-conventions)
11. [Branches and workflow](#11-branches-and-workflow)
12. [Practices in professional environments](#12-practices-in-professional-environments)
13. [Anatomy of a professional repository](#13-anatomy-of-a-professional-repository)
14. [Command reference](#14-command-reference)
15. [Common errors and how to read them](#15-common-errors-and-how-to-read-them)

---

## 1. Git vs. GitHub

They are different things and it is worth not conflating them.

**Git** is a distributed version control system. It runs on your machine, works offline, and stores the project's full history in a hidden `.git/` directory inside the working folder. "Distributed" means every copy of the repository holds the entire history, not a fragment: no copy is technically privileged.

**GitHub** is a commercial service that hosts Git repositories and adds features Git itself lacks: a web interface, access control, pull requests, issues, continuous integration (GitHub Actions), secret scanning. Equivalent alternatives: GitLab, Bitbucket, Gitea, AWS CodeCommit.

Practical consequence: everything you learn about Git transfers to any platform. GitHub-specific features (Actions, the PR interface) transfer less directly, though the concepts translate well.

---

## 2. The three-area model

This is the central concept. Almost every confusing Git command becomes clear once you identify which areas it moves information between.

```
┌─────────────────────┐   git add    ┌─────────────────┐  git commit  ┌──────────────┐
│  Working directory  │ ───────────► │      Index      │ ───────────► │   History    │
│  (files on disk)    │              │ (staging area)  │              │  (commits)   │
└─────────────────────┘ ◄─────────── └─────────────────┘ ◄─────────── └──────────────┘
                         git restore                    git restore --staged
```

| Area | Contents | How to inspect |
|---|---|---|
| **Working directory** | Files exactly as they are on disk right now | `ls`, any editor |
| **Index** (*staging area*) | A snapshot of what will go into the next commit | `git status`, `git diff --staged` |
| **History** | Committed snapshots, immutable | `git log`, `git show` |

**Why the index exists.** It lets you assemble a commit deliberately: you may have modified eight files and decide that only four form a coherent change. A commit should tell a single story; the index is the tool for that.

**Observed case.** If you add a file to the index with `git add` and then delete it from disk with `rm`, `git status` will show it simultaneously as a *new file* staged for commit and as *deleted* in the working tree. This is not a contradiction: two areas are each reporting their own state.

A fourth element worth knowing: the **stash**, a temporary store for half-finished work you do not want to commit (`git stash`, `git stash pop`).

---

## 3. Initial configuration

```bash
git config --global user.name "First Last"
git config --global user.email "ID+username@users.noreply.github.com"
git config --global init.defaultBranch main
git config --global core.editor nano
```

| Setting | Purpose |
|---|---|
| `user.name` | Name recorded in every commit. For a portfolio, using a real name is desirable: you want to be identifiable |
| `user.email` | Email recorded in every commit. **Publicly exposed and permanent.** Hence GitHub's `noreply` address |
| `init.defaultBranch` | Initial branch name in new repositories. `main` is the current standard; `master` is historical and still found in older repositories |
| `core.editor` | Editor Git opens for long commit messages, interactive rebase, and so on. Defaults to `vim`, which surprises those unfamiliar with it |

**Configuration scopes**, lowest to highest precedence:

| Scope | File | Typical use |
|---|---|---|
| `--system` | `/etc/gitconfig` | Whole machine. Rare |
| `--global` | `~/.gitconfig` | Your user. The usual choice |
| `--local` | `.git/config` in the repo | A single repository |

Local wins over global. This is what allows different identities in personal and corporate repositories: in a work repository, `git config --local user.email "name@company.com"`.

```bash
git config --global --list        # view global configuration
git config user.email             # view the effective value here
```

### Email privacy on GitHub

Under **Settings → Emails**:

- *Keep my email addresses private* — enables the `noreply` address.
- *Block command line pushes that expose my email* — rejects a push if a commit carries your real address. A safety net against a misconfiguration.

And under **Settings → Password and authentication**, two-factor authentication. It is mandatory on GitHub and, in an infrastructure-oriented profile, its absence is a negative signal.

---

## 4. SSH authentication

Pushing code to a remote requires proving who you are. Two options: HTTPS with a personal access token, or SSH with a key pair. SSH is the professional standard, and as a DBRE you will work with SSH keys constantly for server access.

### Asymmetric cryptography in one line

A pair of mathematically related keys is generated. The **private** key never leaves your machine. The **public** key is handed out freely. What one encrypts or signs, only the other verifies, and knowing the public key does not allow deriving the private one.

```bash
ssh-keygen -t ed25519 -C "descriptive comment"
```

| Parameter | Meaning |
|---|---|
| `-t ed25519` | Algorithm. Ed25519 is the current recommendation: secure, fast, short keys. RSA remains valid with `-b 4096`; DSA and ECDSA are discouraged |
| `-C` | Comment embedded in the public key. Useful for identifying pairs when you have several |
| `-f path` | Output file path |
| `-N ""` | Empty passphrase. **Only for tests or controlled automation** |

Two files are produced in `~/.ssh/`:

| File | Nature |
|---|---|
| `id_ed25519` | **Private** key. Never shared, never copied elsewhere without reason, never committed to any repository. Mode `600` |
| `id_ed25519.pub` | **Public** key. This is what goes into GitHub or a server's `authorized_keys` |

**Always set a passphrase** on personal keys. It protects the key if someone gains access to your files. The `ssh-agent` keeps it unlocked for the session so you need not retype it:

```bash
eval "$(ssh-agent -s)"      # start the agent in the current session
ssh-add ~/.ssh/id_ed25519   # load the key (prompts once)
ssh-add -l                  # list loaded keys
```

### Verifying the connection

```bash
ssh -T git@github.com
```

The expected reply greets you by username and states that GitHub does not provide shell access. It looks like an error and it is the success case: authentication worked, that service simply offers no terminal.

The first time, it asks whether you trust the server's fingerprint. That is host key verification: SSH is telling you it does not yet know this server. GitHub publishes its official fingerprints, and comparing them is worthwhile even though almost nobody does.

---

## 5. Basic workflow

```bash
git init                       # create a repository in the current directory
git status                     # state of the three areas — check it constantly
git add file                   # working directory → index
git commit -m "message"        # index → history
git log --oneline --graph      # compact history
```

### Connecting a remote

```bash
git remote add origin git@github.com:user/repo.git
git push -u origin main
git remote -v                  # list configured remotes
```

| Element | Meaning |
|---|---|
| `origin` | Conventional name for the primary remote. It is only a label; it can be named otherwise, and a repository can have several remotes |
| `-u` (`--set-upstream`) | Links the local branch to the remote one. Afterwards `git push` and `git pull` work with no arguments |

### On `git add .`

**Avoid it as a habit.** It adds everything it finds, including files you had not anticipated: data dumps, temporary files, credentials you believed were handled separately. The correct sequence is to look first and add explicitly:

```bash
git status
git add README.md docs/
```

To review exactly what you are about to commit:

```bash
git diff              # changes not yet staged
git diff --staged     # staged changes, ready to commit
```

---

## 6. Undoing things

The prior question is always: **which area is the thing I want to undo in?**

| Situation | Command | Effect |
|---|---|---|
| Discard working directory changes | `git restore file` | Reverts to the last commit. **Destructive**: no recovery |
| Unstage while keeping changes | `git restore --staged file` | The file is no longer staged |
| Unstage a newly added file | `git rm --cached file` | Stops tracking, remains on disk |
| Undo the last commit, keep changes | `git reset --soft HEAD~1` | The commit disappears; changes return to the index |
| Undo the last commit and the changes | `git reset --hard HEAD~1` | **Destructive** |
| Undo the **root** commit | `git update-ref -d HEAD` | Removes the branch reference. Files remain on disk |
| Revert an already-published commit | `git revert <hash>` | Creates a new commit that undoes the previous one. **Does not rewrite history** |

### Why the root commit is a special case

`git reset HEAD~1` means "point the branch at the commit before the current one". If the current commit is the repository's first, there is no previous commit to point at. `git update-ref -d HEAD` handles the case by removing the reference directly.

### `reset` vs. `revert`

Operating rule: **`reset` for local history, `revert` for published history.** Rewriting history that others have already fetched causes them conflicts and forces manual resynchronisation. `revert` is additive and therefore safe in collaboration.

### Deleting does not delete

Removing a reference to a commit does not remove the object: it remains in `.git/objects` until garbage collection runs. To force it:

```bash
git reflog expire --expire-unreachable=now --all
git gc --prune=now
```

The `reflog` is also Git's safety net: it records where `HEAD` has recently been and allows recovering commits apparently lost to a `reset --hard`. Before writing something off, run `git reflog`.

### Command atomicity

`git rm` validates all its arguments before acting and **aborts the entire operation** if one does not match, rather than processing the valid ones. This is deliberate: a partial operation would leave the index in an intermediate state that is hard to reason about.

Interactively, failing on the unexpected is the safe option. In automation, a command that aborts over one missing file can halt an entire deployment, and you must decide explicitly which failures are tolerable:

```bash
git rm --cached --ignore-unmatch file1 file2
```

The same pattern recurs in Bash (`set -e`, `|| true`) and in Ansible (`failed_when`, `ignore_errors`). The decision is never "ignore errors", but **distinguishing the expected failure from the unforeseen one**.

---

## 7. `.gitignore`

A file at the repository root telling Git what not to track. It is versioned: it is part of the project.

### Syntax

| Pattern | Meaning |
|---|---|
| `.env` | A specific file |
| `*.key` | All files with that extension |
| `data/` | An entire directory |
| `!.env.example` | **Exception**: do not ignore this, despite a previous rule |
| `**/logs` | At any depth |
| `/build` | Only at the root, not in subdirectories |

The `.env` + `!.env.example` pattern is the standard for credentials: real files are ignored and a template with the required variables and placeholder values is versioned, so anyone cloning knows what to fill in.

### Critical limitation

**`.gitignore` only affects untracked files.** If a file is already in the index or in history, adding it to `.gitignore` does not remove it. It must be withdrawn explicitly:

```bash
git rm --cached file
```

And even then it remains in earlier commits. A `.gitignore` is prevention, never remedy.

---

## 8. Secret prevention: pre-commit and gitleaks

### What a hook is

A *hook* is a script Git runs automatically at a point in its lifecycle. The `pre-commit` hook runs before each commit is created; if it exits non-zero, the commit does not happen.

Hooks live in `.git/hooks/`, **a directory that is not versioned**. Anyone cloning the repository must enable them themselves, which is why it belongs in the README.

### The three distinct elements

| Element | What it is | Versioned |
|---|---|---|
| `pip install pre-commit` | The program, installed on your machine | No |
| `.pre-commit-config.yaml` | Declaration of which checks you want | **Yes** |
| `pre-commit install` | Writes the hook into `.git/hooks/pre-commit` | No |

The hook **reads the YAML file on every run**; it does not keep a copy. Editing the configuration takes effect on the next commit with no reinstallation.

### Configuration used

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.x.x
    hooks:
      - id: gitleaks

  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.x.x
    hooks:
      - id: detect-private-key
      - id: check-added-large-files
      - id: end-of-file-fixer
      - id: trailing-whitespace
      - id: check-yaml
```

| Hook | Function |
|---|---|
| `gitleaks` | Searches for credential patterns: tokens, API keys, connection strings with passwords |
| `detect-private-key` | Detects private key headers, such as the standard OpenSSH and PEM key preambles. A literal, deterministic check. |
| `check-added-large-files` | Blocks large files. Bulky binaries inflate the repository permanently |
| `end-of-file-fixer` | Ensures a trailing newline. Many Unix tools assume one |
| `trailing-whitespace` | Removes end-of-line whitespace, which adds noise to diffs |
| `check-yaml` | Validates YAML syntax. Very useful with Ansible and Docker Compose |

The two auto-fixers (`end-of-file-fixer`, `trailing-whitespace`) **modify the file and return failure** to notify you. This is not an error: re-run `git add` on the corrected files and commit again.

### Commands

```bash
pre-commit install         # enable the hook in this repository
pre-commit run --all-files # run across the project without committing
pre-commit autoupdate      # update `rev` values to the latest releases
```

### Version pinning

The `rev` field pins a specific version of each external tool. Without it, every run could pull different code than the one you tested.

This is a core principle in infrastructure work: **a deployment that is not reproducible is a deployment you do not control**. The same applies in Docker (never `latest` in production), Ansible (collection versions) and Terraform (provider version constraints).

The cost is falling behind and having to update deliberately. `autoupdate` is the mechanism for paying that cost in a controlled way.

### Limits of detection

Detection works on **known patterns**: the shape of an AWS key, a GitHub token prefix, a private key header. It does not understand meaning. A password such as `MyPass2026` is indistinguishable from ordinary text and will not be caught.

Additionally, `gitleaks` maintains **allowlists** of example values that appear in official documentation, precisely so it does not fire on any repository quoting them.

Every detection tool trades off false positives against false negatives, and the conservative calibration exists for a practical reason: a tool that alerts excessively gets disabled by its users, at which point it protects nothing at all. The same trade-off appears in monitoring alert design, where a noisy alert ends up ignored and **an ignored alert is worse than no alert**, because it creates a false sense of coverage.

**Operational conclusion:** automated scanning is a safety net against slips, not a substitute for judgement or for `.gitignore`. Defence is layered and no single layer suffices.

### Verifying the protection

A protection you have not tested is an assumption. A deterministic test:

```bash
ssh-keygen -t ed25519 -f ./test-key -N "" -C "test"
git add test-key
git commit -m "test"        # must fail on detect-private-key
```

Cleanup afterwards:

```bash
git rm --cached --ignore-unmatch test-key
rm -f test-key test-key.pub
git status                  # must be clean
```

### Server-side defence

On GitHub, under **Settings → Code security**:

- **Secret scanning** — analyses repository content.
- **Push protection** — rejects a push containing anything resembling a credential.

Free on public repositories. It is the final layer, the one that acts when everything else has failed.

---

## 9. Handling leaked secrets

**A rule that admits no exceptions: a secret that has left your machine is considered compromised and must be rotated — invalidated and replaced.**

Deleting it from history is not enough. Once published, there are clones, forks, platform caches, CI systems and indexing engines outside your control that may retain it indefinitely. Automated scanners watch public repositories for credentials; the interval between publication and exploitation is measured in minutes.

Procedure after a leak:

1. **Rotate the credential immediately.** This is first and urgent.
2. Review access logs for misuse.
3. Clean the history (`git filter-repo`, or BFG Repo-Cleaner) — cosmetic, but prevents further exposure.
4. Document the incident and fix the condition that allowed it.

Order matters: cleaning history before rotating spends effort on the step that does not reduce risk.

### Sensitive information beyond passwords

In a public repository, also review for:

- Absolute paths revealing usernames or machine layout.
- Internal IP addresses, hostnames and network topology.
- Personal emails, phone numbers, client names.
- Unredacted screenshots.
- Configuration files with real endpoints or identifiers.

---

## 10. Commit message conventions

The most widespread standard is **Conventional Commits**:

```
type: short description in the imperative
```

| Type | Use |
|---|---|
| `feat` | New functionality |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `chore` | Maintenance, configuration, dependencies |
| `refactor` | Internal change with no behavioural difference |
| `test` | Adding or fixing tests |
| `ci` | Continuous integration changes |
| `perf` | Performance improvement |

```
feat: add keyfile authentication between nodes
fix: correct keyfile permissions preventing startup
docs: document the credential rotation procedure
chore: update pre-commit hook versions
```

Practical benefits: the history reads at a glance, changelogs can be generated automatically, and locating when a behaviour was introduced becomes easier.

**Writing guidance.** Present imperative ("add", not "added"). First line under 72 characters. If explanation is needed, leave a blank line and write a body — **the message should explain why, not what**: the what is already in the diff.

A poor history (`changes`, `fix`, `now it works`) is an immediate negative signal in a portfolio review.

---

## 11. Branches and workflow

A branch is a movable pointer to a commit. Creating them is instantaneous and cheap.

```bash
git branch                      # list branches
git switch -c feat/replicaset   # create and switch to a new branch
git switch main                 # switch branches
git merge feat/replicaset       # merge a branch into the current one
git branch -d feat/replicaset   # delete an already-merged branch
```

`git switch` and `git restore` are the modern commands that split the responsibilities of the old `git checkout`, which did too many different things and was confusing. `checkout` still works and appears in older documentation.

### Common professional workflow

The dominant model is **trunk-based development with short-lived branches**:

1. Short branch off `main` for a specific change.
2. Small, coherent commits.
3. Push the branch and open a pull request.
4. Review by another person and automated CI.
5. Merge to `main` and delete the branch.

`main` should always be in a deployable state. Long-lived branches accumulate divergence and produce painful merges.

In a personal project, opening PRs against yourself may feel artificial, but it records the process and demonstrates familiarity with the professional flow. In a portfolio, that counts.

### Branch protection

In professional repositories, `main` is protected: no direct pushes, at least one approval required, and CI must pass. Configured under **Settings → Branches → Branch protection rules**.

---

## 12. Practices in professional environments

**Small, coherent commits.** One per logical change. This eases review and lets `git bisect` locate the origin of a bug.

**Never rewrite shared history.** `push --force` on a branch others use destroys their work. If unavoidable, use `--force-with-lease`, which aborts if the remote changed since your last fetch.

**Systematic code review.** Nobody merges their own change into production unreviewed. It is quality control and knowledge sharing at once.

**Everything as code.** Configuration, infrastructure, alerting policies and documentation live in the repository under the same review cycle as the code. This is the basis of IaC and GitOps.

**CI on every change.** Automated checks run on the platform, not only on a developer's machine. Local hooks can be bypassed with `--no-verify`; CI cannot.

**The repository documents itself.** Anyone cloning it should be able to get started without asking.

**Secrets never in the repository.** They are handled with local `.env` files, dedicated managers (Vault, AWS Secrets Manager, SOPS, `ansible-vault`) or CI platform secrets.

---

## 13. Anatomy of a professional repository

```
project/
├── README.md                 what it is, why, how to run it
├── LICENSE                   without one, nobody may legally reuse it
├── .gitignore
├── .pre-commit-config.yaml
├── Makefile                  single entry point: make up / test / clean
├── .github/workflows/        continuous integration
├── docs/
│   ├── reference/            per-tool guides
│   ├── adr/                  justified architecture decisions
│   └── runbooks/             operational procedures
├── scripts/
└── tests/
```

**README.** The first thing read and often the only thing. It should cover what the project solves, an architecture diagram (Mermaid renders natively on GitHub), quick start, requirements and structure. Write it as you go; leaving it for the end means leaving it undone.

**ADR** (*Architecture Decision Record*). A short document per significant decision: context, options considered, decision, consequences. A repository that justifies its decisions demonstrates judgement, not just execution. This is what most distinguishes a portfolio in technical review.

**Runbooks.** Step-by-step operational procedures for specific tasks — rotating credentials, adding a node, restoring a backup. Everyday DBRE work and very rare in portfolios.

**License.** MIT (permissive, most common), Apache 2.0 (permissive with a patent clause) or GPL (requires derivative works to keep the same terms). Without a license file, default copyright applies and nobody may legally reuse the code.

---

## 14. Command reference

### Configuration
```bash
git config --global user.name "Name"
git config --global user.email "email"
git config --global --list
git config --local user.email "email@company.com"
```

### Inspection
```bash
git status                        # state of the three areas
git diff                          # unstaged changes
git diff --staged                 # staged changes
git log --oneline --graph --all   # compact history
git show <hash>                   # details of a commit
git reflog                        # where HEAD has been — safety net
git blame file                    # who changed each line and when
git grep -n "pattern"             # search tracked files
git check-ignore -v file          # which rule ignores this file
```

### Basic cycle
```bash
git init
git add file
git commit -m "type: message"
git push
git pull
```

### Remotes
```bash
git remote -v
git remote add origin git@github.com:user/repo.git
git push -u origin main
git clone git@github.com:user/repo.git
git fetch --prune                 # drop stale remote-tracking references
```

### Branches
```bash
git switch -c branch-name
git switch main
git merge branch-name
git branch -d branch-name
git push origin --delete branch-name
```

### Undoing
```bash
git restore file                  # discard local changes (destructive)
git restore --staged file         # unstage
git rm --cached file              # stop tracking, keep on disk
git reset --soft HEAD~1           # undo commit, keep changes
git update-ref -d HEAD            # undo the root commit
git revert <hash>                 # undo a published commit
git stash / git stash pop         # shelve and restore work in progress
```

### SSH
```bash
ssh-keygen -t ed25519 -C "comment"
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
ssh-add -l
ssh -T git@github.com
```

### pre-commit
```bash
pre-commit install
pre-commit run --all-files
pre-commit autoupdate
```

---

## 15. Common errors and how to read them

| Message | Cause | Fix |
|---|---|---|
| `fatal: could not resolve 'HEAD'` | No commits exist yet | Use `git rm --cached` instead of `git restore --staged` |
| `fatal: pathspec ... did not match` | One argument is not in the index; the command aborts entirely | Retry without that file, or use `--ignore-unmatch` |
| `Permission denied (publickey)` | SSH key not loaded, or not registered on GitHub | `ssh-add -l`, check the public key on GitHub |
| `rejected — non-fast-forward` | The remote has commits you do not have locally | `git pull --rebase` and retry |
| `remote ref does not exist` | The remote branch was already deleted; your local reference is stale | `git fetch --prune` |
| `uses deprecated stage names` | Outdated hook repository version | `pre-commit autoupdate` |
| A hook modifies files and fails | Normal behaviour of the auto-fixers | `git add` the corrections and commit again |
| `.gitignore` has no effect | The file was already tracked | `git rm --cached file` |
| `warning: deleting branch ... not yet merged to HEAD` | The work is merged in the remote reference but not in your local branch | `git pull` on `main` before deleting |

### A recurring theme

Git is distributed and **synchronises nothing on its own**. Merging on GitHub does not update your local repository; deleting a branch on GitHub does not clean your cached references; `origin/*` is not the remote but your last snapshot of it. Every operation is explicit.

A multi-step process interrupted halfway leaves the system in a state that **looks complete but is not**. The remedy is verification: check `git log` after pulling, before deleting anything.

---

## Further reading

- **Pro Git** (Chacon & Straub) — the reference book, free at `git-scm.com/book`. Chapters 2, 3 and 7 cover almost everything professional.
- `git help <command>` — local documentation, more complete than most tutorials.
- **Conventional Commits** — `conventionalcommits.org`
- **gitleaks** — `github.com/gitleaks/gitleaks`
- **pre-commit** — `pre-commit.com`

---

*`mongo-ha-lab` project reference*
