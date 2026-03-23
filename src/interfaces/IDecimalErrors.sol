// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDecimalErrors
/// @notice Custom errors for the Decimal library
interface IDecimalErrors {
    error Decimal__DivisionByZero();
    error Decimal__InvalidMantissa(uint256 mantissa);
    error Decimal__ExponentOverflow(int64 exponent);
    error Decimal__NegativeLog();
    error Decimal__NegativeSqrt();
    error Decimal__InvalidInput();
}
