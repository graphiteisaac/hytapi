import conversation.{type RequestBody, type ResponseBody}
import gleam/bit_array
import gleam/bool
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
import hytapi/allowlist
import hytapi/discord
import hytapi/sql
import hytapi/web
import plinth/cloudflare/bindings
import plinth/cloudflare/d1
import plinth/cloudflare/worker

const auth_cookie = "__AUTH"

pub fn handle(req, env, ctx) {
  let assert Ok(db) = bindings.d1_database(env, "hytapi_prod")
    as "can't find the database binding"

  let assert Ok(secrets) = get_secrets(env) as "can't get secrets"
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
    ["login"] -> login(context)
    ["auth", "discord"] -> discord_auth(context)
    ["auth", "discord", "callback"] -> discord_callback(context)
    ["auth", "logout"] -> logout()
    ["new"] -> new_server(context)
    ["delete", id] -> delete_server(context, id)
    ["v0", "set", key, players] -> set_server(context, key, players)
    ["v0", "players", hostname] -> playercount(context, hostname)
    ["debug"] -> {
      case context.req.host {
        "localhost" -> debug_view(context)
        _ ->
          response.new(404)
          |> response.set_body(conversation.Text("Page not found"))
          |> Error
          |> promise.resolve
      }
    }
    _ ->
      response.new(404)
      |> response.set_body(conversation.Text("Page not found"))
      |> Error
      |> promise.resolve
  }
  |> promise.map(fn(result) {
    case result {
      Ok(resp) | Error(resp) -> resp
    }
  })
}

fn debug_view(context: Context) {
  use servers <- promise.await(sql.get_all_servers(context.db))

  response.new(200)
  |> response.set_body(conversation.Text(string.inspect(servers)))
  |> Ok
  |> promise.resolve
}

fn playercount(
  context: Context,
  hostname: String,
) -> Promise(Result(Response(ResponseBody), Response(ResponseBody))) {
  use dns <- promise.try_await(
    resolve_dns(hostname)
    |> promise.map(result.replace_error(
      _,
      response.new(400)
        |> response.set_header("Content-Type", "application/json")
        |> response.set_body(conversation.Text(
          "{\"error\":\"DNS resolution failed\"}",
        )),
    )),
  )

  use status <- promise.try_await(
    sql.get_server_status(context.db, dns)
    |> promise.map(result.replace_error(
      _,
      response.new(400)
        |> response.set_header("Content-Type", "application/json")
        |> response.set_body(conversation.Text(
          "{\"error\":\"Server not found\"}",
        )),
    )),
  )

  response.new(200)
  |> response.set_header("Content-Type", "application/json")
  |> response.set_body(conversation.Text(
    "{\"players\":\""
    <> int.to_string(status.players)
    <> "\",\"updated_at\":"
    <> int.to_string(status.updated_at)
    <> "}",
  ))
  |> Ok
  |> promise.resolve
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
  |> Ok
  |> promise.resolve
}

fn set_server(context: Context, key: String, player_str: String) {
  let ip = user_ip(context.req)
  let players =
    int.parse(player_str)
    |> result.unwrap(0)

  use _server_status <- promise.try_await(
    sql.set_server_status(context.db, key, ip, players)
    |> promise.map(result.replace_error(
      _,
      response.new(500)
        |> response.set_body(conversation.Text("Error updating server")),
    )),
  )

  response.new(200)
  |> response.set_header("Content-Type", "application/json")
  |> response.set_body(conversation.Text(
    "{\"status\":\"OK\",\"players\":" <> player_str <> "}",
  ))
  |> Ok
  |> promise.resolve
}

