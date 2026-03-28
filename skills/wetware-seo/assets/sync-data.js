#!/usr/bin/env node

/**
 * sync-data.js
 *
 * Reads SEO collection markdown files from the Obsidian vault,
 * parses frontmatter + structured tables + PageSpeed + WSS scores,
 * and outputs a single JSON file for the SEO dashboard.
 *
 * Usage:
 *   node scripts/sync-data.js
 *   node scripts/sync-data.js --input /custom/path --output /custom/out.json
 */

const fs = require("fs");
const path = require("path");

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const DEFAULT_INPUT_DIR = path.resolve(
  __dirname,
  "../../../obsidian/vaults/inbox/seo-data"
);
const DEFAULT_ALERTS_FILE = path.resolve(
  __dirname,
  "../../../obsidian/vaults/knowledge/memory/seo-alerts.md"
);
const DEFAULT_OUTPUT_FILE = path.resolve(
  __dirname,
  "../src/data/seo-data.json"
);

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {
    inputDir: DEFAULT_INPUT_DIR,
    alertsFile: DEFAULT_ALERTS_FILE,
    outputFile: DEFAULT_OUTPUT_FILE,
  };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--input" && args[i + 1]) opts.inputDir = args[++i];
    if (args[i] === "--alerts" && args[i + 1]) opts.alertsFile = args[++i];
    if (args[i] === "--output" && args[i + 1]) opts.outputFile = args[++i];
  }
  return opts;
}

// ---------------------------------------------------------------------------
// Frontmatter parser
// ---------------------------------------------------------------------------

function parseFrontmatter(content) {
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return {};
  const fm = {};
  for (const line of match[1].split("\n")) {
    const idx = line.indexOf(":");
    if (idx === -1) continue;
    const key = line.slice(0, idx).trim();
    const val = line.slice(idx + 1).trim();
    fm[key] = val;
  }
  return fm;
}

// ---------------------------------------------------------------------------
// Table parser: returns array of [key, value] from two-column markdown tables.
// Handles values that contain literal pipe characters (e.g. "Title | Subtitle")
// by only splitting on the first two cell boundaries.
// ---------------------------------------------------------------------------

function parseTable(text) {
  const rows = [];
  const lines = text.split("\n");
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("|")) continue;
    // skip separator rows like |-------|--------|
    if (/^\|[\s-:|]+\|$/.test(trimmed)) continue;

    // Strip leading and trailing pipe, then split on first pipe only
    // to get exactly [key, value] for two-column tables, or [key, value, extra...]
    // for three-column tables (WSS categories).
    const inner = trimmed.replace(/^\|/, "").replace(/\|$/, "");

    // For WSS-style 3-column tables: Category | Points | Max
    // detect by checking if we have exactly 3 segments separated by |
    const segments = inner.split("|").map((s) => s.trim());

    if (segments.length >= 2) {
      rows.push(segments);
    }
  }
  // first row is usually the header; skip it
  if (rows.length > 0) {
    const first = rows[0];
    const isHeader =
      first[0].toLowerCase().includes("check") ||
      first[0].toLowerCase().includes("category");
    if (isHeader) rows.shift();
  }
  return rows;
}

/**
 * Specialized two-column table parser for page meta tables.
 * Only splits on the FIRST pipe boundary so values like
 * "Home | Big Thunder Dock Company" stay intact.
 * Also captures multi-line continuation text after each table row.
 */
