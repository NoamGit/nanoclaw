# Israeli Spending Categories

Reference for categorizing transactions in Israeli bank and credit card data.
Use this when the MCP returns an unfamiliar merchant name or when the user asks about a specific spending type.

## Categories and Hebrew Terms

### 🏠 Housing (דיור / Diur)
Fixed and variable costs related to home.

| Type | Hebrew | Examples |
|------|--------|---------|
| Rent | שכר דירה | Direct bank transfer to landlord |
| Municipal tax | ארנונה | עיריית תל אביב, עיריית חיפה |
| Building committee | ועד בית | ועד הבית |
| Mortgage | משכנתא | בנק לאומי משכנתאות, בנק הפועלים |
| Home insurance | ביטוח דירה | הפניקס, מגדל, כלל |
| Maintenance / repairs | תחזוקה | שיפוצניק, אינסטלטור |
| Electricity | חשמל | חברת החשמל (IEC) |
| Water | מים | מקורות, תאגיד המים |

**VAT deductibility:** Arnona is 0% deductible for individuals. Home office portion of utilities may be partially deductible for self-employed.

---

### 🛒 Groceries (מזון / Mazon)
Supermarkets and food stores.

| Chain | Hebrew | Notes |
|-------|--------|-------|
| Shufersal | שופרסל | Largest chain, also Shufersal Deal |
| Rami Levy | רמי לוי | Discount, also online |
| Victory | ויקטורי | Independent (Ravid family, VCTR.TA) |
| Yochananof | יוחננוף | Central Israel |
| Osher Ad | אושר עד | Large-format discount |
| Tiv Taam | טיב טעם | Non-kosher available |
| Carrefour / Mega | קרפור / מגה | Formerly Yeinot Bitan |
| AM:PM | AM:PM | Convenience stores |
| Machsanei Hashuk | מחסני השוק | |

---

### 🚗 Transportation (תחבורה / Tahaburah)

| Type | Hebrew | Examples |
|------|--------|---------|
| Public transport | תחבורה ציבורית | רב-קו (Rav-Kav), Moovit top-up |
| Fuel | דלק | סונול (Sonol), פז (Paz), דלק (Delek), Ten |
| Ride-hailing | נסיעות | Gett, Yango, inDrive |
| Parking | חניה | פנגו (Pango), קל פארק (Kal Park) |
| Car insurance | ביטוח רכב | מגדל, הראל, שלמה |
| Car maintenance | טיפול רכב | מוסך, טסט |
| Train | רכבת | רכבת ישראל |

**VAT deductibility:** 2/3 of vehicle fuel and maintenance is deductible for self-employed with a business vehicle.

---

### 📱 Utilities & Communications (שירותים / Sharutim)

| Type | Hebrew | Providers |
|------|--------|----------|
| Mobile | סלולר | Cellcom, Partner, Pelephone, HOT Mobile, Golan, 012, Rami Levy Mobile |
| Internet | אינטרנט | Bezeq, HOT, Partner, Cellcom |
| TV | טלויזיה | HOT, Yes, Cellcom TV |
| Gas | גז | סופרגז, Supergas, פזגז |

---

### 🍽️ Restaurants & Dining (מסעדות / Mis'adot)

| Type | Hebrew | Examples |
|------|--------|---------|
| Restaurants | מסעדות | Any sit-down restaurant |
| Fast food | מזון מהיר | McDonald's, Burger King, KFC, Dominos |
| Cafés | בתי קפה | Aroma, Café Joe, Benedict |
| Food delivery | משלוחים | Wolt, 10bis, Mishloha |
| Work lunches | צהריים בעבודה | |

**VAT deductibility:** 50% deductible as a business meal expense (with receipt). Wolt and 10bis for business purposes: 50% deductible.

---

### 🏥 Healthcare (בריאות / Briut)

| Type | Hebrew | Providers |
|------|--------|---------|
| Health fund | קופת חולים | Clalit (כללית), Maccabi (מכבי), Meuhedet (מאוחדת), Leumit (לאומית) |
| Pharmacy | בית מרקחת | Super-Pharm, New-Pharm, Superpharm |
| Dental | שיניים | Private clinics |
| Supplemental insurance | ביטוח משלים | Hamakor (הפועלים), Dikla (כלל), Maccabi Extra |

---

### 🎓 Education (חינוך / Chinuch)

| Type | Hebrew | Notes |
|------|--------|-------|
| Kindergarten | גן ילדים | Municipal or private |
| School fees | אגרות בית ספר | |
| After-school | צהרון, חוגים | |
| University | אוניברסיטה | Tuition payments |
| Online courses | קורסים | Udemy, Coursera, local providers |

---

### 🎬 Entertainment (בילוי / Bilui)

| Type | Hebrew | Examples |
|------|--------|---------|
| Streaming | סטרימינג | Netflix, Disney+, Apple TV+, Spotify, YouTube Premium |
| Cinema | קולנוע | Yes Planet, Cinema City |
| Sports | ספורט | Gym memberships (Holmes Place, Fit4Life) |
| Events | אירועים | Tickets, concerts |
| Books / games | ספרים / משחקים | Steimatzky, Steam, App Store |

---

### 🛡️ Insurance (ביטוח / Bituach)
(beyond what appears in Housing and Transportation)

| Type | Hebrew | Providers |
|------|--------|---------|
| Life insurance | ביטוח חיים | Harel, Phoenix, Clal, Migdal |
| Travel insurance | ביטוח נסיעות | Harel, AIG |
| Critical illness | ביטוח מחלות קשות | |

---

### 💰 Savings & Financial (חיסכון / Chisachon)

These usually appear as outgoing transfers, not credit card charges:

| Type | Hebrew | Notes |
|------|--------|-------|
| Pension | קרן פנסיה | Employer deduction — usually not in transaction data |
| Keren Hishtalmut | קרן השתלמות | Savings fund for self-employed or employees |
| Investment deposit | פיקדון | Bank fixed-term deposit |
| Kupat Gemel | קופת גמל | |

**Note:** These typically appear as bank account outgoing transfers, not as MCP-visible transactions unless you have Leumi checking account data.

---

## Merchant Name Quirks in Israeli Banking

- **Bank abbreviations**: "בנק לאומי" may appear as "לאומי", "LEUMI", or "L.U.M.I" in transaction descriptions.
- **Credit card company names**: Isracard charges appear under the card type (VISA, Mastercard) + last 4 digits, not "Isracard".
- **Standing orders (הוראות קבע)**: Fixed monthly charges (arnona, insurance, subscriptions) appear with the vendor's banking code, not always their brand name.
- **ATM withdrawals**: Appear as "משיכה" or "ATM" — uncategorizable, treat as cash spending.
- **International charges**: May appear in original currency with conversion rate embedded in the description.
- **Tax authority (מס הכנסה)**: Appears as "שלטונות מס הכנסה" or "מס הכנסה" — periodic advance payments for self-employed.
