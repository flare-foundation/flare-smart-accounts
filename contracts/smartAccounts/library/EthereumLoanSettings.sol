// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {IEthereumLoanSettingsFacet} from "../../userInterfaces/facets/IEthereumLoanSettingsFacet.sol";
import {IMorpho} from "../interface/IMorpho.sol";
import {ILoanSubaccountsFacet} from "../../userInterfaces/facets/ILoanSubaccountsFacet.sol";

library EthereumLoanSettings {

    /// @custom:storage-location erc7201:smartAccounts.EthereumLoanSettings.State
    struct State {
        IEthereumLoanSettingsFacet.Settings settings;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.EthereumLoanSettings.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function setEthereumLoanSettings(
        IEthereumLoanSettingsFacet.Settings calldata _settings
    )
        internal
    {
        State storage state = getState();
        if (
            _settings.lzEndpoint == address(0) &&
            _settings.fxrpOft == address(0) &&
            _settings.morpho == address(0) &&
            _settings.originEid == 0 &&
            _settings.originPeer == bytes32(0) &&
            _settings.marketParams.loanToken == address(0) &&
            _settings.marketParams.collateralToken == address(0) &&
            _settings.marketParams.oracle == address(0) &&
            _settings.marketParams.irm == address(0) &&
            _settings.marketParams.lltv == 0
        ) {
            // explicit clear, only for a fully zero struct: disables lzCompose and the
            // bridge-back sweep until reconfigured; a partially zero struct falls through to
            // the validation below and reverts, so a malformed clear cannot wipe the settings
            delete state.settings;
            emit IEthereumLoanSettingsFacet.EthereumLoanSettingsSet(
                address(0), address(0), 0, bytes32(0), address(0), bytes32(0)
            );
            return;
        }
        require(_settings.lzEndpoint.code.length > 0, IEthereumLoanSettingsFacet.InvalidLzEndpoint());
        require(_settings.morpho.code.length > 0, IEthereumLoanSettingsFacet.InvalidMorpho());
        require(_settings.originEid != 0, IEthereumLoanSettingsFacet.InvalidOriginEid());
        // the origin peer is the Flare-side adapter, an EVM address: it must be non-zero and
        // cleanly zero-padded
        require(
            _settings.originPeer != bytes32(0) && uint256(_settings.originPeer) >> 160 == 0,
            IEthereumLoanSettingsFacet.InvalidOriginPeer()
        );
        IMorpho.MarketParams memory marketParams = _settings.marketParams;
        require(
            marketParams.loanToken != address(0) &&
            marketParams.collateralToken != address(0) &&
            marketParams.lltv != 0,
            IEthereumLoanSettingsFacet.InvalidMarketParams()
        );
        // the OFT must be the FXRP bridge on this chain: it must wrap the market's collateral
        // token, share its decimals (the bridge-back sweep sends with minAmountLD == amountLD),
        // and report the canonical interface and message-codec version - the compose
        // authentication in the subaccount depends on the canonical composeFrom encoding
        require(_settings.fxrpOft.code.length > 0, ILoanSubaccountsFacet.InvalidFxrpOft());
        require(
            IOFT(_settings.fxrpOft).token() == marketParams.collateralToken,
            ILoanSubaccountsFacet.InvalidFxrpOft()
        );
        require(
            IOFT(_settings.fxrpOft).sharedDecimals() ==
                IERC20Metadata(marketParams.collateralToken).decimals(),
            ILoanSubaccountsFacet.InvalidFxrpOft()
        );
        (bytes4 interfaceId, uint64 version) = IOFT(_settings.fxrpOft).oftVersion();
        require(
            interfaceId == type(IOFT).interfaceId && version == 1,
            ILoanSubaccountsFacet.InvalidFxrpOft()
        );
        // the OFT must be wired to the same endpoint that will deliver lzCompose calls;
        // otherwise a wrong (or malicious) endpoint could fabricate every callback parameter
        require(
            address(IOAppCore(_settings.fxrpOft).endpoint()) == _settings.lzEndpoint,
            IEthereumLoanSettingsFacet.InvalidLzEndpoint()
        );
        // the live peer for the origin endpoint must be exactly the pinned remote OApp
        require(
            IOAppCore(_settings.fxrpOft).peers(_settings.originEid) == _settings.originPeer,
            IEthereumLoanSettingsFacet.InvalidOriginPeer()
        );
        state.settings = _settings;
        emit IEthereumLoanSettingsFacet.EthereumLoanSettingsSet(
            _settings.lzEndpoint,
            _settings.fxrpOft,
            _settings.originEid,
            _settings.originPeer,
            _settings.morpho,
            keccak256(abi.encode(marketParams))
        );
    }

    function getEthereumLoanSettings()
        internal view
        returns (IEthereumLoanSettingsFacet.Settings memory)
    {
        return getState().settings;
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