function parseTwoColumnTable(text) {
  const rows = [];
  const lines = text.split("\n");
  let i = 0;

  while (i < lines.length) {
    const trimmed = lines[i].trim();
    i++;

    if (!trimmed.startsWith("|")) continue;
    // skip separator rows
    if (/^\|[\s-:|]+\|$/.test(trimmed)) continue;

    // Strip leading and trailing pipe
    const inner = trimmed.replace(/^\|/, "").replace(/\|$/, "");
    // Split on first pipe only to get [key, value]
    const pipeIdx = inner.indexOf("|");
    if (pipeIdx === -1) continue;

    const key = inner.slice(0, pipeIdx).trim();
    let val = inner.slice(pipeIdx + 1).trim();

    // Check for continuation lines (multi-line meta descriptions).
    // The markdown format can have values that span multiple lines,
    // potentially with blank lines, and end with a trailing " |".
    // We continue until we hit a line that starts with "|" and looks
    // like a new table row (key | value pattern), or a heading.
    while (i < lines.length) {
      const nextLine = lines[i];
      const nextTrimmed = nextLine.trim();

      // If the next line starts with | and looks like a new row, stop
      if (nextTrimmed.startsWith("|") && /^\|[^|]+\|/.test(nextTrimmed)) {
        break;
      }
      // If it's a heading, stop
      if (nextTrimmed.startsWith("#")) {
        break;
      }

      // Append continuation text (strip trailing pipe if present)
      let contText = nextTrimmed;
      // If this line ends with " |", it's the end of the multi-line cell
      if (contText.endsWith("|")) {
        contText = contText.slice(0, -1).trim();
      }
      if (contText !== "") {
        val += " " + contText;
      }
      i++;
    }

    // skip header row
    if (
      key.toLowerCase() === "check" ||
      key.toLowerCase() === "category"
    ) {
      continue;
    }

    rows.push([key, val]);
  }
  return rows;
}

// ---------------------------------------------------------------------------
// HTTP Health
// ---------------------------------------------------------------------------

function parseHttpHealth(section) {
  const rows = parseTwoColumnTable(section);
  const data = { status: "N/A", ttfb: "N/A", redirect: "None", sslExpiry: "N/A" };
  for (const [rawKey, rawVal] of rows) {
    const key = rawKey.toLowerCase();
    const val = rawVal.trim();
    if (key.includes("http status")) data.status = val;
    else if (key.includes("ttfb")) data.ttfb = val;
    else if (key.includes("redirect")) data.redirect = val;
    else if (key.includes("ssl")) data.sslExpiry = val;
  }
  return data;
}

// ---------------------------------------------------------------------------
// robots.txt
// ---------------------------------------------------------------------------

function parseRobotsTxt(section) {
  // Pattern: "Status: Present (200)" or "**MISSING** (HTTP 307)"
  const presentMatch = section.match(/Status:\s*Present\s*\((\d+)\)/i);
  if (presentMatch) {
    return { present: true, status: presentMatch[1] };
  }
  const missingMatch = section.match(/\*\*MISSING\*\*\s*\(HTTP\s*(\d+)\)/i);
  if (missingMatch) {
    return { present: false, status: missingMatch[1] };
  }
  return { present: false, status: "N/A" };
}

// ---------------------------------------------------------------------------
// Sitemap
// ---------------------------------------------------------------------------

function parseSitemap(section) {
  // Pattern: "Status: Present (200); 17 URLs found"
  const match = section.match(
    /Status:\s*Present\s*\((\d+)\);\s*(\d+)\s*URLs?\s*found/i
  );
  if (match) {
    return { present: true, urls: parseInt(match[2], 10) };
  }
  // Could also be missing
  if (/missing/i.test(section)) {
    return { present: false, urls: 0 };
  }
  return { present: false, urls: 0 };
}

// ---------------------------------------------------------------------------
// Page meta from table
// ---------------------------------------------------------------------------

function parsePageMeta(tableSection) {
  const rows = parseTwoColumnTable(tableSection);
  const meta = {
    title: "N/A",
    description: "N/A",
    ogTitle: "N/A",
    ogDescription: "N/A",
    viewport: "N/A",
    jsonLdCount: 0,
    canonical: "N/A",
    h1Count: 0,
  };
  for (const [rawKey, rawVal] of rows) {
    const key = rawKey.toLowerCase();
    const val = rawVal.trim();
    if (key === "title") meta.title = val || "N/A";
    else if (key === "meta description") {
      meta.description = val === "MISSING" || val === "" ? "MISSING" : val;
    } else if (key === "og title") {
      meta.ogTitle = val === "MISSING" || val === "" ? "MISSING" : val;
    } else if (key === "og description") {
      meta.ogDescription = val === "MISSING" || val === "" ? "MISSING" : val;
    } else if (key === "viewport") meta.viewport = val || "N/A";
    else if (key.includes("json-ld")) {
      meta.jsonLdCount = parseInt(val, 10) || 0;
    } else if (key === "canonical") {
      meta.canonical = val === "MISSING" || val === "" ? "MISSING" : val;
    } else if (key.includes("h1")) {
      meta.h1Count = parseInt(val, 10) || 0;
    }
  }
  return meta;
}

