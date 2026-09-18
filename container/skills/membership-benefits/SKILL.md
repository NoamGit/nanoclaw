---
name: membership-benefits
description: Search membership clubs and benefit programs for discounts and offers on a purchase. Use when the user expresses purchase intent and asks about missing benefits or discounts. Hebrew trigger patterns: "אני רוצה לקנות X, יש הנחות שאני מפספס?", "אני מתכנן לרכוש X, יש הטבות?", "אני הולך לקנות X, יש לי הנחות?", "רוצה להזמין X, יש הנחות?", "אני רוצה לרכוש X, יש הנחות?". Also triggers on "/benefits X" or "/הטבות X". Do NOT use for supermarket price comparison (use israeli-grocery-price-intelligence for that).
allowed-tools: Bash(agent-browser:*) WebFetch WebSearch
---

# Membership Benefits Finder (מוצא הטבות)

When the user says they want to buy something and asks about missing benefits or discounts, search all configured membership clubs and surface relevant offers.

## Step 1 — Extract purchase intent

Parse the user's message to identify:
- **Product or service** — what they want to buy (e.g., "מזגן", "כרטיסים לקונצרט", "נסיעה לאילת")
- **Brand or vendor** — if mentioned
- **Price range** — if mentioned

## Step 2 — Load club registry

Read `references/clubs.md` for the full club directory. Each entry specifies:
- Club name and URL
- Credential env var names (injected by the OneCLI vault at container startup)
- Session state path (under `/workspace/group/benefits-auth/`)
- Search strategy and URL patterns

## Step 3 — For each active club, search

### Check if the club is configured

Read the credential env vars listed in the club's registry entry:
```bash
echo "${LEUMI_BONUS_USERNAME:-}"
```
If the env var is empty, skip this club and note it as "not configured" in the final report.

### Authenticate

Session state is cached in `/workspace/group/benefits-auth/<club-id>.json` to avoid re-logging in every time.

**a) Try cached session first:**
```bash
test -f /workspace/group/benefits-auth/<club-id>.json && echo "found" || echo "missing"
```
If found, load it and navigate to a page that requires login to verify it is still valid:
```bash
agent-browser state load /workspace/group/benefits-auth/<club-id>.json
agent-browser open "<club-authenticated-url>"
agent-browser snapshot -c
```
If the page shows a login screen, the session has expired — fall through to fresh login.

**b) Fresh login using vault credentials:**
```bash
agent-browser open "<club-login-url>"
agent-browser snapshot -i
agent-browser fill @<username-field> "${<USERNAME_ENV_VAR>}"
agent-browser fill @<password-field> "${<PASSWORD_ENV_VAR>}"
agent-browser click @<submit-button>
agent-browser wait --load networkidle
```
Verify login succeeded (logged-in indicator in the snapshot), then save the session:
```bash
mkdir -p /workspace/group/benefits-auth
agent-browser state save /workspace/group/benefits-auth/<club-id>.json
```

### Search for benefits

Use the club's search strategy from `references/clubs.md` — typically:
1. Navigate to the search URL with the product query
2. Browse relevant categories if search yields no results
3. Snapshot and extract offer details (discount %, conditions, expiry, merchant)

## Step 4 — Compile and present results

After checking all clubs:
- **Found offers** — list each club with relevant offers, including discount %, conditions, and merchant name
- **No matching offers** — briefly list clubs that had no results
- **Not configured** — list clubs whose credentials are not in the vault, with the env var names needed to configure them

Use the user's language. Lead with the best offers.

---

## Direct commands

- `/benefits-setup <club>` or `/הטבות-הגדרה <club>` — force a fresh login for a specific club (refreshes an expired session). Club must already have credentials in the vault.
- `/benefits <product>` or `/הטבות <product>` — explicit trigger without the "I want to buy" phrasing.

---

## Examples

### Example 1 — Buying an air conditioner
User: "אני רוצה לקנות מזגן, יש הנחות שאני מפספס?"
1. Extract: product = "מזגן"
2. Check env vars → Leumi Bonus configured
3. Load cached session → still valid
4. Search bonus.leumi.co.il for "מזגן" or browse the home appliances category
5. Report: "ב-לאומי בונוס יש 8% הנחה ב-KSP ו-5% ב-אחי נסים. לא מצאתי הטבות ב-X."

### Example 2 — Session expired
Cached session fails the verification check → agent does a fresh login using vault env vars → saves new session → continues with search.

### Example 3 — Club not configured
`BEHATSDAA_USERNAME` is empty → report: "בהצדעה לא מוגדר — הוסף `BEHATSDAA_USERNAME` ו-`BEHATSDAA_PASSWORD` ל-vault כדי לאפשר חיפוש שם."

---

## Bundled Resources

- `references/clubs.md` — Club registry: URLs, env var names, session paths, and search strategies. Add new clubs here.
