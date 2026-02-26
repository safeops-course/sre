# Course Site on Cloudflare (`safeops.work`)

## Goal

Publish Hugo website from `docs/course/` so every chapter/lab/quiz update is reflected on the site.

## Source of Truth

- Source content: `docs/course/`
- Sync/build pipeline:
  - `scripts/sync-course-to-hugo.sh`
  - `site/hugo.toml`
  - `site/`

## Local Validation

From `sre/`:

```bash
make course-site-sync
hugo server --source site -D
```

## Cloudflare Pages (Recommended)

Create a Pages project connected to this repo.

Use:
- Root directory: `sre`
- Build command: `./scripts/sync-course-to-hugo.sh && hugo --source site --minify`
- Build output directory: `site/public`

## Domain Wiring

In Cloudflare Pages:
1. Add custom domain `safeops.work`
2. Add `www.safeops.work` (optional)
3. Set redirect preference (`www` -> apex or apex -> `www`)

DNS records should remain proxied in Cloudflare.

## Change Flow

1. Edit chapter content in `docs/course/`
2. Open PR (CI runs `course-site-build`)
3. Merge to `main`
4. Cloudflare Pages rebuilds and publishes automatically

## Quiz Progress (Optional Next Step)

Current behavior:
- quiz pages run in local mode (browser-only `localStorage`)
- no server-side account/progress yet

Cloudflare upgrade path:
1. Add Pages Function endpoint (e.g. `/api/quiz-results`)
2. Store results in D1
3. Set `params.quizApiEndpoint` in `site/hugo.toml` to that endpoint URL
4. Keep local mode as fallback when endpoint is unset

## Guardrails

- Never edit generated content under `site/content/course/`.
- Keep chapter docs markdown-only and deterministic.
- Validate at least one chapter URL and one quiz URL after each release.
