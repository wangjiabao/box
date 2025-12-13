// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PRBMathUD60x18 } from "prb-math/contracts/PRBMathUD60x18.sol";
import { PRBMathSD59x18 } from "prb-math/contracts/PRBMathSD59x18.sol";

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
    function approve(address s, uint256 v) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IMintableBurnableERC20 is IERC20 {
    function burnFrom(address from, uint256 amount) external;
}

/**
 * @title BondingCurvePrimaryMarket
 * @notice 兼容版：保留 currentPrice()，并新增 x1/x2 独立轴口径方法
 *
 * 记账与模型（新口径）：
 *   - 买沿 x1：S_buy = S(x1_new) - S(x1_old)
 *   - 卖沿 x2：S_sell = S(x2_new) - S(x2_old)
 *   - 台账净储备：R = s1 - s2  ≈  模型净储备：S(x1) - S(x2)
 *
 * 费收（AUSD 侧）：
 *   - 买：总铸造 dX，fee = floor(dX * buyRate / buyBase) 铸给 feeRecipient；用户实收 = dX - fee
 *   - 卖：用户总交割 gross，fee = floor(gross * sellRate / sellBase) 转给 feeRecipient；净烧 burn = gross - fee
 *
 * 兼容项：
 *   - currentPrice() 仍返回 priceAtSupply(internalSupply())（中间价，仅兼容用途）。 
 *
 * 曲线（最新）：
 *   - 基础关系：a * y^1.7 = x，其中 a = A / 1e18（部署时传入 A）
 *   - 价格：y(x) = (x / a)^(10/17)
 *   - 面积：S(x) = (17/27) * x^(27/17) / a^(10/17)
 */
