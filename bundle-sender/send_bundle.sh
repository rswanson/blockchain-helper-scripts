#!/bin/bash
set -euo pipefail

# Flashbots Bundle Sender using Foundry's cast
# Uses cast for signing and RPC calls

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env file if it exists
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Configuration
BUILDER_URL="${BUILDER_URL:-https://host-builder-rpc.parmigiana.signet.sh}"
RPC_URL="${RPC_URL:-https://host-rpc.parmigiana.signet.sh}"
SIGNED_TX="${SIGNED_TX:-}"                           # Signed transaction(s) (optional, will generate if not provided)
VALUE="${VALUE:-1gwei}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_PROFILE="${AWS_PROFILE:-init4-dev-poweruser}"
export AWS_KMS_KEY_ID="${AWS_KMS_KEY_ID:-arn:aws:kms:us-east-1:637423570300:alias/pecorino-poa-bank}"

# Temporary private key for transaction creation (loaded from .env)
TEMP_PRIVATE_KEY="${TEMP_PRIVATE_KEY:-}"
# Derive address from private key if provided
if [[ -n "$TEMP_PRIVATE_KEY" ]]; then
    TEMP_ADDRESS=$(cast wallet address --private-key "$TEMP_PRIVATE_KEY" 2>/dev/null || echo "")
else
    TEMP_ADDRESS=""
fi

usage() {
    cat <<EOF
Usage: $0 [options]

Send a Flashbots bundle using cast.

Options:
    -u, --url URL           Builder URL (default: https://host-builder-rpc.parmigiana.signet.sh)
    -r, --rpc-url URL       RPC URL for getting latest block (default: https://host-rpc.pecorino.signet.sh)
    -t, --tx TX             Signed transaction (can be repeated for multiple txs, optional)
    -v, --value VALUE       Value for generated transaction (default: 1gwei)
    -h, --help              Show this help message

Note: Uses AWS for signing (via cast --aws)
      Submits bundle for blocks latest+2 through latest+5 (4 blocks ahead)
      If no transactions provided, generates one sending VALUE to yourself
      Requires TEMP_PRIVATE_KEY in .env file for transaction generation

Example:
    $0 -u http://localhost:8545
    $0 -u http://localhost:8545 -t 0x02f8...
    $0 -u http://localhost:8545 -v 2gwei
EOF
    exit 0
}

TXS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--url)
            BUILDER_URL="$2"
            shift 2
            ;;
        -r|--rpc-url)
            RPC_URL="$2"
            shift 2
            ;;
        -t|--tx)
            TXS+=("$2")
            shift 2
            ;;
        -v|--value)
            VALUE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Use SIGNED_TX env var if no -t flags provided
