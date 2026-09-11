// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TestnetPriceFeed
 * @notice An operator-controlled price feed in the Chainlink `AggregatorV3Interface` shape, for the
 * Sepolia rehearsal market's oracle. The owner sets the answer, can date it (the Morpho oracle
 * reads no timestamp, and the rehearsal records that rather than assumes it) and can make the
 * feed fail outright, which is what a reverting oracle looks like from the market's side. One
 * round is retained: the latest. Deployed to a public testnet, never to a production chain.
 */
contract TestnetPriceFeed is Ownable {
    uint8 private immutable _feedDecimals;
    string private _feedDescription;
    uint80 private _roundId;
    int256 private _answer;
    uint256 private _updatedAt;
    bool private _failing;

    event AnswerSet(uint80 indexed roundId, int256 answer, uint256 updatedAt);
    event FailingSet(bool failing);

    error FeedFailing();
    error NoSuchRound(uint80 roundId);

    constructor(
        uint8 _decimals,
        string memory _description,
        int256 _initialAnswer,
        address _owner
    )
        Ownable(_owner)
    {
        _feedDecimals = _decimals;
        _feedDescription = _description;
        _record(_initialAnswer, block.timestamp);
    }

    /// @notice Publishes a new answer, dated now.
    function setAnswer(
        int256 _newAnswer
    )
        external onlyOwner
    {
        _record(_newAnswer, block.timestamp);
    }

    /// @notice Publishes a new answer with an explicit timestamp, to present a stale round.
    function setAnswerAt(
        int256 _newAnswer,
        uint256 _timestamp
    )
        external onlyOwner
    {
        _record(_newAnswer, _timestamp);
    }

    /// @notice Makes every read revert, or lifts that again; the stored answer is untouched.
    function setFailing(
        bool _shouldFail
    )
        external onlyOwner
    {
        _failing = _shouldFail;
        emit FailingSet(_shouldFail);
    }

    function latestRoundData()
        external view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (_failing) {
            revert FeedFailing();
        }
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    /// @notice The retained round is the latest one; any other id is unknown here.
    function getRoundData(
        uint80 _requestedRoundId
    )
        external view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (_failing) {
            revert FeedFailing();
        }
        if (_requestedRoundId != _roundId) {
            revert NoSuchRound(_requestedRoundId);
        }
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    function decimals()
        external view
        returns (uint8)
    {
        return _feedDecimals;
    }

    function description()
        external view
        returns (string memory)
    {
        return _feedDescription;
    }

    function version()
        external pure
        returns (uint256)
    {
        return 1;
    }

    function _record(
        int256 _newAnswer,
        uint256 _timestamp
    )
        private
    {
        _roundId += 1;
        _answer = _newAnswer;
        _updatedAt = _timestamp;
        emit AnswerSet(_roundId, _newAnswer, _timestamp);
    }
}
