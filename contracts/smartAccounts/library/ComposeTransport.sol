// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {IOftDecimals} from "../interface/IOftDecimals.sol";
import {IComposeTransportFacet} from "../../userInterfaces/facets/IComposeTransportFacet.sol";

library ComposeTransport {

    /// @custom:storage-location erc7201:smartAccounts.ComposeTransport.State
    struct State {
        /// @dev The compose transport, shared by every compose receiver on this diamond.
        IComposeTransportFacet.Transport transport;
        /// @dev The token every transport's OFT must wrap, once pinned (by the first loan
        /// market registration) and never cleared: the adapter can rotate, the token cannot
        /// change under the write-once consumers that depend on it.
        address pinnedToken;
    }

    bytes32 internal constant STATE_POSITION = keccak256(
        abi.encode(uint256(keccak256("smartAccounts.ComposeTransport.State")) - 1)) & ~bytes32(uint256(0xff)
    );

    function setComposeTransport(
        IComposeTransportFacet.Transport calldata _transport
    )
        internal
    {
        State storage state = getState();
        require(_transport.lzEndpoint.code.length > 0, IComposeTransportFacet.InvalidLzEndpoint());
        require(_transport.originEid != 0, IComposeTransportFacet.InvalidOriginEid());
        // the origin peer is the Flare-side adapter, an EVM address: it must be non-zero and
        // cleanly zero-padded
        require(
            _transport.originPeer != bytes32(0) && uint256(_transport.originPeer) >> 160 == 0,
            IComposeTransportFacet.InvalidOriginPeer()
        );
        // the OFT is the authoritative identity of the bridged token and of the codec the compose
        // authentication depends on. It must also send without truncation: the bridge-back names
        // only the least it accepts, so dropped dust would come out of the user's allowance
        // rather than failing. The conversion rate proves that; equal decimals only imply it for
        // the canonical subclasses (see {IOftDecimals})
        require(_transport.oft.code.length > 0, IComposeTransportFacet.InvalidOft());
        require(
            IOFT(_transport.oft).sharedDecimals() ==
                IERC20Metadata(IOFT(_transport.oft).token()).decimals(),
            IComposeTransportFacet.InvalidOft()
        );
        require(
            IOftDecimals(_transport.oft).decimalConversionRate() == 1,
            IComposeTransportFacet.InvalidOft()
        );
        (bytes4 interfaceId, uint64 version) = IOFT(_transport.oft).oftVersion();
        require(
            interfaceId == type(IOFT).interfaceId && version == 1,
            IComposeTransportFacet.InvalidOft()
        );
        // the OFT must be wired to the endpoint that delivers lzCompose; a wrong (or
        // malicious) endpoint could fabricate every callback parameter
        require(
            address(IOAppCore(_transport.oft).endpoint()) == _transport.lzEndpoint,
            IComposeTransportFacet.InvalidLzEndpoint()
        );
        // the live peer for the origin endpoint must be exactly the pinned remote OApp
        require(
            IOAppCore(_transport.oft).peers(_transport.originEid) == _transport.originPeer,
            IComposeTransportFacet.InvalidOriginPeer()
        );
        // once a token is pinned, a replacement transport may rotate the adapter but must wrap
        // the same token, or the write-once bindings that depend on it could no longer be served
        address pinnedToken = state.pinnedToken;
        require(
            pinnedToken == address(0) || IOFT(_transport.oft).token() == pinnedToken,
            IComposeTransportFacet.InvalidOft()
        );
        state.transport = _transport;
        emit IComposeTransportFacet.ComposeTransportSet(
            _transport.lzEndpoint,
            _transport.oft,
            _transport.originEid,
            _transport.originPeer
        );
    }

    function clearComposeTransport()
        internal
    {
        // disables the compose receivers and the bridge-back while preserving markets and the
        // token pin; the caller must follow the incident runbook in IComposeTransportFacet
        delete getState().transport;
        emit IComposeTransportFacet.ComposeTransportCleared();
    }

    /// @dev Pins the token every later transport's OFT must wrap. Idempotent once set; the
    /// caller has validated `_token` against the current transport's OFT.
    function pinToken(
        address _token
    )
        internal
    {
        State storage state = getState();
        if (state.pinnedToken == address(0)) {
            state.pinnedToken = _token;
        }
    }

    function getComposeTransport()
        internal view
        returns (IComposeTransportFacet.Transport memory)
    {
        return getState().transport;
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