if [[ ${#TXS[@]} -eq 0 && -n "$SIGNED_TX" ]]; then
    TXS+=("$SIGNED_TX")
fi

# Get the signing address
SIGNING_ADDRESS=$(cast wallet address --aws)
echo "Signing address: $SIGNING_ADDRESS"

# Generate transaction if none provided
if [[ ${#TXS[@]} -eq 0 ]]; then
    # Check if private key is configured
    if [[ -z "$TEMP_PRIVATE_KEY" ]] || [[ -z "$TEMP_ADDRESS" ]]; then
        echo "Error: TEMP_PRIVATE_KEY not configured in .env file"
        echo "Please add TEMP_PRIVATE_KEY to $SCRIPT_DIR/.env"
        exit 1
    fi

    echo "No transactions provided, generating one sending $VALUE to $SIGNING_ADDRESS..."

    # Test RPC connectivity first
    echo "Testing RPC connectivity to $RPC_URL..."
    RPC_TEST=$(cast block latest --rpc-url "$RPC_URL" --json 2>&1)
    RPC_TEST_EXIT=$?
    if [[ $RPC_TEST_EXIT -ne 0 ]]; then
        echo "Error: Cannot connect to RPC endpoint: $RPC_URL"
        echo "RPC test output: $RPC_TEST"
        echo ""
        
        # Check for specific error types
        if echo "$RPC_TEST" | grep -q "503"; then
            echo "⚠️  HTTP 503 Service Unavailable detected"
            echo "This usually means:"
            echo "  - The service is overloaded or rate-limited"
            echo "  - The service is starting up and not ready yet"
            echo "  - Health checks are failing"
            echo "  - All backend pods are unavailable"
            echo ""
            echo "Kubernetes debugging commands:"
            echo "  kubectl get pods -n parmigiana | grep rpc"
            echo "  kubectl get svc -n parmigiana | grep rpc"
            echo "  kubectl describe svc -n parmigiana <rpc-service-name>"
            echo "  kubectl get endpoints -n parmigiana <rpc-service-name>"
            echo "  kubectl logs -n parmigiana -l app=<rpc-service-name> --tail=50"
        elif echo "$RPC_TEST" | grep -q "dns error\|nodename\|NXDOMAIN"; then
            echo "⚠️  DNS resolution error detected"
            echo "The hostname cannot be resolved. Check DNS configuration."
        elif echo "$RPC_TEST" | grep -q "Connect\|connection"; then
            echo "⚠️  Connection error detected"
            echo "Cannot establish connection to the RPC endpoint."
        fi
        
        echo ""
        echo "General troubleshooting:"
        echo "  1. Check if the RPC service is running: kubectl get pods -n parmigiana | grep rpc"
        echo "  2. Check service status: kubectl get svc -n parmigiana | grep rpc"
        echo "  3. Check pod logs: kubectl logs -n parmigiana -l app=<rpc-service-name>"
        echo "  4. Test with curl: curl -X POST -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}' $RPC_URL"
        exit 1
    fi
    echo "✓ RPC endpoint is reachable"
    
    # Get the latest block to estimate gas prices
    echo "Fetching latest block information..."
    LATEST_BLOCK_JSON=$(cast block latest --rpc-url "$RPC_URL" --json 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error fetching latest block: $LATEST_BLOCK_JSON"
        exit 1
    fi
    
    # Generate the signed transaction
    # Since cast doesn't support creating transactions without sending,
    # we need the RPC to be available to get nonce, gas, etc.
    echo "Generating signed transaction..."
    
    # Get transaction parameters needed to build the transaction
    echo "Fetching transaction parameters..."
    NONCE=$(cast nonce "$SIGNING_ADDRESS" --rpc-url "$RPC_URL" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error getting nonce: $NONCE"
        if echo "$NONCE" | grep -q "503"; then
            echo ""
            echo "⚠️  RPC is returning 503 errors. Cannot generate transaction."
            echo "Please either:"
            echo "  1. Fix the RPC service (check Kubernetes pods/services)"
            echo "  2. Provide a pre-signed transaction using: -t <transaction_hex>"
            exit 1
        fi
        exit 1
    fi
    
    CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error getting chain ID: $CHAIN_ID"
        exit 1
    fi
    
    # Get base fee for EIP-1559 transaction
    BASE_FEE=$(echo "$LATEST_BLOCK_JSON" | jq -r '.baseFeePerGas' | xargs printf "%d")
    if [[ -z "$BASE_FEE" ]] || [[ "$BASE_FEE" == "null" ]]; then
        echo "Error: Could not get base fee from block"
        exit 1
    fi
    
    # Set priority fee (tip to validators) - use 2 gwei for better inclusion
    PRIORITY_FEE="${PRIORITY_FEE:-2000000000}"  # 2 gwei in wei
    
    # Calculate max fee per gas (base fee * 2 + priority fee for safety)
    MAX_FEE=$((BASE_FEE * 2 + PRIORITY_FEE))
    
    # Convert to gwei for cast mktx (which accepts unit strings)
    PRIORITY_FEE_GWEI=$((PRIORITY_FEE / 1000000000))
    MAX_FEE_GWEI=$((MAX_FEE / 1000000000))
    
    echo "Gas pricing:"
    echo "  Base fee: $BASE_FEE wei"
    echo "  Priority fee: $PRIORITY_FEE wei (${PRIORITY_FEE_GWEI} gwei)"
    echo "  Max fee per gas: $MAX_FEE wei (${MAX_FEE_GWEI} gwei)"
    
    # Use the temporary private key for transaction creation
    echo ""
    echo "Using temporary address: $TEMP_ADDRESS"

    # Check balance
    echo "Checking balance..."
    BALANCE=$(cast balance "$TEMP_ADDRESS" --rpc-url "$RPC_URL" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error checking balance: $BALANCE"
        exit 1
    fi
    
    BALANCE_WEI=$(cast --to-wei "$BALANCE" wei 2>/dev/null || echo "$BALANCE")
    if [[ "$BALANCE_WEI" == "0" ]] || [[ -z "$BALANCE_WEI" ]]; then
        echo "⚠️  Warning: Balance appears to be zero"
        echo "Balance: $BALANCE"
        echo "Ensure the address is funded before running this script."
        exit 1
    else
        echo "✓ Balance: $BALANCE"
    fi
    
    # Get nonce for the temporary address
    echo "Getting nonce for temporary address..."
    TEMP_NONCE=$(cast nonce "$TEMP_ADDRESS" --rpc-url "$RPC_URL" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error getting nonce for temporary address: $TEMP_NONCE"
        exit 1
    fi
    
    # Create and sign the transaction using the temporary key
    # Use EIP-1559 format with proper gas pricing for better inclusion
    # Note: cast mktx uses --gas-price for max fee per gas in EIP-1559 transactions
    # and accepts decimal values or unit strings (e.g., "2gwei")
    echo "Creating signed transaction (EIP-1559)..."
    GENERATED_TX=$(cast mktx \
        "$TEMP_ADDRESS" \
        --rpc-url "$RPC_URL" \
        --value "$VALUE" \
        --nonce "$TEMP_NONCE" \
        --gas-price "${MAX_FEE_GWEI}gwei" \
        --priority-gas-price "${PRIORITY_FEE_GWEI}gwei" \
        --chain-id "$CHAIN_ID" \
        --private-key "$TEMP_PRIVATE_KEY" 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo "Error creating transaction: $GENERATED_TX"
        echo ""
        echo "Note: If --create-only is not supported, the transaction may have been sent."
        echo "Check the network for transaction hash."
        exit 1
    fi
    
    # Extract the raw transaction hex
    GENERATED_TX=$(echo "$GENERATED_TX" | grep -oE '0x[0-9a-fA-F]+' | head -1)
    
    if [[ -z "$GENERATED_TX" ]]; then
        echo "Error: Could not extract transaction from output"
        echo "Raw output: $GENERATED_TX"
        exit 1
    fi
    
    # Extract the raw transaction hex from cast mktx output
    # cast mktx outputs the raw signed transaction hex
    GENERATED_TX=$(echo "$GENERATED_TX" | grep -oE '0x[0-9a-fA-F]+' | head -1)
    
    if [[ -z "$GENERATED_TX" ]]; then
        echo "Error: Could not extract transaction from cast mktx output"
        echo "Raw output: $GENERATED_TX"
        echo ""
        echo "Troubleshooting:"
        echo "  - RPC URL: $RPC_URL"
        echo "  - Check if the RPC service is healthy"
        exit 1
    fi
    
    TXS+=("$GENERATED_TX")
    echo "✓ Transaction created: ${GENERATED_TX:0:66}..."
    echo ""
    echo "The transaction is signed and ready for bundling."
fi

# Build JSON array of transactions
TX_JSON="["
for i in "${!TXS[@]}"; do
    if [[ $i -gt 0 ]]; then
        TX_JSON+=","
    fi
    TX_JSON+="\"${TXS[$i]}\""
done
TX_JSON+="]"

# Bundle targeting configuration
# We target the next few blocks for inclusion
# latest+1 is the immediate next block, latest+2 provides a backup
BLOCK_OFFSET_START=1  # Start at latest + 1 (next block)
BLOCK_OFFSET_END=2    # End at latest + 2 (backup block)
NUM_BLOCKS=$((BLOCK_OFFSET_END - BLOCK_OFFSET_START + 1))

# Refetch the latest block number right before submission to minimize timing drift
# This is critical because transaction generation can take several seconds
echo ""
echo "Fetching latest block number from $RPC_URL..."
LATEST_BLOCK_DEC=$(cast block-number --rpc-url "$RPC_URL")
LATEST_BLOCK_HEX=$(printf "0x%x" "$LATEST_BLOCK_DEC")

# Calculate target block range
FIRST_TARGET=$((LATEST_BLOCK_DEC + BLOCK_OFFSET_START))
LAST_TARGET=$((LATEST_BLOCK_DEC + BLOCK_OFFSET_END))

echo "Builder URL: $BUILDER_URL"
echo "RPC URL: $RPC_URL"
echo "Latest block: $LATEST_BLOCK_HEX ($LATEST_BLOCK_DEC)"
echo "Transactions: ${#TXS[@]}"
echo "Targeting blocks: $(printf "0x%x" $FIRST_TARGET) ($FIRST_TARGET) through $(printf "0x%x" $LAST_TARGET) ($LAST_TARGET)"
echo "  (${NUM_BLOCKS} blocks, ~$((NUM_BLOCKS * 12)) seconds coverage)"
echo ""

# Submit bundle for multiple future blocks to increase chances of inclusion
# Starting from latest+2 ensures the builder has time to receive and process the bundle
for i in $(seq $BLOCK_OFFSET_START $BLOCK_OFFSET_END); do
    TARGET_BLOCK_DEC=$((LATEST_BLOCK_DEC + i))
    TARGET_BLOCK_HEX=$(printf "0x%x" "$TARGET_BLOCK_DEC")

    echo "=== Block $TARGET_BLOCK_HEX ($TARGET_BLOCK_DEC) [latest+$i] ==="

    # Build the JSON-RPC request body for this block
    REQUEST_BODY=$(cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"eth_sendBundle","params":[{"txs":$TX_JSON,"blockNumber":"$TARGET_BLOCK_HEX"}]}
EOF
    )

    # Hash the request body (keccak256)
    BODY_HASH=$(cast keccak "$REQUEST_BODY")

    # Sign the hash (Flashbots expects the hash to be signed, not the message)
    SIGNATURE=$(cast wallet sign --aws "$BODY_HASH" --no-hash)

    # Build the X-Flashbots-Signature header
    FLASHBOTS_HEADER="$SIGNING_ADDRESS:$SIGNATURE"

    # Send the request
    RESPONSE=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "X-Flashbots-Signature: $FLASHBOTS_HEADER" \
        -d "$REQUEST_BODY" \
        "$BUILDER_URL")

    echo "Response:"
    echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
    echo ""
done

echo "✅ Submitted bundle for $NUM_BLOCKS blocks (latest+$BLOCK_OFFSET_START through latest+$BLOCK_OFFSET_END)"
