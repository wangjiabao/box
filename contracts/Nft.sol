// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice 报价池接口：参考你给的 SwapHrxUsdt
///         约定：token1 = USDT(18), token0 = 代币B(18)
interface IToken0Token1AmmQuote {
    function token0() external view returns (address); // B
    function token1() external view returns (address); // USDT
    function liquidityInited() external view returns (bool);

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 ts);

    function feeNum() external view returns (uint32);
    function feeDen() external view returns (uint32);
}

/// @notice 质押分红合约接口：NFT 在 setRewardOnce 盈利时调用
interface IUmbrellaStakeDividend {
    function setReward(address user, uint256 profit) external;
}

/// @title BlindBox NFT + Escrow Marketplace + HoldingValue (BSC 18 decimals)
contract BlindBoxNFT is ERC721Enumerable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------- Roles --------------------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // -------------------- Constants --------------------
    uint256 public constant DECIMALS_18 = 1e18;
    uint256 public constant MONTH_SECONDS = 30 days;

    // open窗口：12:00~次日12:00
    uint256 public constant DAY_SHIFT_SECONDS = 12 hours;
    uint256 public constant BASE_DAILY_OPENS = 1;

    // -------------------- Adjustable Params (DEFAULT_ADMIN_ROLE can change) --------------------
    uint256 public bpsDenominator = 10_000;

    /// @notice mint 分账：给 AccountA 的 bps（默认 9800 = 98%）
    uint256 public accountAFeeBps = 9_800;

    /// @notice 新铸造 token 使用的默认线性月增长率（18位，例：0.04e18）
    uint256 public monthlyRateDefaultE18 = 4e16; // 0.04e18

    // -------------------- OpenBox extra BNB fee --------------------
    uint256 public openFeeBNB;          // wei
    address public openFeeReceiver;     // 收BNB地址

    // -------------------- Tokens --------------------
    IERC20 public immutable usdt;     // BSC USDT(18)
    IERC20 public aToken;             // A(18) - 买槽位
    address public accountA;          // 收费地址（mint 的 AccountA 部分 + 交易手续费收款）

    /// @notice 质押分红合约：mint 剩余 USDT 直接打给这里；盈利也会回调这里
    IUmbrellaStakeDividend public stakingContract;

    // B手续费计价：用你给的 SwapHrxUsdt 报价（token1=USDT, token0=B）
    IToken0Token1AmmQuote public feeQuotePool;
    IERC20 public feeTokenB; // = feeQuotePool.token0()

    // -------------------- Mint tier prices (fixed original mint price) --------------------
    mapping(uint8 => uint256) public tierPrice; // 1=>20,2=>50,3=>100 (18 decimals)

    // -------------------- NFT Data --------------------
    struct BoxInfo {
        uint8 tier;
        uint256 usdtPaid;     // 铸造原价（固定档位价），也是二级市场涨价基数
        uint64 mintedAt;
        uint64 openedAt;      // open时间（不可逆）
        int256 reward;
        uint64 rewardSetAt;   // 0=未设置；设置后不可再改
    }
    mapping(uint256 => BoxInfo) public boxInfo;

    /// @notice open 为 public，且不可逆
    mapping(uint256 => bool) public open;

    // -------------------- Arrays log --------------------
    uint256[] public mintedTokenIds;      // 所有铸造tokenId
    uint256[] public openActionTokenIds;  // 所有open动作tokenId

    // -------------------- TokenId Counter --------------------
    uint256 private _nextTokenId = 1;

    // -------------------- Daily open usage --------------------
    struct Usage {
        uint64 dayIndex; // (ts + 12h)/1d
        uint64 used;     // 当前窗口已用open次数
    }
    mapping(address => Usage) private _usage;

    // -------------------- Slots purchased with A --------------------
    mapping(address => uint256) public extraSlots; // 额外槽位（每天额外open次数）
    uint256 public globalSlotStepCost;                   // 全局步长a（管理员可改）
    mapping(address => uint256) public userSlotStepCost; // 用户个人步长a（首次购买锁定，管理员改不影响）

    // -------------------- Escrow Marketplace (no manual pricing) --------------------
    struct Listing {
        address seller;
        uint64 listedAt;
        bool active;
    }
    mapping(uint256 => Listing) public listings;

    /// @notice 当前正在上架(托管中)的 tokenId 列表（动态数组）
    uint256[] public listedTokenIds;
    mapping(uint256 => uint256) private _listedPosPlusOne; // tokenId => index+1

    // -------------------- Trade Fee (buyer extra pay) --------------------
    uint256 public feeRate;     // USDT fee: feeU = price * feeRate / feeBase
    uint256 public feeBase;

    uint256 public feeRateTwo;  // B fee: feeU = price * feeRateTwo / feeBaseTwo; feeB = quoteFeeInB(feeU)
    uint256 public feeBaseTwo;

    // -------------------- Holding Value (economic owner) --------------------
    /// @notice 经济持有者：用于“持有价值统计”
    /// - 上架/下架不改变
    /// - 成交购买时才切换到买家
    /// - open 后移除（置 0）
    mapping(uint256 => address) public economicHolder;

    /// @notice 每个 token 在 mint 时快照自己的增长率（避免你后续改默认 rate 导致历史估值失真）
    mapping(uint256 => uint256) public tokenMonthlyRateE18;

    /// @dev 聚合：Σ base
    mapping(address => uint256) private _sumBase;

    /// @dev 聚合：Σ (base * rateE18)
    mapping(address => uint256) private _sumBR;

    /// @dev 聚合：Σ (base * rateE18 * mintedAt)
    mapping(address => uint256) private _sumBRMinted;

    // -------------------- Events --------------------
    event ParamsChanged(uint256 bpsDenominator, uint256 accountAFeeBps, uint256 monthlyRateDefaultE18);
    event AccountAChanged(address indexed oldAccountA, address indexed newAccountA);
    event StakingContractChanged(address indexed oldStaking, address indexed newStaking);

    event OpenFeeConfigChanged(uint256 openFeeBNB, address openFeeReceiver);

    event ATokenChanged(address indexed oldToken, address indexed newToken);
    event GlobalSlotStepCostChanged(uint256 oldCost, uint256 newCost);

    event FeeQuotePoolChanged(address indexed pool, address indexed token0B);

    event TierPriceChanged(uint8 indexed tier, uint256 oldPrice, uint256 newPrice);

    event Minted(address indexed minter, uint256 indexed tokenId, uint8 indexed tier, uint256 usdtPaid);
    event Opened(address indexed owner, uint256 indexed tokenId, uint256 timestamp, uint256 bnbPaid);

    event RewardSetOnce(address indexed admin, uint256 indexed tokenId, int256 reward, uint256 timestamp, uint256 profitNotified);

    event SlotsPurchased(
        address indexed buyer,
        uint256 count,
        uint256 stepCostLocked,
        uint256 totalCost,
        uint256 newExtraSlots
    );

    event Listed(address indexed seller, uint256 indexed tokenId, uint256 timestamp);
    event Unlisted(address indexed operator, uint256 indexed tokenId);

    event Purchased(
        address indexed buyer,
        address indexed seller,
        uint256 indexed tokenId,
        uint256 priceUSDT,
        bool feePaidInB,
        uint256 feeUSDT,
        uint256 feeB
    );

    event FeeConfigUSDTChanged(uint256 rate, uint256 base);
    event FeeConfigBChanged(uint256 rateTwo, uint256 baseTwo);

    event ERC20Withdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        address usdt_,
        address aToken_,
        address accountA_,
        uint256 globalSlotStepCost_,
        address staking_
    ) ERC721(name_, symbol_) {
        require(usdt_ != address(0), "USDT=0");
        require(accountA_ != address(0), "AccountA=0");

        usdt = IERC20(usdt_);
        aToken = IERC20(aToken_);
        accountA = accountA_;
        globalSlotStepCost = globalSlotStepCost_;
        stakingContract = IUmbrellaStakeDividend(staking_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        // 固定原价（18位）
        tierPrice[1] = 20 * DECIMALS_18;
        tierPrice[2] = 50 * DECIMALS_18;
        tierPrice[3] = 100 * DECIMALS_18;

        // 默认手续费（示例）
        feeRate = 10;
        feeBase = 10_000;

        feeRateTwo = 50;
        feeBaseTwo = 10_000;
    }

    // ============================================================
    //                    Admin setters
    // ============================================================

    function setParams(uint256 denom, uint256 aFeeBps, uint256 monthlyRateDefault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(denom > 0, "DENOM=0");
        require(aFeeBps <= denom, "A_FEE_TOO_BIG");
        bpsDenominator = denom;
        accountAFeeBps = aFeeBps;
        monthlyRateDefaultE18 = monthlyRateDefault;
        emit ParamsChanged(denom, aFeeBps, monthlyRateDefault);
    }

    function setAccountA(address newAccountA) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAccountA != address(0), "AccountA=0");
        address old = accountA;
        accountA = newAccountA;
        emit AccountAChanged(old, newAccountA);
    }

    function setStakingContract(address newStaking) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = address(stakingContract);
        stakingContract = IUmbrellaStakeDividend(newStaking);
        emit StakingContractChanged(old, newStaking);
    }

    function setOpenFeeConfig(uint256 feeWei, address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        openFeeBNB = feeWei;
        openFeeReceiver = receiver;
        emit OpenFeeConfigChanged(feeWei, receiver);
    }

    function setOpenFeeBNB(uint256 feeWei) external onlyRole(DEFAULT_ADMIN_ROLE) {
        openFeeBNB = feeWei;
        emit OpenFeeConfigChanged(openFeeBNB, openFeeReceiver);
    }

    function setOpenFeeReceiver(address receiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        openFeeReceiver = receiver;
        emit OpenFeeConfigChanged(openFeeBNB, openFeeReceiver);
    }

    function setAToken(address newAToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = address(aToken);
        aToken = IERC20(newAToken);
        emit ATokenChanged(old, newAToken);
    }

    function setGlobalSlotStepCost(uint256 newCost) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = globalSlotStepCost;
        globalSlotStepCost = newCost;
        emit GlobalSlotStepCostChanged(old, newCost);
    }

    function setTierPrice(uint8 tier, uint256 newPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tier >= 1 && tier <= 3, "tier 1..3");
        require(newPrice > 0, "price=0");
        uint256 old = tierPrice[tier];
        tierPrice[tier] = newPrice;
        emit TierPriceChanged(tier, old, newPrice);
    }

    function setFeeConfigUSDT(uint256 rate, uint256 base) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(base != 0, "base=0");
        feeRate = rate;
        feeBase = base;
        emit FeeConfigUSDTChanged(rate, base);
    }

    function setFeeConfigB(uint256 rateTwo, uint256 baseTwo) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(baseTwo != 0, "baseTwo=0");
        feeRateTwo = rateTwo;
        feeBaseTwo = baseTwo;
        emit FeeConfigBChanged(rateTwo, baseTwo);
    }

    function setFeeQuotePool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pool != address(0), "pool=0");

        IToken0Token1AmmQuote p = IToken0Token1AmmQuote(pool);
        require(p.liquidityInited(), "POOL_NOT_INIT");
        require(p.token1() == address(usdt), "pool.token1!=USDT");

        address b = p.token0();
        require(b != address(0), "pool.token0=0");

        feeQuotePool = p;
        feeTokenB = IERC20(b);

        emit FeeQuotePoolChanged(pool, b);
    }

    // ============================================================
    //                           Minting
    // ============================================================

    function mint(uint8 tier) external nonReentrant returns (uint256 tokenId) {
        uint256 price = _requireTierPrice(tier);
        _collectUsdtMint(msg.sender, price);
        tokenId = _mintInternal(msg.sender, tier, price);
    }

    function mintBatch(uint8 tier, uint256 quantity) external nonReentrant returns (uint256[] memory tokenIds) {
        require(quantity > 0, "quantity=0");
        uint256 priceEach = _requireTierPrice(tier);
        uint256 total = priceEach * quantity;

        _collectUsdtMint(msg.sender, total);

        tokenIds = new uint256[](quantity);
        for (uint256 i = 0; i < quantity; i++) {
            tokenIds[i] = _mintInternal(msg.sender, tier, priceEach);
        }
    }

    function mintBatchWithTiers(uint8[] calldata tiers) external nonReentrant returns (uint256[] memory tokenIds) {
        uint256 n = tiers.length;
        require(n > 0, "tiers empty");

        uint256 total = 0;
        uint256[] memory prices = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            uint256 p = _requireTierPrice(tiers[i]);
            prices[i] = p;
            total += p;
        }

        _collectUsdtMint(msg.sender, total);

        tokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            tokenIds[i] = _mintInternal(msg.sender, tiers[i], prices[i]);
        }
    }

    function _requireTierPrice(uint8 tier) internal view returns (uint256 p) {
        require(tier >= 1 && tier <= 3, "tier 1..3");
        p = tierPrice[tier];
        require(p > 0, "tier price=0");
    }

    function _mintInternal(address to, uint8 tier, uint256 paid) internal returns (uint256 tokenId) {
        tokenId = _nextTokenId++;

        // 先写入 BoxInfo 与 tokenRate（保证 _update 钩子里可读）
        BoxInfo storage b = boxInfo[tokenId];
        b.tier = tier;
        b.usdtPaid = paid;
        b.mintedAt = uint64(block.timestamp);

        tokenMonthlyRateE18[tokenId] = monthlyRateDefaultE18;

        _safeMint(to, tokenId);

        mintedTokenIds.push(tokenId);

        emit Minted(to, tokenId, tier, paid);
    }

    /// @dev mint收款：toA 给 AccountA；其余直接给 stakingContract（不留在 NFT 合约）
    function _collectUsdtMint(address payer, uint256 total) internal {
        require(accountA != address(0), "AccountA not set");
        require(address(stakingContract) != address(0), "staking not set");

        uint256 toA = Math.mulDiv(total, accountAFeeBps, bpsDenominator);
        uint256 toStake = total - toA;

        if (toA > 0) usdt.safeTransferFrom(payer, accountA, toA);
        if (toStake > 0) usdt.safeTransferFrom(payer, address(stakingContract), toStake);
    }

    // ============================================================
    //                              Open (irreversible + BNB fee)
    // ============================================================

    function openBox(uint256 tokenId) external payable nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "only owner");
        require(open[tokenId] == false, "already opened");

        // 1) 收 BNB
        uint256 fee = openFeeBNB;
        if (fee == 0) {
            require(msg.value == 0, "NO_FEE_REQUIRED");
        } else {
            require(msg.value == fee, "BAD_BNB_FEE");
            address receiver = openFeeReceiver;
            require(receiver != address(0), "BNB_RECEIVER_0");
            (bool ok,) = receiver.call{value: fee}("");
            require(ok, "BNB_SEND_FAIL");
        }

        // 2) 消耗 open 次数
        _consumeOpenAllowance(msg.sender);

        // 3) open 后从“持有价值统计”移除（不可逆）
        address holder = economicHolder[tokenId];
        require(holder == msg.sender, "bad holder");

        uint256 base = boxInfo[tokenId].usdtPaid;
        uint256 rate = tokenMonthlyRateE18[tokenId];
        uint256 mAt = uint256(boxInfo[tokenId].mintedAt);

        _holdingRemove(holder, base, rate, mAt);
        economicHolder[tokenId] = address(0);

        open[tokenId] = true;
        boxInfo[tokenId].openedAt = uint64(block.timestamp);

        openActionTokenIds.push(tokenId);

        emit Opened(msg.sender, tokenId, block.timestamp, msg.value);
    }

    function _consumeOpenAllowance(address user) internal {
        uint256 dayIdx = _dayIndex(block.timestamp);

        Usage storage u = _usage[user];
        if (u.dayIndex != dayIdx) {
            u.dayIndex = uint64(dayIdx);
            u.used = 0;
        }

        uint256 limit = BASE_DAILY_OPENS + extraSlots[user];
        require(uint256(u.used) < limit, "open limit reached in this window");
        u.used += 1;
    }

    function _dayIndex(uint256 ts) internal pure returns (uint256) {
        return (ts + DAY_SHIFT_SECONDS) / 1 days;
    }

    // ============================================================
    //                        Reward (set once + notify staking)
    // ============================================================

    function setRewardOnce(uint256 tokenId, int256 reward_) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(_ownerOf(tokenId) != address(0), "nonexistent token");
        require(open[tokenId] == true, "must be opened");
        require(boxInfo[tokenId].rewardSetAt == 0, "reward already set");

        boxInfo[tokenId].reward = reward_;
        boxInfo[tokenId].rewardSetAt = uint64(block.timestamp);

        uint256 profitNotified = 0;

        if (reward_ > 0) {
            uint256 paid = boxInfo[tokenId].usdtPaid;
            if (uint256(reward_) > paid) {
                profitNotified = uint256(reward_) - paid;
                require(address(stakingContract) != address(0), "staking not set");
                address holder = ownerOf(tokenId); // open 后不可交易，owner稳定
                stakingContract.setReward(holder, profitNotified);
            }
        }

        emit RewardSetOnce(msg.sender, tokenId, reward_, block.timestamp, profitNotified);
    }

    // ============================================================
    //                    Buy open slots with A (user locks step)
    // ============================================================

    function buyOpenSlots(uint256 count) external nonReentrant {
        require(count > 0, "count=0");
        require(address(aToken) != address(0), "A token not set");
        require(accountA != address(0), "AccountA not set");

        uint256 step = userSlotStepCost[msg.sender];
        if (step == 0) {
            require(globalSlotStepCost > 0, "global step=0");
            step = globalSlotStepCost;
            userSlotStepCost[msg.sender] = step;
        }

        uint256 n = extraSlots[msg.sender];
        uint256 multiplierSum = (count * n) + ((count * (count + 1)) / 2);
        uint256 cost = step * multiplierSum;

        aToken.safeTransferFrom(msg.sender, accountA, cost);

        extraSlots[msg.sender] = n + count;

        emit SlotsPurchased(msg.sender, count, step, cost, n + count);
    }

    // ============================================================
    //                 Secondary Market Dynamic Price (linear, realtime)
    // ============================================================

    function secondaryBuyPrice(uint256 tokenId) public view returns (uint256 price) {
        require(_ownerOf(tokenId) != address(0), "nonexistent token");
        BoxInfo memory b = boxInfo[tokenId];
        require(b.mintedAt != 0, "not minted");

        uint256 base = b.usdtPaid;
        uint256 rate = tokenMonthlyRateE18[tokenId];

        uint256 elapsed = 0;
        if (block.timestamp > uint256(b.mintedAt)) {
            elapsed = block.timestamp - uint256(b.mintedAt);
        }

        // increment = base * rate * elapsed / (1e18 * 30days)
        uint256 numerator = rate * elapsed;
        uint256 inc = Math.mulDiv(base, numerator, DECIMALS_18 * MONTH_SECONDS);

        price = base + inc;
    }

    // ============================================================
    //                      Escrow Marketplace (no manual pricing)
    // ============================================================

    function listedTokenIdsLength() external view returns (uint256) {
        return listedTokenIds.length;
    }

    function getListedTokenIds(uint256 start, uint256 count) external view returns (uint256[] memory out) {
        uint256 len = listedTokenIds.length;
        if (start >= len) return new uint256[](0);

        uint256 end = start + count;
        if (end > len) end = len;

        out = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = listedTokenIds[i];
        }
    }

    function _addListedToken(uint256 tokenId) internal {
        require(_listedPosPlusOne[tokenId] == 0, "ALREADY_LISTED_IN_ARRAY");
        listedTokenIds.push(tokenId);
        _listedPosPlusOne[tokenId] = listedTokenIds.length; // index+1
    }

    function _removeListedToken(uint256 tokenId) internal {
        uint256 posPlusOne = _listedPosPlusOne[tokenId];
        require(posPlusOne != 0, "NOT_IN_LISTED_ARRAY");

        uint256 idx = posPlusOne - 1;
        uint256 lastIdx = listedTokenIds.length - 1;

        if (idx != lastIdx) {
            uint256 lastTokenId = listedTokenIds[lastIdx];
            listedTokenIds[idx] = lastTokenId;
            _listedPosPlusOne[lastTokenId] = idx + 1;
        }

        listedTokenIds.pop();
        delete _listedPosPlusOne[tokenId];
    }

    function list(uint256 tokenId) external nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "only owner");
        require(open[tokenId] == false, "must be unopened");
        require(!listings[tokenId].active, "already listed");

        _transfer(msg.sender, address(this), tokenId);

        listings[tokenId] = Listing({
            seller: msg.sender,
            listedAt: uint64(block.timestamp),
            active: true
        });

        _addListedToken(tokenId);

        emit Listed(msg.sender, tokenId, block.timestamp);
    }

    function unlist(uint256 tokenId) external nonReentrant {
        Listing memory lst = listings[tokenId];
        require(lst.active, "not listed");
        require(lst.seller == msg.sender || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "not seller/admin");

        // 先从数组移除（mapping 仍保留给底层 _update 判定）
        _removeListedToken(tokenId);

        _safeTransfer(address(this), lst.seller, tokenId, "");

        delete listings[tokenId];

        emit Unlisted(msg.sender, tokenId);
    }

    function _feeUSDT(uint256 priceUSDT) internal view returns (uint256) {
        if (feeRate == 0) return 0;
        require(feeBase != 0, "feeBase=0");
        return Math.mulDiv(priceUSDT, feeRate, feeBase);
    }

    function _feeUSDTForBMode(uint256 priceUSDT) internal view returns (uint256) {
        if (feeRateTwo == 0) return 0;
        require(feeBaseTwo != 0, "feeBaseTwo=0");
        return Math.mulDiv(priceUSDT, feeRateTwo, feeBaseTwo);
    }

    function quoteFeeInB(uint256 amount1InUSDT) public view returns (uint256 out0NetB) {
        require(address(feeQuotePool) != address(0), "quote pool not set");
        require(amount1InUSDT > 0, "ZERO_IN");

        require(feeQuotePool.liquidityInited(), "POOL_NOT_INIT");
        require(feeQuotePool.token1() == address(usdt), "pool.token1!=USDT");
        require(feeQuotePool.token0() == address(feeTokenB), "pool.token0!=B");

        (uint112 r0, uint112 r1,) = feeQuotePool.getReserves();
        require(r0 > 0 && r1 > 0, "NO_LIQ");

        uint256 grossMax = Math.mulDiv(uint256(r0), amount1InUSDT, uint256(r1) + amount1InUSDT);
        require(grossMax > 0, "INSUFFICIENT_IN");

        uint256 feeOut = Math.mulDiv(grossMax, uint256(feeQuotePool.feeNum()), uint256(feeQuotePool.feeDen()));
        out0NetB = grossMax - feeOut;
    }

    function buyPayFeeInUSDT(uint256 tokenId) external nonReentrant {
        Listing memory lst = listings[tokenId];
        require(lst.active, "not listed");

        require(open[tokenId] == false, "must be unopened");
        require(ownerOf(tokenId) == address(this), "escrow not holding");
        require(msg.sender != lst.seller, "self buy");

        uint256 price = secondaryBuyPrice(tokenId);
        uint256 feeU = _feeUSDT(price);

        // 先从数组移除（listing mapping 保留给 _update 判定成交迁移）
        _removeListedToken(tokenId);

        usdt.safeTransferFrom(msg.sender, lst.seller, price);

        if (feeU > 0) {
            usdt.safeTransferFrom(msg.sender, accountA, feeU);
        }

        _safeTransfer(address(this), msg.sender, tokenId, "");

        delete listings[tokenId];

        emit Purchased(msg.sender, lst.seller, tokenId, price, false, feeU, 0);
    }

    function buyPayFeeInB(uint256 tokenId, uint256 maxFeeB) external nonReentrant {
        Listing memory lst = listings[tokenId];
        require(lst.active, "not listed");

        require(open[tokenId] == false, "must be unopened");
        require(ownerOf(tokenId) == address(this), "escrow not holding");
        require(msg.sender != lst.seller, "self buy");

        require(address(feeTokenB) != address(0), "B token not set");
        require(address(feeQuotePool) != address(0), "quote pool not set");

        uint256 price = secondaryBuyPrice(tokenId);

        uint256 feeU = _feeUSDTForBMode(price);
        uint256 feeB = 0;

        if (feeU > 0) {
            feeB = quoteFeeInB(feeU);
            if (maxFeeB > 0) require(feeB <= maxFeeB, "feeB too high");
        }

        _removeListedToken(tokenId);

        usdt.safeTransferFrom(msg.sender, lst.seller, price);

        if (feeB > 0) {
            feeTokenB.safeTransferFrom(msg.sender, accountA, feeB);
        }

        _safeTransfer(address(this), msg.sender, tokenId, "");

        delete listings[tokenId];

        emit Purchased(msg.sender, lst.seller, tokenId, price, true, feeU, feeB);
    }

    // ============================================================
    //                 Holding Value (for dividend)
    // ============================================================

    /// @notice 返回某地址当前“盲盒持有价值”（USDT 18位，精确）
    function holdingValueOf(address user) public view returns (uint256 value) {
        uint256 baseSum = _sumBase[user];
        if (baseSum == 0) return 0;

        uint256 brSum = _sumBR[user];
        uint256 brMinted = _sumBRMinted[user];

        uint256 t = block.timestamp;
        uint256 tbr = t * brSum;
        require(tbr >= brMinted, "BAD_SUM");
        uint256 diff = tbr - brMinted;

        uint256 inc = diff / (DECIMALS_18 * MONTH_SECONDS); // floor
        value = baseSum + inc;
    }

    function holdingAggOf(address user) external view returns (uint256 sumBase, uint256 sumBR, uint256 sumBRMinted) {
        return (_sumBase[user], _sumBR[user], _sumBRMinted[user]);
    }

    function _holdingAdd(address user, uint256 base, uint256 rate, uint256 mintedAt) internal {
        if (base == 0) return;
        _sumBase[user] += base;

        uint256 br = base * rate; // 36 decimals
        _sumBR[user] += br;
        _sumBRMinted[user] += (br * mintedAt);
    }

    function _holdingRemove(address user, uint256 base, uint256 rate, uint256 mintedAt) internal {
        if (base == 0) return;
        _sumBase[user] -= base;

        uint256 br = base * rate;
        _sumBR[user] -= br;
        _sumBRMinted[user] -= (br * mintedAt);
    }

    // ============================================================
    //              Bottom-layer hook: move economic holding on transfer
    // ============================================================

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Enumerable)
        returns (address from)
    {
        from = super._update(to, tokenId, auth);

        // burn 不支持，忽略
        if (to == address(0)) return from;

        // open 的 token 不应计入持有统计
        if (open[tokenId]) {
            economicHolder[tokenId] = address(0);
            return from;
        }

        uint256 base = boxInfo[tokenId].usdtPaid;
        uint256 rate = tokenMonthlyRateE18[tokenId];
        uint256 mAt = uint256(boxInfo[tokenId].mintedAt);

        // Mint: 0 -> 用户
        if (from == address(0)) {
            economicHolder[tokenId] = to;
            _holdingAdd(to, base, rate, mAt);
            return from;
        }

        // Escrow deposit: 用户 -> 本合约（上架），不迁移经济持有
        if (to == address(this)) {
            // economicHolder 保持为卖家（from）
            // 不做 holding 迁移
            return from;
        }

        // Transfer out of escrow: 本合约 -> 某人（下架或成交）
        if (from == address(this)) {
            Listing memory lst = listings[tokenId];
            if (lst.active) {
                // 下架：回到 seller，不迁移
                if (to == lst.seller) {
                    return from;
                }
                // 成交：从 seller 迁移到 buyer(to)
                _holdingRemove(lst.seller, base, rate, mAt);
                _holdingAdd(to, base, rate, mAt);
                economicHolder[tokenId] = to;
                return from;
            }
            // 非预期：没有 listing 的 escrow transfer，保守处理：不迁移
            return from;
        }

        // 普通转移（如果未来你放开 transferFrom，这里也能自动保持统计正确）
        _holdingRemove(from, base, rate, mAt);
        _holdingAdd(to, base, rate, mAt);
        economicHolder[tokenId] = to;

        return from;
    }

    // ============================================================
    //                  Pagination reads returning BoxInfo
    // ============================================================

    function mintedTokenIdsLength() external view returns (uint256) {
        return mintedTokenIds.length;
    }

    function openActionTokenIdsLength() external view returns (uint256) {
        return openActionTokenIds.length;
    }

    function getOwnerTokensByPage(address owner, uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory tokenIds, BoxInfo[] memory infos)
    {
        uint256 bal = balanceOf(owner);
        if (start >= bal) return (new uint256[](0), new BoxInfo[](0));

        uint256 end = start + count;
        if (end > bal) end = bal;

        uint256 n = end - start;
        tokenIds = new uint256[](n);
        infos = new BoxInfo[](n);

        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(owner, start + i);
            tokenIds[i] = tokenId;
            infos[i] = boxInfo[tokenId];
        }
    }

    function getMintedByPage(uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory tokenIds, BoxInfo[] memory infos)
    {
        uint256 len = mintedTokenIds.length;
        if (start >= len) return (new uint256[](0), new BoxInfo[](0));

        uint256 end = start + count;
        if (end > len) end = len;

        uint256 n = end - start;
        tokenIds = new uint256[](n);
        infos = new BoxInfo[](n);

        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = mintedTokenIds[start + i];
            tokenIds[i] = tokenId;
            infos[i] = boxInfo[tokenId];
        }
    }

    function getOpenedByPage(uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory tokenIds, BoxInfo[] memory infos)
    {
        uint256 len = openActionTokenIds.length;
        if (start >= len) return (new uint256[](0), new BoxInfo[](0));

        uint256 end = start + count;
        if (end > len) end = len;

        uint256 n = end - start;
        tokenIds = new uint256[](n);
        infos = new BoxInfo[](n);

        for (uint256 i = 0; i < n; i++) {
            uint256 tokenId = openActionTokenIds[start + i];
            tokenIds[i] = tokenId;
            infos[i] = boxInfo[tokenId];
        }
    }

    // ============================================================
    //                         Other views
    // ============================================================

    function openUsageNow(address user)
        external
        view
        returns (uint256 dayIndex, uint256 used, uint256 limit, uint256 remaining)
    {
        dayIndex = _dayIndex(block.timestamp);
        Usage memory u = _usage[user];

        used = (u.dayIndex == dayIndex) ? uint256(u.used) : 0;
        limit = BASE_DAILY_OPENS + extraSlots[user];
        remaining = (limit > used) ? (limit - used) : 0;
    }

    function slotStepForUser(address user) external view returns (uint256) {
        uint256 s = userSlotStepCost[user];
        return s == 0 ? globalSlotStepCost : s;
    }

    function previewSlotCost(address user, uint256 count) external view returns (uint256 cost, uint256 step) {
        require(count > 0, "count=0");
        step = userSlotStepCost[user];
        if (step == 0) step = globalSlotStepCost;

        uint256 n = extraSlots[user];
        uint256 multiplierSum = (count * n) + ((count * (count + 1)) / 2);
        cost = step * multiplierSum;
    }

    function withdrawERC20(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(to != address(0), "to=0");
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Withdrawn(token, to, amount);
    }

    // -------------------- Interface --------------------
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
