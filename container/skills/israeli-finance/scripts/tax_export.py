#!/usr/bin/env python3
"""
tax_export.py — Export transactions as a tax-year CSV for Israeli accountants.

Usage:
  python3 tax_export.py --input transactions.json [--year 2025] [--output expenses_2025.csv]
  python3 tax_export.py --stdin < transactions.json
  python3 tax_export.py --help

Input: JSON array of transaction objects from mcp__israeli-bank__get_transactions.
Output: CSV with columns: date, description, amount, category, account, vat_deductible_pct, notes.

VAT deductibility rates (Israeli tax rules, self-employed):
  - Meals / restaurants / entertainment: 50%
  - Vehicle fuel and maintenance: 66.67% (2/3)
  - Professional services, office supplies, software: 100%
  - Travel abroad: 100%
  - Personal expenses: 0%
"""

import json
import sys
import csv
import argparse
from datetime import datetime

# Category -> VAT deductibility percentage (for self-employed)
VAT_DEDUCTIBILITY = {
    "restaurants": 50,
    "entertainment": 50,
    "food_delivery": 50,
    "transportation": 67,   # fuel/vehicle
    "professional_services": 100,
    "office_supplies": 100,
    "software": 100,
    "travel": 100,
    "communication": 100,   # phone / internet for business
    "education": 100,
    "healthcare": 0,
    "groceries": 0,
    "housing": 0,
    "insurance": 0,
    "savings": 0,
    "personal": 0,
}

# Hebrew category display names
CATEGORY_HE = {
    "restaurants": "מסעדות",
    "entertainment": "בילוי",
    "food_delivery": "משלוחי אוכל",
    "transportation": "תחבורה",
    "professional_services": "שירותים מקצועיים",
    "office_supplies": "ציוד משרדי",
    "software": "תוכנה",
    "travel": "נסיעות",
    "communication": "תקשורת",
    "education": "חינוך",
    "healthcare": "בריאות",
    "groceries": "מזון / קניות",
    "housing": "דיור",
    "insurance": "ביטוח",
    "savings": "חיסכון",
    "personal": "אישי",
}


def parse_date(date_str: str) -> datetime:
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d"):
        try:
            return datetime.strptime(date_str, fmt)
        except ValueError:
            continue
    raise ValueError(f"Cannot parse date: {date_str}")


def format_amount(amount) -> str:
    """Format as negative for expenses (Israeli accountant convention)."""
    try:
        val = float(amount)
        return f"{val:.2f}"
    except (TypeError, ValueError):
        return str(amount)


def export_transactions(transactions: list, year: int, output_file: str = None):
    """Filter to tax year and write CSV."""
    filtered = []
    for tx in transactions:
        date_str = tx.get("date", "")
        try:
            date = parse_date(date_str)
        except ValueError:
            continue
        if date.year != year:
            continue

        amount = tx.get("amount", 0)
        # Skip income/credit entries (positive amounts) unless explicitly requested
        # In Israeli credit card data, charges are negative; credits are positive
        category = tx.get("category", "personal").lower()
        vat_pct = VAT_DEDUCTIBILITY.get(category, 0)
        category_he = CATEGORY_HE.get(category, category)

        filtered.append({
            "date": date.strftime("%d/%m/%Y"),
            "description": tx.get("description", ""),
            "amount_nis": format_amount(amount),
            "category_en": category,
            "category_he": category_he,
            "account": tx.get("accountId", ""),
            "vat_deductible_pct": vat_pct,
            "vat_deductible_amount": f"{abs(float(amount or 0)) * vat_pct / 100:.2f}" if vat_pct > 0 else "0.00",
            "notes": tx.get("memo", ""),
        })

    filtered.sort(key=lambda r: datetime.strptime(r["date"], "%d/%m/%Y"))

    fieldnames = [
        "date", "description", "amount_nis", "category_en", "category_he",
        "account", "vat_deductible_pct", "vat_deductible_amount", "notes",
    ]

    out = open(output_file, "w", newline="", encoding="utf-8-sig") if output_file else sys.stdout
    try:
        writer = csv.DictWriter(out, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(filtered)
    finally:
        if output_file:
            out.close()

    total = sum(float(r["amount_nis"]) for r in filtered)
    total_deductible = sum(float(r["vat_deductible_amount"]) for r in filtered)

    print(f"\nSummary for tax year {year}:", file=sys.stderr)
    print(f"  Transactions exported: {len(filtered)}", file=sys.stderr)
    print(f"  Total expenses:        ₪{abs(total):,.2f}", file=sys.stderr)
    print(f"  VAT-deductible total:  ₪{total_deductible:,.2f}", file=sys.stderr)
    if output_file:
        print(f"  Output file:           {output_file}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Export Israeli bank transactions as tax-year CSV")
    parser.add_argument("--input", help="JSON file from get_transactions (default: stdin)")
    parser.add_argument("--stdin", action="store_true", help="Read JSON from stdin")
    parser.add_argument("--year", type=int, default=datetime.now().year,
                        help="Tax year to export (default: current year)")
    parser.add_argument("--output", help="Output CSV file (default: stdout)")
    args = parser.parse_args()

    if args.input:
        with open(args.input, encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = json.load(sys.stdin)

    # Handle both raw array and wrapped response from MCP
    if isinstance(data, list):
        transactions = data
    elif isinstance(data, dict):
        # MCP response wraps transactions in content[0].text as JSON string
        content = data.get("content", [{}])
        text = content[0].get("text", "{}") if content else "{}"
        inner = json.loads(text)
        transactions = inner.get("transactions", inner) if isinstance(inner, dict) else inner
    else:
        print("Error: unexpected input format", file=sys.stderr)
        sys.exit(1)

    export_transactions(transactions, args.year, args.output)


if __name__ == "__main__":
    main()
