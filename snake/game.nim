import jsconsole, random, strutils, dom, math, colors, deques, htmlgen, sugar
import options

from xmltree import nil

import gamelight/[graphics, geometry, vec, utils]
import jswebsockets

import message, food, replay, countries, vibrate

type
  Game* = ref object
    renderer: Renderer2D
    player: Snake
    food: array[2, Food]
    score: int
    lastUpdate, lastBlink, lastSpecial: float
    paused: bool
    blink: bool
    nextSpecial: float # ms until next special food is shown.
    scoreElement, scoreTextElement: Element
    allTimeTextElement, allTimeScoreElement: Element
    messageElement: Element
    playerCountElement: Element
    highScoreElements: array[5, Element]
    scene: Scene
    players: seq[Player]
    playersCount: int
    socket: WebSocket
    nickname: string
    onGameStart*: proc (game: Game)
    replay: Replay
    currentReplayTime: Option[float] # None when replay isn't active.

  Scene {.pure.} = enum
    MainMenu, Game

  Snake = ref object
    direction: Direction
    requestedDirections: Deque[Direction]
    body: seq[SnakeSegment]
    alive: bool

  SnakeSegment = ref object
    pos: Point[float] ## Position in level. Not in pixels but segment units.

const
  segmentSize = 10 ## In pixels
  levelWidth = 30.0 ## In segments
  levelHeight = 20.0 ## In Segments
  scoreSidebarWidth = 120.0
  scoreTextWidth = scoreSideBarWidth - 30
  allTimeScoreTop = 55.0
  renderWidth = segmentSize * levelWidth + scoreSidebarWidth ## In pixels
  renderHeight = segmentSize * levelHeight ## In pixels

const
  levelBgColor = "#b2bd08"
  crossOutColor = "#cc1f1f"
  font = "Snake, monospace"
  blinkTime = 800 # ms

proc newSnakeSegment(pos: Point[float]): SnakeSegment =
  result = SnakeSegment(
    pos: pos
  )

proc toPixelPos(pos: Point[float]): Point[float] =
  assert pos.x <= levelWidth
  assert pos.y <= levelHeight
  return pos * segmentSize

proc newSnake(): Snake =
  let head = newSnakeSegment((0.0, levelHeight / 2))
  let segment = newSnakeSegment((-1.0, levelHeight / 2))
  let segment2 = newSnakeSegment((-2.0, levelHeight / 2))

  result = Snake(
    direction: dirEast,
    requestedDirections: initDeque[Direction](),
    body: @[head, segment, segment2],
    alive: true
  )

proc head(snake: Snake): SnakeSegment =
  snake.body[0]

proc generateFoodPos(game: Game): Point[float] =
  # TODO: Reimplement this naive implementation.
  var i = 0
  while i < 5:
    result = (
      rand(0 ..< levelWidth.int).float,
      rand(0 ..< levelHeight.int).float
    )

    var hit = false
    for segment in game.player.body:
      if segment.pos == result:
        hit = true
        break
    if not hit: break
    i.inc()

proc createHighScoreText(player: Player): string =
  let country = replace(getUnicodeForCountry(player.countryCode) & "  ", " ",
                        "&nbsp;")
  let nickname = xmltree.escape(player.nickname.toLowerAscii())
  let deathStyle =
    if player.alive: ""
    else: ("background-image: linear-gradient(transparent 5px,$1 5px,$1 7px,transparent 5px);" &
          "background-image: -webkit-linear-gradient(transparent 5px,$1 5px,$1 7px,transparent 5px);") %
          crossOutColor
  let text = span(country, style="float: left; line-height: 1.4;") &
             span(nickname, style="float: left;" &
                                  deathStyle) &
             span(intToStr(player.score.int), style="float: right;")
  return text

proc send(game: Game, data: string) =
  if not game.socket.isNil and game.socket.readyState == ReadyState.Open:
    game.socket.send(data)
  else:
    console.log("Cannot send to server because not connected.")

