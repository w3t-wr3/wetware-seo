---
name: wetware-seo
description: |
  Wetware Labs SEO audit and report generation skill. Use this skill to run SEO data collection on client domains, generate branded PDF reports, and execute the SEO dashboard pipeline. Trigger when the user says "SEO report", "SEO audit", "run SEO collection", "seo dashboard", or references any Wetware Labs SEO workflow.
---

# Wetware SEO

SEO data collection, scoring, and branded report generation for Wetware Labs client portfolio.

## What This Skill Does

1. **Collect SEO data** from client websites (HTTP health, SSL, meta tags, PageSpeed scores, robots.txt, sitemap, JSON-LD)
2. **Score each site** using the Wetware SEO Score (WSS); our proprietary 100-point scale
3. **Generate branded PDF reports** using the Wetware Labs template (black and white only)

## Prerequisites

- Python 3 with `python-docx` and `matplotlib` installed
- `curl`, `jq`, `openssl`, `perl` available (standard on macOS/Linux)
- LibreOffice installed for PDF conversion (`/Applications/LibreOffice.app` on macOS)
- PageSpeed Insights API key set as `PAGESPEED_API_KEY` env var (free from Google Cloud Console)
- The Wetware Labs template: install the `wetware-docs` skill first (`npx skills add w3t-wr3/wetware-docs`)

## Client Registry

Create a `clients.json` file in your project with this structure:

```json
{
  "clients": [
    {
      "name": "Client Name",
      "slug": "client-slug",
      "domain": "clientdomain.com",
      "group": "client-group",
      "platform": "Next.js + Vercel",
      "report_cadence": "bi-weekly",
      "pages": ["/", "/services", "/contact"]
    }
  ],
  "groups": {
    "client-group": {
      "label": "Client Group Label",
      "report_cadence": "bi-weekly",
      "contact": "Contact Name"
    }
  }
}
```

## Wetware SEO Score (WSS)

NEVER use Google Lighthouse SEO scores. They check ~15 basic items and give 100% to sites missing critical SEO infrastructure. Use WSS exclusively.

**WSS is 100 points across 6 categories:**

| Category | Max | What It Measures |
|----------|-----|------------------|
| Crawlability | 20 | robots.txt, sitemap, canonical tags, redirect behavior |
| On-Page | 25 | Title tag, meta description, H1 tags, viewport, keyword presence |
| Structured Data | 15 | JSON-LD schemas, OG tags |
| Social/Sharing | 10 | OG title, OG description, completeness |
| Performance | 20 | TTFB, HTTP status, SSL, PageSpeed mobile score |
| Content Depth | 10 | Number of pages, internal linking |

**Grading scale:** A (90+), B+ (80+), B (70+), C+ (60+), C (50+), D (40+), F (<40)

## How to Collect Data

Run the collection script in `assets/collect.sh`:

```bash
PAGESPEED_API_KEY="your-key" ./collect.sh
```

This produces one markdown file per client in `inbox/seo-data/{slug}-{date}.md` containing all metrics and the WSS score.

For daily health checks only (HTTP + SSL):

```bash
./healthcheck.sh
```

## How to Generate Reports

### Step 1: Collect data first (or use existing collection files)

### Step 2: Generate the report

Use the Python script in `assets/generate-seo-report.py` as a template. Adapt the data section for your client:

```bash
python3 generate-seo-report.py
```

This produces both DOCX and PDF in the output directory.

### Report Rules (MANDATORY)

1. **Black and white only.** No color in text, charts, or tables. Grayscale matplotlib charts only.
2. **Zero blank pages.** Test with PyMuPDF (`fitz`) before delivering. Never use `page_break=True` unless the page is full.
3. **Always generate both DOCX and PDF.** PDF via LibreOffice headless conversion.
4. **Output to `/Documents/clients/[Client Name]/`**, never Desktop.
5. **Cover page has no header.** Use `titlePg` in sectPr to suppress it. Logo goes centered in the body.
6. **No logo re-injection.** The template already has the header logo; don't overwrite chart images with it.
7. **Use WSS, never Lighthouse SEO.** Label the column "LH SEO*" with a footnote if you must show Lighthouse data.

### Report Structure

| Section | Content |
|---------|---------|
| Cover | Logo, title, client name, brands, date. No header. |
| Executive Summary | Metric cards + key findings + scorecard table + LH SEO footnote |
| Performance Dashboard | Bar chart (mobile vs desktop), severity donut, issue legend |
| Technical Completeness | Heatmap matrix + Core Web Vitals chart + site speed + issues per brand |
| Brand Sections | One per brand: infrastructure table + issues + what's working |
| Priority Action Plan | Ranked fixes with severity labels + timeline |

### Chart Design (matplotlib)

All charts use this grayscale palette:

```python
C_BLACK = '#222222'
C_DARK = '#444444'
C_MID = '#444444'  # Darker than typical mid; prints better
C_LIGHT = '#AAAAAA'
C_PALE = '#CCCCCC'
C_FAINT = '#E5E5E5'
```

Chart types used:
- **Horizontal bar chart**: Mobile vs desktop performance per brand
- **Donut chart**: Issue severity breakdown (Critical/High/Medium/Low)
- **Heatmap**: Technical SEO completeness matrix (checkmarks/X per brand per feature)
- **Grouped bar chart**: Core Web Vitals (FCP, LCP) per brand with Iconic on separate scale
- **Side-by-side bars**: Server response time + time until usable
- **Stacked horizontal bars**: Issues per brand by severity

### Document Helpers (python-docx)

```python
from docx import Document
from docx.shared import Pt, Inches, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from copy import deepcopy

BLACK = RGBColor(0, 0, 0)
DARK_GRAY = RGBColor(0x33, 0x33, 0x33)
GRAY = RGBColor(0x55, 0x55, 0x55)
LIGHT_GRAY = RGBColor(0x99, 0x99, 0x99)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)

SKILL_DIR = "<this-skill-directory>"
TEMPLATE_PATH = "<wetware-docs-skill>/assets/Wetware_Labs_Template.docx"
```

Use the wetware-docs skill's template for header/footer. Open it with `Document(TEMPLATE_PATH)`, clear the body preserving sectPr, add content, save. Do NOT re-inject the logo via zipfile; the template already has it.

## Dashboard

The SEO dashboard is a Next.js app deployed on Vercel. It reads from `seo-data.json` generated by the sync script.

To update the dashboard data:
```bash
node scripts/sync-data.js
```

Then commit and push to trigger a Vercel deploy.

## File Reference

| File | Purpose |
|------|---------|
| `assets/collect.sh` | Weekly SEO data collection script |
| `assets/healthcheck.sh` | Daily HTTP + SSL health check |
| `assets/clients.json` | Client registry template |
| `assets/generate-seo-report.py` | Report generator template (adapt per client) |
| `assets/sync-data.js` | Converts collection markdown to dashboard JSON |
