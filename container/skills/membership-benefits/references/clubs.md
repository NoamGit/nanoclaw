# Membership Clubs Registry

Add new clubs by copying the template at the bottom. The agent reads this file during every benefits search.

---

## Club: leumi-bonus

**Name:** לאומי בונוס  
**Website:** https://bonus.leumi.co.il/  
**Description:** Voucher and deal purchasing portal for Bank Leumi cardholders. Buy discounted vouchers and experiences (restaurants, entertainment, travel, retail) at member prices. Fully public — no login required to browse and search deals.

### Credentials (vault env vars)
None — the site is fully public.

### Session state
None required.

### Auth flow
No authentication needed. Fetch directly.

### Search strategy

The page is server-side rendered (SSR) — results are embedded as JSON in the HTML. Use Bash to extract them without needing a browser:

```bash
python3 - <<'EOF'
import urllib.request, re, json, sys

query = "מזגן"  # replace with actual product query
url = f"https://bonus.leumi.co.il/search/{urllib.parse.quote(query)}"
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
html = urllib.request.urlopen(req).read().decode("utf-8")

match = re.search(r'window\.__PRELOADED_STATE__ = ({.*?});\s*</script>', html, re.DOTALL)
state = json.loads(match.group(1))

# Walk to the items list
def find_items(d, depth=0):
    if depth > 8: return []
    if isinstance(d, dict):
        if "items" in d and isinstance(d["items"], list) and len(d["items"]) > 0:
            return d["items"]
        for v in d.values():
            r = find_items(v, depth+1)
            if r: return r
    elif isinstance(d, list):
        for item in d:
            r = find_items(item, depth+1)
            if r: return r
    return []

items = find_items(state)
for item in items:
    name = item.get("name", "")
    club = item.get("club_price", "")
    market = item.get("market_price", "")
    desc = re.sub(r"<[^>]+>", "", item.get("short_description", ""))
    print(f"{name} | מחיר חבר: ₪{club} | מחיר רגיל: ₪{market} | {desc[:80]}")
EOF
```

**Category browse fallback:** if the search returns irrelevant results, try browsing by category URL:
- `https://bonus.leumi.co.il/category/1539` — browse the homepage categories and find the relevant one from the main page's `main_ids` list.

