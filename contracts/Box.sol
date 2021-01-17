// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IPuzzlePieceFactory.sol";
import "./interfaces/IBoxRanking.sol";
import "./interfaces/ISwapWrapper.sol";
import "./interfaces/IMain.sol";

contract Box is ERC20, Ownable, ReentrancyGuard {
    using Math for uint256;
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public officialBoxAmount;

    IMain public main;

    struct Unboxing {
        bool isOfficial;
        uint256 amount;
        uint256 targetBlock;
    }

    mapping(address => Unboxing) public unboxing;
    uint256 public unboxingWaitBlock;
    mapping(address => uint256[]) public lastPuzzlePiece;

    uint256 public constant unit = 10**18;

    uint256 public boxFee = unit * 2; // USDT
    uint256 public boxFeeOfficial = unit / 2; // USDT

    event Open(address indexed self, uint256 amount);
    event OpenOfficial(address indexed self, uint256 amount);
    event TakePuzzlePiece(address indexed self, uint256 boxAmount, uint256 pieceAmount);

    modifier needRegistered(address _sender) {
        require(main.registered(_sender), "Unregistered");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        address _main,
        uint256 _unboxingWaitBlock
    ) ERC20(_name, _symbol) {
        main = IMain(_main);
        unboxingWaitBlock = _unboxingWaitBlock;
    }

    function setUnboxingWaitBlock(uint256 _unboxingWaitBlock) public onlyOwner {
        unboxingWaitBlock = _unboxingWaitBlock;
    }

    function setBoxFee(uint256 _fee) public onlyOwner {
        boxFee = _fee;
    }

    function setBoxFeeOfficial(uint256 _fee) public onlyOwner {
        boxFeeOfficial = _fee;
    }

    function mint(address _account, uint256 _amount) public {
        require(main.pool() == _msgSender(), "Caller is not the pool");
        _mint(_account, _amount);
    }

    function mintOfficial(uint256 _amount) public {
        require(main.pool() == _msgSender(), "Caller is not the pool");
        officialBoxAmount = officialBoxAmount.add(_amount);
    }

    function open(uint256 _amount) public needRegistered(msg.sender) nonReentrant {
        require(_amount > 0, "Amount must be greater than zero");
        _burn(msg.sender, _amount.mul(unit));

        addUnboxing(_amount, false);
        IBoxRanking(main.boxRanking()).open(msg.sender, _amount);

        shareOpenBoxFee(false, msg.sender, _amount);

        emit Open(msg.sender, _amount);
    }

    function openOfficial(uint256 _amount) public needRegistered(msg.sender) nonReentrant {
        require(_amount > 0, "Amount must be greater than zero");
        officialBoxAmount = officialBoxAmount.sub(_amount.mul(unit));

        IBoxRanking(main.boxRanking()).open(msg.sender, _amount);
        addUnboxing(_amount, true);

        shareOpenBoxFee(true, msg.sender, _amount);

        emit OpenOfficial(msg.sender, _amount);
    }

    function takePuzzlePiece(uint256 _amount) public needRegistered(msg.sender) nonReentrant {
        require(_amount > 0, "Invalid _amount");
        require(unboxing[msg.sender].amount >= _amount, "No unboxing");

        Unboxing storage box = unboxing[msg.sender];
        require(block.number > box.targetBlock, "Please wait");

        box.amount = box.amount.sub(_amount);

        lastPuzzlePiece[msg.sender] = IPuzzlePieceFactory(main.puzzlePieceFactory()).create(
            msg.sender,
            box.isOfficial,
            box.targetBlock,
            _amount
        );

        emit TakePuzzlePiece(msg.sender, _amount, lastPuzzlePiece[msg.sender].length);
    }

    function getLastPuzzlePiece(address _sender) public view returns (uint256[] memory) {
        return lastPuzzlePiece[_sender];
    }

    function addUnboxing(uint256 _amount, bool _isOfficial) private {
        require(unboxing[msg.sender].amount == 0, "Already unboxing");

        unboxing[msg.sender] = Unboxing({
            isOfficial: _isOfficial,
            amount: _amount,
            targetBlock: block.number.add(unboxingWaitBlock)
        });
    }

    function shareOpenBoxFee(
        bool _official,
        address _user,
        uint256 _amount
    ) private {
        (, uint256 userID) = main.getUser(_user);
        address inviter = main.getInviterAddr(userID);

        uint256 totalFee;
        uint256 officialFee;
        if (_official) {
            totalFee = ISwapWrapper(main.swapWrapper()).getUSDTAmountOut(boxFeeOfficial).mul(_amount);
        } else {
            totalFee = ISwapWrapper(main.swapWrapper()).getUSDTAmountOut(boxFee).mul(_amount);
            officialFee = totalFee.mul(75).div(100);
            totalFee = totalFee.sub(officialFee);
        }

        IERC20 eKey = IERC20(main.eKey());

        if (inviter == address(0)) {
            officialFee = officialFee.add(totalFee.mul(20).div(100));
        } else {
            eKey.transferFrom(_user, inviter, totalFee.mul(20).div(100));
        }

        eKey.transferFrom(_user, main.boxRanking(), totalFee.mul(40).div(100));

        eKey.transferFrom(_user, main.puzzle(), totalFee.mul(40).div(100));

        if (officialFee > 0) {
            eKey.transferFrom(_user, main.projectAddr(), officialFee);
        }
    }
}
