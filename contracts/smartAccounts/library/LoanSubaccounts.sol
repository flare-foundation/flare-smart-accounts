// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {IISingletonFactory} from "../interface/IISingletonFactory.sol";
import {ILoanSubaccount} from "../../userInterfaces/ILoanSubaccount.sol";
import {
    ILoanSubaccountsFacet,
    SUBACCOUNT_TYPE_NONE
} from "../../userInterfaces/facets/ILoanSubaccountsFacet.sol";
import {PersonalAccounts} from "./PersonalAccounts.sol";

library LoanSubaccounts {

    /// @custom:storage-location erc7201:smartAccounts.LoanSubaccounts.State
    struct State {
        /// @notice Implementation used by each subaccount type's proxy instances.
        mapping(uint256 subaccountType => address) typeImplementation;
        /// Mapping from parent Personal Account and subaccount type to the loan subaccount
        mapping(address parentPersonalAccount =>
            mapping(uint256 subaccountType => ILoanSubaccount)) loanSubaccounts;
        /// @notice FXRP OFT used to bridge FXRP to the loan chain.
        address fxrpOft;
        /// @notice LayerZero endpoint id of the loan chain.
        uint32 destinationEid;
        /// @notice The expected remote OApp (peer) on the loan chain, pinned so that a later
        /// peer mutation on the OFT fails sweeps closed instead of routing to an unknown OApp.
        bytes32 destinationPeer;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.LoanSubaccounts.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    /**
     * @notice The creation bytecode of `LoanSubaccountProxy`, frozen ahead of the first
     * production deployment. Burned in as a constant so the CREATE2 input is invariant across
     * rebuilds.
     *
     * Why not `type(LoanSubaccountProxy).creationCode`: solc resolves that at compile time and
     * inlines the proxy's full creation bytecode, including the trailing CBOR metadata IPFS
     * hash, which is recomputed from the entire compilation context (sources of the proxy and
     * everything it imports, compiler settings). Any drift there - even a comment edit in a
     * transitively-imported file - produces different bytes here, which shifts every future
     * loan subaccount's CREATE2 address. See {PersonalAccounts.PROXY_CREATION_CODE} for the
     * original rationale.
     *
     * For loan subaccounts the cross-chain commitment is load-bearing for funds in flight, not
     * just for UX: `sweepToLoan` and `executeLayerZeroCall` bridge FXRP to this account's own
     * address on the loan chain, so a derivation shift would send assets to an address the
     * user's account no longer controls.
     *
     * Hash of this constant is asserted in `test/LoanSubaccountsLibrary.t.sol`. Do not edit
     * without updating that fixture and acknowledging that all "predicted but not yet
     * deployed" loan subaccount addresses will shift to a new derivation moment.
     */
    bytes internal constant PROXY_CREATION_CODE =
        hex"60c0806040523461012057606081610361803803809161001f8285610137565b"
        hex"833981010312610120576100328161016e565b9060406100416020830161016e"
        hex"565b910151608083905260a0819052604051631628920360e11b815260048101"
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
        hex"806101965750813b151561019656fe60806040819052631628920360e11b8152"
        hex"7f00000000000000000000000000000000000000000000000000000000000000"
        hex"006084526020906024817f000000000000000000000000000000000000000000"
        hex"00000000000000000000006001600160a01b03165afa80156100ce575f901561"
        hex"00ff575060203d6020116100c7575b601f19601f820116608001906080821067"
        hex"ffffffffffffffff8311176100b3576100ae916040526080016100d9565b6100"
        hex"ff565b634e487b7160e01b5f52604160045260245ffd5b503d61007f565b6040"
        hex"513d5f823e3d90fd5b602090607f1901126100fb576080516001600160a01b03"
        hex"811681036100fb5790565b5f80fd5b5f8091368280378136915af43d5f803e15"
        hex"610118573d5ff35b3d5ffdfea2646970667358221220c02984b7bdf263305cfd"
        hex"9346506e2b86d79bba4ae1039e0caf04e85669e6f51464736f6c634300081e00"
        hex"33";

    function setLoanSubaccountImplementation(
        uint256 _subaccountType,
        address _implementation
    )
        internal
    {
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ILoanSubaccountsFacet.InvalidSubaccountType());
        require(
            _implementation.code.length > 0,
            ILoanSubaccountsFacet.InvalidLoanSubaccountImplementation()
        );
        State storage state = getState();
        state.typeImplementation[_subaccountType] = _implementation;
        emit ILoanSubaccountsFacet.LoanSubaccountImplementationSet(_subaccountType, _implementation);
    }

    function setLoanBridgeSettings(
        address _fxrpOft,
        uint32 _destinationEid,
        bytes32 _destinationPeer
    )
        internal
    {
        State storage state = getState();
        if (_fxrpOft == address(0) && _destinationEid == 0 && _destinationPeer == bytes32(0)) {
            // explicit clear: disables the forward sweep until reconfigured
            delete state.fxrpOft;
            delete state.destinationEid;
            delete state.destinationPeer;
            emit ILoanSubaccountsFacet.LoanBridgeSettingsSet(address(0), 0, bytes32(0));
            return;
        }
        require(_fxrpOft.code.length > 0, ILoanSubaccountsFacet.InvalidFxrpOft());
        require(_destinationEid != 0, ILoanSubaccountsFacet.InvalidDestinationEid());
        // the destination peer is an EVM OApp address and must be cleanly zero-padded: the
        // source-computed GUID commits to the full bytes32 receiver, and the destination-side
        // compose authentication recomputes it from the clean local address, so dirty upper
        // bits would route correctly yet fail every delivery
        require(
            _destinationPeer != bytes32(0) && uint256(_destinationPeer) >> 160 == 0,
            ILoanSubaccountsFacet.InvalidDestinationPeer()
        );
        // the OFT must actually be an FXRP bridge: it must wrap the FXRP token, share its
        // decimals (sweeps send with minAmountLD == amountLD, so any shared-decimal dust would
        // make them revert), and its peer for the destination chain must be exactly the intended
        // remote OApp - existence alone would accept a wrong route
        address fxrp = address(ContractRegistry.getAssetManagerFXRP().fAsset());
        require(IOFT(_fxrpOft).token() == fxrp, ILoanSubaccountsFacet.InvalidFxrpOft());
        require(
            IOFT(_fxrpOft).sharedDecimals() == IERC20Metadata(fxrp).decimals(),
            ILoanSubaccountsFacet.InvalidFxrpOft()
        );
        // the destination-side compose authentication depends on the canonical OFT message
        // codec (composeFrom = source caller), so the adapter must declare the canonical
        // interface and codec version exactly; version stability of the pinned adapter is a
        // deployment assumption (the production adapter is not a proxy)
        (bytes4 interfaceId, uint64 version) = IOFT(_fxrpOft).oftVersion();
        require(
            interfaceId == type(IOFT).interfaceId && version == 1,
            ILoanSubaccountsFacet.InvalidFxrpOft()
        );
        require(
            IOAppCore(_fxrpOft).peers(_destinationEid) == _destinationPeer,
            ILoanSubaccountsFacet.InvalidDestinationPeer()
        );
        state.fxrpOft = _fxrpOft;
        state.destinationEid = _destinationEid;
        state.destinationPeer = _destinationPeer;
        emit ILoanSubaccountsFacet.LoanBridgeSettingsSet(_fxrpOft, _destinationEid, _destinationPeer);
    }

    function getOrCreateLoanSubaccount(
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        internal
        returns (ILoanSubaccount _loanSubaccount)
    {
        State storage state = getState();
        _loanSubaccount = state.loanSubaccounts[_parentPersonalAccount][_subaccountType];
        if (address(_loanSubaccount) == address(0)) {
            // create new loan subaccount
            _loanSubaccount = createLoanSubaccount(_parentPersonalAccount, _subaccountType);
        }
    }

    function createLoanSubaccount(
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        internal
        returns (ILoanSubaccount _loanSubaccount)
    {
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ILoanSubaccountsFacet.InvalidSubaccountType());
        require(
            getLoanSubaccountImplementation(_subaccountType) != address(0),
            ILoanSubaccountsFacet.LoanSubaccountImplementationNotSet(_subaccountType)
        );

        bytes memory bytecode = generateBytecode(_parentPersonalAccount, _subaccountType);
        // check if already deployed
        address loanSubaccountProxyAddress = Create2.computeAddress(
            bytes32(0), keccak256(bytecode), PersonalAccounts.SINGLETON_FACTORY
        );
        uint256 codeSize = loanSubaccountProxyAddress.code.length;
        if (codeSize == 0) {
            // deploy via EIP-2470 singleton factory using CREATE2
            IISingletonFactory(PersonalAccounts.SINGLETON_FACTORY).deploy(bytecode, bytes32(0));
        }

        _loanSubaccount = ILoanSubaccount(loanSubaccountProxyAddress);

        // ensure the proxy address is a contract
        codeSize = loanSubaccountProxyAddress.code.length;
        require(
            codeSize > 0,
            ILoanSubaccountsFacet.LoanSubaccountNotSuccessfullyDeployed(loanSubaccountProxyAddress)
        );

        State storage state = getState();
        state.loanSubaccounts[_parentPersonalAccount][_subaccountType] = _loanSubaccount;
        emit ILoanSubaccountsFacet.LoanSubaccountCreated(
            loanSubaccountProxyAddress,
            _parentPersonalAccount,
            _subaccountType
        );
    }

    /**
     * @notice Generates the bytecode for deploying a LoanSubaccountProxy contract.
     * Uses the frozen {PROXY_CREATION_CODE} constant rather than
     * `type(LoanSubaccountProxy).creationCode` to keep CREATE2 derivation stable across rebuilds.
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

    function computeLoanSubaccountAddress(
        address _parentPersonalAccount,
        uint256 _subaccountType
    )
        internal view
        returns (address _loanSubaccount)
    {
        bytes memory bytecode = generateBytecode(_parentPersonalAccount, _subaccountType);
        _loanSubaccount = Create2.computeAddress(
            bytes32(0), keccak256(bytecode), PersonalAccounts.SINGLETON_FACTORY
        );
    }

    function getLoanBridgeSettings()
        internal view
        returns (address _fxrpOft, uint32 _destinationEid, bytes32 _destinationPeer)
    {
        State storage state = getState();
        return (state.fxrpOft, state.destinationEid, state.destinationPeer);
    }

    function getLoanSubaccountImplementation(
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
