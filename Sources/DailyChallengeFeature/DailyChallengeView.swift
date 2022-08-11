import ClientModels
import ComposableArchitecture
import ComposableUserNotifications
import DailyChallengeHelpers
import DateHelpers
import NotificationsAuthAlert
import Overture
import SharedModels
import Styleguide
import SwiftUI

public struct DailyChallengeReducer: ReducerProtocol {
  public struct State: Equatable {
    public var dailyChallenges: [FetchTodaysDailyChallengeResponse]
    @PresentationStateOf<Destinations> public var destination
    public var gameModeIsLoading: GameMode?
    public var inProgressDailyChallengeUnlimited: InProgressGame?
    public var userNotificationSettings: UserNotificationClient.Notification.Settings?

    public init(
      dailyChallenges: [FetchTodaysDailyChallengeResponse] = [],
      destination: Destinations.State? = nil,
      gameModeIsLoading: GameMode? = nil,
      inProgressDailyChallengeUnlimited: InProgressGame? = nil,
      userNotificationSettings: UserNotificationClient.Notification.Settings? = nil
    ) {
      self.dailyChallenges = dailyChallenges
      self.destination = destination
      self.gameModeIsLoading = gameModeIsLoading
      self.inProgressDailyChallengeUnlimited = inProgressDailyChallengeUnlimited
      self.userNotificationSettings = userNotificationSettings
    }
  }

  public enum Action: Equatable {
    case delegate(DelegateAction)
    case destination(PresentationActionOf<Destinations>)
    case fetchTodaysDailyChallengeResponse(TaskResult<[FetchTodaysDailyChallengeResponse]>)
    case gameButtonTapped(GameMode)
    case startDailyChallengeResponse(TaskResult<InProgressGame>)
    case task
    case userNotificationSettingsResponse(UserNotificationClient.Notification.Settings)
  }

  public enum DelegateAction: Equatable {
    case startGame(InProgressGame)
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.fileClient) var fileClient
  @Dependency(\.mainRunLoop) var mainRunLoop
  @Dependency(\.userNotifications) var userNotifications

  public init() {}

  public var body: some ReducerProtocol<State, Action> {
    Reduce { state, action in
      switch action {
      case .delegate:
        return .none

      case let .destination(
        .presented(.notificationsAuthAlert(.delegate(.didChooseNotificationSettings(settings))))):
        state.userNotificationSettings = settings
        return .none

      case .destination:
        return .none

      case .fetchTodaysDailyChallengeResponse(.failure):
        return .none

      case let .fetchTodaysDailyChallengeResponse(.success(response)):
        state.dailyChallenges = response
        return .none

      case let .gameButtonTapped(gameMode):
        guard
          let challenge = state.dailyChallenges
            .first(where: { $0.dailyChallenge.gameMode == gameMode })
        else { return .none }

        let isPlayable: Bool
        switch challenge.dailyChallenge.gameMode {
        case .timed:
          isPlayable = !challenge.yourResult.started
        case .unlimited:
          isPlayable =
            !challenge.yourResult.started || state.inProgressDailyChallengeUnlimited != nil
        }

        guard isPlayable
        else {
          state.destination = .alert(.alreadyPlayed(nextStartsAt: challenge.dailyChallenge.endsAt))
          return .none
        }

        state.gameModeIsLoading = challenge.dailyChallenge.gameMode

        return .task {
          await .startDailyChallengeResponse(
            TaskResult {
              try await startDailyChallengeAsync(
                challenge,
                apiClient: self.apiClient,
                date: { self.mainRunLoop.now.date },
                fileClient: self.fileClient
              )
            }
          )
        }

      case let .startDailyChallengeResponse(.failure(DailyChallengeError.alreadyPlayed(endsAt))):
        state.destination = .alert(.alreadyPlayed(nextStartsAt: endsAt))
        state.gameModeIsLoading = nil
        return .none

      case let .startDailyChallengeResponse(
        .failure(DailyChallengeError.couldNotFetch(nextStartsAt))
      ):
        state.destination = .alert(.couldNotFetchDaily(nextStartsAt: nextStartsAt))
        state.gameModeIsLoading = nil
        return .none

      case .startDailyChallengeResponse(.failure):
        return .none

      case let .startDailyChallengeResponse(.success(inProgressGame)):
        state.gameModeIsLoading = nil
        return .task { .delegate(.startGame(inProgressGame)) }

      case .task:
        return .run { send in
          await withTaskGroup(of: Void.self) { group in
            group.addTask {
              await send(
                .userNotificationSettingsResponse(
                  self.userNotifications.getNotificationSettings()
                )
              )
            }

            group.addTask {
              await send(
                .fetchTodaysDailyChallengeResponse(
                  TaskResult {
                    try await self.apiClient.apiRequest(
                      route: .dailyChallenge(.today(language: .en)),
                      as: [FetchTodaysDailyChallengeResponse].self
                    )
                  }
                ),
                animation: .default
              )
            }
          }
        }

      case let .userNotificationSettingsResponse(settings):
        state.userNotificationSettings = settings
        return .none
      }
    }
    .presentationDestination(state: \.$destination, action: /Action.destination) {
      Destinations()
    }
  }

