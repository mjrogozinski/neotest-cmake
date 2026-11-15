#include <gtest/gtest.h>
// TEST(Fake, Comment) {}
const char* fake = "TEST(Fake, String) {}";
TEST(Basic, Pass) { EXPECT_EQ(4, 2 + 2); }
TEST(Basic, Fail) { EXPECT_EQ(5, 2 + 2); }
TEST(Basic, Skip) { GTEST_SKIP(); }
TEST(Basic, DISABLED_Off) { FAIL(); }
class Values : public testing::TestWithParam<int> {};
TEST_P(Values, Positive) { EXPECT_GT(GetParam(), 0); }
INSTANTIATE_TEST_SUITE_P(Numbers, Values, testing::Values(1, 2));
template <typename T> class Typed : public testing::Test {};
using Types = testing::Types<int, long>;
TYPED_TEST_SUITE(Typed, Types);
TYPED_TEST(Typed, Size) { EXPECT_GT(sizeof(TypeParam), 0); }
INSTANTIATE_TEST_SUITE_P(Named, Values, testing::Values(3),
    [](const testing::TestParamInfo<int>&) { return "Three"; });
template <typename T> class TypeParameters : public testing::Test {};
TYPED_TEST_SUITE_P(TypeParameters);
TYPED_TEST_P(TypeParameters, Size) { EXPECT_GT(sizeof(TypeParam), 0); }
REGISTER_TYPED_TEST_SUITE_P(TypeParameters, Size);
INSTANTIATE_TYPED_TEST_SUITE_P(Instances, TypeParameters, Types);

TEST_P(Values, Mixed) {
    if (GetParam() == 2) GTEST_SKIP();
    EXPECT_NE(GetParam(), 3) << "intentional parameter failure";
}

INSTANTIATE_TEST_SUITE_P(, Values, testing::Values(4));
