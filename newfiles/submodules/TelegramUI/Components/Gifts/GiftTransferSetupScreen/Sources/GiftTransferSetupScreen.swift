import Foundation
import UIKit
import Display
import AsyncDisplayKit
import ComponentFlow
import ViewControllerComponent
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import GiftItemComponent
import GiftNetworkTransfer
import PlainButtonComponent
import MultilineTextComponent
import PromptUI

/// Screen for sending a mod-to-mod gift transfer to a chat peer.
///
/// Lists the account's OWN collectible gifts (the same real `StarGift.UniqueGift` records the
/// official client uses), because a transfer names the gift by its slug and the receiver resolves
/// that slug from Telegram's own `payments.getUniqueStarGift` — so both ends render the identical
/// gift. Tapping a gift selects it, an optional message is entered via a prompt, and "Send" hands
/// the encoded transfer to the completion, which enqueues it as a normal text message. The
/// outgoing local echo carries the synthetic `.starGiftUnique` action as media so the sender sees
/// the gift bubble immediately; the wire text keeps the hidden marker so the receiver's
/// `StoreMessage` hook reconstructs it on delivery.
public final class GiftTransferSetupScreen: ViewControllerComponentContainer {
    public struct Result {
        public let text: String
        public let media: TelegramMediaAction
    }

