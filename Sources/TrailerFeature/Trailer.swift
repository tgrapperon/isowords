import AudioPlayerClient
import Bloom
import Combine
import ComposableArchitecture
import CubeCore
import DictionaryClient
import GameCore
import SharedModels
import SwiftUI
import TcaHelpers

public struct TrailerState: Equatable {
  var game: GameState
  @BindableState var nub: CubeSceneView.ViewState.NubState
  @BindableState var opacity: Double

  public init(
    game: GameState,
    nub: CubeSceneView.ViewState.NubState = .init(),
    opacity: Double = 0
  ) {
    self.game = game
    self.nub = nub
    self.opacity = opacity
  }

  public init() {
    self = .init(
      game: .init(
        cubes: .trailer,
        gameContext: .solo,
        gameCurrentTime: .init(),
        gameMode: .unlimited,
        gameStartTime: .init(),
        moves: []
      )
    )
  }
}

public enum TrailerAction: BindableAction, Equatable {
  case binding(BindingAction<TrailerState>)
  case game(GameAction)
  case task
}

public struct TrailerEnvironment {
  var audioPlayer: AudioPlayerClient
  var backgroundQueue: AnySchedulerOf<DispatchQueue>
  var dictionary: DictionaryClient
  var mainQueue: AnySchedulerOf<DispatchQueue>
  var mainRunLoop: AnySchedulerOf<RunLoop>

  public init(
    audioPlayer: AudioPlayerClient,
    backgroundQueue: AnySchedulerOf<DispatchQueue>,
    dictionary: DictionaryClient,
    mainQueue: AnySchedulerOf<DispatchQueue>,
    mainRunLoop: AnySchedulerOf<RunLoop>
  ) {
    self.audioPlayer = audioPlayer.filteredSounds(
      doNotInclude: AudioPlayerClient.Sound.allValidWords
    )
    self.backgroundQueue = backgroundQueue
    self.dictionary = dictionary
    self.mainQueue = mainQueue
    self.mainRunLoop = mainRunLoop
  }
}

public let trailerReducer = Reducer<TrailerState, TrailerAction, TrailerEnvironment>.combine(
  gameReducer(
    state: \TrailerState.game,
    action: /TrailerAction.game,
    environment: {
      GameEnvironment(
        apiClient: .noop,
        applicationClient: .noop,
        audioPlayer: $0.audioPlayer,
        backgroundQueue: $0.backgroundQueue,
        build: .noop,
        database: .noop,
        dictionary: $0.dictionary,
        feedbackGenerator: .noop,
        fileClient: .noop,
        gameCenter: .noop,
        lowPowerMode: .false,
        mainQueue: $0.mainQueue,
        mainRunLoop: $0.mainRunLoop,
        remoteNotifications: .noop,
        serverConfig: .noop,
        setUserInterfaceStyle: { _ in },
        storeKit: .noop,
        userDefaults: .noop,
        userNotifications: .noop
      )
    },
    isHapticsEnabled: { _ in true }
  ),

  Reducer { state, action, environment in
    switch action {
    case .binding:
      return .none

    case .game:
      return .none

    case .task:
      return .run { send in
        await environment.audioPlayer.load(AudioPlayerClient.Sound.allCases)
        
        // Play trailer music
        await environment.audioPlayer.play(.onboardingBgMusic)

        // Fade the cube in after a second
        await send(.set(\.$opacity, 1), animation: .easeInOut(duration: fadeInDuration))
        try await environment.mainQueue.sleep(for: firstWordDelay)

        // Play each word
        for (wordIndex, word) in replayableWords.enumerated() {
          // Play each character in the word
          for (characterIndex, character) in word.enumerated() {
            let face = IndexedCubeFace(index: character.index, side: character.side)

            // Move the nub to the face being played
            await send(
              .set(\.$nub.location, .face(face)),
              withDuration: moveNubToFaceDuration,
              options: .curveEaseInOut
            )
            try await environment.mainQueue.sleep(
              for: moveNubDelay(characterIndex: characterIndex)
            )

            let duration = Double.random(
              in: (0.3 * moveNubToFaceDuration)...(0.7 * moveNubToFaceDuration)
            )
            await withThrowingTaskGroup(of: Void.self) { group in
              // Press the nub on the first character
              if characterIndex == 0 {
                group.addTask {
                  try await environment.mainQueue.sleep(for: .seconds(duration))
                  await send(.set(\.$nub.isPressed, true), withDuration: 0.3)
                }
              }
              // Select the cube face
              group.addTask {
                try await environment.mainQueue.sleep(for: .seconds(duration))
                await send(.game(.tap(.began, face)), animation: .default)
              }
            }
          }

          // Release the  nub when the last character is played
          await send(.set(\.$nub.isPressed, false), withDuration: 0.3)

          // Move the nub to the submit button
          try await environment.mainQueue.sleep(for: .seconds(0.3))
          await send(
            .set(\.$nub.location, .submitButton),
            withDuration: moveNubToSubmitButtonDuration,
            options: .curveEaseInOut
          )

          // Press the nub
          try await environment.mainQueue.sleep(
            for: .seconds(
              .random(
                in: moveNubToSubmitButtonDuration ...
                  (moveNubToSubmitButtonDuration + submitHestitationDuration)
              )
            )
          )

          // Submit the word
          try await environment.mainQueue.sleep(for: .seconds(0.1))
          await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              await send(.set(\.$nub.isPressed, true), withDuration: 0.3)
            }
            group.addTask {
              try await environment.mainQueue.sleep(for: .seconds(0.2))
              await send(.game(.submitButtonTapped(reaction: nil)))
              try await environment.mainQueue.sleep(for: .seconds(0.3))
              await send(.set(\.$nub.isPressed, false), withDuration: 0.3 )
            }
          }
        }

        // Move the nub off screen once all words have been played
        try await environment.mainQueue.sleep(for: .seconds(0.3))
        await send(
          .set(\.$nub.location, .offScreenBottom),
          withDuration: moveNubOffScreenDuration,
          options: .curveEaseInOut
        )

        await send(.set(\.$opacity, 0), animation: .linear(duration: moveNubOffScreenDuration))
      }
    }
  }
  .binding()
)

