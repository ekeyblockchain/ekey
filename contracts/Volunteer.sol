// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IMain.sol";
import "./interfaces/IPool.sol";
import "./interfaces/ISwapWrapper.sol";
import "./Activity.sol";

contract Volunteer is Ownable, ReentrancyGuard, Activity {
    using SafeMath for uint256;

    IMain public main;

    mapping(uint256 => uint256) public usedCount;
    mapping(uint256 => uint256) public inviteeETH;

    uint256 constant unit = 10**18;
    uint256 public constant target = 10;

    uint256 public endBlock;
    uint256 public withdrawEndBlock;

    event Withdraw(address indexed user, uint256 userID, uint256 amount);
    event AddInviteeETH(uint256 indexed userID, uint256 eth);

    modifier onlyActivityEntrance() {
        require(main.activityEntrance() == _msgSender(), "Caller is not the activityEntrance");
        _;
    }

    constructor(
        address _main,
        uint256 _endBlock,
        uint256 _withdrawEndBlock
    ) {
        main = IMain(_main);
        endBlock = _endBlock;
        withdrawEndBlock = _withdrawEndBlock;
    }

    function getInfo(uint256 _userID)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 eth = inviteeETH[_userID];
        uint256 tc = eth.div(unit).div(target);
        return (eth, tc, tc.sub(usedCount[_userID]));
    }

    function withdraw() public {
        require(block.number >= endBlock && block.number < withdrawEndBlock, "Prohibit withdrawal");

        (, uint256 userID) = main.getUser(msg.sender);
        uint256 tc = inviteeETH[userID].div(unit).div(target);
        uint256 uc = usedCount[userID];
        uint256 count = tc.sub(uc);
        require(count > 0, "Not enough count");

        usedCount[userID] = uc + count;

        uint256 ethAmount = count.mul(target).mul(unit).mul(5).div(1000);
        uint256 ekeyAmount = ISwapWrapper(main.swapWrapper()).getETHAmountOut(ethAmount);
        IERC20(main.eKey()).transfer(msg.sender, ekeyAmount);

        emit Withdraw(msg.sender, userID, ekeyAmount);
    }

    function addInviteeETH(uint256 _userID, uint256 _eth) external override onlyActivityEntrance {
        if (block.number >= endBlock) {
            return;
        }
        uint256 newETH = inviteeETH[_userID].add(_eth);
        inviteeETH[_userID] = newETH;
        emit AddInviteeETH(_userID, _eth);
    }

    function retrieveRemaining() public onlyOwner {
        require(block.number >= withdrawEndBlock, "Prohibit withdrawal");

        IERC20 eKey = IERC20(main.eKey());
        eKey.transfer(msg.sender, eKey.balanceOf(address(this)));
    }
}