    public init(context: AccountContext, peerId: EnginePeer.Id, completion: @escaping (Result) -> Void) {
        let component = GiftTransferSetupScreenComponent(context: context)
        super.init(context: context, component: component, navigationBarAppearance: .transparent, theme: .default)

        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.navigationPresentation = .flatModal

        component.sendGift = { [weak self] uniqueGift, text in
            guard let self else {
                return
            }
            let transferId = Int64.random(in: Int64.min ... Int64.max)
            let payload = GiftTransferCodec.Payload(slug: uniqueGift.slug, text: text.isEmpty ? nil : text, nameHidden: false, transferId: transferId)
            guard let encoded = GiftTransferCodec.encode(payload) else {
                return
            }
            // The receiver resolves the slug itself; the sender already has the resolved gift, so
            // its own local echo can render at once. Warm the slug cache either way.
            context.engine.payments.warmGiftTransferSlug(slug: uniqueGift.slug)
            let action = GiftTransferResolver.makeAction(uniqueGift: uniqueGift, senderId: context.account.peerId, text: payload.text, nameHidden: false)
            // A gift message with no caption carries the official collectible link, so a stock
            // client still sees a tappable gift link instead of an empty message.
            let text = GiftTransferCodec.displayText(payload: payload, originalText: encoded)
            self.dismiss()
            completion(Result(text: text, media: action))
        }
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class GiftTransferSetupScreenComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    var sendGift: ((StarGift.UniqueGift, String) -> Void)?

    init(context: AccountContext) {
        self.context = context
    }

    static func ==(lhs: GiftTransferSetupScreenComponent, rhs: GiftTransferSetupScreenComponent) -> Bool {
        return lhs.context === rhs.context
    }

    final class State: ComponentState {
        let context: AccountContext
        /// The account's own collectible gifts, as slugs plus their resolved records.
        var gifts: [StarGift.UniqueGift] = []
        var selectedSlug: String?
        var isLoading = true
        private let giftsContext: ProfileGiftsContext
        private var disposable: Disposable?

        init(context: AccountContext) {
            self.context = context
            // The same context the official transfer flow uses: my own unique gifts, shown or hidden.
            self.giftsContext = ProfileGiftsContext(account: context.account, peerId: context.account.peerId, filter: [.unique, .displayed, .hidden])

            super.init()

            self.disposable = (self.giftsContext.state
            |> deliverOnMainQueue).start(next: { [weak self] state in
                guard let self else {
                    return
                }
                self.gifts = state.gifts.compactMap { entry in
                    if case let .unique(uniqueGift) = entry.gift {
                        return uniqueGift
                    }
                    return nil
                }
                self.isLoading = state.dataState == .loading
                self.updated()
            })
        }

        func select(slug: String) {
            if self.selectedSlug == slug {
                self.selectedSlug = nil
            } else {
                self.selectedSlug = slug
            }
            self.updated()
        }

        deinit {
            self.disposable?.dispose()
        }
    }

    func makeState() -> State {
        return State(context: self.context)
    }

    final class View: UIView {
        private let backgroundView: UIView
        private let titleView = ComponentView<Empty>()
        private var giftViews: [String: ComponentView<Empty>] = [:]
        private let sendButtonView = ComponentView<Empty>()
        private let hintView = ComponentView<Empty>()
        private let emptyView = ComponentView<Empty>()
        private var scrollView: UIScrollView?

        private var component: GiftTransferSetupScreenComponent?
        private weak var state: State?

        override init(frame: CGRect) {
            self.backgroundView = UIView()
            super.init(frame: frame)
            self.addSubview(self.backgroundView)
        }

        required init?(coder: NSCoder) {
            preconditionFailure()
        }

        func update(component: GiftTransferSetupScreenComponent, availableSize: CGSize, state: State, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
            self.component = component
            self.state = state

            let containerEnvironment = environment[ViewControllerComponentContainer.Environment.self].value
            let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }
            let theme = presentationData.theme
            let strings = presentationData.strings

            self.backgroundView.backgroundColor = theme.list.plainBackgroundColor

            let topInset = 12.0 + containerEnvironment.safeInsets.top

            let titleText = state.selectedSlug != nil ? strings.Gift_Transfer_SelectedTitle : strings.Gift_Transfer_PickTitle
            let titleSize = self.titleView.update(
                transition: transition,
                component: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: titleText, font: Font.bold(24.0), textColor: theme.list.itemPrimaryTextColor)))),
                environment: {},
                containerSize: CGSize(width: availableSize.width - 32.0, height: 60.0)
            )
            if let view = self.titleView.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: 16.0, y: topInset), size: titleSize))
            }

            let buttonHeight: CGFloat = 48.0
            let bottomButtonY = availableSize.height - containerEnvironment.safeInsets.bottom - 16.0 - buttonHeight

            let sendEnabled = state.selectedSlug != nil
            let sendSize = self.sendButtonView.update(
                transition: transition,
                component: AnyComponent(PlainButtonComponent(
                    content: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: strings.Gift_Transfer_Send, font: Font.semibold(17.0), textColor: sendEnabled ? UIColor.white : theme.list.itemSecondaryTextColor)))),
                    background: AnyComponent(Rectangle(color: sendEnabled ? theme.list.itemAccentColor : theme.list.itemDisabledTextColor)),
                    effectAlignment: .center,
                    contentInsets: UIEdgeInsets(top: 14.0, left: 0.0, bottom: 14.0, right: 0.0),
                    action: { [weak self] in
                        guard let self, let component = self.component, let state = self.state, let slug = state.selectedSlug, let gift = state.gifts.first(where: { $0.slug == slug }) else {
                            return
                        }
                        self.requestMessage(gift: gift, component: component, containerEnvironment: containerEnvironment, strings: strings)
                    },
                    isEnabled: sendEnabled
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - 32.0, height: buttonHeight)
            )
            if let view = self.sendButtonView.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: 16.0, y: bottomButtonY), size: sendSize))
                view.clipsToBounds = true
                view.layer.cornerRadius = 12.0
            }

            let hintSize = self.hintView.update(
                transition: transition,
                component: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: strings.Gift_Transfer_Hint, font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor)))),
                environment: {},
                containerSize: CGSize(width: availableSize.width - 32.0, height: 60.0)
            )
            if let view = self.hintView.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: 16.0, y: bottomButtonY - 10.0 - hintSize.height), size: hintSize))
            }

            let contentTop = topInset + titleSize.height + 16.0
            let listHeight = bottomButtonY - 10.0 - hintSize.height - 10.0 - contentTop
            let listFrame = CGRect(origin: CGPoint(x: 0.0, y: contentTop), size: CGSize(width: availableSize.width, height: max(0.0, listHeight)))

            let scrollView: UIScrollView
            if let current = self.scrollView {
                scrollView = current
            } else {
                scrollView = UIScrollView()
                scrollView.showsVerticalScrollIndicator = true
                scrollView.alwaysBounceVertical = true
                self.scrollView = scrollView
                self.addSubview(scrollView)
            }
            transition.setFrame(view: scrollView, frame: listFrame)

            // Empty / loading placeholder text.
            let placeholderText: String
            if state.isLoading && state.gifts.isEmpty {
                placeholderText = strings.Gift_Transfer_Loading
            } else if state.gifts.isEmpty {
                placeholderText = strings.Gift_Transfer_NoGifts
            } else {
                placeholderText = ""
            }
            if placeholderText.isEmpty {
                self.emptyView.view?.removeFromSuperview()
            } else {
                let emptySize = self.emptyView.update(
                    transition: transition,
                    component: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: placeholderText, font: Font.regular(15.0), textColor: theme.list.itemSecondaryTextColor)), horizontalAlignment: .center, maximumNumberOfLines: 0)),
                    environment: {},
                    containerSize: CGSize(width: availableSize.width - 64.0, height: 200.0)
                )
                if let view = self.emptyView.view {
                    if view.superview == nil {
                        scrollView.addSubview(view)
                    }
                    transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: 32.0, y: 40.0), size: emptySize))
                }
            }

            let columnCount = 2
            let sideInset: CGFloat = 16.0
            let spacing: CGFloat = 12.0
            let itemWidth = floorToScreenPixels((availableSize.width - sideInset * 2.0 - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
            // GiftItemComponent in .grid mode returns a square size.
            let itemHeight = itemWidth

            var validSlugs = Set<String>()
            for (index, gift) in state.gifts.enumerated() {
                validSlugs.insert(gift.slug)
                let column = index % columnCount
                let row = index / columnCount
                let frame = CGRect(
                    origin: CGPoint(x: sideInset + CGFloat(column) * (itemWidth + spacing), y: CGFloat(row) * (itemHeight + spacing)),
                    size: CGSize(width: itemWidth, height: itemHeight)
                )

                let itemView: ComponentView<Empty>
                if let current = self.giftViews[gift.slug] {
                    itemView = current
                } else {
                    itemView = ComponentView()
                    self.giftViews[gift.slug] = itemView
                }
                let isSelected = gift.slug == state.selectedSlug
                let _ = itemView.update(
                    transition: transition,
                    component: AnyComponent(PlainButtonComponent(
                        content: AnyComponent(GiftItemComponent(
                            context: component.context,
                            style: .glass,
                            theme: theme,
                            strings: strings,
                            peer: nil,
                            subject: .uniqueGift(gift: gift, price: nil),
                            isSelected: isSelected,
                            mode: .grid,
                            action: {}
                        )),
                        effectAlignment: .center,
                        action: { [weak state] in
                            state?.select(slug: gift.slug)
                        }
                    )),
                    environment: {},
                    containerSize: frame.size
                )
                if let view = itemView.view {
                    if view.superview == nil {
                        scrollView.addSubview(view)
                    }
                    transition.setFrame(view: view, frame: frame)
                }
            }
            var removedSlugs: [String] = []
            for (slug, itemView) in self.giftViews where !validSlugs.contains(slug) {
                itemView.view?.removeFromSuperview()
                removedSlugs.append(slug)
            }
            for slug in removedSlugs {
                self.giftViews.removeValue(forKey: slug)
            }
            let rowCount = (state.gifts.count + columnCount - 1) / columnCount
            scrollView.contentSize = CGSize(width: availableSize.width, height: max(0.0, CGFloat(rowCount) * (itemHeight + spacing) + 16.0))

            return availableSize
        }

        private func requestMessage(gift: StarGift.UniqueGift, component: GiftTransferSetupScreenComponent, containerEnvironment: ViewControllerComponentContainer.Environment, strings: PresentationStrings) {
            guard let controller = containerEnvironment.controller() as? GiftTransferSetupScreen else {
                return
            }
            let sendGift = component.sendGift
            let messagePrompt = promptController(
                context: component.context,
                text: strings.Gift_Transfer_EnterMessage,
                value: "",
                placeholder: strings.Gift_Transfer_MessagePlaceholder,
                characterLimit: 200,
                apply: { text in
                    sendGift?(gift, text ?? "")
                }
            )
            controller.push(messagePrompt)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: State, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
