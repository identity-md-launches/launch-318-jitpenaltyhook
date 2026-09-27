// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";

contract RuntimeSafetyTest is HookFixture {
    function test_tokenAndHookHaveNoEscapeOpcodes() public view {
        _scan(address(token).code);
        _scan(address(hook).code);
    }

    function _scan(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xff && op != 0xf2);
        }
    }
}
