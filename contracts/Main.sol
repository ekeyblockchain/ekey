// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "./interfaces/ISwapWrapper.sol";
import "./interfaces/IPool.sol";

contract Main is Ownable, ReentrancyGuard, Pausable {
    using Math for uint256;
    using SafeMath for uint256;

    bool public initialized;

    struct User {
        address addr;
        uint256 userID;
        uint256 groupID;
        uint256 inviter;
        uint256[] invitees;
    }

    uint256 public nextGroupID = 1;
    mapping(uint256 => User) public users;
    uint256[] groupLeader;

    uint256 public nextUserID = 1;
    mapping(address => uint256) public userIDs;

    address payable public officialAddr;
    address payable public projectAddr;

    address public box;
    address public boxRanking;
    IERC20 public eKey;
    address public pool;
    address public puzzle;
    address public puzzleData;
    address public puzzlePiece;
    address public puzzlePieceFactory;
    ISwapWrapper public swapWrapper;
    address public activityEntrance;

    event Register(address indexed self, uint256 inviter, uint256 userID, uint256 groupID);

    modifier onlyPool() {
        require(pool == _msgSender(), "Caller is not the pool");
        _;
    }

    modifier onlyBox() {
        require(box == _msgSender(), "Caller is not the box");
        _;
    }

    constructor() {
        initialized = false;
        // just funny
        uint256 seed = uint256(blockhash(block.number - 1));
        nextGroupID = uint8(seed);
        nextUserID = uint16(seed);
    }

    function init(
        address payable _officialAddr,
        address payable _projectAddr,
        address _box,
        address _boxRanking,
        address _eKey,
        address _pool,
        address _puzzle,
        address _puzzleData,
        address _puzzlePiece,
        address _puzzlePieceFactory,
        address _swapWrapper,
        address _activityEntrance
    ) public onlyOwner {
        require(!initialized, "Already initialized");

        officialAddr = _officialAddr;
        projectAddr = _projectAddr;

        box = _box;
        boxRanking = _boxRanking;
        eKey = IERC20(_eKey);
        pool = _pool;
        puzzle = _puzzle;
        puzzleData = _puzzleData;
        puzzlePiece = _puzzlePiece;
        puzzlePieceFactory = _puzzlePieceFactory;
        swapWrapper = ISwapWrapper(_swapWrapper);
        activityEntrance = _activityEntrance;

        initialized = true;
    }

    function setOfficialAddr(address payable _officialAddr) public onlyOwner {
        officialAddr = _officialAddr;
    }

    function setProjectAddr(address payable _projectAddr) public onlyOwner {
        projectAddr = _projectAddr;
    }

    function setPuzzlePieceFactory(address _puzzlePieceFactory) public onlyOwner {
        puzzlePieceFactory = _puzzlePieceFactory;
    }

    function setSwapWrapper(address _swapWrapper) public onlyOwner {
        swapWrapper = ISwapWrapper(_swapWrapper);
    }

    function pause(bool p) public onlyOwner returns (bool) {
        if (p) {
            _pause();
        } else {
            _unpause();
        }
        return true;
    }

    function getUserInfo(address _user)
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        User storage user = users[userIDs[_user]];
        return (user.userID, user.groupID, user.inviter, user.invitees.length);
    }

    function register(uint256 _inviter) public nonReentrant whenNotPaused returns (bool) {
        require(userIDs[msg.sender] == 0, "already registered");

        if (_inviter != 0) {
            require(users[_inviter].userID != 0, "invalid inviter");

            User storage inviter = users[_inviter];

            inviter.invitees.push(nextUserID);
            users[nextUserID] = User({
                addr: msg.sender,
                userID: nextUserID,
                groupID: inviter.groupID,
                inviter: inviter.userID,
                invitees: new uint256[](0)
            });

            emit Register(msg.sender, _inviter, nextUserID, nextGroupID);
        } else {
            groupLeader.push(nextUserID);

            users[nextUserID] = User({
                addr: msg.sender,
                userID: nextUserID,
                groupID: nextGroupID,
                inviter: 0,
                invitees: new uint256[](0)
            });

            emit Register(msg.sender, _inviter, nextUserID, nextGroupID);

            nextGroupID++;
        }

        userIDs[msg.sender] = nextUserID;
        nextUserID++;
        return true;
    }

    function getUser(address _user) external view returns (uint256, uint256) {
        uint256 userID = userIDs[_user];
        return (users[userID].groupID, userID);
    }

    function getUserGroupID(uint256 _user) external view returns (uint256) {
        return users[_user].groupID;
    }

    function getInviter(uint256 _user) external view returns (uint256) {
        return users[_user].inviter;
    }

    function getInviterAddr(uint256 _user) external view returns (address) {
        return users[users[_user].inviter].addr;
    }

    function registered(address _user) external view returns (bool) {
        return userIDs[_user] > 0;
    }

    function getInvitees(
        uint256 _userID,
        uint256 _offset,
        uint256 _size
    ) external view returns (uint256[] memory) {
        uint256[] storage invitees = users[_userID].invitees;
        uint256 size = _size.min(invitees.length.sub(_offset));
        uint256[] memory results = new uint256[](size);
        for (uint256 i = 0; i < size; i++) {
            results[i] = invitees[i + _offset];
        }
        return results;
    }
}
