#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DRY_RUN=false
AMOUNT="0.01"
RPC_URL="${RPC_URL:-https://host-rpc.pecorino.signet.sh}"
DELAY_SECONDS=1
GAS_PRICE=""
PRIORITY_FEE=""
CONFIRMATIONS=1

# Create logs directory if it doesn't exist
mkdir -p logs

LOG_FILE="logs/funding_log_$(date +%Y%m%d_%H%M%S).txt"
FAILED_FILE="logs/failed_addresses_$(date +%Y%m%d_%H%M%S).txt"

# Counters
SUCCESS_COUNT=0
FAILED_COUNT=0
TOTAL_ETH_SENT=0

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] <addresses_file>

Fund multiple Ethereum addresses from a newline-delimited file using AWS KMS.

OPTIONS:
    -a, --amount <amount>      Amount of ETH to send to each address (default: 0.01)
    -r, --rpc <url>           RPC endpoint URL (default: \$RPC_URL or http://localhost:8545)
    -d, --delay <seconds>     Delay between transactions in seconds (default: 1)
    -g, --gas-price <gwei>    Gas price in gwei (optional, uses network default if not set)
    -p, --priority-fee <gwei> Priority fee in gwei for EIP-1559 (optional)
    -c, --confirmations <num> Number of confirmations to wait for (default: 1)
    -n, --dry-run            Perform a dry run without sending transactions
    -h, --help               Display this help message

EXAMPLES:
    # Fund wallets with 0.1 ETH each
    $0 --amount 0.1 addresses.txt

    # Dry run to preview transactions
    $0 --dry-run --amount 0.05 addresses.txt

    # Use specific RPC and gas settings
    $0 --rpc https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY --gas-price 30 addresses.txt

    # Fund with custom delay between transactions
    $0 --amount 0.05 --delay 3 addresses.txt

NOTE: This script uses AWS KMS for key management. Ensure your AWS credentials
      are properly configured and you have access to the KMS key.
EOF
    exit 0
}

# Function to log messages
log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" | tee -a "$LOG_FILE" >&2
}

# Function to log errors
log_error() {
    local message="$1"
    echo -e "${RED}[ERROR] $message${NC}" | tee -a "$LOG_FILE" >&2
}

# Function to log success
log_success() {
    local message="$1"
    echo -e "${GREEN}[SUCCESS] $message${NC}" | tee -a "$LOG_FILE" >&2
}

# Function to log info
log_info() {
    local message="$1"
    echo -e "${BLUE}[INFO] $message${NC}" | tee -a "$LOG_FILE" >&2
}

