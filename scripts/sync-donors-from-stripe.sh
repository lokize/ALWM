#!/usr/bin/env bash
# Sync About → Donors list from Stripe Checkout sessions for the ALWM donate payment link.
# Requires: stripe CLI authenticated to the live IAtoTec account.
#
# Usage:
#   bash scripts/sync-donors-from-stripe.sh
#   STRIPE_PAYMENT_LINK=plink_xxx bash scripts/sync-donors-from-stripe.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Sources/Alwm/Resources/donors.json"
PAYMENT_LINK="${STRIPE_PAYMENT_LINK:-plink_1UBvk5Gal1e5K5Xo0WxWvwex}"

if ! command -v stripe >/dev/null 2>&1; then
  echo "error: stripe CLI not found — https://stripe.com/docs/stripe-cli" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 required" >&2
  exit 1
fi

echo "→ Listing completed Checkout Sessions for $PAYMENT_LINK"
TMP="$(mktemp)"
# Paginate until empty — Stripe CLI returns JSON list pages.
starting_after=""
: >"$TMP.raw"
while true; do
  args=(checkout sessions list --limit 100 --payment-link="$PAYMENT_LINK" --status=complete)
  if [[ -n "$starting_after" ]]; then
    args+=(--starting-after="$starting_after")
  fi
  page="$(stripe "${args[@]}" 2>/dev/null || true)"
  if [[ -z "$page" ]]; then
    break
  fi
  echo "$page" >>"$TMP.raw"
  count="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('data',[])))" <<<"$page" 2>/dev/null || echo 0)"
  has_more="$(python3 -c "import json,sys; d=json.load(sys.stdin); print('1' if d.get('has_more') else '0')" <<<"$page" 2>/dev/null || echo 0)"
  if [[ "$count" == "0" ]]; then
    break
  fi
  starting_after="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data'][-1]['id'] if d.get('data') else '')" <<<"$page")"
  if [[ "$has_more" != "1" || -z "$starting_after" ]]; then
    break
  fi
done

python3 - "$TMP.raw" "$OUT" <<'PY'
import json, sys, hashlib
from pathlib import Path

raw_path, out_path = sys.argv[1], sys.argv[2]
chunks = Path(raw_path).read_text().strip()
sessions = []
# File may contain multiple JSON objects concatenated
decoder = json.JSONDecoder()
idx = 0
text = chunks
while idx < len(text):
    while idx < len(text) and text[idx].isspace():
        idx += 1
    if idx >= len(text):
        break
    obj, end = decoder.raw_decode(text, idx)
    idx = end
    sessions.extend(obj.get("data") or [])

seen = set()
donors = []
for s in sessions:
    if s.get("payment_status") != "paid" and s.get("status") != "complete":
        continue
    details = s.get("customer_details") or {}
    name = (details.get("name") or details.get("individual_name") or "").strip()
    if not name:
        # Never publish emails in the About UI.
        continue
    # Stable id without PII beyond the public display name.
    sid = s.get("id") or name
    did = "cs:" + hashlib.sha1(sid.encode()).hexdigest()[:12]
    if did in seen:
        continue
    seen.add(did)
    amount = s.get("amount_total")
    currency = (s.get("currency") or "").upper()
    note = None
    if isinstance(amount, int) and currency:
        major = amount / 100.0 if currency not in {"JPY", "KRW"} else float(amount)
        note = f"{currency} {major:g}"
    donors.append({"id": did, "name": name, "note": note})

donors.sort(key=lambda d: d["name"].lower())
Path(out_path).write_text(json.dumps({"donors": donors}, indent=2, ensure_ascii=False) + "\n")
print(f"Wrote {len(donors)} donor(s) → {out_path}")
PY

rm -f "$TMP" "$TMP.raw"
echo "Done. Commit Sources/Alwm/Resources/donors.json so About can show them."
