// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IAssetManager} from "flare-periphery/src/flare/IAssetManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIMemoInstructionsFacet} from "../interface/IIMemoInstructionsFacet.sol";
// import is needed for @inheritdoc
// solhint-disable-next-line no-unused-import
import {IMemoInstructionsFacet} from "../../userInterfaces/facets/IMemoInstructionsFacet.sol";
import {PersonalAccounts} from "../library/PersonalAccounts.sol";
import {Instructions} from "../library/Instructions.sol";
import {MemoInstructions} from "../library/MemoInstructions.sol";
import {Pause} from "../library/Pause.sol";
import {FacetBase} from "./FacetBase.sol";

/**
 * @title MemoInstructionsFacet
 * @notice Facet for handling memo-based instructions via direct minting.
 */
contract MemoInstructionsFacet is IIMemoInstructionsFacet, FacetBase {
    using SafeERC20 for IERC20;

    modifier notPaused {
        Pause.checkNotPaused();
        _;
    }

    /// @inheritdoc IMemoInstructionsFacet
    function mintedFAssets(
        bytes32 _transactionId,
        string calldata _sourceAddress,
        uint256 _amount,
        uint256 /* _underlyingTimestamp */,
        bytes calldata _memoData,
        address payable _executor
    )
        external payable
        notPaused
    {
        IAssetManager assetManager = ContractRegistry.getAssetManagerFXRP();
        require(msg.sender == address(assetManager), OnlyAssetManager());
        // get or create PA
        address personalAccount = address(PersonalAccounts.getOrCreatePersonalAccount(_sourceAddress));

        // check ignoreMemo first — before any memo validation
        // allows recovery from malformed memos (length < 6, bad instruction ID, malformed UserOp, ...)
        bool memoIgnored;
        if (_memoData.length > 0) {
            MemoInstructions.State storage memoState = MemoInstructions.getState();
            if (memoState.ignoreMemo[personalAccount][_transactionId]) {
                memoState.ignoreMemo[personalAccount][_transactionId] = false;
                memoIgnored = true;
            }
        }

        // check PA executor (0xD0/0xD1 bypass to prevent lock-out)
        bool bypassesExecutorCheck = !memoIgnored && _memoData.length > 0 &&
            (uint8(_memoData[0]) == 0xD0 || uint8(_memoData[0]) == 0xD1);
        if (!bypassesExecutorCheck) {
            address paExecutor = MemoInstructions.getExecutor(personalAccount);
            if (paExecutor != address(0)) {
                require(_executor == paExecutor, WrongExecutor(paExecutor, _executor));
            }
        }

        // determine executor fee
        uint256 executorFee;
        if (!memoIgnored && _memoData.length > 0) {
            require(_memoData.length >= 10, InvalidMemoData());
            executorFee = uint64(bytes8(_memoData[2:10]));
        } else {
            // no memo or memo ignored — use default fee
            executorFee = assetManager.getDirectMintingExecutorFeeUBA();
        }
        // check fee override (applies to all instruction IDs)
        uint64 feeOverride = MemoInstructions.getReplacementFee(personalAccount, _transactionId);
        if (feeOverride > 0) {
            executorFee = feeOverride - 1;
        }

        _mintFAssets(
            personalAccount, _transactionId,
            _sourceAddress, _amount, _executor, executorFee
        );

        // if memo present and not ignored, execute memo instruction
        if (!memoIgnored && _memoData.length > 0) {
            uint8 instructionId = uint8(_memoData[0]);
            if (instructionId == 0xFF) {
                MemoInstructions.execute(_memoData, personalAccount);
            } else if (instructionId == 0xE0) {
                MemoInstructions.setIgnoreMemo(_memoData, personalAccount);
            } else if (instructionId == 0xE1) {
                MemoInstructions.setNonce(_memoData, personalAccount);
            } else if (instructionId == 0xE2) {
                MemoInstructions.setReplacementFee(_memoData, personalAccount);
            } else if (instructionId == 0xD0) {
                MemoInstructions.setExecutor(_memoData, personalAccount);
            } else if (instructionId == 0xD1) {
                MemoInstructions.removeExecutor(_memoData, personalAccount);
            } else {
                revert InvalidInstructionId(instructionId);
            }
        }
    }

    /// @inheritdoc IMemoInstructionsFacet
    function isTransactionIdUsed(
        bytes32 _transactionId
    )
        external view
        returns (bool)
    {
        Instructions.State storage state = Instructions.getState();
        return state.usedTransactionIds[_transactionId];
    }

    /// @inheritdoc IMemoInstructionsFacet
    function getExecutor(
        address _personalAccount
    )
        external view
        returns (address)
    {
        return MemoInstructions.getExecutor(_personalAccount);
    }

    /// @inheritdoc IMemoInstructionsFacet
    function getNonce(
        address _personalAccount
    )
        external view
        returns (uint256)
    {
        return MemoInstructions.getNonce(_personalAccount);
    }

    function _mintFAssets(
        address _personalAccount,
        bytes32 _transactionId,
        string calldata _sourceAddress,
        uint256 _amount,
        address payable _executor,
        uint256 _executorFee
    )
        private
    {
        require(_amount >= _executorFee, InsufficientAmountForFee(_amount, _executorFee));

        // replay protection
        Instructions.State storage state = Instructions.getState();
        require(!state.usedTransactionIds[_transactionId], TransactionAlreadyExecuted());
        state.usedTransactionIds[_transactionId] = true;

        // transfer fAssets
        IERC20 fAsset = ContractRegistry.getAssetManagerFXRP().fAsset();
        if (_executorFee > 0) {
            fAsset.safeTransfer(_executor, _executorFee);
        }
        uint256 remaining = _amount - _executorFee;
        if (remaining > 0) {
            fAsset.safeTransfer(_personalAccount, remaining);
        }

        emit DirectMintingExecuted(
            _personalAccount,
            _transactionId,
            _sourceAddress,
            _amount,
            _executorFee,
            _executor
        );
    }
}
