#include <gtest/gtest.h>
#include <iostream>
#include <string>

class VerboseValues : public testing::TestWithParam<int> {};
TEST_P(VerboseValues, Pass) {
    std::cout << std::string(2048, 'x') << '\n';
    EXPECT_GT(GetParam(), 0);
}
INSTANTIATE_TEST_SUITE_P(Numbers, VerboseValues, testing::Values(1, 2));
TEST(VerboseFailure, Fail) {
    std::cout << std::string(350000, 'x') << '\n';
    FAIL() << "intentional failure after a large log";
}
TEST(VerboseFailure, PassAfterFailure) { SUCCEED(); }
