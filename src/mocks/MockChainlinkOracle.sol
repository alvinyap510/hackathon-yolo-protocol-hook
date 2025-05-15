// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockChainlinkOracle {
    int256 private latestAnswer_;
    string public description_;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    constructor(int256 initialAnswer, string memory _description) {
        latestAnswer_ = initialAnswer;
        description_ = _description;
        emit AnswerUpdated(initialAnswer, 0, block.timestamp);
    }

    function latestAnswer() external view returns (int256) {
        return latestAnswer_;
    }

    function updateAnswer(int256 newAnswer) external {
        latestAnswer_ = newAnswer;
        emit AnswerUpdated(newAnswer, 0, block.timestamp);
    }

    function getTokenType() external pure returns (uint256) {
        return 1;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, latestAnswer_, block.timestamp, block.timestamp, 0);
    }

    function description() external view returns (string memory) {
        return description_;
    }
}
