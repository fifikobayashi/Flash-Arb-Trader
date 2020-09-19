pragma solidity 0.6.12;

/**
    Ropsten instances:
    - Uniswap V2 Router:                    0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
    - Sushiswap V1 Router:                  No official sushi routers on testnet
    - DAI:                                  0xf80A32A835F79D7787E8a8ee5721D0fEaFd78108
    - ETH:                                  0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
    - Aave LendingPoolAddressesProvider:    0x1c8756FD2B28e9426CDBDcC7E3c4d64fa9A54728
    
    Mainnet instances:
    - Uniswap V2 Router:                    0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
    - Sushiswap V1 Router:                  0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F
    - DAI:                                  0x6B175474E89094C44Da98b954EedeAC495271d0F
    - ETH:                                  0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
    - Aave LendingPoolAddressesProvider:    0x24a42fD28C976A61Df5D00D0599C34c4f90748c8
*/

// importing flash loan dependencies as per https://docs.aave.com/developers/tutorials/performing-a-flash-loan/...-with-remix
import "https://github.com/aave/flashloan-box/blob/Remix/contracts/aave/FlashLoanReceiverBase.sol";
import "https://github.com/aave/flashloan-box/blob/Remix/contracts/aave/ILendingPoolAddressesProvider.sol";
import "https://github.com/aave/flashloan-box/blob/Remix/contracts/aave/ILendingPool.sol";

// importing both Sushiswap V1 and Uniswap V2 Router02 dependencies
import "https://github.com/sushiswap/sushiswap/blob/master/contracts/uniswapv2/interfaces/IUniswapV2Router02.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/math/SafeMath.sol";

contract FlashArbTrader is FlashLoanReceiverBase {

    using SafeMath for uint256;
    IUniswapV2Router02 uniswapV2Router;
    IUniswapV2Router02 sushiswapV1Router;
    uint deadline;
    IERC20 dai;
    address daiTokenAddress;
    uint256 amountToTrade;
    uint256 tokensOut;
    
    /**
        Initialize deployment parameters
     */
    constructor(
        address _aaveLendingPool, 
        IUniswapV2Router02 _uniswapV2Router, 
        IUniswapV2Router02 _sushiswapV1Router
        ) FlashLoanReceiverBase(_aaveLendingPool) public {

            // instantiate SushiswapV1 and UniswapV2 Router02
            sushiswapV1Router = IUniswapV2Router02(address(_sushiswapV1Router));
            uniswapV2Router = IUniswapV2Router02(address(_uniswapV2Router));

            // setting deadline to avoid scenario where miners hang onto it and execute at a more profitable time
            deadline = block.timestamp + 300; // 5 minutes
    }
    
    /**
        Mid-flashloan logic i.e. what you do with the temporarily acquired flash liquidity
     */
    function executeOperation(
        address _reserve,
        uint256 _amount,
        uint256 _fee,
        bytes calldata _params
    )
        external
        override
    {
        require(_amount <= getBalanceInternal(address(this), _reserve), "Invalid balance");

        // execute arbitrage strategy
        try this.executeArbitrage() {
        } catch Error(string memory) {
            // Reverted with a reason string provided
        } catch (bytes memory) {
            // failing assertion, division by zero.. blah blah
        }

        // return the flash loan plus Aave's flash loan fee back to the lending pool
        uint totalDebt = _amount.add(_fee);
        transferFundsBackToPoolInternal(_reserve, totalDebt);
    }

    /**
        The specific cross protocol swaps that makes up your arb strategy
        UniswapV2 -> SushiswapV1 example below
     */
    function executeArbitrage() public {

        // Trade 1: Execute swap of Ether into designated ERC20 token on UniswapV2
        try uniswapV2Router.swapETHForExactTokens{ 
            value: amountToTrade 
        }(
            amountToTrade, 
            getPathForETHToToken(daiTokenAddress), 
            address(this), 
            deadline
        ){
        } catch {
            // error handling when arb failed due to trade 1
        }
        
        // Re-checking prior to execution since the NodeJS bot that instantiated this contract would have checked already
        uint256 tokenAmountInWEI = tokensOut.mul(1000000000000000000); //convert into Wei
        uint256 estimatedETH = getEstimatedETHForToken(tokensOut, daiTokenAddress)[0]; // check how much ETH you'll get for x number of ERC20 token
        
        // grant uniswap / sushiswap access to your token, DAI used since we're swapping DAI back into ETH
        dai.approve(address(uniswapV2Router), tokenAmountInWEI);
        dai.approve(address(sushiswapV1Router), tokenAmountInWEI);

        // Trade 2: Execute swap of the ERC20 token back into ETH on Sushiswap to complete the arb
        try sushiswapV1Router.swapExactTokensForETH (
            tokenAmountInWEI, 
            estimatedETH, 
            getPathForTokenToETH(daiTokenAddress), 
            address(this), 
            deadline
        ){
        } catch {
            // error handling when arb failed due to trade 2    
        }
    }

    /**
        sweep entire balance on the arb contract back to contract owner
     */
    function WithdrawBalance() public payable onlyOwner {
        
        // withdraw all ETH
        msg.sender.call{ value: address(this).balance }("");
        
        // withdraw all x ERC20 tokens
        dai.transfer(msg.sender, dai.balanceOf(address(this)));
    }

    /**
        Flash loan x amount of wei's worth of `_flashAsset`
        e.g. 1 ether = 1000000000000000000 wei
     */
    function flashloan (
        address _flashAsset, 
        uint _flashAmount,
        address _daiTokenAddress,
        uint _amountToTrade,
        uint256 _tokensOut
        ) public onlyOwner {
            
        bytes memory data = "";

        daiTokenAddress = address(_daiTokenAddress);
        dai = IERC20(daiTokenAddress);
        
        amountToTrade = _amountToTrade; // how much wei you want to trade
        tokensOut = _tokensOut; // how many tokens you want converted on the return trade     

        // call lending pool to commence flash loan
        ILendingPool lendingPool = ILendingPool(addressesProvider.getLendingPool());
        lendingPool.flashLoan(address(this), _flashAsset, uint(_flashAmount), data);
    }

    /**
        Using a WETH wrapper here since there are no direct ETH pairs in Uniswap v2
        and sushiswap v1 is based on uniswap v2
     */
    function getPathForETHToToken(address ERC20Token) private view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = ERC20Token;
    
        return path;
    }

    /**
        Using a WETH wrapper to convert ERC20 token back into ETH
     */
     function getPathForTokenToETH(address ERC20Token) private view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = ERC20Token;
        path[1] = sushiswapV1Router.WETH();
        
        return path;
    }

    /**
        helper function to check ERC20 to ETH conversion rate
     */
    function getEstimatedETHForToken(uint _tokenAmount, address ERC20Token) public view returns (uint[] memory) {
        return uniswapV2Router.getAmountsOut(_tokenAmount, getPathForTokenToETH(ERC20Token));
    }
}
