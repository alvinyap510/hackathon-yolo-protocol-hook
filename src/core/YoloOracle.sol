// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@yolo/contracts/interfaces/IPriceOracle.sol";

/**
 * @title   YoloOracle
 * @author  0xyolodev.eth
 * @notice  Functions as the single place to aggregate all price feed sources. Price sources were used to
 *          track collateral assets' price, Yolo assets reference price for health factor monitoring and
 *          liquidation purpose.
 * @dev     Based on AaveV3's AaveOracle.sol.
 *          WARNING: SIMPLIFIED FOR HACKATHON PURPOSE, NOT READY FOR PRODUCTION
 */
contract YoloOracle is Ownable {
    address public hook;

    address public anchor;

    mapping(address => IPriceOracle) private assetsSources;

    event AssetSourceUpdated(address indexed asset, address indexed source);

    event AnchorSet(address indexed anchor);

    event HookSet(address indexed hook);

    modifier onlyOwnerOrHook() {
        require(msg.sender == hook || msg.sender == owner());
        _;
    }

    constructor(address[] memory assets, address[] memory sources) Ownable(msg.sender) {
        _setAssetsSources(assets, sources);
    }

    function setAssetSources(address[] calldata assets, address[] calldata sources) external onlyOwnerOrHook {
        _setAssetsSources(assets, sources);
    }

    function _setAssetsSources(address[] memory assets, address[] memory sources) internal {
        require(assets.length == sources.length, "YoloOracle: params length mismatched");
        for (uint256 i = 0; i < assets.length; i++) {
            require(sources[i] != address(0), "YoloOracle: cannot set address(0) as price source");
            assetsSources[assets[i]] = IPriceOracle(sources[i]);
            emit AssetSourceUpdated(assets[i], sources[i]);
        }
    }

    function getAssetPrice(address asset) public view returns (uint256) {
        if (anchor != address(0) && asset == anchor) return 1e8;
        IPriceOracle source = assetsSources[asset];
        require(address(source) != address(0), "YoloOracle: unsupported asset");

        int256 price = source.latestAnswer();

        if (price > 0) return uint256(price);
        else return 0;
    }

    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = getAssetPrice(assets[i]);
        }
        return prices;
    }

    function getSourceOfAsset(address asset) external view returns (address) {
        return address(assetsSources[asset]);
    }

    // Set the anchor (YoloUSD), can only be set onceclear
    function setAnchor(address _anchor) external onlyOwner {
        require(anchor == address(0), "YoloOracle: anchor already set");
        anchor = _anchor;
        emit AnchorSet(_anchor);
    }

    function setHook(address _hook) external onlyOwner {
        hook = _hook;
        emit HookSet(_hook);
    }
}
