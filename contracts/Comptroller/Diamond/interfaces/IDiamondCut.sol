// SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.5.16;
pragma experimental ABIEncoderV2;

/*
有方法暴露这个路由表进行查看和管理。这个在Diamond的标准实现里是实现了一个DiamondCutFacet，这个合约会保存这个路由表，并由LibDiamond库实现了维护这张路由表的方法（增删改查）。
*/
interface IDiamondCut {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }
    // Add=0, Replace=1, Remove=2
    //每一面对应一组函数
    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    /// @notice Add/replace/remove any number of functions and optionally execute
    ///         a function with delegatecall
    /// @param _diamondCut Contains the facet addresses and function selectors
    function diamondCut(FacetCut[] calldata _diamondCut) external;
}
