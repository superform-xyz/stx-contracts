// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import {
    AccountResolver,
    BootstrapConfig,
    BootstrapPreValidationHookConfig,
    IBootstrapNoRegistry
} from "../../../contracts/resolver/AccountResolver.sol";

interface IFactoryCreate {
    function createAccount(bytes calldata initData, bytes32 salt) external payable returns (address payable);
}

interface IAccountOwner {
    function getAccountOwner(address account) external view returns (address);
}

/// @title AccountResolverForkTest
/// @notice Pins the resolver to a REAL Superform Nexus account on Base and asserts it reproduces the address
///         byte-for-byte from (owner, salt). This is the correctness proof: it exercises the live factory,
///         bootstrap and module set, not a mock.
///
///         Ground truth (Base mainnet), verified via computeAccountAddress(initData, salt):
///           account   = 0xd8A0007C5525E69238Db771dc0cBDe68f2aCE742
///           owner     = 0x0c48c1fAb340b8f9732A864cF913DAD4c75810d5
///           salt      = 0x6391bc1d9da455c799bf6a7f0b2df137eb5c7ae0d0ad32c0b86f2f590e1b7690
///           factory   = 0x4153Db38136E74a88A77b51a955A88823820C050
///           bootstrap = 0x5eBeb4d51723bA345080D81bBF178D93E84bC9BE
///           validators[0]  = SuperDestinationValidator 0xADEFF5A0684392C4c273a9C638d1dB8c5dfd0098
///           executors      = [ SuperExecutor 0x9cC8EDCC41154aaFC74D261aD3D87140D21F6281,
///                              SuperDestinationExecutor 0x6ac58e854798D4aae5989B18ad5a1C0fF17817EF ]
contract AccountResolverForkTest is Test {
    AccountResolver internal resolver;

    address constant EXPECTED_ACCOUNT = 0xd8A0007C5525E69238Db771dc0cBDe68f2aCE742;
    address constant OWNER = 0x0c48c1fAb340b8f9732A864cF913DAD4c75810d5;
    bytes32 constant SALT = 0x6391bc1d9da455c799bf6a7f0b2df137eb5c7ae0d0ad32c0b86f2f590e1b7690;

    // v1.3 (current production) set — VERIFIED against the real account above
    address constant FACTORY = 0x4153Db38136E74a88A77b51a955A88823820C050;
    address constant BOOTSTRAP = 0x5eBeb4d51723bA345080D81bBF178D93E84bC9BE;
    address constant SUPER_DESTINATION_VALIDATOR = 0xADEFF5A0684392C4c273a9C638d1dB8c5dfd0098;
    address constant SUPER_EXECUTOR = 0x9cC8EDCC41154aaFC74D261aD3D87140D21F6281;
    address constant SUPER_DESTINATION_EXECUTOR = 0x6ac58e854798D4aae5989B18ad5a1C0fF17817EF;

    // v2.2.3 set — factory/bootstrap are live on Base, but NO real user account exists yet to verify the recipe.
    // Assumption (flagged): v2.2.3 user accounts use the SAME rich recipe and SAME periphery
    // (SuperDestinationValidator + executors) as v1.3, differing only in factory/bootstrap. Confirm with the
    // backend, or re-pin once a real v2.2.3 user account is created. NOTE: the only on-chain v2.2.3 account so
    // far is a deploy-script placeholder created with a BARE initNexusWithDefaultValidator — if the backend
    // actually creates v2.2.3 user accounts with that bare init, the recipe differs and this must be revisited.
    address constant FACTORY_V223 = 0xbc1b12c1ff47EEBf7FE5dfaE593bf050e5dA4294;
    address constant BOOTSTRAP_V223 = 0xb2b3Eef53a05355B1e0C4862122f6a2aD863897D;

    function setUp() public {
        // Fork latest so BOTH factories are live (v2.2.3 was deployed later than the v1.3 account).
        // Repo convention: BASE_RPC_URL env var with a public fallback (see test/fork/nexus/base/BaseSettings.t.sol)
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpcUrl);

        address[] memory executors = new address[](2);
        executors[0] = SUPER_EXECUTOR;
        executors[1] = SUPER_DESTINATION_EXECUTOR;

        AccountResolver.Version[] memory versions = new AccountResolver.Version[](2);
        versions[0] = AccountResolver.Version({
            name: "1.3.0",
            kind: AccountResolver.InitKind.WITH_REGISTRY, // 7-arg init (verified against the real account)
            factory: FACTORY,
            bootstrap: BOOTSTRAP,
            destinationValidator: SUPER_DESTINATION_VALIDATOR,
            executors: executors
        });
        versions[1] = AccountResolver.Version({
            name: "2.2.3",
            kind: AccountResolver.InitKind.NO_REGISTRY, // v2.2.3 bootstrap dropped the trailing RegistryConfig
            factory: FACTORY_V223,
            bootstrap: BOOTSTRAP_V223,
            destinationValidator: SUPER_DESTINATION_VALIDATOR, // shared periphery
            executors: executors
        });
        resolver = new AccountResolver(versions);
    }

    /// @dev The single load-bearing assertion: resolver reproduces a real deployed account from (owner, salt).
    function test_Fork_ReproducesRealAccount() public view {
        AccountResolver.Account memory got = resolver.accountFor(OWNER, 0, SALT);
        assertEq(got.account, EXPECTED_ACCOUNT, "resolver must reproduce the real account address");
        assertEq(got.deployed, true, "the real account is deployed");
        assertEq(got.name, "1.3.0");
    }

    function test_Fork_WrongSaltDoesNotMatch() public view {
        AccountResolver.Account memory got = resolver.accountFor(OWNER, 0, bytes32(uint256(SALT) + 1));
        assertTrue(got.account != EXPECTED_ACCOUNT, "different salt must yield a different address");
        assertEq(got.deployed, false, "that address is not deployed");
    }

    function test_Fork_WrongOwnerDoesNotMatch() public view {
        AccountResolver.Account memory got = resolver.accountFor(address(0xBEEF), 0, SALT);
        assertTrue(got.account != EXPECTED_ACCOUNT, "different owner must yield a different address");
    }

    function test_Fork_AccountsFor_AllVersions() public view {
        AccountResolver.Account[] memory all = resolver.accountsFor(OWNER, SALT);
        assertEq(all.length, 2);
        // version 0 = v1.3, verified real account
        assertEq(all[0].name, "1.3.0");
        assertEq(all[0].account, EXPECTED_ACCOUNT);
        assertEq(all[0].deployed, true);
        // version 1 = v2.2.3
        assertEq(all[1].name, "2.2.3");
    }

    /// @dev v2.2.3 factory is live, so the resolver computes a deterministic non-zero address for it.
    ///      It differs from v1.3 (different factory/bootstrap => different account).
    function test_Fork_V223_ResolvesLiveAndDistinct() public view {
        AccountResolver.Account memory v13 = resolver.accountFor(OWNER, 0, SALT);
        AccountResolver.Account memory v223 = resolver.accountFor(OWNER, 1, SALT);

        assertTrue(v223.account != address(0), "v2.2.3 factory is live => non-zero address");
        assertTrue(v223.account != v13.account, "v2.2.3 must resolve to a different address than v1.3");
    }

    /// @dev End-to-end proof for v2.2.3: predict with the resolver, actually CREATE the account via the live
    ///      v2.2.3 factory using the same recipe, and assert (a) the created address equals the prediction and
    ///      (b) the account is a correctly-configured Superform account (SuperDestinationValidator holds the owner).
    function test_Fork_V223_CreateAndVerify() public {
        address owner = 0x22BC97cFac64D6d9BCaDF5dC36e4D01Db9e929c5; // deployer
        bytes32 salt = keccak256("account-resolver-v223-e2e");

        // 1) predict, and confirm it is not yet deployed
        AccountResolver.Account memory pre = resolver.accountFor(owner, 1, salt);
        assertTrue(pre.account != address(0), "prediction must be non-zero");
        assertEq(pre.deployed, false, "not deployed before creation");

        // 2) build the v2.2.3 (no-registry) initData the same way the resolver does, and create the account
        bytes memory initData = _buildV223InitData(owner);
        address created = IFactoryCreate(FACTORY_V223).createAccount(initData, salt);

        // 3) resolver predicted the real deployment address
        assertEq(created, pre.account, "resolver prediction must equal the actually-created account");

        // 4) resolver now reports it deployed
        AccountResolver.Account memory post = resolver.accountFor(owner, 1, salt);
        assertEq(post.deployed, true, "deployed flag flips after creation");

        // 5) the account is genuinely configured: SuperDestinationValidator returns the owner
        assertEq(
            IAccountOwner(SUPER_DESTINATION_VALIDATOR).getAccountOwner(created),
            owner,
            "SuperDestinationValidator must hold the owner => valid Superform account"
        );
    }

    function _buildV223InitData(address owner) internal pure returns (bytes memory) {
        bytes memory ownerData = abi.encode(owner);

        BootstrapConfig[] memory validators = new BootstrapConfig[](1);
        validators[0] = BootstrapConfig({ module: SUPER_DESTINATION_VALIDATOR, data: ownerData });

        BootstrapConfig[] memory execs = new BootstrapConfig[](2);
        execs[0] = BootstrapConfig({ module: SUPER_EXECUTOR, data: "" });
        execs[1] = BootstrapConfig({ module: SUPER_DESTINATION_EXECUTOR, data: "" });

        BootstrapConfig memory hook = BootstrapConfig({ module: address(0), data: "" });
        BootstrapConfig[] memory fallbacks = new BootstrapConfig[](0);
        BootstrapPreValidationHookConfig[] memory pvh = new BootstrapPreValidationHookConfig[](0);

        bytes memory bootstrapCall = abi.encodeCall(
            IBootstrapNoRegistry.initNexusWithDefaultValidatorAndOtherModules,
            (ownerData, validators, execs, hook, fallbacks, pvh)
        );
        return abi.encode(BOOTSTRAP_V223, bootstrapCall);
    }
}
