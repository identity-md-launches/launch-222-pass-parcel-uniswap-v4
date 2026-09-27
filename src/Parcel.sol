// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply token. The deploying launch factory receives the entire supply.
contract Parcel is ERC20 {
    constructor() ERC20("Parcel", "PRCL") {
        _mint(msg.sender, 1e27);
    }
}
