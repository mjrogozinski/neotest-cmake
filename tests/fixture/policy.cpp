#include <gtest/gtest.h>
#include <chrono>
#include <thread>
TEST(Policy, ExpectedFailure) { FAIL() << "expected failure"; }
TEST(Policy, Timeout) { std::this_thread::sleep_for(std::chrono::seconds(2)); }
TEST(Policy, SkipRule) { std::cout << "SKIP_POLICY\n"; }
