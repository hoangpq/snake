import jsconsole, random, strutils, dom, math

import gamelight/[graphics, geometry, vec]

type
  Game* = ref object
    renderer: Renderer2D
    player: Snake
    food: array[2, Food]
    score: int
    tick: int
    lastUpdate: float
    scoreElement: Element
    gameOverElement: Element

  Snake = ref object
    direction: Direction
    requestedDirection: Direction
    body: seq[SnakeSegment]
    alive: bool

  SnakeSegment = ref object
    pos: Point[int] ## Position in level. Not in pixels but segment units.

  FoodKind = enum
    Apple, Cherry

  Food = ref object
    kind: FoodKind
    pos: Point[int] ## Position in level. Not in pixels but segment units.

const
  segmentSize = 10 ## In pixels
  levelWidth = 30 ## In segments
  levelHeight = 18 ## In Segments
  scoreSidebarWidth = 100
  renderWidth = segmentSize * levelWidth + scoreSidebarWidth ## In pixels
  renderHeight = segmentSize * levelHeight ## In pixels

const
  levelBgColor = "#b2bd08"
  font = "Snake"

proc newSnakeSegment(pos: Point[int]): SnakeSegment =
  result = SnakeSegment(
    pos: pos
  )

proc toPixelPos(pos: Point[int]): Point[int] =
  assert pos.x <= levelWidth
  assert pos.y <= levelHeight
  return pos * segmentSize

proc newSnake(): Snake =
  let head = newSnakeSegment((0, levelHeight div 2))
  let segment = newSnakeSegment((-1, levelHeight div 2))
  let segment2 = newSnakeSegment((-2, levelHeight div 2))

  result = Snake(
    direction: dirEast,
    requestedDirection: dirEast,
    body: @[head, segment, segment2],
    alive: true
  )

proc head(snake: Snake): SnakeSegment =
  snake.body[0]

proc generateFoodPos(game: Game): Point[int] =
  result = (random(0 .. levelWidth), random(0 .. levelHeight))

proc createFood(game: Game, kind: FoodKind, foodIndex: int) =
  let pos = generateFoodPos(game)

  game.food[foodIndex] = Food(kind: kind, pos: pos)

proc newGame*(): Game =
  randomize()
  result = Game(
    renderer: newRenderer2D("canvas", renderWidth, renderHeight),
    player: newSnake()
  )

  # Create text element nodes to show score and other messages.
  let scoreTextPos = (renderWidth - scoreSidebarWidth + 25, 10)
  discard result.renderer.createTextElement("score", scoreTextPos, "#000000",
                                            "24px " & font)
  let scorePos = (renderWidth - scoreSidebarWidth + 25, 35)
  result.scoreElement = result.renderer.createTextElement("0000000", scorePos,
                         "#000000", "14px " & font)
  let gameOverTextPos = (renderWidth - scoreSidebarWidth + 23, 70)
  result.gameOverElement = result.renderer.createTextElement("game<br/>over",
                           gameOverTextPos, "#000000", "26px " & font)

  result.createFood(Apple, 0)

proc changeDirection*(game: Game, direction: Direction) =
  if game.player.direction.toPoint() == -direction.toPoint():
    return # Disallow changing direction in opposite direction of travel.

  game.player.requestedDirection = direction

proc detectHeadCollision(game: Game): bool =
  # Check if head collides with any other segment.
  for i in 1 .. <game.player.body.len:
    if game.player.head.pos == game.player.body[i].pos:
      return true

proc detectFoodCollision(game: Game): int =
  # Check if head collides with food.
  for i in 0 .. <game.food.len:
    if game.food[i].isNil:
      continue

    if game.food[i].pos == game.player.head.pos:
      return i

  return -1

proc eatFood(game: Game, foodIndex: int) =
  let tailPos = game.player.body[^1].pos.copy()
  game.player.body.add(newSnakeSegment(tailPos))

  case game.food[foodIndex].kind
  of Apple:
    game.score += 1
  of Cherry:
    game.score += 5
  game.food[foodIndex] = nil

  game.createFood(Apple, 0)

  # Update score element.
  game.scoreElement.innerHTML = intToStr(game.score, 7)

proc update(game: Game) =
  # Used for tracking time.
  game.tick.inc()

  # Check for collision with itself.
  let headCollision = game.detectHeadCollision()
  if headCollision:
    game.player.alive = false
    return

  # Check for food collision.
  let foodCollision = game.detectFoodCollision()
  if foodCollision != -1:
    game.eatFood(foodCollision)

  # Change direction.
  game.player.direction = game.player.requestedDirection

  # Save old position of head.
  var oldPos = game.player.head.pos.copy()

  # Move head in the current direction.
  let movementVec = game.player.direction.toPoint()
  game.player.head.pos.add(movementVec)

  # Move each body segment with the head.
  for i in 1 .. <game.player.body.len:
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

proc draw(game: Game) =
  game.renderer.fillRect(0, 0, renderWidth, renderHeight, levelBgColor)

  var drawSnake = true
  if (not game.player.alive) and game.tick mod 4 == 0:
    drawSnake = false

  if drawSnake:
    for segment in game.player.body:
      let pos = segment.pos.toPixelPos()
      game.renderer.fillRect(pos.x, pos.y, segmentSize, segmentSize, "#000000")

    # Draw eyes.
    # var headPos = game.player.head.pos.toPixelPos()
    # if game.player.direction in {dirSouth, dirEast}:
    #   headPos.add((segmentSize-2, segmentSize-2))
    # game.renderer.fillRect(headPos.x, headPos.y, 2, 2, "#ffffff")

  # Draw the food.
  for i in 0 .. game.food.high:
    if not game.food[i].isNil:
      var pos = game.food[i].pos.toPixelPos()
      pos.y += segmentSize
      let emoji =
        case game.food[i].kind
        of Apple: "🍎"
        of Cherry: "🍒"
      game.renderer.fillText(emoji, pos, font="$1px Helvetica" % $segmentSize)

  # Draw the scoreboard.
  game.renderer.fillRect(renderWidth - scoreSidebarWidth, 0, scoreSidebarWidth,
                         renderHeight, levelBgColor)

  game.renderer.strokeRect(renderWidth - scoreSidebarWidth, 5,
                           scoreSidebarWidth - 5, renderHeight - 10,
                           lineWidth = 2)

  if drawSnake:
    game.gameOverElement.style.display = "none"
  else:
    # Snake isn't drawn when game is over, so blink game over text.
    game.gameOverElement.style.display = "block"

proc nextFrame*(game: Game, frameTime: float) =
  let elapsedTime = frameTime - game.lastUpdate

  const tickLength = 200
  if elapsedTime > tickLength:
    game.lastUpdate = frameTime
    let ticks = round(elapsedTime / tickLength).int
    for tick in 0 .. <ticks:
      game.update()

  game.draw()