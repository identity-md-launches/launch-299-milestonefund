// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MilestoneFund} from "../../src/MilestoneFund.sol";

/// @dev Backer that re-enters MilestoneFund from the token transfer hook during its rage-quit payout.
contract ReentrantBacker {
    MilestoneFund public immutable fund;
    uint256 public raiseId;
    uint256 public attempts;
    bool public reenterSucceeded;

    constructor(MilestoneFund fund_) {
        fund = fund_;
    }

    function join(uint256 raiseId_, uint256 amount) external {
        raiseId = raiseId_;
        IERC20(address(fund.token())).approve(address(fund), amount);
        fund.deposit(raiseId_, amount);
    }

    bool private armed;

    function quit() external {
        armed = true;
        fund.rageQuit(raiseId);
        armed = false;
    }

    function onTokenTransfer(address, uint256) external {
        if (!armed) return; // ignore plain funding transfers from the test
        if (attempts++ == 0) {
            // Try to be paid twice by quitting again while the first payout is in flight.
            try fund.rageQuit(raiseId) {
                reenterSucceeded = true;
            } catch {}
        }
    }
}

/// @dev Creator that re-enters withdraw() from the token transfer hook during its withdrawal.
contract ReentrantCreator {
    MilestoneFund public immutable fund;
    uint256 public attempts;
    bool public reenterSucceeded;

    constructor(MilestoneFund fund_) {
        fund = fund_;
    }

    function open(uint16 a, uint16 b, uint16 c, uint64 d) external returns (uint256) {
        return fund.open(a, b, c, d);
    }

    bool private armed;

    function withdraw() external {
        armed = true;
        fund.withdraw();
        armed = false;
    }

    function onTokenTransfer(address, uint256) external {
        if (!armed) return;
        if (attempts++ == 0) {
            try fund.withdraw() {
                reenterSucceeded = true;
            } catch {}
        }
    }
}