fn new_server(
  context: Context,
) -> Promise(Result(Response(ResponseBody), Response(ResponseBody))) {
  use user_id <- require_auth(context)
  case context.req.method {
    http.Post -> {
      use formdata <- promise.await(conversation.read_form(context.req.body))
      case formdata {
        Ok(conversation.FormData(values: [#("label", label)], ..)) ->
          handle_create(user_id, context, label)
        _ ->
          response.new(500)
          |> response.set_body(conversation.Text(
            "the form data submitted was not correct",
          ))
          |> Error
          |> promise.resolve
      }
    }
    _ -> {
      [web.create_server()]
      |> web.layout
      |> web.render
      |> Ok
      |> promise.resolve
    }
  }
}

fn delete_server(
  context: Context,
  id_str: String,
) -> Promise(Result(Response(ResponseBody), Response(ResponseBody))) {
  use user_id <- require_auth(context)
  use id <- promise.try_await(
    int.parse(id_str)
    |> result.replace_error(
      response.new(500)
      |> response.set_body(conversation.Text(
        "the provided server ID must be a whole number",
      )),
    )
    |> promise.resolve,
  )

  use server <- promise.try_await(
    sql.get_server_by_id(context.db, id)
    |> promise.map(result.replace_error(
      _,
      response.new(500)
        |> response.set_body(conversation.Text(
          "the form data submitted was not correct",
        )),
    )),
  )

  case context.req.method {
    http.Post -> handle_delete(context, user_id, id)

    _ -> {
      [web.delete_server(server)]
      |> web.layout
      |> web.render
      |> Ok
      |> promise.resolve
    }
  }
}

fn handle_create(
  user_id: String,
  context: Context,
  label: String,
) -> Promise(Result(Response(ResponseBody), Response(ResponseBody))) {
  use <- bool.guard(
    label == "",
    response.new(500)
      |> response.set_body(conversation.Text("labels cannot be empty"))
      |> Error
      |> promise.resolve,
  )

  use created <- promise.try_await(
    sql.create_new_server(context.db, label)
    |> promise.map(
      result.map_error(_, fn(err) {
        response.new(500)
        |> response.set_body(conversation.Text(
          "could not get server: " <> string.inspect(err),
        ))
      }),
    ),
  )
  use _server_op <- promise.await(sql.add_server_operator(
    context.db,
    created,
    user_id,
  ))

  response.new(302)
  |> response.set_header("Location", "/")
  |> response.set_body(conversation.Text("Created a new server"))
  |> Ok
  |> promise.resolve
}

fn handle_delete(context: Context, user_id: String, server_id: Int) {
  use res <- promise.await(sql.delete_server(context.db, user_id, server_id))

  case res {
    Ok(_) ->
      response.new(302)
      |> response.set_header("Location", "/")
      |> response.set_body(conversation.Text("Deleted server successfully"))
      |> Ok
      |> promise.resolve
    Error(err) ->
      response.new(500)
      |> response.set_body(conversation.Text(err))
      |> Error
      |> promise.resolve
  }
}

fn home(
  context: Context,
) -> Promise(Result(Response(ResponseBody), Response(ResponseBody))) {
  use user_id <- require_auth(context)
  use servers <- promise.try_await(
    sql.get_user_servers(context.db, user_id)
    |> promise.map(result.replace_error(
      _,
      response.new(500)
        |> response.set_body(conversation.Text(
          "something went wrong while accessing the homepage",
        )),
    )),
  )

  [web.home(servers)]
  |> web.layout
  |> web.render
  |> Ok
  |> promise.resolve
}

fn login(
  _context: Context,
) -> Promise(Result(Response(ResponseBody), Response(ResponseBody))) {
  [web.login()]
  |> web.layout
  |> web.render
  |> Ok
  |> promise.resolve
}

fn discord_auth(
  context: Context,
) -> Promise(Result(Response(ResponseBody), Response(ResponseBody))) {
  let auth_url =
    discord.redirect_uri(
      context.secrets.discord_client_id,
      context.secrets.discord_redirect_uri,
    )

  response.new(302)
  |> response.set_header("location", auth_url)
  |> response.set_body(conversation.Text("Redirecting to Discord..."))
  |> Ok
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

  // Get authorisation code from query params
  use code <- promise.try_await(
    req.query
    |> option.unwrap("")
    |> uri.parse_query
    |> result.try(list.key_find(_, "code"))
    |> result.replace_error(
      response.new(400)
      |> response.set_body(conversation.Text("Missing authorisation code")),
    )
    |> promise.resolve,
  )

  // Exchange code for access token
  use token <- promise.try_await(
    discord.exchange_code_for_token(
      discord_client_id,
      discord_client_secret,
      discord_redirect_uri,
      code,
    )
    |> promise.map(result.replace_error(
      _,
      response.new(500)
        |> response.set_body(conversation.Text("Failed to get access token")),
    )),
  )

  // Get user info from Discord
  use user_id <- promise.try_await(
    discord.token_user_id(token)
    |> promise.map(result.replace_error(
      _,
      response.new(500)
        |> response.set_body(conversation.Text("Failed to get user info")),
    )),
  )

  use <- bool.guard(
    !list.contains(allowlist.user_ids, user_id),
    response.new(401)
      |> response.set_body(conversation.Text(
        "hytapi is currently invite-only, and you aren't authorised, sorry!",
      ))
      |> Error
      |> promise.resolve,
  )

  // Get or create user in database
  use user <- promise.try_await(
    sql.get_or_create_user(context.db, user_id)
    |> promise.map(result.replace_error(
      _,
      response.new(401)
        |> response.set_body(conversation.Text("could not retrieve user")),
    )),
  )

  // Create session and redirect
  let session_token = sign_cookie(user.discord_id, context.secrets.key)

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
  |> Ok
  |> promise.resolve
}

fn require_auth(
  context: Context,
  next: fn(String) ->
    Promise(Result(Response(ResponseBody), Response(ResponseBody))),
) -> Promise(Result(Response(ResponseBody), Response(ResponseBody))) {
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
    |> Error
    |> promise.resolve
  }

  case list.key_find(request.get_cookies(context.req), auth_cookie) {
    Ok(cookie) ->
      case verify_cookie(cookie, context.secrets.key) {
        Ok(user_id) -> next(user_id)
        _ -> error("the provided cookie was invalid or malformed")
      }
    Error(_) ->
      response.new(302)
      |> response.set_header("Location", "/login")
      |> response.set_body(conversation.Text("Redirecting to /login..."))
      |> Error
      |> promise.resolve
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

pub type DNSError {
  CantSend
  NotJSON
  CantDecode(String)
}

pub fn resolve_dns(hostname: String) -> Promise(Result(String, DNSError)) {
  let req =
    request.new()
    |> request.set_scheme(http.Https)
    |> request.set_host("one.one.one.one")
    |> request.set_header("accept", "application/dns-json")
    |> request.set_path("/dns-query?name=" <> hostname <> "&type=A")

  use resp <- promise.try_await(
    fetch.send(req)
    |> promise.map(result.replace_error(_, CantSend)),
  )

  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(result.replace_error(_, NotJSON)),
  )

  let decoder = {
    use answers <- decode.optional_field(
      "Answer",
      [hostname],
      decode.list({
        use result <- decode.optional_field("data", hostname, decode.string)
        decode.success(result)
      }),
    )
    decode.success(answers)
  }

  case decode.run(resp.body, decoder) {
    Ok([answer, ..]) -> promise.resolve(Ok(answer))
    Ok([]) -> promise.resolve(Ok(hostname))
    Error(err) -> {
      promise.resolve(Error(CantDecode(string.inspect(err))))
    }
  }
}

fn user_ip(req: Request(a)) -> String {
  case request.get_header(req, "Cf-Connecting-Ip") {
    Ok(ip) -> ip
    Error(_) -> "0.0.0.0"
  }
}
