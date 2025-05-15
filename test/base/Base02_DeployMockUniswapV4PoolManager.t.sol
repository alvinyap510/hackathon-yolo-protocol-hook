// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract Base02_DeployMockUniswapV4PoolManager is Test, Deployers {
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Initialize the pool with a fee of 3000 and a starting price
        (poolKey, poolId) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        emit log_named_address("Deployed Pool Manager", address(manager));
        emit log_named_address("Currency 0", Currency.unwrap(currency0));
        emit log_named_address("Currency 1", Currency.unwrap(currency1));
    }

    function test01_Base02_SwapCurrency0ToCurrency1() public {
        int256 amountIn = 1000 * 1e18;
        bytes memory hookData = bytes("");

        BalanceDelta delta = swap(poolKey, true, amountIn, hookData);

        emit log_named_int("Currency0 Change", delta.amount0());
        emit log_named_int("Currency1 Change", delta.amount1());

        assert(delta.amount0() < 0);
        assert(delta.amount1() > 0);
    }

    function test02_Base02_SwapCurrency1ToCurrency0() public {
        int256 amountIn = 1000 * 1e18;
        bytes memory hookData = bytes("");

        BalanceDelta delta = swap(poolKey, false, amountIn, hookData);

        emit log_named_int("Currency0 Change", delta.amount0());
        emit log_named_int("Currency1 Change", delta.amount1());

        assert(delta.amount1() < 0);
        assert(delta.amount0() > 0);
    }
}