  public struct Destinations: ReducerProtocol {
    public enum State: Equatable {
      case alert(AlertState<Never>)
      case notificationsAuthAlert(NotificationsAuthAlert.State)
      case results(DailyChallengeResults.State)
    }

    public enum Action: Equatable {
      case alert(Never)
      case notificationsAuthAlert(NotificationsAuthAlert.Action)
      case results(DailyChallengeResults.Action)
    }

    public var body: some ReducerProtocol<State, Action> {
      ScopeCase(
        state: /State.notificationsAuthAlert,
        action: /Action.notificationsAuthAlert
      ) {
        NotificationsAuthAlert()
      }
      ScopeCase(
        state: /State.results,
        action: /Action.results
      ) {
        DailyChallengeResults()
      }
    }
  }
}

extension AlertState where Action == Never {
  static func alreadyPlayed(nextStartsAt: Date) -> Self {
    Self(
      title: .init("Already played"),
      message: .init(
        """
        You already played today’s daily challenge. You can play the next one in \
        \(nextStartsAt, formatter: relativeFormatter).
        """),
      dismissButton: .default(.init("OK"))
    )
  }

  static func couldNotFetchDaily(nextStartsAt: Date) -> Self {
    Self(
      title: .init("Couldn’t start today’s daily"),
      message: .init(
        """
        We’re sorry. We were unable to fetch today’s daily or you already started it \
        earlier today. You can play the next daily in \(nextStartsAt, formatter: relativeFormatter).
        """),
      dismissButton: .default(.init("OK"))
    )
  }
}

public struct DailyChallengeView: View {
  @Environment(\.adaptiveSize) var adaptiveSize
  @Environment(\.colorScheme) var colorScheme
  @Environment(\.date) var date
  let store: StoreOf<DailyChallengeReducer>
  @ObservedObject var viewStore: ViewStore<ViewState, DailyChallengeReducer.Action>

  struct ViewState: Equatable {
    let gameModeIsLoading: GameMode?
    let isNotificationStatusDetermined: Bool
    let numberOfPlayers: Int
    let timedState: ButtonState
    let unlimitedState: ButtonState

    enum ButtonState: Equatable {
      case played(rank: Int, outOf: Int)
      case playable
      case resume(currentScore: Int)
      case unplayable
    }

