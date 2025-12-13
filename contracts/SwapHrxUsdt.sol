// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IERC20.sol";
import "./utils/SafeTransfer.sol";
import "./utils/ReentrancyGuard.sol";

interface IDLBurnable is IERC20 { function burn(uint256 value) external; }

interface IBondingCurvePrimaryMarket {
    function sellForUsdt(uint256 ausdAmount, uint256 minUsdtOut, address to) external returns (uint256 usdtOut);
}

contract SwapHrxUsdt is ReentrancyGuard {
    using SafeTransfer for IERC20;

    /* ---------------- Storage (initialize 设置) ---------------- */
    address public owner; // 仅此地址可做初始化、调费率等治理操作
    address public feeOwner;
    address public token0;  // DL
    address public token1;  // OTHER

    uint256 public token1BalanceInit; // 系统初始化默认token1的余额

    /* ---------------- Reserves / TWAP ---------------- */
    uint112 private reserve0; // DL
    uint112 private reserve1; // OTHER
    uint32  private blockTimestampLast;

    // TWAP cumulatives (UQ112x112)
    uint256 public price0CumulativeLast; // token1/token0
    uint256 public price1CumulativeLast; // token0/token1

    /* ---------------- Params ---------------- */
    // fee (DL-side, as num/den) —— 由 owner 管理
    uint32  public feeNum = 3;
    uint32  public feeDen = 100;
    bool    public liquidityInited;
    
    IBondingCurvePrimaryMarket public primaryMarket;

    /* ---------------- Events ---------------- */
    event FeeChanged(uint32 oldNum, uint32 oldDen, uint32 newNum, uint32 newDen);
    event Sync(uint112 reserve0, uint112 reserve1);
    event MintInitial(uint256 amountDL, uint256 amountOther);
    event MintOtherOnly(uint256 amountOther);
    event DustPurged(uint256 dlAmount, uint256 usdt);
    event FeeExchanged(uint256 dlAmount, uint256 usdt);

    // amount0In/Out 表示 DL，amount1In/Out 表示 OTHER，amount0OutNet（仅买 DL 时有意义）
    event Swap(
        address indexed sender,
        uint256 amount0In,        // DL in
        uint256 amount1In,        // OTHER in
        uint256 amount0OutGross,  // DL out (gross)
        uint256 amount0OutNet,    // DL out (net = gross - feeOut)
        uint256 amount1OutGross,  // OTHER out (net)
        address indexed to
    );

    /* ---------------- Modifiers ---------------- */
    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(
        address dlToken,
        address otherToken,
        address owner_,
        address feeOwner_,
        uint32  feeNum_,
        uint32  feeDen_
    ) {
        require(dlToken != address(0) && otherToken != address(0), "ZERO_ADDR");
        require(dlToken != otherToken, "IDENTICAL_ADDR");
        require(owner_ != address(0), "ZERO_OWNER");
        require(feeDen_ > 0 && feeNum_ < feeDen_, "BAD_FEE");

        token0  = dlToken;
        token1  = otherToken;
        owner = owner_;
        feeNum  = feeNum_;
        feeDen  = feeDen_;
        feeOwner = feeOwner_;
    }

    /* ---------------- Views ---------------- */
    function getReserves() public view returns (uint112 _r0, uint112 _r1, uint32 _ts) {
        _r0 = reserve0; _r1 = reserve1; _ts = blockTimestampLast;
    }
    function getPriceCumulatives() external view returns (uint256 p0Cum, uint256 p1Cum, uint32 ts) {
        return (price0CumulativeLast, price1CumulativeLast, blockTimestampLast);
    }
    function token1Balance() public view returns (uint256) {
        return IERC20(token1).balanceOf(address(this)) + token1BalanceInit;
    }

    /* ---------------- Internal math ---------------- */
    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /* ---------------- Quotes (front-end helpers) ---------------- */

    function quoteBuyGivenGross(uint256 amount0OutGross)
        external view
        returns (uint256 in1Min, uint256 feeOut, uint256 out0Net)
    {
        require(liquidityInited, "NOT_INIT");
        (uint112 r0, uint112 r1,) = getReserves();
        require(amount0OutGross > 0 && amount0OutGross < r0, "BAD_GROSS");

        // in1_min = ceil(r1 * gross / (r0 - gross))
        uint256 denom = uint256(r0) - amount0OutGross;
        in1Min = _ceilDiv(uint256(r1) * amount0OutGross, denom);

        feeOut = (amount0OutGross * feeNum) / feeDen; // floor
        out0Net = amount0OutGross - feeOut;
    }

    function quoteBuyGivenNet(uint256 out0NetTarget)
        external view
        returns (uint256 grossMin, uint256 feeOut, uint256 in1Min)
    {
        require(liquidityInited, "NOT_INIT");
        (uint112 r0, uint112 r1,) = getReserves();
        require(out0NetTarget > 0 && out0NetTarget < r0, "BAD_NET");

        uint256 denom = uint256(feeDen) - feeNum; // >0
        grossMin = _ceilDiv(out0NetTarget * feeDen, denom); // ceil
        feeOut = (grossMin * feeNum) / feeDen;
        if (grossMin - feeOut < out0NetTarget) {
            unchecked { grossMin += 1; }
            feeOut = (grossMin * feeNum) / feeDen;
        }
        require(grossMin < r0, "INSUFFICIENT_LIQ");

        // in1_min = ceil(r1 * grossMin / (r0 - grossMin))
        uint256 d = uint256(r0) - grossMin;
        in1Min = _ceilDiv(uint256(r1) * grossMin, d);
    }

    function quoteBuyGivenIn1(uint256 amount1In)
        external view
        returns (uint256 grossMax, uint256 feeOut, uint256 out0Net)
    {
        require(liquidityInited, "NOT_INIT");
        (uint112 r0, uint112 r1,) = getReserves();
        require(amount1In > 0, "ZERO_IN");

        grossMax = (uint256(r0) * amount1In) / (uint256(r1) + amount1In); // floor
        require(grossMax < r0, "INSUFFICIENT_LIQ");
        require(grossMax > 0, "INSUFFICIENT_IN");

        feeOut = (grossMax * feeNum) / feeDen; // floor
        out0Net = grossMax - feeOut;
    }

    function quoteSell(uint256 amount0In)
        external view
        returns (uint256 feeIn, uint256 out1)
    {
        require(liquidityInited, "NOT_INIT");
        (uint112 r0, uint112 r1,) = getReserves();
        require(amount0In > 0, "ZERO_IN");

        feeIn = (amount0In * feeNum) / feeDen;
        uint256 in0Eff = amount0In - feeIn;
        out1 = (uint256(r1) * in0Eff) / (uint256(r0) + in0Eff); // floor
    }

    function quoteSellGivenOut1(uint256 out1Target)
        external view
        returns (uint256 in0Min, uint256 feeIn, uint256 in0EffMin)
    {
        require(liquidityInited, "NOT_INIT");
        (uint112 r0, uint112 r1,) = getReserves();
        require(out1Target > 0 && out1Target < r1, "BAD_OUT");

        // 有效输入（已扣费）下限：ceil(r0 * out1 / (r1 - out1))
        uint256 denom = uint256(r1) - out1Target;
        in0EffMin = _ceilDiv(uint256(r0) * out1Target, denom);

        // 把有效输入还原成毛输入（考虑 fee 向下取整，做一次校正）
        uint256 denom2 = uint256(feeDen) - feeNum; // >0
        in0Min = _ceilDiv(in0EffMin * feeDen, denom2);
        feeIn  = (in0Min * feeNum) / feeDen;
        if (in0Min - feeIn < in0EffMin) {
            unchecked { in0Min += 1; }
            feeIn = (in0Min * feeNum) / feeDen;
        }
    }

    function setOwner(address o) external onlyOwner {
        owner = o;
    }

    function setPrimaryMarket(address primary_) external onlyOwner {
        primaryMarket = IBondingCurvePrimaryMarket(primary_);
    }

    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to=0");
        IERC20(token).transfer(to, amount);
    }

    /// 由 owner 完成初始化（需先把 DL 与 OTHER 转入本合约）
    function mintInitial(uint256 _b1) external nonReentrant onlyOwner returns (uint amountDL, uint amountOther) {
        require(!liquidityInited, "ALREADY_INIT");

        token1BalanceInit = _b1;

        (uint112 r0, uint112 r1,) = getReserves(); // 预期(0,0)，但用差值更稳
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = token1Balance();

        amountDL    = b0 - r0;
        amountOther = b1 - r1;
        require(amountDL > 0 && amountOther > 0, "NEED_BOTH_SIDES");

        liquidityInited = true;
        _updateReserves();
        emit MintInitial(amountDL, amountOther);
    }

    function setFee(uint32 newNum, uint32 newDen, address feeOwner_) external {
         require(feeOwner == msg.sender, "NOT_FEEOWNER");
        require(newDen > 0 && newNum < newDen, "BAD_FEE");
        emit FeeChanged(feeNum, feeDen, newNum, newDen);
        feeNum = newNum;
        feeDen = newDen;
        feeOwner = feeOwner_;
    }

    /* ---------------- Swap (public) ---------------- */
    function swap(uint256 amount0OutGross, uint256 amount1OutGross, address to)
        external
        nonReentrant
    {
        require(liquidityInited, "NOT_INIT");
        require(to != address(0), "ZERO_TO");
        require(to != token0 && to != token1 && to != address(this), "INVALID_TO");
        require(amount0OutGross > 0 || amount1OutGross > 0, "ZERO_OUT");
        require(amount0OutGross == 0 || amount1OutGross == 0, "ONE_SIDE_ONLY");

        (uint112 r0, uint112 r1,) = getReserves();
        require(amount0OutGross < r0 && amount1OutGross < r1, "INSUFFICIENT_LIQ");

        // ======= 买 DL（OTHER -> DL）路径 =======
        if (amount0OutGross > 0) {
            // 1) 买前清灰 DL（防止外部预存 DL 被当作输入或纳入储备）
            {
                uint256 b0Pre = IERC20(token0).balanceOf(address(this));
                if (b0Pre > r0) {
                    uint256 dust = b0Pre - r0;
                    require(IERC20(token0).approve(address(primaryMarket), dust), "APP_FAIL");
                    uint256 usdtOut;
                    try primaryMarket.sellForUsdt(dust, 0, feeOwner) returns (uint256 out) {
                        usdtOut = out;
                    } catch {
                        require(IERC20(token0).approve(address(primaryMarket), 0), "APP_FAIL");
                        IDLBurnable(token0).burn(dust);
                    }

                    emit DustPurged(dust, usdtOut);
                }
            }

            // 2) 计算输出净额与手续费，转出净额并燃烧手续费
            uint256 dlOutFee = (amount0OutGross * feeNum) / feeDen;
            uint256 out0Net  = amount0OutGross - dlOutFee;

            if (out0Net > 0) IERC20(token0).safeTransfer(to, out0Net);
            if (dlOutFee > 0) {
                require(IERC20(token0).approve(address(primaryMarket), dlOutFee), "APP_FAIL");
                uint256 usdtOut;
                try primaryMarket.sellForUsdt(dlOutFee, 0, feeOwner) returns (uint256 out) {
                    usdtOut = out;
                } catch {
                    require(IERC20(token0).approve(address(primaryMarket), 0), "APP_FAIL");
                    IDLBurnable(token0).burn(dlOutFee);
                }

                emit FeeExchanged(dlOutFee, usdtOut);
            }

            // 3) 反推输入（余额差）
            uint256 b0 = IERC20(token0).balanceOf(address(this));
            uint256 b1 = token1Balance();
            uint256 in0 = b0 > r0 - amount0OutGross ? b0 - (r0 - amount0OutGross) : 0; // DL in（通常为0）
            uint256 in1 = b1 > r1 ? b1 - r1 : 0;                                       // OTHER in
            require(in0 > 0 || in1 > 0, "INSUFFICIENT_INPUT");

            // 4) 溢出防护 + K 校验（按真实余额）
            require(b0 <= type(uint112).max && b1 <= type(uint112).max, "OVERFLOW");
            require(b0 * b1 >= uint256(r0) * uint256(r1), "K");

            _updateReserves();
            emit Swap(msg.sender, in0, in1, amount0OutGross, out0Net, 0, to);
            return;
        }

        // ======= 卖 DL（DL -> OTHER）路径 =======
        {
            // 1) 先转出 OTHER（exact-out 风格）
            IERC20(token1).safeTransfer(to, amount1OutGross);

            // 2) 反推输入（余额差）
            uint256 b0 = IERC20(token0).balanceOf(address(this));
            uint256 b1 = token1Balance();
            uint256 in0 = b0 > r0 ? b0 - r0 : 0;                                       // DL in
            uint256 in1 = b1 > r1 - amount1OutGross ? b1 - (r1 - amount1OutGross) : 0; // OTHER in（通常为0）
            require(in0 > 0 || in1 > 0, "INSUFFICIENT_INPUT");

            // 3) 对 DL 输入扣费并燃烧，再用净额参与 K 校验
            uint256 feeIn = (in0 * feeNum) / feeDen;
            if (feeIn > 0) {
                require(IERC20(token0).approve(address(primaryMarket), feeIn), "APP_FAIL");
                uint256 usdtOut;
                try primaryMarket.sellForUsdt(feeIn, 0, feeOwner) returns (uint256 out) {
                    usdtOut = out;
                } catch {
                    require(IERC20(token0).approve(address(primaryMarket), 0), "APP_FAIL");
                    IDLBurnable(token0).burn(feeIn);
                }

                emit FeeExchanged(feeIn, usdtOut);
                unchecked { b0 -= feeIn; }
            }

            // 4) 溢出防护 + K 校验（按真实余额）
            require(b0 <= type(uint112).max && b1 <= type(uint112).max, "OVERFLOW");
            require(b0 * b1 >= uint256(r0) * uint256(r1), "K");

            _updateReserves();
            emit Swap(msg.sender, in0, in1, 0, 0, amount1OutGross, to);
            return;
        }
    }

    function sync() external nonReentrant {
        (uint112 r0,,) = getReserves();
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        if (b0 > r0) {
            uint256 extra = b0 - r0;
            require(IERC20(token0).approve(address(primaryMarket), extra), "APP_FAIL");
            uint256 usdtOut;
            try primaryMarket.sellForUsdt(extra, 0, feeOwner) returns (uint256 out) {
                usdtOut = out;
            } catch {
                require(IERC20(token0).approve(address(primaryMarket), 0), "APP_FAIL");
                IDLBurnable(token0).burn(extra);
            }
            
            emit DustPurged(extra, usdtOut);
        }
        _updateReserves();
    }

    /* ---------------- internal ---------------- */
    function _updateReserves() internal {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = token1Balance();
        require(b0 <= type(uint112).max && b1 <= type(uint112).max, "OVERFLOW");

        uint32 ts = uint32(block.timestamp);
        uint32 elapsed = ts - blockTimestampLast; // uint32 wrap-safe

        if (elapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            unchecked {
                // UQ112x112 prices
                uint256 price0 = (uint256(uint224(reserve1)) << 112) / reserve0; // token1/token0
                uint256 price1 = (uint256(uint224(reserve0)) << 112) / reserve1; // token0/token1
                price0CumulativeLast += price0 * elapsed;
                price1CumulativeLast += price1 * elapsed;
            }
        }

        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
        blockTimestampLast = ts;
        emit Sync(reserve0, reserve1);
    }
}