// ---------------------------------------------------------------------------
// PageSpeed Insights
// ---------------------------------------------------------------------------

function parsePageSpeedBlock(text) {
  // Successful format:
  //   Performance: 71 | SEO: 100 | Accessibility: 88 | Best Practices: 100
  //   FCP: 1.8 s | LCP: 40.3 s | TBT: 0 ms | CLS: 0
  // Error format:
  //   API error; ...
  if (/API error/i.test(text) || /N\/A/i.test(text)) {
    return null;
  }

  const result = {
    performance: "N/A",
    seo: "N/A",
    accessibility: "N/A",
    bestPractices: "N/A",
    fcp: "N/A",
    lcp: "N/A",
    tbt: "N/A",
    cls: "N/A",
  };

  // Try parsing "Performance: 71" etc.
  const perfMatch = text.match(/Performance:\s*(\d+)/i);
  if (perfMatch) result.performance = parseInt(perfMatch[1], 10);

  const seoMatch = text.match(/SEO:\s*(\d+)/i);
  if (seoMatch) result.seo = parseInt(seoMatch[1], 10);

  const a11yMatch = text.match(/Accessibility:\s*(\d+)/i);
  if (a11yMatch) result.accessibility = parseInt(a11yMatch[1], 10);

  const bpMatch = text.match(/Best Practices:\s*(\d+)/i);
  if (bpMatch) result.bestPractices = parseInt(bpMatch[1], 10);

  const fcpMatch = text.match(/FCP:\s*([\d.]+\s*[sm]+)/i);
  if (fcpMatch) result.fcp = fcpMatch[1].trim();

  const lcpMatch = text.match(/LCP:\s*([\d.]+\s*[sm]+)/i);
  if (lcpMatch) result.lcp = lcpMatch[1].trim();

  const tbtMatch = text.match(/TBT:\s*([\d.]+\s*[sm]+)/i);
  if (tbtMatch) result.tbt = tbtMatch[1].trim();

  const clsMatch = text.match(/CLS:\s*([\d.]+)/i);
  if (clsMatch) result.cls = clsMatch[1].trim();

  return result;
}

function parsePageSpeed(pageSection) {
  const pagespeed = {
    mobile: null,
    desktop: null,
  };

  // Extract Mobile block
  const mobileMatch = pageSection.match(
    /\*\*Mobile:\*\*\s*([\s\S]*?)(?=\*\*Desktop:\*\*|$)/i
  );
  if (mobileMatch) {
    pagespeed.mobile = parsePageSpeedBlock(mobileMatch[1]);
  }

  // Extract Desktop block
  const desktopMatch = pageSection.match(/\*\*Desktop:\*\*\s*([\s\S]*?)$/i);
  if (desktopMatch) {
    pagespeed.desktop = parsePageSpeedBlock(desktopMatch[1]);
  }

  return pagespeed;
}

// ---------------------------------------------------------------------------
// WSS categories
// ---------------------------------------------------------------------------

const WSS_CATEGORY_MAP = {
  crawlability: "crawlability",
  "on-page": "onPage",
  "structured data": "structuredData",
  "social/sharing": "socialSharing",
  performance: "performance",
  "content depth": "contentDepth",
};

function normalizeCategoryKey(raw) {
  // "Crawlability (robots, sitemap, canonical)" -> "crawlability"
  const base = raw.split("(")[0].trim().toLowerCase();
  for (const [pattern, key] of Object.entries(WSS_CATEGORY_MAP)) {
    if (base.includes(pattern)) return key;
  }
  // fallback: slugify
  return base.replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
}

function parseWss(section) {
  // Overall line: **Overall: 44/100 (D)**
  const overallMatch = section.match(
    /\*\*Overall:\s*(\d+)\/(\d+)\s*\(([^)]+)\)\*\*/
  );
  const wss = {
    total: 0,
    grade: "N/A",
    categories: {},
  };
  if (overallMatch) {
    wss.total = parseInt(overallMatch[1], 10);
    wss.grade = overallMatch[3].trim();
  }

  // Category table
  const rows = parseTable(section);
  for (const cells of rows) {
    const rawName = cells[0];
    if (rawName.toLowerCase().startsWith("**total")) continue; // skip total row
    if (rawName.toLowerCase() === "total") continue;
    const key = normalizeCategoryKey(rawName);
    const score = parseInt(cells[1], 10) || 0;
    const max = parseInt(cells[2], 10) || 0;
    wss.categories[key] = { score, max };
  }

  return wss;
}

