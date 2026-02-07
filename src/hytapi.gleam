import conversation.{type RequestBody, type ResponseBody}
import gleam/bit_array
import gleam/crypto
import gleam/dynamic
import gleam/dynamic/decode
import gleam/fetch
import gleam/http
import gleam/http/cookie
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri
import hytapi/discord
import hytapi/sql
import hytapi/web
import plinth/cloudflare/bindings
import plinth/cloudflare/d1
import plinth/cloudflare/worker

const auth_cookie = "__AUTH"

pub fn handle(req, env, ctx) {
  let assert Ok(db) =
    bindings.d1_database(env, "hytapi_prod")
    |> result.replace_error(fn(e) { echo e })

  let assert Ok(secrets) = get_secrets(env)
  let req = conversation.to_gleam_request(req)

  let context = Context(secrets, req, env, ctx, db)
  use resp <- promise.map(do_fetch(context))
  conversation.to_js_response(resp)
}

type Context {
  Context(
    secrets: Secrets,
    req: Request(RequestBody),
    env: dynamic.Dynamic,
    ctx: worker.Context,
    db: d1.Database,
  )
}

type Secrets {
  Secrets(
    key: String,
    discord_client_id: String,
    discord_client_secret: String,
    discord_redirect_uri: String,
  )
}

