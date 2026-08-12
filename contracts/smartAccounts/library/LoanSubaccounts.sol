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
import {LoanSubaccountProxy} from "../proxy/LoanSubaccountProxy.sol";
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
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.LoanSubaccounts.State")) - 1)) & ~bytes32(uint256(0xff)
    );

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
        uint32 _destinationEid
    )
        internal
    {
        State storage state = getState();
        if (_fxrpOft == address(0) && _destinationEid == 0) {
            // explicit clear: disables the forward sweep until reconfigured
            delete state.fxrpOft;
            delete state.destinationEid;
            emit ILoanSubaccountsFacet.LoanBridgeSettingsSet(address(0), 0);
            return;
        }
        require(_fxrpOft.code.length > 0, ILoanSubaccountsFacet.InvalidFxrpOft());
        require(_destinationEid != 0, ILoanSubaccountsFacet.InvalidDestinationEid());
        // the OFT must actually be an FXRP bridge: it must wrap the FXRP token, share its
        // decimals (sweeps send with minAmountLD == amountLD, so any shared-decimal dust would
        // make them revert), and have a peer wired for the destination chain
        address fxrp = address(ContractRegistry.getAssetManagerFXRP().fAsset());
        require(IOFT(_fxrpOft).token() == fxrp, ILoanSubaccountsFacet.InvalidFxrpOft());
        require(
            IOFT(_fxrpOft).sharedDecimals() == IERC20Metadata(fxrp).decimals(),
            ILoanSubaccountsFacet.InvalidFxrpOft()
        );
        require(
            IOAppCore(_fxrpOft).peers(_destinationEid) != bytes32(0),
            ILoanSubaccountsFacet.InvalidDestinationEid()
        );
        state.fxrpOft = _fxrpOft;
        state.destinationEid = _destinationEid;
        emit ILoanSubaccountsFacet.LoanBridgeSettingsSet(_fxrpOft, _destinationEid);
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
     * @dev Uses `type(LoanSubaccountProxy).creationCode` while the module is under development.
     * Before the first production deployment (or the first time a predicted address is handed out),
     * this must be frozen to a constant, exactly like {PersonalAccounts.PROXY_CREATION_CODE}, so
     * loan subaccount CREATE2 addresses stay identical across chains and rebuilds.
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
            type(LoanSubaccountProxy).creationCode,
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
        returns (address _fxrpOft, uint32 _destinationEid)
    {
        State storage state = getState();
        return (state.fxrpOft, state.destinationEid);
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
