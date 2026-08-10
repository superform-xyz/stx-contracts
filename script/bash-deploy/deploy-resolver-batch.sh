#!/usr/bin/env bash

# Load centralized network configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/networks.sh"

printMan() {
    printf "Usage: $0 <Environment: local|mainnet|testnet> [--preset <main|demo|staging|production>] [chain1 chain2 ...]\n"
    printf "Examples:\n"
    printf "  $0 mainnet --preset production\n"
    printf "  $0 mainnet --preset staging\n"
    printf "  $0 mainnet prod-ethereum prod-base prod-arbitrum\n"
    printf "Prereq per chain: the Nexus deployment (deploy-nexus.sh) AND the v2-core periphery for this environment must already exist.\n"
}

if [ $# -lt 1 ]; then
    printMan
    exit 1
fi

ENVIRONMENT=$1
shift

PRESET=""
CHAINS=()

while (( "$#" )); do
    case "$1" in
        --preset)
            shift
            PRESET=$1
            ;;
        *)
            CHAINS+=("$1")
            ;;
    esac
    shift
done

if [ -n "$PRESET" ]; then
    PRESET_CHAINS=$(get_preset_chains "$PRESET")
    if [ $? -ne 0 ]; then
        printf "Unknown preset: %s\n" "$PRESET"
        exit 1
    fi
    read -ra CHAINS <<< "$PRESET_CHAINS"
fi

if [ ${#CHAINS[@]} -eq 0 ]; then
    printf "No chains provided.\n"
    printMan
    exit 1
fi

for CHAIN in "${CHAINS[@]}"; do
    printf "\n===============================================\n"
    printf "Deploying AccountResolver to %s (%s)\n" "$CHAIN" "$ENVIRONMENT"
    printf "===============================================\n\n"
    ( cd "$SCRIPT_DIR" && bash deploy-resolver.sh "$ENVIRONMENT" "$CHAIN" ) || {
        printf "Deployment failed for %s (%s)\n" "$CHAIN" "$ENVIRONMENT"
        exit 1
    }
done

printf "\nAll resolver deployments completed successfully.\n"