fn do_fetch(context: Context) -> Promise(Response(ResponseBody)) {
  let Context(req:, ..) = context
  case uri.path_segments(req.path) {
    [] -> home(context)
    ["auth", "discord"] -> discord_auth(context)
    ["auth", "discord", "callback"] -> discord_callback(context)
    ["auth", "logout"] -> logout()
    ["v1", "new"] -> new_server(context)
    ["v1", "set", hostname] -> set_server(context, hostname)
    ["v1", "players", hostname] -> {
      // TODO: Resolve given hostname to a real hostname
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

fn home(context: Context) -> Promise(Response(ResponseBody)) {
  use user_id, _ <- require_auth(context)
  use servers <- promise.await(sql.get_user_servers(context.db, user_id))

  // let table =
  //   tobble.builder()
  //   |> tobble.add_row(["id", "hostname", "players", "key"])

  case servers {
    Ok(servers) -> {
      // let assert Ok(table) =
      //   list.fold(servers, table, fn(table, server) {
      //     tobble.add_row(table, [
      //       int.to_string(server.id),
      //       server.hostname,
      //       int.to_string(server.players_online),
      //       server.key,
      //     ])
      //   })
      //   |> tobble.add_row(["", "<a href=\"/v1/new\">create new</a>", "", ""])
      //   |> tobble.build
      //
      // let output =
      //   "<!DOCTYPE html><html><head><title>hytapi</title><body><pre>"
      //   <> tobble.render(table)
      //   <> "</pre></body></html>"
      [web.home(servers)]
      |> web.layout
      |> web.render
      |> promise.resolve
    }
    Error(_) ->
      response.new(200)
      |> response.set_body(conversation.Text(string.inspect(servers)))
      |> promise.resolve
  }
}

fn discord_auth(context: Context) -> Promise(Response(ResponseBody)) {
  let auth_url =
    discord.redirect_uri(
      context.secrets.discord_client_id,
      context.secrets.discord_redirect_uri,
    )

  response.new(302)
  |> response.set_header("location", auth_url)
  |> response.set_body(conversation.Text("Redirecting to Discord..."))
  |> promise.resolve
}

fn discord_callback(context: Context) {
  let Context(
    secrets: Secrets(
      discord_client_id:,
      discord_client_secret:,
      discord_redirect_uri:,
      ..,
    ),
    req:,
    ..,
  ) = context

  // Get authorization code from query params
  let code_result =
    req.query
    |> option.unwrap("")
    |> uri.parse_query
    |> result.try(list.key_find(_, "code"))

  case code_result {
    Ok(code) -> {
      // Exchange code for access token
      use token_response <- promise.await(discord.exchange_code_for_token(
        discord_client_id,
        discord_client_secret,
        discord_redirect_uri,
        code,
      ))

      case token_response {
        Ok(token) -> {
          // Get user info from Discord
          use user_response <- promise.await(discord.token_user_id(token))

          case user_response {
            Ok(user_id) -> {
              use user <- promise.await(sql.get_or_create_user(
                context.db,
                user_id,
              ))
              case user {
                Ok(user) -> {
                  let cookie_string =
                    int.to_string(user.id) <> "_" <> user.discord_id

                  let session_token =
                    sign_cookie(cookie_string, context.secrets.key)

                  response.new(302)
                  |> response.set_header("location", "/")
                  |> response.set_body(conversation.Text(
                    "Authentication successful: " <> string.inspect(user),
                  ))
                  |> response.set_cookie(
                    auth_cookie,
                    session_token,
                    cookie.Attributes(
                      max_age: option.Some(2_592_000),
                      domain: option.None,
                      path: option.Some("/"),
                      secure: True,
                      http_only: True,
                      same_site: option.Some(cookie.Lax),
                    ),
                  )
                  |> promise.resolve
                }
                Error(_) ->
                  response.new(401)
                  |> response.set_body(conversation.Text(
                    "could not retrieve user",
                  ))
                  |> promise.resolve
              }
            }
            Error(_) -> {
              response.new(500)
              |> response.set_body(conversation.Text("Failed to get user info"))
              |> promise.resolve
            }
          }
        }
        Error(_) -> {
          response.new(500)
          |> response.set_body(conversation.Text("Failed to get access token"))
          |> promise.resolve
        }
      }
    }
    Error(_) -> {
      response.new(400)
      |> response.set_body(conversation.Text("Missing authorization code"))
      |> promise.resolve
    }
  }
}

fn logout() {
  response.new(200)
  |> response.set_cookie(
    auth_cookie,
    "",
    cookie.Attributes(
      max_age: option.Some(0),
      domain: option.None,
      path: option.Some("/"),
      secure: True,
      http_only: True,
      same_site: option.Some(cookie.Lax),
    ),
  )
  |> response.set_body(conversation.Text("Successful logout"))
  |> promise.resolve
}

fn set_server(context: Context, hostname: String) {
  use key <- extract_key(context.req)
  // let query =
  //   d1.prepare(
  //     context.db,
  //     "INSERT INTO servers (hostname, players, updated_at) VALUES (?1, ?2, now()) ON CONFLICT(hostname) DO UPDATE SET players = ?2, updated_at = now()",
  //   )
  // d1.bind(query, [hostname, int.to_string(players)])

  response.new(200)
  |> response.set_body(conversation.Text(
    "(Not implemented) Set status (" <> key <> ")" <> hostname,
  ))
  |> promise.resolve
}

fn extract_key(
  req: Request(RequestBody),
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

fn new_server(context: Context) {
  case context.req.method {
    http.Post -> {
      response.new(200)
      |> response.set_body(conversation.Text("Bello"))
    }
    _ -> {
      [web.home([])]
      |> web.layout
      |> web.render
    }
  }
  |> promise.resolve
}

fn require_auth(
  context: Context,
  next: fn(Int, String) -> Promise(Response(ResponseBody)),
) -> Promise(Response(ResponseBody)) {
  let error = fn(message: String) {
    response.new(401)
    |> response.set_cookie(
      auth_cookie,
      "",
      cookie.Attributes(
        max_age: option.Some(0),
        domain: option.None,
        path: option.Some("/"),
        secure: True,
        http_only: True,
        same_site: option.Some(cookie.Lax),
      ),
    )
    |> response.set_body(conversation.Text(message))
    |> promise.resolve
  }

  case list.key_find(request.get_cookies(context.req), auth_cookie) {
    Ok(cookie) ->
      case
        verify_cookie(cookie, context.secrets.key),
        string.split_once(cookie, ".")
      {
        Ok(_), Ok(#(id, discord_id)) ->
          case int.parse(id) {
            Ok(id) -> next(id, discord_id)
            _ -> error("the provided cookie was invalid")
          }
        _, _ -> error("the provided cookie was invalid or malformed")
      }
    Error(_) -> error("no auth cookie was provided")
  }
}

// --- UTILS ----

// Sign a cookie value with HMAC-SHA256
fn sign_cookie(value: String, secret: String) -> String {
  let signature =
    crypto.hmac(<<value:utf8>>, crypto.Sha256, <<secret:utf8>>)
    |> bit_array.base64_url_encode(False)

  value <> "." <> signature
}

// Verify and extract a signed cookie value
fn verify_cookie(signed_value: String, secret: String) -> Result(String, Nil) {
  case string.split(signed_value, ".") {
    [value, signature] -> {
      let expected_signature =
        crypto.hmac(<<value:utf8>>, crypto.Sha256, <<secret:utf8>>)
        |> bit_array.base64_url_encode(False)

      case signature == expected_signature {
        True -> Ok(value)
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn get_secrets(
  env: dynamic.Dynamic,
) -> Result(Secrets, List(decode.DecodeError)) {
  use key <- result.try(bindings.secret(env, "AUTH_SECRET_KEY"))
  use discord_client_id <- result.try(bindings.secret(env, "DISCORD_CLIENT_ID"))
  use discord_client_secret <- result.try(bindings.secret(
    env,
    "DISCORD_CLIENT_SECRET",
  ))
  use discord_redirect_uri <- result.try(bindings.secret(
    env,
    "DISCORD_REDIRECT_URI",
  ))

  Ok(Secrets(
    key:,
    discord_client_id:,
    discord_client_secret:,
    discord_redirect_uri:,
  ))
}

pub fn resolve_dns(
  hostname: String,
) -> Promise(Result(String, fetch.FetchError)) {
  let req =
    request.new()
    |> request.set_scheme(http.Https)
    |> request.set_host("one.one.one.one")
    |> request.set_header("accept", "application/dns-json")
    |> request.set_path("/dns-query?name=" <> hostname <> "&type=A")

  use resp <- promise.try_await(fetch.send(req))
  use resp <- promise.try_await(fetch.read_json_body(resp))

  let decoder = {
    use answers <- decode.field(
      "Answer",
      decode.list({
        use result <- decode.field("data", decode.string)
        decode.success(result)
      }),
    )
    decode.success(answers)
  }

  case decode.run(resp.body, decoder) {
    Ok([answer, ..]) -> promise.resolve(Ok(answer))
    _ -> promise.resolve(Error(fetch.InvalidJsonBody))
  }
}
