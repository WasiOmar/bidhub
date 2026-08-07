#!/usr/bin/env bash
set -uo pipefail
BASE_URL="${BASE_URL:-http://localhost:4000/api}"
FAIL=0
json_get() {
    local json="$1" key="$2"
    echo "$json" | grep -oP "(?<=\"${key}\":)\s*\"?[^\",}]*\"?" | head -1 | tr -d '"' | xargs
}
check() {
    local label="$1" condition="$2"
    if [ "$condition" = "1" ]; then
        echo "PASS  $label"
    else
        echo "FAIL  $label"
        FAIL=1
    fi
}
STAMP=$(date +%s)
SELLER_JSON=$(curl -s -X POST "$BASE_URL/auth/register" -H 'Content-Type: application/json' \
    -d "{\"full_name\":\"Test Seller\",\"email\":\"seller-${STAMP}@bidhub.local\",\"password\":\"password123\",\"role\":\"SELLER\"}")
SELLER_TOKEN=$(json_get "$SELLER_JSON" token)
BIDDER_A_JSON=$(curl -s -X POST "$BASE_URL/auth/register" -H 'Content-Type: application/json' \
    -d "{\"full_name\":\"Bidder A\",\"email\":\"bidder-a-${STAMP}@bidhub.local\",\"password\":\"password123\",\"role\":\"BUYER\"}")
BIDDER_A_TOKEN=$(json_get "$BIDDER_A_JSON" token)
BIDDER_B_JSON=$(curl -s -X POST "$BASE_URL/auth/register" -H 'Content-Type: application/json' \
    -d "{\"full_name\":\"Bidder B\",\"email\":\"bidder-b-${STAMP}@bidhub.local\",\"password\":\"password123\",\"role\":\"BUYER\"}")
BIDDER_B_TOKEN=$(json_get "$BIDDER_B_JSON" token)
check "register (seller + 2 bidders)" \
    "$([ -n "$SELLER_TOKEN" ] && [ -n "$BIDDER_A_TOKEN" ] && [ -n "$BIDDER_B_TOKEN" ] && echo 1 || echo 0)"
CATEGORY_ID=$(curl -s "$BASE_URL/categories/tree" | grep -oP '(?<="category_id":)[0-9]+' | head -1)
if [ -z "$CATEGORY_ID" ]; then
    echo "FAIL  no category found via GET /api/categories/tree -- seed at least one category first"
    exit 1
fi
ITEM_JSON=$(curl -s -X POST "$BASE_URL/items" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $SELLER_TOKEN" \
    -d "{\"category_id\":${CATEGORY_ID},\"title\":\"API Test Item ${STAMP}\",\"condition\":\"USED\"}")
ITEM_ID=$(json_get "$ITEM_JSON" item_id)
check "create item" "$([ -n "$ITEM_ID" ] && echo 1 || echo 0)"
END_TIME=$(node -e "console.log(new Date(Date.now()+3600000).toISOString())" 2>/dev/null \
    || date -u -d '+1 hour' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ")
AUCTION_JSON=$(curl -s -X POST "$BASE_URL/auctions" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $SELLER_TOKEN" \
    -d "{\"item_id\":${ITEM_ID},\"starting_price\":100.00,\"bid_increment\":10.00,\"end_time\":\"${END_TIME}\"}")
AUCTION_ID=$(json_get "$AUCTION_JSON" auction_id)
check "create auction" "$([ -n "$AUCTION_ID" ] && echo 1 || echo 0)"
BID_A_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/auctions/${AUCTION_ID}/bids" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $BIDDER_A_TOKEN" \
    -d '{"amount": 100.00}')
check "Bidder A places opening bid (100.00)" "$([ "$BID_A_STATUS" = "201" ] && echo 1 || echo 0)"
BID_B_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/auctions/${AUCTION_ID}/bids" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $BIDDER_B_TOKEN" \
    -d '{"amount": 110.00}')
check "Bidder B outbids at 110.00" "$([ "$BID_B_STATUS" = "201" ] && echo 1 || echo 0)"
LEADERBOARD_JSON=$(curl -s "$BASE_URL/auctions/${AUCTION_ID}/leaderboard")
TOP_AMOUNT=$(echo "$LEADERBOARD_JSON" | grep -oP '(?<="amount":)"?[0-9.]+' | head -1 | tr -d '"')
check "leaderboard row 1 is the current high bid (110.00)" "$([ "$TOP_AMOUNT" = "110.00" ] && echo 1 || echo 0)"
NOTIF_JSON=$(curl -s "$BASE_URL/notifications" -H "Authorization: Bearer $BIDDER_A_TOKEN")
HAS_OUTBID=$(echo "$NOTIF_JSON" | grep -c '"type":"OUTBID"')
check "Bidder A has an OUTBID notification (written by trg_outbid, not this API)" "$([ "$HAS_OUTBID" -ge 1 ] && echo 1 || echo 0)"
UNDERBID_JSON=$(curl -s -w '\n%{http_code}' -X POST "$BASE_URL/auctions/${AUCTION_ID}/bids" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $BIDDER_A_TOKEN" \
    -d '{"amount": 111.00}')
UNDERBID_STATUS=$(echo "$UNDERBID_JSON" | tail -1)
UNDERBID_BODY=$(echo "$UNDERBID_JSON" | sed '$d')
UNDERBID_CODE=$(json_get "$UNDERBID_BODY" code)
check "underbid rejected with 400 AU001" "$([ "$UNDERBID_STATUS" = "400" ] && [ "$UNDERBID_CODE" = "AU001" ] && echo 1 || echo 0)"
SELFBID_JSON=$(curl -s -w '\n%{http_code}' -X POST "$BASE_URL/auctions/${AUCTION_ID}/bids" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $SELLER_TOKEN" \
    -d '{"amount": 200.00}')
SELFBID_STATUS=$(echo "$SELFBID_JSON" | tail -1)
SELFBID_BODY=$(echo "$SELFBID_JSON" | sed '$d')
SELFBID_CODE=$(json_get "$SELFBID_BODY" code)
check "self-bid rejected with 403 AU003" "$([ "$SELFBID_STATUS" = "403" ] && [ "$SELFBID_CODE" = "AU003" ] && echo 1 || echo 0)"
echo "---"
if [ "$FAIL" -eq 0 ]; then
    echo "test-api.sh: PASS"
else
    echo "test-api.sh: FAIL"
    exit 1
fi
