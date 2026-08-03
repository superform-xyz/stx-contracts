#!/opt/homebrew/bin/bash

# Load centralized network configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/networks.sh"

# Colors for better visual output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Function to print colored header
print_header() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                                                      ║${NC}"
    echo -e "${CYAN}║${WHITE}                    📤 Nexus S3 Sync Script 📤                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║${WHITE}           (Nexus, NexusBootstrap & NexusAccountFactory Only)                    ${CYAN}║${NC}"
    echo -e "${CYAN}║                                                                                      ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Function to print section separator
print_separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Logging function for consistent output
log() {
    local level=$1
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
}

# Function to validate that network exists in networks.sh configuration
validate_network_exists() {
    local network_name=$1
    local chain_id=$2
    
    # Get the expected network name from networks.sh for this chain ID
    local expected_network_name=$(get_chain_name "$chain_id")
    
    if [ -z "$expected_network_name" ]; then
        log "ERROR" "Chain ID $chain_id is not defined in networks.sh"
        return 1
    fi
    
    if [ "$network_name" != "$expected_network_name" ]; then
        log "ERROR" "Network name mismatch: found '$network_name' but expected '$expected_network_name' for chain ID $chain_id"
        return 1
    fi
    
    log "INFO" "Network validation passed: $network_name matches configuration for chain ID $chain_id"
    return 0
}

# Function to filter and extract only allowed contracts from the JSON
filter_allowed_contracts() {
    local contracts_json=$1
    local network_name=$2
    local allowed_contracts=("Nexus" "NexusBootstrap" "NexusAccountFactory")
    
    log "INFO" "Filtering contracts for $network_name to only include Nexus, NexusBootstrap and NexusAccountFactory"
    
    # Create filtered JSON with only allowed contracts
    local filtered_json="{}"
    
    for allowed in "${allowed_contracts[@]}"; do
        local contract_address=$(echo "$contracts_json" | jq -r ".$allowed // empty")
        if [ -n "$contract_address" ] && [ "$contract_address" != "null" ] && [ "$contract_address" != "empty" ]; then
            filtered_json=$(echo "$filtered_json" | jq --arg contract "$allowed" --arg addr "$contract_address" '.[$contract] = $addr')
            log "INFO" "Found and extracted $allowed: $contract_address for $network_name"
        else
            log "WARN" "Contract $allowed not found in deployment file for $network_name"
        fi
    done
    
    echo "$filtered_json"
}

# Function to read latest file from S3
read_latest_from_s3() {
    local environment=$1
    local s3_bucket=$2
    local latest_file_path="/tmp/nexus_latest_s3.json"

    if aws s3 cp "s3://$s3_bucket/$environment/latest.json" "$latest_file_path" --quiet 2>/dev/null; then
        log "INFO" "Successfully downloaded latest.json from S3 for $environment"
        
        # Read the file and validate JSON
        local content=$(cat "$latest_file_path")
        
        # Check if content is empty or just whitespace
        if [ -z "$(echo "$content" | tr -d '[:space:]')" ]; then
            log "WARN" "S3 file is empty or whitespace only, initializing default content"
            content="{\"networks\":{},\"updated_at\":null}"
        elif ! echo "$content" | jq '.' >/dev/null 2>&1; then
            log "ERROR" "Invalid JSON in latest file, resetting to default"
            content="{\"networks\":{},\"updated_at\":null}"
        else
            log "INFO" "Successfully validated latest.json from S3"
        fi
    else
        log "WARN" "latest.json not found in S3 for $environment, initializing empty file"
        content="{\"networks\":{},\"updated_at\":null}"
    fi
   
    echo "$content"
}

