// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Config {
    struct Asset {
        string name;
        string symbol;
        uint256 initialSupply;
    }

    struct Oracle {
        string description;
        int256 initialPrice;
    }

    Asset[] internal assets;
    Oracle[] internal oracles;

    constructor() {
        // Initialize Assets
        assets.push(Asset("Mock DAI", "DAI", 100_000_000 * 1e18));
        assets.push(Asset("Mock USDC", "USDC", 100_000_000 * 1e6));
        assets.push(Asset("Mock USDT", "USDT", 100_000_000 * 1e6));
        assets.push(Asset("Mock USDe", "USDe", 100_000_000 * 1e18));
        assets.push(Asset("Mock WBTC", "WBTC", 100_000_000 * 1e8));
        assets.push(Asset("Mock PT-sUSDe-31JUL2025", "PT-sUSDe-31JUL2025", 10_000_000 * 1e18));
        assets.push(Asset("Mock wstETH", "wstETH", 10_000_000 * 1e18));


        // Initialize Oracles
        oracles.push(Oracle("DAI / USD", 1 * 1e8));
        oracles.push(Oracle("USDC / USD", 1 * 1e8));
        oracles.push(Oracle("USDT / USD", 1 * 1e8));
        oracles.push(Oracle("USDe / USD", 1 * 1e8));
        oracles.push(Oracle("BTC / USD", 104_000 * 1e8));
        oracles.push(Oracle("PT-sUSDe-31JUL2025 / USD", 2_600 * 1e8));
        oracles.push(Oracle("wstETH / USD", 3_061_441_798_33));
        oracles.push(Oracle("ETH / USD", 2_600 * 1e8));
    }

    function getAssetsLength() public view returns (uint256) {
        return assets.length;
    }

    function getAssetName(uint256 index) public view returns (string memory) {
        return assets[index].name;
    }

    function getAssetSymbol(uint256 index) public view returns (string memory) {
        return assets[index].symbol;
    }

    function getAssetInitialSupply(uint256 index) public view returns (uint256) {
        return assets[index].initialSupply;
    }

    function getOraclesLength() public view returns (uint256) {
        return oracles.length;
    }

    function getOracleDescription(uint256 index) public view returns (string memory) {
        return oracles[index].description;
    }

    function getOracleInitialPrice(uint256 index) public view returns (int256) {
        return oracles[index].initialPrice;
    }
}