proc processMessage(game: Game, data: string) =
  let msg = parseMessage(data)
  console.log("Got message ", msg)
  case msg.kind
  of MessageType.PlayerUpdate:
    console.log("Received ", msg.count, " players")
    game.players = msg.players
    game.playersCount = msg.count

    # Update message in UI.
    let count = $(game.playersCount-1)
    game.playerCountElement.innerHtml = count & " others playing"

    # Update high score labels.
    for i in 0 ..< game.highScoreElements.high:
      if i < len(game.players):
        let player = game.players[i]
        game.highScoreElements[i].innerHTML = createHighScoreText(player)
        game.highScoreElements[i].style.color =
          if player.paused: "#6d6d6d"
          else: "#2d2d2d"
      else:
        game.highScoreElements[i].innerHTML = ""

    # Update top score.
    game.allTimeScoreElement.innerHTML = createHighScoreText(msg.top)
  of MessageType.Replay:
    game.replay = msg.oldReplay
    game.paused = false
    game.lastSpecial = game.lastUpdate
    game.currentReplayTime = some(game.replay.events[0].time)
    game.scoreTextElement.innerHtml = "replay"
  of MessageType.Hello, MessageType.ClientUpdate,
     MessageType.ReplayEvent, MessageType.GetReplay: discard

proc createFood(game: Game, kind: FoodKind, foodIndex: int) =
  let pos = generateFoodPos(game)

  game.food[foodIndex] = Food(kind: kind, pos: pos, ticksLeft: -1)
  console.log("Created food at ", pos)
  if kind == Special:
    game.food[foodIndex].ticksLeft = 20

  game.send(toJson(createReplayEventMessage(
    game.replay.recordNewFood(pos, kind)
  )))

proc connect(game: Game) =
  when defined(local):
    game.socket = newWebSocket("ws://localhost:25473/", "snake")
  else:
    game.socket = newWebSocket("wss://picheta.me/snake/server/", "snake")

  game.socket.onOpen =
    proc (e: Event) =
      console.log("Connected to server")
      let msg = createHelloMessage(game.nickname, game.replay)
      game.send(toJson(msg))

  game.socket.onMessage =
    proc (e: MessageEvent) =
      processMessage(game, $e.data)

  game.socket.onClose =
    proc (e: CloseEvent) =
      console.log("Server closed")
      game.players = @[]
      game.playerCountElement.innerHtml = "disconnected"
      for element in game.highScoreElements:
        element.innerHtml = ""
      # Let's attempt to reconnect.
      console.log("Going to reconnect in 10 seconds")
      discard window.setTimeout(() => connect(game), 10000)