public struct TrailerView: View {
  let store: Store<TrailerState, TrailerAction>
  @ObservedObject var viewStore: ViewStore<ViewState, TrailerAction>
  @Environment(\.deviceState) var deviceState

  struct ViewState: Equatable {
    let opacity: Double
    let selectedWordHasAlreadyBeenPlayed: Bool
    let selectedWordIsValid: Bool
    let selectedWordScore: Int?
    let selectedWordString: String

    init(state: TrailerState) {
      self.opacity = state.opacity
      self.selectedWordHasAlreadyBeenPlayed = state.game.selectedWordHasAlreadyBeenPlayed
      self.selectedWordIsValid = state.game.selectedWordIsValid
      self.selectedWordScore = self.selectedWordIsValid ? state.game.selectedWordScore : nil
      self.selectedWordString = state.game.selectedWordString
    }
  }

  public init(store: Store<TrailerState, TrailerAction>) {
    self.store = store
    self.viewStore = ViewStore(self.store.scope(state: ViewState.init(state:)))
  }

  public var body: some View {
    GeometryReader { proxy in
      ZStack {
        VStack {
          if !self.viewStore.selectedWordString.isEmpty {
            (Text(self.viewStore.selectedWordString)
              + self.scoreText
              .baselineOffset(
                (self.deviceState.idiom == .pad ? 2 : 1) * 16
              )
              .font(
                .custom(
                  .matterMedium,
                  size: (self.deviceState.idiom == .pad ? 2 : 1) * 20
                )
              ))
              .adaptiveFont(
                .matterSemiBold,
                size: (self.deviceState.idiom == .pad ? 2 : 1) * 32
              )
              .opacity(self.viewStore.selectedWordIsValid ? 1 : 0.5)
              .allowsTightening(true)
              .minimumScaleFactor(0.2)
              .lineLimit(1)
              .transition(.opacity)
              .animation(nil, value: self.viewStore.selectedWordString)
          }

          Spacer()

          if !self.viewStore.selectedWordString.isEmpty {
            WordSubmitButton(
              store: self.store.scope(
                state: \.game.wordSubmitButtonFeature,
                action: { .game(.wordSubmitButton($0)) }
              )
            )
            .transition(
              AnyTransition
                .asymmetric(insertion: .offset(y: 50), removal: .offset(y: 50))
                .combined(with: .opacity)
            )
            .offset(y: .grid(6))
          }

          WordListView(
            isLeftToRight: true,
            store: self.store.scope(
              state: \.game,
              action: TrailerAction.game
            )
          )
        }
        .adaptivePadding(.top, .grid(18))
        .adaptivePadding(.bottom, .grid(2))

        CubeView(
          store: self.store.scope(
            state: { CubeSceneView.ViewState(game: $0.game, nub: $0.nub, settings: .init()) },
            action: { .game(CubeSceneView.ViewAction.to(gameAction: $0)) }
          )
        )
        .adaptivePadding(
          self.deviceState.idiom == .pad ? .horizontal : [],
          .grid(30)
        )
      }
      .background(
        BloomBackground(
          size: proxy.size,
          store: self.store.actionless
            .scope(
              state: {
                BloomBackground.ViewState(
                  bloomCount: $0.game.selectedWord.count,
                  word: $0.game.selectedWordString
                )
              }
            )
        )
      )
    }
    .padding(
      self.deviceState.idiom == .pad ? .vertical : [],
      .grid(15)
    )
    .opacity(self.viewStore.opacity)
    .task { await self.viewStore.send(.task).finish() }
  }

  var scoreText: Text {
    self.viewStore.selectedWordScore.map {
      Text(" \($0)")
    } ?? Text("")
  }
}

private func moveNubDelay(characterIndex: Int) -> DispatchQueue.SchedulerTimeType.Stride {
  if characterIndex == 0 {
    return firstCharacterDelay
  } else {
    return 0
  }
}

private let firstCharacterDelay: DispatchQueue.SchedulerTimeType.Stride = 0.3
private let firstWordDelay: DispatchQueue.SchedulerTimeType.Stride = 1.5
private let moveNubToFaceDuration = 0.45
private let moveNubToSubmitButtonDuration = 0.4
private let moveNubOffScreenDuration = 0.5
private let fadeInDuration = 0.3
private let fadeOutDuration = 0.3
private let submitPressDuration = 0.05
private let submitHestitationDuration = 0.15
