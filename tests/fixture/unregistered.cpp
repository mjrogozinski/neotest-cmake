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
INSTANTIATE_TEST_SUITE_P(Named, DirectValues, testing::Values(3),
    [](const testing::TestParamInfo<int>&) { return "Three"; });
template <typename T> class DirectTypeParameters : public testing::Test {};
TYPED_TEST_SUITE_P(DirectTypeParameters);
TYPED_TEST_P(DirectTypeParameters, Size) { EXPECT_GT(sizeof(TypeParam), 0); }
REGISTER_TYPED_TEST_SUITE_P(DirectTypeParameters, Size);
INSTANTIATE_TYPED_TEST_SUITE_P(Instances, DirectTypeParameters, DirectTypes);

TEST_P(DirectValues, Mixed) {
    if (GetParam() == 2) GTEST_SKIP();
    EXPECT_NE(GetParam(), 3) << "intentional parameter failure";
}

INSTANTIATE_TEST_SUITE_P(, DirectValues, testing::Values(4));