proc switchScene(game: Game, scene: Scene) =
  case scene
  of Scene.MainMenu:
    # We do not support moving to previous scene.
    assert game.scene != Scene.Game

    # Create elements showing "snake" and asking for nickname.
    var elements: seq[Element] = @[]
    let snakeTextPos = (renderWidth / 2 - 90, renderHeight / 2 - 70)
    elements.add game.renderer.createTextElement("snake", snakeTextPos,
        "#000000", 90.0, font)

    let nameTextPos = (snakeTextPos[0], snakeTextPos[1] + 100)
    elements.add game.renderer.createTextElement("nick: ", nameTextPos,
        "#000000", 24.0, font)

    let nameInputPos = (nameTextPos[0] + 50, nameTextPos[1] + 3)
    elements.add game.renderer.createTextBox(nameInputPos, width = 80, height = 16)
    elements[^1].style.backgroundColor = "transparent"
    elements[^1].style.border = "none"
    elements[^1].style.borderBottom = "2px solid black"

    let playBtnPos = (nameInputPos[0] + 90, nameInputPos[1])
    elements.add game.renderer.createButton(playBtnPos, "play", width = 60,
                                            height = 20, fontSize = 18,
                                            fontFamily = font)
    elements[^1].style.backgroundColor = "black"
    elements[^1].style.color = levelBgColor
    elements[^1].style.border = "0"

    elements[^1].addEventListener("click",
      proc (ev: Event) =
        game.nickname = $elements[^2].OptionElement.value
        switchScene(game, Scene.Game)

        for element in elements:
          element.style.display = "none"
    )

  of Scene.Game:
    # Initialise vibration (phones ask for permission, best to do it at start).
    vibrate(10)

    # Let snake.nim know that the game started.
    if not game.onGameStart.isNil:
      game.onGameStart(game)

    # Scale to screen size.
    if isTouchDevice():
      game.renderer.setScaleToScreen(true)

    # Create text element nodes to show player score.
    let scoreTextPos = (renderWidth - scoreSidebarWidth + 35, 10.0)
    game.scoreTextElement = game.renderer.createTextElement(
      "score", scoreTextPos, "#000000", 24, font
    )
    let scorePos = (renderWidth - scoreSidebarWidth + 35, 35.0)
    game.scoreElement = game.renderer.createTextElement("0000000", scorePos,
                          "#000000", 14, font)

    # Create all time high score elements.
    let allTimePos = (renderWidth - scoreSidebarWidth + 28, allTimeScoreTop)
    game.allTimeTextElement = game.renderer.createTextElement(
        "all time high score", allTimePos, levelBgColor, 10, font)
    let allTimeScorePos = (renderWidth - scoreSidebarWidth + 15,
                           allTimePos[1] + 10.0)
    game.allTimeScoreElement = game.renderer.createTextElement("",
        allTimeScorePos, levelBgColor, 12, font, scoreTextWidth)

    # Create element to show game over/paused message.
    let messageTextPos = (renderWidth - scoreSidebarWidth + 23, 85.0)
    game.messageElement = game.renderer.createTextElement("game<br/>over",
                            messageTextPos, "#000000", 26, font)

    # Create element to show current player count.
    let playerCountPos = (renderWidth - scoreSideBarWidth + 15,
                          renderHeight - 25.0)
    game.playerCountElement = game.renderer.createTextElement("",
                                playerCountPos, "#1d1d1d", 12, font)

    # Create a high score elements.
    for i in 0 .. game.highScoreElements.high:
      let y = (i.float * 15.0) + allTimeScoreTop
      let pos = (renderWidth - scoreSideBarWidth + 15,
                scorePos[1] + y)
      game.highScoreElements[i] = game.renderer.createTextElement("",
          pos, "#2d2d2d", 12, font, scoreTextWidth)

    # Create first nibble.
    game.createFood(Nibble, 0)

    # Set up WebSocket connection.
    game.connect()

  game.scene = scene

proc newGame*(canvasId: string): Game =
  randomize()
  result = Game(
    renderer: newRenderer2D(canvasId, renderWidth.int, renderHeight.int),
    player: newSnake(),
    players: @[],
    scene: Scene.MainMenu,
    replay: newReplay()
  )

  switchScene(result, Scene.MainMenu)

proc isReplay(game: Game): bool =
  return game.currentReplayTime.isSome()

proc changeDirection*(game: Game, direction: Direction) =
  if game.scene != Scene.Game or game.isReplay: return

  if game.player.requestedDirections.len >= 2:
    return

  game.player.requestedDirections.addLast(direction)

proc getLastDirection*(game: Game): Direction =
  ## Retrieves the direction that the snake is moving in currently,
  ## or if directions have been requested but not executed yet then it
  ## returns the last of those directions.
  result = game.player.direction
  if game.player.requestedDirections.len > 0:
    result = game.player.requestedDirections[^1]

proc getHeadPixelPos*(game: Game): Point[int] =
  ## Returns the pixel point of the head's front (centered).
  ##
  ## The resulting point is scaled to the canvas on the screen (!).
  let res = game.player.head.pos.toPixelPos()
  case game.player.direction
  of dirNorth, dirSouth:
    result = (res.x.int + (segmentSize div 2), res.y.int)
  of dirWest, dirEast:
    result = (res.x.int, res.y.int + (segmentSize div 2))

  return game.renderer.scale(result)

