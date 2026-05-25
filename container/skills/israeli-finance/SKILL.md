---
name: israeli-finance
description: Analyze Israeli bank and credit card transactions using the live financial data MCP. Use when the user asks about spending, bank accounts, credit cards, expenses, financial summaries, subscriptions, budget, salary, burn rate, or anything money-related. Trigger keywords (Hebrew): הוצאות, חשבון, כרטיס אשראי, תנועות, תקציב, חיסכון, הכנסה, קניות, סיכום פיננסי, ניתוח הוצאות, כמה הוצאתי, עמלות, מנויים, חיובים קבועים, ישראכרט, לאומי, מקס. Trigger keywords (English): spending, transactions, bank, credit card, balance, budget, expenses, financial summary, burn rate, subscriptions, recurring charges, salary. Do NOT use for investment advice, stock trading, or payments/transfers.
license: MIT
allowed-tools: Bash(python3:*) mcp__israeli-bank__*
---

# Israeli Finance Skill

## Overview

This skill connects to the **israeli-bank** MCP server, which holds live data scraped daily from your Israeli bank and credit card accounts. Data is refreshed every day at 06:00 via an automated cron job.

**Connected accounts (when all scrapers succeed):**
- Bank Leumi — checking account
- Max (Leumi Card) — credit card
- Isracard — credit card (your account)
- Isracard 2 — credit card (wife's account)

**Known limitation:** Isracard is occasionally rate-limited (HTTP 429) by their API. When this happens, Leumi and Max data is still current. Check freshness before any analysis.

---

## Standard Workflow

### Step 1 — Always check data freshness first

```
mcp__israeli-bank__get_data_freshness
```

- `fresh` (< 36h): proceed normally
- `stale` (> 36h): tell the user data may not reflect recent transactions; offer to proceed anyway
- `never`: no successful scrape yet — explain the limitation

### Step 2 — Orient yourself

Before answering any financial question, call `get_metadata` to understand the date range available:

```
mcp__israeli-bank__get_metadata
```

Then `get_accounts` to see which accounts are populated and their current balances:

```
mcp__israeli-bank__get_accounts
```

Never assume account IDs — always resolve them from `get_accounts`.

### Step 3 — Match the question to the right tool

| User asks about | Tool to use |
|----------------|-------------|
| Monthly burn rate / how much did I spend | `get_financial_summary` |
| Specific transactions / did I pay X | `search_transactions` or `get_transactions` |
| Subscriptions / recurring charges | `get_recurring_charges` |
| Spending at a specific merchant | `analyze_merchant_spending` |
| Top merchants this month | `get_spending_by_merchant` |
| Category breakdown (food vs transport) | `get_category_comparison` |
| Balance history / trend over months | `get_account_balance_history` |
| Day-of-week spending patterns | `analyze_day_of_week_spending` |
| Credit card monthly statement | `get_monthly_credit_summary` |
| Available category names | `get_available_categories` |
| Last scrape status / which providers ran | `get_scrape_status` |

### Step 4 — Interpret and contextualize

Always translate raw numbers into Israeli financial context:
- Currency is ₪ (NIS / שקל)
- Israeli tax year is January–December (same as calendar year)
- VAT (מע"מ) is 18% — note when amounts likely include VAT
- Credit card billing cycle: typically 1st of month (Isracard), around 10th (Max)
- Arnona, vaad bayit, and kupat cholim are fixed monthly charges — flag them as non-discretionary
- "Pending" transactions may not yet appear; scraper captures posted transactions only

### Step 5 — Tax export (optional)

When the user needs a tax-year expense report, use the bundled script `scripts/tax_export.py` together with `get_transactions` output. Run:

```bash
python3 /workspace/global/.claude/skills/israeli-finance/scripts/tax_export.py
```

The script formats transactions as a CSV ready for Israeli accountants, marks potentially VAT-deductible business categories, and groups by tax year.

---

## Common Query Patterns

### "כמה הוצאתי החודש?" / "What did I spend this month?"

1. `get_data_freshness`
2. `get_financial_summary` for current month
3. Compare to previous month for context
4. Highlight top 3 categories and any anomalies

### "מה המנויים שלי?" / "What subscriptions am I paying?"

1. `get_data_freshness`
2. `get_recurring_charges` — lists all detected recurring patterns
3. Summarize total monthly fixed cost
4. Flag any subscriptions that haven't charged recently (cancelled?) or any new ones

### "כמה הוצאתי על אוכל?" / "How much did I spend on food?"

1. `get_available_categories` — confirm the exact category name for food/restaurants
2. `get_category_comparison` with food-related categories for the relevant period
3. Break down between supermarkets vs. restaurants vs. delivery apps

### "יש חיוב חריג?" / "Any unusual charges?"

1. `get_financial_summary` for current period
2. `get_spending_by_merchant` — look for one-time large charges
3. `search_transactions` for amounts above a threshold if needed
4. Flag anything > 2× the average for that merchant

### "סיכום לצרכי מס" / "Tax year summary"

1. `get_metadata` to confirm available date range
2. `get_financial_summary` for each quarter (Q1–Q4)
3. Run `scripts/tax_export.py` with the full year's transactions
4. Return CSV formatted for accountant

---

## Bundled Resources

### References
- `references/spending-categories.md` — Israeli spending category definitions with Hebrew terms, common merchants per category, and VAT deductibility notes. Consult when categorizing unfamiliar merchants or when the user asks about a specific spending type.

### Scripts
- `scripts/tax_export.py` — Exports transactions as a tax-year CSV. Marks business-deductible categories (50% VAT deductibility for meals/entertainment in Israel, 100% for office supplies/professional services). Run with `--help` for options.

---

## Gotchas

- **Always call `get_available_categories` before filtering by category.** Category names are specific strings; hallucinating a category name will return empty results with no error.
- **Always call `get_accounts` before filtering by account ID.** Account IDs are generated from provider+identifier and are not guessable.
- **Isracard may be missing** when the 429 rate limit hits. `get_scrape_status` will tell you which providers ran successfully in the last scrape. Don't tell the user Isracard data is missing without checking.
- **Pending credit card transactions** are not captured — only posted/billed transactions appear in the DB. Transactions from the last 2–3 days on credit cards may be missing.
- **Max (Leumi Card) billing cycle**: Max charges are billed around the 10th of each month. A large charge in one calendar month may appear in the next month's statement.
- **Dual Isracard accounts**: `isracard` is your account, `isracard2` is your wife's. When the user asks "our" expenses, include both.
- **Hebrew date context**: when the user says "החודש" (this month) or "השבוע" (this week), translate to the actual date range before calling tools.
- **Large transfers (העברות)**: Leumi account shows salary deposits and internal transfers. Distinguish income transfers from expenses when calculating burn rate — don't count a salary credit as a "transaction to analyze".

## Troubleshooting

### "No accounts found" or empty results
Likely cause: the account ID used doesn't match. Call `get_accounts` and use the exact ID returned.

### Data seems old / missing recent transactions
Call `get_data_freshness` and `get_scrape_status`. If Isracard failed with 429, the next daily cron (06:00) will retry. Leumi and Max data should still be current.

### Category filter returns nothing
Call `get_available_categories` first — the exact string matters. For example, the category may be `"restaurants"` not `"food"`.

### User asks about investments / stocks / pension
Out of scope for this skill. The MCP only sees bank and credit card transactions, not brokerage accounts, pension funds (קרן פנסיה), or keren hishtalmut (קרן השתלמות).
