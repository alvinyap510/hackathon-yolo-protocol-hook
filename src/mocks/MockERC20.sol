// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockERC20
 * @author 0xyolodev.eth
 * @dev ERC20 Token with mint and burn capabilities, for testing purposes.
 */
contract MockERC20 is ERC20, ERC20Burnable, Ownable {
    constructor(string memory name, string memory symbol, uint256 initialSupply)
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        _mint(msg.sender, initialSupply);
    }

    /**
     * @dev Mint new tokens to a specific address.
     * @param to The address to receive the minted tokens.
     * @param amount The amount of tokens to be minted.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Burn tokens from a specific address.
     * @param from The address to burn tokens from.
     * @param amount The amount of tokens to be burned.
     */
    function burnFrom(address from, uint256 amount) public override onlyOwner {
        _burn(from, amount);
    }
}
