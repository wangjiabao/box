// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice NFT 合约需要提供的接口：查询某地址“盲盒持有价值(USDT,18位)”
interface IBlindBoxValue {
    function holdingValueOf(address user) external view returns (uint256);
}

/// @title UmbrellaStakeDividend
/// @notice
/// - 推荐网：parentOf[user]、childrenOf[parent]、topOf[user]
/// - 质押：stake A（18位），minStakeA 可调
/// - setReward：仅 NFT 合约可调用，传入 holder + profit(USDT)
/// - 分红：profit 的 refProfitBps% 进入“分配池”，其余归用户可提
///   分配池：
///   - 先由 1级上级B的“持有价值”决定给(B,C)的比例；剩余给(项目方+顶级)平分(顶级需满足条件)
///   - (B,C)之间按 (BValue*2) : (CValue*1) 分配（权重倍数可调）
/// - 顶级分红条件：
///   1) topEnabled[top]==true（管理员开关）
///   2) stakedA[top] >= minStakeA
contract UmbrellaStakeDividend is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    IERC20 public immutable aToken;   // A token (18 decimals)
    IERC20 public immutable usdt;     // USDT (18 decimals)

    /// @notice 项目方地址（拿项目份额，也可 claim）
    address public projectAddress;

    /// @notice 唯一允许调用 setReward 的 NFT 合约地址
    address public nftContract;

    /// @notice 分红使用的 NFT 合约接口（用于查 B/C 的持有价值）
    IBlindBoxValue public nftValueReader;

    // -------------------- staking --------------------
    uint256 public minStakeA; // 最低质押数量（18位）
    mapping(address => uint256) public stakedA;
    uint256 public totalStakedA;

    // -------------------- referral graph --------------------
    mapping(address => bool) public registered;
    mapping(address => address) public parentOf; // 直属上级
    mapping(address => address) public topOf;    // 顶级(伞顶)

    mapping(address => address[]) private _childrenOf; // 下级数组

    function childrenLength(address u) external view returns (uint256) {
        return _childrenOf[u].length;
    }

    function getChildrenByPage(address u, uint256 start, uint256 count) external view returns (address[] memory out) {
        uint256 len = _childrenOf[u].length;
        if (start >= len) return new address[](0);
        uint256 end = start + count;
        if (end > len) end = len;

        out = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = _childrenOf[u][i];
        }
    }

    // -------------------- top eligibility --------------------
    mapping(address => bool) public topEnabled; // 管理员开关

    function isTopEligible(address top) public view returns (bool) {
        if (top == address(0)) return false;
        if (!topEnabled[top]) return false;
        return stakedA[top] >= minStakeA;
    }

    // -------------------- reward accounting (USDT) --------------------
    mapping(address => uint256) public pendingUsdt;
    mapping(address => uint256) public totalEarnedUsdt;

    // -------------------- configs --------------------
    uint256 public bpsDenominator = 10_000;

    /// @notice profit 的多少进入“分配池”（默认 10%）
    uint256 public refProfitBps = 1_000; // 10%

    /// @notice B(1级上级)持有价值阈值（USDT, 18位）
    uint256 public holdValueMin = 300e18;
    uint256 public holdValueMax = 10_000e18;

    /// @notice 当 B >= holdValueMin 时，给(B,C)的比例至少为 20%
    uint256 public minUplinePortionBps = 2_000; // 20%

    /// @notice (B,C)权重倍数（示例：B*2, C*1）
    uint256 public level1WeightMul = 2;
    uint256 public level2WeightMul = 1;

    // -------------------- events --------------------
    event ProjectAddressChanged(address indexed oldAddr, address indexed newAddr);
    event NftContractChanged(address indexed oldNft, address indexed newNft);

    event Registered(address indexed user, address indexed parent, address indexed top);
    event TopEnabledSet(address indexed top, bool enabled);

    event MinStakeSet(uint256 newMinStake);
    event Staked(address indexed user, uint256 amount, uint256 newTotal);
    event Unstaked(address indexed user, uint256 amount, uint256 newTotal);

    event ConfigBpsDenominator(uint256 denom);
    event ConfigRefProfit(uint256 refProfitBps);
    event ConfigHoldRange(uint256 minValue, uint256 maxValue, uint256 minUplinePortionBps);
    event ConfigWeightMul(uint256 level1Mul, uint256 level2Mul);

    event RewardNotified(
        address indexed user,
        uint256 profit,
        uint256 userShare,
        address indexed l1,
        address indexed l2,
        address top,
        uint256 pool,
        uint256 uplinePortionBps,
        uint256 toL1,
        uint256 toL2,
        uint256 toTop,
        uint256 toProject
    );

    event Claimed(address indexed user, address indexed to, uint256 amount);

    constructor(
        address aToken_,
        address usdt_,
        address project_
    ) {
        require(aToken_ != address(0) && usdt_ != address(0), "ZERO_TOKEN");
        require(project_ != address(0), "ZERO_PROJECT");

        aToken = IERC20(aToken_);
        usdt = IERC20(usdt_);
        projectAddress = project_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    // -------------------- admin setters --------------------

    function setProjectAddress(address p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(p != address(0), "ZERO_PROJECT");
        address old = projectAddress;
        projectAddress = p;
        emit ProjectAddressChanged(old, p);
    }

    /// @notice 设置允许调用 setReward 的 NFT 合约，并作为持有价值读取源
    function setNftContract(address nft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(nft != address(0), "ZERO_NFT");
        address old = nftContract;
        nftContract = nft;
        nftValueReader = IBlindBoxValue(nft);
        emit NftContractChanged(old, nft);
    }

    function setMinStakeA(uint256 m) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minStakeA = m;
        emit MinStakeSet(m);
    }

    function setTopEnabled(address top, bool enabled) external onlyRole(MANAGER_ROLE) {
        require(top != address(0), "ZERO_TOP");
        topEnabled[top] = enabled;
        emit TopEnabledSet(top, enabled);
    }

    function setBpsDenominator(uint256 denom) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(denom > 0, "DENOM=0");
        bpsDenominator = denom;
        emit ConfigBpsDenominator(denom);
    }

    function setRefProfitBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bps <= bpsDenominator, "BPS_TOO_BIG");
        refProfitBps = bps;
        emit ConfigRefProfit(bps);
    }

    function setHoldValueConfig(uint256 minV, uint256 maxV, uint256 minPortionBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(maxV > 0 && maxV >= minV, "BAD_RANGE");
        require(minPortionBps <= bpsDenominator, "BAD_MIN_PORTION");
        holdValueMin = minV;
        holdValueMax = maxV;
        minUplinePortionBps = minPortionBps;
        emit ConfigHoldRange(minV, maxV, minPortionBps);
    }

    function setWeightMultipliers(uint256 l1Mul, uint256 l2Mul) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(l1Mul > 0 && l2Mul > 0, "MUL=0");
        level1WeightMul = l1Mul;
        level2WeightMul = l2Mul;
        emit ConfigWeightMul(l1Mul, l2Mul);
    }

    // -------------------- register --------------------

    /// @notice 注册：parent 为上级地址；若 parent==0 则自己成为顶级（伞顶）
    /// @dev 若要注册到某上级下：必须满足「该伞顶 top 已质押 >= minStakeA」
    function register(address parent) external {
        address user = msg.sender;
        require(!registered[user], "ALREADY_REGISTERED");
        require(parent != user, "PARENT_SELF");

        if (parent == address(0)) {
            // 自己成为顶级
            registered[user] = true;
            parentOf[user] = address(0);
            topOf[user] = user;

            // 顶级默认开启（管理员可关）
            topEnabled[user] = true;

            emit Registered(user, address(0), user);
            return;
        }

        require(registered[parent], "PARENT_NOT_REGISTERED");
        address top = topOf[parent];
        require(top != address(0), "BAD_TOP");

        // 允许挂靠到该伞顶的条件：伞顶质押达到最低值
        require(stakedA[top] >= minStakeA, "TOP_STAKE_TOO_LOW");

        registered[user] = true;
        parentOf[user] = parent;
        topOf[user] = top;

        _childrenOf[parent].push(user);

        emit Registered(user, parent, top);
    }

    // -------------------- staking A --------------------

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "AMOUNT=0");
        aToken.safeTransferFrom(msg.sender, address(this), amount);
        stakedA[msg.sender] += amount;
        totalStakedA += amount;
        emit Staked(msg.sender, amount, stakedA[msg.sender]);
    }

    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "AMOUNT=0");
        uint256 bal = stakedA[msg.sender];
        require(bal >= amount, "INSUFFICIENT_STAKE");
        stakedA[msg.sender] = bal - amount;
        totalStakedA -= amount;
        aToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, stakedA[msg.sender]);
    }

    // -------------------- claim USDT --------------------

    function claimAll(address to) external nonReentrant returns (uint256 claimed) {
        require(to != address(0), "TO=0");
        claimed = pendingUsdt[msg.sender];
        require(claimed > 0, "NOTHING");
        pendingUsdt[msg.sender] = 0;
        usdt.safeTransfer(to, claimed);
        emit Claimed(msg.sender, to, claimed);
    }

    function claim(address to, uint256 amount) external nonReentrant {
        require(to != address(0), "TO=0");
        require(amount > 0, "AMOUNT=0");
        uint256 p = pendingUsdt[msg.sender];
        require(p >= amount, "INSUFFICIENT_PENDING");
        pendingUsdt[msg.sender] = p - amount;
        usdt.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    // -------------------- core: setReward --------------------

    modifier onlyNft() {
        require(msg.sender == nftContract, "ONLY_NFT");
        _;
    }

    /// @notice NFT 合约调用：通知某 user 本次盈利 profit(USDT 18位)
    /// @dev 这里仅做“记账分配”，不从 NFT 拉钱；USDT 应由 NFT mint 转入本合约等方式保证余额充足
    function setReward(address user, uint256 profit) external onlyNft nonReentrant {
        require(user != address(0), "USER=0");
        require(profit > 0, "PROFIT=0");
        require(projectAddress != address(0), "PROJECT=0");
        require(address(nftValueReader) != address(0), "NFT_READER=0");

        // 如果用户没注册，则默认他是一个新的顶级伞（避免 setReward 失败）
        if (!registered[user]) {
            registered[user] = true;
            parentOf[user] = address(0);
            topOf[user] = user;
            topEnabled[user] = true;
            emit Registered(user, address(0), user);
        }

        uint256 pool = Math.mulDiv(profit, refProfitBps, bpsDenominator);
        uint256 userShare = profit - pool;

        _addPending(user, userShare);

        address l1 = parentOf[user];
        address l2 = (l1 == address(0)) ? address(0) : parentOf[l1];
        address top = topOf[user];
        if (top == address(0)) top = user;

        // 计算：给(B,C)的比例（由 B=l1 的持有价值决定）
        uint256 l1Value = (l1 == address(0)) ? 0 : nftValueReader.holdingValueOf(l1);
        uint256 uplinePortionBps = _calcUplinePortionBps(l1Value);

        uint256 uplinesPart = Math.mulDiv(pool, uplinePortionBps, bpsDenominator);
        uint256 rest = pool - uplinesPart; // 给项目方+顶级平分（顶级需合格）

        uint256 toL1 = 0;
        uint256 toL2 = 0;

        if (uplinesPart > 0 && l1 != address(0)) {
            uint256 l2Value = (l2 == address(0)) ? 0 : nftValueReader.holdingValueOf(l2);

            uint256 w1 = l1Value * level1WeightMul;
            uint256 w2 = l2Value * level2WeightMul;
            uint256 wSum = w1 + w2;

            if (wSum == 0) {
                rest += uplinesPart;
            } else {
                toL1 = Math.mulDiv(uplinesPart, w1, wSum);
                toL2 = uplinesPart - toL1;

                if (toL1 > 0) _addPending(l1, toL1);
                if (toL2 > 0 && l2 != address(0)) {
                    _addPending(l2, toL2);
                } else if (toL2 > 0) {
                    // 没有 l2，则给项目方
                    _addPending(projectAddress, toL2);
                    toL2 = 0;
                }
            }
        } else if (uplinesPart > 0) {
            // 没有 l1，则全并入 rest
            rest += uplinesPart;
        }

        uint256 toTop = 0;
        uint256 toProject = 0;

        if (rest > 0) {
            if (isTopEligible(top)) {
                toTop = rest / 2;
                toProject = rest - toTop;
                if (toTop > 0) _addPending(top, toTop);
                if (toProject > 0) _addPending(projectAddress, toProject);
            } else {
                toProject = rest;
                _addPending(projectAddress, toProject);
            }
        }

        emit RewardNotified(user, profit, userShare, l1, l2, top, pool, uplinePortionBps, toL1, toL2, toTop, toProject);
    }

    function _addPending(address u, uint256 amt) internal {
        if (amt == 0) return;
        pendingUsdt[u] += amt;
        totalEarnedUsdt[u] += amt;
    }

    /// @dev 规则：
    /// - 若 BValue < holdValueMin => 0%
    /// - 否则 bps = (BValue / holdValueMax) * 100%
    /// - 且 bps 至少 minUplinePortionBps（默认 20%）
    /// - bps 最大不超过 100%
    function _calcUplinePortionBps(uint256 bValue) internal view returns (uint256) {
        if (bValue < holdValueMin) return 0;
        if (holdValueMax == 0) return 0;

        uint256 bps = Math.mulDiv(bValue, bpsDenominator, holdValueMax);
        if (bps > bpsDenominator) bps = bpsDenominator;
        if (bps < minUplinePortionBps) bps = minUplinePortionBps;
        return bps;
    }
}
