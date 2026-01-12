// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice 只取你 BlindBoxNFT 用得到的 view 方法
interface IBlindBoxNFTView {
    function open(uint256 tokenId) external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);

    function boxInfo(uint256 tokenId)
        external
        view
        returns (
            uint8 tier,
            uint256 usdtPaid,
            uint64 mintedAt,
            uint64 openedAt,
            int256 reward,
            uint64 rewardSetAt,
            uint256 tokenIdInStruct
        );
}

/// @title 本金可提合约（按 reward 与 paid 规则计算）
/// @notice 合约需要自己持有足够的 USDT 才能给用户提现（外部转账充值即可）
contract BlindBoxPrincipalVault is AccessControl, ReentrancyGuard {
    // 超管：DEFAULT_ADMIN_ROLE
    // 管理员：ADMIN_ROLE（可 setRewardOnce）
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    IBlindBoxNFTView public immutable nft;
    IERC20 public immutable usdt; // BSC USDT: 0x55d398...

    struct PrincipalInfo {
        uint256 amount;      // 本 tokenId 对应可提本金
        bool isSet;          // 是否已经设置过（只能一次）
        bool withdrawn;      // ✅ 是否已提取（提过不能再提）
        address beneficiary; // ✅ 设置时绑定受益人（= setRewardOnce 时 tokenId 的 owner）
    }

    /// @notice tokenId => 本金记录
    mapping(uint256 => PrincipalInfo) public principalInfoOfToken;

    /// @notice user => 剩余可提总额（用于前端展示；提现只允许按 tokenId）
    mapping(address => uint256) public withdrawableOf;

    // -------------------- Events --------------------
    event PrincipalSetOnce(
        address indexed operator,
        uint256 indexed tokenId,
        address indexed beneficiary,
        int256 reward,
        uint256 paid,
        uint256 principalAmount,
        uint256 newUserWithdrawable
    );

    event PrincipalWithdrawn(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 remaining,
        uint256 timestamp
    );

    event ERC20Withdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(address nftAddress) {
        require(nftAddress != address(0), "NFT=0");
        nft = IBlindBoxNFTView(nftAddress);

        // ✅ 固定 BSC USDT 地址
        usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // 超管
        _grantRole(ADMIN_ROLE, msg.sender);         // 默认也给管理员权限
    }

    // ============================================================
    //                  管理员：设置本金（一次性）
    // ============================================================

    /// @notice 参考 NFT setRewardOnce：这里只做“本金可提”计算与入账
    function setRewardOnce(uint256 tokenId, int256 reward_) external onlyRole(ADMIN_ROLE) nonReentrant {
        // 1) 必须已开盒
        require(nft.open(tokenId) == true, "must be opened");

        // 2) 不可二次设置
        PrincipalInfo storage pi = principalInfoOfToken[tokenId];
        require(pi.isSet == false, "principal already set");

        // 3) 取 paid（铸造本金）
        (, uint256 paid, , , , ,) = nft.boxInfo(tokenId);

        // 4) 计算 principalAmount
        // reward > paid  => principal = paid
        // 0 < reward <= paid => principal = reward
        // reward <= 0 => principal = 0
        uint256 principalAmount = 0;
        if (reward_ > 0) {
            uint256 r = uint256(reward_);
            principalAmount = (r > paid) ? paid : r;
        }

        // 5) 绑定受益人 = 设置时 token 当前 owner（避免转手后被新 owner 提走）
        address beneficiary = nft.ownerOf(tokenId);

        // 6) 写入 tokenId 记录（即使 amount=0 也算设置过，防止二次调用）
        pi.amount = principalAmount;
        pi.isSet = true;
        pi.withdrawn = false;
        pi.beneficiary = beneficiary;

        // 7) 记入用户总可提余额（用于展示）
        if (principalAmount > 0) {
            withdrawableOf[beneficiary] += principalAmount;
        }

        emit PrincipalSetOnce(
            msg.sender,
            tokenId,
            beneficiary,
            reward_,
            paid,
            principalAmount,
            withdrawableOf[beneficiary]
        );
    }

    // ============================================================
    //                     用户：提现（只能按 tokenId）
    // ============================================================

    /// @notice ✅ 用户只能按 tokenId 提取该 tokenId 对应本金；提取过就不能再提
    function withdrawByTokenId(uint256 tokenId) external nonReentrant returns (uint256 sent) {
        PrincipalInfo storage pi = principalInfoOfToken[tokenId];

        require(pi.isSet == true, "principal not set");
        require(pi.withdrawn == false, "already withdrawn");
        require(pi.amount > 0, "principal=0");
        require(pi.beneficiary == msg.sender, "not beneficiary");

        uint256 amount = pi.amount;

        // 标记已提取（先写状态防重入）
        pi.withdrawn = true;

        // 同步扣减用户剩余可提
        // （理论上一定 >= amount，因为 setRewardOnce 时加过；这里做个保护）
        uint256 userBal = withdrawableOf[msg.sender];
        if (userBal <= amount) {
            withdrawableOf[msg.sender] = 0;
        } else {
            withdrawableOf[msg.sender] = userBal - amount;
        }

        // 只用 transfer（低级 call 兼容不标准返回值）
        _safeTransfer(address(usdt), msg.sender, amount);

        emit PrincipalWithdrawn(msg.sender, tokenId, amount, withdrawableOf[msg.sender], block.timestamp);
        return amount;
    }

    // ============================================================
    //                 超管：可提现任意 ERC20（含 USDT）
    // ============================================================

    function withdrawERC20(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(to != address(0), "to=0");
        _safeTransfer(token, to, amount);
        emit ERC20Withdrawn(token, to, amount);
    }

    // ============================================================
    //                      internal helpers
    // ============================================================

    /// @dev 仅依赖 ERC20 的 transfer(selector=0xa9059cbb)，兼容返回 bool / 不返回值 两种情况
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));

        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }
}
