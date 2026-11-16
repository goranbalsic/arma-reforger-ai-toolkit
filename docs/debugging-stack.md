# Debugging and security stack

What to run on this repo (PowerShell + Python + C# WPF + the local web dashboard),
and how to wire it into OpenCode. Everything here is free/open source except the
optional paid tiers, which are marked.

**Rule:** an agent reviewing code is not a security gate. Scanners catch patterns,
tests catch behaviour, CI enforces both. Keep the agent as a fast first pass.

## Tier 0 - seconds, after every change

| Tool | Repo | What it catches | Run |
| --- | --- | --- | --- |
| PSScriptAnalyzer | [PowerShell/PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) | PowerShell errors (unapproved verbs, null members, overwritten automatic vars like `$args`) | `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error` |
| ruff | [astral-sh/ruff](https://github.com/astral-sh/ruff) | Python syntax errors, undefined names, dead imports | `ruff check --select E9,F .` |
| python | stdlib | compile errors | `python -m py_compile <file>` |
| node | nodejs.org | the dashboard page's JavaScript (a syntax slip there kills the whole UI) | `node --check page.js` |
| gitleaks | [gitleaks/gitleaks](https://github.com/gitleaks/gitleaks) | committed keys, tokens, DPAPI blobs pasted into code | `gitleaks detect --no-git --redact` |

`tools/audit.ps1` in this repo runs PSScriptAnalyzer, ruff, gitleaks and the
page's `node --check` (the last two offline, so a broken page is caught without
the dashboard running), and exits non-zero on findings. Warning-severity
PSScriptAnalyzer rules (verb naming, `Write-Host`) are style here and are not a
gate - `PSAvoidAssignmentToAutomaticVariable` is the one to watch by hand.

## Tier 1 - before a commit / on demand (~1 min)

| Tool | Repo | What it catches | Run |
| --- | --- | --- | --- |
| Semgrep | [semgrep/semgrep](https://github.com/semgrep/semgrep) | security patterns across languages, taint-style rules, secrets | `uvx semgrep --config p/ci --config p/secrets --config p/python .` |
| Trivy | [aquasecurity/trivy](https://github.com/aquasecurity/trivy) | dependency CVEs, secrets, IaC misconfig in a folder | `trivy fs --scanners vuln,secret,misconfig .` |
| osv-scanner | [google/osv-scanner](https://github.com/google/osv-scanner) | dependency CVEs via OSV (alternative to Trivy) | `osv-scanner --lockfile=<file> .` |

Notes:
- **There is no `p/powershell` ruleset** (it returns HTTP 404). Use `p/ci`,
  `p/secrets`, `p/python`; `p/default` also works.
- Trivy downloads a ~100 MB vulnerability DB on first use. On a slow link this
  times out (`failed to download vulnerability DB`) and is **not** a code
  finding - run it when the link is idle, or use `osv-scanner` instead.
- This repo has no dependency manifests (PowerShell + Python stdlib), so
  Trivy/osv-scanner mostly matter for the C# WPF app and its NuGet packages
  (`dotnet list package --vulnerable`).
- Trivy's GitHub Action was compromised twice in March 2026. Pin the action to a
  **commit SHA**, never `@v1`/`@master`, and install the CLI from a pinned release.
- Semgrep's standalone MCP repo (`semgrep/mcp`) is **deprecated**; the server now
  ships as `semgrep-mcp` (pip/uvx) and through the main Semgrep install.

## Tier 2 - CI gate (free)

- **Semgrep** and **Trivy** + **gitleaks** on every pull request, blocking on
  high/critical findings.
- **CodeQL** for the C# WPF app: [github/codeql-action](https://github.com/github/codeql-action)
  (free for public repos; private needs GitHub Advanced Security).
- **OWASP ZAP** baseline against the running dashboard:
  [zaproxy/zaproxy](https://github.com/zaproxy/zaproxy),
  `zap-baseline.py -t http://host.docker.internal:8123`. The dashboard binds to
  localhost and requires a per-run CSRF token, so expect few findings - it is a
  regression net, not the main defence.
- Pin every third-party action to a commit SHA.

## Tier 3 - while the app runs

- **Playwright MCP** ([microsoft/playwright-mcp](https://github.com/microsoft/playwright-mcp))
  or OpenCode's built-in browser tools: click through the dashboard, catch console
  errors and broken flows that no static scan sees.
- `dotnet build` / `dotnet test` for the WPF app (Roslyn analyzers ship with the SDK).
- **Pester** ([pester/Pester](https://github.com/pester/Pester)) v5 for PowerShell
  logic; this machine currently has 3.4 - upgrade before writing real tests.

## MCP wiring (OpenCode V2)

Config lives in `~/.config/opencode/opencode.jsonc` (global) or
`opencode.jsonc` in the project. V2 puts servers under `mcp.servers`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "semgrep": {
        "type": "local",
        "command": ["uvx", "semgrep-mcp"],
        "codemode": false
      },
      "trivy": {
        "type": "local",
        "command": ["trivy", "mcp"],
        "codemode": false
      },
      "playwright": {
        "type": "local",
        "command": ["npx", "-y", "@playwright/mcp@latest"]
      }
    }
  }
}
```

Setup commands:

```powershell
uv tool install semgrep          # provides the semgrep CLI
uvx semgrep-mcp --help           # MCP server (ships in the semgrep project)
winget install aquasecurity.trivy
trivy plugin install mcp         # then: trivy mcp
npx -y @playwright/mcp@latest --help
```

MCP servers run with your user permissions. Prefer official servers, keep them
read-only where possible, and never paste secrets into the config - use
`{env:NAME}` substitution instead.

## Cost

| Tool | Cost |
| --- | --- |
| PSScriptAnalyzer, ruff, gitleaks, osv-scanner, ZAP, Playwright, Pester | free |
| Semgrep OSS rules + CLI | free (rulesets `p/ci`, `p/secrets`, `p/powershell`) |
| Semgrep Pro / Guardian (MCP + hooks + skills) | paid, 30-day trial |
| Trivy | free |
| CodeQL | free for public repos; GHAS licence for private |

## Limits to keep in mind

- No scanner finds a logic bug such as "queue cleared then refilled" - only a test
  or a human tracing the flow does.
- Secret scanners see the working tree/history, not your DPAPI store; that store is
  deliberately outside the repo (mod.io credentials).
- Static analysis of PowerShell is shallow where the code is dynamic; the runtime
  checks (`test-rules.ps1`, `/verify`, the watchdog log) matter more here.
- A green scan is not proof. The dashboard's own test (`mod-manager/test-rules.ps1`)
  and an actual play session catch the rest.

## As installed on this machine (2026-11-15)

| Tool | Version | Status |
| --- | --- | --- |
| PSScriptAnalyzer | 1.25.0 | installed (PS7 path, loads in 5.1) |
| ruff | 0.17.5 | installed via `uv tool` (`~\.local\bin`) |
| gitleaks | 8.30.1 | via winget |
| semgrep | 1.185.0 | via `uv tool` |
| semgrep-mcp | - | installing via `uv tool install semgrep-mcp` |
| trivy | 0.76.2 | via winget; vulnerability DB download times out on this link |
| osv-scanner | 2.7.0 | via winget; `api.osv.dev` is unreachable from this network |
| python | 3.14 | installed |
| node | 24.x | installed |
| uv | installed | used for `uvx semgrep` / `semgrep-mcp` |
| dotnet | installed | for the WPF app |
| Pester | 3.4.0 | old; `Install-Module Pester -Force -SkipPublisherCheck` for v5 |
