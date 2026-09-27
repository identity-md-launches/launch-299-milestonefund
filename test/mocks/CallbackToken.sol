// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITransferHook {
    function onTokenTransfer(address from, uint256 amount) external;
}

/// @dev Test-only ERC-20 that notifies contract recipients on every transfer, like an ERC-777 style token.
///      TRNC has no such hook; this exists only to prove MilestoneFund's reentrancy guard holds even if it did.
contract CallbackToken is ERC20 {
    constructor() ERC20("Callback", "CB") {
        _mint(msg.sender, 10 ** 27);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to.code.length > 0 && from != address(0)) {
            // Best effort: recipients without the hook (such as MilestoneFund itself) are simply skipped.
            try ITransferHook(to).onTokenTransfer(from, value) {} catch {}
        }
    }
}
