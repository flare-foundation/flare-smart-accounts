// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILoanChainSettingsFacet} from "../../userInterfaces/facets/ILoanChainSettingsFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";
import {ILoanBridgeSettingsFacet} from "../../userInterfaces/facets/ILoanBridgeSettingsFacet.sol";
import {SUBACCOUNT_TYPE_NONE, ISubaccountsFacet} from "../../userInterfaces/facets/ISubaccountsFacet.sol";

library LoanChainSettings {

    /// @custom:storage-location erc7201:smartAccounts.LoanChainSettings.State
    struct State {
        /// @dev The global LayerZero transport, shared by every loan subaccount type.
        ILoanChainSettingsFacet.Transport transport;
        /// @dev The market each type is bound to, write-once: positions live in it, so the
        /// binding must never change under them.
        mapping(uint256 subaccountType => ILoanChainSettingsFacet.Market) markets;
        /// @dev Types with new debt increases disabled - the routine way to sunset a pool.
        mapping(uint256 subaccountType => bool) borrowingDisabled;
        /// @dev The collateral (FXRP) token, pinned by the first market registration and
        /// never cleared: every later non-zero transport must wrap it, or a transport
        /// replacement could strand the write-once market bindings.
        address collateralToken;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.LoanChainSettings.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function setLoanChainTransport(
        ILoanChainSettingsFacet.Transport calldata _transport
    )
        internal
    {
        State storage state = getState();
        if (
            _transport.lzEndpoint == address(0) &&
            _transport.fxrpOft == address(0) &&
            _transport.originEid == 0 &&
            _transport.originPeer == bytes32(0)
        ) {
            // explicit clear, only for a fully zero struct: disables lzCompose and the
            // bridge-back sweep for all loan types until reconfigured; markets, repayment,
            // defensive deposits and recovery to the parent persist. A partially zero struct
            // falls through to validation and reverts - a malformed clear cannot wipe it
            delete state.transport;
            emit ILoanChainSettingsFacet.LoanChainTransportSet(
                address(0), address(0), 0, bytes32(0)
            );
            return;
        }
        require(_transport.lzEndpoint.code.length > 0, ILoanChainSettingsFacet.InvalidLzEndpoint());
        require(_transport.originEid != 0, ILoanChainSettingsFacet.InvalidOriginEid());
        // the origin peer is the Flare-side adapter, an EVM address: it must be non-zero and
        // cleanly zero-padded
        require(
            _transport.originPeer != bytes32(0) && uint256(_transport.originPeer) >> 160 == 0,
            ILoanChainSettingsFacet.InvalidOriginPeer()
        );
        // the OFT is the authoritative FXRP identity: it must share decimals with its own
        // token (sweeps send with minAmountLD == amountLD) and report the canonical
        // interface/codec version - the compose authentication depends on its encoding
        require(_transport.fxrpOft.code.length > 0, ILoanBridgeSettingsFacet.InvalidFxrpOft());
        require(
            IOFT(_transport.fxrpOft).sharedDecimals() ==
                IERC20Metadata(IOFT(_transport.fxrpOft).token()).decimals(),
            ILoanBridgeSettingsFacet.InvalidFxrpOft()
        );
        (bytes4 interfaceId, uint64 version) = IOFT(_transport.fxrpOft).oftVersion();
        require(
            interfaceId == type(IOFT).interfaceId && version == 1,
            ILoanBridgeSettingsFacet.InvalidFxrpOft()
        );
        // the OFT must be wired to the endpoint that delivers lzCompose; a wrong (or
        // malicious) endpoint could fabricate every callback parameter
        require(
            address(IOAppCore(_transport.fxrpOft).endpoint()) == _transport.lzEndpoint,
            ILoanChainSettingsFacet.InvalidLzEndpoint()
        );
        // the live peer for the origin endpoint must be exactly the pinned remote OApp
        require(
            IOAppCore(_transport.fxrpOft).peers(_transport.originEid) == _transport.originPeer,
            ILoanChainSettingsFacet.InvalidOriginPeer()
        );
        // once any market is registered, the collateral token identity is pinned for good:
        // a replacement transport may rotate the OFT adapter, but it must wrap the same
        // token, or the permanent market bindings could no longer be served
        address pinnedCollateralToken = state.collateralToken;
        require(
            pinnedCollateralToken == address(0) ||
                IOFT(_transport.fxrpOft).token() == pinnedCollateralToken,
            ILoanBridgeSettingsFacet.InvalidFxrpOft()
        );
        state.transport = _transport;
        emit ILoanChainSettingsFacet.LoanChainTransportSet(
            _transport.lzEndpoint,
            _transport.fxrpOft,
            _transport.originEid,
            _transport.originPeer
        );
    }

    function registerLoanChainMarket(
        uint256 _subaccountType,
        ILoanChainSettingsFacet.Market calldata _market
    )
        internal
    {
        State storage state = getState();
        require(_subaccountType != SUBACCOUNT_TYPE_NONE, ISubaccountsFacet.InvalidSubaccountType());
        // write-once: a position's market can never change under it, so exits never need a
        // registry - a different market is a different subaccount type
        require(
            state.markets[_subaccountType].morpho == address(0),
            ILoanChainSettingsFacet.MarketAlreadyRegistered(_subaccountType)
        );
        // the transport pins FXRP's identity (the OFT's own token), which the market's
        // collateral token must match - so the transport must be configured first
        address fxrpOft = state.transport.fxrpOft;
        require(
            fxrpOft != address(0),
            ILoanChainSettingsFacet.LoanChainTransportNotConfigured()
        );
        require(_market.morpho.code.length > 0, ILoanChainSettingsFacet.InvalidMorpho());
        IMorpho.MarketParams memory marketParams = _market.marketParams;
        require(
            marketParams.loanToken != address(0) &&
            marketParams.collateralToken != address(0) &&
            marketParams.loanToken != marketParams.collateralToken &&
            marketParams.lltv != 0,
            ILoanChainSettingsFacet.InvalidMarketParams()
        );
        // both tokens must be contracts: the binding is permanent, and a Morpho market can
        // exist for a token address that carries no code
        require(
            marketParams.loanToken.code.length > 0 &&
            marketParams.collateralToken.code.length > 0,
            ILoanChainSettingsFacet.InvalidMarketParams()
        );
        require(
            IOFT(fxrpOft).token() == marketParams.collateralToken,
            ILoanBridgeSettingsFacet.InvalidFxrpOft()
        );
        // the market must actually exist on the Morpho contract, or every credited compose
        // action against it would revert
        bytes32 marketId = keccak256(abi.encode(marketParams));
        (, , , , uint128 lastUpdate, ) = IMorpho(_market.morpho).market(marketId);
        require(lastUpdate != 0, ILoanChainSettingsFacet.InvalidMarketParams());

        // the first registration pins the collateral token: every later non-zero transport
        // must wrap it (checked in setLoanChainTransport), so later markets - validated
        // against the live OFT above - transitively match it too
        if (state.collateralToken == address(0)) {
            state.collateralToken = marketParams.collateralToken;
        }
        state.markets[_subaccountType] = _market;
        emit ILoanChainSettingsFacet.LoanChainMarketRegistered(
            _subaccountType, _market.morpho, marketId
        );
    }

    function disableLoanChainBorrowing(
        uint256 _subaccountType
    )
        internal
    {
        _setBorrowingDisabled(_subaccountType, true);
        emit ILoanChainSettingsFacet.LoanChainBorrowingDisabled(_subaccountType);
    }

    function enableLoanChainBorrowing(
        uint256 _subaccountType
    )
        internal
    {
        _setBorrowingDisabled(_subaccountType, false);
        emit ILoanChainSettingsFacet.LoanChainBorrowingEnabled(_subaccountType);
    }

    function getLoanChainTransport()
        internal view
        returns (ILoanChainSettingsFacet.Transport memory)
    {
        return getState().transport;
    }

    function getLoanChainMarket(
        uint256 _subaccountType
    )
        internal view
        returns (ILoanChainSettingsFacet.Market memory)
    {
        return getState().markets[_subaccountType];
    }

    function isLoanChainBorrowingDisabled(
        uint256 _subaccountType
    )
        internal view
        returns (bool)
    {
        return getState().borrowingDisabled[_subaccountType];
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

    function _setBorrowingDisabled(
        uint256 _subaccountType,
        bool _disabled
    )
        private
    {
        State storage state = getState();
        require(
            state.markets[_subaccountType].morpho != address(0),
            ILoanChainSettingsFacet.MarketNotRegistered(_subaccountType)
        );
        state.borrowingDisabled[_subaccountType] = _disabled;
    }
}
