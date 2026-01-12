// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBlindBoxNFT is IERC721 {
    function list(uint256 tokenId) external;
    function unlist(uint256 tokenId) external;
}

contract BlindBoxUserVault is Initializable, IERC721Receiver {
    using SafeERC20 for IERC20;

    address public owner;        // 用户钱包
    IBlindBoxNFT public nft;     // BlindBoxNFT
    IERC20 public usdt;          // USDT(18)

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    /// @dev 模板合约禁止被初始化（只允许 clone 后 initialize）
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address nft_, address usdt_) external initializer {
        require(owner_ != address(0), "OWNER_0");
        require(nft_ != address(0), "NFT_0");
        require(usdt_ != address(0), "USDT_0");

        owner = owner_;
        nft = IBlindBoxNFT(nft_);
        usdt = IERC20(usdt_);
    }

    /// 批量上架（1笔交易）
    /// 前置：用户在 BlindBoxNFT 上 setApprovalForAll(vault, true)
    function batchDepositAndList(uint256[] calldata tokenIds) external onlyOwner {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            // 1) 从用户拉到 vault（需要 setApprovalForAll）
            nft.safeTransferFrom(owner, address(this), tokenId);

            // 2) vault 作为 owner 调用 list（list 内部会把 token 托管进 BlindBoxNFT 合约）
            nft.list(tokenId);
        }
    }

    /// 批量下架并直接转回用户钱包（1笔交易）
    function batchUnlistToOwner(uint256[] calldata tokenIds) external onlyOwner {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            // unlist 会把 token 从 BlindBoxNFT escrow 退回到 seller(vault)
            nft.unlist(tokenId);

            // 退回后 vault 立刻转给用户钱包
            nft.safeTransferFrom(address(this), owner, tokenId);
        }
    }

    /// 提现：把 vault 内的全部 USDT 提给用户钱包
    function withdrawAllUSDT() external onlyOwner {
        uint256 bal = usdt.balanceOf(address(this));
        if (bal > 0) {
            usdt.safeTransfer(owner, bal);
        }
    }

    /// 必须实现：接收 NFT（safeTransferFrom / unlist 退回都会走这里）
    function onERC721Received(
        address, address, uint256, bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
