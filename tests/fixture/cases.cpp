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
