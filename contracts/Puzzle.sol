// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/IMain.sol";
import "./interfaces/IPuzzleData.sol";
import "./interfaces/ISwapWrapper.sol";

contract Puzzle is ERC721, Ownable {
    using Math for uint256;
    using SafeMath for uint256;

    uint256 tokenCount;
    mapping(uint256 => uint16) public puzzleNumber;

    uint16 public greatNumber;
    uint256 public greatReward;
    uint256 public lastGreatBlock;
    uint256 public constant dayBlocks = 28800;

    IMain main;

    event PayForPuzzlePiece(address indexed user, uint256 amount);
    event MintReward(address indexed user, uint256 amount);

    modifier onlyPuzzlePiece() {
        require(main.puzzlePiece() == _msgSender(), "Caller is not the puzzlePiece");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        address _main
    ) ERC721(_name, _symbol) {
        main = IMain(_main);
    }

    function setGreatNumber(uint256 _reward, uint16 _num) public onlyOwner {
        greatNumber = _num;
        greatReward = _reward;
        lastGreatBlock = block.number;
    }

    function getReward(uint16 _num) public view returns (uint256) {
        if (_num == greatNumber) {
            return calcGreatReward();
        } else {
            return IPuzzleData(main.puzzleData()).getPuzzleReward(_num);
        }
    }

    function payForPuzzlePiece(address _user, uint256 _ekeyAmount) external onlyPuzzlePiece {
        IERC20(main.eKey()).transfer(_user, _ekeyAmount);
        emit PayForPuzzlePiece(_user, _ekeyAmount);
    }

    function mint(address _to, uint16 _num) external onlyPuzzlePiece returns (uint256) {
        uint256 tokenId = tokenCount++;
        _mint(_to, tokenId);
        puzzleNumber[tokenId] = _num;

        uint256 reward = 0;
        if (_num == greatNumber) {
            reward = calcGreatReward();
            lastGreatBlock = block.number;
        } else {
            reward = IPuzzleData(main.puzzleData()).getPuzzleReward(_num);
        }
        reward = ISwapWrapper(main.swapWrapper()).getUSDTAmountOut(reward);
        IERC20 eKey = IERC20(main.eKey());
        reward = reward.min(eKey.balanceOf(address(this)));

        eKey.transfer(_to, reward);
        emit MintReward(_to, reward);

        return tokenId;
    }

    function calcGreatReward() private view returns (uint256) {
        uint256 day = block.number.sub(lastGreatBlock).div(dayBlocks);
        return day.mul(50*(10**18)).add(greatReward);
    }
}
