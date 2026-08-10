#!/usr/bin/env bash

### VERIFY INPUTS ###
printMan() {
    printf "Usage: $0 <Environment: local|mainnet|testnet> <Network Name>\n"
    printf "Supported networks: prod-ethereum, prod-optimism, prod-base, prod-polygon, prod-arbitrum, prod-avalanche, prod-bnb, prod-unichain, prod-berachain, prod-sonic, prod-gnosis, prod-worldchain, prod-hyperliquid, prod-flare, prod-stable, prod-rh, staging-base, staging-ethereum, staging-arbitrum, staging-avalanche, staging-bnb, staging-hyperevm, staging-flare, staging-stable\n"
    printf "Prereq: the Nexus deployment (deploy-nexus.sh) AND the v2-core periphery for this environment must already exist.\n"
}

if [ -z "$1" ]; then
    printf "Please provide environment\n"; printMan; exit 1
fi

ENVIRONMENT=$1

if [ "$ENVIRONMENT" = "local" ]; then
    CHAIN_NAME="localhost"
elif [ "$ENVIRONMENT" = "mainnet" ] || [ "$ENVIRONMENT" = "testnet" ]; then
    if [ -z "$2" ]; then
        printf "Please provide network name\n"; printMan; exit 1
    fi
    CHAIN_NAME=$2
else
    printf "Invalid environment\n"; printMan; exit 1
fi

# Load centralized network configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/networks.sh"
cd "$SCRIPT_DIR"

# Load env + private key
if [ ! -f "$SCRIPT_DIR/../../.env" ]; then
    printf "ERROR: .env not found at repo root (cp .env.example .env)\n"; exit 1
fi
source "$SCRIPT_DIR/../../.env"
if [ -z "$MAINNET_DEPLOYER_PRIVATE_KEY" ]; then
    printf "ERROR: MAINNET_DEPLOYER_PRIVATE_KEY not set in .env\n"; exit 1
fi
PRIVATE_KEY=$MAINNET_DEPLOYER_PRIVATE_KEY

# Validate + resolve chain config
if ! validate_chain_name "$CHAIN_NAME"; then
    printf "Unsupported chain: $CHAIN_NAME\n"; printMan; exit 1
fi
CHAIN_RPC_URL=$(get_rpc_url "$CHAIN_NAME") || { printf "Failed to get RPC URL for: $CHAIN_NAME\n"; exit 1; }
ENVIRONMENT_NAME=$(get_environment_from_chain_name "$CHAIN_NAME") || exit 1

### PREVIEW CONFIG ###
printf "Previewing AccountResolver config (environment: $ENVIRONMENT_NAME):\n"
PREVIEW_OUTPUT=$(FOUNDRY_PROFILE=deploy forge script DeployAccountResolver "$ENVIRONMENT_NAME" \
    --sig "run(string)" --rpc-url "$CHAIN_RPC_URL" -vv 2>&1) || {
    printf "Preview failed for %s — not deploying.\n%s\n" "$CHAIN_NAME" "$(echo "$PREVIEW_OUTPUT" | tail -5)"
    exit 1
}
echo "$PREVIEW_OUTPUT" | grep -e "version:" -e "factory" -e "bootstrap" -e "Validator" -e "executor"

printf "Do you want to proceed with the addresses above? (y/n): "
read -r proceed
if [ "$proceed" != "y" ]; then
    printf "Exiting\n"; exit 0
fi

printf "Do you want to specify gas price? (y/n): "
read -r gas
GAS_SUFFIX=""
if [ "$gas" = "y" ]; then
    printf "EIP-1559: '<baseFee> <priorityFee>' gwei | legacy: '<gasPrice>' gwei\n"
    read -r -a GAS_ARGS
    if [ ${#GAS_ARGS[@]} -eq 2 ]; then
        GAS_SUFFIX="--with-gas-price ${GAS_ARGS[0]}gwei --priority-gas-price ${GAS_ARGS[1]}gwei"
    else
        GAS_SUFFIX="--legacy --with-gas-price ${GAS_ARGS[0]}gwei"
    fi
fi

### DEPLOY ###
mkdir -p ./logs/$CHAIN_NAME
{
    FOUNDRY_PROFILE=deploy forge script DeployAccountResolver "$ENVIRONMENT_NAME" \
        --sig "runDeploy(string)" --rpc-url "$CHAIN_RPC_URL" --private-key "$PRIVATE_KEY" \
        -vv --broadcast --slow $GAS_SUFFIX \
        1> ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-resolver.log 2> ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-resolver-errors.log
} || {
    printf "Deployment failed. See ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-resolver-errors.log\n"; exit 1
}
printf "Deployment successful\n"
grep -e "deployed at" -e "Exported AccountResolver" ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-resolver.log
