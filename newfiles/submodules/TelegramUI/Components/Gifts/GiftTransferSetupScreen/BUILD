load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "GiftTransferSetupScreen",
    module_name = "GiftTransferSetupScreen",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/AsyncDisplayKit",
        "//submodules/ComponentFlow",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/AccountContext",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/GiftNetworkTransfer",
        "//submodules/Components/ViewControllerComponent",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/TelegramUI/Components/PlainButtonComponent",
        "//submodules/TelegramUI/Components/Gifts/GiftItemComponent",
        "//submodules/PromptUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
