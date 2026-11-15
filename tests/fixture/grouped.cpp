#include <gtest/gtest.h>
#include <cstdlib>
#include <fstream>
TEST(Group, Environment) {
  ASSERT_NE(nullptr, std::getenv("ADAPTER_ENV"));
  EXPECT_STREQ("present", std::getenv("ADAPTER_ENV"));
  EXPECT_TRUE(std::ifstream("prepared").good());
}
TEST(Group, Failure) { FAIL() << "intentional"; }
