// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { LibString } from "solady/utils/LibString.sol";

/// @dev Mirrors NexusBootstrap's config tuple: (address module, bytes data)
struct BootstrapConfig {
    address module;
    bytes data;
}

/// @dev Mirrors NexusBootstrap's pre-validation hook config: (uint256 hookType, address module, bytes data)
struct BootstrapPreValidationHookConfig {
    uint256 hookType;
    address module;
    bytes data;
}

/// @dev Mirrors NexusBootstrap.RegistryConfig: (IERC7484 registry, address[] attesters, uint8 threshold).
///      `registry` is typed as address here; it abi-encodes identically to the interface type.
struct RegistryConfig {
    address registry;
    address[] attesters;
    uint8 threshold;
}

interface INexusFactoryLike {
    function computeAccountAddress(bytes calldata initData, bytes32 salt) external view returns (address payable);
}

/// @dev The bootstrap entrypoint Superform accounts are created with. The default validator (SuperValidator, baked
///      into the Nexus implementation) is initialized with `defaultValidatorInitData`; SuperDestinationValidator is
///      installed via `validators`; SuperExecutor + SuperDestinationExecutor via `executors`. Superform accounts pass
///      empty hook/fallbacks/preValidationHooks. Two variants exist across versions:
///        - v1.3: 7-arg, trailing RegistryConfig (selector 0x77182ae6)
///        - v2.2.3: 6-arg, no RegistryConfig (registry removed from the bootstrap)
interface IBootstrapWithRegistry {
    function initNexusWithDefaultValidatorAndOtherModules(
        bytes calldata defaultValidatorInitData,
        BootstrapConfig[] calldata validators,
        BootstrapConfig[] calldata executors,
        BootstrapConfig calldata hook,
        BootstrapConfig[] calldata fallbacks,
        BootstrapPreValidationHookConfig[] calldata preValidationHooks,
        RegistryConfig calldata registryConfig
    )
        external;
}

interface IBootstrapNoRegistry {
    function initNexusWithDefaultValidatorAndOtherModules(
        bytes calldata defaultValidatorInitData,
        BootstrapConfig[] calldata validators,
        BootstrapConfig[] calldata executors,
        BootstrapConfig calldata hook,
        BootstrapConfig[] calldata fallbacks,
        BootstrapPreValidationHookConfig[] calldata preValidationHooks
    )
        external;
}

