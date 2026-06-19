// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

// abstract vs 普通 contract:
//   - abstract: 不能 new / 不能单独部署,只能被继承;可以含未实现函数(只有签名没函数体)
//   - 普通 contract: 可部署;一旦有任何未实现函数就必须标 abstract
//   - 两者都可有状态变量、构造函数、已实现函数
//   - 注意: Base 的函数全部实现了,本可不标 abstract;标 abstract 是为了表达
//     "这是基类,只配被继承,别直接部署"
abstract contract Base {
    function _call() internal pure returns (uint256) {
        return 3;
    }
}

contract Base2 {
    function _call2() internal pure returns (uint256) {
        return 4;
    }
}

contract Higher is Base, Base2 {
    // 继承来的函数可直接用函数名调用,无需 super:
    //   - 直接调 _call()      -> 沿继承链解析到的最终实现(未 override 时就是父类的)
    //   - super._call()       -> 仅当本合约 override 了该函数,又想调上一层的版本时才用
    //   - Base._call()        -> 多重继承下指定具体某个父合约以消歧
    function mycall() public pure returns (uint256) {
        return _call() + _call2();
    }
}