proc processDirections(game: Game) =
  while game.player.requestedDirections.len > 0:
    let direction = game.player.requestedDirections.popFirst()
    if toPoint[float](game.player.direction) == -toPoint[float](direction):
      continue # Disallow changing direction in opposite direction of travel.

    if direction != game.player.direction:
      game.player.direction = direction
      game.send(toJson(createReplayEventMessage(
        game.replay.recordNewDirection(game.player.head.pos, direction)
      )))
      break

proc detectHeadCollision(game: Game): bool =
  # Check if head collides with any other segment.
  for i in 1 ..< game.player.body.len:
    if game.player.head.pos == game.player.body[i].pos:
      return true

proc detectFoodCollision(game: Game): int =
  # Check if head collides with food.
  for i in 0 ..< game.food.len:
    if game.food[i].isNil:
      continue

    if game.food[i].pos == game.player.head.pos:
      return i

  return -1

proc updateServer(game: Game) =
  let msg = createClientUpdateMessage(
    game.player.alive, game.paused or game.isReplay
  )
  if game.socket.readyState == ReadyState.Open:
    game.send(toJson(msg))

proc updateScore(game: Game) =
  # Update score element.
  game.scoreElement.innerHTML = intToStr(game.score, 7)

  # Update server.
  updateServer(game)

proc eatFood(game: Game, foodIndex: int) =
  let tailPos = game.player.body[^1].pos.copy()
  game.player.body.add(newSnakeSegment(tailPos))

  let kind = game.food[foodIndex].kind
  game.score += getPoints(kind)
  case kind
  of Nibble:
    game.createFood(Nibble, 0)
  of Special:
    game.food[foodIndex] = nil

  vibrate(50)

  game.send(toJson(createReplayEventMessage(
    game.replay.recordFoodEaten(game.player.head.pos, kind)
  )))

  game.updateScore()

proc updateFood(game: Game) =
  # Expire special food.
  if not game.food[1].isNil:
    assert game.food[1].kind == Special
    game.food[1].ticksLeft.dec()

    if game.food[1].ticksLeft <= 0:
      game.food[1] = nil

  # Randomly create special food.
  if game.nextSpecial == 0:
    game.lastSpecial = game.lastUpdate
    game.nextSpecial = rand(4_000.0 .. 30_000.0)

  if game.lastUpdate - game.lastSpecial >= game.nextSpecial and
     game.food[1].isNil:
    game.lastSpecial = game.lastUpdate
    game.nextSpecial = 0
    createFood(game, Special, 1)

proc executeEvent(game: Game, event: ReplayEvent) =
  console.log("Executing event ", $event.kind, " at time ", event.time)
  case event.kind
  of FoodAppeared:
    case event.foodKind
    of Nibble:
      game.food[0] = Food(kind: Nibble, pos: event.foodPos, ticksLeft: -1)
    of Special:
      game.food[1] = Food(kind: Special, pos: event.foodPos, ticksLeft: 20)
  of FoodEaten:
    let tailPos = game.player.body[^1].pos.copy()
    game.player.body.add(newSnakeSegment(tailPos))
    game.score += getPoints(event.foodKind)
    updateScore(game)
    if event.foodKind == Special:
      game.food[1] = nil
  of DirectionChanged:
    game.player.direction = event.playerDirection
    game.player.head.pos = event.playerPos

proc updateReplay(game: Game) =
  if not game.isReplay: return

  let currentTime = game.currentReplayTime.get()
  while game.replay.events.len > 0 and currentTime > game.replay.events[0].time:
    executeEvent(game, game.replay.events[0])
    game.replay.events.delete(0)

  # Hacky, but we reuse lastSpecial to keep track of time. This has the side
  # effect that it prevents random special food being created.
  let diff = (game.lastUpdate - game.lastSpecial) / 1000
  game.currentReplayTime = some(currentTime + diff)
  game.lastSpecial = game.lastUpdate

  # Game over.
  if game.replay.events.len == 0:
    game.player.alive = false
    game.messageElement.innerHtml = "game<br/>over"