/// @title AccountResolver
/// @author Superform Labs
/// @notice Stateless lens that, given an owner and a deployment salt, returns the deterministic Superform smart-account
///         address for every configured account version in a single call — collapsing many off-chain
///         `computeAccountAddress` RPC round-trips into one `eth_call`, and reporting on-chain existence (`deployed`).
/// @dev Reproduces Superform's exact account-creation recipe (verified on-chain against a live Base account):
///        defaultValidatorInitData = abi.encode(owner)                       // SuperValidator (impl default validator)
///        validators = [ (superDestinationValidator, abi.encode(owner)) ]    // SuperDestinationValidator
///        executors  = [ (executor, "") for executor in executors ]          // SuperExecutor, SuperDestinationExecutor
///        hook = (0,""), fallbacks = [], preValidationHooks = [], registryConfig = (0,[],0)
///        initData = abi.encode(bootstrap, abi.encodeCall(bootstrap.initNexusWithDefaultValidatorAndOtherModules, ...))
///        account  = factory.computeAccountAddress(initData, salt)
///
///      The per-account `salt` is chosen by the account-creation backend and is NOT derivable from the owner, so it is
///      a required parameter. Results are DISCOVERY, not a trust statement — for older versions the returned address
/// is
///      where the canonical account WOULD be, which under the pre-fix factory could have been squatted; pair with an
///      owner-key authorization layer before trusting an old-version address.
///
///      Versions are fixed at construction (no admin setters): the contract is a pure discovery aid, so a new version
///      is served by deploying a new resolver rather than mutating a trusted one.
contract AccountResolver {
    /// @notice Whether a version's bootstrap init takes a trailing RegistryConfig argument
    enum InitKind {
        WITH_REGISTRY, // v1.3 (7-arg)
        NO_REGISTRY // v2.2.3 (6-arg)
    }

    /// @notice Per-version deployment convention (all addresses are chain-specific).
    /// @dev The default validator (SuperValidator) address is not needed: it is baked into the version's Nexus
    ///      implementation and is applied automatically by calling that version's factory.
    struct Version {
        string name; // human-readable, e.g. "1.3.0" / "2.2.3"
        InitKind kind; // bootstrap init variant (registry vs no-registry)
        address factory; // that version's NexusAccountFactory
        address bootstrap; // that version's NexusBootstrap
        address destinationValidator; // SuperDestinationValidator installed via validators[]
        address[] executors; // SuperExecutor, SuperDestinationExecutor (order matters — affects the address)
    }

    /// @notice One resolved account for a given (owner, version, salt)
    struct Account {
        uint256 versionId;
        string name;
        address account;
        bool deployed;
    }

    /// @notice Account index roles used by the salt convention (index 0..3)
    /// @dev PRIMARY, COMPANION, EIP7702, EOA_SIGNER — see saltFor()
    uint256 public constant INDEX_PRIMARY = 0;
    uint256 public constant INDEX_COMPANION = 1;
    uint256 public constant INDEX_EIP7702 = 2;
    uint256 public constant INDEX_EOA_SIGNER = 3;

    error NoVersions();
    error VersionOutOfRange();

    Version[] private _versions;

    constructor(Version[] memory versions_) {
        if (versions_.length == 0) revert NoVersions();
        for (uint256 i; i < versions_.length; ++i) {
            _versions.push(versions_[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of configured versions
    function versionCount() external view returns (uint256) {
        return _versions.length;
    }

    /// @notice Returns the configuration for a given version id
    function version(uint256 versionId) external view returns (Version memory) {
        if (versionId >= _versions.length) revert VersionOutOfRange();
        return _versions[versionId];
    }

    /// @notice The deployment salt for a given (owner, index), per the account-creation convention.
    /// @dev salt = keccak256( lowercaseHex(owner, no "0x") ++ decimal(index) ). Index roles:
    ///      0 = Primary, 1 = Companion, 2 = EIP-7702, 3 = EOA signer. Verified against real prod + staging accounts.
    function saltFor(address owner, uint256 index) public pure returns (bytes32) {
        return keccak256(
            bytes(string.concat(LibString.toHexStringNoPrefix(uint256(uint160(owner)), 20), LibString.toString(index)))
        );
    }

    /// @notice Resolve a single (owner, version, salt)
    function accountFor(address owner, uint256 versionId, bytes32 salt) public view returns (Account memory) {
        if (versionId >= _versions.length) revert VersionOutOfRange();
        return _resolve(_versions[versionId], versionId, owner, salt);
    }

    /// @notice Resolve a single (owner, version, index) — derives the salt via the account convention.
    function accountForIndex(address owner, uint256 versionId, uint256 index) external view returns (Account memory) {
        return accountFor(owner, versionId, saltFor(owner, index));
    }

    /// @notice Resolve an owner across ALL versions at a given account index (derives the salt).
    function accountsForIndex(address owner, uint256 index) external view returns (Account[] memory) {
        return accountsFor(owner, saltFor(owner, index));
    }

    /// @notice Resolve an owner across ALL versions at one salt (the primary backend call)
    function accountsFor(address owner, bytes32 salt) public view returns (Account[] memory out) {
        uint256 n = _versions.length;
        out = new Account[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _resolve(_versions[i], i, owner, salt);
        }
    }

    /// @notice Batch of owners across all versions at one salt. out[i] aligns with owners[i].
    function accountsForOwners(address[] calldata owners, bytes32 salt) external view returns (Account[][] memory out) {
        out = new Account[][](owners.length);
        for (uint256 i; i < owners.length; ++i) {
            out[i] = accountsFor(owners[i], salt);
        }
    }

    /// @notice One owner across all versions for a set of salts (enumerate a user's multiple accounts).
    ///         out[k] holds all versions at salts[k].
    function accountsForSalts(address owner, bytes32[] calldata salts) external view returns (Account[][] memory out) {
        out = new Account[][](salts.length);
        for (uint256 k; k < salts.length; ++k) {
            out[k] = accountsFor(owner, salts[k]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _resolve(
        Version memory v,
        uint256 versionId,
        address owner,
        bytes32 salt
    )
        internal
        view
        returns (Account memory a)
    {
        address account;
        // Keep the lens robust on chains where a given version's factory is not deployed: a call to a codeless
        // address would revert on the ABI return-decode (not caught by try/catch), so guard explicitly first.
        if (v.factory.code.length != 0) {
            bytes memory initData = _buildInitData(v, owner);
            // Delegate to the authoritative factory so the implementation/proxy bytecode is always the version's own.
            try INexusFactoryLike(v.factory).computeAccountAddress(initData, salt) returns (address payable predicted) {
                account = predicted;
            } catch {
                account = address(0);
            }
        }

        a = Account({
            versionId: versionId,
            name: v.name,
            account: account,
            deployed: account != address(0) && account.code.length != 0
        });
    }

    function _buildInitData(Version memory v, address owner) internal pure returns (bytes memory) {
        bytes memory ownerData = abi.encode(owner);

        BootstrapConfig[] memory validators = new BootstrapConfig[](1);
        validators[0] = BootstrapConfig({ module: v.destinationValidator, data: ownerData });

        uint256 execLen = v.executors.length;
        BootstrapConfig[] memory executors = new BootstrapConfig[](execLen);
        for (uint256 i; i < execLen; ++i) {
            executors[i] = BootstrapConfig({ module: v.executors[i], data: "" });
        }

        BootstrapConfig memory hook = BootstrapConfig({ module: address(0), data: "" });
        BootstrapConfig[] memory fallbacks = new BootstrapConfig[](0);
        BootstrapPreValidationHookConfig[] memory preValidationHooks = new BootstrapPreValidationHookConfig[](0);

        bytes memory bootstrapCall;
        if (v.kind == InitKind.WITH_REGISTRY) {
            RegistryConfig memory registryConfig =
                RegistryConfig({ registry: address(0), attesters: new address[](0), threshold: 0 });
            bootstrapCall = abi.encodeCall(
                IBootstrapWithRegistry.initNexusWithDefaultValidatorAndOtherModules,
                (ownerData, validators, executors, hook, fallbacks, preValidationHooks, registryConfig)
            );
        } else {
            bootstrapCall = abi.encodeCall(
                IBootstrapNoRegistry.initNexusWithDefaultValidatorAndOtherModules,
                (ownerData, validators, executors, hook, fallbacks, preValidationHooks)
            );
        }

        return abi.encode(v.bootstrap, bootstrapCall);
    }
}