# Function to process all Nexus contract updates in batch
process_all_nexus_updates() {
    local environment=$1
    local s3_bucket=$2
    local deployments=("${@:3}")
    
    log "INFO" "Processing all Nexus contract updates in batch for environment: $environment"
    
    # Read current S3 content once
    local s3_content=$(read_latest_from_s3 "$environment" "$s3_bucket")
    local updated_content="$s3_content"
    
    # Track updates for summary
    declare -a update_summary=()
    local total_networks=0
    local successful_networks=0
    local failed_networks=0
    
    # Process each deployment
    for deployment in "${deployments[@]}"; do
        IFS=':' read -r chain_id network_name <<< "$deployment"
        total_networks=$((total_networks + 1))
        
        echo -e "${PURPLE}╭─────────────────────────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "${PURPLE}│${WHITE}                     📤 Processing $network_name Nexus Contracts 📤                  ${PURPLE}│${NC}"
        echo -e "${PURPLE}╰─────────────────────────────────────────────────────────────────────────────────────╯${NC}"
        
        # Validate network exists in configuration
        if ! validate_network_exists "$network_name" "$chain_id"; then
            echo -e "${RED}❌ Network validation failed for $network_name (Chain ID: $chain_id)${NC}"
            update_summary+=("❌ $network_name: Network validation failed")
            failed_networks=$((failed_networks + 1))
            continue
        fi
        
        # Read deployment file
        local contracts_file="$SCRIPT_DIR/deployment/$environment/$chain_id/$network_name.json"
        
        if [ ! -f "$contracts_file" ]; then
            log "ERROR" "Contract file not found: $contracts_file"
            echo -e "${RED}❌ Contract file not found for $network_name${NC}"
            update_summary+=("❌ $network_name: Contract file not found")
            failed_networks=$((failed_networks + 1))
            continue
        fi
        
        # Read and parse contracts
        local contracts=$(tr -d '\r' < "$contracts_file")
        if ! contracts=$(echo "$contracts" | jq -c '.' 2>/dev/null); then
            log "ERROR" "Failed to parse JSON from contract file for $network_name"
            echo -e "${RED}❌ Failed to parse JSON for $network_name${NC}"
            update_summary+=("❌ $network_name: Failed to parse JSON")
            failed_networks=$((failed_networks + 1))
            continue
        fi
        
        # Filter to only allowed contracts
        local filtered_contracts=$(filter_allowed_contracts "$contracts" "$network_name")
        local contract_count=$(echo "$filtered_contracts" | jq 'length')
        
        if [ "$contract_count" -eq 0 ]; then
            log "ERROR" "No allowed contracts found for $network_name"
            echo -e "${RED}❌ No allowed contracts found for $network_name${NC}"
            update_summary+=("❌ $network_name: No allowed contracts found")
            failed_networks=$((failed_networks + 1))
            continue
        fi
        
        # Check if network exists in S3
        local network_exists=$(echo "$updated_content" | jq -r ".networks[\"$network_name\"] // empty")
        
        if [ -z "$network_exists" ] || [ "$network_exists" = "null" ]; then
            log "ERROR" "Network $network_name does not exist in S3"
            echo -e "${RED}❌ Network '$network_name' not found in S3 bucket '$s3_bucket'${NC}"
            echo -e "${YELLOW}💡 Please deploy v2-core contracts first before syncing Nexus contracts.${NC}"
            update_summary+=("❌ $network_name: Network not found in S3 (v2-core not deployed)")
            failed_networks=$((failed_networks + 1))
            continue
        fi
        
        # Extract existing contracts and update only Nexus contracts
        local existing_contracts=$(echo "$updated_content" | jq -r ".networks[\"$network_name\"].contracts // {}")
        
        local nexus=$(echo "$filtered_contracts" | jq -r '.Nexus // empty')
        local nexus_bootstrap=$(echo "$filtered_contracts" | jq -r '.NexusBootstrap // empty')
        local nexus_account_factory=$(echo "$filtered_contracts" | jq -r '.NexusAccountFactory // empty')
        
        local updates_made=()
        
        if [ -n "$nexus" ] && [ "$nexus" != "empty" ]; then
            existing_contracts=$(echo "$existing_contracts" | jq --arg addr "$nexus" '.Nexus = $addr')
            updates_made+=("Nexus: $nexus")
        fi
        
        if [ -n "$nexus_bootstrap" ] && [ "$nexus_bootstrap" != "empty" ]; then
            existing_contracts=$(echo "$existing_contracts" | jq --arg addr "$nexus_bootstrap" '.NexusBootstrap = $addr')
            updates_made+=("NexusBootstrap: $nexus_bootstrap")
        fi
        
        if [ -n "$nexus_account_factory" ] && [ "$nexus_account_factory" != "empty" ]; then
            existing_contracts=$(echo "$existing_contracts" | jq --arg addr "$nexus_account_factory" '.NexusAccountFactory = $addr')
            updates_made+=("NexusAccountFactory: $nexus_account_factory")
        fi
        
        # Update the S3 content with new contracts (preserve existing counter)
        updated_content=$(echo "$updated_content" | jq \
            --arg network "$network_name" \
            --argjson contracts "$existing_contracts" \
            '.networks[$network].contracts = $contracts')
        
        echo -e "${GREEN}✅ Prepared updates for $network_name${NC}"
        update_summary+=("✅ $network_name: ${updates_made[*]}")
        successful_networks=$((successful_networks + 1))
    done
    
    # Update timestamp
    updated_content=$(echo "$updated_content" | jq --arg time "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '.updated_at = $time')
    
    # Display summary of all changes
    print_separator
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}                          📋 BATCH UPDATE SUMMARY 📋                                 ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}Environment: ${WHITE}$environment${NC}"
    echo -e "${CYAN}S3 Bucket: ${WHITE}$s3_bucket${NC}"
    echo -e "${CYAN}Total Networks: ${WHITE}$total_networks${NC}"
    echo -e "${GREEN}Successful: ${WHITE}$successful_networks${NC}"
    echo -e "${RED}Failed: ${WHITE}$failed_networks${NC}"
    echo ""
    
    for summary_line in "${update_summary[@]}"; do
        echo -e "  $summary_line"
    done
    
    echo ""
    
    if [ $successful_networks -eq 0 ]; then
        echo -e "${RED}❌ No successful updates to upload${NC}"
        return 1
    fi
    
    # Show networks that will be updated in S3
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Networks that will be updated in S3:${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Show updated networks with only Nexus contracts
    for deployment in "${deployments[@]}"; do
        IFS=':' read -r chain_id network_name <<< "$deployment"
        
        # Only show successful networks
        local network_exists=$(echo "$updated_content" | jq -r ".networks[\"$network_name\"] // empty")
        if [ -n "$network_exists" ] && [ "$network_exists" != "null" ]; then
            echo -e "${CYAN}📍 $network_name:${NC}"
            echo "$updated_content" | jq ".networks[\"$network_name\"] | {contracts: {Nexus: .contracts.Nexus, NexusBootstrap: .contracts.NexusBootstrap, NexusAccountFactory: .contracts.NexusAccountFactory}}"
            echo ""
        fi
    done
    
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Ask for single confirmation to upload all changes
    printf "${WHITE}Do you want to upload ALL these updates to S3 in a single batch? (y/n): ${NC}"
    read -r confirmation
    echo ""
    
    if [ "$confirmation" != "y" ] && [ "$confirmation" != "Y" ]; then
        log "INFO" "Batch upload cancelled by user"
        echo -e "${YELLOW}⚠️ Batch upload cancelled${NC}"
        return 1
    fi
    
    # Upload to S3
    local latest_file_path="/tmp/nexus_batch_upload.json"
    echo "$updated_content" | jq '.' > "$latest_file_path"
    
    if aws s3 cp "$latest_file_path" "s3://$s3_bucket/$environment/latest.json" --quiet; then
        log "SUCCESS" "Successfully uploaded batch update to S3 for $environment"
        echo -e "${GREEN}✅ Successfully uploaded batch update to S3${NC}"
        return 0
    else
        log "ERROR" "Failed to upload batch update to S3"
        echo -e "${RED}❌ Failed to upload batch update to S3${NC}"
        return 1
    fi
}

