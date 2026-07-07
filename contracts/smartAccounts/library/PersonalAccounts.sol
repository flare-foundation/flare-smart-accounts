// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IISingletonFactory} from "../interface/IISingletonFactory.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IPersonalAccountsFacet} from "../../userInterfaces/facets/IPersonalAccountsFacet.sol";

library PersonalAccounts {

    /// @custom:storage-location erc7201:smartAccounts.PersonalAccounts.State
    struct State {
        /// @notice PersonalAccount implementation used by BeaconProxy PA instances via IBeacon
        address personalAccountImplementation;
        /// Mapping from XRPL address to Personal Account
        mapping(string xrplAddress => IIPersonalAccount) personalAccounts;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.PersonalAccounts.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    /// @notice EIP-2470 Singleton Factory address used as the CREATE2 deployer
    address internal constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    /**
     * @notice Frozen `PersonalAccountProxy` creation bytecode used for per-account CREATE2 derivation.
     *
     * Equal to `type(PersonalAccountProxy).creationCode` as compiled at commit `2abb115` (the
     * source commit used for the live Flare deployment on 2026-02-13). Burned in as a constant
     * so the CREATE2 input is invariant across rebuilds.
     *
     * Why not `type(PersonalAccountProxy).creationCode`:
     *   Solc resolves that constant at compile time and inlines the proxy's full creation bytecode,
     *   including the trailing CBOR metadata IPFS hash. The IPFS hash is recomputed from the entire
     *   compilation context of `PersonalAccountProxy` (its source, its imports' sources, compiler
     *   settings). Any drift there — even a comment edit in a transitively-imported file — produces
     *   different bytes here, which in turn shifts every future Personal Account's CREATE2 address.
     *
     * Cross-chain commitment is the property we want to preserve: a given XRPL owner string maps to
     * the same EVM address on flare / coston2 / songbird / future chains. Freezing this constant
     * makes the derivation `keccak256(constant || abi.encode(diamond, xrplOwner))`, which is purely
     * a function of inputs that don't change with project drift.
     *
     * Hash of this constant is asserted in `test/PersonalAccountsLibrary.t.sol`. Do not edit without
     * updating that fixture and acknowledging that all "predicted but not yet deployed" PA addresses
     * will shift to a new derivation moment.
     */
    bytes internal constant PROXY_CREATION_CODE =
        hex"60a08060405234610283575f6104a7803803809161001d82866102c0565b8439"
        hex"82019060408383031261028357610035836102e3565b60208401519093600160"
        hex"0160401b038211610283570182601f820112156102835780516001600160401b"
        hex"0381116102ac576040519161007e601f8301601f1916602001846102c0565b81"
        hex"835260208301946020838301011161028357815f926020809301875e83010152"
        hex"6100f9608460405180956379ccf11760e11b602083015260018060a01b038816"
        hex"94856024840152604060448401525180918160648501528484015e5f83828401"
        hex"0152601f801991011681010301601f1981018552846102c0565b833b1561029a"
        hex"577fa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b3513"
        hex"3d5080546001600160a01b03191682179055604051635c60da1b60e01b815260"
        hex"2081600481855afa90811561028f575f91610251575b50803b15610231575080"
        hex"7f1cf3b03a6cf19fa2baba4df148e9dcabedea7f8a5c07840e207e5c089be95d"
        hex"3e5f80a282511561022957602060049160405192838092635c60da1b60e01b82"
        hex"525afa91821561021d5780926101d8575b5050906101bc916102f7565b505b60"
        hex"8052604051610123908161038482396080518160180152f35b9091506020823d"
        hex"602011610215575b816101f4602093836102c0565b8101031261021257509061"
        hex"020a6101bc926102e3565b90915f6101b0565b80fd5b3d91506101e7565b6040"
        hex"51903d90823e3d90fd5b5050506101be565b634c9c8ce360e01b5f9081526001"
        hex"600160a01b0391909116600452602490fd5b90506020813d602011610287575b"
        hex"8161026c602093836102c0565b810103126102835761027d906102e3565b5f61"
        hex"0155565b5f80fd5b3d915061025f565b6040513d5f823e3d90fd5b631933b43b"
        hex"60e21b5f5260045260245ffd5b634e487b7160e01b5f52604160045260245ffd"
        hex"5b601f909101601f19168101906001600160401b038211908210176102ac5760"
        hex"4052565b51906001600160a01b038216820361028357565b905f809160208151"
        hex"9101845af48080610370575b1561032b5750506040513d81523d5f602083013e"
        hex"60203d82010160405290565b1561035057639996b31560e01b5f908152600160"
        hex"0160a01b0391909116600452602490fd5b3d15610361576040513d5f823e3d90"
        hex"fd5b63d6bda27560e01b5f5260045ffd5b503d15158061030b5750813b151561"
        hex"030b56fe60806040819052635c60da1b60e01b81526020906004817f00000000"
        hex"0000000000000000000000000000000000000000000000000000000060016001"
        hex"60a01b03165afa801560a2575f901560d1575060203d602011609c575b601f19"
        hex"601f820116608001906080821067ffffffffffffffff83111760885760849160"
        hex"405260800160ad565b60d1565b634e487b7160e01b5f52604160045260245ffd"
        hex"5b503d6058565b6040513d5f823e3d90fd5b602090607f19011260cd57608051"
        hex"6001600160a01b038116810360cd5790565b5f80fd5b5f809136828037813691"
        hex"5af43d5f803e1560e9573d5ff35b3d5ffdfea2646970667358221220b478207f"
        hex"86e1709abbf7bee7e7524adae5e5aefa482c67a6cf1392055c07f16164736f6c"
        hex"634300081e0033";

    function setPersonalAccountImplementation(
        address _implementation
    )
        internal
    {
        require(_implementation.code.length > 0, IPersonalAccountsFacet.InvalidPersonalAccountImplementation());
        State storage state = getState();
        state.personalAccountImplementation = _implementation;
        emit IPersonalAccountsFacet.PersonalAccountImplementationSet(_implementation);
    }

    function getOrCreatePersonalAccount(
        string memory _xrplOwner
    )
        internal
        returns (IIPersonalAccount _personalAccount)
    {
        State storage state = getState();
        _personalAccount = state.personalAccounts[_xrplOwner];
        if (address(_personalAccount) == address(0)) {
            // create new Personal Account
            _personalAccount = createPersonalAccount(_xrplOwner);
        }
    }

    function createPersonalAccount(
        string memory _xrplOwner
    )
        internal
        returns (IIPersonalAccount _personalAccount)
    {
        bytes memory bytecode = generateBytecode(_xrplOwner);
        // check if already deployed
        address personalAccountProxyAddress =
            Create2.computeAddress(bytes32(0), keccak256(bytecode), SINGLETON_FACTORY);
        uint256 codeSize = personalAccountProxyAddress.code.length;
        if (codeSize == 0) {
            // deploy via EIP-2470 singleton factory using CREATE2
            IISingletonFactory(SINGLETON_FACTORY).deploy(bytecode, bytes32(0));
        }

        _personalAccount = IIPersonalAccount(payable(personalAccountProxyAddress));

        // ensure the proxy address is a contract
        codeSize = personalAccountProxyAddress.code.length;
        require(
            codeSize > 0,
            IPersonalAccountsFacet.PersonalAccountNotSuccessfullyDeployed(personalAccountProxyAddress)
        );

        State storage state = getState();
        state.personalAccounts[_xrplOwner] = _personalAccount;
        emit IPersonalAccountsFacet.PersonalAccountCreated(personalAccountProxyAddress, _xrplOwner);
    }

    /**
     * @notice Generates the bytecode for deploying a PersonalAccountProxy contract.
     * Uses the frozen {PROXY_CREATION_CODE} constant rather than
     * `type(PersonalAccountProxy).creationCode` to keep CREATE2 derivation stable across rebuilds.
     * See the doc on {PROXY_CREATION_CODE} for the full rationale.
     * @return The bytecode to be used for CREATE2 deployment.
     */
    function generateBytecode(string memory _xrplOwner)
        internal view
        returns (bytes memory)
    {
        // Use the controller (diamond) address as the beacon so the controller acts as IBeacon for PAs.
        // address(this) resolves to the diamond address when called via delegatecall from facet.
        return abi.encodePacked(
            PROXY_CREATION_CODE,
            abi.encode(
                address(this),
                _xrplOwner
            )
        );
    }

    function computePersonalAccountAddress(
        string memory _xrplOwner
    )
        internal view
        returns (address _personalAccount)
    {
        bytes memory bytecode = generateBytecode(_xrplOwner);
        _personalAccount = Create2.computeAddress(bytes32(0), keccak256(bytecode), SINGLETON_FACTORY);
    }

    function getState()
        internal pure
        returns (State storage _state)
    {
        bytes32 position = STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}
