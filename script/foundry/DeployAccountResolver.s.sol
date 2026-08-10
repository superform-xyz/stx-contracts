// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { Script, console2 } from "forge-std/Script.sol";
import { AccountResolver } from "../../contracts/resolver/AccountResolver.sol";

/// @title DeployAccountResolver
/// @notice Deploys AccountResolver initialized (in-constructor) with both account versions for a given environment,
///         mirroring the DeployNexus bash-deploy flow (pass environment + network, read canonical address JSONs).
///
/// Address sources per chain (environment = production|staging|demo, from the prod-*/staging-*/demo- chain name):
///   - v1.3 Nexus infra + periphery: v2-core output
///       ../v2-core/script/output/<v2coreEnvDir>/<chainId>/<ChainName>-latest.json
///       (v2coreEnvDir: production -> "prod", otherwise the environment name)
///       keys: NexusAccountFactory, NexusBootstrap, SuperDestinationValidator, SuperExecutor, SuperDestinationExecutor
///   - v2.2.3 Nexus infra: this repo's Nexus deployment output
///       script/bash-deploy/deployment/<environment>/<chainId>/<ChainName>.json
///       keys: NexusAccountFactory, NexusBootstrap
///   Periphery from the same environment is reused for v2.2.3.
///
/// Salt convention (both versions): keccak256( lowercaseHex(owner) ++ decimal(index) ),
///   index 0=Primary, 1=Companion, 2=EIP-7702, 3=EOA signer — see AccountResolver.saltFor.
contract DeployAccountResolver is Script {
    mapping(uint64 => string) public chainNames;

    function setUp() public {
        chainNames[1] = "Ethereum";
        chainNames[10] = "Optimism";
        chainNames[8453] = "Base";
        chainNames[137] = "Polygon";
        chainNames[42_161] = "Arbitrum";
        chainNames[43_114] = "Avalanche";
        chainNames[56] = "BNB";
        chainNames[130] = "Unichain";
        chainNames[80_094] = "Berachain";
        chainNames[146] = "Sonic";
        chainNames[100] = "Gnosis";
        chainNames[480] = "Worldchain";
        chainNames[999] = "HyperEVM";
        chainNames[14] = "Flare";
        chainNames[988] = "Stable";
        chainNames[4663] = "RH";
    }

    /// @notice Preview the version config that would be deployed for `environment` (no broadcast).
    function run(string memory environment) external view {
        AccountResolver.Version[] memory versions = _loadVersions(environment);
        console2.log("=== AccountResolver config for environment:", environment, "===");
        _logVersion(versions[0]);
        _logVersion(versions[1]);
    }

    /// @notice Deploy AccountResolver for `environment` and write its address to the deployment folder.
    function runDeploy(string memory environment) external returns (AccountResolver resolver) {
        AccountResolver.Version[] memory versions = _loadVersions(environment);

        vm.startBroadcast();
        resolver = new AccountResolver(versions);
        vm.stopBroadcast();

        console2.log("AccountResolver deployed at:", address(resolver));
        _logVersion(versions[0]);
        _logVersion(versions[1]);

        _writeDeployment(address(resolver), uint64(block.chainid), environment);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _loadVersions(string memory environment)
        internal
        view
        returns (AccountResolver.Version[] memory versions)
    {
        string memory chainName = chainNames[uint64(block.chainid)];
        require(bytes(chainName).length > 0, "Chain name not configured");
        string memory id = vm.toString(block.chainid);
        string memory root = vm.projectRoot();

        // v2-core output (v1.3 infra + periphery) for this environment
        string memory a = vm.readFile(
            string.concat(
                root, "/../v2-core/script/output/", _v2coreEnvDir(environment), "/", id, "/", chainName, "-latest.json"
            )
        );
        // this repo's Nexus deployment (v2.2.3 infra)
        string memory b = vm.readFile(
            string.concat(root, "/script/bash-deploy/deployment/", environment, "/", id, "/", chainName, ".json")
        );

        address destinationValidator = vm.parseJsonAddress(a, ".SuperDestinationValidator");
        address[] memory executors = new address[](2);
        executors[0] = vm.parseJsonAddress(a, ".SuperExecutor");
        executors[1] = vm.parseJsonAddress(a, ".SuperDestinationExecutor");

        versions = new AccountResolver.Version[](2);
        versions[0] = AccountResolver.Version({
            name: "1.3.0",
            kind: AccountResolver.InitKind.WITH_REGISTRY,
            factory: vm.parseJsonAddress(a, ".NexusAccountFactory"),
            bootstrap: vm.parseJsonAddress(a, ".NexusBootstrap"),
            destinationValidator: destinationValidator,
            executors: executors
        });
        versions[1] = AccountResolver.Version({
            name: "2.2.3",
            kind: AccountResolver.InitKind.NO_REGISTRY,
            factory: vm.parseJsonAddress(b, ".NexusAccountFactory"),
            bootstrap: vm.parseJsonAddress(b, ".NexusBootstrap"),
            destinationValidator: destinationValidator,
            executors: executors
        });

        // Guard: if the v2.2.3 factory equals the v1.3 factory, v2.2.3 has NOT been deployed on this chain
        // (the Nexus JSON still holds the older v1.3 addresses). Wiring it would give two identical versions.
        require(
            versions[1].factory != versions[0].factory,
            "v2.2.3 not deployed on this chain: NexusAccountFactory == v1.3 factory (update the Nexus deployment first)"
        );
        require(versions[1].factory.code.length != 0, "v2.2.3 NexusAccountFactory has no code on this chain");
    }

    /// @dev Maps the bash-deploy environment to the v2-core output directory name.
    function _v2coreEnvDir(string memory environment) internal pure returns (string memory) {
        if (keccak256(bytes(environment)) == keccak256(bytes("production"))) return "prod";
        return environment; // staging -> staging, demo -> demo
    }

    function _writeDeployment(address resolver, uint64 chainId, string memory environment) internal {
        string memory chainName = chainNames[chainId];
        string memory root = vm.projectRoot();
        string memory folder = string.concat(
            "/script/bash-deploy/deployment/", environment, "/", vm.toString(uint256(chainId)), "/"
        );
        vm.createDir(string.concat(root, folder), true);

        string memory objectKey = string.concat("RESOLVER_EXPORT_", vm.toString(uint256(chainId)));
        string memory json = vm.serializeAddress(objectKey, "AccountResolver", resolver);
        string memory outputPath = string.concat(root, folder, chainName, "-AccountResolver.json");
        vm.writeJson(json, outputPath);
        console2.log("Exported AccountResolver to:", outputPath);
    }

    function _logVersion(AccountResolver.Version memory v) internal pure {
        console2.log("  version:", v.name);
        console2.log("    factory   :", v.factory);
        console2.log("    bootstrap :", v.bootstrap);
        console2.log("    destValidator:", v.destinationValidator);
        console2.log("    executor[0]:", v.executors[0]);
        console2.log("    executor[1]:", v.executors[1]);
    }
}