proc update(game: Game) =
  # Return early if paused.
  if game.paused or game.scene != Scene.Game: return

  if not game.player.alive: return

  if not game.isReplay:
    # Check for collision with itself.
    let headCollision = game.detectHeadCollision()
    if headCollision:
      game.player.alive = false
      game.messageElement.innerHtml = "game<br/>over"
      vibrate([100, 50, 200])
      updateServer(game)
      return

    # Check for food collision.
    let foodCollision = game.detectFoodCollision()
    if foodCollision != -1:
      game.eatFood(foodCollision)

    # Change direction.
    processDirections(game)

  # Save old position of head.
  var oldPos = game.player.head.pos.copy()

  # Move head in the current direction.
  let movementVec = toPoint[float](game.player.direction)
  game.player.head.pos.add(movementVec)

  # Move each body segment with the head.
  for i in 1 ..< game.player.body.len:
    swap(game.player.body[i].pos, oldPos)

  # Create a portal out of the edges of the level.
  if game.player.head.pos.x >= levelWidth:
    game.player.head.pos.x = 0
  elif game.player.head.pos.x < 0:
    game.player.head.pos.x = levelWidth

  if game.player.head.pos.y >= levelHeight:
    game.player.head.pos.y = 0
  elif game.player.head.pos.y < 0:
    game.player.head.pos.y = levelHeight

  # Update replay (only does anything when replay is enabled).
  updateReplay(game)

  # Update food.
  updateFood(game)

proc drawFood(game: Game, food: Food) =
  const nibble = [
    0, 0, 0, 1, 1, 1, 1, 0, 0, 0,
    0, 0, 0, 1, 1, 1, 1, 0, 0, 0,
    0, 0, 0, 1, 1, 1, 1, 0, 0, 0,
    1, 1, 1, 0, 0, 0, 0, 1, 1, 1,
    1, 1, 1, 0, 0, 0, 0, 1, 1, 1,
    1, 1, 1, 0, 0, 0, 0, 1, 1, 1,
    1, 1, 1, 0, 0, 0, 0, 1, 1, 1,
    0, 0, 0, 1, 1, 1, 1, 0, 0, 0,
    0, 0, 0, 1, 1, 1, 1, 0, 0, 0,
    0, 0, 0, 1, 1, 1, 1, 0, 0, 0,
  ]

  const special = [
    9, 9, 9, 2, 2, 2, 2, 3, 3, 3,
    9, 9, 9, 2, 2, 2, 2, 3, 3, 3,
    9, 9, 9, 2, 2, 2, 2, 3, 3, 3,
    8, 8, 8, 1, 1, 1, 1, 4, 4, 4,
    8, 8, 8, 1, 1, 1, 1, 4, 4, 4,
    8, 8, 8, 1, 1, 1, 1, 4, 4, 1,
    8, 8, 8, 1, 1, 1, 1, 4, 4, 4,
    7, 7, 7, 6, 6, 6, 6, 5, 5, 5,
    7, 7, 7, 6, 6, 6, 6, 5, 5, 5,
    7, 7, 7, 6, 6, 6, 6, 5, 5, 5,
  ]

  var pos = food.pos.toPixelPos()
  for x in 0 ..< segmentSize:
    for y in 0 ..< segmentSize:
      let index = x + (y * segmentSize)
      let pos = (pos.x + x.float, pos.y + y.float)
      case food.kind
      of Nibble:
        if nibble[index] == 1:
          game.renderer[pos] = colBlack
      of Special:
        if special[index] < food.ticksLeft:
          game.renderer[pos] = colBlack

