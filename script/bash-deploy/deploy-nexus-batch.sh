#!/usr/bin/env bash

# Load centralized network configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/networks.sh"

printMan() {
    printf "Usage: $0 <Environment: local|mainnet|testnet> [--preset <main|demo|staging|production>] [chain1 chain2 ...]\n"
    printf "Examples:\n"
    printf "  $0 mainnet --preset main\n"
    printf "  $0 testnet demo-ethereum demo-op demo-base\n"
    printf "  $0 mainnet --preset staging\n"
    printf "  $0 mainnet --preset production\n"
    printf "  $0 mainnet prod-ethereum prod-base prod-arbitrum\n"
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

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Ask the per-chain questions once and apply the answers to every chain.
printf "Rebuild Nexus artifacts from local sources? Applies to all chains (y/n): "
read -r BATCH_REBUILD
printf "Auto-confirm the computed addresses on every chain? (y = don't ask again, n = ask per chain): "
read -r CONFIRM_ONCE
if [ "$CONFIRM_ONCE" = "y" ]; then
    BATCH_PROCEED="y"
    export BATCH_PROCEED
fi
printf "Gas price for all chains — 'n' for defaults, or args ('20 1' eip-1559, '20' legacy): "
read -r BATCH_GAS
export BATCH_REBUILD BATCH_GAS

for CHAIN in "${CHAINS[@]}"; do
    printf "\n===============================================\n"
    printf "Deploying to %s (%s)\n" "$CHAIN" "$ENVIRONMENT"
    printf "===============================================\n\n"
    ( cd "$SCRIPT_DIR" && bash deploy-nexus.sh "$ENVIRONMENT" "$CHAIN" ) || {
        printf "Deployment failed for %s (%s)\n" "$CHAIN" "$ENVIRONMENT"
        exit 1
    }
done

printf "\nAll deployments completed successfully.\n"


