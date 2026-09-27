// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/// @dev Test-only shared router. No position ownership checks; never deploy this for users.
contract LiquidityRouter is IUnlockCallback {
    using CurrencySettler for Currency;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        returns (BalanceDelta delta, BalanceDelta fees)
    {
        (delta, fees) = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta, BalanceDelta));
        if (address(this).balance != 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address payer, PoolKey memory key, ModifyLiquidityParams memory params) =
            abi.decode(data, (address, PoolKey, ModifyLiquidityParams));
        (BalanceDelta delta, BalanceDelta fees) = manager.modifyLiquidity(key, params, "");
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta, fees);
    }

    function _settle(Currency currency, address payer, int128 delta) private {
        if (delta < 0) currency.settle(manager, payer, uint256(-int256(delta)), false);
        if (delta > 0) currency.take(manager, payer, uint128(delta), false);
    }
}
