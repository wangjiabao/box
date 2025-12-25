// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

interface IBlindBoxNFTPieceHook {
    function holdingAdd(address user, uint256 burnAmount) external;
}

contract Piece is ERC20, ERC20Burnable, ERC20Permit, AccessControl {
    address public nft; // BlindBoxNFT 地址

    event NFTChanged(address indexed oldNFT, address indexed newNFT);

    constructor(
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _mint(0x8e5BE35252401b54BA6a2DC951F0cEcF8Fc582E1, 1171350625 * 1e18);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function setNFT(address newNFT) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = nft;
        nft = newNFT;
        emit NFTChanged(old, newNFT);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20) {
        super._update(from, to, value);

        // burn: to == 0
        if (to == address(0) && from != address(0) && value > 0) {
            address nftAddr = nft;
            require(nftAddr != address(0), "NFT_NOT_SET");
            IBlindBoxNFTPieceHook(nftAddr).holdingAdd(from, value);
        }
    }
}
