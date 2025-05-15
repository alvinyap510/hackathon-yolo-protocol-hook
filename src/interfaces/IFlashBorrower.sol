//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFlashBorrower {
    function onFlashLoan(address _initiator, address _token, uint256 _amount, uint256 _fee, bytes calldata _data)
        external;

    function onBatchFlashLoan(
        address _initiator,
        address[] calldata _tokens,
        uint256[] calldata _amounts,
        uint256[] calldata _fees,
        bytes calldata _data
    ) external;
}
