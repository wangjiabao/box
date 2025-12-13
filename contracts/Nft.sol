// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
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

/// @title BlindBox NFT + Escrow Marketplace (BSC 18 decimals)
/// @notice
/// - 铸造：固定原价 20/50/100（18位），收USDT：98%到AccountA，2%留合约
/// - open：不可逆；每天默认1次（12:00~次日12:00为一天），可用A买槽位扩展次数；用户首次买槽位锁定自己的步长a
/// - reward：ADMIN_ROLE 只能对 open=true 的NFT设置一次 int256 reward
/// - 二级市场：托管式（上架把NFT转入本合约，不定价）；买价按“铸造原价”为基数实时线性每月+4%（不复利、实时增长）
/// - 二级市场手续费：买家额外支付，可选用USDT或代币B；B数量用你给的SwapHrxUsdt报价公式换算（token1=USDT, token0=B）
/// - 增加：维护“正在上架 tokenId 动态数组”，便于前端获取正在上架的盲盒
/// - 增加：分页枚举 owner NFTs；分页读取 minted/openAction 并返回 BoxInfo
contract BlindBoxNFT is ERC721Enumerable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------- Roles --------------------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // -------------------- Constants --------------------
    uint256 public constant DECIMALS_18 = 1e18;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    // mint分账：98%给AccountA
    uint256 public constant ACCOUNT_A_FEE_BPS = 9_800;

    // 二级市场线性涨价：每月 +4%（0.04 * 1e18）
    // 实时增长：price = base + base * 0.04 * elapsed / 30days
    uint256 public constant MONTHLY_RATE_E18 = 4e16; // 0.04e18
    uint256 public constant MONTH_SECONDS = 30 days;

    // open窗口：12:00~次日12:00（通过 +12h shift 分桶）
    uint256 public constant DAY_SHIFT_SECONDS = 12 hours;
    uint256 public constant BASE_DAILY_OPENS = 1;

    // -------------------- Tokens --------------------
    IERC20 public immutable usdt;     // BSC USDT(18)
    IERC20 public aToken;             // A(18) - 买槽位
    address public accountA;          // 收费地址（mint 98% + 交易手续费收款）

    // B手续费计价：用你给的 SwapHrxUsdt 报价（token1=USDT, token0=B）
    IToken0Token1AmmQuote public feeQuotePool;
    IERC20 public feeTokenB; // = feeQuotePool.token0()

    // -------------------- Mint tier prices (fixed original mint price) --------------------
    // tier: 1=>20u, 2=>50u, 3=>100u (all 18 decimals)
    mapping(uint8 => uint256) public tierPrice;

    // -------------------- NFT Data --------------------
    struct BoxInfo {
        uint8 tier;

        // 记录“铸造原价”（=当时铸造支付的固定价），也是二级市场涨价的基数
        uint256 usdtPaid;

        uint64 mintedAt;

        uint64 openedAt;      // open时间（不可逆，只有一次）
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

    /// @dev tokenId => index+1 in listedTokenIds（0表示不在上架数组中）
    mapping(uint256 => uint256) private _listedPosPlusOne;

    // 二级市场交易手续费（买家额外付）
    // 1) 用USDT：feeU = price * feeRate / feeBase
    uint256 public feeRate;
    uint256 public feeBase;

    // 2) 用B：先算等值 feeU = price * feeRateTwo / feeBaseTwo
    //    再用 quoteFeeInB(feeU) 换算 feeB（token0）
    uint256 public feeRateTwo;
    uint256 public feeBaseTwo;

    // -------------------- Events --------------------
    event AccountAChanged(address indexed oldAccountA, address indexed newAccountA);

    event ATokenChanged(address indexed oldToken, address indexed newToken);
    event GlobalSlotStepCostChanged(uint256 oldCost, uint256 newCost);

    event FeeQuotePoolChanged(address indexed pool, address indexed token0B);

    event TierPriceChanged(uint8 indexed tier, uint256 oldPrice, uint256 newPrice);

    event Minted(address indexed minter, uint256 indexed tokenId, uint8 indexed tier, uint256 usdtPaid);

    event Opened(address indexed owner, uint256 indexed tokenId, uint256 timestamp);

    event RewardSetOnce(address indexed admin, uint256 indexed tokenId, int256 reward, uint256 timestamp);

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

    // -------------------- Constructor --------------------
    constructor(
        string memory name_,
        string memory symbol_,
        address usdt_,
        address aToken_,
        address accountA_,
        uint256 globalSlotStepCost_
    ) ERC721(name_, symbol_) {
        require(usdt_ != address(0), "USDT=0");
        require(accountA_ != address(0), "AccountA=0");

        usdt = IERC20(usdt_);
        aToken = IERC20(aToken_);
        accountA = accountA_;

        globalSlotStepCost = globalSlotStepCost_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        // 固定原价（18位）
        tierPrice[1] = 20 * DECIMALS_18;
        tierPrice[2] = 50 * DECIMALS_18;
        tierPrice[3] = 100 * DECIMALS_18;

        // 默认手续费（你代码里写了非0）
        feeRate = 100;
        feeBase = BPS_DENOMINATOR;

        feeRateTwo = 50;
        feeBaseTwo = BPS_DENOMINATOR;
    }

    // ============================================================
    //                 Active listed array helpers (O(1))
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

    // ============================================================
    //                       Admin setters
    // ============================================================

    function setAccountA(address newAccountA) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAccountA != address(0), "AccountA=0");
        address old = accountA;
        accountA = newAccountA;
        emit AccountAChanged(old, newAccountA);
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

    /// @notice 可选：调整“铸造原价”，仅影响未来新铸造；已铸造NFT不受影响（boxInfo.usdtPaid已写死）
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

    /// @notice 设置手续费B模式的报价池（你给的 SwapHrxUsdt）
    /// @dev 要求：pool.token1 == USDT；pool.liquidityInited == true
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
    //                           Minting (fixed original price)
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
        _safeMint(to, tokenId);

        BoxInfo storage b = boxInfo[tokenId];
        b.tier = tier;
        b.usdtPaid = paid; // 固定原价（也是二级市场涨价基数）
        b.mintedAt = uint64(block.timestamp);

        mintedTokenIds.push(tokenId);

        emit Minted(to, tokenId, tier, paid);
    }

    /// @dev mint收款：98%到AccountA，2%留合约
    function _collectUsdtMint(address payer, uint256 total) internal {
        require(accountA != address(0), "AccountA not set");

        uint256 toA = Math.mulDiv(total, ACCOUNT_A_FEE_BPS, BPS_DENOMINATOR);
        uint256 toContract = total - toA;

        if (toA > 0) usdt.safeTransferFrom(payer, accountA, toA);
        if (toContract > 0) usdt.safeTransferFrom(payer, address(this), toContract);
    }

    // ============================================================
    //                              Open (irreversible)
    // ============================================================

    function openBox(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "only owner");
        require(open[tokenId] == false, "already opened");

        _consumeOpenAllowance(msg.sender);

        open[tokenId] = true;
        boxInfo[tokenId].openedAt = uint64(block.timestamp);

        openActionTokenIds.push(tokenId);

        emit Opened(msg.sender, tokenId, block.timestamp);
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
        // 12:00~次日12:00
        return (ts + DAY_SHIFT_SECONDS) / 1 days;
    }

    // ============================================================
    //                        Reward (set once)
    // ============================================================

    function setRewardOnce(uint256 tokenId, int256 reward_) external onlyRole(ADMIN_ROLE) {
        require(_ownerOf(tokenId) != address(0), "nonexistent token");
        require(open[tokenId] == true, "must be opened");
        require(boxInfo[tokenId].rewardSetAt == 0, "reward already set");

        boxInfo[tokenId].reward = reward_;
        boxInfo[tokenId].rewardSetAt = uint64(block.timestamp);

        emit RewardSetOnce(msg.sender, tokenId, reward_, block.timestamp);
    }

    // ============================================================
    //                    Buy open slots with A (user locks step)
    // ============================================================

    function buyOpenSlots(uint256 count) external nonReentrant {
        require(count > 0, "count=0");
        require(address(aToken) != address(0), "A token not set");
        require(accountA != address(0), "AccountA not set");

        // 用户首次购买时锁定自己的步长a
        uint256 step = userSlotStepCost[msg.sender];
        if (step == 0) {
            require(globalSlotStepCost > 0, "global step=0");
            step = globalSlotStepCost;
            userSlotStepCost[msg.sender] = step;
        }

        uint256 n = extraSlots[msg.sender]; // 已有额外槽位
        // (n+1)+(n+2)+...+(n+count) = count*n + count*(count+1)/2
        uint256 multiplierSum = (count * n) + ((count * (count + 1)) / 2);
        uint256 cost = step * multiplierSum;

        aToken.safeTransferFrom(msg.sender, accountA, cost);

        extraSlots[msg.sender] = n + count;

        emit SlotsPurchased(msg.sender, count, step, cost, n + count);
    }

    // ============================================================
    //                 Secondary Market Dynamic Price (linear, realtime)
    // ============================================================

    /// @notice 二级市场买价（实时线性上涨，不复利）
    /// price = base + base * 0.04 * elapsed / 30days
    /// base = boxInfo.usdtPaid（铸造原价）
    /// elapsed = now - mintedAt
    function secondaryBuyPrice(uint256 tokenId) public view returns (uint256 price) {
        require(_ownerOf(tokenId) != address(0), "nonexistent token");

        BoxInfo memory b = boxInfo[tokenId];
        require(b.mintedAt != 0, "not minted");
        uint256 base = b.usdtPaid;

        uint256 elapsed = 0;
        if (block.timestamp > uint256(b.mintedAt)) {
            elapsed = block.timestamp - uint256(b.mintedAt);
        }

        // increment = base * (0.04e18 * elapsed) / (1e18 * 30days)
        uint256 numerator = MONTHLY_RATE_E18 * elapsed;
        uint256 denom = DECIMALS_18 * MONTH_SECONDS;

        uint256 inc = Math.mulDiv(base, numerator, denom);
        price = base + inc;
    }

    // ============================================================
    //                      Escrow Marketplace (no manual pricing)
    // ============================================================

    /// @notice 上架：直接把NFT转入本合约托管；不定价；必须 open=false
    function list(uint256 tokenId) external nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "only owner");
        require(open[tokenId] == false, "must be unopened");
        require(!listings[tokenId].active, "already listed");

        // 托管转入合约（内部transfer，不需要事先approve）
        _transfer(msg.sender, address(this), tokenId);

        listings[tokenId] = Listing({
            seller: msg.sender,
            listedAt: uint64(block.timestamp),
            active: true
        });

        // 维护上架动态数组
        _addListedToken(tokenId);

        emit Listed(msg.sender, tokenId, block.timestamp);
    }

    /// @notice 下架：返还NFT给卖家（卖家或管理员可下架）
    function unlist(uint256 tokenId) external nonReentrant {
        Listing memory lst = listings[tokenId];
        require(lst.active, "not listed");
        require(lst.seller == msg.sender || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "not seller/admin");

        // 先维护数组/状态，防重入
        _removeListedToken(tokenId);
        delete listings[tokenId];

        // 返还给卖家
        _safeTransfer(address(this), lst.seller, tokenId, "");

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

    /// @notice 用你给的 SwapHrxUsdt 报价方法：
    /// 给定 amount1In(USDT)，计算 out0Net(B)：
    /// grossMax = floor(r0 * in1 / (r1 + in1))
    /// feeOut   = floor(grossMax * feeNum / feeDen)
    /// out0Net  = grossMax - feeOut
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

    /// @notice 购买：手续费用USDT支付（额外从买家收）
    function buyPayFeeInUSDT(uint256 tokenId) external nonReentrant {
        Listing memory lst = listings[tokenId];
        require(lst.active, "not listed");

        require(open[tokenId] == false, "must be unopened");
        require(ownerOf(tokenId) == address(this), "escrow not holding");
        require(msg.sender != lst.seller, "self buy");

        uint256 price = secondaryBuyPrice(tokenId);
        uint256 feeU = _feeUSDT(price);

        // 先清状态/数组，防重入
        _removeListedToken(tokenId);
        delete listings[tokenId];

        // price -> seller
        usdt.safeTransferFrom(msg.sender, lst.seller, price);

        // feeU -> AccountA
        if (feeU > 0) {
            usdt.safeTransferFrom(msg.sender, accountA, feeU);
        }

        // NFT -> buyer
        _safeTransfer(address(this), msg.sender, tokenId, "");

        emit Purchased(msg.sender, lst.seller, tokenId, price, false, feeU, 0);
    }

    /// @notice 购买：手续费用B支付（额外从买家收）
    /// @param maxFeeB 保护参数：如果报价算出来的feeB > maxFeeB，则回滚
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

        // 先清状态/数组，防重入
        _removeListedToken(tokenId);
        delete listings[tokenId];

        // price 用USDT给卖家
        usdt.safeTransferFrom(msg.sender, lst.seller, price);

        // fee 用B给AccountA
        if (feeB > 0) {
            feeTokenB.safeTransferFrom(msg.sender, accountA, feeB);
        }

        _safeTransfer(address(this), msg.sender, tokenId, "");

        emit Purchased(msg.sender, lst.seller, tokenId, price, true, feeU, feeB);
    }

    // ============================================================
    //                         Views / Helpers
    // ============================================================

    /// @notice （保留）一次性枚举 owner 持有的 tokenId（不分页，适合小数量）
    function tokensOfOwner(address owner) external view returns (uint256[] memory ids) {
        uint256 bal = balanceOf(owner);
        ids = new uint256[](bal);
        for (uint256 i = 0; i < bal; i++) {
            ids[i] = tokenOfOwnerByIndex(owner, i);
        }
    }

    /// @notice ✅新增：分页枚举 owner 持有的 tokenId，并返回对应 BoxInfo
    /// @param owner 查询地址
    /// @param start 从 owner 的 index=start 开始（0-based）
    /// @param count 最多返回多少条
    /// @return tokenIds tokenId数组
    /// @return infos   与 tokenIds 一一对应的 BoxInfo 数组
    function getOwnerTokensByPage(address owner, uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory tokenIds, BoxInfo[] memory infos)
    {
        uint256 bal = balanceOf(owner);
        if (start >= bal) {
            return (new uint256[](0), new BoxInfo[](0));
        }

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

    function mintedTokenIdsLength() external view returns (uint256) {
        return mintedTokenIds.length;
    }

    function openActionTokenIdsLength() external view returns (uint256) {
        return openActionTokenIds.length;
    }

    /// @notice ✅新增：分页读取 mintedTokenIds，并返回每个NFT的 BoxInfo
    function getMintedByPage(uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory tokenIds, BoxInfo[] memory infos)
    {
        uint256 len = mintedTokenIds.length;
        if (start >= len) {
            return (new uint256[](0), new BoxInfo[](0));
        }

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

    /// @notice ✅新增：分页读取 openActionTokenIds，并返回每个NFT的 BoxInfo
    function getOpenedByPage(uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory tokenIds, BoxInfo[] memory infos)
    {
        uint256 len = openActionTokenIds.length;
        if (start >= len) {
            return (new uint256[](0), new BoxInfo[](0));
        }

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

    /// @notice 当前窗口open额度（12:00~次日12:00）
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

    /// @notice 用户当前槽位步长a（没买过则显示全局）
    function slotStepForUser(address user) external view returns (uint256) {
        uint256 s = userSlotStepCost[user];
        return s == 0 ? globalSlotStepCost : s;
    }

    /// @notice 预估购买count个槽位需要多少A（按用户锁定步长或全局步长）
    function previewSlotCost(address user, uint256 count) external view returns (uint256 cost, uint256 step) {
        require(count > 0, "count=0");
        step = userSlotStepCost[user];
        if (step == 0) step = globalSlotStepCost;

        uint256 n = extraSlots[user];
        uint256 multiplierSum = (count * n) + ((count * (count + 1)) / 2);
        cost = step * multiplierSum;
    }

    /// @notice 提走合约里累积的USDT(2%)或其他ERC20
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
