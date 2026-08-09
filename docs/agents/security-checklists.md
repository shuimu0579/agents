# Security Reviewer — Reference Checklists

Conditional / deep-reference material for `security-reviewer`. Load these sections only when the reviewed scope matches. The agent prompt stays core static application-security logic; this file holds the domain detail (2026-08-09 audit S2-2 split).

## Grep patterns (always use `-l` / line-number-only output — never echo matching lines)

```text
# Secrets / keys
api[_-]?key|password|secret|token|BEGIN (RSA |OPENSSH )?PRIVATE|sk-[a-zA-Z0-9]

# Dangerous sinks
innerHTML\s*=|document\.write\(|eval\(|new Function\(|child_process|\.exec\(|\.query\(\s*[`'"]

# Authz gaps (heuristic)
app\.(get|post|put|delete)\([^)]+\)\s*(async\s*)?\(  without nearby auth middleware names
```

Report a hit as `path:line` (filename + line number only). Inspect a full value only when necessary, and never echo it — first4/last4 only.

## OWASP Top 10 checklist

1. **Injection (SQL/NoSQL/Command)** — parameterized queries / ORM binds; no string-concat SQL
2. **Broken Authentication** — bcrypt/argon2; JWT sig + exp + aud on every request; HttpOnly/Secure/SameSite cookies; MFA if available
3. **Sensitive Data Exposure** — HTTPS enforced; secrets in env; PII encrypted at rest; logs sanitized
4. **XXE** — XML parsers configured securely; external entities disabled
5. **Broken Access Control** — authz on every route; indirect object references; CORS explicit allowlist (no `*`)
6. **Security Misconfiguration** — default creds changed; secure error handling; security headers; no debug in prod
7. **XSS** — output escaped/sanitized; CSP set; framework defaults respected
8. **Insecure Deserialization** — safe deserialization; libraries up to date
9. **Known Vulnerable Components** — lockfiles reviewed; owner-run audit CLI; CVE monitoring
10. **Insufficient Logging & Monitoring** — security events logged; monitored; alerts configured

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
