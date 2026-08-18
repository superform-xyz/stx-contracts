// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test, console2 } from "forge-std/Test.sol";
import {
    AccountResolver,
    BootstrapConfig,
    BootstrapPreValidationHookConfig,
    RegistryConfig,
    IBootstrapWithRegistry,
    IBootstrapNoRegistry
} from "../../../contracts/resolver/AccountResolver.sol";

interface IFactoryCreate {
    function createAccount(bytes calldata initData, bytes32 salt) external payable returns (address payable);
}

interface INexusAccountId {
    function accountId() external view returns (string memory);
}

/// @title AccountResolverLiveForkTest
/// @notice End-to-end proof against the LIVE production resolver on Base (post Nexus-1.3.3 redeploy):
///         for each configured version, actually CREATE the account through that version's real factory on a
///         fork and assert the address equals what the resolver's view methods predicted. Also asserts the
///         created v2.2.3 account reports biconomy.nexus.1.3.3 (the single-initialization fix).
contract AccountResolverLiveForkTest is Test {
    /// @dev Deployed production resolver on Base (script/bash-deploy/deployment/production/8453)
    AccountResolver constant RESOLVER = AccountResolver(0x23947B15Ce55B3F57a652f606D12019C1574d4b4);

    /// @dev Real prod user (see AccountResolverFork.t.sol) — v1.3 account exists on-chain at index 0
    address constant REAL_OWNER = 0x0c48c1fAb340b8f9732A864cF913DAD4c75810d5;
    address constant REAL_V13_ACCOUNT = 0xd8A0007C5525E69238Db771dc0cBDe68f2aCE742;

    /// @dev Arbitrary owner with no accounts anywhere — exercises fresh creation for both versions
    address constant FRESH_OWNER = 0xBeEf00000000000000000000000000000000ab12;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpcUrl);
    }

    /// @dev Reproduce AccountResolver._buildInitData from the deployed resolver's own version config
    function _initDataFor(AccountResolver.Version memory v, address owner) internal pure returns (bytes memory) {
        bytes memory ownerData = abi.encode(owner);

        BootstrapConfig[] memory validators = new BootstrapConfig[](1);
        validators[0] = BootstrapConfig({ module: v.destinationValidator, data: ownerData });

        BootstrapConfig[] memory executors = new BootstrapConfig[](v.executors.length);
        for (uint256 i; i < v.executors.length; ++i) {
            executors[i] = BootstrapConfig({ module: v.executors[i], data: "" });
        }

        BootstrapConfig memory hook = BootstrapConfig({ module: address(0), data: "" });
        BootstrapConfig[] memory fallbacks = new BootstrapConfig[](0);
        BootstrapPreValidationHookConfig[] memory preValidationHooks = new BootstrapPreValidationHookConfig[](0);

        bytes memory bootstrapCall;
        if (v.kind == AccountResolver.InitKind.WITH_REGISTRY) {
            bootstrapCall = abi.encodeCall(
                IBootstrapWithRegistry.initNexusWithDefaultValidatorAndOtherModules,
                (
                    ownerData,
                    validators,
                    executors,
                    hook,
                    fallbacks,
                    preValidationHooks,
                    RegistryConfig({ registry: address(0), attesters: new address[](0), threshold: 0 })
                )
            );
        } else {
            bootstrapCall = abi.encodeCall(
                IBootstrapNoRegistry.initNexusWithDefaultValidatorAndOtherModules,
                (ownerData, validators, executors, hook, fallbacks, preValidationHooks)
            );
        }
        return abi.encode(v.bootstrap, bootstrapCall);
    }

    function _createAndCompare(address owner, uint256 index) internal {
        bytes32 salt = RESOLVER.saltFor(owner, index);
        AccountResolver.Account[] memory predicted = RESOLVER.accountsFor(owner, salt);
        assertEq(predicted.length, 2, "expected two versions");

        for (uint256 i; i < predicted.length; ++i) {
            AccountResolver.Version memory v = RESOLVER.version(i);
            address created = IFactoryCreate(v.factory).createAccount(_initDataFor(v, owner), salt);

            assertEq(created, predicted[i].account, "createAccount address != resolver prediction");
            assertGt(created.code.length, 0, "created account has no code");

            console2.log("version %s | resolver + factory agree on:", v.name, created);
            console2.log("  account.accountId():", INexusAccountId(created).accountId());
        }
    }

    /// @notice Existing prod user: v1.3 createAccount must return his REAL deployed account; v2.2.3 gets created
    function test_realOwner_bothVersionsMatchResolver() public {
        bytes32 salt = RESOLVER.saltFor(REAL_OWNER, 0);
        AccountResolver.Account[] memory predicted = RESOLVER.accountsFor(REAL_OWNER, salt);
        assertEq(predicted[0].account, REAL_V13_ACCOUNT, "v1.3 prediction != real deployed account");
        assertTrue(predicted[0].deployed, "real v1.3 account must be seen as deployed");

        _createAndCompare(REAL_OWNER, 0);
    }

    /// @notice Brand-new owner: both versions created fresh, addresses must match the resolver
    function test_freshOwner_bothVersionsMatchResolver() public {
        _createAndCompare(FRESH_OWNER, 0);
    }

    /// @notice The v2.2.3 factory must produce accounts running the FIXED Nexus (1.3.3, single-init)
    function test_v223AccountRunsFixedImplementation() public {
        AccountResolver.Version memory v223 = RESOLVER.version(1);
        assertEq(v223.name, "2.2.3");

        bytes32 salt = RESOLVER.saltFor(FRESH_OWNER, 1);
        address created = IFactoryCreate(v223.factory).createAccount(_initDataFor(v223, FRESH_OWNER), salt);
        assertEq(
            INexusAccountId(created).accountId(),
            "biconomy.nexus.1.3.3",
            "v2.2.3 account must run the fixed implementation"
        );
    }
}
