// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ILoanSubaccount} from "../../userInterfaces/ILoanSubaccount.sol";
import {PAYLOAD_VERSION_1} from "../../userInterfaces/IComposeReceiverAccountBase.sol";
import {
    ACTION_BORROW,
    ACTION_WITHDRAW,
    ACTION_DEPOSIT_COLLATERAL,
    ACTION_CANCEL,
    DESTINATION_KIND_EVM
} from "../../userInterfaces/IMorphoLoanSubaccountRemote.sol";
import {BridgingSubaccountBase} from "./BridgingSubaccountBase.sol";

/**
 * @title LoanSubaccount contract
 * @notice The Flare implementation of the loan subaccount type: the parent-driven loan
 * instructions - {borrow}, {depositCollateral} and {withdraw} - each a typed payload the
 * loan-chain twin executes on arrival, built here so a malformed payload cannot reach the
 * bridge, and sent through the shared forward move of {BridgingSubaccountBase} (the type's
 * route, the live peer re-check, the exact quoted fee). Everything else the account does on
 * Flare - the permissionless `sweepRedeem`, redeeming its twin's bridge-back on arrival - is
 * the bridging surface every such type shares, in the base.
 * @dev The controller (MasterAccountController Diamond) is the beacon: the proxy and this
 * implementation resolve through `implementationForType`. No `receive()` and no native exit -
 * see the base.
 */
contract LoanSubaccount is ILoanSubaccount, BridgingSubaccountBase {

    /// @inheritdoc ILoanSubaccount
    function borrow(
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        uint8 _destinationKind,
        bytes32 _destination,
        uint256 _minComposeValue,
        bytes32 _operationId,
        uint64 _deadline,
        bytes calldata _extraOptions
    )
        external payable
        onlyParent
        nonReentrant
    {
        // mirror the remote static checks before paying the bridge fee. V1 supports only a
        // clean, non-zero EVM destination other than this subaccount (the parent - the user's
        // own loan-chain account - is a valid target), and that destination spends no compose
        // value on arrival, so it may not name a delivery-value floor
        {
            address destinationAddress = address(uint160(uint256(_destination)));
            require(
                _operationId != bytes32(0) &&
                    _deadline >= block.timestamp &&
                    _borrowAmount > 0 &&
                    _destinationKind == DESTINATION_KIND_EVM &&
                    _minComposeValue == 0 &&
                    uint256(_destination) >> 160 == 0 &&
                    destinationAddress != address(0) &&
                    destinationAddress != address(this),
                InvalidLoanInstruction()
            );
        }
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_BORROW,
            abi.encode(
                _operationId, _deadline, _destinationKind, _destination, _borrowAmount, _minComposeValue
            )
        );
        (uint32 destinationEid, bytes32 guid) =
            _bridgeToSelf(_collateralAmount, _extraOptions, payload);
        emit BorrowInstructionSent(
            _parentAccount(),
            _operationId,
            _collateralAmount,
            _borrowAmount,
            _destinationKind,
            _destination,
            destinationEid,
            guid
        );
    }

    /// @inheritdoc ILoanSubaccount
    function depositCollateral(
        uint256 _amount,
        bytes calldata _extraOptions
    )
        external payable
        onlyParent
        nonReentrant
    {
        require(_amount > 0, InvalidLoanInstruction());
        // no operation id and no deadline: the deposit only adds the user's own collateral,
        // which the loan chain's permissionless rail can do with the same tokens anyway
        bytes memory payload = abi.encode(PAYLOAD_VERSION_1, ACTION_DEPOSIT_COLLATERAL, bytes(""));
        (uint32 destinationEid, bytes32 guid) = _bridgeToSelf(_amount, _extraOptions, payload);
        emit CollateralDepositInstructionSent(_parentAccount(), _amount, destinationEid, guid);
    }

    /// @inheritdoc ILoanSubaccount
    function withdraw(
        uint256 _amount,
        bytes32 _operationId,
        uint64 _deadline,
        WithdrawOptions calldata _options
    )
        external payable
        onlyParent
        nonReentrant
    {
        // require a non-zero signed delivery-value floor: it is what makes the prepaid return
        // fee reach the loan chain, where delivery is permissionless and the value
        // unauthenticated. destinationOptions are processed here, by the OFT at quote time;
        // only returnOptions first reach a validator remotely, which is why a bad blob there
        // is the frozen-options residual
        require(
            _operationId != bytes32(0) && _deadline >= block.timestamp && _amount > 0 &&
                _options.minComposeValue > 0,
            InvalidLoanInstruction()
        );
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_WITHDRAW,
            abi.encode(
                _operationId,
                _deadline,
                _amount,
                _options.minComposeValue,
                _options.returnOptions
            )
        );
        (uint32 destinationEid, bytes32 guid) = _bridgeToSelf(0, _options.destinationOptions, payload);
        emit WithdrawInstructionSent(
            _parentAccount(), _operationId, _amount, destinationEid, guid
        );
    }

    /// @inheritdoc ILoanSubaccount
    function cancel(
        bytes32 _operationId,
        bytes calldata _extraOptions
    )
        external payable
        onlyParent
        nonReentrant
    {
        // no deadline to check and nothing to size: the whole instruction is the id it burns
        require(_operationId != bytes32(0), InvalidLoanInstruction());
        bytes memory payload = abi.encode(
            PAYLOAD_VERSION_1,
            ACTION_CANCEL,
            abi.encode(_operationId)
        );
        (uint32 destinationEid, bytes32 guid) = _bridgeToSelf(0, _extraOptions, payload);
        emit LoanCancelInstructionSent(_parentAccount(), _operationId, destinationEid, guid);
    }
}
