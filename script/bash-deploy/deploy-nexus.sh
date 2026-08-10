
#!/usr/bin/env bash

### VERIFY INPUTS ###
printMan() {
    printf "Usage: $0 <Environment: local|mainnet|testnet> <Network Name>\n"
    printf "Supported networks: main-ethereum, main-op, main-base, demo-ethereum, demo-op, demo-base, staging-bnb, staging-ethereum, staging-arbitrum, staging-avalanche, staging-base, staging-hyperevm, staging-flare, staging-stable, prod-ethereum, prod-optimism, prod-base, prod-polygon, prod-arbitrum, prod-avalanche, prod-bnb, prod-unichain, prod-berachain, prod-sonic, prod-gnosis, prod-worldchain, prod-hyperliquid, prod-flare, prod-stable, prod-rh\n"
}

if [ $# -eq 0 ]; then
    printf "Please provide private key, environment and network name\n"
    printMan
    exit 1
fi

if [ -z $1 ]; then
    printf "Please provide environment\n"
    printMan
    exit 1
fi

ENVIRONMENT=$1
VERIFY=""

if [ $ENVIRONMENT = "local" ]; then
    CHAIN_NAME="localhost"
else
    if [ $ENVIRONMENT = "mainnet" ] || [ $ENVIRONMENT = "testnet" ]; then
        if [ -z $2 ]; then
            printf "Please provide network name\n"
            printMan
            exit 1
        fi
        CHAIN_NAME=$2
        VERIFY="--verify"
    else
        printf "Invalid environment\n"
        printMan
        exit 1
    fi
fi

# Load centralized network configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/networks.sh"

# Run from the bash-deploy directory so relative paths (logs, artifacts, ../../out) work
# regardless of where the script was invoked from
cd "$SCRIPT_DIR"

# Load environment variables from .env (for EP_V07_DEPLOY_TX_DATA and other variables)
if [ ! -f "$SCRIPT_DIR/../../.env" ]; then
    printf "ERROR: .env not found at repo root\n"
    printf "Create it first: cp .env.example .env  (then set MAINNET_DEPLOYER_PRIVATE_KEY)\n"
    exit 1
fi
source "$SCRIPT_DIR/../../.env"

# Load private key from environment variable (set in .env)
if [ -z "$MAINNET_DEPLOYER_PRIVATE_KEY" ]; then
    printf "ERROR: MAINNET_DEPLOYER_PRIVATE_KEY not set in .env\n"
    exit 1
fi
PRIVATE_KEY=$MAINNET_DEPLOYER_PRIVATE_KEY

# Setup chain configuration using centralized networks
setup_chain_config() {
    if ! validate_chain_name "$CHAIN_NAME"; then
        printf "Unsupported chain: $CHAIN_NAME\n"
        printf "Supported chains: main-ethereum, main-op, main-base, demo-ethereum, demo-op, demo-base, staging-bnb, staging-ethereum, staging-arbitrum, staging-avalanche, staging-base, staging-hyperevm, staging-flare, staging-stable, prod-ethereum, prod-optimism, prod-base, prod-polygon, prod-arbitrum, prod-avalanche, prod-bnb, prod-unichain, prod-berachain, prod-sonic, prod-gnosis, prod-worldchain, prod-hyperliquid, prod-flare, prod-stable, prod-rh\n"
        exit 1
    fi

    CHAIN_RPC_URL=$(get_rpc_url "$CHAIN_NAME")
    if [ $? -ne 0 ]; then
        printf "Failed to get RPC URL for chain: $CHAIN_NAME\n"
        exit 1
    fi
}

# Determine default validator using centralized networks
compute_default_validator() {
    DEFAULT_VALIDATOR=$(get_default_validator "$CHAIN_NAME")
}

# Determine environment using centralized networks
compute_environment() {
    ENVIRONMENT_NAME=$(get_environment_from_chain_name "$CHAIN_NAME")
}

# Set up chain configuration and defaults
setup_chain_config
compute_default_validator
compute_environment

### DEPLOY PRE-REQUISITES ###
{ (bash "$SCRIPT_DIR/deploy-prerequisites.sh" $PRIVATE_KEY $ENVIRONMENT $CHAIN_NAME $CHAIN_RPC_URL) } || {
    printf "Deployment prerequisites failed\n"
    exit 1
}

### COPY ARTIFACTS ###
# NOTE: the precompiled artifacts are the canonical v2.2.3 release bytecode (Nexus 1.3.3,
# with the single-initialization fix from bcnmy/stx-contracts#24). Rebuilding from the
# current branch sources produces byte-identical output, so either answer is safe.
# Batch mode: BATCH_REBUILD (y/n) answers this prompt for all chains.
if [ -n "$BATCH_REBUILD" ]; then
    proceed=$BATCH_REBUILD
    printf "Batch mode: rebuild artifacts = %s\n" "$proceed"
else
    read -r -p "Do you want to rebuild Nexus artifacts from your local sources? (y/n): " proceed
fi
if [ $proceed = "y" ]; then
    ### BUILD ARTIFACTS ###
    printf "Building Nexus artifacts\n"
    { (forge build 1> ./logs/forge-build.log 2> ./logs/forge-build-errors.log) } || {
        printf "Build failed\n See logs for more details\n"
        exit 1
    }
    printf "Copying Nexus artifacts\n"
    mkdir -p ./artifacts/Nexus
    mkdir -p ./artifacts/NexusBootstrap
    mkdir -p ./artifacts/NexusAccountFactory
    mkdir -p ./artifacts/NexusProxy

    cp ../../out/Nexus.sol/Nexus.json ./artifacts/Nexus/.
    cp ../../out/NexusBootstrap.sol/NexusBootstrap.json ./artifacts/NexusBootstrap/.
    cp ../../out/NexusAccountFactory.sol/NexusAccountFactory.json ./artifacts/NexusAccountFactory/.
    cp ../../out/NexusProxy.sol/NexusProxy.json ./artifacts/NexusProxy/.

    printf "Artifacts copied\n"

    ### CREATE VERIFICATION ARTIFACTS ###
    printf "Creating verification artifacts\n"

    forge verify-contract --show-standard-json-input $(cast address-zero) Nexus > ./artifacts/Nexus/verify.json
    forge verify-contract --show-standard-json-input $(cast address-zero) NexusBootstrap > ./artifacts/NexusBootstrap/verify.json
    forge verify-contract --show-standard-json-input $(cast address-zero) NexusAccountFactory > ./artifacts/NexusAccountFactory/verify.json
    forge verify-contract --show-standard-json-input $(cast address-zero) NexusProxy > ./artifacts/NexusProxy/verify.json


else
    printf "Using precompiled artifacts\n"
fi

### DEPLOY NEXUS SCs ###
printf "Addresses for Nexus SCs (validator: $DEFAULT_VALIDATOR, environment: $ENVIRONMENT_NAME):\n"
FOUNDRY_PROFILE=deploy forge script DeployNexus true $DEFAULT_VALIDATOR --sig "run(bool,address)" --rpc-url $CHAIN_RPC_URL -vv | grep -e "Addr" -e "already deployed"
# Batch mode: BATCH_PROCEED (y/n) answers the address confirmation for all chains.
if [ -n "$BATCH_PROCEED" ]; then
    proceed=$BATCH_PROCEED
    printf "Batch mode: proceed with addresses = %s\n" "$proceed"
else
    printf "Do you want to proceed with the addresses above? (y/n): "
    read -r proceed
fi
if [ $proceed = "y" ]; then
    # Batch mode: BATCH_GAS = "n" for default gas, or gas args (e.g. "20 1" eip-1559, "20" legacy).
    if [ -n "$BATCH_GAS" ]; then
        if [ "$BATCH_GAS" = "n" ]; then
            GAS_ARGS=()
        else
            read -r -a GAS_ARGS <<< "$BATCH_GAS"
        fi
        printf "Batch mode: gas = %s\n" "${BATCH_GAS}"
    else
        printf "Do you want to specify gas price? (y/n): "
        read -r proceed
        if [ $proceed = "y" ]; then
            printf "Enter gas prices args: \n For the EIP-1559 chains, enter two args: base fee and priority fee in gwei\n For the legacy chains, enter one argument. \n Example eip-1559: 20 1 \n Example legacy: 20 \n"
            read -r -a GAS_ARGS
        else
            GAS_ARGS=()
        fi
    fi
    if [ ${#GAS_ARGS[@]} -eq 2 ]; then
        GAS_SUFFIX="--with-gas-price ${GAS_ARGS[0]}gwei --priority-gas-price ${GAS_ARGS[1]}gwei"
    elif [ ${#GAS_ARGS[@]} -eq 1 ]; then
        GAS_SUFFIX="--legacy --with-gas-price ${GAS_ARGS[0]}gwei"
    else
        GAS_SUFFIX=""
    fi
    {
        printf "Proceeding with deployment \n"
        mkdir -p ./logs/$CHAIN_NAME

        # Set verification flag (default to false)
        SHOULD_VERIFY=false

        if [ "$SHOULD_VERIFY" = true ]; then
            FOUNDRY_PROFILE=deploy forge script DeployNexus $ENVIRONMENT_NAME $DEFAULT_VALIDATOR --sig "runDeploy(string,address)" --rpc-url $CHAIN_RPC_URL --etherscan-api-key $CHAIN_NAME --private-key $PRIVATE_KEY $VERIFY -vv --broadcast --slow $GAS_SUFFIX 1> ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-nexus.log 2> ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-nexus-errors.log
        else
            FOUNDRY_PROFILE=deploy forge script DeployNexus $ENVIRONMENT_NAME $DEFAULT_VALIDATOR --sig "runDeploy(string,address)" --rpc-url $CHAIN_RPC_URL --private-key $PRIVATE_KEY -vv --broadcast --slow $GAS_SUFFIX 1> ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-nexus.log 2> ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-nexus-errors.log
        fi
    } || {
        printf "Deployment failed\n See logs for more details\n"
        exit 1
    }
    printf "Deployment successful\n"
    cat ./logs/$CHAIN_NAME/$CHAIN_NAME-deploy-nexus.log | grep "deployed at"

else
    printf "Exiting\n"
fi
