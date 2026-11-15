#include <gtest/gtest.h>
TEST(Direct, Pass) { SUCCEED(); }
TEST(Direct, Fail) { FAIL() << "intentional direct failure"; }
TEST(Direct, Skip) { GTEST_SKIP(); }
TEST(Direct, DISABLED_Off) { FAIL(); }
class DirectValues : public testing::TestWithParam<int> {};
TEST_P(DirectValues, Positive) { EXPECT_GT(GetParam(), 0); }
INSTANTIATE_TEST_SUITE_P(Numbers, DirectValues, testing::Values(1, 2));
template <typename T> class DirectTyped : public testing::Test {};
using DirectTypes = testing::Types<int, long>;
TYPED_TEST_SUITE(DirectTyped, DirectTypes);
TYPED_TEST(DirectTyped, Size) { EXPECT_GT(sizeof(TypeParam), 0); }
