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
import GiftNetworkTransfer
import GiftItemComponent
import PlainButtonComponent
import MultilineTextComponent
import PromptUI

/// The mod's visual-appearance menu, opened by triple-tapping the chats tab.
///
/// Three sections (mirroring DuckGram's hidden editor, serverless):
/// - **Visual gifts**: paste collectible slugs or `t.me/nft/...` links (one per line, up to
///   100). Each is validated, resolved through Telegram's own `getUniqueStarGift`, and added
///   to the visual profile. No ownership required — the point is the visual.
/// - **Visual number**: a fake phone number shown in your profile instead of the real one
///   (e.g. `8881234567` renders as an anonymous +888 number).
/// - **Publish**: writes the appearance into the bio marker so every mod user viewing the
///   profile sees it. The bio keeps your own text; the marker rides at the end.
public final class ModAppearanceMenuScreen: ViewControllerComponentContainer {
    public init(context: AccountContext) {
        let component = ModAppearanceMenuComponent(context: context)
        super.init(context: context, component: component, navigationBarAppearance: .transparent, theme: .default)

        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.navigationPresentation = .flatModal
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ModAppearanceMenuComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext

    init(context: AccountContext) {
        self.context = context
    }

    static func ==(lhs: ModAppearanceMenuComponent, rhs: ModAppearanceMenuComponent) -> Bool {
        return lhs.context === rhs.context
    }

    final class State: ComponentState {
        let context: AccountContext
        var appearance = ModAppearanceCodec.Appearance(phone: nil, slugs: [])
        var resolvedGifts: [StarGift.UniqueGift] = []
        var isPublishing = false
        var lastPublishedAt: Int32?
        private var disposable: Disposable?

        init(context: AccountContext) {
            self.context = context

            super.init()

            // Load the locally stored appearance and resolve its slugs for the preview list.
            let engine = context.engine
            self.disposable = (engine.payments.readModAppearance()
            |> deliverOnMainQueue).start(next: { [weak self] appearance in
                guard let self else {
                    return
                }
                self.appearance = appearance
                self.updated()
                self.refreshResolved()
            })
        }

        func refreshResolved() {
            let engine = self.context.engine
            let appearance = self.appearance
            self.disposable = (engine.payments.resolveModAppearance(appearance)
            |> deliverOnMainQueue).start(next: { [weak self] gifts in
                guard let self else {
                    return
                }
                self.resolvedGifts = gifts
                self.updated()
            })
        }

        func addSlugs(_ raw: String) {
            // Accept slugs and t.me/nft/... links, one per line or comma/space separated.
            var parsed: [String] = []
            for token in raw.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " }) {
                var slug = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
                if slug.hasPrefix("t.me/nft/") {
                    slug = String(slug.dropFirst("t.me/nft/".count))
                } else if slug.hasPrefix("https://t.me/nft/") {
                    slug = String(slug.dropFirst("https://t.me/nft/".count))
                }
                if ModAppearanceCodec.isWellFormedSlug(slug), !self.appearance.slugs.contains(slug) {
                    parsed.append(slug)
                }
            }
            guard !parsed.isEmpty else {
                return
            }
            self.appearance.slugs.append(contentsOf: parsed)
            self.updated()
            self.refreshResolved()
        }

        func removeSlug(_ slug: String) {
            self.appearance.slugs.removeAll { $0 == slug }
            self.resolvedGifts.removeAll { $0.slug == slug }
            self.updated()
        }

        func setPhone(_ phone: String?) {
            let digits = phone?.filter { $0.isNumber }
            self.appearance = ModAppearanceCodec.Appearance(phone: digits?.isEmpty == true ? nil : digits, slugs: self.appearance.slugs)
            self.updated()
        }

        func publish() {
            guard !self.isPublishing else {
                return
            }
            self.isPublishing = true
            self.updated()
            let appearance = self.appearance
            self.disposable = (self.context.engine.payments.publishModAppearance(appearance)
            |> deliverOnMainQueue).start(completed: { [weak self] in
                guard let self else {
                    return
                }
                self.isPublishing = false
                self.lastPublishedAt = Int32(Date().timeIntervalSince1970)
                self.updated()
            })
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
        private let phoneRowView = ComponentView<Empty>()
        private let addGiftsRowView = ComponentView<Empty>()
        private let publishRowView = ComponentView<Empty>()
        private var giftViews: [String: ComponentView<Empty>] = [:]
        private let statusView = ComponentView<Empty>()
        private var scrollView: UIScrollView?

        private var component: ModAppearanceMenuComponent?
        private weak var state: State?

        override init(frame: CGRect) {
            self.backgroundView = UIView()
            super.init(frame: frame)
            self.addSubview(self.backgroundView)
        }

        required init?(coder: NSCoder) {
            preconditionFailure()
        }

        func update(component: ModAppearanceMenuComponent, availableSize: CGSize, state: State, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
            self.component = component
            self.state = state

            let containerEnvironment = environment[ViewControllerComponentContainer.Environment.self].value
            let presentationData = component.context.sharedContext.currentPresentationData.with { $0 }
            let theme = presentationData.theme
            let strings = presentationData.strings

            self.backgroundView.backgroundColor = theme.list.plainBackgroundColor

            let topInset = 12.0 + containerEnvironment.safeInsets.top

            let titleSize = self.titleView.update(
                transition: transition,
                component: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: strings.Mod_Appearance_Title, font: Font.bold(24.0), textColor: theme.list.itemPrimaryTextColor)))),
                environment: {},
                containerSize: CGSize(width: availableSize.width - 32.0, height: 60.0)
            )
            if let view = self.titleView.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: 16.0, y: topInset), size: titleSize))
            }

            let rowHeight: CGFloat = 48.0
            let buttonBottomY = availableSize.height - containerEnvironment.safeInsets.bottom - 16.0 - rowHeight

            // Publish button (bottom).
            let publishTitle = state.isPublishing ? strings.Mod_Appearance_Publishing : strings.Mod_Appearance_Publish
            let publishSize = self.publishRowView.update(
                transition: transition,
                component: AnyComponent(PlainButtonComponent(
                    content: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: publishTitle, font: Font.semibold(17.0), textColor: UIColor.white)))),
                    background: AnyComponent(Rectangle(color: theme.list.itemAccentColor)),
                    effectAlignment: .center,
                    contentInsets: UIEdgeInsets(top: 14.0, left: 0.0, bottom: 14.0, right: 0.0),
                    action: { [weak state] in
                        state?.publish()
                    },
                    isEnabled: !state.isPublishing
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - 32.0, height: rowHeight)
            )
            if let view = self.publishRowView.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: 16.0, y: buttonBottomY), size: publishSize))
                view.clipsToBounds = true
                view.layer.cornerRadius = 12.0
            }

            // Status line above publish.
            let statusText: String
            if state.lastPublishedAt != nil {
                statusText = strings.Mod_Appearance_Published
            } else {
                statusText = strings.Mod_Appearance_Hint
            }
            let statusSize = self.statusView.update(
                transition: transition,
                component: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: statusText, font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor)), maximumNumberOfLines: 0)),
                environment: {},
                containerSize: CGSize(width: availableSize.width - 32.0, height: 60.0)
            )
            if let view = self.statusView.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: 16.0, y: buttonBottomY - 10.0 - statusSize.height), size: statusSize))
            }

            // Visual number row.
            let phoneDisplay = state.appearance.phone ?? ""
            let phoneTitle = phoneDisplay.isEmpty ? strings.Mod_Appearance_SetNumber : "+\(phoneDisplay)"
            let phoneSize = self.phoneRowView.update(
                transition: transition,
                component: AnyComponent(PlainButtonComponent(
                    content: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: strings.Mod_Appearance_NumberRow(phoneTitle).string, font: Font.regular(17.0), textColor: theme.list.itemPrimaryTextColor)))),
                    background: AnyComponent(Rectangle(color: theme.list.itemBlocksBackgroundColor)),
                    effectAlignment: .center,
                    contentInsets: UIEdgeInsets(top: 12.0, left: 16.0, bottom: 12.0, right: 16.0),
                    action: { [weak self] in
                        guard let controller = containerEnvironment.controller() else {
                            return
                        }
                        self?.requestPhone(strings: strings, controller: controller)
                    }
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - 32.0, height: rowHeight)
            )
            if let view = self.phoneRowView.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: 16.0, y: topInset + titleSize.height + 16.0), size: phoneSize))
                view.clipsToBounds = true
                view.layer.cornerRadius = 12.0
            }

            // Add-gifts row.
            let addY = topInset + titleSize.height + 16.0 + phoneSize.height + 8.0
            let addSize = self.addGiftsRowView.update(
                transition: transition,
                component: AnyComponent(PlainButtonComponent(
                    content: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: strings.Mod_Appearance_AddGifts, font: Font.regular(17.0), textColor: theme.list.itemAccentColor)))),
                    background: AnyComponent(Rectangle(color: theme.list.itemBlocksBackgroundColor)),
                    effectAlignment: .center,
                    contentInsets: UIEdgeInsets(top: 12.0, left: 16.0, bottom: 12.0, right: 16.0),
                    action: { [weak self] in
                        guard let controller = containerEnvironment.controller() else {
                            return
                        }
                        self?.requestSlugs(strings: strings, controller: controller)
                    }
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - 32.0, height: rowHeight)
            )
            if let view = self.addGiftsRowView.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: 16.0, y: addY), size: addSize))
                view.clipsToBounds = true
                view.layer.cornerRadius = 12.0
            }

            // Resolved gifts list (scrollable).
            let listTop = addY + addSize.height + 8.0
            let listHeight = max(0.0, buttonBottomY - 10.0 - statusSize.height - 10.0 - listTop)
            let listFrame = CGRect(origin: CGPoint(x: 0.0, y: listTop), size: CGSize(width: availableSize.width, height: listHeight))

            let scrollView: UIScrollView
            if let current = self.scrollView {
                scrollView = current
            } else {
                scrollView = UIScrollView()
                scrollView.showsVerticalScrollIndicator = true
                self.scrollView = scrollView
                self.addSubview(scrollView)
            }
            transition.setFrame(view: scrollView, frame: listFrame)

            let columnCount = 3
            let sideInset: CGFloat = 16.0
            let spacing: CGFloat = 10.0
            let itemWidth = floorToScreenPixels((availableSize.width - sideInset * 2.0 - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
            let itemHeight = itemWidth

            var validSlugs = Set<String>()
            for (index, gift) in state.resolvedGifts.enumerated() {
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
                            mode: .thumbnail,
                            action: {}
                        )),
                        effectAlignment: .center,
                        action: { [weak state] in
                            state?.removeSlug(gift.slug)
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
            let rowCount = (state.resolvedGifts.count + columnCount - 1) / columnCount
            scrollView.contentSize = CGSize(width: availableSize.width, height: max(0.0, CGFloat(rowCount) * (itemHeight + spacing) + 16.0))

            return availableSize
        }

        private func requestPhone(strings: PresentationStrings, controller: ViewController) {
            guard let component = self.component, let state = self.state else {
                return
            }
            let prompt = promptController(
                context: component.context,
                text: strings.Mod_Appearance_EnterNumber,
                value: state.appearance.phone ?? "",
                placeholder: "8881234567",
                characterLimit: 16,
                apply: { [weak state] value in
                    state?.setPhone(value)
                }
            )
            controller.present(prompt, in: .current)
        }

        private func requestSlugs(strings: PresentationStrings, controller: ViewController) {
            guard let component = self.component, let state = self.state else {
                return
            }
            let prompt = promptController(
                context: component.context,
                text: strings.Mod_Appearance_EnterSlugs,
                value: "",
                placeholder: "PlushPepe-1",
                characterLimit: 4000,
                apply: { [weak state] value in
                    state?.addSlugs(value ?? "")
                }
            )
            controller.present(prompt, in: .current)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: State, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
