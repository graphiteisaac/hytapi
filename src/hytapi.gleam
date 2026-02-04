import conversation.{type ResponseBody}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option
import gleam/result
import gleam/uri
import plinth/cloudflare/bindings
import plinth/cloudflare/d1
import plinth/cloudflare/worker

pub fn fetch(req, env, ctx) {
  let assert Ok(db) =
    bindings.d1_database(env, "db_prod")
    |> result.replace_error(fn(e) { echo e })

  let req = conversation.to_gleam_request(req)
  use resp <- promise.map(do_fetch(req, env, ctx, db))
  conversation.to_js_response(resp)
}

type SetParams {
  SetParams(hostname: String, players: Int)
}

type Context {
  Context(
    req: request.Request(conversation.RequestBody),
    env: dynamic.Dynamic,
    ctx: worker.Context,
    db: d1.Database,
  )
}

fn set_params_decoder() -> decode.Decoder(SetParams) {
  use hostname <- decode.field("hostname", decode.string)
  use players <- decode.field("players", decode.int)
  decode.success(SetParams(hostname:, players:))
}

pub fn do_fetch(
  req: request.Request(conversation.RequestBody),
  env: dynamic.Dynamic,
  ctx: worker.Context,
  db: d1.Database,
) {
  let context = Context(req, env, ctx, db)

  case uri.path_segments(req.path) {
    ["v1", "set", hostname] -> set_server(req, context, hostname)
    ["v1", "ping", hostname] -> {
      response.new(200)
      |> response.set_body(conversation.Text(
        "(Not implemented) Ping " <> hostname,
      ))
      |> promise.resolve
    }
    _ ->
      response.new(404)
      |> response.set_body(conversation.Text("Page not found"))
      |> promise.resolve
  }
}

fn set_server(req, context: Context, hostname: String) {
  use key <- extract_key(req)
  // let query =
  //   d1.prepare(
  //     context.db,
  //     "INSERT INTO servers (hostname, players) VALUES (?1, ?2) ON CONFLICT(hostname) DO UPDATE SET players = ?2",
  //   )
  // d1.bind(query, [hostname, int.to_string(players)])

  response.new(200)
  |> response.set_body(conversation.Text(
    "(Not implemented) Set status (" <> key <> ")" <> hostname,
  ))
  |> promise.resolve
}

fn extract_key(
  req: request.Request(conversation.RequestBody),
  next: fn(String) -> Promise(Response(ResponseBody)),
) -> Promise(Response(ResponseBody)) {
  let resp =
    response.new(401)
    |> response.set_body(conversation.Text("you must provide a key"))
    |> promise.resolve

  case uri.parse_query(option.unwrap(req.query, "0")) {
    Ok(params) ->
      case list.key_find(params, "key") {
        Ok(key) -> next(key)
        Error(_) -> resp
      }
    Error(_) -> resp
  }
}