print_header

# Check if arguments are provided
if [ $# -lt 1 ]; then
    echo -e "${RED}❌ Error: Missing required argument${NC}"
    echo -e "${YELLOW}Usage: $0 <environment> [chain_id1,chain_id2,...]${NC}"
    echo -e "${CYAN}  environment: main, demo, or staging${NC}"
    echo -e "${CYAN}  chain_ids: Optional comma-separated list of chain IDs${NC}"
    echo -e "${CYAN}Examples:${NC}"
    echo -e "${CYAN}  $0 main${NC}"
    echo -e "${CYAN}  $0 demo 1,10,8453${NC}"
    echo -e "${CYAN}  $0 staging 1${NC}"
    echo ""
    echo -e "${YELLOW}Note: Production deployments can be done via deploy-nexus.sh, but S3 sync is manual${NC}"
    echo ""
    print_network_summary
    exit 1
fi

ENVIRONMENT=$1
CHAIN_IDS_INPUT=${2:-""}

# Validate environment using centralized networks
if ! validate_environment "$ENVIRONMENT"; then
    exit 1
fi

# Special check for production environment in S3 sync script
if [ "$ENVIRONMENT" = "production" ]; then
    echo -e "${RED}❌ Production environment is not supported for S3 sync${NC}"
    echo -e "${YELLOW}💡 Production Nexus deployments can be done via deploy-nexus.sh${NC}"
    echo -e "${CYAN}   However, S3 sync for production must be handled manually${NC}"
    exit 1
fi

print_separator
echo -e "${BLUE}🔧 Loading Configuration...${NC}"

# Get S3 bucket for environment using centralized networks
S3_BUCKET=$(get_s3_bucket_for_environment "$ENVIRONMENT")
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Failed to determine S3 bucket for environment: $ENVIRONMENT${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Configuration loaded successfully${NC}"
echo -e "${CYAN}   • Environment: $ENVIRONMENT${NC}"
echo -e "${CYAN}   • S3 Bucket: $S3_BUCKET${NC}"
print_separator

echo -e "${BLUE}🔍 Scanning for Nexus deployments in $SCRIPT_DIR/deployment/$ENVIRONMENT/...${NC}"

FOUND_DEPLOYMENTS=()

# If specific chain IDs are provided, use those
if [ -n "$CHAIN_IDS_INPUT" ]; then
    IFS=',' read -ra CHAIN_ID_ARRAY <<< "$CHAIN_IDS_INPUT"
    for chain_id in "${CHAIN_ID_ARRAY[@]}"; do
        chain_name=$(get_chain_name "$chain_id")
        if [ $? -eq 0 ]; then
            contracts_file="$SCRIPT_DIR/deployment/$ENVIRONMENT/$chain_id/$chain_name.json"
            if [ -f "$contracts_file" ]; then
                echo -e "${GREEN}   ✅ Found deployment: $chain_name (Chain ID: $chain_id)${NC}"
                FOUND_DEPLOYMENTS+=("$chain_id:$chain_name")
            else
                echo -e "${YELLOW}   ⚠️  No deployment found: $chain_name (Chain ID: $chain_id) - $contracts_file${NC}"
            fi
        else
            echo -e "${RED}   ❌ Chain ID $chain_id not defined in networks.sh${NC}"
            exit 1
        fi
    done
else
    # Scan all possible deployments using centralized chain IDs
    for chain_id in $(get_all_chain_ids); do
        chain_name=$(get_chain_name "$chain_id")
        if [ -n "$chain_name" ]; then
            contracts_file="$SCRIPT_DIR/deployment/$ENVIRONMENT/$chain_id/$chain_name.json"
            if [ -f "$contracts_file" ]; then
                echo -e "${GREEN}   ✅ Found deployment: $chain_name (Chain ID: $chain_id)${NC}"
                FOUND_DEPLOYMENTS+=("$chain_id:$chain_name")
            fi
        fi
    done
fi

if [ ${#FOUND_DEPLOYMENTS[@]} -eq 0 ]; then
    echo -e "${RED}❌ No Nexus contract deployments found in $SCRIPT_DIR/deployment/$ENVIRONMENT/ directory${NC}"
    echo -e "${YELLOW}Please ensure contracts have been deployed before running this script.${NC}"
    exit 1
fi

print_separator
echo -e "${BLUE}📤 Processing Nexus contract updates in batch mode...${NC}"

# Process all deployments in batch
if process_all_nexus_updates "$ENVIRONMENT" "$S3_BUCKET" "${FOUND_DEPLOYMENTS[@]}"; then
    print_separator
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                                                      ║${NC}"
    echo -e "${GREEN}║${WHITE}              🎉 Batch Nexus Contract Update Completed Successfully! 🎉             ${GREEN}║${NC}"
    echo -e "${GREEN}║                                                                                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}🔗 Nexus contracts updated in S3 bucket: $S3_BUCKET/$ENVIRONMENT/latest.json${NC}"
    echo -e "${CYAN}📊 Total networks processed: ${#FOUND_DEPLOYMENTS[@]}${NC}"
else
    print_separator
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                                                      ║${NC}"
    echo -e "${RED}║${WHITE}                    ❌ Batch Update Failed or Cancelled ❌                         ${RED}║${NC}"
    echo -e "${RED}║                                                                                      ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

print_separator