    init(state: DailyChallengeReducer.State) {
      self.gameModeIsLoading = state.gameModeIsLoading
      self.isNotificationStatusDetermined = ![.notDetermined, .provisional]
        .contains(state.userNotificationSettings?.authorizationStatus)
      self.numberOfPlayers = state.dailyChallenges.numberOfPlayers
      self.timedState = .init(
        fetchedResponse: state.dailyChallenges.timed,
        inProgressGame: nil
      )
      self.unlimitedState = .init(
        fetchedResponse: state.dailyChallenges.unlimited,
        inProgressGame: state.inProgressDailyChallengeUnlimited
      )
    }
  }

  public init(store: StoreOf<DailyChallengeReducer>) {
    self.store = store
    self.viewStore = ViewStore(self.store.scope(state: ViewState.init))
  }

  public var body: some View {
    GeometryReader { proxy in
      VStack {
        Spacer()
          .frame(maxHeight: .grid(16))

        VStack(spacing: .grid(8)) {
          Group {
            if self.viewStore.numberOfPlayers <= 1 {
              (Text("Play")
                + Text("\nagainst the")
                + Text("\ncommunity"))
            } else {
              (Text("\(self.viewStore.numberOfPlayers)")
                + Text("\npeople have")
                + Text("\nplayed!"))
            }
          }
          .font(.custom(.matterMedium, size: self.adaptiveSize.pad(48, by: 2)))
          .lineLimit(3)
          .minimumScaleFactor(0.2)
          .multilineTextAlignment(.center)

          (Text("(") + Text(timeDescriptionUntilTomorrow(now: self.date())) + Text(" left)"))
            .adaptiveFont(.matter, size: 20)
        }
        .screenEdgePadding(.horizontal)

        Spacer()

        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible()),
          ]
        ) {
          GameButton(
            title: Text("Timed"),
            icon: Image(systemName: "clock.fill"),
            color: .dailyChallenge,
            inactiveText: self.viewStore.timedState.inactiveText,
            isLoading: self.viewStore.gameModeIsLoading == .timed,
            resumeText: self.viewStore.timedState.resumeText,
            action: { self.viewStore.send(.gameButtonTapped(.timed), animation: .default) }
          )
          .disabled(self.viewStore.gameModeIsLoading != nil)

          GameButton(
            title: Text("Unlimited"),
            icon: Image(systemName: "infinity"),
            color: .dailyChallenge,
            inactiveText: self.viewStore.unlimitedState.inactiveText,
            isLoading: self.viewStore.gameModeIsLoading == .unlimited,
            resumeText: self.viewStore.unlimitedState.resumeText,
            action: { self.viewStore.send(.gameButtonTapped(.unlimited), animation: .default) }
          )
          .disabled(self.viewStore.gameModeIsLoading != nil)
        }
        .adaptivePadding(.vertical)
        .screenEdgePadding(.horizontal)

