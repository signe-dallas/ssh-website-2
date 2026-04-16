# NACUBO SSH Site Mirror

This folder contains a strict same-origin linked crawl of:
`https://nacubo-ssh.agencyq.ai/`

## What was downloaded
- `43` HTML pages
- `83` linked assets (CSS/JS/images/video)
- `0` crawl errors

See `site-mirror/mirror-summary.json` for totals.

## Structure
- Mirrored site root:
  - `site-mirror/nacubo-ssh.agencyq.ai/`
- Crawl script:
  - `mirror_site.ps1`

## Re-run crawl
```powershell
powershell -ExecutionPolicy Bypass -File .\mirror_site.ps1 -StartUrl 'https://nacubo-ssh.agencyq.ai/' -OutputDir 'site-mirror' -MaxPages 3000
```

## Edit in VS Code
Open this folder in VS Code and edit files under:
`site-mirror/nacubo-ssh.agencyq.ai/`

Recommended starting file:
- `site-mirror/nacubo-ssh.agencyq.ai/index.html`

## Push to GitHub
1. Create an empty GitHub repo.
2. Add remote and push:
```powershell
git remote add origin <YOUR_GITHUB_REPO_URL>
git add .
git commit -m "Initial mirrored NACUBO SSH website"
git branch -M main
git push -u origin main
```
