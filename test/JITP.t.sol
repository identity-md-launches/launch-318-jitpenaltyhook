// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JITP} from "../src/JITP.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract JITPTest is Test {
    JITP private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new JITP();
    }

    function test_fixedMetadataAndEntireSupplyToActualDeployer() public {
        assertEq(token.name(), "JIT Guard");
        assertEq(token.symbol(), "JITP");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        vm.prank(ALICE);
        JITP other = new JITP();
        assertEq(other.balanceOf(ALICE), other.totalSupply());
        assertEq(other.balanceOf(address(this)), 0);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        vm.prank(ALICE);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(ALICE), amount);
    }

    function test_allowanceAndInfiniteApproval() public {
        token.approve(ALICE, 100);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 40));
        assertEq(token.allowance(address(this), ALICE), 60);
        assertEq(token.balanceOf(BOB), 40);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 40);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
    }

    function test_failuresPreserveBalances() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_noMintAdminUpgradeOrBurnEntrypoints() public {
        bytes4[8] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("mint(uint256)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("setOwner(address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("initialize(address)")),
            bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("setMinter(address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool deployerOK,) = address(token).call(abi.encodeWithSelector(selectors[i], ALICE, 1 ether));
            assertFalse(deployerOK);
            vm.prank(ALICE);
            (bool strangerOK,) = address(token).call(abi.encodeWithSelector(selectors[i], ALICE, 1 ether));
            assertFalse(strangerOK);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(ALICE), 0);
    }
}
