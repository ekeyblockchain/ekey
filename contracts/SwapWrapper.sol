// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";

import "./interfaces/IMain.sol";

import "./PancakeRouter.sol";

contract SwapWrapper is Ownable, ReentrancyGuard {
    IMain public main;
    address puzzlePieceExchange;
    IPancakeRouter02 public swapRouter;
    address public weth;
    address public eKey;
    address[] public ethPath;
    address[] public usdtPath;
    address[] public ekeyPath;
    address[] public wethPath;
    uint256 constant initEKeySwapAmount = 300;

    modifier onlyPool() {
        require(main.pool() == _msgSender(), "Caller is not the pool");
        _;
    }

    modifier onlyPuzzlePiece() {
        require(main.puzzlePiece() == _msgSender(), "Caller is not the puzzle piece");
        _;
    }

    modifier onlyPuzzlePieceExchange() {
        require(puzzlePieceExchange == _msgSender(), "Caller is not the puzzle piece exchange");
        _;
    }

    constructor(
        address _main,
        address _puzzlePieceExchange,
        address _swapRouter,
        address _weth,
        address _usdt,
        address _eKey
    ) {
        main = IMain(_main);
        puzzlePieceExchange = _puzzlePieceExchange;
        swapRouter = IPancakeRouter02(_swapRouter);
        weth = _weth;
        eKey = _eKey;

        ethPath.push(_weth);
        ethPath.push(_eKey);

        usdtPath.push(_usdt);
        usdtPath.push(_weth);
        usdtPath.push(_eKey);

        ekeyPath.push(_eKey);
        ekeyPath.push(_weth);
        ekeyPath.push(_usdt);

        wethPath.push(_weth);
        wethPath.push(_usdt);
    }

    function setPuzzlePieceExchange(address _puzzlePieceExchange) public onlyOwner {
        puzzlePieceExchange = _puzzlePieceExchange;
    }

    function getLP() public view returns (address) {
        return IPancakeFactory(swapRouter.factory()).getPair(eKey, swapRouter.WETH());
    }

    function getUSDTAmountOut(uint256 _amountIn) external view returns (uint256) {
        uint256[] memory amounts = swapRouter.getAmountsOut(_amountIn, usdtPath);
        return amounts[2];
    }

    function getETHAmountOut(uint256 _amountIn) external view returns (uint256) {
        uint256[] memory amounts = swapRouter.getAmountsOut(_amountIn, ethPath);
        return amounts[1];
    }

    function getEKeyPrice() external view returns (uint256) {
        uint256[] memory amounts = swapRouter.getAmountsOut(10**18, ekeyPath);
        return amounts[2];
    }

    function totalAssets() external view returns (uint256) {
        IPancakeFactory factory = IPancakeFactory(swapRouter.factory());
        address pair = factory.getPair(ethPath[0], ethPath[1]);
        uint256[] memory amounts1 = swapRouter.getAmountsOut(IERC20(eKey).balanceOf(pair), ekeyPath);
        uint256[] memory amounts2 = swapRouter.getAmountsOut(IERC20(weth).balanceOf(pair), wethPath);
        return amounts1[2] + amounts2[1];
    }

    function approve() public onlyOwner {
        IERC20(eKey).approve(address(swapRouter), 2**255);
    }

    function createLiquidity(address _to) external payable onlyPool returns (uint256) {
        (, uint256 amountETH, uint256 liquidity) =
            swapRouter.addLiquidityETH{ value: msg.value }(
                address(eKey),
                msg.value * initEKeySwapAmount,
                0,
                0,
                _to,
                block.timestamp
            );
        if (msg.value > amountETH) {
            main.projectAddr().transfer(msg.value - amountETH);
        }
        return liquidity;
    }

    function addLiquidityETH(address payable _owner, address _to) external payable onlyPool returns (uint256) {
        uint256[] memory amounts = swapRouter.getAmountsOut(msg.value, ethPath);

        (, uint256 amountETH, uint256 liquidity) =
            swapRouter.addLiquidityETH{ value: msg.value }(address(eKey), amounts[1], 0, 0, _to, block.timestamp);
        if (msg.value > amountETH) {
            _owner.transfer(msg.value - amountETH);
        }
        return liquidity;
    }

    function addLiquidityETHSwap(address payable _owner, address _to) external payable onlyPool returns (uint256) {
        uint256 eth = msg.value / 2;
        uint256[] memory amounts = swapRouter.swapExactETHForTokens{ value: eth }(0, ethPath, _to, block.timestamp);

        (, uint256 amountETH, uint256 liquidity) =
            swapRouter.addLiquidityETH{ value: msg.value - eth }(address(eKey), amounts[1], 0, 0, _to, block.timestamp);
        if (msg.value - eth > amountETH) {
            _owner.transfer(msg.value - eth - amountETH);
        }
        return liquidity;
    }

    function swapETH(address _to) external payable onlyPuzzlePieceExchange returns (uint256) {
        uint256[] memory amounts =
            swapRouter.swapExactETHForTokens{ value: msg.value }(0, ethPath, _to, block.timestamp);
        return amounts[1];
    }

    function burn() public onlyOwner {
        ERC20Burnable token = ERC20Burnable(eKey);
        token.burn(token.balanceOf(address(this)));
    }

    fallback() external payable {}
}
