#!/usr/bin/env bash
set -euo pipefail

RPC_URL="https://host-rpc.pecorino.signet.sh"
LOW_NONCE=55066
HIGH_NONCE=62840
VALUE="1gwei"
WALLET_CMD="cast wallet address --aws"
BLOB_PATH="/Users/swanpro/git/swan-scripts/blob.json"
DELAY=1
GAS_LIMIT=200000   # adjust to your blob+calldata needs
BUMP_PCT=120       # +20% bump
TIP=1000000000     # 1 gwei

# fetch on‐chain fees
BASE_FEE_DEC=$(( $(cast block latest --rpc-url "$RPC_URL" --json | jq -r '.baseFeePerGas') ))
# BLOB_BASE_FEE_DEC=$(( $(cast block latest --rpc-url "$RPC_URL" --json | jq -r '.blobBaseFeePerGas') ))

# compute bumped values
BUMPED_MAX_FEE=$(( (BASE_FEE_DEC * BUMP_PCT / 100) + TIP ))
BUMPED_BLOB_GAS_PRICE=1000000000

echo "Using maxFeePerGas    = ${BUMPED_MAX_FEE} wei"
echo "      blob-gas-price  = ${BUMPED_BLOB_GAS_PRICE} wei"

send_blob_tx() {
  local nonce=$1
  echo "► nonce=$nonce  maxFee=${BUMPED_MAX_FEE}  blobTip=${BUMPED_BLOB_GAS_PRICE}"
  cast send \
    --rpc-url "$RPC_URL" \
    --value "$VALUE" \
    --aws "$($WALLET_CMD)" \
    --nonce "$nonce" \
    --gas-limit "$GAS_LIMIT" \
    --gas-price "$BUMPED_MAX_FEE" \
    --priority-gas-price "$TIP" \
    --blob \
    --blob-gas-price "$BUMPED_BLOB_GAS_PRICE" \
    --path "$BLOB_PATH" \
}

for (( n=LOW_NONCE; n<=HIGH_NONCE; n++ )); do
  if send_blob_tx "$n"; then
    echo "  ✓ nonce $n"
  else
    echo "  ✗ nonce $n"
  fi
  sleep "$DELAY"
done

echo "✅ Done nonces $LOW_NONCE–$HIGH_NONCE"
