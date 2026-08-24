// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {ILoanBridgeSettingsFacet} from "../../userInterfaces/facets/ILoanBridgeSettingsFacet.sol";

library LoanBridgeSettings {

    /// @custom:storage-location erc7201:smartAccounts.LoanBridgeSettings.State
    struct State {
        /// @notice FXRP OFT used to bridge FXRP to the loan chain.
        address fxrpOft;
        /// @notice LayerZero endpoint id of the loan chain.
        uint32 destinationEid;
        /// @notice The expected remote OApp (peer) on the loan chain, pinned so that a later
        /// peer mutation on the OFT fails sweeps closed instead of routing to an unknown OApp.
        bytes32 destinationPeer;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.LoanBridgeSettings.State")) - 1)) & ~bytes32(uint256(0xff)
    );

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
            emit ILoanBridgeSettingsFacet.LoanBridgeSettingsSet(address(0), 0, bytes32(0));
            return;
        }
        require(_fxrpOft.code.length > 0, ILoanBridgeSettingsFacet.InvalidFxrpOft());
        require(_destinationEid != 0, ILoanBridgeSettingsFacet.InvalidDestinationEid());
        // the destination peer is an EVM OApp address and must be cleanly zero-padded: the
        // source-computed GUID commits to the full bytes32 receiver, and the destination-side
        // compose authentication recomputes it from the clean local address, so dirty upper
        // bits would route correctly yet fail every delivery
        require(
            _destinationPeer != bytes32(0) && uint256(_destinationPeer) >> 160 == 0,
            ILoanBridgeSettingsFacet.InvalidDestinationPeer()
        );
        // the OFT must actually be an FXRP bridge: it must wrap the FXRP token, share its
        // decimals (sweeps send with minAmountLD == amountLD, so any shared-decimal dust would
        // make them revert), and its peer for the destination chain must be exactly the intended
        // remote OApp - existence alone would accept a wrong route
        address fxrp = address(ContractRegistry.getAssetManagerFXRP().fAsset());
        require(IOFT(_fxrpOft).token() == fxrp, ILoanBridgeSettingsFacet.InvalidFxrpOft());
        require(
            IOFT(_fxrpOft).sharedDecimals() == IERC20Metadata(fxrp).decimals(),
            ILoanBridgeSettingsFacet.InvalidFxrpOft()
        );
        // the destination-side compose authentication depends on the canonical OFT message
        // codec (composeFrom = source caller), so the adapter must declare the canonical
        // interface and codec version exactly; version stability of the pinned adapter is a
        // deployment assumption (the production adapter is not a proxy)
        (bytes4 interfaceId, uint64 version) = IOFT(_fxrpOft).oftVersion();
        require(
            interfaceId == type(IOFT).interfaceId && version == 1,
            ILoanBridgeSettingsFacet.InvalidFxrpOft()
        );
        require(
            IOAppCore(_fxrpOft).peers(_destinationEid) == _destinationPeer,
            ILoanBridgeSettingsFacet.InvalidDestinationPeer()
        );
        state.fxrpOft = _fxrpOft;
        state.destinationEid = _destinationEid;
        state.destinationPeer = _destinationPeer;
        emit ILoanBridgeSettingsFacet.LoanBridgeSettingsSet(_fxrpOft, _destinationEid, _destinationPeer);
    }

    function getLoanBridgeSettings()
        internal view
        returns (address _fxrpOft, uint32 _destinationEid, bytes32 _destinationPeer)
    {
        State storage state = getState();
        return (state.fxrpOft, state.destinationEid, state.destinationPeer);
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
