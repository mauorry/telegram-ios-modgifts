load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")

swift_library(
    name = "GiftNetworkTransfer",
    module_name = "GiftNetworkTransfer",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
    ],
    visibility = [
        "//visibility:public",
    ],
)

# Host (macOS) test: the codec needs nothing but Foundation.
# Run with `./build-input/bazel-9.2.0-darwin-arm64 test //submodules/GiftNetworkTransfer:GiftNetworkTransferTests`.
swift_test(
    name = "GiftNetworkTransferTests",
    srcs = [
        "Tests/GiftTransferCodecTests.swift",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        ":GiftNetworkTransfer",
    ],
)