# Function to validate ethereum address
validate_address() {
    local address="$1"
    if [[ ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        return 1
    fi
    return 0
}

# Function to get sender address from AWS KMS
get_sender_address() {
    log_info "Getting sender address from AWS KMS..."
    
    # Ensure AWS environment variables are available
    export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
    export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}"
    export AWS_REGION="${AWS_REGION}"
    export AWS_KMS_KEY_ID="${AWS_KMS_KEY_ID}"
    
    # Get address with error output for debugging
    local sender_output=$(env | grep -E '^AWS_' | wc -l)
    log_info "Number of AWS environment variables: $sender_output"
    
    sender_output=$(cast wallet address --aws 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "Failed to get address from AWS KMS: $sender_output"
        log_error "Please check your AWS configuration and ensure KMS key is accessible."
        
        # Try with explicit env vars passed to cast
        log_info "Retrying with explicit environment..."
        sender_output=$(env AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
                           AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
                           AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" \
                           AWS_REGION="$AWS_REGION" \
                           AWS_KMS_KEY_ID="$AWS_KMS_KEY_ID" \
                           cast wallet address --aws 2>&1)
        exit_code=$?
        
        if [ $exit_code -ne 0 ]; then
            log_error "Still failed with explicit env: $sender_output"
            return 1
        fi
    fi
    
    # Extract the address (should be a 42-character hex string starting with 0x)
    local sender_address=$(echo "$sender_output" | grep -oE '0x[a-fA-F0-9]{40}' | head -1)
    
    if [ -z "$sender_address" ]; then
        log_error "Could not parse address from output: $sender_output"
        return 1
    fi
    
    log_info "Found sender address: $sender_address"
    echo "$sender_address"
    return 0
}

# Function to check sender balance
check_balance() {
    local sender_address="$1"
    local total_needed="$2"
    
    log_info "Checking sender balance for address: $sender_address"
    
    # Get balance with proper error handling
    log_info "Cast Commmand: cast balance $sender_address --rpc-url $RPC_URL"
    local balance_output=$(cast balance "$sender_address" --rpc-url "$RPC_URL" 2>&1)
    log_info "Balance output: $balance_output"
    local balance_exit_code=$?
    
    if [ $balance_exit_code -ne 0 ]; then
        log_error "Failed to get balance: $balance_output"
        return 1
    fi
    
    # Extract the numeric value from balance output
    local balance_wei=$(echo "$balance_output" | grep -oE '[0-9]+' | head -1)
    
    if [ -z "$balance_wei" ]; then
        log_error "Could not parse balance from output: $balance_output"
        return 1
    fi
    
    local balance_eth=$(cast --from-wei "$balance_wei" 2>/dev/null || echo "0")
    
    log_info "Sender balance: $balance_eth ETH (raw: $balance_wei wei)"
    log_info "Total needed: $total_needed ETH (plus gas)"
    
    # Convert to wei for comparison - ensure we handle large numbers properly
    local needed_wei=$(cast --to-wei "$total_needed" 2>&1)
    local needed_exit_code=$?
    
    if [ $needed_exit_code -ne 0 ]; then
        log_error "Failed to convert amount to wei: $needed_wei"
        return 1
    fi
    
    # Extract numeric values for comparison
    local balance_num="${balance_wei//[^0-9]/}"
    local needed_num="${needed_wei//[^0-9]/}"
    
    # Use bc for comparison to handle large numbers
    if [ $(echo "$balance_num < $needed_num" | bc) -eq 1 ]; then
        log_error "Insufficient balance! Have $balance_eth ETH, need at least $total_needed ETH plus gas."
        return 1
    fi
    
    return 0
}

# Function to estimate gas for better reporting
estimate_gas() {
    local to_address="$1"
    local amount="$2"
    
    local gas_estimate=$(cast estimate --rpc-url "$RPC_URL" --aws --value "${amount}ether" "$to_address" 2>/dev/null || echo "21000")
    echo "$gas_estimate"
}

# Function to send ETH to an address
send_eth() {
    local to_address="$1"
    local amount="$2"
    
    # Ensure AWS environment variables are exported
    export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
    export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}"
    export AWS_REGION="${AWS_REGION}"
    export AWS_KMS_KEY_ID="${AWS_KMS_KEY_ID}"
    
    # Build cast send command
    local cmd="cast send"
    cmd="$cmd --rpc-url '$RPC_URL'"
    cmd="$cmd --aws"  # Use AWS KMS for signing
    cmd="$cmd --value '${amount}ether'"
    
    if [ -n "$GAS_PRICE" ]; then
        cmd="$cmd --gas-price '${GAS_PRICE}gwei'"
    fi
    
    if [ -n "$PRIORITY_FEE" ]; then
        cmd="$cmd --priority-gas-price '${PRIORITY_FEE}gwei'"
    fi
    
    if [ "$CONFIRMATIONS" -gt 0 ]; then
        cmd="$cmd --confirmations $CONFIRMATIONS"
    fi
    
    cmd="$cmd '$to_address'"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would send $amount ETH to $to_address"
        return 0
    fi
    
    # Execute the transaction with environment variables
    if tx_output=$(eval "$cmd" 2>&1); then
        # Extract transaction hash from output
        tx_hash=$(echo "$tx_output" | grep -oE '0x[a-fA-F0-9]{64}' | head -1)
        log_success "Sent $amount ETH to $to_address (tx: $tx_hash)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        TOTAL_ETH_SENT=$(echo "$TOTAL_ETH_SENT + $amount" | bc)
        return 0
    else
        log_error "Failed to send to $to_address: $tx_output"
        echo "$to_address" >> "$FAILED_FILE"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi
}

# Parse command line arguments
ADDRESSES_FILE="wallets-host"

while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--amount)
            AMOUNT="$2"
            shift 2
            ;;
        -r|--rpc)
            RPC_URL="$2"
            shift 2
            ;;
        -d|--delay)
            DELAY_SECONDS="$2"
            shift 2
            ;;
        -g|--gas-price)
            GAS_PRICE="$2"
            shift 2
            ;;
        -p|--priority-fee)
            PRIORITY_FEE="$2"
            shift 2
            ;;
        -c|--confirmations)
            CONFIRMATIONS="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            ADDRESSES_FILE="$1"
            shift
            ;;
    esac
