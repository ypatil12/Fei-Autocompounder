pragma solidity ^0.6.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router.sol";
import "./UniswapV2Library.sol";
import "../interfaces/ITribalChief.sol";


contract FEITribeAutoCompounder is Ownable, ERC20 {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Decimal for Decimal.D256;

    address public fei;
    address public tribe;
    address public feiTribeUniPair;
    address public univ2Router;
    address public tribalChief;
    address[] public tribeFeiPath;
    uint256 poolId;
    //Fee is represented as Basis Points *100
    uint256 fee;
    uint256 public constant FEE_GRANULARITY = 10000;


    constructor(
        address _fei,
        address _tribe,
        address _feiTribeUniPair,
        address _univ2Router,
        address _tribalChief,
        uint256 poolId,
        uint256 fee
    ) ERC20("FEI-Tribe Autocompounder Shares", "FTAS") {
        fei = _fei;
        tribe = _tribe;
        feiTribeUniPair = _feiTribeUniPair;
        univ2Router = _univ2Router;
        tribalChief = _tribalChief;
        
        tribeFeiPath = new address[](2);
        tribeFeiPath[0] = tribe;
        tribeFeiPath[1] = fei;

        IERC20(fei).approve(univ2Router, uint256(-1));
        IERC20(tribe).approve(univ2Router, uint256(-1));
        IERC20(_feiTribeUniPair).approve(tribalChief, uint256(-1));
    }

    function getStakedTokens() external view returns(uint256){
        return ITribalChief(tribalChief).getTotalStakedInPool(poolId, address(this));
    }

    function deposit(uint256 LPTokens) external nonReentrant {
        //Deposit LP
        IERC20(feiTribeUniPair).safeTransferFrom(msg.sender, address(this), LPTokens);
        uint256 shares = 0;
        if (totalSupply() == 0){
            shares = LPTokens;
        }else{
            shares = Decimal.from(LPTokens).mul(totalSupply())).div(getStakedTokens()).asUint256();
        }

        //Get any leftover LP Tokens and deposit
        uint256 depositAmount = IERC20(feiTribeUniPair).balanceOf(address(this));
        ITribalChief(tribalChief).deposit(poolId, depositAmount, 0);
        _mint(msg.sender, shares);
    }

    function withdraw(uint256 shares) external nonReentrant {
        require(balanceOf(msg.sender) >= shares, 'Request too many shares to be withdrawn');

        uint256 LPTokens = Decimal.from(shares).mul(getStakedTokens())).div(totalSupply()).asUint256();

        uint256 depositLength = ITribalChief(tribalChief).openUserDeposits(poolId, address(this));
        uint256[] depositAmounts = new uint256[](depositLength);

        uint256 depositSum = 0;
        uint256 count = 0;

        //Can we combine the below two loops into one - main issue is checking if sum >= LPTokens
        for(uint256 i = 0; i < depositLength; i++){
            (uint256 amount, , ) = ITribalChief(tribalChief).depositInfo(poolId, address(this), i);

            if(amount > 0){
                depositAmounts[i] = amount;
                sum = sum.add(amount);
            }
            count++;
            if(sum>=LPTokens){
                break;
            }
        }

        require(sum >= LPTokens, "Insufficient amount staked ");

        for(uint256 i = 0; i < count; i++){
            if(depositAmount[i] > 0){
                //Don't want to withdraw entire deposit of the last depositIndex... but this would be handled in harvest or new staker - clears all dust
                if (i == count - 1){
                    ITribalChief.withdrawFromDeposit(poolId, sum, address(this), index);
                }
                else{
                    ITribalChief.withdrawFromDeposit(poolId, depositAmounts[i], address(this), i);
                }
                sum = sum.sub(depositAmounts[i]);
            }
        }

        _burn(msg.sender, shares);
        IERC20(feiTribeUniPair).safeTransfer(msg.sender, LPTokens);

    }

    function harvest() onlyOwner {
        //Get Tribe reward
        ITribalChief.harvest(poolId, address(this));
        uint256 tribeBalance = IERC20(tribe).balanceOf(address(this));

        if (tribeBalance) > 0{
            //Take fee
            uint256 tribeFees = Decimal.from(tribeBalance).mul(fee).div(FEE_GRANULARITY).asUint256();
            IERC20(tribe).safeTransfer(owner(), tribeFees);
            tribeBalance = tribeBalance - keptTribe; 

            // Get FEI-TRIBE pair reserves
            (uint256 _token0, uint256 _token1, ) = IUniswapV2Pair(feiTribeUniPair).getReserves()
            (uint256 tribeReserve, uint256 feiReserve) = IUniswapV2Pair.token0() == tribe 
                ? (_token0, _token1) : (_token1, _token0);
            
            //Prepare swap
            uint256 amountIn = tribeBalance.div(2);
            uint256 amountOut = UniswapV2Library.getAmountOut(amountIn, tribeReserve, feiReserve);
            //Swap 50% of Tribe for FEI
            feiTribeUniPair.swap(amountIn, amountOut, address(this), new bytes(0));

            //add liquidity to uniswap pool 
            uint256 feiBalance = IERC20(fei).balanceOf(address(this));
            tribeBalance = IERC20(tribe).balannceOf(address(this));
            if (feiBalance > 0 && tribeBalance > 0){
                IUniswapV2Router(univ2Router).addLiquidity(
                    fei,
                    tribe,
                    feiBalance,
                    tribeBalance, 
                    0,
                    0,
                    address(this),
                    now + 60
                );
            }

            //send dust back to owner
            feiBalance = IERC20(fei).balanceOf(address(this));
            tribeBalance = IERC20(tribe).balannceOf(address(this));
            
            if (feiBalance > 0){
                IERC20(fei).safeTransfer(owner(), feiBalance);
            }
            if (tribeBalance > 0){
                IERC20(tribe).safeTransfer(owner(), tribeBalance);
            }

            //stake in TribalChief
            uint256 lpTokens = IERC20(feiTribePair).balanceOf(address(this));
            if (lpTokens > 0){
                ITribalChief(tribalChief).deposit(poolId, lpTokens, 0);
            }
        
        }
    }

    function updateFee(uint256 _fee) onlyOwner {
        fee = _fee;
    }
    
}