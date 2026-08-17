// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { AccountResolver } from "../../../contracts/resolver/AccountResolver.sol";

/// @title AccountResolverSaltForkTest
/// @notice Verifies the resolver reproduces a REAL account using its OWN salt derivation from (owner, index),
///         pinned to the example tx on Base:
///           https://basescan.org/tx/0x45945f3bcd4d37b6c1b06fbc9a0fc2723e61d89e4f57f21d8d0a749f830e7e1c
///         owner   = 0xbb0618683e84d69ccee2c81f640f98c5fa364303
///         index   = 0 (Primary)
///         account = 0xfe67C05aC97441518251629A5dC3884D0D74188e
///         This account was created on the STAGING v1.3 set (factory 0x4fb71F02...). Both the recipe
///         (WITH_REGISTRY) and the salt formula keccak256(lowerHex(owner)++decimal(index)) are exercised.
contract AccountResolverSaltForkTest is Test {
    AccountResolver internal resolver;

    address constant OWNER = 0xbB0618683e84D69CcEE2c81f640f98c5fa364303;
    address constant EXPECTED_ACCOUNT = 0xfe67C05aC97441518251629A5dC3884D0D74188e;

    // STAGING v1.3 set on Base (v2-core/script/output/staging/8453/Base-latest.json)
    address constant FACTORY = 0x4fb71F028D424358B27877fb3d9F481cf10D1C63;
    address constant BOOTSTRAP = 0x3BF33e679b933446292b95F27186DCDB68492CD0;
    address constant SUPER_DESTINATION_VALIDATOR = 0xCA9bB3fcDfB455962ee284A189CbFc2262970b39;
    address constant SUPER_EXECUTOR = 0xdC903190CF37993e970aA0b15cCC6e08EA12BCa0;
    address constant SUPER_DESTINATION_EXECUTOR = 0xd0B5d200a6B136D619Dd1c7BBA30b004b4773C40;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpcUrl);

        address[] memory executors = new address[](2);
        executors[0] = SUPER_EXECUTOR;
        executors[1] = SUPER_DESTINATION_EXECUTOR;

        AccountResolver.Version[] memory versions = new AccountResolver.Version[](1);
        versions[0] = AccountResolver.Version({
            name: "1.3.0-staging",
            kind: AccountResolver.InitKind.WITH_REGISTRY,
            factory: FACTORY,
            bootstrap: BOOTSTRAP,
            destinationValidator: SUPER_DESTINATION_VALIDATOR,
            executors: executors
        });
        resolver = new AccountResolver(versions);
    }

    /// @dev The salt derivation matches the on-chain account exactly.
    function test_SaltFor_MatchesExampleTxSalt() public view {
        assertEq(
            resolver.saltFor(OWNER, 0),
            0xbb3f944237dfc16affbab094cf7b86ae2f4d9e7979bc1763c86385e1a652d6a6,
            "saltFor(owner,0) must equal the example tx salt"
        );
    }

    /// @dev End-to-end: resolver derives the salt AND reproduces the real deployed account from (owner, index).
    function test_AccountForIndex_ReproducesRealAccount() public {
        AccountResolver.Account memory got = resolver.accountForIndex(OWNER, 0, 0); // version 0, Primary

        emit log_named_address("resolver output   ", got.account);
        emit log_named_address("tx-produced account", EXPECTED_ACCOUNT);
        emit log_named_bytes32("salt derived by resolver", resolver.saltFor(OWNER, 0));

        assertEq(got.account, EXPECTED_ACCOUNT, "resolver must reproduce the real account from (owner, index)");
        assertEq(got.deployed, true, "the real account is deployed");
    }

    /// @dev Same result WITHOUT the formula: pass the tx's literal salt straight into accountFor(owner, version, salt).
    function test_RawSalt_FromTx_ReproducesRealAccount() public {
        bytes32 txSalt = 0xbb3f944237dfc16affbab094cf7b86ae2f4d9e7979bc1763c86385e1a652d6a6; // the exact salt in the tx
        AccountResolver.Account memory got = resolver.accountFor(OWNER, 0, txSalt);

        emit log_named_address("resolver output (raw salt)", got.account);
        emit log_named_address("tx-produced account       ", EXPECTED_ACCOUNT);

        assertEq(got.account, EXPECTED_ACCOUNT, "raw tx salt must reproduce the real account");
        assertEq(got.deployed, true, "the real account is deployed");
    }

    /// @dev Shows CONCRETELY that the prod-labeled set does NOT reproduce this account: it was created by the
    ///      staging factory. This is the evidence for which address set the prod resolver must use.
    function test_ProdSetDoesNotReproduceThisAccount() public {
        address[] memory prodExec = new address[](2);
        prodExec[0] = 0x9cC8EDCC41154aaFC74D261aD3D87140D21F6281; // prod SuperExecutor
        prodExec[1] = 0x6ac58e854798D4aae5989B18ad5a1C0fF17817EF; // prod SuperDestinationExecutor

        AccountResolver.Version[] memory versions = new AccountResolver.Version[](1);
        versions[0] = AccountResolver.Version({
            name: "1.3.0-prod",
            kind: AccountResolver.InitKind.WITH_REGISTRY,
            factory: 0x4153Db38136E74a88A77b51a955A88823820C050, // prod factory
            bootstrap: 0x5eBeb4d51723bA345080D81bBF178D93E84bC9BE, // prod bootstrap
            destinationValidator: 0xADEFF5A0684392C4c273a9C638d1dB8c5dfd0098, // prod SuperDestinationValidator
            executors: prodExec
        });
        AccountResolver prodResolver = new AccountResolver(versions);

        address prodAddr = prodResolver.accountForIndex(OWNER, 0, 0).account;
        emit log_named_address("prod-set address for this owner/index", prodAddr);
        emit log_named_address("actual (staging) account", EXPECTED_ACCOUNT);
        assertTrue(prodAddr != EXPECTED_ACCOUNT, "prod set computes a DIFFERENT address than the real account");
    }

    /// @dev Different index roles (Primary/Companion/7702/EOA-signer) resolve to different addresses.
    function test_IndexRolesAreDistinct() public view {
        address primary = resolver.accountForIndex(OWNER, 0, 0).account;
        address companion = resolver.accountForIndex(OWNER, 0, 1).account;
        address eip7702 = resolver.accountForIndex(OWNER, 0, 2).account;
        address eoaSigner = resolver.accountForIndex(OWNER, 0, 3).account;
        assertTrue(primary != companion && companion != eip7702 && eip7702 != eoaSigner, "roles must be distinct");
        assertEq(primary, EXPECTED_ACCOUNT, "primary (index 0) is the verified account");
    }
}