contract BondingCurvePrimaryMarket is AccessControl, ReentrancyGuard {
    using PRBMathUD60x18 for uint256;

    // -------------------- 60.18 常量 --------------------
    uint256 private constant ONE   = 1e18;
    uint256 private constant TWO   = 2e18;
    uint256 private constant THREE = 3e18;
    uint256 private constant TWO_THIRDS_CONST = 666_666_666_666_666_667; // 2/3 (60.18)

    // 1.7 幂曲线相关常量（60.18）
    uint256 private constant TEN_OVER_SEVENTEEN          = 588_235_294_117_647_059;   // 10/17
    uint256 private constant TWENTY_SEVEN_OVER_SEVENTEEN = 1_588_235_294_117_647_059; // 27/17
    uint256 private constant SEVENTEEN_OVER_TWENTY_SEVEN = 629_629_629_629_629_630;   // 17/27

    bool public initStatus;

    // -------------------- Tokens --------------------
    IERC20 public immutable usdt;                 // 18 decimals（此处强制 18）
    IMintableBurnableERC20 public immutable ausd; // 18 decimals

    // -------------------- Curve params (60.18) --------------------
    uint256 public immutable A;          // > 0，真实 a = A / 1e18
    uint256 public immutable SQRT_A;     // 沿用旧字段（不再参与新曲线计算）
    uint256 public immutable K;          // 沿用旧字段（不再参与新曲线计算）
    uint256 public immutable C;          // 沿用旧字段（不再参与新曲线计算）
    uint256 public immutable TWO_THIRDS; // 沿用旧字段（不再参与新曲线计算）

    // 新曲线面积系数：S(x) = K_AY_1_7 * x^(27/17)
    uint256 private immutable K_AY_1_7;

    // -------------------- Fees --------------------
    uint256 public buyFeeRate  = 3;     // 默认 3/100
    uint256 public buyFeeBase  = 100;
    uint256 public sellFeeRate = 3;     // 默认 3/100
    uint256 public sellFeeBase = 100;
    address public feeRecipient;

    // -------------------- Internal ledger --------------------
    uint256 public s1; // 累计入金（USDT，面积） ~= S(x1)
    uint256 public s2; // 累计出金（USDT，面积） ~= S(x2)
    uint256 public x1; // 累计总铸造 AUSD（含买侧手续费部分）
    uint256 public x2; // 累计净销毁 AUSD（仅净烧，扣除卖侧手续费）

    // -------------------- Events --------------------
    event FeesUpdated(
        uint256 buyRate,
        uint256 buyBase,
        uint256 sellRate,
        uint256 sellBase,
        address feeRecipient
    );

    event Bought(
        address indexed buyer,
        address indexed to,
        uint256 usdtUsed,         // 入金（沿 x1 面积）
        uint256 ausdGrossOut,     // 总铸造
        uint256 ausdFee,          // 手续费（铸给 feeRecipient）
        uint256 ausdNetOut,       // 用户实收
        uint256 priceBefore,      // priceAtSupply(x1_old)
        uint256 priceAfter        // priceAtSupply(x1_new)
    );

    event Sold(
        address indexed seller,
        address indexed to,
        uint256 ausdGrossIn,      // 用户交割总量
        uint256 ausdFee,          // 手续费（转给 feeRecipient）
        uint256 ausdBurn,         // 实际净烧（x2 增量）
        uint256 usdtOut,          // 出金（沿 x2 面积）
        uint256 priceBefore,      // priceAtSupply(x2_old)
        uint256 priceAfter        // priceAtSupply(x2_new)
    );

    event Skimmed(address indexed to, uint256 amount);

    // -------------------- Constructor --------------------
    constructor(
        address usdt_,
        address ausd_,
        uint256 a,               // 60.18，真实 a = a / 1e18，例如 1e27 => a = 1e9
        address admin,
        address feeRecipient_
    ) {
        require(usdt_ != address(0) && ausd_ != address(0), "ZERO_ADDR");
        require(a > 0, "A_ZERO");
        require(admin != address(0), "ADMIN_ZERO");
        require(feeRecipient_ != address(0), "FEE_ZERO");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        usdt = IERC20(usdt_);
        ausd = IMintableBurnableERC20(ausd_);
        A = a;

        // 均强制 18 位
        try usdt.decimals() returns (uint8 d0) { require(d0 == 18, "USDT_DEC"); } catch {}
        try ausd.decimals() returns (uint8 d1) { require(d1 == 18, "AUSD_DEC"); } catch {}

        // 旧曲线中用到的参数，保留赋值以兼容外部读取，但不再参与新曲线计算
        SQRT_A     = A.sqrt();
        K          = TWO.div(THREE.mul(SQRT_A));
        C          = THREE.mul(SQRT_A).div(TWO);
        TWO_THIRDS = TWO_THIRDS_CONST;

        // 新曲线面积系数：K_AY_1_7 = (17/27) / a^(10/17)
        // 其中 a = A / 1e18（真实值），这里直接用 UD60x18 运算
        uint256 aPow10Over17 = A.pow(TEN_OVER_SEVENTEEN);     // a^(10/17)
        K_AY_1_7 = SEVENTEEN_OVER_TWENTY_SEVEN.div(aPow10Over17);

        feeRecipient = feeRecipient_;
    }

    // -------------------- Admin ops --------------------
    function setFees(
        uint256 _buyRate,
        uint256 _buyBase,
        uint256 _sellRate,
        uint256 _sellBase,
        address _feeRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_buyBase > 0 && _sellBase > 0, "BASE_ZERO");
        require(_buyRate < _buyBase, "BUY_FEE_CFG");
        require(_sellRate < _sellBase, "SELL_FEE_CFG");
        require(_feeRecipient != address(0), "FEE_ZERO");

        buyFeeRate  = _buyRate;
        buyFeeBase  = _buyBase;
        sellFeeRate = _sellRate;
        sellFeeBase = _sellBase;
        feeRecipient = _feeRecipient;

        emit FeesUpdated(_buyRate, _buyBase, _sellRate, _sellBase, _feeRecipient);
    }

    function setBuyFees(uint256 _buyRate, uint256 _buyBase) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_buyBase > 0, "BASE_ZERO");
        require(_buyRate < _buyBase, "BUY_FEE_CFG");
        buyFeeRate = _buyRate;
        buyFeeBase = _buyBase;
        emit FeesUpdated(buyFeeRate, buyFeeBase, sellFeeRate, sellFeeBase, feeRecipient);
    }

    function setSellFees(uint256 _sellRate, uint256 _sellBase) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_sellBase > 0, "BASE_ZERO");
        require(_sellRate < _sellBase, "SELL_FEE_CFG");
        sellFeeRate = _sellRate;
        sellFeeBase = _sellBase;
        emit FeesUpdated(buyFeeRate, buyFeeBase, sellFeeRate, sellFeeBase, feeRecipient);
    }

    // -------------------- Views --------------------
    /// 当前净可流通供给（用于约束 x2 的上界）
    function internalSupply() public view returns (uint256) {
        return x1 >= x2 ? x1 - x2 : 0;
    }

    /// 台账净储备（USDT）
    function internalReserve() public view returns (uint256) {
        return s1 >= s2 ? s1 - s2 : 0;
    }

    /// 模型净储备（USDT）：S(x1) - S(x2)
    function modeledReserve() public view returns (uint256) {
        uint256 a1 = areaOf(x1);
        uint256 a2 = areaOf(x2);
        return a1 >= a2 ? a1 - a2 : 0;
    }

    /// 真实余额（USDT）
    function realReserve() public view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    /// 兼容旧 ABI：中间价（沿 X = x1-x2），仅用于兼容读取；推荐改用 buy/sell 各自价格
    function currentPrice() public view returns (uint256) {
        return priceAtSupply(internalSupply());
    }

    /// 买侧价格：使用 x1（买盘轴）
    function currentBuyPrice() public view returns (uint256) {
        return priceAtSupply(x1);
    }

    /// 卖侧价格：使用 x2（卖盘轴）
    function currentSellPrice() public view returns (uint256) {
        return priceAtSupply(x2);
    }

    // y(x) = (x / a)^(10/17)，其中 a = A / 1e18
    // y(x) = (x / a)^(10/17)，其中 a = A / 1e18
    function priceAtSupply(uint256 x) public view returns (uint256) {
        if (x == 0) return 0;

        // 如果 x >= a：直接算 (x/a)^(10/17)，此时 (x/a) >= 1，不会触发 LogInputTooSmall
        if (x >= A) {
            uint256 ratio = x.div(A); // x / a
            return ratio.pow(TEN_OVER_SEVENTEEN);
        } else {
            // 如果 x < a：y = (x/a)^(10/17) = 1 / ( (a/x)^(10/17) )
            uint256 invRatio = A.div(x);             // a / x > 1
            uint256 t        = invRatio.pow(TEN_OVER_SEVENTEEN); // (a/x)^(10/17) >= 1
            return ONE.div(t);                       // 1 / t
        }
    }

    // S(x) = K_AY_1_7 * x^(27/17)
    function areaOf(uint256 x) public view returns (uint256) {
        if (x == 0) return 0;
        uint256 xPow = x.pow(TWENTY_SEVEN_OVER_SEVENTEEN);
        return K_AY_1_7.mul(xPow);
    }

    // S^{-1}(s)：s = K_AY_1_7 * x^(27/17) => x = (s / K_AY_1_7)^(17/27)
    function supplyFromArea(uint256 s) public view returns (uint256) {
        if (s == 0) return 0;
        uint256 ratio = s.div(K_AY_1_7);
        return ratio.pow(SEVENTEEN_OVER_TWENTY_SEVEN);
    }

    // -------------------- Helpers --------------------
    function _mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a == 0 || b == 0) ? 0 : (a * b + d - 1) / d;
    }

    // -------------------- Quotes（沿各自轴的理论报价） --------------------

    /// 买：给定 usdtIn，求净出、费与总铸造（沿 x1 轴）
    function quoteBuyGivenUsdt(uint256 usdtIn)
        external view
        returns (uint256 ausdNetOut, uint256 ausdFee, uint256 ausdGrossOut)
    {
        uint256 X1  = x1;
        uint256 X1n = supplyFromArea(areaOf(X1) + usdtIn);
        ausdGrossOut = X1n - X1;
        ausdFee      = (ausdGrossOut * buyFeeRate) / buyFeeBase; // floor
        ausdNetOut   = ausdGrossOut - ausdFee;
    }

    /// 买：给定期望净拿 AUSD，求所需 USDT、费与总铸造（沿 x1 轴）
    function quoteBuyForExactAusdt(uint256 ausdNetWant)
        external view
        returns (uint256 usdtIn, uint256 ausdFee, uint256 ausdGross)
    {
        uint256 X1    = x1;
        uint256 denom = buyFeeBase - buyFeeRate;
        ausdGross = _mulDivUp(ausdNetWant, buyFeeBase, denom);
        usdtIn    = areaOf(X1 + ausdGross) - areaOf(X1);
        ausdFee   = ausdGross - ausdNetWant;
    }

    /// 买：给定总铸造量（精确让 x1 增加指定值），返回所需 USDT 与净出
    function quoteBuyGivenGross(uint256 ausdGross)
        external view
        returns (uint256 usdtIn, uint256 ausdFee, uint256 ausdNetOut)
    {
        uint256 X1   = x1;
        usdtIn       = areaOf(X1 + ausdGross) - areaOf(X1);
        ausdFee      = (ausdGross * buyFeeRate) / buyFeeBase;
        ausdNetOut   = ausdGross - ausdFee;
    }

    /// 卖：给定总交割，返回出金、费与净烧（沿 x2 轴）
    function quoteSellGivenAusdt(uint256 ausdGrossIn)
        external view
        returns (uint256 usdtOut, uint256 ausdFee, uint256 ausdBurn)
    {
        uint256 X2  = x2;
        ausdFee     = (ausdGrossIn * sellFeeRate) / sellFeeBase; // floor
        ausdBurn    = ausdGrossIn - ausdFee;
        require(ausdBurn <= internalSupply(), "SELL_EXCEEDS_INTERNAL_SUPPLY");
        usdtOut     = areaOf(X2 + ausdBurn) - areaOf(X2);
    }

    /// 卖：给定希望拿到的 USDT 出金，返回总交割、费与净烧（沿 x2 轴）
    function quoteSellForExactUsdt(uint256 usdtOut)
        external view
        returns (uint256 ausdGrossIn, uint256 ausdFee, uint256 ausdBurn)
    {
        require(usdtOut <= modeledReserve(), "EXCEEDS_MODELED_RESERVE");
        uint256 X2    = x2;
        uint256 X2n   = supplyFromArea(areaOf(X2) + usdtOut);
        ausdBurn      = X2n - X2;
        require(ausdBurn <= internalSupply(), "SELL_EXCEEDS_INTERNAL_SUPPLY");
        uint256 denom = sellFeeBase - sellFeeRate;
        ausdGrossIn   = _mulDivUp(ausdBurn, sellFeeBase, denom);
        ausdFee       = ausdGrossIn - ausdBurn;
    }

    /// 卖：给定净烧（精确让 x2 增加指定值），返回出金、费与总交割（沿 x2 轴）
    function quoteSellForBurn(uint256 ausdBurn)
        external view
        returns (uint256 usdtOut, uint256 ausdFee, uint256 ausdGrossIn)
    {
        require(ausdBurn <= internalSupply(), "SELL_EXCEEDS_INTERNAL_SUPPLY");
        uint256 X2    = x2;
        usdtOut       = areaOf(X2 + ausdBurn) - areaOf(X2);
        uint256 denom = sellFeeBase - sellFeeRate;
        ausdGrossIn   = _mulDivUp(ausdBurn, sellFeeBase, denom);
        ausdFee       = ausdGrossIn - ausdBurn;
    }

    // -------------------- Trades --------------------
    /// 买（按 USDT 入金）：沿 x1 轴推进，初始化专用，无手续费
    function buyWithUsdtInit(uint256 usdtIn, address to)
        external nonReentrant returns (uint256 dX)
    {
        require(!initStatus, "ALREADY_INIT");
        initStatus = true;

        require(usdtIn > 0, "ZERO_IN");
        address _to = to == address(0) ? msg.sender : to;

        uint256 X1      = x1;
        uint256 price0  = priceAtSupply(X1);
        uint256 X1n     = supplyFromArea(areaOf(X1) + usdtIn);
        dX              = X1n - X1;

        s1 += usdtIn;
        x1 += dX;

        ausd.transfer(_to, dX);

        emit Bought(msg.sender, _to, usdtIn, dX, 0, dX, price0, priceAtSupply(X1n));
    }

    /// 买（按 USDT 入金）：沿 x1 轴推进
    function buyWithUsdt(uint256 usdtIn, uint256 minAusdNetOut, address to)
        external nonReentrant returns (uint256 ausdNetOut)
    {
        require(usdtIn > 0, "ZERO_IN");
        require(feeRecipient != address(0), "FEE_ZERO");
        address _to = to == address(0) ? msg.sender : to;

        require(usdt.transferFrom(msg.sender, address(this), usdtIn), "TF_FROM");

        uint256 X1      = x1;
        uint256 price0  = priceAtSupply(X1);
        uint256 X1n     = supplyFromArea(areaOf(X1) + usdtIn);
        uint256 dX      = X1n - X1;

        uint256 feeA    = (dX * buyFeeRate) / buyFeeBase;
        ausdNetOut      = dX - feeA;
        require(ausdNetOut >= minAusdNetOut, "SLIPPAGE");

        s1 += usdtIn;
        x1 += dX;

        if (feeA > 0) ausd.transfer(feeRecipient, feeA);
        ausd.transfer(_to, ausdNetOut);

        emit Bought(msg.sender, _to, usdtIn, dX, feeA, ausdNetOut, price0, priceAtSupply(X1n));
    }

    /// 买（精确净拿 AUSD）：沿 x1 轴推进
    function buyExactAusdt(uint256 ausdNetOut, uint256 maxUsdtIn, address to)
        external nonReentrant returns (uint256 usdtUsed)
    {
        require(ausdNetOut > 0, "ZERO_OUT");
        require(feeRecipient != address(0), "FEE_ZERO");
        address _to = to == address(0) ? msg.sender : to;

        uint256 X1      = x1;
        uint256 price0  = priceAtSupply(X1);
        uint256 denom   = buyFeeBase - buyFeeRate;
        uint256 dX      = _mulDivUp(ausdNetOut, buyFeeBase, denom);
        usdtUsed        = areaOf(X1 + dX) - areaOf(X1);
        require(usdtUsed <= maxUsdtIn, "SLIPPAGE");

        require(usdt.transferFrom(msg.sender, address(this), usdtUsed), "TF_FROM");

        s1 += usdtUsed;
        x1 += dX;

        uint256 feeA = dX - ausdNetOut;
        if (feeA > 0) ausd.transfer(feeRecipient, feeA);
        ausd.transfer(_to, ausdNetOut);

        emit Bought(msg.sender, _to, usdtUsed, dX, feeA, ausdNetOut, price0, priceAtSupply(X1 + dX));
    }

    /// 买（精确总铸造）：让 x1 精确增加 ausdGross
    function buyExactGross(uint256 ausdGross, uint256 maxUsdtIn, address to)
        external nonReentrant returns (uint256 usdtUsed, uint256 ausdNetOut)
    {
        require(ausdGross > 0, "ZERO_GROSS");
        require(feeRecipient != address(0), "FEE_ZERO");
        address _to = to == address(0) ? msg.sender : to;

        uint256 X1      = x1;
        uint256 price0  = priceAtSupply(X1);
        usdtUsed        = areaOf(X1 + ausdGross) - areaOf(X1);
        require(usdtUsed <= maxUsdtIn, "SLIPPAGE");

        require(usdt.transferFrom(msg.sender, address(this), usdtUsed), "TF_FROM");

        s1 += usdtUsed;
        x1 += ausdGross;

        uint256 feeA = (ausdGross * buyFeeRate) / buyFeeBase;
        ausdNetOut   = ausdGross - feeA;

        if (feeA > 0) ausd.transfer(feeRecipient, feeA);
        ausd.transfer(_to, ausdNetOut);

        emit Bought(msg.sender, _to, usdtUsed, ausdGross, feeA, ausdNetOut, price0, priceAtSupply(X1 + ausdGross));
    }

    /// 卖（按总交割）：沿 x2 轴推进
    function sellForUsdt(uint256 ausdGrossIn, uint256 minUsdtOut, address to)
        external nonReentrant returns (uint256 usdtOut)
    {
        require(ausdGrossIn > 0, "ZERO_IN");
        require(feeRecipient != address(0), "FEE_ZERO");
        address _to = to == address(0) ? msg.sender : to;

        uint256 feeA  = (ausdGrossIn * sellFeeRate) / sellFeeBase;
        uint256 burnX = ausdGrossIn - feeA;
        require(burnX <= internalSupply(), "SELL_EXCEEDS_INTERNAL_SUPPLY");

        uint256 X2     = x2;
        uint256 price0 = priceAtSupply(X2);

        if (feeA > 0) {
            require(ausd.transferFrom(msg.sender, feeRecipient, feeA), "TF_FEE");
        }
        ausd.burnFrom(msg.sender, burnX);

        usdtOut = areaOf(X2 + burnX) - areaOf(X2);
        require(usdtOut >= minUsdtOut, "SLIPPAGE");

        s2 += usdtOut;
        x2 += burnX;

        require(usdt.transfer(_to, usdtOut), "TF_OUT");

        emit Sold(msg.sender, _to, ausdGrossIn, feeA, burnX, usdtOut, price0, priceAtSupply(X2 + burnX));
    }

    /// 卖（精确 USDT 出金）：沿 x2 轴推进
    function sellExactUsdt(uint256 usdtOut, uint256 maxAusdGrossIn, address to)
        external nonReentrant returns (uint256 ausdGrossIn)
    {
        require(usdtOut > 0, "ZERO_OUT");
        require(feeRecipient != address(0), "FEE_ZERO");
        require(usdtOut <= modeledReserve(), "EXCEEDS_MODELED_RESERVE");
        address _to = to == address(0) ? msg.sender : to;

        uint256 X2     = x2;
        uint256 price0 = priceAtSupply(X2);

        uint256 X2n    = supplyFromArea(areaOf(X2) + usdtOut);
        uint256 burnX  = X2n - X2;
        require(burnX <= internalSupply(), "SELL_EXCEEDS_INTERNAL_SUPPLY");

        uint256 denom  = sellFeeBase - sellFeeRate;
        ausdGrossIn    = _mulDivUp(burnX, sellFeeBase, denom);
        require(ausdGrossIn <= maxAusdGrossIn, "SLIPPAGE");
        uint256 feeA   = ausdGrossIn - burnX;

        if (feeA > 0) {
            require(ausd.transferFrom(msg.sender, feeRecipient, feeA), "TF_FEE");
        }
        ausd.burnFrom(msg.sender, burnX);

        s2 += usdtOut;
        x2 += burnX;

        require(usdt.transfer(_to, usdtOut), "TF_OUT");

        emit Sold(msg.sender, _to, ausdGrossIn, feeA, burnX, usdtOut, price0, priceAtSupply(X2n));
    }

    /// 卖（精确净烧）：让 x2 精确增加 burnX（沿 x2 轴）
    function sellExactBurn(uint256 burnX, uint256 minUsdtOut, address to)
        external nonReentrant returns (uint256 usdtOut, uint256 ausdGrossIn)
    {
        require(burnX > 0, "ZERO_BURN");
        require(feeRecipient != address(0), "FEE_ZERO");
        require(burnX <= internalSupply(), "SELL_EXCEEDS_INTERNAL_SUPPLY");
        address _to = to == address(0) ? msg.sender : to;

        uint256 X2     = x2;
        uint256 price0 = priceAtSupply(X2);

        uint256 denom  = sellFeeBase - sellFeeRate;
        ausdGrossIn    = _mulDivUp(burnX, sellFeeBase, denom);
        uint256 feeA   = ausdGrossIn - burnX;

        if (feeA > 0) {
            require(ausd.transferFrom(msg.sender, feeRecipient, feeA), "TF_FEE");
        }
        ausd.burnFrom(msg.sender, burnX);

        usdtOut = areaOf(X2 + burnX) - areaOf(X2);
        require(usdtOut >= minUsdtOut, "SLIPPAGE");

        s2 += usdtOut;
        x2 += burnX;

        require(usdt.transfer(_to, usdtOut), "TF_OUT");

        emit Sold(msg.sender, _to, ausdGrossIn, feeA, burnX, usdtOut, price0, priceAtSupply(X2 + burnX));
    }

    // -------------------- Dust handling (public skim) --------------------

    /// 把“真实余额 - 台账余额”的正差额提走，使 realReserve 回到 s1 - s2（不改台账）
    function skimExcess() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (uint256 amount) {
        uint256 realR  = realReserve();
        uint256 bookR  = internalReserve(); // s1 - s2
        require(realR > bookR, "NO_EXCESS");
        amount = realR - bookR;

        // 如希望把 skim 记账，可改为：s2 += amount;（会改变 s1-s2，不建议）
        require(usdt.transfer(msg.sender, amount), "TF_SKIM");
        emit Skimmed(msg.sender, amount);
    }

    function withdrawToken(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(to != address(0), "to=0");
        IERC20(token).transfer(to, amount);
    }
}
