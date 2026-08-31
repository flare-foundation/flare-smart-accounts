// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IISingletonFactory} from "../interface/IISingletonFactory.sol";
import {
    ISubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ISubaccountsFacet.sol";
import {PersonalAccounts} from "./PersonalAccounts.sol";

library Subaccounts {

    /// @custom:storage-location erc7201:smartAccounts.Subaccounts.State
    struct State {
        /// @notice Implementation used by each subaccount type's proxy instances.
        mapping(uint256 subaccountType => address) typeImplementation;
        /// Mapping from parent Personal Account and subaccount type to the subaccount
        mapping(address parentPersonalAccount =>
            mapping(uint256 subaccountType => address)) subaccounts;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.Subaccounts.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    /**
     * @notice The creation bytecode of `SubaccountProxy`, frozen ahead of the first
     * production deployment. Burned in as a constant so the CREATE2 input is invariant across
     * rebuilds.
     *
     * Why not `type(SubaccountProxy).creationCode`: solc resolves that at compile time and
     * inlines the proxy's full creation bytecode, including the trailing CBOR metadata IPFS
     * hash, which is recomputed from the entire compilation context (sources of the proxy and
     * everything it imports, compiler settings). Any drift there - even a comment edit in a
     * transitively-imported file - produces different bytes here, which shifts every future
     * subaccount's CREATE2 address. See {PersonalAccounts.PROXY_CREATION_CODE} for the
     * original rationale.
     *
     * For subaccounts the cross-chain commitment is load-bearing for funds in flight, not
     * just for UX: the loan instructions bridge FXRP to this account's own
     * address on the loan chain, so a derivation shift would send assets to an address the
     * user's account no longer controls.
     *
     * Hash of this constant is asserted in `test/SubaccountsLibrary.t.sol`. Do not edit
     * without updating that fixture and acknowledging that all "predicted but not yet
     * deployed" subaccount addresses will shift to a new derivation moment.
     */
    bytes internal constant PROXY_CREATION_CODE =
        hex"60c0806040523461012057606081610361803803809161001f8285610137565b"
        hex"833981010312610120576100328161016e565b9060406100416020830161016e"
        hex"565b910151608083905260a081905260405163c6dd726760e01b815260048101"
        hex"829052926001600160a01b03169190602084602481865afa91821561012c575f"
        hex"926100eb575b6040516305e52ecf60e21b602082015260248101949094526001"
        hex"600160a01b0316604484015260648084019190915282526100cb92506100c660"
        hex"8483610137565b610182565b50604051610152908161020f823960805181603c"
        hex"015260a0518160120152f35b91506020843d602011610124575b816101066020"
        hex"9383610137565b810103126101205761011a6100cb9461016e565b9161008556"
        hex"5b5f80fd5b3d91506100f9565b6040513d5f823e3d90fd5b601f909101601f19"
        hex"168101906001600160401b0382119082101761015a57604052565b634e487b71"
        hex"60e01b5f52604160045260245ffd5b51906001600160a01b0382168203610120"
        hex"57565b905f8091602081519101845af480806101fb575b156101b65750506040"
        hex"513d81523d5f602083013e60203d82010160405290565b156101db57639996b3"
        hex"1560e01b5f9081526001600160a01b0391909116600452602490fd5b3d156101"
        hex"ec576040513d5f823e3d90fd5b63d6bda27560e01b5f5260045ffd5b503d1515"
        hex"806101965750813b151561019656fe6080604081905263c6dd726760e01b8152"
        hex"7f00000000000000000000000000000000000000000000000000000000000000"
        hex"006084526020906024817f000000000000000000000000000000000000000000"
        hex"00000000000000000000006001600160a01b03165afa80156100ce575f901561"
        hex"00ff575060203d6020116100c7575b601f19601f820116608001906080821067"
        hex"ffffffffffffffff8311176100b3576100ae916040526080016100d9565b6100"
        hex"ff565b634e487b7160e01b5f52604160045260245ffd5b503d61007f565b6040"
        hex"513d5f823e3d90fd5b602090607f1901126100fb576080516001600160a01b03"
        hex"811681036100fb5790565b5f80fd5b5f8091368280378136915af43d5f803e15"
        hex"610118573d5ff35b3d5ffdfea2646970667358221220f794d5d7bf4e2af7968b"
        hex"236ad68dc4d4c9f05d2d4d3d647e1aed2b54d69be42c64736f6c634300082300"
        hex"33";

    function setSubaccountImplementation(
        uint256 _subaccountType,
        address _implementation
    )
        internal
    {
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ISubaccountsFacet.InvalidSubaccountType());
        require(
            _implementation.code.length > 0,
            ISubaccountsFacet.InvalidSubaccountImplementation()
        );
        State storage state = getState();
        state.typeImplementation[_subaccountType] = _implementation;
        emit ISubaccountsFacet.SubaccountImplementationSet(_subaccountType, _implementation);
    }

    function getOrCreateSubaccount(
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        internal
        returns (address _subaccount)
    {
        State storage state = getState();
        _subaccount = state.subaccounts[_parentPersonalAccount][_subaccountType];
        if (_subaccount == address(0)) {
            // create new subaccount
            _subaccount = createSubaccount(_parentPersonalAccount, _subaccountType);
        }
    }

    function createSubaccount(
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        internal
        returns (address _subaccount)
    {
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ISubaccountsFacet.InvalidSubaccountType());
        require(
            implementationForType(_subaccountType) != address(0),
            ISubaccountsFacet.SubaccountImplementationNotSet(_subaccountType)
        );

        bytes memory bytecode = generateBytecode(_parentPersonalAccount, _subaccountType);
        // check if already deployed
        _subaccount = Create2.computeAddress(
            bytes32(0), keccak256(bytecode), PersonalAccounts.SINGLETON_FACTORY
        );
        uint256 codeSize = _subaccount.code.length;
        if (codeSize == 0) {
            // deploy via EIP-2470 singleton factory using CREATE2
            IISingletonFactory(PersonalAccounts.SINGLETON_FACTORY).deploy(bytecode, bytes32(0));
        }

        // ensure the proxy address is a contract
        codeSize = _subaccount.code.length;
        require(
            codeSize > 0,
            ISubaccountsFacet.SubaccountNotSuccessfullyDeployed(_subaccount)
        );

        State storage state = getState();
        state.subaccounts[_parentPersonalAccount][_subaccountType] = _subaccount;
        emit ISubaccountsFacet.SubaccountCreated(
            _subaccount,
            _parentPersonalAccount,
            _subaccountType
        );
    }

    /**
     * @notice Generates the bytecode for deploying a SubaccountProxy contract.
     * Uses the frozen {PROXY_CREATION_CODE} constant rather than
     * `type(SubaccountProxy).creationCode` to keep CREATE2 derivation stable across rebuilds.
     * See the doc on {PROXY_CREATION_CODE} for the full rationale.
     * @return The bytecode to be used for CREATE2 deployment.
     */
    function generateBytecode(
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        internal view
        returns (bytes memory)
    {
        // Use the controller (diamond) address to resolve the implementation per subaccount type.
        // address(this) resolves to the diamond address when called via delegatecall from facet.
        return abi.encodePacked(
            PROXY_CREATION_CODE,
            abi.encode(
                address(this),
                _parentPersonalAccount,
                _subaccountType
            )
        );
    }

    function computeSubaccountAddress(
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        internal view
        returns (address _subaccount)
    {
        bytes memory bytecode = generateBytecode(_parentPersonalAccount, _subaccountType);
        _subaccount = Create2.computeAddress(
            bytes32(0), keccak256(bytecode), PersonalAccounts.SINGLETON_FACTORY
        );
    }

    function implementationForType(
        uint256 _subaccountType
    )
        internal view
        returns (address)
    {
        return getState().typeImplementation[_subaccountType];
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