// ---------------------------------------------------------------------------
// Parse pages (splits on ### headings)
// ---------------------------------------------------------------------------

function parsePages(content) {
  const pages = [];

  // Split on ### /path headings; each page section starts with ### /...
  const pageSections = content.split(/(?=^### \/)/m);

  for (const section of pageSections) {
    const pathMatch = section.match(/^### (\/\S*)/m);
    if (!pathMatch) continue;

    const pagePath = pathMatch[1];

    // Find the table for meta
    const meta = parsePageMeta(section);

    // Find PageSpeed section
    const pagespeed = parsePageSpeed(section);

    pages.push({
      path: pagePath,
      meta,
      pagespeed,
    });
  }

  return pages;
}

// ---------------------------------------------------------------------------
// Parse a single collection file
// ---------------------------------------------------------------------------

function parseCollectionFile(filePath) {
  const raw = fs.readFileSync(filePath, "utf-8");
  const fm = parseFrontmatter(raw);

  // Split into major sections by ## headings
  const sections = {};
  const sectionRegex = /^## (.+)$/gm;
  let match;
  const sectionStarts = [];

  while ((match = sectionRegex.exec(raw)) !== null) {
    sectionStarts.push({ title: match[1].trim(), index: match.index });
  }

  for (let i = 0; i < sectionStarts.length; i++) {
    const start = sectionStarts[i].index;
    const end =
      i + 1 < sectionStarts.length ? sectionStarts[i + 1].index : raw.length;
    sections[sectionStarts[i].title.toLowerCase()] = raw.slice(start, end);
  }

  // Parse each section
  const http = sections["http health"]
    ? parseHttpHealth(sections["http health"])
    : { status: "N/A", ttfb: "N/A", redirect: "None", sslExpiry: "N/A" };

  const robotsTxt = sections["robots.txt"]
    ? parseRobotsTxt(sections["robots.txt"])
    : { present: false, status: "N/A" };

  const sitemap = sections["sitemap"]
    ? parseSitemap(sections["sitemap"])
    : { present: false, urls: 0 };

  // Pages are under "## Page Analysis" with ### subheadings
  const pageAnalysisSection = sections["page analysis"] || "";
  const pages = parsePages(pageAnalysisSection);

  const wss = sections["wetware seo score"]
    ? parseWss(sections["wetware seo score"])
    : { total: 0, grade: "N/A", categories: {} };

  return {
    client: fm.client || "Unknown",
    slug: fm.slug || path.basename(filePath, ".md"),
    domain: fm.domain || "unknown",
    group: fm.group || "ungrouped",
    date: fm.collected || "unknown",
    collection: {
      date: fm.collected || "unknown",
      http,
      robotsTxt,
      sitemap,
      pages,
      wss,
    },
  };
}

// ---------------------------------------------------------------------------
// Parse alerts file
// ---------------------------------------------------------------------------

function parseAlerts(filePath) {
  if (!fs.existsSync(filePath)) {
    return { status: "unknown", lastCheck: "N/A", items: [] };
  }

  const raw = fs.readFileSync(filePath, "utf-8");

  // Extract last check date
  const lastCheckMatch = raw.match(/\*\*Last check:\*\*\s*(.+)/);
  const lastCheck = lastCheckMatch ? lastCheckMatch[1].trim() : "N/A";

  // Check if healthy
  const isHealthy = /all.*healthy|no alerts/i.test(raw);

  // Parse domain status table for individual items
  const items = [];
  const tableSection = raw.match(/## Domain Status[\s\S]*/);
  if (tableSection) {
    const rows = parseTable(tableSection[0]);
    for (const cells of rows) {
      if (cells.length >= 3) {
        // Parse "Big Thunder Dock Co. (bigthunderdocks.com)"
        const domainMatch = cells[0].match(/^(.+?)\s*\(([^)]+)\)/);
        const clientName = domainMatch ? domainMatch[1].trim() : cells[0];
        const domain = domainMatch ? domainMatch[2].trim() : "unknown";
        const httpStatus = cells[1].trim();
        const sslExpiry = cells[2].trim();

        // Flag non-200 HTTP as info, SSL expiring within 30 days as warning
        const alerts = [];
        const statusCode = parseInt(httpStatus, 10);
        if (statusCode >= 400) {
          alerts.push({
            severity: "error",
            message: `HTTP ${httpStatus}`,
          });
        } else if (statusCode >= 300) {
          alerts.push({
            severity: "info",
            message: `HTTP ${httpStatus} (redirect)`,
          });
        }

        // Parse SSL date and check if within 30 days
        try {
          const sslDate = new Date(sslExpiry);
          const now = new Date();
          const daysUntilExpiry = Math.floor(
            (sslDate - now) / (1000 * 60 * 60 * 24)
          );
          if (daysUntilExpiry <= 30 && daysUntilExpiry > 0) {
            alerts.push({
              severity: "warning",
              message: `SSL expires in ${daysUntilExpiry} days`,
            });
          } else if (daysUntilExpiry <= 0) {
            alerts.push({
              severity: "error",
              message: `SSL expired`,
            });
          }
        } catch (e) {
          // skip date parse errors
        }

        if (alerts.length > 0) {
          items.push({
            client: clientName,
            domain,
            alerts,
          });
        }
      }
    }
  }

  return {
    status: isHealthy ? "healthy" : "issues-detected",
    lastCheck,
    items,
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  const opts = parseArgs();

  console.log(`Reading SEO collections from: ${opts.inputDir}`);
  console.log(`Reading alerts from: ${opts.alertsFile}`);
  console.log(`Writing output to: ${opts.outputFile}`);

  // Find all markdown files
  if (!fs.existsSync(opts.inputDir)) {
    console.error(`Input directory not found: ${opts.inputDir}`);
    process.exit(1);
  }

  const files = fs
    .readdirSync(opts.inputDir)
    .filter((f) => f.endsWith(".md"))
    .map((f) => path.join(opts.inputDir, f));

  console.log(`Found ${files.length} collection files`);

  // Parse all files
  const parsed = files.map((f) => {
    try {
      return parseCollectionFile(f);
    } catch (err) {
      console.error(`Error parsing ${f}: ${err.message}`);
      return null;
    }
  }).filter(Boolean);

  // Group by slug, sort collections by date for trend tracking
  const clientMap = new Map();

  for (const entry of parsed) {
    if (!clientMap.has(entry.slug)) {
      clientMap.set(entry.slug, {
        name: entry.client,
        slug: entry.slug,
        domain: entry.domain,
        group: entry.group,
        collections: [],
      });
    }
    clientMap.get(entry.slug).collections.push(entry.collection);
  }

  // Sort each client's collections by date (oldest first for trend tracking)
  for (const client of clientMap.values()) {
    client.collections.sort((a, b) => a.date.localeCompare(b.date));
  }

  // Sort clients alphabetically by name
  const clients = Array.from(clientMap.values()).sort((a, b) =>
    a.name.localeCompare(b.name)
  );

  // Parse alerts
  const alerts = parseAlerts(opts.alertsFile);

  // Determine lastUpdated from most recent collection date
  const allDates = parsed.map((p) => p.date).filter((d) => d !== "unknown");
  const lastUpdated =
    allDates.length > 0 ? allDates.sort().reverse()[0] : new Date().toISOString().slice(0, 10);

  // Build output
  const output = {
    lastUpdated,
    alerts,
    clients,
  };

  // Ensure output directory exists
  const outDir = path.dirname(opts.outputFile);
  if (!fs.existsSync(outDir)) {
    fs.mkdirSync(outDir, { recursive: true });
  }

  fs.writeFileSync(opts.outputFile, JSON.stringify(output, null, 2), "utf-8");

  // Summary
  console.log(`\nSync complete.`);
  console.log(`  Clients: ${clients.length}`);
  console.log(`  Collections: ${parsed.length}`);
  console.log(`  Last updated: ${lastUpdated}`);
  console.log(`  Alerts status: ${alerts.status}`);
  console.log(`  Output: ${opts.outputFile}`);
}

main();
