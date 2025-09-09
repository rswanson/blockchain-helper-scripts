#!/bin/bash

# Blockchain Fork Detection Script
# Finds the first block where two RPC endpoints diverge using binary search

# Configuration
RPC1="http://localhost:7645"
RPC2="https://rpc.pecorino.signet.sh"
START_BLOCK=0
END_BLOCK=236048

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to get block hash from an RPC endpoint
get_block_hash() {
    local block_num=$1
    local rpc_url=$2
    local hex_num=$(cast to-hex "$block_num")
    
    # Get the hash, suppress error output
    local hash=$(cast rpc eth_getBlockByNumber "$hex_num" "true" --rpc-url "$rpc_url" 2>/dev/null | jq -r .hash 2>/dev/null)
    
    # Check if we got a valid response
    if [ -z "$hash" ] || [ "$hash" = "null" ]; then
        echo "ERROR"
    else
        echo "$hash"
    fi
}

# Function to compare hashes at a given block
compare_blocks() {
    local block_num=$1
    
    echo -ne "Checking block $block_num... "
    
    local hash1=$(get_block_hash "$block_num" "$RPC1")
    local hash2=$(get_block_hash "$block_num" "$RPC2")
    
    # Handle errors
    if [ "$hash1" = "ERROR" ] || [ "$hash2" = "ERROR" ]; then
        echo -e "${RED}Error fetching block data${NC}"
        return 2
    fi
    
    if [ "$hash1" = "$hash2" ]; then
        echo -e "${GREEN}Match${NC} ($hash1)"
        return 0
    else
        echo -e "${RED}Divergence found!${NC}"
        echo "  RPC1 ($RPC1): $hash1"
        echo "  RPC2 ($RPC2): $hash2"
        return 1
    fi
}

# Main binary search logic
binary_search() {
    local left=$START_BLOCK
    local right=$END_BLOCK
    local first_divergence=-1
    
    echo "==============================================="
    echo "Blockchain Fork Detection"
    echo "==============================================="
    echo "RPC Endpoint 1: $RPC1"
    echo "RPC Endpoint 2: $RPC2"
    echo "Search Range: Block $left to $right"
    echo "==============================================="
    echo ""
    
    # First check the boundaries
    echo -e "${YELLOW}Checking boundary blocks...${NC}"
    
    # Check if the start block matches
    if ! compare_blocks "$left"; then
        echo ""
        echo -e "${RED}Chains diverge from the very beginning (block $left)!${NC}"
        return
    fi
    
    # Check if the end block matches
    if compare_blocks "$right"; then
        echo ""
        echo -e "${GREEN}No divergence found in the entire range!${NC}"
        echo "Both chains are identical from block $left to $right"
        return
    fi
    
    echo ""
    echo -e "${YELLOW}Starting binary search...${NC}"
    echo ""
    
    # Binary search for the first divergence
    while [ $left -lt $right ]; do
        local mid=$(( (left + right) / 2 ))
        
        if compare_blocks "$mid"; then
            # Blocks match, divergence is after this block
            left=$((mid + 1))
        else
            # Blocks don't match, divergence is at or before this block
            first_divergence=$mid
            right=$mid
        fi
        
        # Show progress
        echo "  Search range: [$left, $right]"
        echo ""
    done
    
    # Final verification
    echo "==============================================="
    echo -e "${YELLOW}Final Verification${NC}"
    echo "==============================================="
    
    if [ $first_divergence -ne -1 ]; then
        echo -e "${GREEN}First divergence found at block: $first_divergence${NC}"
        echo ""
        
        # Show the last matching block (if not at start)
        if [ $first_divergence -gt $START_BLOCK ]; then
            local last_match=$((first_divergence - 1))
            echo "Last matching block: $last_match"
            compare_blocks "$last_match"
            echo ""
        fi
        
        # Show the first diverging block
        echo "First diverging block: $first_divergence"
        compare_blocks "$first_divergence"
    else
        echo -e "${RED}Unable to find divergence point${NC}"
    fi
}

# Check dependencies
check_dependencies() {
    local missing_deps=0
    
    if ! command -v cast &> /dev/null; then
        echo -e "${RED}Error: 'cast' command not found${NC}"
        echo "Please install Foundry: https://getfoundry.sh"
        missing_deps=1
    fi
    
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: 'jq' command not found${NC}"
        echo "Please install jq: apt-get install jq (or brew install jq)"
        missing_deps=1
    fi
    
    if [ $missing_deps -eq 1 ]; then
        exit 1
    fi
}

# Main execution
main() {
    check_dependencies
    
    # Optional: Allow custom range via command line arguments
    if [ $# -ge 2 ]; then
        START_BLOCK=$1
        END_BLOCK=$2
        echo "Using custom range: $START_BLOCK to $END_BLOCK"
    fi
    
    # Optional: Allow custom RPC endpoints
    if [ $# -ge 4 ]; then
        RPC1=$3
        RPC2=$4
        echo "Using custom RPC endpoints"
    fi
    
    binary_search
}

# Run the script
main "$@"
