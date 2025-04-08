// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract FlashArbBot is FlashLoanReceiverBase {
    event ArbitrageCompleted(uint profit);
    event ArbitrageFailed(bytes error);
    
    uint256 constant DEADLINE = 300; // 5 minutes
    
    constructor(address _aaveLendingPool, IUniswapV2Router02 _uniswapV2Router, IUniswapV2Router02 _sushiswapV1Router)
        FlashLoanReceiverBase(_aaveLendingPool)
        public
    {
        uniswapV2Router = _uniswapV2Router;
        sushiswapV1Router = _sushiswapV1Router;
    }

    function flashloan(
        address _flashAsset,
        uint _amount,
        address _daiTokenAddress,
        uint _amountToTrade,
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
            uint256 profit = finalBalance.sub(initialBalance);
            
            emit ArbitrageCompleted(profit);
        } catch (bytes memory reason) {
            emit ArbitrageFailed(reason);
            revert(string(reason));
        }

        uint256 totalDebt = _amount.add(_fee);
        transferFundsBackToPoolInternal(_reserve, totalDebt);
    }

    function executeArbitrage() private {
        address[] memory path = getPathForETHToToken(daiTokenAddress);
        
        uniswapV2Router.swapETHForExactTokens{
            value: amountToTrade,
            gas: gasleft()
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
}