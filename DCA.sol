//SPDX-License-Identifier:MIT 
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

abstract contract DCAStrategy is AutomationCompatibleInterface, Ownable {
    IPool public aavePool;
    ISwapRouter public uniswapRouter;
    address public chainlinkAutomationRegistry;

    struct DCAConfig {
        address inToken; // Token deposited by the user
        address outToken;
        uint256 dcaAmount;
        uint256 frequency;
        uint256 nextExecution;
        bool paused;
    }

    mapping(address => mapping(address => uint256)) public userBalances; // user -> token -> amount
    mapping(address => DCAConfig) public userDCAConfig;
    address[] public users; // To keep track of users for upkeep checks

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event StrategySet(address indexed user, address indexed outToken, uint256 dcaAmount, uint256 frequency);
    event DCAPaused(address indexed user);
    event DCAResumed(address indexed user);
    event DCAExecuted(address indexed user, uint256 amountIn, uint256 amountOut);

    constructor(
        address _aavePool,
        address _uniswapRouter,
        address _chainlinkAutomationRegistry
    ) {
        aavePool = IPool(_aavePool);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        chainlinkAutomationRegistry = _chainlinkAutomationRegistry;
    }

    function deposit(address token, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        IERC20(token).approve(address(aavePool), amount);
        aavePool.supply(token, amount, address(this), 0);
        userBalances[msg.sender][token] += amount;

        // Add user to users array if this is their first deposit
        if (userBalances[msg.sender][token] == amount) {
            users.push(msg.sender);
        }

        emit Deposited(msg.sender, token, amount);
    }

    // function withdraw(address token, uint256 amount) external {
    //     require(userBalances[msg.sender][token] >= amount, "Insufficient balance");
    //     userBalances[msg.sender][token] -= amount;
    //     aavePool.withdraw(token, amount, msg.sender);

    //     emit Withdrawn(msg.sender, token, amount);
    // }

    function setDCA(address outToken, uint256 dcaAmount, uint256 frequency) external {
        address inToken = getUserDepositedToken(msg.sender);
        require(inToken != address(0), "No tokens deposited");

        userDCAConfig[msg.sender] = DCAConfig({
            inToken: inToken,
            outToken: outToken,
            dcaAmount: dcaAmount,
            frequency: frequency,
            nextExecution: block.timestamp + frequency,
            paused: false
        });

        emit StrategySet(msg.sender, outToken, dcaAmount, frequency);
    }

    function pauseDCA() external {
        userDCAConfig[msg.sender].paused = true;
        emit DCAPaused(msg.sender);
    }

    function resumeDCA() external {
        userDCAConfig[msg.sender].paused = false;
        emit DCAResumed(msg.sender);
    }

    function checkUpkeep(bytes calldata /* checkData */)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        for (uint256 i = 0; i < users.length; i++) {
            address userAddress = users[i];
            DCAConfig memory config = userDCAConfig[userAddress];
            if (!config.paused && block.timestamp >= config.nextExecution) {
                upkeepNeeded = true;
                performData = abi.encode(userAddress);
                return (upkeepNeeded, performData);
            }
        }
        upkeepNeeded = false;
    }

    function performUpkeep(bytes calldata performData) external override {
        address userAddress = abi.decode(performData, (address));
        DCAConfig storage config = userDCAConfig[userAddress];
        if (block.timestamp >= config.nextExecution && !config.paused) {
            uint256 amountIn = config.dcaAmount;
            address tokenIn = config.inToken;
            require(userBalances[userAddress][tokenIn] >= amountIn, "Insufficient balance for DCA");

            // Withdraw from Aave
            aavePool.withdraw(tokenIn, amountIn, address(this));
            IERC20(tokenIn).approve(address(uniswapRouter), amountIn);

            // Swap on Uniswap
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: config.outToken,
                fee: 3000,
                recipient: userAddress,
                deadline: block.timestamp + 60,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            uint256 amountOut = uniswapRouter.exactInputSingle(params);

            // Update balances and next execution time
            userBalances[userAddress][tokenIn] -= amountIn;
            config.nextExecution = block.timestamp + config.frequency;

            emit DCAExecuted(userAddress, amountIn, amountOut);
        }
    }

    function getUserDepositedToken(address userAddress) internal view returns (address) {
        for (uint256 i = 0; i < users.length; i++) {
            if (userBalances[userAddress][users[i]] > 0) {
                return users[i];
            }
        }
        return address(0);
    }


    /*
       modification can be done 
    */
    function withdraw(address token, uint256 amount) external {
    require(userBalances[msg.sender][token] >= amount, "Insufficient balance");

    uint256 aaveBalance = IERC20(token).balanceOf(address(this)); // Check available balance in Aave pool
    uint256 amountToWithdrawFromAave = 0 ; 
    if(aaveBalance>=amount)
    {
        amountToWithdrawFromAave = amount;
    }
    else 
    {
        amountToWithdrawFromAave = aaveBalance;

    }

    uint256 totalWithdrawn = 0;

    // Withdraw from Aave if there are enough funds
    if (amountToWithdrawFromAave > 0) {
        aavePool.withdraw(token, amountToWithdrawFromAave, address(this));
        userBalances[msg.sender][token] -= amountToWithdrawFromAave;
        totalWithdrawn += amountToWithdrawFromAave;
        amount -= amountToWithdrawFromAave;
    }

    // Swap tokens if the remaining amount is greater than 0
    if (amount > 0) {
        DCAConfig storage config = userDCAConfig[msg.sender];
        address inToken = config.inToken;

        require(inToken != address(0), "No DCA configuration found");

        uint256 inTokenBalance = userBalances[msg.sender][inToken];
        require(inTokenBalance >= amount, "Insufficient balance in inToken");
        IERC20(inToken).approve(address(uniswapRouter), amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: inToken,
            tokenOut: token,
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp + 60,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        userBalances[msg.sender][inToken] -= amount;
        totalWithdrawn += amountOut;
    }

    // Transfer the total withdrawn amount to the user
    IERC20(token).transfer(msg.sender, totalWithdrawn);

    emit Withdrawn(msg.sender, token, totalWithdrawn);
}

}