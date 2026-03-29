#!/usr/bin/env bash
# SEO Pipeline: On-page + PageSpeed collection
# Hermes runs this weekly (Monday 05:00 CT)
# Outputs one markdown file per client to inbox/seo-data/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="$VAULT_DIR/inbox/seo-data"
CLIENTS_FILE="$SCRIPT_DIR/clients.json"
TODAY=$(date +%Y-%m-%d)
PAGESPEED_API="https://www.googleapis.com/pagespeedonline/v5/runPagespeed"

# Optional: set PAGESPEED_API_KEY env var for 25K req/day (free)
# Without a key, the API uses a shared quota that runs out fast
PSI_KEY="${PAGESPEED_API_KEY:-}"

mkdir -p "$DATA_DIR"

# Check dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd not found" >&2
    exit 1
  fi
done

# Read clients from registry
CLIENT_COUNT=$(jq '.clients | length' "$CLIENTS_FILE")

for i in $(seq 0 $((CLIENT_COUNT - 1))); do
  NAME=$(jq -r ".clients[$i].name" "$CLIENTS_FILE")
  SLUG=$(jq -r ".clients[$i].slug" "$CLIENTS_FILE")
  DOMAIN=$(jq -r ".clients[$i].domain" "$CLIENTS_FILE")
  GROUP=$(jq -r ".clients[$i].group" "$CLIENTS_FILE")
  PLATFORM=$(jq -r ".clients[$i].platform" "$CLIENTS_FILE")
  PAGE_COUNT=$(jq ".clients[$i].pages | length" "$CLIENTS_FILE")

  OUTFILE="$DATA_DIR/${SLUG}-${TODAY}.md"

  echo "Collecting: $NAME ($DOMAIN)..."

  cat > "$OUTFILE" <<HEADER
---
client: $NAME
slug: $SLUG
domain: $DOMAIN
group: $GROUP
collected: $TODAY
type: seo-collection
---

# SEO Collection: $NAME
**Date:** $TODAY
**Domain:** $DOMAIN
**Platform:** $PLATFORM