        Button {
          viewStore.send(.destination(.present(.results(DailyChallengeResults.State()))))
        } label: {
          HStack {
            Text("View all results")
              .adaptiveFont(.matterMedium, size: 16)
            Spacer()
            Image(systemName: "arrow.right")
              .font(.system(size: self.adaptiveSize.pad(16)))
          }
          .adaptivePadding(.horizontal, .grid(5))
          .adaptivePadding(.vertical, .grid(9))
          .padding(.bottom, proxy.safeAreaInsets.bottom / 2)
        }
        .frame(maxWidth: .infinity)
        .foregroundColor((self.colorScheme == .dark ? .isowordsBlack : .dailyChallenge))
        .background(self.colorScheme == .dark ? Color.dailyChallenge : .isowordsBlack)
      }
      .task { await self.viewStore.send(.task).finish() }
      .navigationStyle(
        backgroundColor: self.colorScheme == .dark ? .isowordsBlack : .dailyChallenge,
        foregroundColor: self.colorScheme == .dark ? .dailyChallenge : .isowordsBlack,
        title: Text("Daily Challenge"),
        trailing: Group {
          if !self.viewStore.isNotificationStatusDetermined {
            ReminderBell {
              self.viewStore.send(
                .destination(.present(.notificationsAuthAlert(NotificationsAuthAlert.State()))),
                animation: .default
              )
            }
            .transition(
              AnyTransition
                .scale(scale: 0)
                .animation(Animation.easeOut.delay(1))
            )
          }
        }
      )
      .edgesIgnoringSafeArea(.bottom)
    }
    .alert(
      store: self.store.scope(
        state: \.$destination,
        action: DailyChallengeReducer.Action.destination
      ),
      state: /DailyChallengeReducer.Destinations.State.alert,
      action: DailyChallengeReducer.Destinations.Action.alert
    )
    .notificationsAlert(
      store: self.store.scope(
        state: \.$destination,
        action: DailyChallengeReducer.Action.destination
      ),
      state: /DailyChallengeReducer.Destinations.State.notificationsAuthAlert,
      action: DailyChallengeReducer.Destinations.Action.notificationsAuthAlert
    )
    .navigationDestination(
      store: self.store.scope(
        state: \.$destination,
        action: DailyChallengeReducer.Action.destination
      ),
      state: /DailyChallengeReducer.Destinations.State.results,
      action: DailyChallengeReducer.Destinations.Action.results,
      destination: DailyChallengeResultsView.init(store:)
    )
  }
}

extension DailyChallengeView.ViewState.ButtonState {
  init(
    fetchedResponse: FetchTodaysDailyChallengeResponse?,
    inProgressGame: InProgressGame?
  ) {
    if let rank = fetchedResponse?.yourResult.rank,
      let outOf = fetchedResponse?.yourResult.outOf
    {
      self = .played(rank: rank, outOf: outOf)
    } else if let currentScore = inProgressGame?.currentScore {
      self = .resume(currentScore: currentScore)
    } else if fetchedResponse?.yourResult.started == .some(true) {
      self = .unplayable
    } else {
      self = .playable
    }
  }

  var inactiveText: Text? {
    switch self {
    case let .played(rank: rank, outOf: outOf):
      return Text("Played\n#\(rank) of \(outOf)")
    case .resume:
      return nil
    case .playable:
      return nil
    case .unplayable:
      return Text("Played")
    }
  }

  var resumeText: Text? {
    switch self {
    case .played:
      return nil
    case let .resume(currentScore: currentScore):
      return currentScore > 0 ? Text("\(currentScore) pts") : nil
    case .playable:
      return nil
    case .unplayable:
      return nil
    }
  }
}

private let relativeFormatter = RelativeDateTimeFormatter()

private struct ReminderBell: View {
  @State var shake = false
  let action: () -> Void

  var body: some View {
    Button(action: self.action) {
      Image(systemName: "bell.badge.fill")
        .font(.system(size: 20))
        .modifier(RingEffect(animatableData: CGFloat(self.shake ? 1 : 0)))
        .onAppear {
          withAnimation(Animation.easeInOut(duration: 1).delay(2)) {
            self.shake = true
          }
        }
    }
  }
}

private struct RingEffect: GeometryEffect {
  var animatableData: CGFloat

  func effectValue(size: CGSize) -> ProjectionTransform {
    ProjectionTransform(
      CGAffineTransform(rotationAngle: -.pi / 30 * sin(animatableData * .pi * 10))
    )
  }
}

#if DEBUG
  import SwiftUIHelpers

  struct DailyChallengeView_Previews: PreviewProvider {
    static var previews: some View {
      Preview {
        NavigationStack {
          DailyChallengeView(
            store: .init(
              initialState: DailyChallengeReducer.State(
                inProgressDailyChallengeUnlimited: update(.mock) {
                  $0?.moves = [.highScoringMove]
                }
              ),
              reducer: DailyChallengeReducer()
                .dependency(\.userNotifications.getNotificationSettings) {
                  .init(authorizationStatus: .notDetermined)
                }
            )
          )
        }
      }
    }
  }
#endif
