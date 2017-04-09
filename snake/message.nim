import json, algorithm, future

# TODO: It's annoying that we need to import these for FoodKind and Point...
import gamelight/[vec, geometry], food

import replay

type
  MessageType* {.pure.} = enum
    Hello, ScoreUpdate, PlayerUpdate

  Player* = object
    nickname*: string
    score*: BiggestInt
    alive*, paused*: bool

  Message* = object
    case kind*: MessageType
    of MessageType.Hello:
      nickname*: string
    of MessageType.ScoreUpdate:
      score*: BiggestInt
      alive*: bool
      paused*: bool
      replay*: Replay
    of MessageType.PlayerUpdate:
      players*: seq[Player]
      count*: int
      top*: Player

# TODO: Use marshal module.

proc parsePlayer*(player: JsonNode): Player =
  Player(
    nickname: player["nickname"].getStr,
    score: player["score"].getNum(),
    alive: player["alive"].getBVal(),
    paused: player["paused"].getBVal()
  )

proc parseMessage*(data: string): Message =
  let json = parseJson(data)

  result.kind = MessageType(json["kind"].getNum())
  case result.kind
  of MessageType.Hello:
    result.nickname = json["nickname"].getStr()
  of MessageType.ScoreUpdate:
    result.score = json["score"].getNum()
    result.alive = json["alive"].getBVal()
    result.paused = json["paused"].getBVal()
    if json["replay"].kind == JString:
      result.replay = to(json["replay"], Replay)
  of MessageType.PlayerUpdate:
    result.players = @[]
    for player in json["players"]:
      result.players.add(parsePlayer(player))
    result.count = json["count"].getNum().int
    result.top = parsePlayer(json["top"])

proc `%`(player: Player): JsonNode =
  %{
        "nickname": %player.nickname,
        "score": %player.score,
        "alive": %player.alive,
        "paused": %player.paused
   }

proc toJson*(message: Message): string =
  var json = newJObject()
  json["kind"] = %int(message.kind)

  case message.kind
  of MessageType.Hello:
    json["nickname"] = %message.nickname
  of MessageType.ScoreUpdate:
    json["score"] = %message.score
    json["alive"] = %message.alive
    json["paused"] = %message.paused
    json["replay"] = %message.replay
  of MessageType.PlayerUpdate:
    var players: seq[JsonNode] = @[]
    for player in message.players:
      players.add(%player)
    json["players"] = %players
    json["count"] = %message.count
    json["top"] = %message.top

  result = $json

proc createHelloMessage*(nickname: string): Message =
  Message(kind: MessageType.Hello, nickname: nickname)

proc createScoreUpdateMessage*(score: int, alive, paused: bool,
                               replay: Replay): Message =
  Message(kind: MessageType.ScoreUpdate, score: score, alive: alive,
          paused: paused, replay: replay)

proc createPlayerUpdateMessage*(players: seq[Player], top: Player): Message =
  # Sort by high score.
  let sorted = sorted(players, (x, y: Player) => cmp(x.score, y.score),
                      Descending)

  let selection = sorted[0 .. <min(sorted.len, 5)]

  return Message(
    kind: MessageType.PlayerUpdate,
    players: selection,
    count: players.len,
    top: top
  )

proc initPlayer*(): Player =
  Player(nickname: "Unknown", score: 0)