done

# Validate inputs
if [ -z "$ADDRESSES_FILE" ]; then
    echo -e "${RED}Error: No addresses file specified${NC}"
    usage
fi

if [ ! -f "$ADDRESSES_FILE" ]; then
    echo -e "${RED}Error: Addresses file '$ADDRESSES_FILE' not found${NC}"
    exit 1
fi

# Check if cast is installed
if ! command -v cast &> /dev/null; then
    echo -e "${RED}Error: 'cast' command not found. Please install Foundry first.${NC}"
    echo "Visit: https://book.getfoundry.sh/getting-started/installation"
    exit 1
fi

# Check AWS credentials and environment
log_info "Checking AWS configuration..."

# Debug: Show which AWS environment variables are set (without showing values)
[ -n "$AWS_ACCESS_KEY_ID" ] && log_info "AWS_ACCESS_KEY_ID is set"
[ -n "$AWS_SECRET_ACCESS_KEY" ] && log_info "AWS_SECRET_ACCESS_KEY is set"
[ -n "$AWS_SESSION_TOKEN" ] && log_info "AWS_SESSION_TOKEN is set"
[ -n "$AWS_REGION" ] && log_info "AWS_REGION is set: $AWS_REGION"
[ -n "$AWS_KMS_KEY_ID" ] && log_info "AWS_KMS_KEY_ID is set"
[ -n "$AWS_PROFILE" ] && log_info "AWS_PROFILE is set: $AWS_PROFILE"

if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}Error: AWS credentials not configured or expired.${NC}"
    echo "Please configure AWS CLI or set AWS environment variables:"
    echo "  - AWS_ACCESS_KEY_ID"
    echo "  - AWS_SECRET_ACCESS_KEY"
    echo "  - AWS_SESSION_TOKEN (if using temporary credentials)"
    echo "  - AWS_REGION"
    exit 1
fi

# Get sender address from AWS KMS
SENDER_ADDRESS=$(get_sender_address)
if [ $? -ne 0 ]; then
    exit 1
fi
log_info "Sender address: $SENDER_ADDRESS"

# Read and validate addresses
declare -a VALID_ADDRESSES
TOTAL_ADDRESSES=0
INVALID_COUNT=0

log_info "Reading addresses from $ADDRESSES_FILE..."