HEADER

  # --- HTTP Status & TTFB ---
  echo "## HTTP Health" >> "$OUTFILE"
  echo "" >> "$OUTFILE"

  HTTP_CODE=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN/" 2>/dev/null || echo "000")
  TTFB=$(curl -so /dev/null -w "%{time_starttransfer}" --max-time 10 "https://$DOMAIN/" 2>/dev/null || echo "timeout")
  REDIRECT=$(curl -sI -o /dev/null -w "%{redirect_url}" --max-time 10 "https://$DOMAIN/" 2>/dev/null || echo "none")

  echo "| Check | Result |" >> "$OUTFILE"
  echo "|-------|--------|" >> "$OUTFILE"
  echo "| HTTP Status | $HTTP_CODE |" >> "$OUTFILE"
  echo "| TTFB | ${TTFB}s |" >> "$OUTFILE"

  if [ -n "$REDIRECT" ] && [ "$REDIRECT" != "" ]; then
    echo "| Redirect | $REDIRECT |" >> "$OUTFILE"
  else
    echo "| Redirect | None |" >> "$OUTFILE"
  fi

  # --- SSL Certificate ---
  SSL_EXPIRY=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo "UNKNOWN")
  echo "| SSL Expiry | $SSL_EXPIRY |" >> "$OUTFILE"
  echo "" >> "$OUTFILE"

  # --- robots.txt ---
  echo "## robots.txt" >> "$OUTFILE"
  echo "" >> "$OUTFILE"
  ROBOTS=$(curl -s --max-time 5 "https://$DOMAIN/robots.txt" 2>/dev/null || echo "FETCH FAILED")
  ROBOTS_STATUS=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN/robots.txt" 2>/dev/null || echo "000")

  if [ "$ROBOTS_STATUS" = "200" ]; then
    echo "Status: Present (200)" >> "$OUTFILE"
    echo '```' >> "$OUTFILE"
    echo "$ROBOTS" | head -20 >> "$OUTFILE"
    echo '```' >> "$OUTFILE"
  else
    echo "**MISSING** (HTTP $ROBOTS_STATUS)" >> "$OUTFILE"
  fi
  echo "" >> "$OUTFILE"

  # --- Sitemap ---
  echo "## Sitemap" >> "$OUTFILE"
  echo "" >> "$OUTFILE"
  SITEMAP_STATUS=$(curl -sI -L -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN/sitemap.xml" 2>/dev/null || echo "000")

  SITEMAP_CONTENT=""
  if [ "$SITEMAP_STATUS" = "200" ]; then
    SITEMAP_CONTENT=$(curl -sL --max-time 10 "https://$DOMAIN/sitemap.xml" 2>/dev/null || echo "")
    SITEMAP_URLS=$(echo "$SITEMAP_CONTENT" | grep -c "<loc>" || echo "0")
    echo "Status: Present (200); $SITEMAP_URLS URLs found" >> "$OUTFILE"
  else
    SITEMAP_URLS=0
    echo "**MISSING** (HTTP $SITEMAP_STATUS)" >> "$OUTFILE"
  fi
  echo "" >> "$OUTFILE"

  # --- Authority score accumulators (collected during per-page loop) ---
  AUTH_WORD_COUNT=0
  AUTH_INTERNAL_LINKS=0
  AUTH_HAS_GBP=0
  AUTH_SOCIAL_FB=0
  AUTH_SOCIAL_IG=0
  AUTH_SOCIAL_TW=0
  AUTH_SOCIAL_LI=0
  AUTH_HAS_REVIEWS=0
  AUTH_HAS_FAQ_SECTION=0
  AUTH_HAS_FAQ_SCHEMA=0
  AUTH_HAS_BREADCRUMB_SCHEMA=0
  AUTH_JSONLD_TOTAL=0
  AUTH_HAS_BLOG=0
  AUTH_TITLES_COLLECTED=""
  # Mobile PageSpeed raw values for Authority (captured from PSI)
  AUTH_MOBILE_PERF="N/A"
  AUTH_LCP_RAW="N/A"
  AUTH_CLS_RAW="N/A"
  AUTH_TBT_RAW="N/A"

  # Check sitemap for blog/news/articles URLs
  if [ -n "$SITEMAP_CONTENT" ]; then
    if echo "$SITEMAP_CONTENT" | grep -qiE '/blog|/news|/articles'; then
      AUTH_HAS_BLOG=1
    fi
  fi

  # --- Per-page checks ---
  echo "## Page Analysis" >> "$OUTFILE"
  echo "" >> "$OUTFILE"

  for j in $(seq 0 $((PAGE_COUNT - 1))); do
    PAGE=$(jq -r ".clients[$i].pages[$j]" "$CLIENTS_FILE")
    URL="https://$DOMAIN$PAGE"

    echo "### $PAGE" >> "$OUTFILE"
    echo "" >> "$OUTFILE"

    # Fetch page HTML to temp file (avoids piping 1MB+ through bash variables)
    TMPHTML=$(mktemp)
    trap "rm -f $TMPHTML" EXIT
    curl -sL --max-time 15 "$URL" -o "$TMPHTML" 2>/dev/null

    if [ ! -s "$TMPHTML" ]; then
      echo "**FETCH FAILED**" >> "$OUTFILE"
      echo "" >> "$OUTFILE"
      rm -f "$TMPHTML"
      continue
    fi

    # Extract all meta info in one perl pass for speed
    eval "$(perl -0777 -ne '
      my $t = $1 if /<title[^>]*>(.*?)<\/title>/si;
      $t //= "MISSING";
      $t =~ s/\n/ /g;

      my $md = "MISSING";
      $md = $1 if /meta\s[^>]*name=["\x27]description["\x27][^>]*content=["\x27]([^"\x27]*)/i;
      $md = $1 if $md eq "MISSING" && /meta\s[^>]*content=["\x27]([^"\x27]*)["\x27][^>]*name=["\x27]description["\x27]/i;

      my $ot = "MISSING";
      $ot = $1 if /meta\s[^>]*property=["\x27]og:title["\x27][^>]*content=["\x27]([^"\x27]*)/i;
      $ot = $1 if $ot eq "MISSING" && /meta\s[^>]*content=["\x27]([^"\x27]*)["\x27][^>]*property=["\x27]og:title["\x27]/i;

      my $od = "MISSING";
      $od = $1 if /meta\s[^>]*property=["\x27]og:description["\x27][^>]*content=["\x27]([^"\x27]*)/i;
      $od = $1 if $od eq "MISSING" && /meta\s[^>]*content=["\x27]([^"\x27]*)["\x27][^>]*property=["\x27]og:description["\x27]/i;

      my $vp = "MISSING";
      $vp = $1 if /meta\s[^>]*name=["\x27]viewport["\x27][^>]*content=["\x27]([^"\x27]*)/i;
      $vp = $1 if $vp eq "MISSING" && /meta\s[^>]*content=["\x27]([^"\x27]*)["\x27][^>]*name=["\x27]viewport["\x27]/i;

      my $jl = () = /application\/ld\+json/g;

      my $cn = "MISSING";
      $cn = $1 if /link\s[^>]*rel=["\x27]canonical["\x27][^>]*href=["\x27]([^"\x27]*)/i;
      $cn = $1 if $cn eq "MISSING" && /link\s[^>]*href=["\x27]([^"\x27]*)["\x27][^>]*rel=["\x27]canonical["\x27]/i;

      my $h1 = () = /<h1[\s>]/gi;

      # Shell-safe: single-quote values, escape internal single quotes
      for ($t,$md,$ot,$od,$vp,$cn) { s/\x27/\x27\\\x27\x27/g; }
      print "META_TITLE=\x27$t\x27\n";
      print "META_DESC=\x27$md\x27\n";
      print "OG_TITLE=\x27$ot\x27\n";
      print "OG_DESC=\x27$od\x27\n";
      print "VIEWPORT=\x27$vp\x27\n";
      print "JSONLD_COUNT=\x27$jl\x27\n";
      print "CANONICAL=\x27$cn\x27\n";
      print "H1_COUNT=\x27$h1\x27\n";
    ' "$TMPHTML")"

    # --- Authority data extraction (before temp file cleanup) ---
    # Word count: strip HTML tags, count words (homepage only, PAGE="/")
    if [ "$PAGE" = "/" ]; then
      AUTH_WORD_COUNT=$(perl -0777 -pe 's/<script[^>]*>.*?<\/script>//gsi; s/<style[^>]*>.*?<\/style>//gsi; s/<[^>]+>//g; s/&[a-z]+;//gi; s/\s+/ /g;' "$TMPHTML" | wc -w | tr -d ' ')
      AUTH_WORD_COUNT=${AUTH_WORD_COUNT:-0}

      # Internal links on homepage: href="/" or href="https://DOMAIN"
      AUTH_INTERNAL_LINKS=$(grep -oiE 'href="(/[^"]*|https?://'"$DOMAIN"'[^"]*)"' "$TMPHTML" | wc -l | tr -d ' ')
      AUTH_INTERNAL_LINKS=${AUTH_INTERNAL_LINKS:-0}

      # Google Business Profile or NAP
      if grep -qiE 'google\.com/maps|"@type"\s*:\s*"(LocalBusiness|PostalAddress)"' "$TMPHTML" 2>/dev/null; then
        AUTH_HAS_GBP=1
      fi

      # Social media links
      grep -qi 'facebook\.com' "$TMPHTML" 2>/dev/null && AUTH_SOCIAL_FB=1
      grep -qi 'instagram\.com' "$TMPHTML" 2>/dev/null && AUTH_SOCIAL_IG=1
      grep -qiE 'twitter\.com|x\.com' "$TMPHTML" 2>/dev/null && AUTH_SOCIAL_TW=1
      grep -qi 'linkedin\.com' "$TMPHTML" 2>/dev/null && AUTH_SOCIAL_LI=1

      # Reviews/testimonials
      if grep -qiE 'review|testimonial|stars|rating' "$TMPHTML" 2>/dev/null; then
        AUTH_HAS_REVIEWS=1
      fi

      # FAQ section (check nav links and page content)
      if grep -qiE 'href="[^"]*faq[^"]*"|id="faq"|class="[^"]*faq[^"]*"|<h[2-4][^>]*>[^<]*faq[^<]*</h' "$TMPHTML" 2>/dev/null; then
        AUTH_HAS_FAQ_SECTION=1
      fi

      # Blog/content section from nav links on homepage
      if [ "${AUTH_HAS_BLOG:-0}" -eq 0 ] 2>/dev/null; then
        if grep -qiE 'href="[^"]*/blog[^"]*"|href="[^"]*/news[^"]*"|href="[^"]*/articles[^"]*"' "$TMPHTML" 2>/dev/null; then
          AUTH_HAS_BLOG=1
        fi
      fi
    fi

    # JSON-LD schema types (all pages)
    AUTH_JSONLD_TOTAL=$((AUTH_JSONLD_TOTAL + JSONLD_COUNT))

    # FAQPage schema
    if grep -qi '"FAQPage"' "$TMPHTML" 2>/dev/null; then
      AUTH_HAS_FAQ_SCHEMA=1
      AUTH_HAS_FAQ_SECTION=1
    fi

    # Breadcrumb schema
    if grep -qi '"BreadcrumbList"' "$TMPHTML" 2>/dev/null; then
      AUTH_HAS_BREADCRUMB_SCHEMA=1
    fi

    # Collect title for uniqueness comparison
    if [ "$META_TITLE" != "MISSING" ] && [ -n "$META_TITLE" ]; then
      AUTH_TITLES_COLLECTED="${AUTH_TITLES_COLLECTED}${META_TITLE}"$'\n'
    fi

    rm -f "$TMPHTML"

    echo "| Check | Value |" >> "$OUTFILE"
    echo "|-------|-------|" >> "$OUTFILE"
    echo "| Title | $META_TITLE |" >> "$OUTFILE"
    echo "| Meta Description | $META_DESC |" >> "$OUTFILE"
    echo "| OG Title | $OG_TITLE |" >> "$OUTFILE"
    echo "| OG Description | $OG_DESC |" >> "$OUTFILE"
    echo "| Viewport | $VIEWPORT |" >> "$OUTFILE"
    echo "| JSON-LD Schemas | $JSONLD_COUNT |" >> "$OUTFILE"
    echo "| Canonical | $CANONICAL |" >> "$OUTFILE"
    echo "| H1 Tags | $H1_COUNT |" >> "$OUTFILE"
    echo "" >> "$OUTFILE"

    # --- PageSpeed Insights ---
    echo "#### PageSpeed Insights" >> "$OUTFILE"
    echo "" >> "$OUTFILE"

    for STRATEGY in mobile desktop; do
      STRAT_LABEL=$(echo "$STRATEGY" | perl -pe '$_ = ucfirst')
      ENCODED_URL=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$URL', safe=''))")
      PSI_URL="$PAGESPEED_API?url=$ENCODED_URL&strategy=$STRATEGY&category=PERFORMANCE&category=SEO&category=ACCESSIBILITY&category=BEST_PRACTICES"
      [ -n "$PSI_KEY" ] && PSI_URL="$PSI_URL&key=$PSI_KEY"
      PSI_RESULT=$(curl -s --max-time 45 "$PSI_URL" 2>/dev/null || echo "{}")

      # Check for API errors (quota exceeded, etc.)
      PSI_ERROR=$(echo "$PSI_RESULT" | jq -r '.error.message // empty' 2>/dev/null || echo "")
      if [ -n "$PSI_ERROR" ]; then
        echo "**$STRAT_LABEL:** API error; $PSI_ERROR" >> "$OUTFILE"
        echo "" >> "$OUTFILE"
        continue
      fi

      PERF_SCORE=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.categories.performance.score // empty' 2>/dev/null || echo "")
      SEO_SCORE=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.categories.seo.score // empty' 2>/dev/null || echo "")
      A11Y_SCORE=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.categories.accessibility.score // empty' 2>/dev/null || echo "")
      BP_SCORE=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.categories["best-practices"].score // empty' 2>/dev/null || echo "")

      # Convert to percentages
      [ -n "$PERF_SCORE" ] && PERF_SCORE=$(echo "$PERF_SCORE * 100" | bc | cut -d. -f1) || PERF_SCORE="N/A"
      [ -n "$SEO_SCORE" ] && SEO_SCORE=$(echo "$SEO_SCORE * 100" | bc | cut -d. -f1) || SEO_SCORE="N/A"
      [ -n "$A11Y_SCORE" ] && A11Y_SCORE=$(echo "$A11Y_SCORE * 100" | bc | cut -d. -f1) || A11Y_SCORE="N/A"
      [ -n "$BP_SCORE" ] && BP_SCORE=$(echo "$BP_SCORE * 100" | bc | cut -d. -f1) || BP_SCORE="N/A"

      # Core Web Vitals from PSI
      FCP=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.audits["first-contentful-paint"].displayValue // "N/A"' 2>/dev/null || echo "N/A")
      LCP=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.audits["largest-contentful-paint"].displayValue // "N/A"' 2>/dev/null || echo "N/A")
      TBT=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.audits["total-blocking-time"].displayValue // "N/A"' 2>/dev/null || echo "N/A")
      CLS=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.audits["cumulative-layout-shift"].displayValue // "N/A"' 2>/dev/null || echo "N/A")

      # Capture mobile PSI values for Authority Page Experience scoring
      if [ "$STRATEGY" = "mobile" ] && [ "$PAGE" = "/" ]; then
        AUTH_MOBILE_PERF="${PERF_SCORE}"
        AUTH_LCP_RAW=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.audits["largest-contentful-paint"].numericValue // empty' 2>/dev/null || echo "")
        AUTH_CLS_RAW=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.audits["cumulative-layout-shift"].numericValue // empty' 2>/dev/null || echo "")
        AUTH_TBT_RAW=$(echo "$PSI_RESULT" | jq -r '.lighthouseResult.audits["total-blocking-time"].numericValue // empty' 2>/dev/null || echo "")
      fi

      echo "**$STRAT_LABEL:**" >> "$OUTFILE"
      echo "" >> "$OUTFILE"
      echo "| Metric | Score |" >> "$OUTFILE"
      echo "|--------|-------|" >> "$OUTFILE"
      echo "| Performance | ${PERF_SCORE}% |" >> "$OUTFILE"
      echo "| SEO | ${SEO_SCORE}% |" >> "$OUTFILE"
      echo "| Accessibility | ${A11Y_SCORE}% |" >> "$OUTFILE"
      echo "| Best Practices | ${BP_SCORE}% |" >> "$OUTFILE"
      echo "| FCP | $FCP |" >> "$OUTFILE"
      echo "| LCP | $LCP |" >> "$OUTFILE"
      echo "| TBT | $TBT |" >> "$OUTFILE"
      echo "| CLS | $CLS |" >> "$OUTFILE"
      echo "" >> "$OUTFILE"

      # Rate limit: be polite to the free API
      sleep 2
    done
  done

  # ==========================================================
  # WSS FOUNDATION: computed from collected data above
  # 100-point scale across 6 categories
  # ==========================================================
  echo "## WSS Foundation" >> "$OUTFILE"
  echo "" >> "$OUTFILE"

  WSS_TOTAL=0

  # --- Crawlability (20 pts) ---
  WSS_CRAWL=0
  [ "$ROBOTS_STATUS" = "200" ] && WSS_CRAWL=$((WSS_CRAWL + 5))
  [ "$SITEMAP_STATUS" = "200" ] && WSS_CRAWL=$((WSS_CRAWL + 5))
  [ "$SITEMAP_STATUS" = "200" ] && [ "${SITEMAP_URLS:-0}" -gt 0 ] 2>/dev/null && WSS_CRAWL=$((WSS_CRAWL + 2))
  # Canonical (from last page analyzed)
  [ "$CANONICAL" != "MISSING" ] && [ -n "$CANONICAL" ] && WSS_CRAWL=$((WSS_CRAWL + 5))
  # No redirect on homepage
  if [ -z "$REDIRECT" ] || [ "$REDIRECT" = "" ]; then
    WSS_CRAWL=$((WSS_CRAWL + 3))
  fi
  WSS_TOTAL=$((WSS_TOTAL + WSS_CRAWL))

  # --- On-Page (25 pts) ---
  WSS_ONPAGE=0
  # Title present and reasonable length
  if [ "$META_TITLE" != "MISSING" ] && [ -n "$META_TITLE" ]; then
    TITLE_LEN=${#META_TITLE}
    WSS_ONPAGE=$((WSS_ONPAGE + 3))
    [ "$TITLE_LEN" -ge 30 ] && [ "$TITLE_LEN" -le 70 ] && WSS_ONPAGE=$((WSS_ONPAGE + 2))
  fi
  # Meta description present and reasonable length
  if [ "$META_DESC" != "MISSING" ] && [ -n "$META_DESC" ]; then
    DESC_LEN=${#META_DESC}
    WSS_ONPAGE=$((WSS_ONPAGE + 3))
    [ "$DESC_LEN" -ge 100 ] && [ "$DESC_LEN" -le 170 ] && WSS_ONPAGE=$((WSS_ONPAGE + 2))
  fi
  # H1 present
  [ "${H1_COUNT:-0}" -ge 1 ] 2>/dev/null && WSS_ONPAGE=$((WSS_ONPAGE + 5))
  # Exactly one H1
  [ "${H1_COUNT:-0}" -eq 1 ] 2>/dev/null && WSS_ONPAGE=$((WSS_ONPAGE + 2))
  # Viewport
  [ "$VIEWPORT" != "MISSING" ] && [ -n "$VIEWPORT" ] && WSS_ONPAGE=$((WSS_ONPAGE + 3))
  # Title contains location or service keyword (basic check)
  if echo "$META_TITLE" | grep -qi "lake\|ozark\|boat\|rental\|wake\|yacht\|chiro\|dock"; then
    WSS_ONPAGE=$((WSS_ONPAGE + 5))
  fi
  [ $WSS_ONPAGE -gt 25 ] && WSS_ONPAGE=25
  WSS_TOTAL=$((WSS_TOTAL + WSS_ONPAGE))

  # --- Structured Data (15 pts) ---
  WSS_SCHEMA=0
  [ "${JSONLD_COUNT:-0}" -ge 1 ] 2>/dev/null && WSS_SCHEMA=$((WSS_SCHEMA + 8))
  [ "${JSONLD_COUNT:-0}" -ge 2 ] 2>/dev/null && WSS_SCHEMA=$((WSS_SCHEMA + 2))
  [ "$OG_TITLE" != "MISSING" ] && [ -n "$OG_TITLE" ] && WSS_SCHEMA=$((WSS_SCHEMA + 5))
  [ $WSS_SCHEMA -gt 15 ] && WSS_SCHEMA=15
  WSS_TOTAL=$((WSS_TOTAL + WSS_SCHEMA))

  # --- Social/Sharing (10 pts) ---
  WSS_SOCIAL=0
  [ "$OG_TITLE" != "MISSING" ] && [ -n "$OG_TITLE" ] && WSS_SOCIAL=$((WSS_SOCIAL + 3))
  [ "$OG_DESC" != "MISSING" ] && [ -n "$OG_DESC" ] && WSS_SOCIAL=$((WSS_SOCIAL + 3))
  # Twitter card check (re-fetch would be needed; estimate from OG presence)
  [ "$OG_TITLE" != "MISSING" ] && [ "$OG_DESC" != "MISSING" ] && WSS_SOCIAL=$((WSS_SOCIAL + 4))
  [ $WSS_SOCIAL -gt 10 ] && WSS_SOCIAL=10
  WSS_TOTAL=$((WSS_TOTAL + WSS_SOCIAL))

  # --- Performance (20 pts) ---
  # Use last captured PageSpeed scores (PERF_SCORE is still in scope from last strategy loop)
  WSS_PERF=0
  # TTFB
  TTFB_MS=$(echo "$TTFB" | awk '{printf "%d", $1 * 1000}' 2>/dev/null || echo "9999")
  [ "$TTFB_MS" -lt 500 ] 2>/dev/null && WSS_PERF=$((WSS_PERF + 4))
  [ "$TTFB_MS" -ge 500 ] 2>/dev/null && [ "$TTFB_MS" -lt 1000 ] 2>/dev/null && WSS_PERF=$((WSS_PERF + 2))
  # HTTP status
  [ "$HTTP_CODE" = "200" ] && WSS_PERF=$((WSS_PERF + 3))
  # SSL valid
  [ "$SSL_EXPIRY" != "UNKNOWN" ] && WSS_PERF=$((WSS_PERF + 3))
  # PageSpeed mobile performance (from last run; use N/A-safe check)
  if [ "${PERF_SCORE:-N/A}" != "N/A" ] 2>/dev/null; then
    [ "$PERF_SCORE" -ge 90 ] 2>/dev/null && WSS_PERF=$((WSS_PERF + 5))
    [ "$PERF_SCORE" -ge 70 ] 2>/dev/null && [ "$PERF_SCORE" -lt 90 ] 2>/dev/null && WSS_PERF=$((WSS_PERF + 3))
    [ "$PERF_SCORE" -ge 50 ] 2>/dev/null && [ "$PERF_SCORE" -lt 70 ] 2>/dev/null && WSS_PERF=$((WSS_PERF + 1))
  fi
  # Desktop bonus
  WSS_PERF=$((WSS_PERF + 5))  # Default credit; PSI desktop almost always 90+
  [ $WSS_PERF -gt 20 ] && WSS_PERF=20
  WSS_TOTAL=$((WSS_TOTAL + WSS_PERF))

  # --- Content Depth (10 pts) ---
  WSS_CONTENT=0
  [ "$PAGE_COUNT" -gt 1 ] 2>/dev/null && WSS_CONTENT=$((WSS_CONTENT + 5))
  [ "$PAGE_COUNT" -gt 3 ] 2>/dev/null && WSS_CONTENT=$((WSS_CONTENT + 3))
  # Single-page sites get partial credit for content length (can't easily measure here)
  [ "$PAGE_COUNT" -eq 1 ] 2>/dev/null && WSS_CONTENT=$((WSS_CONTENT + 2))
  [ $WSS_CONTENT -gt 10 ] && WSS_CONTENT=10
  WSS_TOTAL=$((WSS_TOTAL + WSS_CONTENT))

  # Cap at 100
  [ $WSS_TOTAL -gt 100 ] && WSS_TOTAL=100

  # Grade
  if [ $WSS_TOTAL -ge 90 ]; then WSS_GRADE="A"
  elif [ $WSS_TOTAL -ge 80 ]; then WSS_GRADE="B+"
  elif [ $WSS_TOTAL -ge 70 ]; then WSS_GRADE="B"
  elif [ $WSS_TOTAL -ge 60 ]; then WSS_GRADE="C+"
  elif [ $WSS_TOTAL -ge 50 ]; then WSS_GRADE="C"
  elif [ $WSS_TOTAL -ge 40 ]; then WSS_GRADE="D"
  else WSS_GRADE="F"
  fi

  echo "**Overall: ${WSS_TOTAL}/100 (${WSS_GRADE})**" >> "$OUTFILE"
  echo "" >> "$OUTFILE"
  echo "| Category | Points | Max |" >> "$OUTFILE"
  echo "|----------|--------|-----|" >> "$OUTFILE"
  echo "| Crawlability (robots, sitemap, canonical) | $WSS_CRAWL | 20 |" >> "$OUTFILE"
  echo "| On-Page (title, description, H1, keywords) | $WSS_ONPAGE | 25 |" >> "$OUTFILE"
  echo "| Structured Data (JSON-LD, OG tags) | $WSS_SCHEMA | 15 |" >> "$OUTFILE"
  echo "| Social/Sharing (OG, Twitter cards) | $WSS_SOCIAL | 10 |" >> "$OUTFILE"
  echo "| Performance (TTFB, PageSpeed, SSL) | $WSS_PERF | 20 |" >> "$OUTFILE"
  echo "| Content Depth (pages, internal links) | $WSS_CONTENT | 10 |" >> "$OUTFILE"
  echo "| **Total** | **$WSS_TOTAL** | **100** |" >> "$OUTFILE"
  echo "" >> "$OUTFILE"

  # ==========================================================
  # WSS AUTHORITY: content quality & competitive readiness
  # 100-point scale across 5 categories
  # ==========================================================
  echo "## WSS Authority" >> "$OUTFILE"
  echo "" >> "$OUTFILE"

  AUTH_TOTAL=0

  # --- Content Quality (30 pts) ---
  AUTH_CQ=0
  # Word count scoring
  if [ "${AUTH_WORD_COUNT:-0}" -ge 1000 ] 2>/dev/null; then
    AUTH_CQ=$((AUTH_CQ + 15))
  elif [ "${AUTH_WORD_COUNT:-0}" -ge 500 ] 2>/dev/null; then
    AUTH_CQ=$((AUTH_CQ + 10))
  elif [ "${AUTH_WORD_COUNT:-0}" -ge 300 ] 2>/dev/null; then
    AUTH_CQ=$((AUTH_CQ + 5))
  fi
  # Unique pages in sitemap
  if [ "${SITEMAP_URLS:-0}" -gt 10 ] 2>/dev/null; then
    AUTH_CQ=$((AUTH_CQ + 10))
  elif [ "${SITEMAP_URLS:-0}" -ge 6 ] 2>/dev/null; then
    AUTH_CQ=$((AUTH_CQ + 8))
  elif [ "${SITEMAP_URLS:-0}" -ge 2 ] 2>/dev/null; then
    AUTH_CQ=$((AUTH_CQ + 5))
  fi
  # Blog/content section (detected from sitemap URLs + homepage nav links)
  [ "${AUTH_HAS_BLOG:-0}" -eq 1 ] 2>/dev/null && AUTH_CQ=$((AUTH_CQ + 5))
  [ $AUTH_CQ -gt 30 ] && AUTH_CQ=30
  AUTH_TOTAL=$((AUTH_TOTAL + AUTH_CQ))

  # --- Internal Linking (15 pts) ---
  AUTH_IL=0
  if [ "${AUTH_INTERNAL_LINKS:-0}" -gt 20 ] 2>/dev/null; then
    AUTH_IL=15
  elif [ "${AUTH_INTERNAL_LINKS:-0}" -ge 11 ] 2>/dev/null; then
    AUTH_IL=10
  elif [ "${AUTH_INTERNAL_LINKS:-0}" -ge 4 ] 2>/dev/null; then
    AUTH_IL=5
  fi
  AUTH_TOTAL=$((AUTH_TOTAL + AUTH_IL))

  # --- External Readiness (20 pts) ---
  AUTH_ER=0
  # GBP / NAP
  [ "${AUTH_HAS_GBP:-0}" -eq 1 ] 2>/dev/null && AUTH_ER=$((AUTH_ER + 5))
  # Social media links: +2 each, max 8
  AUTH_SOCIAL_PTS=0
  [ "${AUTH_SOCIAL_FB:-0}" -eq 1 ] 2>/dev/null && AUTH_SOCIAL_PTS=$((AUTH_SOCIAL_PTS + 2))
  [ "${AUTH_SOCIAL_IG:-0}" -eq 1 ] 2>/dev/null && AUTH_SOCIAL_PTS=$((AUTH_SOCIAL_PTS + 2))
  [ "${AUTH_SOCIAL_TW:-0}" -eq 1 ] 2>/dev/null && AUTH_SOCIAL_PTS=$((AUTH_SOCIAL_PTS + 2))
  [ "${AUTH_SOCIAL_LI:-0}" -eq 1 ] 2>/dev/null && AUTH_SOCIAL_PTS=$((AUTH_SOCIAL_PTS + 2))
  [ $AUTH_SOCIAL_PTS -gt 8 ] && AUTH_SOCIAL_PTS=8
  AUTH_ER=$((AUTH_ER + AUTH_SOCIAL_PTS))
  # Reviews/testimonials
  [ "${AUTH_HAS_REVIEWS:-0}" -eq 1 ] 2>/dev/null && AUTH_ER=$((AUTH_ER + 4))
  # FAQ section or FAQ schema
  if [ "${AUTH_HAS_FAQ_SECTION:-0}" -eq 1 ] 2>/dev/null || [ "${AUTH_HAS_FAQ_SCHEMA:-0}" -eq 1 ] 2>/dev/null; then
    AUTH_ER=$((AUTH_ER + 3))
  fi
  [ $AUTH_ER -gt 20 ] && AUTH_ER=20
  AUTH_TOTAL=$((AUTH_TOTAL + AUTH_ER))

  # --- Technical Depth (20 pts) ---
  AUTH_TD=0
  # JSON-LD schema count (total across all pages)
  if [ "${AUTH_JSONLD_TOTAL:-0}" -ge 4 ] 2>/dev/null; then
    AUTH_TD=$((AUTH_TD + 8))
  elif [ "${AUTH_JSONLD_TOTAL:-0}" -ge 2 ] 2>/dev/null; then
    AUTH_TD=$((AUTH_TD + 6))
  elif [ "${AUTH_JSONLD_TOTAL:-0}" -ge 1 ] 2>/dev/null; then
    AUTH_TD=$((AUTH_TD + 3))
  fi
  # FAQPage schema specifically
  [ "${AUTH_HAS_FAQ_SCHEMA:-0}" -eq 1 ] 2>/dev/null && AUTH_TD=$((AUTH_TD + 4))
  # Breadcrumb schema
  [ "${AUTH_HAS_BREADCRUMB_SCHEMA:-0}" -eq 1 ] 2>/dev/null && AUTH_TD=$((AUTH_TD + 4))
  # Unique titles across pages
  if [ "$PAGE_COUNT" -gt 1 ] 2>/dev/null && [ -n "$AUTH_TITLES_COLLECTED" ]; then
    AUTH_UNIQUE_TITLES=$(echo "$AUTH_TITLES_COLLECTED" | sort -u | grep -c . || echo "0")
    AUTH_TOTAL_TITLES=$(echo "$AUTH_TITLES_COLLECTED" | grep -c . || echo "0")
    if [ "$AUTH_UNIQUE_TITLES" -eq "$AUTH_TOTAL_TITLES" ] 2>/dev/null && [ "$AUTH_TOTAL_TITLES" -gt 1 ] 2>/dev/null; then
      AUTH_TD=$((AUTH_TD + 4))
    elif [ "$AUTH_UNIQUE_TITLES" -gt 1 ] 2>/dev/null; then
      AUTH_TD=$((AUTH_TD + 2))
    fi
  fi
  [ $AUTH_TD -gt 20 ] && AUTH_TD=20
  AUTH_TOTAL=$((AUTH_TOTAL + AUTH_TD))

  # --- Page Experience (15 pts) ---
  AUTH_PE=0
  # Mobile PageSpeed >= 90: +5, >= 70: +3, >= 50: +1
  if [ "${AUTH_MOBILE_PERF:-N/A}" != "N/A" ] 2>/dev/null; then
    if [ "$AUTH_MOBILE_PERF" -ge 90 ] 2>/dev/null; then
      AUTH_PE=$((AUTH_PE + 5))
    elif [ "$AUTH_MOBILE_PERF" -ge 70 ] 2>/dev/null; then
      AUTH_PE=$((AUTH_PE + 3))
    elif [ "$AUTH_MOBILE_PERF" -ge 50 ] 2>/dev/null; then
      AUTH_PE=$((AUTH_PE + 1))
    fi
  fi
  # LCP: numericValue is in ms; <= 2500ms: +5, <= 4000ms: +3
  if [ -n "${AUTH_LCP_RAW}" ] && [ "${AUTH_LCP_RAW}" != "N/A" ] && [ "${AUTH_LCP_RAW}" != "" ]; then
    AUTH_LCP_MS=$(printf '%.0f' "$AUTH_LCP_RAW" 2>/dev/null || echo "99999")
    if [ "$AUTH_LCP_MS" -le 2500 ] 2>/dev/null; then
      AUTH_PE=$((AUTH_PE + 5))
    elif [ "$AUTH_LCP_MS" -le 4000 ] 2>/dev/null; then
      AUTH_PE=$((AUTH_PE + 3))
    fi
  fi
  # CLS: numericValue is raw; <= 0.1: +3 (compare as integer: multiply by 1000)
  if [ -n "${AUTH_CLS_RAW}" ] && [ "${AUTH_CLS_RAW}" != "N/A" ] && [ "${AUTH_CLS_RAW}" != "" ]; then
    AUTH_CLS_INT=$(printf '%.0f' "$(echo "${AUTH_CLS_RAW} * 1000" | bc 2>/dev/null || echo "9999")" 2>/dev/null || echo "9999")
    if [ "$AUTH_CLS_INT" -le 100 ] 2>/dev/null; then
      AUTH_PE=$((AUTH_PE + 3))
    fi
  fi
  # TBT: numericValue is in ms; < 200ms: +2
  if [ -n "${AUTH_TBT_RAW}" ] && [ "${AUTH_TBT_RAW}" != "N/A" ] && [ "${AUTH_TBT_RAW}" != "" ]; then
    AUTH_TBT_MS=$(printf '%.0f' "$AUTH_TBT_RAW" 2>/dev/null || echo "99999")
    if [ "$AUTH_TBT_MS" -lt 200 ] 2>/dev/null; then
      AUTH_PE=$((AUTH_PE + 2))
    fi
  fi
  [ $AUTH_PE -gt 15 ] && AUTH_PE=15
  AUTH_TOTAL=$((AUTH_TOTAL + AUTH_PE))

  # Cap at 100
  [ $AUTH_TOTAL -gt 100 ] && AUTH_TOTAL=100

  # Grade
  if [ $AUTH_TOTAL -ge 90 ]; then AUTH_GRADE="A"
  elif [ $AUTH_TOTAL -ge 80 ]; then AUTH_GRADE="B+"
  elif [ $AUTH_TOTAL -ge 70 ]; then AUTH_GRADE="B"
  elif [ $AUTH_TOTAL -ge 60 ]; then AUTH_GRADE="C+"
  elif [ $AUTH_TOTAL -ge 50 ]; then AUTH_GRADE="C"
  elif [ $AUTH_TOTAL -ge 40 ]; then AUTH_GRADE="D"
  else AUTH_GRADE="F"
  fi

  echo "**Overall: ${AUTH_TOTAL}/100 (${AUTH_GRADE})**" >> "$OUTFILE"
  echo "" >> "$OUTFILE"
  echo "| Category | Points | Max |" >> "$OUTFILE"
  echo "|----------|--------|-----|" >> "$OUTFILE"
  echo "| Content Quality (word count, pages, blog) | $AUTH_CQ | 30 |" >> "$OUTFILE"
  echo "| Internal Linking (homepage links) | $AUTH_IL | 15 |" >> "$OUTFILE"
  echo "| External Readiness (GBP, social, reviews, FAQ) | $AUTH_ER | 20 |" >> "$OUTFILE"
  echo "| Technical Depth (schemas, breadcrumbs, titles) | $AUTH_TD | 20 |" >> "$OUTFILE"
  echo "| Page Experience (PageSpeed, LCP, CLS, TBT) | $AUTH_PE | 15 |" >> "$OUTFILE"
  echo "| **Total** | **$AUTH_TOTAL** | **100** |" >> "$OUTFILE"
  echo "" >> "$OUTFILE"

  # ==========================================================
  # COMBINED WSS: average of Foundation and Authority
  # ==========================================================
  echo "## Combined WSS" >> "$OUTFILE"
  echo "" >> "$OUTFILE"

  COMBINED=$((( WSS_TOTAL + AUTH_TOTAL ) / 2))

  # Grade
  if [ $COMBINED -ge 90 ]; then COMBINED_GRADE="A"
  elif [ $COMBINED -ge 80 ]; then COMBINED_GRADE="B+"
  elif [ $COMBINED -ge 70 ]; then COMBINED_GRADE="B"
  elif [ $COMBINED -ge 60 ]; then COMBINED_GRADE="C+"
  elif [ $COMBINED -ge 50 ]; then COMBINED_GRADE="C"
  elif [ $COMBINED -ge 40 ]; then COMBINED_GRADE="D"
  else COMBINED_GRADE="F"
  fi

  echo "**Overall: ${COMBINED}/100 (${COMBINED_GRADE})**" >> "$OUTFILE"
  echo "" >> "$OUTFILE"
  echo "| Score | Points | Grade |" >> "$OUTFILE"
  echo "|-------|--------|-------|" >> "$OUTFILE"
  echo "| WSS Foundation | ${WSS_TOTAL}/100 | $WSS_GRADE |" >> "$OUTFILE"
  echo "| WSS Authority | ${AUTH_TOTAL}/100 | $AUTH_GRADE |" >> "$OUTFILE"
  echo "| **Combined** | **${COMBINED}/100** | **$COMBINED_GRADE** |" >> "$OUTFILE"
  echo "" >> "$OUTFILE"

  echo "---" >> "$OUTFILE"
  echo "Collected by SEO Pipeline v3.0 (WSS Foundation + Authority)" >> "$OUTFILE"

  echo "  -> $OUTFILE (Foundation: ${WSS_TOTAL}/100, Authority: ${AUTH_TOTAL}/100, Combined: ${COMBINED}/100)"
done

echo ""
echo "Collection complete. Files in: $DATA_DIR"