### Notes
- This is a **voucher-purchase site** — deals are pre-bought experiences and gift cards at a member discount, not a at-the-register discount network (that's חבר). Report the `club_price` as what the user pays and `market_price` as the full value.
- Results from the search endpoint may not always be exactly on-topic — use judgment to filter for relevance to the user's actual purchase intent

---

## Club: behatsdaa

**Name:** בהצדעה  
**Website:** https://www.behatsdaa.org.il/  
**Description:** Benefits club for IDF veterans, career military, and their families. Covers retail, services, travel, and entertainment.

### Credentials (vault env vars)
| Env var | Value |
|---------|-------|
| `BEHATSDAA_USERNAME` | Username or ID number |
| `BEHATSDAA_PASSWORD` | Account password |

### Session state
`/workspace/group/benefits-auth/behatsdaa.json`

### Auth flow
The site is a React SPA — form fields are JS-rendered. Use agent-browser to discover them at runtime:

1. Navigate to: `https://www.behatsdaa.org.il/login`
2. Wait for JS to render: `agent-browser wait --load networkidle`
3. Snapshot interactive elements: `agent-browser snapshot -i`
4. Identify the username/ID field and the password field from the snapshot output
5. Fill using semantic locators (adapt to what the snapshot actually shows):
   ```bash
   agent-browser find placeholder "תעודת זהות" fill "${BEHATSDAA_USERNAME}"
   # or: agent-browser fill @<ref-from-snapshot> "${BEHATSDAA_USERNAME}"
   agent-browser find placeholder "סיסמה" fill "${BEHATSDAA_PASSWORD}"
   # or: agent-browser fill @<ref-from-snapshot> "${BEHATSDAA_PASSWORD}"
   ```
6. Click the login/submit button (look for "כניסה" or "התחבר" text)
7. Wait for redirect: `agent-browser wait --load networkidle`
8. Snapshot to confirm login succeeded (member name or dashboard visible)

### Search strategy
1. After login, snapshot the page to find the search bar
2. Fill the search bar with the product query and submit
3. Category browse fallback: if no search bar or no results, navigate to the most relevant category
4. Extract each offer: merchant name, benefit description, conditions

### Notes
- Membership is limited to IDF veterans and career military and their families; credentials must already be registered on the site
- Site is a React SPA with WAF protection — always use agent-browser, never WebFetch

---

## Club: haver-mcc

**Name:** מועדון חבר (HVR)  
**Website:** https://www.mcc.co.il/st_reshet_public.aspx  
**Description:** Public discount network for חבר green card holders. Lists businesses and their discount percentages across retail, food, health, electronics, travel, sport, and more. No login required — the entire directory is publicly accessible.

### Credentials (vault env vars)
None — this is a public site. No login needed.

### Session state
None required.

### Auth flow
No authentication needed. Navigate directly to the search page.

### Search strategy

The site renders results via JavaScript (jQuery + socket.io + DataTables) — use agent-browser, not WebFetch.

**Step 1 — Free text search (preferred):**
```bash
agent-browser open "https://www.mcc.co.il/st_reshet_public.aspx"
agent-browser wait --load networkidle
agent-browser snapshot -i
# Select the "חיפוש לפי מילה" radio if not already selected, then fill freeSearch:
agent-browser find text "חיפוש לפי מילה" click
agent-browser find placeholder "הקלד מילות חיפוש" fill "<product query>"
agent-browser find text "חפש בתי עסק" click
agent-browser wait --load networkidle
agent-browser snapshot -c
```

**Step 2 — Category browse fallback** (if free text yields no results):  
Select the category radio, choose the best-matching category from the dropdown, and click חפש:

| Product type | Category (main_type) |
|---|---|
| אלקטרוניקה / מחשב / מזגן | חשמל מחשבים ואלקטרוניקה |
| אופנה / ביגוד | אופנה |
| מזון / מסעדות | מזון ומשקאות |
| בריאות / יופי / תרופות | בריאות ויופי / בתי מרקחת |
| ריהוט / לבית | לבית ולמשרד / ריהוט |
| ספורט / פנאי | פנאי וספורט |
| נסיעות / תיירות | תיירות, בילוי ונופש |
| רכב / תחבורה | תחבורה ורכב |
| לימודים / קורסים | לימודים |

**Step 3 — Extract results:**  
From the DataTable results, extract for each row:
- Business name (strong.title)
- Discount percentage (אחוז הנחה column)
- Region if shown

### Notes
- Discounts are applied at the credit card billing level (not at the register) — this is noted on the site and worth mentioning to the user
- The site uses socket.io for data loading; wait for `networkidle` before snapshotting results
- Region filter is available if the user wants results near a specific area: כל הארץ / מרכז / דרום / צפון / ירושלים / אילת

---

## Template — adding a new club

Copy this block and fill in the details:

```
## Club: <club-id>

**Name:** <Hebrew/English name>
**Website:** <https://...>
**Description:** <One line: who it's for and what it covers>

### Credentials (vault env vars)
| Env var | Value |
|---------|-------|
| `<CLUB_ID>_USERNAME` | <what this field is> |
| `<CLUB_ID>_PASSWORD` | <what this field is> |

### Session state
`/workspace/group/benefits-auth/<club-id>.json`

### Auth flow
1. Navigate to: `<login URL>`
2. <Step-by-step login instructions>

### Search strategy
1. <How to search — URL pattern or UI steps>
2. <Category browse fallback if applicable>
3. <What to extract from results>

### Notes
- <Quirks, eligibility requirements, session lifetime, etc.>
```
