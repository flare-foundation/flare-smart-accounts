// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract SimpleExample {
    mapping(uint256 => uint256) public map;
    uint256[] public allKeys;
    bool public flag;

    function addValue(uint256 _a) public payable {
        require(_a > 0, "a must be greater than 0");
        require(msg.value > 0, "msg.value must be greater than 0");
        if (map[_a] == 0) {
            allKeys.push(_a);
        }
        map[_a] = map[_a] + msg.value;
    }

    function setFlag(bool _set) public {
        flag = _set;
    }

    function getAllKeys() public view returns (uint256[] memory) {
        return allKeys;
    }
}