proc drawEyes(game: Game) =
  let angle = game.player.direction.angle
  let headPos = game.player.head.pos.toPixelPos()
  let headMiddle = headPos + ((segmentSize-1) / 2, (segmentSize-1) / 2)

  let eyeTop = (headPos.x + 5.0, headPos.y + 2).toPoint()
  let eyeBot = (headPos.x + 5.0, headPos.y + 6).toPoint()

  for eye in [eyeTop, eyeBot]:
    let rect = [
      (eye.x    , eye.y    ).toPoint().rotate(angle, headMiddle),
      (eye.x + 1, eye.y    ).toPoint().rotate(angle, headMiddle),
      (eye.x    , eye.y + 1).toPoint().rotate(angle, headMiddle),
      (eye.x + 1, eye.y + 1).toPoint().rotate(angle, headMiddle)
    ]
    for point in rect:
      game.renderer[point] = colWhite

proc drawMainMenu(game: Game) =
  discard

proc drawGame(game: Game) =
  # Determines whether the Game Over/Paused message should be shown.
  let showMessage = not game.player.alive or game.paused

  # Draw the food.
  for i in 0 .. game.food.high:
    if not game.food[i].isNil:
      game.drawFood(game.food[i])

  # Draw snake.
  if not (game.blink and showMessage):
    for i in 0 ..< game.player.body.len:
      let segment = game.player.body[i]
      let pos = segment.pos.toPixelPos()
      game.renderer.fillRect(pos.x, pos.y, segmentSize, segmentSize, "#000000")

    game.drawEyes()

  # Draw the scoreboard.
  game.renderer.fillRect(renderWidth - scoreSidebarWidth, 0, scoreSidebarWidth,
                         renderHeight, levelBgColor)

  game.renderer.strokeRect(renderWidth - scoreSidebarWidth, 5,
                           scoreSidebarWidth - 5, renderHeight - 10,
                           lineWidth = 2)

  game.renderer.fillRect(renderWidth - scoreSidebarWidth, allTimeScoreTop - 2,
                         scoreSidebarWidth - 5, 25.0)

  # Show/hide high scores.
  for element in game.highScoreElements:
    element.style.display = if showMessage: "none" else: "block"

  # Show/hide Game Over or Pause message.
  if game.blink and showMessage:
    game.messageElement.style.display = "block"
    game.scoreElement.style.color = crossOutColor
  else:
    game.messageElement.style.display = "none"
    game.scoreElement.style.color = "black"

  # Show/hide `replay` message
  if game.blink and game.isReplay:
    game.scoreTextElement.style.display = "none"
  else:
    game.scoreTextElement.style.display = "block"

proc draw(game: Game, lag: float) =
  # Fill background color.
  game.renderer.fillRect(0.0, 0.0, renderWidth, renderHeight, levelBgColor)

  case game.scene
  of Scene.MainMenu:
    drawMainMenu(game)
  of Scene.Game:
    drawGame(game)

proc getTickLength(game: Game): float =
  result = 200.0
  if game.player.alive:
    result -= game.score.float

proc nextFrame*(game: Game, frameTime: float) =
  # Determine whether we should update.
  let elapsedTime = frameTime - game.lastUpdate

  let ticks = floor(elapsedTime / game.getTickLength).int
  let lag = (elapsedTime / game.getTickLength) - ticks.float
  if elapsedTime > game.getTickLength:
    game.lastUpdate = frameTime
    #for tick in 0 .. <ticks:
    game.update()

  # Blink timer.
  let elapsedBlinkTime = frameTime - game.lastBlink
  if elapsedBlinkTime > blinkTime:
    game.lastBlink = frameTime
    game.blink = not game.blink

  game.draw(lag)

proc togglePause*(game: Game) =
  if game.scene != Scene.Game: return
  if not game.player.alive: return

  game.paused = not game.paused
  game.messageElement.innerHtml = "paused"

  updateServer(game)

proc restart*(game: Game) =
  game.player = newSnake()
  game.score = 0
  game.replay = newReplay()
  game.currentReplayTime = none[float]()

  let msg = createHelloMessage(game.nickname, nil)
  game.send(toJson(msg))
  updateScore(game)

proc replay*(game: Game) =
  restart(game)
  game.paused = true
  game.send(toJson(createGetReplayMessage()))

proc isScaledToScreen*(game: Game): bool =
  return game.renderer.getScaleToScreen()