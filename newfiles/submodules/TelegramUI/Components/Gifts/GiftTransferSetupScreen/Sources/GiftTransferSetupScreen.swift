import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
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
/// Shows the cached star-gift catalog as a list; tapping a gift selects it, the collectible
/// number and the accompanying message are entered via prompts, and "Send" encodes the transfer
/// with `GiftTransferCodec` into the message text and hands it to the completion, which enqueues
/// it as a normal text message. The outgoing local echo carries the synthetic `.starGiftUnique`
/// action as media so the sender sees the gift bubble immediately; the wire text keeps the hidden
/// marker so the receiver's `StoreMessage` hook reconstructs it on delivery.
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

        component.sendGift = { [weak self] gift, number, text in
            guard let self else {
                return
            }
            let transferId = Int64.random(in: Int64.min ... Int64.max)
            let payload = GiftTransferCodec.Payload(giftId: gift.id, number: number, text: text.isEmpty ? nil : text, nameHidden: false, transferId: transferId)
            guard let encoded = GiftTransferCodec.encode(payload) else {
                return
            }
            let uniqueGift = GiftTransferResolver.makeUniqueGift(gift: gift, number: number, transferId: transferId, senderPeerId: context.account.peerId, recipientPeerId: peerId, date: Int32(Date().timeIntervalSince1970), text: payload.text)
            let action = GiftTransferResolver.makeAction(uniqueGift: uniqueGift, senderId: context.account.peerId, text: payload.text, nameHidden: false)
            self.dismiss()
            completion(Result(text: encoded, media: action))
        }
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class GiftTransferSetupScreenComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    var sendGift: ((StarGift.Gift, Int32, String) -> Void)?

    init(context: AccountContext) {
        self.context = context
    }

    static func ==(lhs: GiftTransferSetupScreenComponent, rhs: GiftTransferSetupScreenComponent) -> Bool {
        return lhs.context === rhs.context
    }

    final class State: ComponentState {
        let context: AccountContext
        var gifts: [StarGift.Gift] = []
        var selectedId: Int64?
        private var disposable: Disposable?

        init(context: AccountContext) {
            self.context = context

            super.init()

            self.disposable = (context.engine.payments.cachedStarGifts()
            |> deliverOnMainQueue).start(next: { [weak self] gifts in
                guard let self else {
                    return
                }
                self.gifts = (gifts ?? []).compactMap { gift in
                    if case let .generic(generic) = gift {
                        return generic
                    }
                    return nil
                }
                self.updated()
            })
        }

        func select(giftId: Int64) {
            if self.selectedId == giftId {
                self.selectedId = nil
            } else {
                self.selectedId = giftId
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
        private var giftViews: [Int64: ComponentView<Empty>] = [:]
        private let sendButtonView = ComponentView<Empty>()
        private let hintView = ComponentView<Empty>()
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

            let titleText = state.selectedId != nil ? strings.Gift_Transfer_SelectedTitle : strings.Gift_Transfer_PickTitle
            let titleSize = self.titleView.update(
                transition: .immediate,
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

            let sendEnabled = state.selectedId != nil
            let sendSize = self.sendButtonView.update(
                transition: .immediate,
                component: AnyComponent(PlainButtonComponent(
                    content: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: strings.Gift_Transfer_Send, font: Font.semibold(17.0), textColor: sendEnabled ? UIColor.white : theme.list.itemSecondaryTextColor)))),
                    background: AnyComponent(Rectangle(color: sendEnabled ? theme.list.itemAccentColor : theme.list.itemDisabledTextColor)),
                    effectAlignment: .center,
                    contentInsets: UIEdgeInsets(top: 14.0, left: 0.0, bottom: 14.0, right: 0.0),
                    action: { [weak self] in
                        guard let self, let component = self.component, let state = self.state, let selectedId = state.selectedId, let gift = state.gifts.first(where: { $0.id == selectedId }) else {
                            return
                        }
                        self.requestNumber(gift: gift, component: component, state: state, containerEnvironment: containerEnvironment, strings: strings)
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
                transition: .immediate,
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

            // Gifts list: two columns of GiftItemComponent inside a scroll view.
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
                self.insertSubview(scrollView, belowSubview: self.titleView.view ?? self)
            }
            transition.setFrame(view: scrollView, frame: listFrame)

            let columnCount = 2
            let sideInset: CGFloat = 16.0
            let spacing: CGFloat = 12.0
            let itemWidth = floorToScreenPixels((availableSize.width - sideInset * 2.0 - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
            let itemHeight = itemWidth

            var validIds = Set<Int64>()
            var y: CGFloat = 0.0
            for gift in state.gifts {
                validIds.insert(gift.id)
                let index = state.gifts.firstIndex(where: { $0.id == gift.id }) ?? 0
                let column = index % columnCount
                let row = index / columnCount
                let origin = CGPoint(x: sideInset + CGFloat(column) * (itemWidth + spacing), y: CGFloat(row) * (itemHeight + spacing))
                let frame = CGRect(origin: origin, size: CGSize(width: itemWidth, height: itemHeight))

                let itemView: ComponentView<Empty>
                if let current = self.giftViews[gift.id] {
                    itemView = current
                } else {
                    itemView = ComponentView()
                    self.giftViews[gift.id] = itemView
                }
                let isSelected = gift.id == state.selectedId
                let _ = itemView.update(
                    transition: .immediate,
                    component: AnyComponent(PlainButtonComponent(
                        content: AnyComponent(GiftItemComponent(
                            context: component.context,
                            style: .glass,
                            theme: theme,
                            strings: strings,
                            peer: nil,
                            subject: .starGift(gift: gift, price: ""),
                            isSelected: isSelected,
                            mode: .grid,
                            action: {}
                        )),
                        effectAlignment: .center,
                        action: { [weak state] in
                            state?.select(giftId: gift.id)
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
                y = max(y, frame.maxY)
            }
            var removedIds: [Int64] = []
            for (id, itemView) in self.giftViews {
                if !validIds.contains(id) {
                    itemView.view?.removeFromSuperview()
                    removedIds.append(id)
                }
            }
            for id in removedIds {
                self.giftViews.removeValue(forKey: id)
            }
            scrollView.contentSize = CGSize(width: availableSize.width, height: y + 16.0)

            return availableSize
        }

        private func requestNumber(gift: StarGift.Gift, component: GiftTransferSetupScreenComponent, state: State, containerEnvironment: ViewControllerComponentContainer.Environment, strings: PresentationStrings) {
            guard let controller = containerEnvironment.controller() as? GiftTransferSetupScreen else {
                return
            }
            let context = component.context
            let sendGift = component.sendGift
            let numberPrompt = promptController(
                context: context,
                text: strings.Gift_Transfer_EnterNumber,
                value: "1",
                placeholder: "1234",
                characterLimit: 9,
                apply: { value in
                    let digits = (value ?? "").filter { $0.isNumber }
                    let number = max(1, min(Int32(digits) ?? 1, 999_999_999))
                    let textPrompt = promptController(
                        context: context,
                        text: strings.Gift_Transfer_EnterMessage,
                        value: "",
                        placeholder: strings.Gift_Transfer_MessagePlaceholder,
                        characterLimit: 200,
                        apply: { text in
                            sendGift?(gift, number, text ?? "")
                        }
                    )
                    controller.push(textPrompt)
                }
            )
            controller.push(numberPrompt)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: State, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
