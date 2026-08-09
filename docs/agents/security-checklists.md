# Security Reviewer — Reference Checklists

Conditional / deep-reference material for `security-reviewer`. Load these sections only when the reviewed scope matches. The agent prompt stays core static application-security logic; this file holds the domain detail (2026-08-09 audit S2-2 split).

## Grep patterns (use `files_only` to locate candidates, then Read a bounded range)

```text
# Secrets / keys
api[_-]?key|password|secret|token|BEGIN (RSA |OPENSSH )?PRIVATE|sk-[a-zA-Z0-9]

# Dangerous sinks
innerHTML\s*=|document\.write\(|eval\(|new Function\(|child_process|\.exec\(|\.query\(\s*[`'"]

# Authz gaps (heuristic)
app\.(get|post|put|delete)\([^)]+\)\s*(async\s*)?\(  without nearby auth middleware names
```

Use Grep `files_only` so matching lines are not echoed. Read only the bounded range needed to establish a finding, then report `path:line`; secret values stay first4/last4 only. Route bulk secret scans to owner-run `gitleaks` or `trufflehog`.

## OWASP Top 10:2025 checklist

1. **A01 Broken Access Control** — authz on every route/object; CORS allowlist; SSRF explicitly checked on server-side URL fetches with scheme/host/IP validation and redirect/DNS-rebinding controls
2. **A02 Security Misconfiguration** — default credentials removed; errors fail closed; security headers set; debug disabled in production
3. **A03 Software Supply Chain Failures** — lockfiles reviewed; provenance and build pipeline protected; owner-run vulnerability/license audit supplied
4. **A04 Cryptographic Failures** — modern password hashing; key lifecycle defined; TLS and sensitive-data encryption established or marked UNKNOWN
5. **A05 Injection** — parameterized SQL/NoSQL; command arguments avoid shell interpolation; output encoding covers XSS
6. **A06 Insecure Design** — threat model covers trust boundaries, abuse cases, rate limits, money, and irreversible actions
7. **A07 Authentication Failures** — JWT signature/expiry/audience checked; secure cookies; session rotation/revocation; MFA evidence marked UNKNOWN when unavailable
8. **A08 Software or Data Integrity Failures** — signed/verified artifacts and updates; safe deserialization; untrusted code/data cannot cross integrity boundaries
9. **A09 Security Logging & Alerting Failures** — security events logged without secrets; alerts route to an owner and have a tested response path
10. **A10 Mishandling of Exceptional Conditions** — error paths fail closed; resource limits and cleanup hold under malformed, partial, timeout, and dependency-failure conditions

## Domain checklists (apply only when the stack is present — detect from repo markers, never assume)

### Financial / ledger
- [ ] Balance mutations atomic (DB transaction or equivalent)
- [ ] Balance checked under lock / serializable isolation before debit
- [ ] Rate limiting on withdrawal / transfer / trade endpoints
- [ ] Audit log for every money movement (who, amount, id, time)
- [ ] No IEEE floating-point for currency (integer minor units or decimal type)

### Blockchain / wallet
- [ ] Signatures verified chain-native against expected pubkey before accept/send
- [ ] Transaction instructions reviewed before broadcast
- [ ] Private keys never logged or persisted in app storage
- [ ] RPC / indexer clients rate limited and URL-allowlisted
- [ ] Slippage / max-fee bounds on user-facing trades

### Authentication / session
- [ ] Session binding + refresh + logout revoke
- [ ] JWT (if used): sig + exp + aud verified every request
- [ ] Cookies HttpOnly / Secure / SameSite
- [ ] No auth bypass paths on protected routes
- [ ] Rate limiting on login / token / password-reset

### Database / persistence
- [ ] Parameterized queries or safe ORM only (no string-concat SQL)
- [ ] Authz enforced server-side (RLS and/or app checks), not client-only
- [ ] No secrets/PII in application logs
- [ ] Credentials from env; rotation path documented

### HTTP / API
- [ ] Auth required except explicitly public routes
- [ ] Input validated with schema at trust boundaries
- [ ] Rate limiting per user and/or IP on public/expensive routes
- [ ] CORS explicit origin allowlist (no `*`) + credentials policy
- [ ] No secrets in URLs or query strings
- [ ] Safe method semantics (GET/HEAD no side effects)

### Third-party AI / search / cache
- [ ] Provider API keys server-side only
- [ ] TLS for remote caches/DBs
- [ ] No PII sent to external models unless policy allows and is documented
- [ ] Query/input length and rate limits enforced

## Emergency response (CRITICAL findings)

1. Document — full finding block in the report's Output Format
2. Notify — surface CRITICAL first for the owner
3. Recommend fix — secure example in report only (no Write/Edit/shell)
4. Verification steps — exact commands/tests for post-fix validation
5. Impact — whether secrets/data may already be exposed
6. Handoff — rotate secrets if exposed; main session applies patch; re-run this agent

## Recommended tooling (owner installs — this agent never runs them)

```text
devDependencies (JS): eslint-plugin-security, audit-ci
scripts: "security:audit": "npm audit", "security:lint": "eslint . --plugin security"
```

Owner-run audit CLIs: `npm audit` / `pip-audit` / `cargo audit`, `trufflehog`, `semgrep`. List them in the report under Scans → owner-run; never claim you executed them.

## Common false positives

- Env placeholders in `.env.example` (not live secrets)
- Test credentials in clearly-marked non-production test files
- Public client IDs / publishable keys intended for browsers
- SHA256/MD5 used for checksums (not password hashing)

Always verify context before flagging.
