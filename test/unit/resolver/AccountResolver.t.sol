// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { AccountResolver } from "../../../contracts/resolver/AccountResolver.sol";

/// @dev Deterministic stand-in for NexusAccountFactory.computeAccountAddress — returns a hash of the inputs so
///      the resolver's plumbing (per-version dispatch, batch shapes, reverts, deployed flag) can be tested
///      without a fork. Correctness of the actual address recipe is proven in AccountResolverFork.t.sol.
contract MockFactory {
    function computeAccountAddress(bytes calldata initData, bytes32 salt) external view returns (address payable) {
        return payable(address(uint160(uint256(keccak256(abi.encode(address(this), initData, salt))))));
    }
}

contract AccountResolverTest is Test {
    AccountResolver internal resolver;
    MockFactory internal fa;
    MockFactory internal fb;

    address constant OWNER = address(0xA11CE);
    bytes32 constant SALT = keccak256("salt");

    function setUp() public {
        fa = new MockFactory();
        fb = new MockFactory();

        address[] memory execA = new address[](2);
        execA[0] = address(0x1111);
        execA[1] = address(0x2222);
        address[] memory execB = new address[](1);
        execB[0] = address(0x3333);

        AccountResolver.Version[] memory versions = new AccountResolver.Version[](2);
        versions[0] = AccountResolver.Version({
            name: "vA",
            kind: AccountResolver.InitKind.WITH_REGISTRY,
            factory: address(fa),
            bootstrap: address(0xB0),
            destinationValidator: address(0xDA),
            executors: execA
        });
        versions[1] = AccountResolver.Version({
            name: "vB",
            kind: AccountResolver.InitKind.NO_REGISTRY,
            factory: address(fb),
            bootstrap: address(0xB1),
            destinationValidator: address(0xDB),
            executors: execB
        });
        resolver = new AccountResolver(versions);
    }

    function test_VersionCount() public view {
        assertEq(resolver.versionCount(), 2);
        assertEq(resolver.version(0).name, "vA");
        assertEq(resolver.version(1).name, "vB");
    }

    function test_AccountFor_MatchesFactory() public view {
        AccountResolver.Account memory got = resolver.accountFor(OWNER, 0, SALT);
        // recompute the expected address the same way the resolver builds it is covered by the fork test;
        // here just assert it is deterministic, version-tagged, and not falsely marked deployed
        assertTrue(got.account != address(0));
        assertEq(got.versionId, 0);
        assertEq(got.name, "vA");
        assertEq(got.deployed, false); // mock factory output has no code
    }

    function test_VersionsProduceDifferentAddresses() public view {
        // different factory + module set per version => different addresses
        assertTrue(resolver.accountFor(OWNER, 0, SALT).account != resolver.accountFor(OWNER, 1, SALT).account);
    }

    function test_SaltChangesAddress() public view {
        assertTrue(
            resolver.accountFor(OWNER, 0, SALT).account != resolver.accountFor(OWNER, 0, keccak256("other")).account
        );
    }

    function test_OwnerChangesAddress() public view {
        assertTrue(resolver.accountFor(OWNER, 0, SALT).account != resolver.accountFor(address(0xB0B), 0, SALT).account);
    }

    function test_AccountsFor_AllVersions() public view {
        AccountResolver.Account[] memory all = resolver.accountsFor(OWNER, SALT);
        assertEq(all.length, 2);
        assertEq(all[0].name, "vA");
        assertEq(all[1].name, "vB");
    }

    function test_AccountsForOwners_Batch() public view {
        address[] memory owners = new address[](2);
        owners[0] = OWNER;
        owners[1] = address(0xB0B);
        AccountResolver.Account[][] memory res = resolver.accountsForOwners(owners, SALT);
        assertEq(res.length, 2);
        assertEq(res[0][0].account, resolver.accountFor(OWNER, 0, SALT).account);
        assertEq(res[1][0].account, resolver.accountFor(address(0xB0B), 0, SALT).account);
    }

    function test_AccountsForSalts_Enumeration() public view {
        bytes32[] memory salts = new bytes32[](2);
        salts[0] = SALT;
        salts[1] = keccak256("second");
        AccountResolver.Account[][] memory res = resolver.accountsForSalts(OWNER, salts);
        assertEq(res.length, 2);
        assertTrue(res[0][0].account != res[1][0].account);
    }

    function test_UnreachableFactory_ReturnsZero() public {
        // Version whose factory has no code: computeAccountAddress call reverts -> address(0), deployed false
        AccountResolver.Version[] memory versions = new AccountResolver.Version[](1);
        address[] memory noExec = new address[](0);
        versions[0] = AccountResolver.Version({
            name: "dead",
            kind: AccountResolver.InitKind.WITH_REGISTRY,
            factory: address(0xDEAD),
            bootstrap: address(0xB0),
            destinationValidator: address(0xDA),
            executors: noExec
        });
        AccountResolver r = new AccountResolver(versions);
        AccountResolver.Account memory got = r.accountFor(OWNER, 0, SALT);
        assertEq(got.account, address(0));
        assertEq(got.deployed, false);
    }

    function test_RevertIf_NoVersions() public {
        AccountResolver.Version[] memory empty = new AccountResolver.Version[](0);
        vm.expectRevert(AccountResolver.NoVersions.selector);
        new AccountResolver(empty);
    }

    function test_RevertIf_VersionOutOfRange() public {
        vm.expectRevert(AccountResolver.VersionOutOfRange.selector);
        resolver.accountFor(OWNER, 99, SALT);
    }
}
