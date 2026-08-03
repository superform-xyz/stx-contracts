// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { Script, console2 } from "node_modules/forge-std/src/Script.sol";
import { DeterministicDeployerLib } from "script/deploy/util/DeterministicDeployerLib.sol";
import { NexusAccountFactory } from "contracts/nexus/factory/NexusAccountFactory.sol";
import { NexusBootstrap } from "contracts/nexus/utils/NexusBootstrap.sol";

contract DeployNexus is Script {
    uint256 deployed;
    uint256 total;

    // Contract address tracking per chain
    mapping(uint64 chainId => mapping(string contractName => address contractAddress)) public contractAddresses;

    // Contract export tracking
    mapping(uint64 => string) private exportedContracts;
    mapping(uint64 => uint256) private contractCount;

    // Environment and chain name mappings
    mapping(uint64 => string) public chainNames;

    address public constant REGISTRY_ADDRESS = 0x000000000069E2a187AEFFb852bF3cCdC95151B2;
    address public constant EP_V07_ADDRESS = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address public constant eEeEeAddress = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // NEXUS CONTRACTS DEPLOYMENT SALTS
    bytes32 constant NEXUS_SALT = 0x0000000000000000000000000000000000000000f036b687a1f82003988bd953;

    bytes32 constant NEXUSBOOTSTRAP_SALT = 0x000000000000000000000000000000000000000069b8a8e8fec67700be0ca325;

    bytes32 constant NEXUS_ACCOUNT_FACTORY_SALT = 0x0000000000000000000000000000000000000000e289724d34a3660389fc1ab0;

    address internal defaultValidator; // Set via script argument

    function setUp() public {
        // Initialize chain name mappings (matches S3 format with proper case)
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
    }

    function run(bool check, address defaultValidator_) public {
        defaultValidator = defaultValidator_;
        if (check) {
            checkNexusAddress();
        } else {
            deployNexus();
        }
    }

    function checkNexusAddress() internal {
        // ======== Nexus ========

        bytes32 salt = NEXUS_SALT;
        bytes memory bytecode = vm.getCode("script/bash-deploy/artifacts/Nexus/Nexus.json");
        // v2.2.3: default validator init data is packed 20 bytes (K1MeeValidator.onInstall reads data[:20])
        bytes memory args = abi.encode(EP_V07_ADDRESS, defaultValidator, abi.encodePacked(eEeEeAddress));
        address nexus = DeterministicDeployerLib.computeAddress(bytecode, args, salt);
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(nexus)
        }
        checkDeployed(codeSize);
        console2.log("Nexus Addr: ", nexus, " || >> Code Size: ", codeSize);
        console2.logBytes(args);
        console2.logBytes32(keccak256(abi.encodePacked(bytecode, args)));

        // ======== NexusBootstrap ========

        salt = NEXUSBOOTSTRAP_SALT;
        bytecode = vm.getCode("script/bash-deploy/artifacts/NexusBootstrap/NexusBootstrap.json");
        args = abi.encode(defaultValidator, abi.encodePacked(eEeEeAddress));
        address bootstrap = DeterministicDeployerLib.computeAddress(bytecode, args, salt);
        assembly {
            codeSize := extcodesize(bootstrap)
        }
        checkDeployed(codeSize);
        console2.log("Nexus Bootstrap Addr: ", bootstrap, " || >> Code Size: ", codeSize);
        console2.logBytes(args);
        console2.logBytes32(keccak256(abi.encodePacked(bytecode, args)));

        // ======== NexusAccountFactory ========

        salt = NEXUS_ACCOUNT_FACTORY_SALT;
        bytecode = vm.getCode("script/bash-deploy/artifacts/NexusAccountFactory/NexusAccountFactory.json");
        args = abi.encode(
            nexus, // implementation
            address(0x129443cA2a9Dec2020808a2868b38dDA457eaCC7) // factory owner
        );
        address nexusAccountFactory = DeterministicDeployerLib.computeAddress(bytecode, args, salt);
        assembly {
            codeSize := extcodesize(nexusAccountFactory)
        }
        checkDeployed(codeSize);
        console2.log("Nexus Account Factory Addr: ", nexusAccountFactory, " || >> Code Size: ", codeSize);
        console2.logBytes(args);
        console2.logBytes32(keccak256(abi.encodePacked(bytecode, args)));
        console2.log("=====> On this chain we have", deployed, " contracts already deployed out of ", total);
    }

    // #########################################################################################
    // ################## DEPLOYMENT ##################
    // #########################################################################################

    function deployNexus() internal {
        // ======== Nexus ========

        bytes32 salt = NEXUS_SALT;
        bytes memory bytecode = vm.getCode("script/bash-deploy/artifacts/Nexus/Nexus.json");
        bytes memory args = abi.encode(EP_V07_ADDRESS, defaultValidator, abi.encodePacked(eEeEeAddress));
        address nexus = DeterministicDeployerLib.computeAddress(bytecode, args, salt);

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(nexus)
        }
        if (codeSize > 0) {
            console2.log("Nexus already deployed at: ", nexus, " skipping deployment");
        } else {
            nexus = DeterministicDeployerLib.broadcastDeploy(bytecode, args, salt);
            console2.log("Nexus deployed at: %s. Default validator: %s", nexus, defaultValidator);
        }

        // Export Nexus contract
        _exportContract("Nexus", nexus, uint64(block.chainid));

        // ======== NexusBootstrap ========

        salt = NEXUSBOOTSTRAP_SALT;
        bytecode = vm.getCode("script/bash-deploy/artifacts/NexusBootstrap/NexusBootstrap.json");
        args = abi.encode(defaultValidator, abi.encodePacked(eEeEeAddress));
        address bootstrap = DeterministicDeployerLib.computeAddress(bytecode, args, salt);
        assembly {
            codeSize := extcodesize(bootstrap)
        }
        if (codeSize > 0) {
            console2.log("Nexus Bootstrap already deployed at: ", bootstrap, " skipping deployment");
        } else {
            bootstrap = DeterministicDeployerLib.broadcastDeploy(bytecode, args, salt);
            console2.log("Nexus Bootstrap deployed at: ", bootstrap);
        }

        // Export NexusBootstrap contract
        _exportContract("NexusBootstrap", bootstrap, uint64(block.chainid));

        // ======== NexusAccountFactory ========

        salt = NEXUS_ACCOUNT_FACTORY_SALT;
        bytecode = vm.getCode("script/bash-deploy/artifacts/NexusAccountFactory/NexusAccountFactory.json");
        args = abi.encode(
            nexus, // implementation
            address(0x129443cA2a9Dec2020808a2868b38dDA457eaCC7) // factory owner
        );
        address nexusAccountFactory = DeterministicDeployerLib.computeAddress(bytecode, args, salt);
        assembly {
            codeSize := extcodesize(nexusAccountFactory)
        }
        if (codeSize > 0) {
            console2.log("Nexus Account Factory already deployed at: ", nexusAccountFactory, " skipping deployment");
        } else {
            nexusAccountFactory = DeterministicDeployerLib.broadcastDeploy(bytecode, args, salt);
            console2.log("Nexus Account Factory deployed at: ", nexusAccountFactory);
        }

        // Export NexusAccountFactory contract
        _exportContract("NexusAccountFactory", nexusAccountFactory, uint64(block.chainid));

        // ======== NexusProxy ========

        salt = 0x0000000000000000000000000000000000000000000000000000000000000001;
        bytes memory initData = abi.encode(
            bootstrap,
            abi.encodeWithSelector(
                NexusBootstrap.initNexusWithDefaultValidator.selector, abi.encodePacked(eEeEeAddress)
            )
        );
        vm.startBroadcast();
        address nexusProxy = NexusAccountFactory(nexusAccountFactory).createAccount(initData, salt);
        vm.stopBroadcast();
        console2.log("Nexus Proxy deployed at: ", nexusProxy);

        // Export NexusProxy contract
        _exportContract("NexusProxy", nexusProxy, uint64(block.chainid));
    }

    function checkDeployed(uint256 codeSize) internal {
        if (codeSize > 0) {
            deployed++;
        }
        total++;
    }

    /// @notice Export a contract address for JSON serialization
    /// @param contractName Name of the contract
    /// @param addr Address of the contract
    /// @param chainId Chain ID
    function _exportContract(string memory contractName, address addr, uint64 chainId) internal {
        contractCount[chainId]++;
        string memory objectKey = string(abi.encodePacked("NEXUS_EXPORTS_", vm.toString(uint256(chainId))));
        exportedContracts[chainId] = vm.serializeAddress(objectKey, contractName, addr);

        // Store in mapping for reference
        contractAddresses[chainId][contractName] = addr;

        console2.log("Exported %s: %s for chain %d", contractName, addr, chainId);
    }

    /// @notice Write exported contracts to environment-specific JSON files
    /// @param chainId Chain ID
    /// @param environment Environment name (main, demo, staging, production)
    function _writeExportedContracts(uint64 chainId, string memory environment) internal {
        if (contractCount[chainId] == 0) return;

        string memory chainName = chainNames[chainId];
        require(bytes(chainName).length > 0, "Chain name not configured");

        string memory root = vm.projectRoot();
        string memory deploymentFolder = string(
            abi.encodePacked("/script/bash-deploy/deployment/", environment, "/", vm.toString(uint256(chainId)), "/")
        );

        // Create directory if it doesn't exist
        vm.createDir(string(abi.encodePacked(root, deploymentFolder)), true);

        // Write to {chainName}.json (e.g., ethereum.json, optimism.json)
        string memory outputPath = string(abi.encodePacked(root, deploymentFolder, chainName, ".json"));
        vm.writeJson(exportedContracts[chainId], outputPath);

        console2.log("Exported %d contracts to: %s", contractCount[chainId], outputPath);
    }

    /// @notice Get environment from chain name prefix
    /// @param chainNameInput Chain name with environment prefix (e.g., "main-ethereum", "demo-base")
    /// @return environment The environment name
    function _getEnvironmentFromChainName(string memory chainNameInput)
        internal
        pure
        returns (string memory environment)
    {
        bytes memory chainBytes = bytes(chainNameInput);

        // Check for main- prefix
        if (
            chainBytes.length >= 5 && chainBytes[0] == "m" && chainBytes[1] == "a" && chainBytes[2] == "i"
                && chainBytes[3] == "n" && chainBytes[4] == "-"
        ) {
            return "main";
        }

        // Check for demo- prefix
        if (
            chainBytes.length >= 5 && chainBytes[0] == "d" && chainBytes[1] == "e" && chainBytes[2] == "m"
                && chainBytes[3] == "o" && chainBytes[4] == "-"
        ) {
            return "demo";
        }

        // Check for staging- prefix
        if (
            chainBytes.length >= 8 && chainBytes[0] == "s" && chainBytes[1] == "t" && chainBytes[2] == "a"
                && chainBytes[3] == "g" && chainBytes[4] == "i" && chainBytes[5] == "n" && chainBytes[6] == "g"
                && chainBytes[7] == "-"
        ) {
            return "staging";
        }

        // Default to production for standalone chain names
        return "production";
    }

    /// @notice Deploy and export contracts
    /// @param environment Environment name
    /// @param defaultValidator_ Default validator address
    function runDeploy(string memory environment, address defaultValidator_) public {
        defaultValidator = defaultValidator_;
        deployNexus();
        _writeExportedContracts(uint64(block.chainid), environment);
    }
}