while IFS= read -r address || [ -n "$address" ]; do
    # Skip empty lines and trim whitespace
    address=$(echo "$address" | tr -d '[:space:]')
    [ -z "$address" ] && continue
    
    # Skip comments (lines starting with #)
    [[ "$address" =~ ^# ]] && continue
    
    TOTAL_ADDRESSES=$((TOTAL_ADDRESSES + 1))
    
    if validate_address "$address"; then
        VALID_ADDRESSES+=("$address")
    else
        log_error "Invalid address format: $address"
        INVALID_COUNT=$((INVALID_COUNT + 1))
    fi
done < "$ADDRESSES_FILE"

log_info "Found $TOTAL_ADDRESSES addresses ($((TOTAL_ADDRESSES - INVALID_COUNT)) valid, $INVALID_COUNT invalid)"

if [ ${#VALID_ADDRESSES[@]} -eq 0 ]; then
    log_error "No valid addresses found!"
    exit 1
fi

# Calculate total ETH needed
TOTAL_NEEDED=$(echo "${#VALID_ADDRESSES[@]} * $AMOUNT" | bc)

# Check balance (skip in dry run mode)
if [ "$DRY_RUN" = false ]; then
    if ! check_balance $SENDER_ADDRESS $TOTAL_NEEDED; then
        exit 1
    fi
fi

# Get current gas price for estimation
CURRENT_GAS_PRICE=""
if [ "$DRY_RUN" = false ]; then
    CURRENT_GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL" 2>/dev/null || echo "unknown")
    if [ "$CURRENT_GAS_PRICE" != "unknown" ]; then
        CURRENT_GAS_PRICE_GWEI=$(cast --from-wei "$CURRENT_GAS_PRICE" gwei 2>/dev/null || echo "unknown")
        log_info "Current network gas price: $CURRENT_GAS_PRICE_GWEI gwei"
    fi
fi

# Display summary
echo -e "\n${BLUE}${NC}"
echo -e "${BLUE}           FUNDING SUMMARY${NC}"
echo -e "${BLUE}${NC}"
echo -e "RPC URL:         $RPC_URL"
echo -e "Sender:          $SENDER_ADDRESS"
echo -e "Addresses:       ${#VALID_ADDRESSES[@]}"
echo -e "Amount per addr: $AMOUNT ETH"
echo -e "Total to send:   $TOTAL_NEEDED ETH"
echo -e "Delay:           ${DELAY_SECONDS}s between txs"
[ -n "$GAS_PRICE" ] && echo -e "Gas price:       $GAS_PRICE gwei"
[ -n "$PRIORITY_FEE" ] && echo -e "Priority fee:    $PRIORITY_FEE gwei"
echo -e "Confirmations:   $CONFIRMATIONS"
echo -e "Key management:  AWS KMS"
[ "$DRY_RUN" = true ] && echo -e "${YELLOW}MODE:            DRY RUN${NC}"
echo -e "${BLUE}${NC}\n"

# Confirm before proceeding (skip in dry run)
if [ "$DRY_RUN" = false ]; then
    echo -e "${YELLOW}Proceed with funding? (yes/no):${NC}"
    read -r CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_info "Operation cancelled by user"
        exit 0
    fi
fi

# Start funding process
log_info "Starting funding process..."
START_TIME=$(date +%s)
COUNTER=0

# Progress bar function
show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    
    printf "\r["
    printf "%0.s�" $(seq 1 $filled)
    printf "%0.s�" $(seq $((filled + 1)) 50)
    printf "] %d%% (%d/%d)" $percent $current $total
}

for address in "${VALID_ADDRESSES[@]}"; do
    COUNTER=$((COUNTER + 1))
    echo -e "\n[${COUNTER}/${#VALID_ADDRESSES[@]}] Processing $address..."
    show_progress $COUNTER ${#VALID_ADDRESSES[@]}
    echo  # New line after progress bar
    
    if send_eth "$address" "$AMOUNT"; then
        :  # Success already logged
    else
        # Ask whether to continue on failure
        if [ "$DRY_RUN" = false ]; then
            echo -e "${YELLOW}Continue with remaining addresses? (yes/no):${NC}"
            read -r CONTINUE
            if [ "$CONTINUE" != "yes" ]; then
                break
            fi
        fi
    fi
    
    # Add delay between transactions (except for last one or dry run)
    if [ "$COUNTER" -lt "${#VALID_ADDRESSES[@]}" ] && [ "$DRY_RUN" = false ] && [ "$DELAY_SECONDS" -gt 0 ]; then
        echo -e "${BLUE}Waiting ${DELAY_SECONDS} seconds...${NC}"
        sleep "$DELAY_SECONDS"
    fi
done

# Calculate elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

# Final summary
echo -e "\n${BLUE}${NC}"
echo -e "${BLUE}           FINAL REPORT${NC}"
echo -e "${BLUE}${NC}"
echo -e "${GREEN}Successful:      $SUCCESS_COUNT${NC}"
echo -e "${RED}Failed:          $FAILED_COUNT${NC}"
echo -e "Total ETH sent:  $TOTAL_ETH_SENT ETH"
echo -e "Time elapsed:    ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
echo -e "Log file:        $LOG_FILE"
[ "$FAILED_COUNT" -gt 0 ] && echo -e "Failed addresses: $FAILED_FILE"
echo -e "${BLUE}${NC}"

if [ "$FAILED_COUNT" -gt 0 ]; then
    echo -e "\n${YELLOW}To retry failed addresses, run:${NC}"
    echo -e "  $0 $FAILED_FILE"
fi

# If all successful and not dry run, show final balance
if [ "$SUCCESS_COUNT" -gt 0 ] && [ "$FAILED_COUNT" -eq 0 ] && [ "$DRY_RUN" = false ]; then
    echo -e "\n${GREEN}All transactions completed successfully!${NC}"
    
    # Show updated sender balance
    FINAL_BALANCE_WEI=$(cast balance "$SENDER_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
    FINAL_BALANCE_ETH=$(cast --from-wei "$FINAL_BALANCE_WEI" 2>/dev/null || echo "0")
    echo -e "Remaining balance: $FINAL_BALANCE_ETH ETH"
fi

exit 0