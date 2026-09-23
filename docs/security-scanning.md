# Security Scanning with Trivy

This repository uses [Trivy](https://github.com/aquasecurity/trivy) for automated security scanning of container images, filesystems, and infrastructure-as-code.

## Overview

Trivy is integrated into all CI/CD pipelines to catch security vulnerabilities before they reach production.

**Scan Types:**
- 🔍 **Container Image Vulnerabilities** - OS packages and application dependencies
- 🔑 **Secret Detection** - Exposed API keys, passwords, tokens
- ⚙️ **Misconfiguration Detection** - Kubernetes, Docker, Terraform issues

## CI/CD Integration

### Build Workflows (Develop & Staging)

Every image build is scanned automatically:

```yaml
- name: Run Trivy vulnerability scanner
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.short_sha }}
    format: 'sarif'
    output: 'trivy-results.sarif'
    severity: 'CRITICAL,HIGH,MEDIUM'
    exit-code: '0'  # Don't fail build, just report

- name: Upload Trivy results to GitHub Security
  uses: github/codeql-action/upload-sarif@v3
  if: always()
  with:
    sarif_file: 'trivy-results.sarif'

- name: Run Trivy vulnerability scanner (table output)
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.short_sha }}
    format: 'table'
    severity: 'CRITICAL,HIGH,MEDIUM'
    exit-code: '1'  # Fail build if vulnerabilities found
```

**Workflow:**
1. **SARIF format** - Results uploaded to GitHub Security tab (doesn't fail build)
2. **Table format** - Human-readable output in logs (fails build on HIGH/CRITICAL)

### Production Promotion Workflow

Before promoting to production, staging image is scanned with **stricter** rules:

```yaml
- name: Run Trivy security scan (fail on critical)
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:staging
    format: 'table'
    severity: 'CRITICAL'
    exit-code: '1'  # Fail promotion if CRITICAL vulnerabilities found
```

**Policy:** Production promotion is **blocked** if CRITICAL vulnerabilities are detected.

## Viewing Scan Results

### GitHub Security Tab

1. Go to repository → **Security** → **Code scanning**
2. View all Trivy findings organized by severity
3. Filter by:
   - Severity (Critical, High, Medium, Low)
   - State (Open, Fixed, Dismissed)
   - Branch
   - File/image

### GitHub Actions Logs

1. Go to **Actions** tab
2. Click on workflow run
3. Expand "Run Trivy vulnerability scanner (table output)" step
4. View detailed vulnerability table

### Local Scanning

Scan images locally before pushing:

```bash
# Scan built image
docker build -t backend:test .
trivy image backend:test

# Scan specific severity
trivy image --severity CRITICAL,HIGH backend:test

# Scan with custom config
trivy image --config trivy.yaml backend:test

# Scan filesystem (useful for detecting secrets)
trivy fs .

# Scan Kubernetes manifests
trivy config flux/

# Scan Terraform
trivy config infra/terraform/
```

## Configuration

### trivy.yaml

Located in backend repository:

```yaml
# Scan settings
scan:
  security-checks:
    - vuln        # Vulnerabilities
    - secret      # Secrets
    - config      # Misconfigurations

# Severity levels to report
severity:
  - CRITICAL
  - HIGH
  - MEDIUM

# Output format
format: table

# Exit code (non-zero if vulnerabilities found)
exit-code: 1

# Ignore unfixed vulnerabilities
ignore-unfixed: false
```

### .trivyignore

Used to ignore false positives or accepted risks:

```
# Example: Ignore specific CVE
CVE-2023-12345

# Example: Ignore vulnerabilities in specific packages
pkg:golang/github.com/example/package@1.2.3
```

## Severity Levels

Trivy classifies vulnerabilities into 4 severity levels:

| Severity | Description | Action |
|----------|-------------|--------|
| **CRITICAL** | Actively exploited, high impact | **Block production** deployment |
| **HIGH** | Easy to exploit, significant impact | **Fail build**, require fix or justification |
| **MEDIUM** | Moderate risk | **Warn**, fix when possible |
| **LOW** | Low risk or hard to exploit | **Info**, fix eventually |

## Common Vulnerabilities

### OS Package Vulnerabilities

**Example:**
```
CVE-2023-12345 (CRITICAL)
Package: openssl
Installed Version: 1.1.1k
Fixed Version: 1.1.1l
```

**Fix:**
Update base image or rebuild with latest packages:
```dockerfile
FROM alpine:3.20
RUN apk update && apk upgrade
```

### Application Dependency Vulnerabilities

**Example:**
```
CVE-2023-54321 (HIGH)
Package: github.com/gin-gonic/gin
Installed Version: 1.8.0
Fixed Version: 1.9.0
```

**Fix:**
Update go.mod:
```bash
go get github.com/gin-gonic/gin@v1.9.0
go mod tidy
```

### Secret Detection

**Example:**
```
SECRET (HIGH)
File: config.yaml
Match: AWS Access Key
```

**Fix:**
- Remove hardcoded secrets
- Use environment variables or SOPS-encrypted secrets
- Rotate exposed credentials immediately

### Misconfiguration

**Example:**
```
MISCONFIGURATION (MEDIUM)
File: Dockerfile
Issue: Running as root user
```

**Fix:**
```dockerfile
RUN adduser -D -u 10001 app
USER app
```

## Handling Vulnerabilities

### 1. Fix Immediately (CRITICAL/HIGH)

```bash
# Update dependencies
go get -u github.com/vulnerable/package

# Rebuild image
docker build -t backend:fixed .

# Test
trivy image backend:fixed

# Commit and push
git add go.mod go.sum
git commit -m "fix: update vulnerable package"
git push
```

### 2. Create Issue for Tracking (MEDIUM/LOW)

```bash
# Create GitHub issue
gh issue create \
  --title "Security: Medium severity CVE-2023-12345 in package X" \
  --label "security,vulnerability" \
  --body "Trivy detected CVE-2023-12345..."
```

### 3. Suppress False Positives

Add to `.trivyignore`:
```
# False positive - package X is not used in affected code path
CVE-2023-12345
```

Document why in code comments or security review docs.

### 4. Accept Risk (Rare)

For unfixable vulnerabilities with low exploitability:

1. Document risk acceptance in `docs/security/risk-acceptance.md`
2. Add to `.trivyignore` with comment
3. Schedule periodic review (quarterly)
4. Implement compensating controls

## Best Practices

### ✅ DO:

- ✅ Run Trivy scans in every CI/CD pipeline
- ✅ Fail builds on HIGH/CRITICAL vulnerabilities
- ✅ Block production promotion on CRITICAL issues
- ✅ Update dependencies regularly (weekly/monthly)
- ✅ Use minimal base images (alpine, distroless)
- ✅ Monitor GitHub Security tab regularly
- ✅ Subscribe to security advisories for your stack
- ✅ Implement automated dependency updates (Dependabot)
- ✅ Scan IaC and manifests, not just images
- ✅ Document accepted risks properly

### ❌ DON'T:

- ❌ Ignore CRITICAL vulnerabilities
- ❌ Disable security scanning to "make builds pass"
- ❌ Suppress vulnerabilities without investigation
- ❌ Use outdated base images (>6 months old)
- ❌ Commit secrets to code (use SOPS/vault)
- ❌ Run containers as root user
- ❌ Use `latest` tags in production
- ❌ Skip scans for "hotfix" deployments
- ❌ Forget to rotate exposed credentials
- ❌ Deploy without reviewing security findings

## Troubleshooting

### Scan is slow or times out

```bash
# Increase timeout in workflow
timeout: 10m

# Use offline scanning mode (DB cached in image)
trivy image --offline-scan myimage
```

### Too many false positives

```bash
# Ignore unfixed vulnerabilities
trivy image --ignore-unfixed myimage

# Only scan OS packages (skip app dependencies)
trivy image --vuln-type os myimage
```

### SARIF upload fails

```yaml
# Ensure proper permissions
permissions:
  security-events: write

# Upload only if file exists
- name: Upload Trivy results
  if: always() && hashFiles('trivy-results.sarif') != ''
  uses: github/codeql-action/upload-sarif@v3
```

### Different results locally vs CI

```bash
# Update Trivy database
trivy image --download-db-only

# Clear cache
trivy image --clear-cache

# Use same version as CI
trivy image --version
```

## Integration with Other Tools

### Dependabot

Enable Dependabot for automated dependency updates:

```.github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    schedule:
      interval: "weekly"
```

### GitHub Advanced Security

Enable code scanning for comprehensive security:

1. Repository Settings → Security → Code scanning
2. Enable CodeQL analysis
3. Trivy results appear alongside CodeQL findings

### Slack/Email Notifications

Add notification step to workflows:

```yaml
- name: Notify on security issues
  if: failure()
  run: |
    curl -X POST ${{ secrets.SLACK_WEBHOOK }} \
      -d '{"text":"Security scan failed for ${{ github.sha }}"}'
```

## Metrics & Reporting

Track security metrics:

- **Time to fix** CRITICAL vulnerabilities
- **Number of vulnerabilities** by severity
- **Scan coverage** (% of images scanned)
- **False positive rate**
- **Mean time to detection (MTTD)**
- **Mean time to remediation (MTTR)**

Query GitHub Security API:

```bash
gh api repos/:owner/:repo/code-scanning/alerts \
  --jq '.[] | select(.tool.name=="Trivy") | {severity: .rule.severity, state: .state}'
```

## Resources

- [Trivy Documentation](https://aquasecurity.github.io/trivy/)
- [Trivy GitHub Action](https://github.com/aquasecurity/trivy-action)
- [CVE Database](https://cve.mitre.org/)
- [GitHub Security Advisories](https://github.com/advisories)
- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [Container Security Best Practices](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)

## Security Incident Response

If Trivy detects a CRITICAL vulnerability in production:

1. **Assess impact** - Is it actively exploited?
2. **Create incident** - Document in incident tracking system
3. **Hotfix or rollback** - Deploy fix or rollback to previous version
4. **Rotate secrets** - If secrets exposed, rotate immediately
5. **Post-mortem** - Document lessons learned
6. **Update processes** - Prevent similar issues

---

**Remember:** Security scanning is only one layer of defense. Combine with:
- Code reviews
- Penetration testing
- Runtime security monitoring
- Access controls (RBAC, Network Policies)
- Secrets management (SOPS)
- Regular security audits
